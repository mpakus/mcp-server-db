defmodule McpEx.RuntimeTest.Adapter do
  def start_link(config), do: Agent.start_link(fn -> :pool end, name: config.connection[:name])
end

defmodule McpEx.RuntimeTest do
  use ExUnit.Case
  alias McpEx.{Config, Runtime, Session}

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
