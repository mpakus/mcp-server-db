defmodule McpEx.Mysql do
  @moduledoc "MyXQL pool, transaction enforcement and MySQL metadata queries."
  def dialect, do: :mysql
  def start_link(config), do: MyXQL.start_link(config.connection)

  def pool_metrics(context), do: DBConnection.get_connection_metrics(context.pool)

  def execute(context, sql, values, :ddl) do
    # MySQL DDL implicitly commits; no transaction wrapper can make it rollback-safe.
    MyXQL.query(context.pool, sql, values, timeout: context.config.timeout)
  end

  def execute(context, sql, values, mode) do
    timeout = context.config.timeout

    DBConnection.run(
      context.pool,
      fn conn ->
        if mode == :read,
          do:
            MyXQL.query!(conn, "SET TRANSACTION READ ONLY", [],
              query_type: :text,
              timeout: timeout
            )

        result =
          MyXQL.transaction(
            conn,
            fn tx ->
              result = MyXQL.query!(tx, sql, values, timeout: timeout)
              finish_query(tx, result, mode)
            end,
            timeout: timeout
          )

        case result do
          {:error, {:read_result, result}} -> {:ok, result}
          result -> result
        end
      end,
      timeout: timeout
    )
  rescue
    error -> {:error, error}
  end

  defp finish_query(tx, result, :read), do: MyXQL.rollback(tx, {:read_result, result})
  defp finish_query(_, result, _), do: result

  def tables(context) do
    database = context.config.schema
    filter = if database, do: "AND table_schema = ?", else: ""

    McpEx.Server.execute!(
      context,
      """
      SELECT table_schema AS `schema`, table_name AS name, table_type AS type,
             table_rows AS row_count, data_length AS data_size, index_length AS index_size
      FROM information_schema.tables
      WHERE table_schema NOT IN ('information_schema','mysql','performance_schema','sys') #{filter}
      ORDER BY table_schema, table_name
      """,
      if(database, do: [database], else: []),
      :read
    )
  end

  def columns(context, schema, table) do
    McpEx.Server.execute!(
      context,
      """
      SELECT column_name AS column_name, data_type AS data_type, is_nullable AS is_nullable,
           column_default AS column_default, column_key AS column_key
      FROM information_schema.columns
      WHERE table_schema = ? AND table_name = ?
      ORDER BY ordinal_position
      """,
      [schema, table],
      :read
    )
  end
end

defmodule McpEx.Mysql.CLI do
  @moduledoc "MySQL MCP escript entry point."
  def main(args), do: McpEx.CLI.main(args, McpEx.Mysql)
end
