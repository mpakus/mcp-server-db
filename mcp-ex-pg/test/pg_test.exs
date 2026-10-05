defmodule McpEx.PgTest do
  use ExUnit.Case
  alias McpEx.{Config, Server}

  test "PostgreSQL configuration and adapter identity" do
    assert McpEx.Pg.dialect() == :pg
    assert Config.load(:pg, %{}).tool == "pg_query"
  end

  @tag :integration
  test "real PostgreSQL reads, native read-only enforcement, CTEs, writes, rollback and returning redaction" do
    env = %{
      "PG_HOST" => "127.0.0.1",
      "PG_PORT" => System.get_env("MCP_TEST_PG_PORT", "15433"),
      "PG_USER" => "mcp_test",
      "PG_PASS" => "mcp_test_password",
      "PG_DB" => "mcp_test",
      "PG_POOL_SIZE" => "1"
    }

    config = Config.load(:pg, env)
    pool = start_supervised!(%{id: McpEx.Pg, start: {McpEx.Pg, :start_link, [config]}})
    ctx = %{pool: pool, config: config, adapter: McpEx.Pg}
    rows = payload(query(ctx, "SELECT balance, big_id, created_at FROM users WHERE id=$1", [1]))
    assert hd(rows)["balance"] == "123.450"
    assert hd(rows)["big_id"] == "9223372036854775000"
    assert hd(rows)["created_at"] == "2026-09-30T12:30:00.000000"
    assert query(ctx, "SELECT mutate_count()")["isError"]

    assert query(
             ctx,
             "WITH changed AS (UPDATE users SET label='oops' RETURNING id) SELECT id FROM changed"
           )["isError"]

    assert query(ctx, "EXPLAIN ANALYZE UPDATE users SET label='oops'")["isError"]
    assert payload(query(ctx, "SELECT label FROM users WHERE id=1")) == [%{"label" => "sample"}]
    assert query(ctx, "INSERT INTO users (id,label) VALUES (99,'test')")["isError"]

    writable = %{
      ctx
      | config:
          Config.load(
            :pg,
            Map.merge(env, %{
              "ALLOW_INSERT_OPERATION" => "true",
              "ALLOW_UPDATE_OPERATION" => "true",
              "ALLOW_DELETE_OPERATION" => "true",
              "ALLOW_DDL_OPERATION" => "true",
              "SCHEMA_UPDATE_PERMISSIONS" => "locked:false",
              "ENABLE_PII_REDACTION" => "true",
              "PII_ALLOW_REFERENCES" => "true"
            })
          )
    }

    refute query(writable, "INSERT INTO users (id,label,email) VALUES ($1,$2,$3)", [
             99,
             "test",
             "john@example.com"
           ])["isError"]

    assert query(writable, "INSERT INTO users (id,label) VALUES (99,'duplicate')")["isError"]

    assert hd(
             payload(
               query(writable, "UPDATE users SET label=$1 WHERE id=$2 RETURNING email", [
                 "updated",
                 99
               ])
             )
           )["email"] == "j***@e***.com"

    assert query(writable, "UPDATE locked.users SET label='denied' WHERE id=1")["isError"]
    refute query(writable, "DELETE FROM users WHERE id=$1", [99])["isError"]
    refute query(writable, "CREATE TABLE mcp_ddl_check (id INT)")["isError"]
    refute query(writable, "DROP TABLE mcp_ddl_check")["isError"]

    assert Enum.any?(
             Server.rows(McpEx.Pg.columns(ctx, "public", "users")),
             &(&1["column_name"] == "email")
           )

    multi = %{ctx | config: %{config | schema: nil}}
    tables = Server.rows(McpEx.Pg.tables(multi))
    assert Enum.any?(tables, &(&1["schema"] == "public" and &1["name"] == "users"))
    assert Enum.any?(tables, &(&1["schema"] == "locked" and &1["name"] == "users"))
  end

  defp query(ctx, sql, values \\ []) do
    {response, _} =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "pg_query", "arguments" => %{"sql" => sql, "params" => values}}
        },
        ctx
      )

    response["result"]
  end

  defp payload(result), do: Jason.decode!(hd(result["content"])["text"])
end
