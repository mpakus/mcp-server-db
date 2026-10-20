defmodule McpEx.SessionTest.Adapter do
  def execute(context, "SELECT wait", values, _) do
    send(context.test_owner, {:query_started, self(), values})

    receive do
      :release -> {:ok, %{columns: ["value"], rows: [[1]], num_rows: 1}}
      :crash -> exit(:kill)
    end
  end

  def execute(_, "SELECT large", _, _),
    do: {:ok, %{columns: ["value"], rows: [[String.duplicate("x", 2000)]], num_rows: 1}}
end

defmodule McpEx.SessionTest do
  use ExUnit.Case
  alias McpEx.{Config, HTTP, Server, Session}
  import Plug.Conn

  setup do
    start_supervised!({Registry, keys: :unique, name: __MODULE__.Registry})
    tasks = start_supervised!({Task.Supervisor, max_children: 2})
    sessions = start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 3})
    config = Config.load(:mysql, %{"MYSQL_DB" => "app", "REMOTE_SECRET_KEY" => "secret"})

    context = %{
      config: %{config | max_inflight: 1},
      pool: nil,
      adapter: __MODULE__.Adapter,
      test_owner: self(),
      registry: __MODULE__.Registry,
      tasks: tasks,
      sessions: sessions
    }

    %{context: context}
  end

  defp rpc(method, id \\ 1, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp initialize do
    rpc("initialize", 0, %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "1"}
    })
  end

  defp initialized, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

  defp query(id, sql \\ "SELECT wait"),
    do: rpc("tools/call", id, %{"name" => "mysql_query", "arguments" => %{"sql" => sql}})

  defp ready(context, owner \\ nil) do
    {:ok, id, pid} = Session.open(context, owner)
    {:ok, response} = Session.request(pid, initialize())
    assert Jason.decode!(response)["result"]["protocolVersion"] == "2025-11-25"
    assert {:ok, nil} = Session.request(pid, initialized())
    {id, pid}
  end

  defp response do
    receive do
      {:session_response, {:ok, value}} -> if value, do: Jason.decode!(value)
    after
      1000 -> flunk("No session response")
    end
  end

  test "lifecycle, negotiated version and independent request IDs", %{context: context} do
    {:ok, _, pid} = Session.open(context)
    {:ok, encoded} = Session.request(pid, rpc("tools/list"))
    assert Jason.decode!(encoded)["error"]["code"] == -32000
    {:ok, _} = Session.request(pid, initialize())
    {:ok, encoded} = Session.request(pid, rpc("tools/list"))
    assert Jason.decode!(encoded)["error"]
    assert {:ok, nil} = Session.request(pid, initialized())
    assert {:error, :version} = Session.request(pid, rpc("ping"), "2025-06-18")
    {:ok, encoded} = Session.request(pid, initialize())
    assert Jason.decode!(encoded)["error"]["message"] == "Session already initialized"

    {_, other} = ready(context)
    for session <- [pid, other], do: Session.submit(session, query(1), self())
    assert_receive {:query_started, first, []}
    assert_receive {:query_started, second, []}
    assert first != second
    send(first, :release)
    send(second, :release)
    assert response()["id"] == 1
    assert response()["id"] == 1
  end

  test "slow queries keep ping responsive; duplicate and excess work are rejected", %{
    context: context
  } do
    {_, pid} = ready(context)
    Session.submit(pid, query(1), self())
    assert_receive {:query_started, worker, []}

    {:ok, pong} = Session.request(pid, rpc("ping", 2))
    assert Jason.decode!(pong)["result"] == %{}
    {:ok, duplicate} = Session.request(pid, query(1))
    assert Jason.decode!(duplicate)["error"]["code"] == -32600
    {:ok, busy} = Session.request(pid, query(3))
    assert Jason.decode!(busy)["error"]["message"] =~ "busy"
    send(worker, :release)
    refute response()["result"]["isError"]
  end

  test "global worker and session capacity are bounded", %{context: context} do
    {_, one} = ready(context)
    {_, two} = ready(context)
    {_, three} = ready(context)
    assert {:error, :max_children} = Session.open(context)
    Session.submit(one, query(1), self())
    Session.submit(two, query(1), self())
    assert_receive {:query_started, first, []}
    assert_receive {:query_started, second, []}
    {:ok, encoded} = Session.request(three, query(1))
    assert Jason.decode!(encoded)["error"]["message"] =~ "busy"
    assert length(Task.Supervisor.children(context.tasks)) == 2
    send(first, :release)
    send(second, :release)
    response()
    response()
  end

  test "cancellation frees worker and discards result without affecting another session", %{
    context: context
  } do
    {_, pid} = ready(context)
    {_, other} = ready(context)
    Session.submit(pid, query(7), self())
    assert_receive {:query_started, worker, []}
    monitor = Process.monitor(worker)

    cancel = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => 7}
    }

    assert {:ok, nil} = Session.request(other, cancel)
    assert {:ok, nil} = Session.request(pid, put_in(cancel, ["params", "requestId"], 7.0))
    assert {:ok, nil} = Session.request(pid, %{cancel | "params" => false})
    assert {:ok, nil} = Session.request(pid, %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}})
    assert Process.alive?(worker)
    assert {:ok, nil} = Session.request(pid, cancel)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert response() == nil
    assert {:ok, nil} = Session.request(pid, cancel)
    {:ok, pong} = Session.request(pid, rpc("ping"))
    assert Jason.decode!(pong)["result"] == %{}
  end

  @tag capture_log: true
  test "worker failure and deadline leave session usable", %{context: context} do
    context = %{context | config: %{context.config | request_timeout: 100}}
    {_, pid} = ready(context)
    Session.submit(pid, query(1), self())
    assert_receive {:query_started, worker, []}
    send(worker, :crash)
    assert response()["error"]["message"] == "Request worker failed"

    Session.submit(pid, query(2), self())
    assert_receive {:query_started, worker, []}
    monitor = Process.monitor(worker)
    assert response()["error"]["message"] == "Request timed out"
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    {:ok, pong} = Session.request(pid, rpc("ping"))
    assert Jason.decode!(pong)["result"] == %{}
  end

  test "normal close and untrappable session death clean up workers without restarting sessions",
       %{context: context} do
    for stop <- [:close, :kill] do
      {id, pid} = ready(context)
      Session.submit(pid, query(1), self())
      assert_receive {:query_started, worker, []}
      monitor = Process.monitor(worker)
      session_monitor = Process.monitor(pid)
      if stop == :close, do: Session.close(pid), else: Process.exit(pid, :kill)
      assert_receive {:DOWN, ^session_monitor, :process, ^pid, _}
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
      assert {:error, :closed} = Session.request(pid, rpc("ping"))
      assert {:error, :not_found} = Session.lookup(context, id)
    end
  end

  test "HTTP sessions expire after inactivity but keep active work", %{context: context} do
    context = %{context | config: %{context.config | session_idle_timeout: 30}}
    {_, pid} = ready(context)
    monitor = Process.monitor(pid)
    Session.submit(pid, query(1), self())
    assert_receive {:query_started, worker, []}
    refute_receive {:DOWN, ^monitor, _, _, _}, 60
    send(worker, :release)
    assert response()["result"]
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "stdio drains accepted work on EOF and closes when its owner dies", %{context: context} do
    {_, pid} = ready(context, self())
    Session.submit(pid, query(1), self())
    assert_receive {:query_started, worker, []}
    assert :ok = Session.finish(pid, self())
    refute_receive :session_drained, 20
    send(worker, :release)
    assert response()["result"]
    assert_receive :session_drained

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {_, pid} = ready(context, owner)
    monitor = Process.monitor(pid)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "large responses return a bounded error", %{context: context} do
    context = %{context | config: %{context.config | max_response_bytes: 500}}
    {_, pid} = ready(context)
    {:ok, encoded} = Session.request(pid, query(1, "SELECT large"))
    assert byte_size(encoded) < 500
    assert Jason.decode!(encoded)["error"]["message"] =~ "Response too large"
    assert Server.encode(nil, 500) == nil
  end

  test "session status and crash reports omit credentials and messages", %{context: context} do
    context = %{context | config: %{context.config | secret: "private-session-credential"}}
    {_, pid} = ready(context)
    refute inspect(:sys.get_status(pid)) =~ "private-session-credential"
    monitor = Process.monitor(pid)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, {:unexpected, "private-sql-value"})
        assert {:ok, _} = Session.request(pid, rpc("ping"))
        GenServer.stop(pid, {:failure, "private-sql-value"})
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      end)

    refute log =~ "private-session-credential"
    refute log =~ "private-sql-value"
  end

  defp http(context, message, id \\ nil, method \\ :post) do
    conn =
      Plug.Test.conn(method, "/mcp", Jason.encode!(message))
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")

    conn = if id, do: put_req_header(conn, "mcp-session-id", id), else: conn
    HTTP.call(conn, context)
  end

  test "HTTP init, required session ID, reused ID, DELETE and version binding", %{
    context: context
  } do
    assert http(context, rpc("ping")).status == 400
    init = http(context, initialize())
    assert init.status == 200
    [id] = get_resp_header(init, "mcp-session-id")
    assert byte_size(id) == 32
    assert http(context, initialized(), id).status == 202
    assert http(context, rpc("ping"), id).status == 200

    wrong_version =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(rpc("ping")))
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", id)
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> HTTP.call(context)

    assert wrong_version.status == 400
    assert http(context, %{}, id, :delete).status == 204
    assert http(context, rpc("ping"), id).status == 404
    assert http(context, rpc("ping"), String.duplicate("x", 32)).status == 404
    assert http(context, %{}, id, :get).status == 404
    new_init = http(context, initialize())
    [new_id] = get_resp_header(new_init, "mcp-session-id")
    assert http(context, %{}, new_id, :get).status == 405
  end

  test "malformed initialization cannot fill the session supervisor", %{context: context} do
    for _ <- 1..5 do
      assert http(context, rpc("initialize")).status == 200
    end

    assert DynamicSupervisor.count_children(context.sessions).active == 0
    for _ <- 1..3, do: assert(http(context, initialize()).status == 200)
    assert http(context, initialize()).status == 503
  end
end
