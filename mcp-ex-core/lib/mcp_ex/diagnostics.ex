defmodule McpEx.Diagnostics do
  @moduledoc "Optional counters and private, bounded snapshots; never stores query data."
  use GenServer
  import Bitwise
  alias McpEx.{Config, Server}

  @methods ~w(initialize ping tools/list tools/call resources/list resources/read)
  @keys ~w(requests rpc_success rpc_errors notifications tools tool_success tool_failed
    validation_errors policy_rejections database_failures processing_failures
    tool_duration_us tool_max_us queries_read queries_write queries_ddl parse_errors oversize_errors) ++
          Enum.map(@methods ++ ["other"], &("method." <> &1)) ++
          Enum.map(
            [200, 202, 400, 401, 403, 404, 405, 406, 413, 415],
            &("http." <> to_string(&1))
          )
  @limit 1_048_576
  @resource_keys ~w(uri name title mimeType)
  @snapshot_keys ~w(schema_version instance_id server pid transport started_at updated_at sequence
    uptime_ms database counters beam health pool resources)

  def directory(env \\ System.get_env()) do
    base =
      if env["XDG_STATE_HOME"] in [nil, ""],
        do: Path.join(System.user_home!(), ".local/state"),
        else: env["XDG_STATE_HOME"]

    path =
      if env["MCP_DASHBOARD_DIR"] in [nil, ""],
        do: Path.join(base, "mcp-ex"),
        else: env["MCP_DASHBOARD_DIR"]

    Path.expand(path)
  end

  def start(context, opts \\ []) do
    if context.config.dashboard do
      with {:ok, uid} <- uid(),
           :ok <- prepare_directory(context.config.dashboard_dir, uid) do
        table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
        :ets.insert(table, Enum.map(@keys, &{&1, 0}))
        {:ok, pid} = GenServer.start(__MODULE__, {context, table, self(), uid, opts})
        %{pid: pid, table: table}
      else
        _ ->
          IO.puts(
            :stderr,
            "Dashboard disabled: snapshot directory must be private and owned by this user"
          )

          nil
      end
    end
  rescue
    _ ->
      IO.puts(:stderr, "Dashboard disabled: unable to start snapshot publisher")
      nil
  end

  def stop(nil), do: :ok

  def stop(handle) do
    try do
      GenServer.stop(handle.pid, :normal, 1000)
    catch
      :exit, _ -> :ok
    end

    try do
      :ets.delete(handle.table)
    rescue
      ArgumentError -> :ok
    end
  end

  def count(context, key, amount \\ 1) do
    case Map.get(context, :diagnostics) do
      %{table: table} when key in @keys ->
        :ets.update_counter(table, key, amount)
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  def rpc(context, message, fun) do
    notification =
      is_map(message) and message["jsonrpc"] == "2.0" and
        is_binary(message["method"]) and is_map(Map.get(message, "params", %{})) and
        not Map.has_key?(message, "id")

    {response, _} = result = fun.()

    cond do
      notification ->
        count(context, "notifications")

      is_nil(response) ->
        :ok

      true ->
        count(context, "requests")
        method = if is_map(message), do: message["method"], else: nil
        count(context, "method." <> if(method in @methods, do: method, else: "other"))
        count(context, if(Map.has_key?(response, "error"), do: "rpc_errors", else: "rpc_success"))
    end

    result
  end

  def tool(context, fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    count(context, "tools")
    count(context, if(result["isError"], do: "tool_failed", else: "tool_success"))
    elapsed = max(System.monotonic_time(:microsecond) - started, 0)
    count(context, "tool_duration_us", elapsed)
    maximum(context, elapsed)
    result
  end

  def step(context, failure, fun) do
    fun.()
  catch
    kind, reason ->
      count(context, failure)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp maximum(%{diagnostics: %{table: table}}, elapsed) do
    :ets.select_replace(table, [
      {{"tool_max_us", :"$1"}, [{:<, :"$1", elapsed}], [{{"tool_max_us", elapsed}}]}
    ])
  rescue
    ArgumentError -> :ok
  end

  defp maximum(_, _), do: :ok

  @impl true
  def init({context, table, owner, uid, opts}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)
    config = context.config
    id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    now = System.system_time(:millisecond)
    # Keep credentials and bearer tokens out of the collector and its crash reports.
    sample_config =
      Map.take(config, [
        :dialect,
        :scheme,
        :tool,
        :schema,
        :timeout,
        :pii,
        :pii_columns,
        :pii_patterns,
        :pii_json,
        :pii_star,
        :pii_references,
        :pii_introspection,
        :pii_block_introspection
      ])
      |> Map.update!(:timeout, &min(&1, 2000))

    state = %{
      directory: config.dashboard_dir,
      uid: uid,
      id: id,
      table: table,
      path: Path.join(config.dashboard_dir, id <> ".json"),
      context: %{adapter: context.adapter, pool: context.pool, config: sample_config},
      identity: %{
        "server" => Server.info(config),
        "pid" => System.pid(),
        "transport" => Keyword.get(opts, :transport, "stdio"),
        "started_at" => now,
        "database" => %{
          "dialect" => to_string(config.dialect),
          "host" => config.connection[:hostname],
          "port" => config.connection[:port],
          "name" => config.connection[:database],
          "schema" => config.schema,
          "pool_size" => config.connection[:pool_size],
          "read_only" => Config.read_only?(config),
          "pii" => config.pii
        }
      },
      started: System.monotonic_time(:millisecond),
      sequence: 0,
      health: %{
        "status" => "ok",
        "checked_at" => now,
        "last_success_at" => now,
        "last_success_duration_ms" => Keyword.get(opts, :initial_probe_ms)
      },
      pool: %{"status" => "pending", "checked_at" => nil},
      resources: %{
        "status" => "pending",
        "checked_at" => nil,
        "sampled_at" => nil,
        "items" => [],
        "total" => 0,
        "truncated" => false
      },
      due: %{resources: 0, pool: 0, health: now + 30_000},
      job: nil,
      interval: Keyword.get(opts, :interval, 2000),
      sampling: Keyword.get(opts, :sampling, true),
      write_failed: false
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state |> publish() |> schedule()}
  end

  def handle_info({:sample, ref, value}, %{job: %{ref: ref} = job} = state) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    {:noreply, state |> finish(job.kind, value) |> Map.put(:job, nil) |> publish() |> schedule()}
  end

  def handle_info({:deadline, ref}, %{job: %{ref: ref} = job} = state) do
    Process.exit(job.pid, :kill)
    Process.demonitor(job.monitor, [:flush])

    {:noreply,
     state
     |> finish(job.kind, {:error, "timeout"})
     |> Map.put(:job, nil)
     |> publish()
     |> schedule()}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{job: %{monitor: monitor} = job} = state) do
    Process.cancel_timer(job.timer)

    {:noreply,
     state
     |> finish(job.kind, {:error, "unavailable"})
     |> Map.put(:job, nil)
     |> publish()
     |> schedule()}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.job, do: Process.exit(state.job.pid, :kill)
    File.rm(state.path)
    :ok
  end

  defp schedule(%{sampling: false} = state), do: state
  defp schedule(%{job: job} = state) when not is_nil(job), do: state

  defp schedule(state) do
    now = System.system_time(:millisecond)
    kind = Enum.find([:resources, :pool, :health], &(state.due[&1] <= now))

    if kind do
      ref = make_ref()
      publisher = self()
      context = state.context

      {pid, monitor} =
        :erlang.spawn_opt(fn -> send(publisher, {:sample, ref, sample(kind, context)}) end, [
          :link,
          :monitor
        ])

      timeout = if kind == :pool, do: 500, else: 2000
      timer = Process.send_after(self(), {:deadline, ref}, timeout)
      interval = %{pool: 5000, health: 30_000, resources: 60_000}[kind]

      %{
        state
        | job: %{kind: kind, ref: ref, pid: pid, monitor: monitor, timer: timer},
          due: Map.put(state.due, kind, now + interval)
      }
    else
      state
    end
  end

  defp sample(kind, context) do
    value =
      case kind do
        :health ->
          started = System.monotonic_time(:microsecond)
          Server.execute!(context, "SELECT 1", [], :read)

          %{
            "last_success_at" => System.system_time(:millisecond),
            "last_success_duration_ms" => (System.monotonic_time(:microsecond) - started) / 1000
          }

        :pool ->
          metrics = context.adapter.pool_metrics(context)

          %{
            "ready" => Enum.reduce(metrics, 0, &(&1.ready_conn_count + &2)),
            "queued" => Enum.reduce(metrics, 0, &(&1.checkout_queue_length + &2))
          }

        :resources ->
          {response, _} =
            Server.handle(%{"jsonrpc" => "2.0", "id" => 0, "method" => "resources/list"}, context)

          items = response["result"]["resources"]

          %{
            "items" => items |> Enum.take(200) |> Enum.map(&Map.take(&1, @resource_keys)),
            "total" => length(items),
            "truncated" => length(items) > 200,
            "sampled_at" => System.system_time(:millisecond)
          }
      end

    {:ok, value}
  rescue
    _ -> {:error, "unavailable"}
  catch
    _, _ -> {:error, "unavailable"}
  end

  defp finish(state, kind, result) do
    now = System.system_time(:millisecond)

    value =
      case result do
        {:ok, value} -> Map.merge(Map.fetch!(state, kind), value) |> Map.put("status", "ok")
        {:error, status} -> Map.put(Map.fetch!(state, kind), "status", status)
      end

    Map.put(state, kind, Map.put(value, "checked_at", now))
  end

  defp publish(state) do
    snapshot =
      Map.merge(state.identity, %{
        "schema_version" => 1,
        "instance_id" => state.id,
        "updated_at" => System.system_time(:millisecond),
        "sequence" => state.sequence + 1,
        "uptime_ms" => max(System.monotonic_time(:millisecond) - state.started, 0),
        "counters" => Map.new(:ets.tab2list(state.table)),
        "beam" => %{
          "memory_bytes" => :erlang.memory(:total),
          "processes" => :erlang.system_info(:process_count)
        },
        "health" => state.health,
        "pool" => state.pool,
        "resources" => state.resources
      })

    result = write_snapshot(state, Jason.encode!(snapshot))

    if result != :ok and not state.write_failed,
      do: IO.puts(:stderr, "Dashboard snapshot unavailable; check private directory permissions")

    %{state | sequence: state.sequence + 1, write_failed: result != :ok}
  end

  defp write_snapshot(state, data) when byte_size(data) <= @limit do
    temporary = state.path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- private_directory(state.directory, state.uid),
           {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
        try do
          with :ok <- File.chmod(temporary, 0o600),
               :ok <- IO.binwrite(file, data),
               :ok <- File.close(file),
               :ok <- File.rename(temporary, state.path),
               do: :ok
        after
          File.close(file)
        end
      end
    after
      File.rm(temporary)
    end
  end

  defp write_snapshot(_, _), do: {:error, :too_large}

  defp uid do
    case System.cmd("/usr/bin/id", ["-u"]) do
      {value, 0} -> {:ok, value |> String.trim() |> String.to_integer()}
      _ -> {:error, :unsupported_platform}
    end
  rescue
    _ -> {:error, :unsupported_platform}
  end

  defp prepare_directory(path, uid) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(path),
             :ok <- File.chmod(path, 0o700),
             do: private_directory(path, uid)

      _ ->
        private_directory(path, uid)
    end
  end

  defp private_directory(path, uid), do: private(path, uid, :directory)

  defp private(path, uid, type) do
    case File.lstat(path) do
      {:ok, %{type: ^type, uid: ^uid, mode: mode}} when (mode &&& 0o077) == 0 -> :ok
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :unsafe_permissions}
    end
  end

  def snapshots(directory) do
    with {:ok, uid} <- uid() do
      case File.lstat(directory) do
        {:error, :enoent} ->
          {:ok, []}

        _ ->
          with :ok <- private_directory(directory, uid), {:ok, names} <- File.ls(directory) do
            names
            |> Enum.filter(&Regex.match?(~r/^[a-f0-9]{24}\.json$/, &1))
            |> Enum.sort()
            |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
              case read_snapshot(Path.join(directory, name), uid) do
                {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
                {:error, :enoent} -> {:cont, {:ok, acc}}
                error -> {:halt, error}
              end
            end)
          end
      end
    end
  end

  defp read_snapshot(path, uid) do
    with :ok <- private(path, uid, :regular),
         {:ok, %{size: size}} when size <= @limit <- File.lstat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        with data when is_binary(data) and byte_size(data) <= @limit <-
               IO.binread(file, @limit + 1),
             {:ok, snapshot} <- Jason.decode(data),
             true <-
               valid?(snapshot) and Path.basename(path) == snapshot["instance_id"] <> ".json" do
          {:ok, Map.take(snapshot, @snapshot_keys)}
        else
          _ -> {:error, :invalid_snapshot}
        end
      after
        File.close(file)
      end
    else
      {:ok, _} -> {:error, :too_large}
      error -> error
    end
  end

  defp valid?(s) when is_map(s) do
    s["schema_version"] == 1 and is_binary(s["instance_id"]) and
      Regex.match?(~r/^[a-f0-9]{24}$/, s["instance_id"]) and
      Enum.all?(~w(started_at updated_at sequence uptime_ms), &nonnegative?(s[&1])) and
      is_binary(s["pid"]) and s["transport"] in ["stdio", "http"] and
      is_map(s["server"]) and Enum.all?(~w(name version), &is_binary(s["server"][&1])) and
      is_map(s["database"]) and s["database"]["dialect"] in ["mysql", "pg"] and
      Enum.all?(
        ~w(host name schema),
        &(is_binary(s["database"][&1]) or is_nil(s["database"][&1]))
      ) and
      Enum.all?(~w(port pool_size), &nonnegative?(s["database"][&1])) and
      Enum.all?(~w(read_only pii), &is_boolean(s["database"][&1])) and
      is_map(s["counters"]) and Enum.sort(Map.keys(s["counters"])) == Enum.sort(@keys) and
      Enum.all?(Map.values(s["counters"]), &nonnegative?/1) and
      is_map(s["beam"]) and Enum.all?(~w(memory_bytes processes), &nonnegative?(s["beam"][&1])) and
      Enum.all?(~w(health pool resources), &valid_sample?(s[&1])) and
      nonnegative?(s["health"]["last_success_at"]) and
      (is_nil(s["health"]["last_success_duration_ms"]) or
         (is_number(s["health"]["last_success_duration_ms"]) and
            s["health"]["last_success_duration_ms"] >= 0)) and
      (s["pool"]["status"] != "ok" or Enum.all?(~w(ready queued), &nonnegative?(s["pool"][&1]))) and
      is_list(s["resources"]["items"]) and length(s["resources"]["items"]) <= 200 and
      nonnegative?(s["resources"]["total"]) and is_boolean(s["resources"]["truncated"]) and
      (is_nil(s["resources"]["sampled_at"]) or nonnegative?(s["resources"]["sampled_at"])) and
      Enum.all?(s["resources"]["items"], fn item ->
        is_map(item) and Map.keys(item) -- @resource_keys == [] and
          Enum.all?(~w(uri name mimeType), &is_binary(item[&1])) and
          (is_nil(item["title"]) or is_binary(item["title"]))
      end)
  end

  defp valid?(_), do: false
  defp nonnegative?(n), do: is_integer(n) and n >= 0

  defp valid_sample?(s),
    do:
      is_map(s) and s["status"] in ~w(ok pending unavailable timeout) and
        (is_nil(s["checked_at"]) or nonnegative?(s["checked_at"]))
end
