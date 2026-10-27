defmodule McpEx.CLI do
  @moduledoc "Escript lifecycle and newline-delimited stdio transport."

  def main(args, adapter) do
    :ok = :logger.update_primary_config(%{level: :warning})
    {:ok, handler} = :logger.get_handler_config(:default)
    handler = handler |> Map.drop([:id, :module]) |> put_in([:config, :type], :standard_error)
    # The standard handler's output type cannot be changed after it starts.
    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, handler)

    case args do
      [command | options] when command in ["status", "resources"] ->
        System.halt(McpEx.Monitor.run(command, options, adapter.dialect()))

      _ ->
        serve(args, adapter)
    end
  rescue
    error -> startup_error(error)
  end

  defp serve(args, adapter) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [stdio: :boolean, http: :boolean, host: :string, port: :integer]
      )

    if rest != [] or invalid != [],
      do: raise(ArgumentError, "Use [--stdio | --http] [--host HOST] [--port PORT]")

    if opts[:stdio] && opts[:http], do: raise(ArgumentError, "Choose one transport")

    env =
      Enum.reduce([host: "HOST", port: "PORT"], System.get_env(), fn {option, name}, env ->
        if value = opts[option], do: Map.put(env, name, to_string(value)), else: env
      end)

    config = McpEx.Config.load(adapter.dialect(), env)
    remote = config.remote or opts[:http] == true

    if remote and (is_nil(config.secret) or config.secret == ""),
      do: raise(ArgumentError, "REMOTE_SECRET_KEY is required in HTTP mode")

    context = McpEx.Runtime.context(config, adapter)
    {:ok, runtime} = McpEx.Runtime.start_link(context)
    probe_started = System.monotonic_time(:microsecond)
    McpEx.Server.execute!(context, "SELECT 1", [], :read)
    probe_ms = (System.monotonic_time(:microsecond) - probe_started) / 1000

    transport = if remote and opts[:stdio] != true, do: "http", else: "stdio"

    diagnostics =
      McpEx.Diagnostics.start(context, transport: transport, initial_probe_ms: probe_ms)

    context =
      Map.merge(context, %{
        diagnostics: diagnostics,
        dashboard_token:
          if(diagnostics, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))
      })

    try do
      if transport == "http" or diagnostics != nil do
        plug = if transport == "http", do: McpEx.HTTP, else: McpEx.Dashboard

        {:ok, _} =
          Supervisor.start_child(
            runtime,
            {Bandit, plug: {plug, context}, ip: config.http_ip, port: config.http_port}
          )
      end

      startup_notice(context, transport)

      if transport == "http" do
        Process.sleep(:infinity)
      else
        case McpEx.Stdio.run(context) do
          :ok -> :ok
          {:error, _} -> System.halt(1)
        end
      end
    after
      McpEx.Diagnostics.stop(diagnostics)
      Supervisor.stop(runtime)
    end
  end

  defp startup_notice(context, transport) do
    config = context.config
    host = if config.http_host in ["0.0.0.0", "::"], do: "localhost", else: config.http_host
    base = %URI{scheme: "http", host: host, port: config.http_port}

    endpoint =
      if transport == "http",
        do: URI.to_string(%{base | path: "/mcp"}),
        else: "stdio"

    dashboard =
      cond do
        context.diagnostics ->
          URI.to_string(%{
            base
            | path: "/dashboard",
              fragment: "token=" <> context.dashboard_token
          })

        config.dashboard ->
          "unavailable (see startup warning)"

        true ->
          "disabled (enable with MCP_DASHBOARD=true)"
      end

    IO.puts(:stderr, "MCP: #{endpoint}\nDashboard: #{dashboard}")
  end

  defp startup_error(error) do
    message =
      if is_struct(error, ArgumentError),
        do: Exception.message(error),
        else: "Server startup failed; check database connectivity and configuration"

    IO.puts(:stderr, message)
    System.halt(1)
  end
end
