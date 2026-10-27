defmodule McpEx.Stdio do
  @moduledoc "Bounded port buffering and one stdout writer for a single MCP session."
  alias McpEx.{Diagnostics, Server, Session}

  def run(context) do
    if :init.get_argument(:noinput) == :error,
      do:
        raise(
          ArgumentError,
          "Stdio requires -noinput; use the built escript or ERL_FLAGS=-noinput"
        )

    {:ok, _, session} = Session.open(context, self())
    monitor = Process.monitor(session)
    port = Port.open({:fd, 0, 1}, [:binary, :in, :eof])

    try do
      loop(context, session, monitor, port, [], 0)
    after
      Session.close(session)
      if Port.info(port), do: Port.close(port)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp loop(context, session, monitor, port, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        case consume(data, chunks, size, context, session) do
          :oversize ->
            Diagnostics.count(context, "oversize_errors")
            write(Server.encode(Server.error(nil, -32_700, "Request too large"), :infinity))
            {:error, :oversize}

          {chunks, size} ->
            loop(context, session, monitor, port, chunks, size)
        end

      {^port, :eof} ->
        if chunks != [], do: submit(chunks, context, session)
        Session.finish(session, self())
        loop(context, session, monitor, port, [], 0)

      {:session_response, {:ok, response}} ->
        if response, do: write(response)
        loop(context, session, monitor, port, chunks, size)

      {:session_response, {:error, :closed}} ->
        {:error, :session_closed}

      :session_drained ->
        :ok

      {:DOWN, ^monitor, :process, ^session, _} ->
        {:error, :session_closed}
    end
  end

  defp consume("", chunks, size, _, _), do: {chunks, size}

  defp consume(data, chunks, size, context, session) do
    case :binary.match(data, "\n") do
      {offset, 1} when size + offset <= context.config.max_bytes ->
        line = binary_part(data, 0, offset)
        rest = binary_part(data, offset + 1, byte_size(data) - offset - 1)
        submit([line | chunks], context, session)
        consume(rest, [], 0, context, session)

      :nomatch when size + byte_size(data) <= context.config.max_bytes ->
        {[data | chunks], size + byte_size(data)}

      _ ->
        :oversize
    end
  end

  defp submit(chunks, context, session) do
    line = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case Jason.decode(line) do
      {:ok, message} ->
        Session.submit(session, message, self())

      _ ->
        Diagnostics.count(context, "parse_errors")
        write(Server.encode(Server.error(nil, -32_700, "Invalid JSON"), :infinity))
    end
  end

  # Coalesce only responses already queued; never wait to fill a batch.
  defp write(response), do: write([[response, "\n"]], 1, byte_size(response) + 1)

  defp write(responses, count, size) when count < 64 and size < 65_536 do
    receive do
      {:session_response, {:ok, nil}} ->
        write(responses, count + 1, size)

      {:session_response, {:ok, response}} ->
        write([[response, "\n"] | responses], count + 1, size + byte_size(response) + 1)
    after
      0 -> IO.binwrite(:stdio, Enum.reverse(responses))
    end
  end

  defp write(responses, _, _), do: IO.binwrite(:stdio, Enum.reverse(responses))
end
