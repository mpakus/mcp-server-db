defmodule McpEx.DiagnosticsAdapter do
  def execute(_, "SELECT 1", _, _), do: {:ok, %{columns: ["value"], rows: [[1]], num_rows: 1}}

  def execute(_, "SELECT broken_processing", _, _),
    do: {:ok, %{columns: ["value"], rows: [:bad], num_rows: 1}}

  def execute(_, _, _, _), do: {:error, RuntimeError.exception("sensitive-db-error")}

  def tables(%{pool: :many}),
    do: %{columns: ["schema", "name"], rows: for(n <- 1..250, do: ["app", "table#{n}"])}

  def tables(_), do: %{columns: ["schema", "name"], rows: [["app", "users\e[31m"]]}
  def pool_metrics(%{pool: :hung}), do: Process.sleep(:infinity)
  def pool_metrics(_), do: [%{ready_conn_count: 2, checkout_queue_length: 0}]
end

defmodule McpEx.DiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias McpEx.{Config, Diagnostics, Monitor, Server}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-dashboard-#{System.unique_integer([:positive])}")

    config =
      Config.load(:mysql, %{
        "MYSQL_DB" => "app",
        "MYSQL_PASS" => "private-password",
        "REMOTE_SECRET_KEY" => "private-token",
        "MCP_DASHBOARD" => "true",
        "MCP_DASHBOARD_DIR" => dir
      })

    context = %{config: config, adapter: McpEx.DiagnosticsAdapter, pool: nil}
    old_dir = System.get_env("MCP_DASHBOARD_DIR")
    System.put_env("MCP_DASHBOARD_DIR", dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if old_dir,
        do: System.put_env("MCP_DASHBOARD_DIR", old_dir),
        else: System.delete_env("MCP_DASHBOARD_DIR")
    end)

    %{dir: dir, context: context}
  end

  defp start(context, opts \\ []) do
    handle = Diagnostics.start(context, Keyword.merge([interval: 20], opts))
    on_exit(fn -> Diagnostics.stop(handle) end)
    Map.put(context, :diagnostics, handle)
  end

  defp snapshot(dir, predicate \\ fn _ -> true end, tries \\ 100) do
    case Diagnostics.snapshots(dir) do
      {:ok, [s]} -> if predicate.(s), do: s, else: again(dir, predicate, tries)
      _ -> again(dir, predicate, tries)
    end
  end

  defp again(_, _, 0), do: flunk("snapshot was not published")

  defp again(dir, predicate, tries) do
    Process.sleep(20)
    snapshot(dir, predicate, tries - 1)
  end

  defp request(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp tool(context, args),
    do:
      Server.handle(
        request("tools/call", %{"name" => "mysql_query", "arguments" => args}),
        context
      )

  test "disabled diagnostics performs no filesystem work", %{context: context, dir: dir} do
    assert Diagnostics.start(%{context | config: %{context.config | dashboard: false}}) == nil
    refute File.exists?(dir)

    assert Diagnostics.directory(%{"XDG_STATE_HOME" => "", "MCP_DASHBOARD_DIR" => ""}) ==
             Path.join(System.user_home!(), ".local/state/mcp-ex")

    assert Diagnostics.directory(%{"XDG_STATE_HOME" => "/tmp/state"}) == "/tmp/state/mcp-ex"
    assert Diagnostics.count(context, "requests") == :ok
  end

  test "counters distinguish tool, RPC and policy outcomes without retaining data", %{
    context: context,
    dir: dir
  } do
    ctx = start(context)
    tool(ctx, %{"sql" => "SELECT 1", "params" => ["private-parameter"]})
    tool(ctx, nil)
    tool(ctx, %{"sql" => "DELETE FROM users"})
    tool(ctx, %{"sql" => "SELECT sensitive_query"})
    tool(ctx, %{"sql" => "SELECT broken_processing"})
    Server.handle(request("unknown-private-method"), ctx)
    Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, ctx)
    Server.handle(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}, ctx)
    s = snapshot(dir, &(&1["counters"]["tools"] == 5))
    c = s["counters"]
    assert c["requests"] == 6
    assert c["notifications"] == 1
    assert c["rpc_errors"] == 1
    assert c["tool_success"] == 1
    assert c["tool_failed"] == 4

    assert Enum.map(
             ~w(validation_errors policy_rejections database_failures processing_failures),
             &c[&1]
           ) == [1, 1, 1, 1]

    assert c["queries_read"] == 3
    assert c["tool_max_us"] > 0
    assert c["method.other"] == 1
    data = Jason.encode!(s)

    for secret <-
          ~w(private-password private-token private-parameter sensitive_query sensitive-db-error unknown-private-method) do
      refute data =~ secret
    end

    assert s["database"]["pii"] == false
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700

    assert File.stat!(Path.join(dir, s["instance_id"] <> ".json")).mode |> Bitwise.band(0o777) ==
             0o600

    assert s["resources"]["items"]
           |> Enum.any?(&(&1["uri"] == "mysql://tables/app/users%1B%5B31m"))

    rendered =
      Monitor.render("status", [
        hd(elem(Monitor.inspect_instances(dir, :mysql), 1)) |> Map.put("queries_per_second", nil)
      ])

    refute rendered =~ "\e"
    assert rendered =~ "users?[31m"
  end

  test "hung pool sampling cannot stop heartbeat or MCP and collector loss is harmless", %{
    context: context,
    dir: dir
  } do
    ctx = start(%{context | pool: :hung})
    first = snapshot(dir)
    later = snapshot(dir, &(&1["pool"]["status"] == "timeout"))
    assert later["sequence"] > first["sequence"]
    {response, _} = tool(ctx, %{"sql" => "SELECT 1"})
    assert response["result"]["isError"] == false
    Process.exit(ctx.diagnostics.pid, :kill)
    {response, _} = tool(ctx, %{"sql" => "SELECT 1"})
    assert response["result"]["isError"] == false
    :ets.delete(ctx.diagnostics.table)
    assert Server.handle(request("ping"), ctx) |> elem(0) |> Map.fetch!("result") == %{}
  end

  test "resources are capped, instances isolated and normal stop removes only its file", %{
    context: context,
    dir: dir
  } do
    first = start(%{context | pool: :many})
    s = snapshot(dir, &(&1["resources"]["status"] == "ok"))
    assert s["resources"]["total"] == 251
    assert length(s["resources"]["items"]) == 200
    assert s["resources"]["truncated"]
    second = start(context)
    Process.sleep(60)
    {:ok, instances} = Diagnostics.snapshots(dir)
    assert length(instances) == 2
    assert Enum.uniq_by(instances, & &1["instance_id"]) == instances

    assert capture_io(:stderr, fn -> assert Monitor.run("resources", [], :mysql) == 2 end) =~
             "Several instances"

    Diagnostics.stop(first.diagnostics)
    assert {:ok, [_]} = Diagnostics.snapshots(dir)
    Diagnostics.stop(second.diagnostics)
    assert {:ok, []} = Diagnostics.snapshots(dir)
  end

  test "unsafe directories and snapshot files fail closed", %{context: context, dir: dir} do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o755)
    assert capture_io(:stderr, fn -> assert Diagnostics.start(context) == nil end) =~ "private"
    assert {:error, :unsafe_permissions} = Diagnostics.snapshots(dir)
    File.chmod!(dir, 0o700)
    ctx = start(context, sampling: false)
    s = snapshot(dir)
    path = Path.join(dir, s["instance_id"] <> ".json")
    Diagnostics.stop(ctx.diagnostics)
    File.write!(path, "{}")
    File.chmod!(path, 0o600)
    assert {:error, :invalid_snapshot} = Diagnostics.snapshots(dir)
    File.rm!(path)
    File.ln_s!("/etc/passwd", path)
    assert {:error, :unsafe_permissions} = Diagnostics.snapshots(dir)
    File.rm!(path)
    File.write!(path, String.duplicate("x", 1_048_577))
    File.chmod!(path, 0o600)
    assert {:error, :too_large} = Diagnostics.snapshots(dir)
  end

  test "HTTP counters include transport rejections without inventing RPC calls", %{
    context: context,
    dir: dir
  } do
    ctx = start(%{context | config: %{context.config | secret: "private-token", max_bytes: 50}})
    assert McpEx.HTTP.call(Plug.Test.conn(:get, "/mcp"), ctx).status == 401

    conn = fn body ->
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer private-token")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("content-type", "application/json")
    end

    assert McpEx.HTTP.call(conn.("bad-json"), ctx).status == 400
    assert McpEx.HTTP.call(conn.(String.duplicate("x", 100)), ctx).status == 413
    s = snapshot(dir, &(&1["counters"]["http.413"] == 1))
    assert s["counters"]["requests"] == 0
    assert s["counters"]["parse_errors"] == 1
    assert s["counters"]["oversize_errors"] == 1
    assert s["counters"]["http.401"] == 1
  end

  test "storage failure leaves MCP working and publication recovers", %{
    context: context,
    dir: dir
  } do
    assert capture_io(:stderr, fn ->
             ctx = start(context, sampling: false)
             before = snapshot(dir)
             File.chmod!(dir, 0o755)
             Process.sleep(60)
             assert Server.handle(request("ping"), ctx) |> elem(0) |> Map.fetch!("result") == %{}
             File.chmod!(dir, 0o700)
             after_failure = snapshot(dir, &(&1["sequence"] > before["sequence"] + 1))
             assert after_failure["counters"]["requests"] == 1
           end) =~ "snapshot unavailable"
  end

  test "viewer marks stale, future and expired health samples and does not load database config",
       %{context: context, dir: dir} do
    ctx = start(context, sampling: false)
    s = snapshot(dir)
    now = s["updated_at"]
    {:ok, [fresh]} = Monitor.inspect_instances(dir, :mysql, nil, now)
    assert fresh["state"] == "healthy"
    {:ok, [stale]} = Monitor.inspect_instances(dir, :mysql, nil, now + 10_001)
    assert stale["state"] == "stale"
    {:ok, [future]} = Monitor.inspect_instances(dir, :mysql, nil, now - 1)
    assert future["state"] == "unknown"
    assert {:ok, []} = Monitor.inspect_instances(dir, :pg)
    Diagnostics.stop(ctx.diagnostics)
    expired = s |> Map.put("updated_at", now + 100_000)
    path = Path.join(dir, s["instance_id"] <> ".json")
    File.write!(path, Jason.encode!(expired))
    File.chmod!(path, 0o600)
    {:ok, [degraded]} = Monitor.inspect_instances(dir, :mysql, nil, now + 100_000)
    assert degraded["state"] == "degraded"
    File.rm!(path)
    old = System.get_env("MCP_DASHBOARD_DIR")
    System.put_env("MCP_DASHBOARD_DIR", dir)

    on_exit(fn ->
      if old,
        do: System.put_env("MCP_DASHBOARD_DIR", old),
        else: System.delete_env("MCP_DASHBOARD_DIR")
    end)

    assert capture_io(fn -> assert Monitor.run("status", ["--json"], :mysql) == 1 end)
           |> Jason.decode!() == %{"schema_version" => 1, "instances" => []}

    assert capture_io(:stderr, fn -> assert Monitor.run("status", ["--unknown"], :mysql) == 2 end) =~
             "Use status"
  end
end
