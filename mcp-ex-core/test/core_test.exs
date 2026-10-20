defmodule McpEx.TestAdapter do
  def execute(_, "SELECT 1", _, mode) do
    send(self(), {:executed, mode})
    {:ok, %{columns: ["value"], rows: [[1]], num_rows: 1}}
  end

  def execute(_, _, _, _), do: {:error, RuntimeError.exception("password=do-not-expose")}

  def tables(_),
    do: %{
      columns: ["schema", "name"],
      rows: [["app", "users"], ["app", "odd / table"]],
      num_rows: 2
    }

  def columns(_, "app", "users"),
    do: %{
      columns: ["column_name", "data_type"],
      rows: [["id", "int"], ["email", "text"]],
      num_rows: 2
    }
end

defmodule McpEx.CoreTest do
  use ExUnit.Case, async: true
  alias McpEx.{Config, Policy, Redact, Server}
  defp config(extra \\ %{}), do: Config.load(:mysql, Map.merge(%{"MYSQL_DB" => "app"}, extra))
  defp context(config \\ config()), do: %{config: config, adapter: McpEx.TestAdapter, pool: nil}

  defp request(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params}

  test "read policy, literals, comments and unsupported SQL" do
    assert Config.read_only?(config())
    assert Policy.check("SELECT 'a;b', ?; -- comment", config()).mode == :read
    assert Policy.check("/* lead */ WITH x AS (SELECT 1) SELECT 1", config()).mode == :read

    for sql <- [
          "DELETE FROM users",
          "SET sql_mode = ''",
          "USE other",
          "CALL proc()",
          "SELECT 1; DELETE FROM users",
          "SELECT 1 /*!; DROP TABLE users */",
          "SELECT 'unterminated",
          "/* incomplete",
          "SELECT @session",
          "SELECT 1 INTO OUTFILE '/tmp/leak'"
        ] do
      assert_raise ArgumentError, fn -> Policy.check(sql, config()) end
    end
  end

  test "file SQL rejects quoted identifiers while preserving string values" do
    for name <- ["LOAD_FILE", "load_file", "LoAd_FiLe", "OUTFILE", "DUMPFILE"] do
      for sql <- ["SELECT #{name}(?)", "SELECT `#{name}`(?)", "SELECT app.`#{name}`(?)"] do
        assert_raise ArgumentError, "File access SQL is disabled", fn ->
          Policy.check(sql, config())
        end
      end

      assert Policy.check("SELECT '#{name}' AS label", config()).mode == :read
    end

    assert Policy.check("SELECT 'LOAD_FILE' AS label WHERE ? = ?", config()).mode == :read
  end

  test "writes reject extra target qualification for both dialects" do
    operations = Map.new(~w(INSERT UPDATE DELETE DDL), &{"ALLOW_#{&1}_OPERATION", "true"})

    for {dialect, target} <- [
          {:pg, "mcp_test.locked.users"},
          {:pg, ~s("mcp_test"."locked"."users")},
          {:pg, ~s(mcp_test /* comment */ . "locked" . users)},
          {:mysql, "app.locked.users"},
          {:mysql, "`app`.`locked`.`users`"}
        ] do
      cfg = Config.load(dialect, Map.put(operations, "MYSQL_DB", "app"))

      for sql <- [
            "ALTER TABLE #{target} ADD COLUMN audit_probe integer",
            "INSERT INTO #{target} (id) VALUES (1)",
            "UPDATE #{target} SET id = 1",
            "DELETE FROM #{target}",
            "CREATE TABLE #{target} (id integer)",
            "DROP TABLE #{target}",
            "TRUNCATE TABLE #{target}"
          ] do
        assert_raise ArgumentError, "Write targets must use table or schema.table", fn ->
          Policy.check(sql, cfg)
        end
      end

      assert Policy.check("ALTER TABLE users ADD COLUMN audit_probe integer", cfg).mode == :ddl

      assert Policy.check("ALTER TABLE allowed.users ADD COLUMN audit_probe integer", cfg).schema ==
               "allowed"
    end
  end

  test "schema overrides, qualified targets and multi mode" do
    cfg =
      config(%{"ALLOW_INSERT_OPERATION" => "true", "SCHEMA_INSERT_PERMISSIONS" => "locked:false"})

    assert Policy.check("INSERT INTO app.users (id) VALUES (1)", cfg).mode == :write

    assert_raise ArgumentError, fn ->
      Policy.check("INSERT/**/INTO `locked`.`users` (id) VALUES (1)", cfg)
    end

    cfg = config(%{"SCHEMA_INSERT_PERMISSIONS" => "app:true"})
    refute Config.read_only?(cfg)
    assert Policy.check("INSERT INTO users (id) VALUES (1)", cfg).schema == "app"
    multi = Config.load(:mysql, %{"ALLOW_INSERT_OPERATION" => "true"})
    assert Config.read_only?(multi)
    assert_raise ArgumentError, fn -> Policy.check("INSERT INTO app.users VALUES (1)", multi) end

    assert Policy.check("INSERT INTO app.users VALUES (1)", %{multi | multi_write: true}).mode ==
             :write
  end

  test "ambiguous writes and cross-schema DDL are refused, upsert checks update permission" do
    cfg = config(Map.new(~w(INSERT UPDATE DELETE DDL), &{"ALLOW_#{&1}_OPERATION", "true"}))

    for sql <- [
          "UPDATE app.users JOIN locked.users ON 1 SET id=1",
          "DELETE FROM users USING locked.users",
          "INSERT INTO users SELECT 1",
          "ALTER TABLE users RENAME TO locked.users",
          "CREATE TABLE users AS SELECT * FROM locked.users",
          "CREATE TABLE users (id int REFERENCES locked.users(id))",
          "DROP TABLE users, locked.users",
          "TRUNCATE users CASCADE",
          "ALTER TABLE users SET SCHEMA locked"
        ] do
      assert_raise ArgumentError, fn -> Policy.check(sql, cfg) end
    end

    assert Policy.check("CREATE TABLE IF NOT EXISTS users (id int)", cfg).mode == :ddl

    assert Policy.check("INSERT INTO users (id) VALUES (1) ON DUPLICATE KEY UPDATE id=1", cfg).mode ==
             :write

    assert_raise ArgumentError, fn ->
      Policy.check(
        "INSERT INTO users VALUES (1) ON DUPLICATE KEY UPDATE id=1",
        config(%{"ALLOW_INSERT_OPERATION" => "true"})
      )
    end

    pg =
      Config.load(:pg, %{
        "SCHEMA_UPDATE_PERMISSIONS" => "locked:false",
        "ALLOW_UPDATE_OPERATION" => "true"
      })

    assert_raise ArgumentError, fn -> Policy.check("UPDATE LOCKED.users SET id=1", pg) end

    assert_raise ArgumentError, fn ->
      Policy.check("INSERT INTO ONLY locked.users (id) VALUES (1)", %{
        pg
        | allow: Map.put(pg.allow, "insert", true)
      })
    end

    assert_raise ArgumentError, fn ->
      Policy.check(
        "CrEaTe TaBlE If NoT ExIsTs locked.users (id int)",
        config(%{"ALLOW_DDL_OPERATION" => "true", "SCHEMA_DDL_PERMISSIONS" => "locked:false"})
      )
    end

    assert_raise ArgumentError, fn ->
      Policy.check(
        "UPDATE LOCKED.users SET id=1",
        config(%{
          "ALLOW_UPDATE_OPERATION" => "true",
          "SCHEMA_UPDATE_PERMISSIONS" => "locked:false"
        })
      )
    end
  end

  test "PII references, nested wildcards and introspection" do
    cfg = config(%{"ENABLE_PII_REDACTION" => "true"})

    for sql <- [
          "SELECT * FROM users",
          "SELECT t.* FROM users t",
          "SELECT id FROM (SELECT * FROM users) t",
          "SELECT email AS safe FROM users",
          "SELECT id FROM users WHERE phone IS NULL",
          "SELECT column_name FROM information_schema.columns",
          "SHOW CREATE TABLE users"
        ] do
      assert_raise ArgumentError, fn -> Policy.check(sql, cfg) end
    end

    assert Policy.check("SELECT COUNT(*) FROM users", cfg).mode == :read
    assert Policy.check("SELECT 'email' AS label", cfg).mode == :read
    assert Policy.check("SHOW COLUMNS FROM users", cfg).introspection == :columns

    assert_raise ArgumentError, fn ->
      Policy.check("SHOW TABLES", %{cfg | pii_block_introspection: true})
    end

    assert Policy.check("SELECT * FROM users", %{cfg | pii_star: true}).mode == :read
  end

  test "PostgreSQL dollar quotes and identifier normalization" do
    pg = Config.load(:pg, %{})
    assert Policy.check("SELECT $tag$a;b$tag$, $1", pg).mode == :read
    assert Policy.check("SELECT $$secret;$$", pg).mode == :read

    for sql <- [
          "SELECT $tag$unterminated",
          "SELECT $$value$$; DELETE FROM users",
          "SELECT `id` FROM users"
        ] do
      assert_raise ArgumentError, fn -> Policy.check(sql, pg) end
    end
  end

  test "recursive masking, numeric PII, JSON and precision" do
    cfg =
      config(%{
        "ENABLE_PII_REDACTION" => "true",
        "PII_EXTRA_COLUMNS" => "badge",
        "PII_EXTRA_COLUMN_PATTERNS" => "^private_"
      })

    value = %{
      "email" => "john@example.com",
      "ssn" => 123_456_789,
      "note" => "john@example.com 4111111111111111",
      "badge" => "xyz",
      "private_data" => ["xyz"],
      "audit" => ~s({"phone":"214-555-1212"}),
      "id" => 9_223_372_036_854_775_000
    }

    result = Redact.apply(value, cfg)
    assert result["email"] == "j***@e***.com"
    assert result["ssn"] == "***"
    assert result["note"] == "j***@e***.com ****-****-****-1111"
    assert result["badge"] == "***"
    assert result["private_data"] == ["***"]
    assert Jason.decode!(result["audit"])["phone"] == "***-***-1212"
    assert result["id"] == "9223372036854775000"
    assert Redact.normalize(Decimal.new("123.450")) == "123.450"
    assert Redact.normalize(<<255>>) == %{"base64" => "/w=="}
  end

  test "configuration validates permissions, flags, ports, regex and TLS" do
    for extra <- [
          %{"MYSQL_PORT" => "zero"},
          %{"MYSQL_PORT" => "65536"},
          %{"ALLOW_INSERT_OPERATION" => "yes"},
          %{"SCHEMA_INSERT_PERMISSIONS" => "app"},
          %{"MYSQL_SSL_CERT" => "missing"},
          %{"IS_REMOTE_MCP" => "true"}
        ] do
      assert_raise ArgumentError, fn -> config(extra) end
    end

    assert_raise Regex.CompileError, fn -> config(%{"PII_EXTRA_COLUMN_PATTERNS" => "["}) end
    cfg = config(%{"MYSQL_CONNECTION_STRING" => "mysql://user:p%40ss@db:3307/example"})
    assert cfg.connection[:password] == "p@ss"
    assert cfg.schema == "example"
  end

  test "initialization, notifications, request ids and safe errors" do
    ctx = context()
    {response, :new} = Server.handle(request("tools/list"), ctx, :new)
    assert response["error"]["code"] == -32000

    {response, :initializing} =
      Server.handle(
        request("initialize", %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }),
        ctx,
        :new
      )

    assert response["result"]["protocolVersion"] == "2025-06-18"

    assert {nil, :ready} =
             Server.handle(
               %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
               ctx,
               :initializing
             )

    {response, _} =
      Server.handle(
        request("tools/call", %{"name" => "mysql_query", "arguments" => %{"sql" => "SELECT 1"}}),
        ctx
      )

    assert_receive {:executed, :read}
    refute response["result"]["isError"]
    assert response["id"] == 7

    {response, _} =
      Server.handle(
        request("tools/call", %{"name" => "mysql_query", "arguments" => %{"sql" => "SELECT 2"}}),
        ctx
      )

    assert response["result"]["isError"]
    refute inspect(response) =~ "do-not-expose"

    for message <- [
          [],
          %{},
          %{"jsonrpc" => "1.0", "method" => "ping"},
          Map.put(request("ping"), "id", nil)
        ] do
      {response, _} = Server.handle(message, ctx)
      assert response["error"]["code"] == -32600
    end
  end

  test "session limits and deadlines reject invalid configuration" do
    for key <-
          ~w(MCP_MAX_RESPONSE_BYTES MCP_MAX_SESSIONS MCP_MAX_INFLIGHT MCP_SESSION_IDLE_TIMEOUT MCP_REQUEST_TIMEOUT),
        value <- ["0", "-1", "bad", "2147483648"] do
      assert_raise ArgumentError, fn -> config(%{key => value}) end
    end

    assert config(%{"MYSQL_QUERY_TIMEOUT" => "500"}).request_timeout == 1500
    assert config(%{"MYSQL_QUERY_TIMEOUT" => "2147483647"}).request_timeout == 2_147_483_647
  end

  test "schema-qualified URIs, root contents and PII schema filtering" do
    ctx = context(config(%{"ENABLE_PII_REDACTION" => "true"}))
    {response, _} = Server.handle(request("resources/list"), ctx)
    uris = Enum.map(response["result"]["resources"], & &1["uri"])
    assert "mysql://tables/app/users" in uris
    assert "mysql://tables/app/odd%20%2F%20table" in uris
    {response, _} = Server.handle(request("resources/read", %{"uri" => "mysql://tables"}), ctx)
    assert length(Jason.decode!(hd(response["result"]["contents"])["text"])) == 2

    {response, _} =
      Server.handle(request("resources/read", %{"uri" => "mysql://tables/app/users"}), ctx)

    assert Jason.decode!(hd(response["result"]["contents"])["text"]) == [
             %{"column_name" => "id", "data_type" => "int"}
           ]

    {response, _} =
      Server.handle(request("resources/read", %{"uri" => "mysql://tables/missing/users"}), ctx)

    assert response["error"]["code"] == -32002
  end

  test "HTTP exact authentication, origin, protocol, request size and media types" do
    ctx = context(%{config() | secret: "test-token", max_bytes: 1000})

    base = fn ->
      Plug.Test.conn(:post, "/mcp", Jason.encode!(request("ping")))
      |> Plug.Conn.put_req_header("authorization", "Bearer test-token")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("content-type", "application/json")
    end

    assert McpEx.HTTP.call(base.(), ctx).status == 400

    for token <- ["Bearer prefix-test-token", "Bearer token", "Basic test-token"] do
      assert base.()
             |> Plug.Conn.put_req_header("authorization", token)
             |> McpEx.HTTP.call(ctx)
             |> Map.fetch!(:status) == 401
    end

    assert base.()
           |> Plug.Conn.put_req_header("origin", "https://evil.test")
           |> McpEx.HTTP.call(ctx)
           |> Map.fetch!(:status) == 403

    assert base.()
           |> Plug.Conn.put_req_header("mcp-protocol-version", "unknown")
           |> McpEx.HTTP.call(ctx)
           |> Map.fetch!(:status) == 400

    assert base.()
           |> Plug.Conn.put_req_header("accept", "text/html")
           |> McpEx.HTTP.call(ctx)
           |> Map.fetch!(:status) == 406

    assert McpEx.HTTP.call(base.(), %{ctx | config: %{ctx.config | max_bytes: 1}}).status == 413
  end
end
