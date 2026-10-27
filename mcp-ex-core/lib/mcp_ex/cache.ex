defmodule McpEx.Cache do
  @moduledoc "Optional bounded query-payload cache: direct ETS reads, supervised writes and expiry."
  use GenServer

  @scope ~w(dialect schema pii pii_columns pii_patterns pii_json pii_star pii_references pii_introspection pii_block_introspection)a

  def start_link({name, options}),
    do: GenServer.start_link(__MODULE__, {name, options}, name: name)

  def fetch(context, sql, values, fun) do
    case Map.get(context, :cache) do
      nil ->
        {fun.(), :disabled}

      table ->
        fetch_cached(table, key(context.config, sql, values), context.config.cache.ttl, fun)
    end
  end

  def with_write(context, fun) do
    table = Map.get(context, :cache)
    ref = if table, do: call(table, :begin_write)

    try do
      fun.()
    after
      if is_reference(ref), do: call(table, {:end_write, ref})
    end
  end

  defp key(config, sql, values),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({Map.take(config, @scope), sql, values}))

  defp fetch_cached(table, key, ttl, fun) do
    started = now()

    case lookup(table, key) do
      {:hit, payload} ->
        {payload, :hit}

      {:miss, generation} ->
        payload = fun.()
        call(table, {:put, generation, key, started + ttl, payload})
        {payload, :miss}

      :bypass ->
        {fun.(), :bypass}
    end
  end

  defp lookup(table, key) do
    case :ets.lookup(table, :generation) do
      [{:generation, generation, false}] ->
        lookup_payload(table, generation, key)

      _ ->
        :bypass
    end
  rescue
    ArgumentError -> :bypass
  end

  defp lookup_payload(table, generation, key) do
    case :ets.lookup(table, {generation, key}) do
      [{_, expires, payload}] ->
        if expires > now(), do: {:hit, payload}, else: {:miss, generation}

      _ ->
        {:miss, generation}
    end
  end

  defp call(table, message) do
    GenServer.call(table, message, :infinity)
  catch
    :exit, _ -> :unavailable
  end

  @impl true
  def init({table, options}) do
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(table, {:generation, make_ref(), false})
    state = %{table: table, options: options, writers: %{}}
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:put, generation, key, expires, payload}, _from, state) do
    if :ets.lookup(state.table, :generation) == [{:generation, generation, false}] and
         expires > now() and byte_size(payload) <= state.options.max_entry_bytes do
      expire_key(state.table, {generation, key})

      if :ets.info(state.table, :size) > state.options.max_entries, do: sweep(state)

      # The owner serializes admissions, so concurrent misses cannot exceed the cap.
      if :ets.info(state.table, :size) <= state.options.max_entries,
        do: :ets.insert_new(state.table, {{generation, key}, expires, payload})
    end

    {:reply, :ok, state}
  end

  def handle_call(:begin_write, {pid, _}, state) do
    ref = Process.monitor(pid)
    state = %{state | writers: Map.put(state.writers, ref, pid)}
    invalidate(state)
    {:reply, ref, state}
  end

  def handle_call({:end_write, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, end_write(state, ref)}
  end

  defp expire_key(table, key) do
    case :ets.lookup(table, key) do
      [{_, previous_expiry, _}] ->
        if previous_expiry <= now(), do: :ets.delete(table, key)

      [] ->
        :ok
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, end_write(state, ref)}

  def handle_info(:sweep, state) do
    sweep(state)
    schedule(state)
    {:noreply, state}
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, %{active_writers: map_size(state.writers)}}
      {:log, _} -> {:log, []}
      {key, _} when key in [:message, :reason] -> {key, :redacted}
      entry -> entry
    end)
  end

  defp end_write(state, ref) do
    if is_map_key(state.writers, ref) do
      state = %{state | writers: Map.delete(state.writers, ref)}
      invalidate(state)
      state
    else
      state
    end
  end

  defp invalidate(state) do
    :ets.insert(state.table, {:generation, make_ref(), map_size(state.writers) > 0})
    :ets.select_delete(state.table, [{{{:_, :_}, :_, :_}, [], [true]}])
  end

  defp sweep(state),
    do:
      :ets.select_delete(state.table, [{{{:_, :_}, :"$1", :_}, [{:"=<", :"$1", now()}], [true]}])

  defp schedule(state),
    do: Process.send_after(self(), :sweep, max(100, min(state.options.ttl, 1000)))

  defp now, do: System.monotonic_time(:millisecond)
end
