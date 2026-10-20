# MCP session benchmarks

[Results from 2026-10-20](session-processes-2026-10-20.json) compare the commits
immediately before (`b542550`) and after (`9646c0a`) supervised MCP sessions,
bounded query workers and buffered stdio were introduced. The root
[README summary](../../README.md#performance-before-and-after-mcp-sessions)
contains the measured medians.

For sustained request rates, concurrency/overload sweeps, laptop specifications
and CPU/memory measurements, see the [local stress test](STRESS.md).

## Workloads

The [Node harness](../../test/benchmark.mjs) uses only the disposable databases
in [`compose.test.yml`](../../compose.test.yml). It starts one server at a time,
initializes one logical client/session, warms up with ten `SELECT 1` requests,
and records five samples of each workload:

- Sequential `SELECT 1 AS value` round trips.
- Four simultaneous `SELECT SLEEP(0.2)` / `SELECT pg_sleep(0.2)` requests.
- A ping submitted 30 ms after starting a 300 ms sleeping query, recording both
  ping latency and response order.
- Pings with 0, 1 KiB, 64 KiB and 256 KiB of ASCII request padding. These measure
  request framing and decoding; the response is small.

Each engine/transport runs before then after. Initialization and build/startup
are excluded from timings. HTTP follows each revision's protocol: the baseline
is stateless; the new server issues a session ID, reused for every request.
The harness validates response IDs, HTTP status, JSON-RPC errors and tool errors,
and stops each server before starting the next. It writes one JSON object per
engine/transport/revision to stdout; progress goes to stderr.

Both builds use the same locked dependencies and pool size 10, with dashboard
and PII redaction disabled. The new session permits four simultaneous workers.
The recorded environment includes database/runtime versions, source revisions,
fixture and harness hashes, all individual samples and their medians.

These are local latency microbenchmarks. Sleep queries isolate serialization and
worker scheduling; they do not measure real SQL throughput. Five samples are
insufficient for tail latency or statistical significance. Memory, CPU usage,
sustained load, multiple sessions, overload, production data and network/TLS
behavior were not benchmarked. Improvements include the entire commit; the large
input improvement comes from buffering, not from creating a GenServer alone.

## Reproduce

Requires the repository's pinned Erlang/Elixir, Node and Docker. Run from the
repository root. This creates isolated source/build directories without changing
the working tree. Dependency downloads and builds happen before measurements.
Use fixture ports 13307/15433 and MCP ports 13107/13108 only when available.
The command owns and removes the disposable Compose fixtures on exit.

```sh
(
  set -eu
  benchmark_dir=$(mktemp -d)
  trap 'docker compose -f compose.test.yml down; rm -rf "$benchmark_dir"' EXIT
  for version in before after; do
    case "$version" in
      before) revision=b5425502b4172986382f59af8ef069ef530a1e58 ;;
      after) revision=9646c0a337eadeb2ab84b19bd175874a8559f0c9 ;;
    esac
    mkdir "$benchmark_dir/$version"
    git archive "$revision" .tool-versions mcp-ex-core mcp-ex-mysql mcp-ex-pg > "$benchmark_dir/source.tar"
    tar -xf "$benchmark_dir/source.tar" -C "$benchmark_dir/$version"
    for app in mcp-ex-core mcp-ex-mysql mcp-ex-pg; do
      (cd "$benchmark_dir/$version/$app" && MIX_ENV=dev mix deps.get)
    done
    for app in mcp-ex-mysql mcp-ex-pg; do
      (cd "$benchmark_dir/$version/$app" && MIX_ENV=dev mix escript.build)
    done
  done
  docker compose -f compose.test.yml up -d --wait
  node test/benchmark.mjs "$benchmark_dir/before" "$benchmark_dir/after" > benchmark-results.jsonl
)
```

For the recorded run, existing dependency source caches were copied into the
isolated directories instead of downloaded. No compiled `_build` directories or
escripts were reused. Docker image tags may resolve to newer database releases
on future runs; compare the exact versions recorded in the result artifact.
