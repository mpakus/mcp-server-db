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

    {:ok, pool} = adapter.start_link(config)
    context = %{pool: pool, adapter: adapter, config: config}
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
          Bandit.start_link(
            plug: {McpEx.HTTP, context},
            ip: config.http_ip,
            port: config.http_port
          )

        Process.sleep(:infinity)
      else
        stdio(context, :new)
      end
    after
      McpEx.Diagnostics.stop(diagnostics)
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

  defp stdio(context, state) do
    case line(context.config.max_bytes, [], 0) do
      :eof ->
        :ok

      {:error, reason} ->
        McpEx.Diagnostics.count(
          context,
          if(reason == "Request too large", do: "oversize_errors", else: "parse_errors")
        )

        IO.puts(Jason.encode!(McpEx.Server.error(nil, -32700, reason)))
        if reason == "Request too large", do: System.halt(1), else: stdio(context, state)

      {:ok, line} ->
        {response, next} =
          case Jason.decode(line) do
            {:ok, message} ->
              McpEx.Server.handle(message, context, state)

            _ ->
              McpEx.Diagnostics.count(context, "parse_errors")
              {McpEx.Server.error(nil, -32700, "Invalid JSON"), state}
          end

        if response, do: IO.puts(Jason.encode!(response))
        stdio(context, next)
    end
  end

  # ponytail: byte-at-a-time input bounds memory; switch to a buffered port if stdio throughput becomes material.
  defp line(limit, _, size) when size > limit, do: {:error, "Request too large"}

  defp line(limit, acc, size) do
    case IO.binread(:stdio, 1) do
      :eof when acc == [] -> :eof
      :eof -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _} -> {:error, "Input read failed"}
      "\n" -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      byte -> line(limit, [byte | acc], size + 1)
    end
  end
end
