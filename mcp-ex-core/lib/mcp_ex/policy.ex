defmodule McpEx.Policy do
  @moduledoc "Conservative single-statement SQL policy; the database enforces read-only reads."
  alias McpEx.{Config, Redact}

  def check(sql, config) when is_binary(sql) and byte_size(sql) > 0 do
    if byte_size(sql) > config.max_bytes,
      do: raise(ArgumentError, "SQL exceeds the request limit")

    tokens = sql |> tokenize(config.dialect) |> single_statement!()

    words =
      Enum.flat_map(tokens, fn
        {:word, word} -> [String.upcase(word)]
        _ -> []
      end)

    if Enum.any?(tokens, fn
         {kind, value} when kind in [:word, :identifier] ->
           String.upcase(value) in ~w(OUTFILE DUMPFILE LOAD_FILE)

         _ ->
           false
       end),
       do: raise(ArgumentError, "File access SQL is disabled")

    {mode, operations, schema} = classify(tokens, words, config)

    Enum.each(operations, fn operation ->
      unless Config.allowed?(config, operation, schema),
        do:
          raise(
            ArgumentError,
            "#{String.upcase(operation)} is not permitted for schema #{inspect(schema)}"
          )
    end)

    introspection = introspection(tokens, words)
    pii!(tokens, introspection, config)
    %{mode: mode, schema: schema, introspection: introspection}
  end

  def check(_, _), do: raise(ArgumentError, "sql must be a nonempty string")

  def tokenize(sql, dialect), do: lex(sql, dialect, []) |> Enum.reverse()

  defp lex("", _, acc), do: acc

  defp lex(<<c, rest::binary>>, dialect, acc) when c in [9, 10, 13, 32],
    do: lex(rest, dialect, acc)

  defp lex("/*!" <> _, _, _), do: raise(ArgumentError, "Executable SQL comments are disabled")
  defp lex("/*M!" <> _, _, _), do: raise(ArgumentError, "Executable SQL comments are disabled")

  defp lex("/*" <> rest, :mysql, acc) do
    case :binary.split(rest, "*/") do
      [body, tail] ->
        if String.contains?(body, "/*"),
          do: raise(ArgumentError, "Nested MySQL comments are disabled")

        lex(tail, :mysql, acc)

      _ ->
        raise ArgumentError, "Unterminated SQL comment"
    end
  end

  defp lex("/*" <> rest, dialect, acc), do: lex(comment(rest, 1), dialect, acc)

  defp lex("--" <> rest = sql, dialect, acc) do
    if dialect == :pg or rest == "" or String.starts_with?(rest, [" ", "\t", "\r", "\n"]) do
      lex(skip_line(rest), dialect, acc)
    else
      <<_, rest::binary>> = sql
      lex(rest, dialect, [{:symbol, "-"} | acc])
    end
  end

  defp lex("#" <> rest, :mysql, acc), do: lex(skip_line(rest), :mysql, acc)

  defp lex(<<quote, rest::binary>>, dialect, acc) when quote in [?', ?", ?`] do
    if quote == ?` and dialect == :pg,
      do: raise(ArgumentError, "Backticks are not PostgreSQL identifiers")

    {value, rest} = quoted(rest, quote, "")

    # Double-quoted MySQL SQL depends on sql_mode; rejecting it avoids ambiguous policy interpretation.
    if quote == ?" and dialect == :mysql,
      do:
        raise(ArgumentError, "Use backticks for MySQL identifiers and single quotes for strings")

    kind = if quote == ?', do: :literal, else: :identifier
    lex(rest, dialect, [{kind, value} | acc])
  end

  defp lex("$" <> _ = sql, :pg, acc) do
    cond do
      match = Regex.run(~r/^\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$/, sql) ->
        [delimiter] = match
        rest = binary_part(sql, byte_size(delimiter), byte_size(sql) - byte_size(delimiter))

        case :binary.split(rest, delimiter) do
          [value, tail] -> lex(tail, :pg, [{:literal, value} | acc])
          _ -> raise ArgumentError, "Unterminated dollar string"
        end

      match = Regex.run(~r/^\$[0-9]+/, sql) ->
        [param] = match
        lex(drop(sql, param), :pg, [{:literal, param} | acc])

      true ->
        raise ArgumentError, "Invalid dollar token"
    end
  end

  defp lex(sql, dialect, acc) do
    cond do
      match = Regex.run(~r/^[\p{L}_][\p{L}\p{N}_$]*/u, sql) ->
        [word] = match
        lex(drop(sql, word), dialect, [{:word, word} | acc])

      match = Regex.run(~r/^[0-9]+(?:\.[0-9]+)?/, sql) ->
        [number] = match
        lex(drop(sql, number), dialect, [{:literal, number} | acc])

      true ->
        <<c::utf8, rest::binary>> = sql
        if c not in ~c"().,;*+-/%=<>!?|&:[]", do: raise(ArgumentError, "Unsupported SQL token")
        lex(rest, dialect, [{:symbol, <<c::utf8>>} | acc])
    end
  end

  defp drop(sql, prefix),
    do: binary_part(sql, byte_size(prefix), byte_size(sql) - byte_size(prefix))

  defp skip_line(sql) do
    case :binary.split(sql, "\n") do
      [_] -> ""
      [_, rest] -> rest
    end
  end

  defp comment("", _), do: raise(ArgumentError, "Unterminated SQL comment")
  defp comment("/*!" <> _, _), do: raise(ArgumentError, "Executable SQL comments are disabled")
  defp comment("/*" <> rest, n), do: comment(rest, n + 1)
  defp comment("*/" <> rest, 1), do: rest
  defp comment("*/" <> rest, n), do: comment(rest, n - 1)
  defp comment(<<_, rest::binary>>, n), do: comment(rest, n)
  defp quoted("", _, _), do: raise(ArgumentError, "Unterminated SQL quote")
  defp quoted(<<q, q, rest::binary>>, q, acc), do: quoted(rest, q, acc <> <<q>>)
  defp quoted(<<q, rest::binary>>, q, acc), do: {acc, rest}

  defp quoted("\\" <> _, _, _),
    do: raise(ArgumentError, "Use doubled SQL quotes; backslash escapes are disabled")

  defp quoted(<<c::utf8, rest::binary>>, q, acc), do: quoted(rest, q, acc <> <<c::utf8>>)

  defp single_statement!(tokens) do
    tokens = if List.last(tokens) == {:symbol, ";"}, do: Enum.drop(tokens, -1), else: tokens

    if tokens == [] or {:symbol, ";"} in tokens,
      do: raise(ArgumentError, "Exactly one SQL statement is required")

    tokens
  end

  defp classify([{:word, first} | tail] = tokens, words, config) do
    case String.upcase(first) do
      read when read in ~w(SELECT WITH SHOW DESCRIBE DESC EXPLAIN VALUES) ->
        {:read, [], nil}

      "INSERT" ->
        insert_target(tail, words, config)

      "UPDATE" ->
        {schema, rest} = target(tail, config)

        unless keyword?(List.first(rest), "SET"),
          do: raise(ArgumentError, "Only single-table UPDATE is supported")

        simple_write!(rest, ~w(SELECT JOIN WITH DELETE INSERT UPDATE FROM))
        {:write, ["update"], schema}

      "DELETE" ->
        delete_target(tail, config)

      ddl when ddl in ~w(CREATE ALTER DROP TRUNCATE) ->
        ddl_target(tokens, config)

      _ ->
        raise ArgumentError, "SQL statement type is disabled"
    end
  end

  defp classify(_, _, _), do: raise(ArgumentError, "SQL must start with a statement keyword")

  defp insert_target(tail, words, config) do
    {schema, rest} = tail |> expect("INTO") |> target(config)

    unless List.first(rest) == {:symbol, "("} or
             Enum.any?(~w(VALUES VALUE DEFAULT AS), &keyword?(List.first(rest), &1)),
           do: raise(ArgumentError, "Only an explicit single-table INSERT is supported")

    simple_write!(rest, ~w(SELECT JOIN WITH DELETE INSERT))
    operations = if "UPDATE" in words, do: ["insert", "update"], else: ["insert"]
    {:write, operations, schema}
  end

  defp delete_target(tail, config) do
    {schema, rest} = tail |> expect("FROM") |> target(config)

    if rest != [] and not keyword?(List.first(rest), "WHERE") and
         not keyword?(List.first(rest), "RETURNING"),
       do: raise(ArgumentError, "Only single-table DELETE is supported")

    simple_write!(rest, ~w(SELECT JOIN WITH DELETE INSERT UPDATE USING))
    {:write, ["delete"], schema}
  end

  defp ddl_target([{:word, operation} | rest], config) do
    operation = String.upcase(operation)

    rest =
      if operation == "TRUNCATE" and not keyword?(List.first(rest), "TABLE"),
        do: rest,
        else: expect(rest, "TABLE")

    rest = existence_condition(rest)

    {schema, tail} = target(rest, config)

    if operation == "CREATE" and List.first(tail) != {:symbol, "("},
      do: raise(ArgumentError, "CREATE TABLE requires explicit column definitions")

    if operation in ["DROP", "TRUNCATE"] and tail != [],
      do: raise(ArgumentError, "Only one table without CASCADE is supported")

    simple_write!(
      tail,
      ~w(SELECT JOIN WITH REFERENCES RENAME EXCHANGE ATTACH DETACH INHERIT FOREIGN FUNCTION PROCEDURE TRIGGER CASCADE)
    )

    if operation == "ALTER" and Enum.any?(tail, &keyword?(&1, "SCHEMA")),
      do: raise(ArgumentError, "Schema changes are disabled")

    {:ddl, ["ddl"], schema}
  end

  defp existence_condition(rest) do
    if keyword?(List.first(rest), "IF") do
      rest = tl(rest)
      rest = if keyword?(List.first(rest), "NOT"), do: tl(rest), else: rest
      expect(rest, "EXISTS")
    else
      rest
    end
  end

  defp target([first, {:symbol, "."}, second | rest], config) do
    identifier!(second, config.dialect)

    if match?([{:symbol, "."} | _], rest),
      do: raise(ArgumentError, "Write targets must use table or schema.table")

    {identifier!(first, config.dialect), rest}
  end

  defp target([first | rest], config) do
    identifier!(first, config.dialect)
    if is_nil(config.schema), do: raise(ArgumentError, "Writes require a schema-qualified table")
    {config.schema, rest}
  end

  defp target(_, _), do: raise(ArgumentError, "Missing write target")

  defp identifier!({:word, value}, dialect) do
    if String.upcase(value) in ~w(ONLY IF NOT EXISTS),
      do: raise(ArgumentError, "Unsupported table modifier")

    if dialect == :pg, do: String.downcase(value), else: value
  end

  defp identifier!({kind, value}, _) when kind in [:word, :identifier], do: value
  defp identifier!(_, _), do: raise(ArgumentError, "Invalid table identifier")

  defp expect([token | rest], keyword) do
    if keyword?(token, keyword), do: rest, else: raise(ArgumentError, "Expected #{keyword}")
  end

  defp expect(_, keyword), do: raise(ArgumentError, "Expected #{keyword}")
  defp keyword?({:word, value}, keyword), do: String.upcase(value) == keyword
  defp keyword?(_, _), do: false

  defp simple_write!(tokens, blocked) do
    if Enum.any?(tokens, fn token -> Enum.any?(blocked, &keyword?(token, &1)) end),
      do: raise(ArgumentError, "Complex writes are disabled; use a single table statement")
  end

  defp introspection(tokens, words) do
    cond do
      Enum.any?(tokens, fn
        {kind, value} when kind in [:word, :identifier] ->
          String.downcase(value) in ~w(information_schema mysql performance_schema sys pg_catalog) or
              String.starts_with?(String.downcase(value), "pg_")

        _ ->
          false
      end) ->
        :blocked

      List.first(words) in ~w(DESCRIBE DESC) ->
        :columns

      List.first(words) == "EXPLAIN" and
          Enum.at(words, 1) not in ~w(SELECT INSERT UPDATE DELETE REPLACE ANALYZE FORMAT EXTENDED PARTITIONS) ->
        :columns

      List.first(words) == "SHOW" ->
        show_introspection(tl(words))

      true ->
        nil
    end
  end

  defp show_introspection([kind | _]) when kind in ~w(COLUMNS FIELDS INDEX INDEXES KEYS),
    do: :columns

  defp show_introspection(["FULL", kind | _]) when kind in ~w(COLUMNS FIELDS), do: :columns

  defp show_introspection([kind | _])
       when kind in ~w(TABLES DATABASES SCHEMAS CHARACTER CHARSET COLLATION), do: :topology

  defp show_introspection(_), do: :blocked

  defp pii!(_, _, %{pii: false}), do: :ok

  defp pii!(tokens, introspection, config) do
    if not config.pii_introspection and
         (introspection == :blocked or (config.pii_block_introspection and introspection)),
       do:
         raise(
           ArgumentError,
           "SQL introspection is disabled by PII policy; use MCP table resources"
         )

    if not config.pii_star, do: check_wildcards!(tokens)

    if not config.pii_references and
         Enum.any?(tokens, fn
           {kind, value} when kind in [:word, :identifier] -> Redact.column?(value, config)
           _ -> false
         end),
       do: raise(ArgumentError, "Query references a protected PII identifier")
  end

  defp check_wildcards!(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.each(fn
      {{:symbol, "*"}, index} ->
        unless Enum.at(tokens, index - 1) == {:symbol, "("} and
                 keyword?(Enum.at(tokens, index - 2), "COUNT"),
               do:
                 raise(
                   ArgumentError,
                   "Wildcard SQL is disabled by PII policy; project explicit columns"
                 )

      _ ->
        :ok
    end)
  end
end
