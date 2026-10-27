defmodule McpEx.Session do
  @moduledoc "One MCP lifecycle, with bounded, supervised and monitored query workers."
  use GenServer, restart: :temporary
  alias McpEx.Server

  def open(context, owner \\ nil, version \\ nil) do
    id = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

    case DynamicSupervisor.start_child(
           context.sessions,
           {__MODULE__, {context, id, owner, version}}
         ) do
      {:ok, pid} -> {:ok, id, pid}
      error -> error
    end
  end

  def lookup(context, id) do
    case Registry.lookup(context.registry, id) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
      [] -> {:error, :not_found}
    end
  end

  def start_link({context, id, owner, version}) do
    GenServer.start_link(__MODULE__, {context, owner, version},
      name: {:via, Registry, {context.registry, id}}
    )
  end

  def request(pid, message, version \\ nil),
    do: call(pid, {:request, message, version})

  def submit(pid, message, receiver), do: call(pid, {:submit, message, receiver})
  def finish(pid, receiver), do: call(pid, {:finish, receiver})
  def close(pid), do: call(pid, :close)

  defp call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  @impl true
  def init({context, owner, version}) do
    # Tasks are linked for owner-death cleanup; their failures arrive as DOWN messages.
    Process.flag(:trap_exit, true)
    if owner, do: Process.monitor(owner)

    state = %{
      context: context,
      owner: owner,
      phase: if(version, do: :initializing, else: :new),
      version: version,
      pending: %{},
      request_refs: %{},
      idle: nil,
      draining: nil
    }

    {:ok, touch(state)}
  end

  @impl true
  def handle_call({:request, message, version}, from, state) do
    if version && state.version && version != state.version do
      {:reply, {:error, :version}, state}
    else
      {:noreply, accept(message, {:call, from}, touch(state))}
    end
  end

  def handle_call({:submit, message, receiver}, _from, state),
    do: {:reply, :ok, accept(message, {:send, receiver}, touch(state))}

  def handle_call({:finish, receiver}, _from, state) do
    state = %{state | draining: receiver}
    if map_size(state.pending) == 0, do: send(self(), :drained)
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}
  def handle_call(_, _from, state), do: {:reply, {:error, :unsupported}, state}

  @impl true
  def handle_info({ref, response}, state) when is_reference(ref),
    do: {:noreply, complete(state, ref, response)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{owner: pid} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    response =
      case state.pending[ref] do
        nil -> nil
        entry -> encode(Server.error(entry.id, -32_603, "Request worker failed"), state)
      end

    {:noreply, complete(state, ref, response)}
  end

  def handle_info({:deadline, ref}, state) do
    case state.pending[ref] do
      nil ->
        {:noreply, state}

      entry ->
        Process.exit(entry.task.pid, :kill)
        response = encode(Server.error(entry.id, -32_000, "Request timed out"), state)
        {:noreply, complete(state, ref, response)}
    end
  end

  def handle_info({:idle, token}, %{idle: {_, token}, pending: pending} = state)
      when map_size(pending) == 0,
      do: {:stop, :normal, state}

  def handle_info({:idle, _}, state), do: {:noreply, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info(:drained, state) do
    send(state.draining, :session_drained)
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    for {_, entry} <- state.pending do
      Process.exit(entry.task.pid, :kill)
      deliver(entry.target, {:error, :closed})
    end

    :ok
  end

  @impl true
  def format_status(status) do
    # Session contexts contain credentials; incoming messages may contain SQL/PII.
    Map.new(status, fn
      {:state, state} ->
        {:state, %{phase: state.phase, active_requests: map_size(state.pending)}}

      {:log, _} ->
        {:log, []}

      {key, _} when key in [:message, :reason] ->
        {key, :redacted}

      entry ->
        entry
    end)
  end

  defp accept(
         %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"} = message,
         target,
         state
       )
       when not is_map_key(message, "id") do
    id = if is_map(message["params"]), do: message["params"]["requestId"]
    ref = Map.get(state.request_refs, id)

    state =
      case state.pending[ref] do
        entry when not is_nil(entry) ->
          Process.exit(entry.task.pid, :kill)
          complete(state, ref, nil)

        nil ->
          state
      end

    deliver(target, {:ok, nil})
    state
  end

  defp accept(message, target, state) do
    id = request_id(message)

    cond do
      not is_nil(id) and is_map_key(state.request_refs, id) ->
        deliver(
          target,
          {:ok, encode(Server.error(id, -32_600, "Request id already active"), state)}
        )

        state

      not is_nil(id) and message["method"] == "initialize" and state.phase != :new ->
        deliver(
          target,
          {:ok, encode(Server.error(id, -32_600, "Session already initialized"), state)}
        )

        state

      work?(message, state) ->
        start_work(message, target, state)

      true ->
        {response, phase} = Server.handle(message, state.context, state.phase)
        version = get_in(response || %{}, ["result", "protocolVersion"]) || state.version
        deliver(target, {:ok, encode(response, state)})
        %{state | phase: phase, version: version}
    end
  end

  defp request_id(%{"jsonrpc" => "2.0", "method" => method, "id" => id})
       when is_binary(method) and (is_integer(id) or is_binary(id)),
       do: id

  defp request_id(_), do: nil

  defp work?(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = message, state) do
    state.phase == :ready and (is_integer(id) or is_binary(id)) and
      is_map(Map.get(message, "params", %{})) and
      method in ["tools/call", "resources/list", "resources/read"]
  end

  defp work?(_, _), do: false

  defp start_work(message, target, state) do
    if map_size(state.pending) >= state.context.config.max_inflight do
      overloaded(message, target, state)
    else
      context = state.context

      owner = self()

      # Linking also cleans up on an untrappable session kill. The handshake installs
      # the monitor before work starts; task failures cannot crash the trapping owner.
      case Task.Supervisor.start_child(context.tasks, fn ->
             Process.link(owner)

             receive do
               {:run, ref} ->
                 {response, _} = Server.handle(message, context)
                 send(owner, {ref, Server.encode(response, context.config.max_response_bytes)})
             end
           end) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          timer = Process.send_after(self(), {:deadline, ref}, context.config.request_timeout)
          entry = %{id: message["id"], task: %{pid: pid, ref: ref}, timer: timer, target: target}
          send(pid, {:run, ref})

          %{
            state
            | pending: Map.put(state.pending, ref, entry),
              request_refs: Map.put(state.request_refs, entry.id, ref)
          }

        {:error, :max_children} ->
          overloaded(message, target, state)
      end
    end
  end

  defp overloaded(message, target, state) do
    deliver(
      target,
      {:ok, encode(Server.error(message["id"], -32_000, "Server busy; retry later"), state)}
    )

    state
  end

  defp complete(state, ref, response) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        state

      {entry, pending} ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(ref, [:flush])
        deliver(entry.target, {:ok, response})

        state =
          touch(%{
            state
            | pending: pending,
              request_refs: Map.delete(state.request_refs, entry.id)
          })

        if state.draining && map_size(pending) == 0, do: send(self(), :drained)
        state
    end
  end

  defp touch(%{owner: owner} = state) when is_pid(owner), do: state

  defp touch(state) do
    if state.idle, do: Process.cancel_timer(elem(state.idle, 0))
    token = make_ref()
    timer = Process.send_after(self(), {:idle, token}, state.context.config.session_idle_timeout)
    %{state | idle: {timer, token}}
  end

  defp encode(response, state),
    do: Server.encode(response, state.context.config.max_response_bytes)

  defp deliver({:call, from}, result), do: GenServer.reply(from, result)
  defp deliver({:send, pid}, result), do: send(pid, {:session_response, result})
end
