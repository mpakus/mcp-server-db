defmodule McpEx.Server do
  @moduledoc "The database MCP request handlers, shared by stdio and HTTP sessions."
  alias McpEx.{Cache, Config, Diagnostics, Policy, Redact}
  @versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  def versions, do: @versions

  def info(config), do: %{"name" => "mcp-ex-#{config.dialect}", "version" => "0.1.0"}

  def handle(message, context, state \\ :ready),
    do: Diagnostics.rpc(context, message, fn -> do_handle(message, context, state) end)

  defp do_handle(%{"jsonrpc" => "2.0", "method" => method} = message, context, state)
       when is_binary(method) do
    params = Map.get(message, "params", %{})

    cond do
      not is_map(params) ->
        {error(Map.get(message, "id"), -32602, "params must be an object"), state}

      not Map.has_key?(message, "id") ->
        next =
          if method == "notifications/initialized" and state == :initializing,
            do: :ready,
            else: state

        {nil, next}

      not is_integer(message["id"]) and not is_binary(message["id"]) ->
        {error(nil, -32600, "Invalid request id"), state}

      state != :ready and method not in ["initialize", "ping"] ->
        {error(message["id"], -32000, "Initialize the MCP connection first"), state}

      true ->
        try do
          result = dispatch(method, params, context)
          next = if method == "initialize" and state == :new, do: :initializing, else: state
          {%{"jsonrpc" => "2.0", "id" => message["id"], "result" => result}, next}
        rescue
          error in ArgumentError ->
            {error(message["id"], -32602, Exception.message(error)), state}

          error ->
            {error(message["id"], -32603, safe_error(error, context.config)), state}
        catch
          {:rpc, code, reason} -> {error(message["id"], code, reason), state}
        end
    end
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => _} = message, _, state)
       when is_map_key(message, "result") or is_map_key(message, "error"), do: {nil, state}

  defp do_handle(_, _, state), do: {error(nil, -32600, "Invalid JSON-RPC request"), state}

  def error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  def encode(nil, _limit), do: nil

  def encode(response, limit) do
    encoded = Jason.encode_to_iodata!(response)

    if IO.iodata_length(encoded) <= limit,
      do: IO.iodata_to_binary(encoded),
      else:
        Jason.encode!(error(response["id"], -32000, "Response too large; use a smaller query"))
  end

  defp dispatch("initialize", params, context) do
    version = params["protocolVersion"]

    unless is_binary(version) and is_map(params["capabilities"]) and is_map(params["clientInfo"]),
      do: raise(ArgumentError, "initialize requires protocolVersion, capabilities and clientInfo")

    %{
      "protocolVersion" => if(version in @versions, do: version, else: hd(@versions)),
      "capabilities" => %{"tools" => %{}, "resources" => %{}},
      "serverInfo" => info(context.config),
      "instructions" =>
        "Use table resources for schema discovery. Submit one SQL statement per call. Writes require configured permissions."
    }
  end

  defp dispatch("ping", _, _), do: %{}

  defp dispatch("tools/list", _, %{config: config}) do
    read_only = Config.read_only?(config)

    %{
      "tools" => [
        %{
          "name" => config.tool,
          "description" =>
            "Execute a single #{config.dialect} SQL statement. Reads use read-only transactions; writes require operation and schema permission.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{
              "sql" => %{"type" => "string", "description" => "SQL statement"},
              "cache" => %{
                "type" => "boolean",
                "default" => false,
                "description" =>
                  "Opt into TTL reuse for this read when MCP_CACHE_ENABLED=true; use only for reads that may be stale."
              },
              "params" => %{
                "type" => "array",
                "description" => "Bound values: ? for MySQL, $1/$2 for PostgreSQL",
                "items" => %{}
              }
            },
            "required" => ["sql"],
            "additionalProperties" => false
          },
          "annotations" => %{
            "readOnlyHint" => read_only,
            "destructiveHint" => not read_only,
            "idempotentHint" => read_only,
            "openWorldHint" => false
          }
        }
      ]
    }
  end

  defp dispatch("tools/call", params, context) do
    unless params["name"] == context.config.tool, do: throw({:rpc, -32602, "Unknown tool"})

    Diagnostics.tool(context, fn ->
      try do
        {sql, values, cache?} =
          Diagnostics.step(context, "validation_errors", fn ->
            arguments = params["arguments"]
            unless is_map(arguments), do: raise(ArgumentError, "arguments must be an object")

            if Enum.any?(Map.keys(arguments), &(&1 not in ["sql", "params", "cache"])),
              do: raise(ArgumentError, "Unknown tool argument")

            values = Map.get(arguments, "params", [])
            unless is_list(values), do: raise(ArgumentError, "params must be an array")
            unless is_binary(arguments["sql"]), do: raise(ArgumentError, "sql must be a string")
            cache? = Map.get(arguments, "cache", false)
            unless is_boolean(cache?), do: raise(ArgumentError, "cache must be a boolean")
            {arguments["sql"], values, cache?}
          end)

        policy =
          Diagnostics.step(context, "policy_rejections", fn ->
            policy = Policy.check(sql, context.config)

            if cache? and policy.mode != :read,
              do: raise(ArgumentError, "cache is only valid for read queries")

            policy
          end)

        start = System.monotonic_time(:microsecond)
        execute = fn -> query_payload(context, sql, values, policy) end

        {payload, status} =
          if cache?, do: Cache.fetch(context, sql, values, execute), else: {execute.(), :bypass}

        if cache?, do: Diagnostics.count(context, "cache_" <> Atom.to_string(status))
        elapsed = (System.monotonic_time(:microsecond) - start) / 1000
        label = if status == :hit, do: "Cache lookup time", else: "Query execution time"

        result = %{
          "content" => [text(payload), text("#{label}: #{Float.round(elapsed, 2)} ms")],
          "isError" => false
        }

        if cache?,
          do: Map.put(result, "_meta", %{"cache" => Atom.to_string(status)}),
          else: result
      rescue
        error ->
          %{
            "content" => [text("Error: " <> safe_error(error, context.config))],
            "isError" => true
          }
      end
    end)
  end

  defp dispatch("resources/list", _, context) do
    config = context.config

    resources =
      Enum.map(tables(context), fn table ->
        %{
          "uri" => table_uri(config, table["schema"], table["name"]),
          "name" => table["name"],
          "title" => "#{table["schema"]}.#{table["name"]}",
          "description" => "Table or view column metadata",
          "mimeType" => "application/json"
        }
      end)

    %{
      "resources" => [
        %{
          "uri" => config.scheme <> "://tables",
          "name" => "Tables",
          "mimeType" => "application/json",
          "description" => "Accessible tables and views"
        }
        | resources
      ]
    }
  end

  defp dispatch("resources/read", %{"uri" => uri}, context) when is_binary(uri) do
    parsed = URI.parse(uri)

    unless parsed.scheme == context.config.scheme and parsed.host == "tables" and
             is_nil(parsed.query) and is_nil(parsed.fragment) and is_nil(parsed.userinfo) and
             is_nil(parsed.port),
           do: throw({:rpc, -32002, "Unknown resource URI"})

    payload =
      case parsed.path do
        path when path in [nil, "", "/"] ->
          tables(context)

        path ->
          parts = path |> String.trim_leading("/") |> String.split("/") |> Enum.map(&URI.decode/1)

          {schema, table} =
            case parts do
              [schema, table] when schema != "" and table != "" ->
                {schema, table}

              [table] when table != "" and not is_nil(context.config.schema) ->
                {context.config.schema, table}

              _ ->
                throw({:rpc, -32002, "Use a schema-qualified table resource URI"})
            end

          unless Enum.any?(tables(context), &(&1["schema"] == schema and &1["name"] == table)),
            do: throw({:rpc, -32002, "Table resource does not exist or is not accessible"})

          context.adapter.columns(context, schema, table)
          |> rows()
          |> Redact.filter_columns(context.config)
      end

    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => "application/json",
          "text" => Jason.encode!(Redact.normalize(payload))
        }
      ]
    }
  end

  defp dispatch("resources/read", _, _), do: raise(ArgumentError, "uri must be a string")
  defp dispatch(_, _, _), do: throw({:rpc, -32601, "Method not found"})

  defp query_payload(context, sql, values, policy) do
    Diagnostics.count(context, "queries_" <> to_string(policy.mode))

    result =
      Diagnostics.step(context, "database_failures", fn ->
        execute!(context, sql, values, policy.mode)
      end)

    Diagnostics.step(context, "processing_failures", fn ->
      rows = rows(result)

      rows =
        if policy.introspection == :columns and context.config.pii and
             not context.config.pii_introspection,
           do: Redact.filter_introspection(rows, context.config),
           else: rows

      payload =
        if is_nil(result.columns),
          do: %{"affectedRows" => result.num_rows, "insertId" => Map.get(result, :last_insert_id)},
          else: rows

      payload |> Redact.apply(context.config) |> Jason.encode!()
    end)
  end

  def execute!(context, sql, params, mode) do
    execute = fn ->
      case context.adapter.execute(context, sql, params, mode) do
        {:ok, result} -> result
        {:error, error} when is_exception(error) -> raise error
        {:error, _} -> raise RuntimeError, "Database operation failed"
      end
    end

    if mode == :read, do: execute.(), else: Cache.with_write(context, execute)
  end

  def rows(%{columns: nil}), do: []

  def rows(%{columns: columns, rows: rows}),
    do: Enum.map(rows || [], &Map.new(Enum.zip(columns, &1)))

  defp tables(context), do: context.adapter.tables(context) |> rows()

  defp table_uri(config, schema, table),
    do:
      config.scheme <>
        "://tables/" <>
        URI.encode(schema, &URI.char_unreserved?/1) <>
        "/" <> URI.encode(table, &URI.char_unreserved?/1)

  defp text(value), do: %{"type" => "text", "text" => value}

  defp safe_error(%ArgumentError{} = error, _), do: Exception.message(error)

  defp safe_error(error, config) do
    # Database errors can contain SQL, passwords or failed-row values; return only the code.
    code = Map.get(error, :postgres, %{}) || %{}
    code = Map.get(code, :code) || Map.get(error, :mysql, %{}) |> database_code()
    message = "Database operation failed" <> if(code, do: " (#{code})", else: "")
    Redact.apply(message, config)
  end

  defp database_code(value) when is_map(value), do: Map.get(value, :code)
  defp database_code(value), do: value
end
