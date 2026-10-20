# Stdio throughput optimization

This comparison measures baseline `ffce357` against the working tree changes to
`McpEx.Stdio` and `McpEx.Session` on 2026-10-20. Stdio already had one supervised
session GenServer and bounded concurrent query workers before this change.

The writer now combines responses already waiting in its mailbox into one
`IO.binwrite` call. It does not wait for more responses, and stops collecting at
64 messages or once 64 KiB is reached (one response can exceed that threshold).
The session also maps active request IDs to worker monitor references, avoiding a
scan of all workers on duplicate-ID checks and cancellation. The index is removed
on completion, cancellation, timeout and failure. Both transports use this index.

One logical stdio session, one stdout writer, synchronous admission acknowledgements,
request/response limits, supervision, deadlines and EOF draining are preserved.
There is no new setting, dependency or default pool/concurrency increase.

## Results

The campaign completed **72 measured phases** with **11,268,662 validated
successful responses**, **zero unexpected errors**, and **300,374 busy replies**
confined to the four deliberate overload phases. All 30 confirmations
completed **9,427,093 successful responses without busy replies or errors**.
Every default/sweep/lookup phase outside overload also had zero busy/errors.
The [raw artifact](stdio-2026-10-20.json) includes every phase, histogram,
per-second count, resource measurement, environment version and source/build hash.

| Engine | Build / transport / sessions | Median RPS | Run range (RPS) | p50 / p95 / p99 (ms) | BEAM CPU (cores) | Peak RSS (MiB) |
| --- | --- | ---: | --- | --- | ---: | ---: |
| MySQL | before / stdio / 1 | 8,726.54 | 8,651.70–8,750.91 | 14.05 / 17.60 / 20.40 | 5.98 | 160.92 |
| MySQL | after / stdio / 1 | 12,754.74 | 12,752.26–12,924.74 | 9.45 / 12.80 / 16.25 | 5.14 | 166.75 |
| MySQL | before / http / 4 | 12,426.25 | 12,405.19–12,598.10 | 9.70 / 13.05 / 16.10 | 5.58 | 195.83 |
| MySQL | after / http / 4 | 12,173.90 | 12,101.38–12,548.23 | 9.80 / 13.35 / 18.45 | 5.45 | 193.48 |
| MySQL | after / http / 1 | 12,295.88 | 12,208.22–12,522.76 | 9.80 / 13.20 / 16.75 | 5.63 | 191.73 |
| PostgreSQL | before / stdio / 1 | 8,031.31 | 7,995.02–8,082.70 | 10.75 / 14.00 / 16.30 | 5.97 | 140.86 |
| PostgreSQL | after / stdio / 1 | 9,581.55 | 9,555.92–9,584.53 | 9.00 / 11.80 / 15.15 | 5.41 | 148.09 |
| PostgreSQL | before / http / 4 | 9,513.71 | 9,469.64–9,545.27 | 9.05 / 11.95 / 15.20 | 5.65 | 165.17 |
| PostgreSQL | after / http / 4 | 9,486.65 | 9,392.20–9,494.65 | 9.10 / 12.00 / 15.00 | 5.70 | 165.53 |
| PostgreSQL | after / http / 1 | 9,512.91 | 9,496.57–9,578.38 | 9.00 / 11.95 / 15.00 | 5.69 | 167.67 |

MySQL stdio improved **46.2%** at the fixed concurrency. Four-session
HTTP's median changed **-2.0%**; the individual ranges above show run
variability. The ten-second bound lookup measured 8,510.58 →
12,391.35 RPS for stdio before → after.

PostgreSQL stdio improved **19.3%** at the fixed concurrency. Four-session
HTTP's median changed **-0.3%**; the individual ranges above show run
variability. The ten-second bound lookup measured 7,752.08 →
9,608.07 RPS for stdio before → after.

The optimized single-session stdio rates are close to the HTTP controls. The
existing session design reaches those rates after reducing transport/session
overhead. The measurements apply to the combined
batching/index change; no separate ablation or per-process CPU profile was run.
Three samples do not establish statistical significance for small HTTP changes.

The machine/runtime/database setup matches the original stress inventory:
Apple M5 Max, 18 CPU cores, 64 GiB RAM, macOS 27.0.1, Elixir 1.20.4,
OTP 28.5 / ERTS 16.4, MySQL 8.4.11, PostgreSQL 16.15, Node 26.8.2 and
Docker Engine 29.8.0. Docker has 18 CPUs and approximately 7.75 GiB RAM.
Source changes are identified by their SHA-256 hashes in the raw artifact;
the baseline is `ffce35793ef3ee6b6190bfc760a0f8d87d05cc29`.

## Method

The [comparison harness](../../test/stdio-benchmark.mjs) reuses the
[stress client and measurement code](../../test/stress.mjs). It starts only one
MCP server/load run at a time against disposable Compose fixtures. Preserved
baseline escripts and current escripts use the same dependencies and databases.
Initialization and two seconds of warm-up are excluded from each measurement.

