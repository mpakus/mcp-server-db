defmodule McpEx.Runtime do
  @moduledoc "Supervision for one server instance and its shared database pool."
  use Supervisor

  def context(config, adapter) do
    %{
      config: config,
      adapter: adapter,
      pool: McpEx.Pool,
      cache: if(config.cache.enabled, do: McpEx.QueryCache),
      registry: McpEx.SessionRegistry,
      sessions: McpEx.SessionSupervisor,
      tasks: McpEx.QuerySupervisor
    }
  end

  def start_link(context), do: Supervisor.start_link(__MODULE__, context)

  @impl true
  def init(context) do
    config = %{
      context.config
      | connection: Keyword.put(context.config.connection, :name, context.pool)
    }

    cache = if context.cache, do: [{McpEx.Cache, {context.cache, config.cache}}], else: []

    children =
      [
        %{id: :database, start: {context.adapter, :start_link, [config]}}
      ] ++
        cache ++
        [
          {Registry, keys: :unique, name: context.registry},
          {Task.Supervisor, name: context.tasks, max_children: config.connection[:pool_size]},
          {DynamicSupervisor,
           name: context.sessions, strategy: :one_for_one, max_children: config.max_sessions}
        ]

    # A replaced pool or worker supervisor invalidates all dependent sessions.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
