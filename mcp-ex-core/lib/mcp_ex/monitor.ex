defmodule McpEx.Monitor do
  @moduledoc "Separate status/resources viewer; reads snapshots without starting a database pool."
  alias McpEx.Diagnostics

  def run(command, args, dialect) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [instance: :string, json: :boolean, watch: :boolean]
      )

    if rest != [] or invalid != [],
      do: raise(ArgumentError, "Use #{command} [--instance ID] [--json] [--watch]")

    watch(command, opts, dialect, %{})
  rescue
    error in ArgumentError ->
      IO.puts(:stderr, Exception.message(error))
      2

    _ ->
      IO.puts(
        :stderr,
        "Unable to read dashboard snapshots: check schema, size, ownership and private permissions"
      )

      2
  end

  def inspect_instances(
        directory,
        dialect,
        instance \\ nil,
        now \\ System.system_time(:millisecond)
      ) do
    with {:ok, snapshots} <- Diagnostics.snapshots(directory, instance) do
      instances =
        snapshots
        |> Enum.filter(&(&1["database"]["dialect"] == to_string(dialect)))
        |> Enum.filter(&(is_nil(instance) or &1["instance_id"] == instance))
        |> Enum.sort_by(& &1["instance_id"])
        |> Enum.map(&describe(&1, now))

      {:ok, instances}
    end
  end

  defp watch(command, opts, dialect, previous) do
    {:ok, instances} = inspect_instances(Diagnostics.directory(), dialect, opts[:instance])

    if command == "resources" and length(instances) > 1,
      do: raise(ArgumentError, "Several instances found; select resources --instance ID")

    instances = Enum.map(instances, &rate(&1, previous))
    json = opts[:json] == true
    if opts[:watch] == true and not json and terminal?(), do: IO.write("\e[H\e[2J")

    if json do
      IO.puts(Jason.encode!(%{"schema_version" => 1, "instances" => instances}))
    else
      IO.puts(render(command, instances))
    end

    if opts[:watch] do
      Process.sleep(2000)
      watch(command, opts, dialect, Map.new(instances, &{&1["instance_id"], &1}))
    else
      if instances != [] and Enum.all?(instances, &(&1["state"] == "healthy")), do: 0, else: 1
    end
  end

  defp describe(s, now) do
    age = age(now, s["updated_at"])
    fresh = not is_nil(age) and age <= 10_000
    health_age = age(now, s["health"]["checked_at"])
    health_ok = s["health"]["status"] == "ok" and not is_nil(health_age) and health_age <= 90_000
    pool_age = age(now, s["pool"]["checked_at"])
    resources_age = age(now, s["resources"]["sampled_at"])

    state =
      cond do
        is_nil(age) -> "unknown"
        not fresh -> "stale"
        not health_ok -> "degraded"
        true -> "healthy"
      end

    tools = s["counters"]["tools"]

    Map.merge(s, %{
      "state" => state,
      "snapshot_age_ms" => age,
      "health_age_ms" => health_age,
      "health_last_success_age_ms" => age(now, s["health"]["last_success_at"]),
      "pool_age_ms" => pool_age,
      "resources_age_ms" => resources_age,
      "tool_avg_ms" =>
        if(tools > 0, do: s["counters"]["tool_duration_us"] / tools / 1000, else: nil),
      "tool_max_ms" => if(tools > 0, do: s["counters"]["tool_max_us"] / 1000, else: nil)
    })
  end

  defp age(now, then) when is_integer(then) and then <= now, do: now - then
  defp age(_, _), do: nil

  defp rate(s, previous) do
    old = previous[s["instance_id"]]
    elapsed = if old, do: s["uptime_ms"] - old["uptime_ms"], else: 0
    count = attempts(s)
    delta = if old, do: count - attempts(old), else: -1
    value = if elapsed > 0 and delta >= 0, do: Float.round(delta * 1000 / elapsed, 2), else: nil
    Map.put(s, "queries_per_second", value)
  end

  defp attempts(s),
    do: Enum.sum(for mode <- ~w(read write ddl), do: s["counters"]["queries_" <> mode])

  def render(command, instances) do
    heading = "MCP EX / #{String.upcase(command)}   #{DateTime.to_iso8601(DateTime.utc_now())}"

    cards =
      if instances == [],
        do: ["No instances found. Enable MCP_DASHBOARD=true on the server."],
        else: Enum.map(instances, &card(command, &1))

    Enum.join([heading, String.duplicate("=", 88) | cards], "\n")
  end

  defp card(command, s) do
    db = s["database"]
    c = s["counters"]
    resources = s["resources"]

    base = [
      "#{clean(s["server"]["name"])} #{clean(s["server"]["version"])}  [#{String.upcase(s["state"])}]  #{clean(s["transport"])}  PID #{clean(s["pid"])}",
      "Instance #{s["instance_id"]}   uptime #{seconds(s["uptime_ms"])}   snapshot #{seconds(s["snapshot_age_ms"])} ago",
      "Database #{clean(db["host"])}:#{db["port"]}/#{clean(db["name"])}  schema #{clean(db["schema"])}  #{if db["read_only"], do: "READ ONLY", else: "WRITES ENABLED"}  PII #{if db["pii"], do: "on", else: "off"}",
      "Health #{s["health"]["status"]} (#{seconds(s["health_age_ms"])} ago)   Pool #{pool(s)} (#{seconds(s["pool_age_ms"])} ago)",
      "RPC #{c["requests"]} requests / #{c["rpc_errors"]} errors / #{c["notifications"]} notifications",
      "Tools #{c["tools"]} completed / #{c["tool_success"]} ok / #{c["tool_failed"]} failed   latency avg #{ms(s["tool_avg_ms"])} / max #{ms(s["tool_max_ms"])}",
      "Failures validation #{c["validation_errors"]} / policy #{c["policy_rejections"]} / database #{c["database_failures"]} / processing #{c["processing_failures"]}",
      "Query attempts read #{c["queries_read"]} / write #{c["queries_write"]} / ddl #{c["queries_ddl"]}   rate #{rate_text(s["queries_per_second"])}",
      "Transport parse #{c["parse_errors"]} / oversized #{c["oversize_errors"]}   HTTP rejected #{http_rejected(c)}",
      "BEAM #{Float.round(s["beam"]["memory_bytes"] / 1_048_576, 1)} MiB / #{s["beam"]["processes"]} processes",
      "Resources #{resources["total"]} / #{resources["status"]} / sampled #{seconds(s["resources_age_ms"])} ago#{if resources["truncated"], do: " (first 200 retained)", else: ""}"
    ]

    entries =
      if command == "resources", do: resources["items"], else: Enum.take(resources["items"], 5)

    lines = Enum.map(entries, &"  #{clean(&1["title"] || &1["name"])}  #{clean(&1["uri"])}")
    Enum.join(base ++ lines ++ [String.duplicate("-", 88)], "\n")
  end

  defp pool(s) do
    p = s["pool"]

    if p["status"] == "ok",
      do: "#{p["ready"]}/#{s["database"]["pool_size"]} ready, #{p["queued"]} queued",
      else: p["status"]
  end

  defp http_rejected(c),
    do: Enum.sum(for code <- [400, 401, 403, 404, 405, 406, 413, 415], do: c["http.#{code}"])

  defp clean(nil), do: "(all)"
  defp clean(s), do: s |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, "?") |> String.slice(0, 160)
  defp seconds(nil), do: "unknown"
  defp seconds(n), do: "#{Float.round(n / 1000, 1)}s"
  defp ms(nil), do: "--"
  defp ms(n), do: "#{Float.round(n, 2)}ms"
  defp rate_text(nil), do: "-- (watch for rate)"
  defp rate_text(n), do: "#{n}/s"
  defp terminal?, do: match?({:ok, _}, :io.columns()) and System.get_env("TERM") != "dumb"
end
