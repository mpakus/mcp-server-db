defmodule McpEx.MysqlTest do
  use ExUnit.Case
  alias McpEx.{Config, Server}

  test "MySQL configuration and adapter identity" do
    assert McpEx.Mysql.dialect() == :mysql
    assert Config.load(:mysql, %{}).tool == "mysql_query"
  end

  @tag :integration
  test "real MySQL reads, native read-only enforcement, writes, rollback, metadata and masking" do
    env = %{
      "MYSQL_HOST" => "127.0.0.1",
      "MYSQL_PORT" => System.get_env("MCP_TEST_MYSQL_PORT", "13307"),
      "MYSQL_USER" => "mcp_test",
      "MYSQL_PASS" => "mcp_test_password",
      "MYSQL_DB" => "mcp_test",
      "MYSQL_POOL_SIZE" => "1"
    }

    config = Config.load(:mysql, env)
    pool = start_supervised!({MyXQL, config.connection})
    ctx = %{pool: pool, config: config, adapter: McpEx.Mysql}

    assert query(ctx, "SELECT id, balance, big_id, created_at FROM users WHERE id = ?", [1])[
             "isError"
           ] == false

    rows = payload(query(ctx, "SELECT balance, big_id, created_at FROM users WHERE id = ?", [1]))
    assert hd(rows)["balance"] == "123.450"
    assert hd(rows)["big_id"] == "9223372036854775000"
    assert hd(rows)["created_at"] == "2026-09-30T12:30:00"
    assert query(ctx, "SELECT mutate_count()")["isError"]
    assert payload(query(ctx, "SELECT label FROM users WHERE id=1")) == [%{"label" => "sample"}]
    assert query(ctx, "INSERT INTO users (id,label) VALUES (99,'test')")["isError"]

    writable = %{
      ctx
      | config:
          Config.load(
            :mysql,
            Map.merge(env, %{
              "ALLOW_INSERT_OPERATION" => "true",
              "ALLOW_UPDATE_OPERATION" => "true",
              "ALLOW_DELETE_OPERATION" => "true",
              "ALLOW_DDL_OPERATION" => "true",
              "SCHEMA_UPDATE_PERMISSIONS" => "mcp_locked:false"
            })
          )
    }

    assert payload(query(writable, "INSERT INTO users (id,label) VALUES (?,?)", [99, "test"]))[
             "affectedRows"
           ] == 1

    assert query(writable, "INSERT INTO users (id,label) VALUES (99,'duplicate')")["isError"]
    refute query(writable, "UPDATE users SET label=? WHERE id=?", ["updated", 99])["isError"]
    assert query(writable, "UPDATE mcp_locked.users SET label='denied' WHERE id=1")["isError"]
    refute query(writable, "DELETE FROM users WHERE id=?", [99])["isError"]
    refute query(writable, "CREATE TABLE mcp_ddl_check (id INT)")["isError"]
    refute query(writable, "DROP TABLE mcp_ddl_check")["isError"]

    pii = %{
      ctx
      | config:
          Config.load(
            :mysql,
            Map.merge(env, %{"ENABLE_PII_REDACTION" => "true", "PII_ALLOW_REFERENCES" => "true"})
          )
    }

    assert hd(payload(query(pii, "SELECT email FROM users WHERE id=1")))["email"] ==
             "j***@e***.com"

    assert query(pii, "SELECT * FROM users")["isError"]
    fields = payload(query(pii, "SHOW COLUMNS FROM users"))
    refute Enum.any?(fields, &(&1["Field"] == "email"))
    assert length(Server.rows(McpEx.Mysql.tables(ctx))) >= 1

    assert Enum.any?(
             Server.rows(McpEx.Mysql.columns(ctx, "mcp_test", "users")),
             &(&1["column_name"] == "email")
           )

    multi_config = Config.load(:mysql, Map.delete(env, "MYSQL_DB"))
    multi_pool = start_supervised!({MyXQL, multi_config.connection}, id: :multi)
    multi = %{ctx | config: multi_config, pool: multi_pool}
    tables = Server.rows(McpEx.Mysql.tables(multi))
    assert Enum.any?(tables, &(&1["schema"] == "mcp_test" and &1["name"] == "users"))
    assert Enum.any?(tables, &(&1["schema"] == "mcp_locked" and &1["name"] == "users"))
  end

  defp query(ctx, sql, values \\ []) do
    {response, _} =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "mysql_query",
            "arguments" => %{"sql" => sql, "params" => values}
          }
        },
        ctx
      )

    response["result"]
  end

  defp payload(result), do: Jason.decode!(hd(result["content"])["text"])
end