- Each stdio build gets a five-second default-settings check at concurrency 4,
  five-second expanded-pool sweeps at concurrency 1, 4, 16, 32, 64 and the fixed
  comparison concurrency, then three seconds at twice pool capacity to exercise
  overload rejection.
- MySQL uses pool/per-session limit 128 and comparison concurrency 124.
  PostgreSQL uses pool/per-session limit 96 and comparison concurrency 88.
  These settings are fixed for both builds and both transports; this comparison
  does not reselect a different best concurrency for each variant.
- Before/after stdio and before/after four-session HTTP each receive three
  30-second confirmations. New HTTP also receives three confirmations using
  one session. Each session has one load-generator thread: the one-session
  HTTP control matches stdio's session/thread counts.
- Runs alternate forward/reverse/forward variant order to reduce ordering bias.
  Servers restart between confirmation rounds. Each variant also gets a
  ten-second bound lookup after its third confirmation.
- Every successful response is checked for matching JSON-RPC ID and correct row
  data. Busy responses are counted separately; any busy response outside an
  intentional overload phase invalidates the run. Unexpected errors stop it.

The primary workload is `SELECT 1 AS value` through SQL policy, a read-only
database transaction, result encoding and client validation. The secondary
workload binds ID 1 in the fixture's one-row `users` table. Dashboard and PII
redaction are disabled; local HTTP/database connections have no TLS.

RPS is successful completions divided by measured wall time, including drain.
Headline rates use the median of three confirmations, with ranges shown for
run variability. Latency percentiles merge all three successful-response
histograms (0.05 ms upper-bound buckets). CPU 100% means one core; BEAM CPU/RSS
exclude the database and Docker VM. Memory is sampled, not an instantaneous peak.

## Reproduce

Run from the repository root with the pinned Erlang/Elixir, Node and Docker.
Allow about twenty minutes plus dependency/build time. This command creates and
removes the disposable Compose fixtures; fixture ports 13307/15433 and MCP ports
13107/13108 must be available. It preserves the working tree and builds an
isolated baseline from Git.

```sh
(
  set -eu
  benchmark_dir=$(mktemp -d)
  trap 'docker compose -f compose.test.yml down; rm -rf "$benchmark_dir"' EXIT
  mkdir "$benchmark_dir/source" "$benchmark_dir/before"
  git archive ffce35793ef3ee6b6190bfc760a0f8d87d05cc29 \
    .tool-versions mcp-ex-core mcp-ex-mysql mcp-ex-pg > "$benchmark_dir/source.tar"
  tar -xf "$benchmark_dir/source.tar" -C "$benchmark_dir/source"
  for app in mcp-ex-core mcp-ex-mysql mcp-ex-pg; do
    (cd "$benchmark_dir/source/$app" && MIX_ENV=dev mix deps.get)
  done
  for app in mcp-ex-mysql mcp-ex-pg; do
    (cd "$benchmark_dir/source/$app" && MIX_ENV=dev mix escript.build)
    cp "$benchmark_dir/source/$app/$app" "$benchmark_dir/before/$app"
    (cd "$app" && MIX_ENV=dev mix escript.build)
  done
  docker compose -f compose.test.yml up -d --wait
  BENCH_BEFORE_DIR="$benchmark_dir/before" BENCH_SMOKE=true \
    node test/stdio-benchmark.mjs > stdio-smoke.jsonl
  BENCH_BEFORE_DIR="$benchmark_dir/before" \
    node test/stdio-benchmark.mjs > stdio-comparison.jsonl
)
```

Set `BENCH_APPS=mysql` or `BENCH_APPS=pg` for one engine. Progress goes to stderr;
stdout contains one JSON result per phase. Docker tags can change: compare exact
image digests and versions in the saved artifact before comparing future runs.

## Limits

`MCP_INTEGRATION=true rtk proxy ./bin/check` passed 39 ExUnit tests, both escript
builds and the SDK/dashboard/raw transport checks for both databases. Regression
coverage includes typed request IDs, ID reuse after all completion paths,
cancellation, responsive pings, fragmented UTF-8, frame/response limits,
pipelined initialization, a 300-response burst, a 128 KiB result and EOF drain.
The benchmark's 32-phase smoke test also passed before the measured campaign.

These closed-loop, tiny hot reads measure observed local capacity at fixed
settings, not a proven hardware maximum or production capacity. The two changes
are measured together; they do not establish each change's individual share of
the gain. One versus four HTTP sessions also changes generator thread count, so
that control does not isolate session count alone. The laptop runs the generator,
BEAM and Docker together. Background load, power and thermal state can change
results; large result sets, TLS, real production SQL and long soak behavior need
separate measurements. See the [original stress methodology](STRESS.md) for
closed-loop latency and resource-sampling caveats.
