defmodule McpEx.CacheTest.Adapter do
  def execute(_, _, _, _) do
    send(self(), :executed)
    {:ok, %{columns: ["label"], rows: [["john@example.com"]], num_rows: 1}}
  end
end

defmodule McpEx.CacheTest do
  use ExUnit.Case
  alias McpEx.{Cache, Config, Server}

  defp context(extra \\ %{}) do
    config =
      Config.load(:mysql, Map.merge(%{"MYSQL_DB" => "app", "MCP_CACHE_ENABLED" => "true"}, extra))

    start_supervised!({Cache, {__MODULE__, config.cache}})
    %{cache: __MODULE__, config: config, adapter: __MODULE__.Adapter, pool: nil}
  end

  defp fetch(context, value \\ "value"),
    do: Cache.fetch(context, "SELECT 1", [], fn -> value end)

  defp query(context, args, id \\ 1) do
    {response, _} =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => "tools/call",
          "params" => %{"name" => "mysql_query", "arguments" => args}
        },
        context
      )

    response
  end

  test "defaults are disabled and configuration is bounded" do
    assert Config.load(:mysql, %{}).cache == %{
             enabled: false,
             ttl: 5000,
             max_entries: 1000,
             max_entry_bytes: 65_536
           }

    assert fetch(%{cache: nil}) == {"value", :disabled}

    for {key, values} <- [
          {"MCP_CACHE_ENABLED", ["yes"]},
          {"MCP_CACHE_TTL_MS", ["0", "-1", "bad", "2147483648"]},
          {"MCP_CACHE_MAX_ENTRIES", ["0", "100001"]},
          {"MCP_CACHE_MAX_ENTRY_BYTES", ["0", "8388609"]}
        ],
        value <- values do
      assert_raise ArgumentError, fn -> Config.load(:mysql, %{key => value}) end
    end
  end

  test "hits avoid execution and keys isolate SQL, params, schema and redaction" do
    ctx = context()
    assert fetch(ctx) == {"value", :miss}
    assert fetch(ctx, "new") == {"value", :hit}

    for {sql, params, cfg} <- [
          {"SELECT 2", [], ctx.config},
          {"SELECT 1", [1], ctx.config},
          {"SELECT 1", [], %{ctx.config | schema: "other"}},
          {"SELECT 1", [], %{ctx.config | pii: true}},
          {"SELECT 1", [], %{ctx.config | dialect: :pg}}
        ] do
      assert Cache.fetch(%{ctx | config: cfg}, sql, params, fn -> "different" end) ==
               {"different", :miss}
    end

    assert :ets.info(ctx.cache, :protection) == :protected
    refute inspect(:ets.tab2list(ctx.cache)) =~ "SELECT"
  end

  test "TTL is fixed, enforced on reads before sweep, and starts before query execution" do
    ctx = context(%{"MCP_CACHE_TTL_MS" => "50"})
    assert fetch(ctx) == {"value", :miss}
    Process.sleep(30)
    assert fetch(ctx) == {"value", :hit}
    Process.sleep(30)
    assert fetch(ctx, "fresh") == {"fresh", :miss}
    assert fetch(ctx) == {"fresh", :hit}

    assert Cache.fetch(ctx, "slow", [], fn ->
             Process.sleep(60)
             "old"
           end) == {"old", :miss}

    assert Cache.fetch(ctx, "slow", [], fn -> "fresh" end) == {"fresh", :miss}
  end

  test "entry and byte bounds hold under concurrent admissions and expired entries free space" do
    ctx =
      context(%{
        "MCP_CACHE_MAX_ENTRIES" => "2",
        "MCP_CACHE_MAX_ENTRY_BYTES" => "4",
        "MCP_CACHE_TTL_MS" => "50"
      })

    assert fetch(ctx, "oversize") == {"oversize", :miss}
    assert :ets.info(ctx.cache, :size) == 1

    1..20
    |> Task.async_stream(fn i -> Cache.fetch(ctx, to_string(i), [], fn -> "ok" end) end)
    |> Stream.run()

    assert :ets.info(ctx.cache, :size) == 3
    Process.sleep(60)
    assert fetch(ctx, "new") == {"new", :miss}
    assert fetch(ctx) == {"new", :hit}
    Process.sleep(160)
    assert :ets.info(ctx.cache, :size) == 1
  end

  test "failed executions are never cached" do
    ctx = context()

    assert_raise RuntimeError, fn ->
      Cache.fetch(ctx, "SELECT 1", [], fn -> raise "failed" end)
    end

    assert fetch(ctx) == {"value", :miss}
  end

  test "writes invalidate before and after, including failed writes" do
    ctx = context()
    fetch(ctx)

    assert_raise RuntimeError, fn ->
      Cache.with_write(ctx, fn ->
        assert fetch(ctx, "live") == {"live", :bypass}
        raise "write failed"
      end)
    end

    assert fetch(ctx, "new") == {"new", :miss}
    assert fetch(ctx) == {"new", :hit}
  end

  test "concurrent writers bypass cache until every writer exits, including cancellation" do
    ctx = context()
    parent = self()

    writers =
      for _ <- 1..2 do
        spawn(fn ->
          Cache.with_write(ctx, fn ->
            send(parent, {:writing, self()})

            receive do
              :finish -> :ok
            end
          end)
        end)
      end

    for writer <- writers, do: assert_receive({:writing, ^writer})
    assert fetch(ctx) == {"value", :bypass}
    [first, second] = writers
    monitor = Process.monitor(first)
    send(first, :finish)
    assert_receive {:DOWN, ^monitor, _, _, _}
    assert fetch(ctx) == {"value", :bypass}
    monitor = Process.monitor(second)
    Process.exit(second, :kill)
    assert_receive {:DOWN, ^monitor, _, _, _}
    # Wait for the owner's independently delivered monitor message.
    eventually(fn -> assert fetch(ctx) == {"value", :miss} end)
    assert fetch(ctx) == {"value", :hit}
  end

  test "slow fills cannot repopulate after a write or owner restart" do
    ctx = context()

    for action <- [:write, :restart] do
      parent = self()

      reader =
        Task.async(fn ->
          Cache.fetch(ctx, "SELECT 1", [], fn ->
            send(parent, :reading)

            receive do
              :finish -> "stale"
            end
          end)
        end)

      assert_receive :reading

      case action do
        :write ->
          Cache.with_write(ctx, fn -> :ok end)

        :restart ->
          stop_supervised!(Cache)
          start_supervised!({Cache, {__MODULE__, ctx.config.cache}})
      end

      send(reader.pid, :finish)
      assert Task.await(reader) == {"stale", :miss}
      assert fetch(ctx, "fresh") == {"fresh", :miss}
      Cache.with_write(ctx, fn -> :ok end)
    end
  end

  test "server opt-in caches redacted payload only and checks policy on every request" do
    ctx = context(%{"ENABLE_PII_REDACTION" => "true"})
    args = %{"sql" => "SELECT label FROM users", "cache" => true}
    first = query(ctx, args)
    assert_receive :executed
    assert first["result"]["_meta"]["cache"] == "miss"
    second = query(ctx, args, 99)
    refute_receive :executed
    assert second["id"] == 99
    assert second["result"]["_meta"]["cache"] == "hit"
    assert hd(second["result"]["content"]) == hd(first["result"]["content"])
    refute inspect(:ets.tab2list(ctx.cache)) =~ "john@example.com"
    assert inspect(:ets.tab2list(ctx.cache)) =~ "j***@e***.com"

    # Even a populated entry must not bypass the current SQL/PII policy.
    Cache.fetch(ctx, "SELECT email FROM users", [], fn -> "forbidden-payload" end)
    assert query(ctx, %{args | "sql" => "SELECT email FROM users"})["result"]["isError"]
    refute_receive :executed
    query(ctx, Map.delete(args, "cache"))
    assert_receive :executed
    query(ctx, %{args | "cache" => false})
    assert_receive :executed
    assert query(ctx, %{args | "cache" => "true"})["result"]["isError"]
    writable = %{ctx | config: %{ctx.config | allow: Map.put(ctx.config.allow, "update", true)}}

    assert query(writable, %{args | "sql" => "UPDATE users SET label = 'new'"})["result"][
             "isError"
           ]

    refute_receive :executed
    query(writable, %{"sql" => "UPDATE users SET label = 'new'"})
    assert_receive :executed
    assert query(ctx, args)["result"]["_meta"]["cache"] == "miss"
  end

  test "owner status omits payloads and unavailable cache falls back to execution" do
    ctx = context()
    fetch(ctx, "private-payload")
    refute inspect(:sys.get_status(ctx.cache)) =~ "private-payload"
    stop_supervised!(Cache)
    assert fetch(ctx) == {"value", :bypass}
  end

  defp eventually(assertion, attempts \\ 20) do
    assertion.()
  rescue
    e in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(e, __STACKTRACE__)
      Process.sleep(5)
      eventually(assertion, attempts - 1)
  end
end
