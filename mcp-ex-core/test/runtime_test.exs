defmodule McpEx.RuntimeTest.Adapter do
  def start_link(config), do: Agent.start_link(fn -> :pool end, name: config.connection[:name])
end

defmodule McpEx.RuntimeTest do
  use ExUnit.Case
  alias McpEx.{Cache, Config, Runtime, Session}

  @tag capture_log: true
  test "cache replacement drops entries and sessions but preserves the database pool" do
    context =
      Runtime.context(Config.load(:mysql, %{"MCP_CACHE_ENABLED" => "true"}), __MODULE__.Adapter)

    runtime = start_supervised!({Runtime, context})
    assert Cache.fetch(context, "SELECT 1", [], fn -> "old" end) == {"old", :miss}
    {:ok, _, session} = Session.open(context)
    monitor = Process.monitor(session)
    pool = Process.whereis(context.pool)
    old_cache = Process.whereis(context.cache)
    Process.exit(old_cache, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :shutdown}
    Supervisor.which_children(runtime)
    assert Process.whereis(context.pool) == pool
    assert Process.whereis(context.cache) != old_cache
    assert Cache.fetch(context, "SELECT 1", [], fn -> "new" end) == {"new", :miss}

    cache_monitor = Process.monitor(Process.whereis(context.cache))
    Process.exit(pool, :kill)
    assert_receive {:DOWN, ^cache_monitor, :process, _, :shutdown}
    Supervisor.which_children(runtime)
    assert Cache.fetch(context, "SELECT 1", [], fn -> "newer" end) == {"newer", :miss}
  end

  @tag capture_log: true
  test "pool replacement invalidates dependent sessions and restarts the listener" do
    context = Runtime.context(Config.load(:mysql, %{}), __MODULE__.Adapter)
    runtime = start_supervised!({Runtime, context})

    {:ok, listener} =
      Supervisor.start_child(
        runtime,
        {Bandit, plug: {McpEx.HTTP, context}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, id, session} = Session.open(context)
    monitor = Process.monitor(session)
    listener_monitor = Process.monitor(listener)
    old_pool = Process.whereis(context.pool)
    Process.exit(old_pool, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :shutdown}
    assert_receive {:DOWN, ^listener_monitor, :process, ^listener, :shutdown}

    # A supervisor call waits until its restart sequence has completed.
    children = Supervisor.which_children(runtime)
    assert Process.whereis(context.pool) != old_pool

    assert Enum.any?(children, fn
             {{Bandit, _}, pid, _, _} -> is_pid(pid) and pid != listener
             _ -> false
           end)

    assert {:error, :not_found} = Session.lookup(context, id)
    assert {:ok, _, _} = Session.open(context)
  end
end
