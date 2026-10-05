defmodule McpEx.Pg do
  @moduledoc "Postgrex pool, transaction enforcement and PostgreSQL schema discovery."
  def dialect, do: :pg

  def start_link(config) do
    schema = config.schema
    # Pin unqualified names to exactly one schema, without a fallback to public.
    search_path = if schema, do: "\"" <> String.replace(schema, "\"", "\"\"") <> "\"", else: ""

    config.connection
    |> Keyword.put(:parameters,
      search_path: search_path,
      statement_timeout: to_string(config.timeout)
    )
    |> Keyword.put(:prepare, :unnamed)
    |> Postgrex.start_link()
  end

  def execute(context, sql, values, mode) do
    result =
      Postgrex.transaction(
        context.pool,
        fn conn ->
          if mode == :read, do: Postgrex.query!(conn, "SET TRANSACTION READ ONLY", [])
          result = Postgrex.query!(conn, sql, values, timeout: context.config.timeout)
          if mode == :read, do: Postgrex.rollback(conn, {:read_result, result}), else: result
        end,
        timeout: context.config.timeout
      )

    case result do
      {:error, {:read_result, result}} -> {:ok, result}
      result -> result
    end
  rescue
    error -> {:error, error}
  end

  def tables(context) do
    schema = context.config.schema
    filter = if schema, do: "AND table_schema = $1", else: ""

    McpEx.Server.execute!(
      context,
      """
      SELECT table_schema AS schema, table_name AS name, table_type AS type
      FROM information_schema.tables
      WHERE table_schema NOT IN ('pg_catalog','information_schema')
        AND table_schema NOT LIKE 'pg_toast%' AND table_schema NOT LIKE 'pg_temp_%' #{filter}
      ORDER BY table_schema, table_name
      """,
      if(schema, do: [schema], else: []),
      :read
    )
  end

  def columns(context, schema, table) do
    McpEx.Server.execute!(
      context,
      """
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2
      ORDER BY ordinal_position
      """,
      [schema, table],
      :read
    )
  end
end

defmodule McpEx.Pg.CLI do
  def main(args), do: McpEx.CLI.main(args, McpEx.Pg)
end
