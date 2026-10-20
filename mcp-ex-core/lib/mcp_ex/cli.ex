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
    config = McpEx.Config.load(adapter.dialect())
    remote = config.remote or "--http" in args

    if Enum.any?(args, &(&1 not in ["--stdio", "--http"])),
      do: raise(ArgumentError, "Use --stdio or --http")

    if "--stdio" in args and "--http" in args, do: raise(ArgumentError, "Choose one transport")

    if remote and (is_nil(config.secret) or config.secret == ""),
      do: raise(ArgumentError, "REMOTE_SECRET_KEY is required in HTTP mode")

    context = McpEx.Runtime.context(config, adapter)
    {:ok, runtime} = McpEx.Runtime.start_link(context)
    probe_started = System.monotonic_time(:microsecond)
    McpEx.Server.execute!(context, "SELECT 1", [], :read)
    probe_ms = (System.monotonic_time(:microsecond) - probe_started) / 1000

    transport = if remote and "--stdio" not in args, do: "http", else: "stdio"

    diagnostics =
      McpEx.Diagnostics.start(context, transport: transport, initial_probe_ms: probe_ms)

    context = Map.put(context, :diagnostics, diagnostics)

    try do
      if transport == "http" do
        {:ok, _} =
          Supervisor.start_child(
            runtime,
            {Bandit, plug: {McpEx.HTTP, context}, ip: config.http_ip, port: config.http_port}
          )

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

  defp startup_error(error) do
    message =
      if is_struct(error, ArgumentError),
        do: Exception.message(error),
        else: "Server startup failed; check database connectivity and configuration"

    IO.puts(:stderr, message)
    System.halt(1)
  end
end
