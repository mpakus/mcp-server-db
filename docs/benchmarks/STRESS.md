# Local throughput stress test

For the subsequent output batching and request-ID indexing change, see the
[fresh stdio/HTTP comparison](STDIO.md). The results below preserve the original
measurement before that optimization.

The 2026-10-20 run measures completed MCP SQL tool calls on this laptop, using
the server code at `d69485f1788dea160f233f706c20588b0f95460a`. No application code
or persisted server settings were changed. The [root README](../../README.md)
summarizes the results. [Raw results](stress-2026-10-20.json) retain every phase,
latency histogram, per-second success count, resource sample summary, environment,
dependency version and source/build hash.

## Results

The final campaign completed 82 measured phases with **6,740,570 validated
successful responses**, **1,202,096 separately counted busy replies**, and **zero
unexpected query/protocol/result errors**. Deliberate over-cap sweeps account
for most busy replies. PostgreSQL HTTP's 94-concurrency candidate produced one
busy reply during confirmation and was rejected; 92 passed the complete check.
The selected settings below completed 3,645,110 requests without any busy replies
or errors across their twelve confirmation runs.

| Server / transport | Pool / per-session limit | Concurrency | Median RPS | 30-second RPS range | p50 / p95 / p99 (ms) |
| --- | ---: | ---: | ---: | --- | --- |
| MySQL / stdio | 128 / 128 | 124 | 9,003 | 8,527–9,080 | 13.75 / 17.35 / 20.10 |
| MySQL / HTTP | 128 / 128 | 124 | 12,963 | 12,919–12,985 | 9.35 / 12.65 / 15.60 |
| PostgreSQL / stdio | 96 / 96 | 88 | 8,399 | 8,359–8,432 | 10.25 / 13.45 / 15.80 |
| PostgreSQL / HTTP | 96 / 96 | 92 | 10,221 | 10,189–10,399 | 8.75 / 11.60 / 14.15 |

The server's CPU is an average over the selected confirmation windows; RSS is
the highest sampled value across those windows. 100% CPU equals one core.
Generator CPU covers the Node process including its worker threads; utilization
is the busiest generator event loop observed across the confirmations.

| Server / transport | BEAM CPU | BEAM sampled peak RSS (MiB) | Generator CPU | Busiest generator event loop |
| --- | ---: | ---: | ---: | ---: |
| MySQL / stdio | 555.44% | 159.92 | 24.76% | 33% |
| MySQL / HTTP | 542.20% | 192.27 | 69.44% | 22% |
| PostgreSQL / stdio | 569.02% | 147.92 | 23.72% | 32% |
| PostgreSQL / HTTP | 546.03% | 168.67 | 60.50% | 20% |

The generator had substantial headroom at the selected settings. These metrics
do not isolate whether the server, Docker networking or database is the ultimate
bottleneck, and they do not include database/VM CPU or memory.

| Server / transport | Best default-limit sweep RPS (5 s) | Default concurrency | Lookup RPS at selected settings (15 s) | Lookup p99 (ms) |
| --- | ---: | ---: | ---: | ---: |
| MySQL / stdio | 2,685 | 4 | 8,820 | 20.00 |
| MySQL / HTTP | 3,684 | 8 | 12,646 | 16.25 |
| PostgreSQL / stdio | 2,324 | 4 | 8,174 | 16.15 |
| PostgreSQL / HTTP | 3,187 | 8 | 10,154 | 13.65 |

Default-limit values are exploratory five-second samples, not independently
confirmed 90-second capacity figures. The lookup is a bound read from a one-row,
in-memory fixture, not a representative production dataset. Startup, session
initialization and warm-up are excluded from all throughput figures.

## Machine and software

| Component | Recorded value |
| --- | --- |
| Laptop | MacBook Pro, model `Mac17,6`, connected to AC power |
| Chip | Apple M5 Max, arm64, 18 physical/logical CPU cores |
| CPU groups reported by macOS | 6 Super cores and 12 Performance cores |
| Memory | 64 GiB unified memory |
| GPU | Apple M5 Max, 40 cores, Metal 4; unused by this test |
| SSD | APPLE SSD AP2048Z, 2 TB; database fixtures use tmpfs |
| OS | macOS 27.0.1, build 26A434 |
| Elixir | 1.20.4, compiled for OTP 28 |
| Erlang/OTP | 28.5, ERTS 16.4, JIT, 18 online schedulers |
| MySQL | 8.4.11, Docker image `mysql:8.4` |
| PostgreSQL | 16.15, aarch64, Docker image `postgres:16-alpine` |
| Docker | Desktop 4.92.0; Engine 29.8.0; LinuxKit 7.0.12 |
| Docker VM allocation | 18 CPUs, 8,317,267,968 bytes RAM (about 7.75 GiB) |
| Load generator | Node.js 26.8.2; no additional packages |
| Drivers | MyXQL 0.9.0, Postgrex 0.22.4, DBConnection 2.10.2 |
| HTTP stack | Bandit 1.13.1, Plug 1.20.3 |

Hardware details are filtered to benchmark-relevant properties. Machine serial
numbers, hardware UUIDs, hostnames and network identifiers are not recorded.

## Method

The [harness](../../test/stress.mjs) starts one MCP server process at a time,
against the disposable [`compose.test.yml`](../../compose.test.yml) databases.
Both databases remain running; only the selected database receives load.
Escripts are built with `MIX_ENV=dev`, matching the documented build procedure.
Dashboard and PII redaction are disabled. HTTP uses authenticated HTTP/1.1
keep-alive over loopback without TLS. Database connections use TCP through
Docker's loopback port mapping.

1. Initialize sessions and warm up for two seconds.
2. Sweep the default configuration (pool 10, per-session limit 4) at 1, 4, 8 and
   16 outstanding requests, five seconds per level.
3. Sweep a temporary expanded configuration, five seconds per level. MySQL uses
   pool/per-session limit 128 and concurrency 1, 4, 8, 16, 32, 64, 80, 96, 112,
   124, 128 and 256. PostgreSQL uses pool/per-session limit 96 and concurrency
   1, 4, 8, 16, 32, 64, 80, 88, 92, 94, 96 and 192. Existing database connection
   limits remain unchanged: MySQL 151 and PostgreSQL 100.
4. Choose the highest successful RPS among levels with zero errors and zero
   overload rejections, below the global worker/pool cap to leave headroom.
   Restart that configuration, warm up, and confirm it in three consecutive
   30-second runs. A busy response rejects the candidate and tries the next best
   eligible setting; a query/result validation error fails the harness.
5. At the same settings, run a 15-second bound primary-key lookup against the
   fixture's one-row `users` table. Check that the returned ID and label match.

An initial pool-64 MySQL stdio run reached about 8,700 successful RPS, but its
second 30-second full-cap confirmation returned one busy response. That sample
is retained as exploratory evidence. Further pool-64 probes showed rising
throughput without saturating the client, motivating the wider final sweep.
The headline results use the final campaign and leave worker headroom.

Stdio uses one session and one generator thread. HTTP uses four sessions and
four Node worker threads, with total concurrency divided evenly among them.
The reported concurrency is the total across all sessions, not per session.
Each client lane sends its next request after the previous response. This is
a closed-loop test, not a fixed arrival-rate/open-loop test. Busy requests are
counted separately and are not retried; the lane immediately submits its next
new request. Consequently overload sweeps can produce many cheap rejections.

The main workload is `SELECT 1 AS value`. Every successful response must contain
exactly one row with value 1. The lookup is `SELECT id, label FROM users WHERE
id = ?` for MySQL and `$1` for PostgreSQL, bound to 1. These calls include MCP
decoding, SQL policy, task/session messaging, pool checkout, the database's
read-only transaction and rollback, result encoding and client validation.
One MCP request includes multiple database wire operations; RPS is not raw SQL
statements per second. No writes or application databases are involved.

## Metrics and interpretation

- **Successful RPS:** validated successful responses divided by actual phase
  elapsed time, including draining the last in-flight requests. Startup,
  initialization and warm-up are excluded. Rejections and errors never count.
- **Confirmed throughput:** median RPS of the three confirmation runs. Their
  individual range shows short-run variability. This is the highest tested
  error-free configuration selected by the sweep, not a proven hardware maximum.
- **Latency:** successful request round trips, including client result validation.
  Histograms use 0.05 ms upper-bound buckets; p50/p95/p99 use nearest ranks.
  Percentiles combine requests, not averages of per-worker percentiles.
- **Server CPU:** change in the BEAM process's cumulative CPU time from `ps`,
  divided by wall time. 100% means one CPU core. Database/VM CPU is excluded.
- **Server memory:** highest RSS observed at phase start/end and one-second
  intervals. This is sampled process RSS, not a guaranteed instantaneous peak
  or total memory of the server plus database.
- **Generator:** process CPU/RSS, worker event-loop utilization and p99 event-loop
  delay are recorded to help identify client limits. Idle workers report null.
- **Per-second counts:** the last bin can be a partial second caused by drain;
  do not interpret that partial bin as a throughput collapse.

The read-only fixture is tiny and hot in memory. This does not establish capacity
for large results, complex SQL, writes, disk-bound data, production networks,
TLS, PII filtering, dashboards or thousands of sessions. Latencies describe the
closed-loop workload and can understate queueing under an external fixed arrival
rate. The laptop runs the client, BEAM and Docker together; other applications,
power/thermal conditions and Docker allocation can change results. The run does
not isolate the ultimate bottleneck or exhaust every pool/scheduler setting.

## Reproduce

Use the pinned Erlang/Elixir from `.tool-versions`, Node and Docker. Fetch Mix
dependencies as described in the root README first. Run from the repository root
with fixture ports 13307/15433 and MCP ports 13107/13108 available. This command
owns and removes the disposable Compose fixtures on exit. Allow roughly twelve
to fifteen minutes for the full run, plus builds and database startup.

```sh
(
  set -eu
  trap 'docker compose -f compose.test.yml down' EXIT
  (cd mcp-ex-mysql && MIX_ENV=dev mix escript.build)
  (cd mcp-ex-pg && MIX_ENV=dev mix escript.build)
  docker compose -f compose.test.yml up -d --wait
  STRESS_SMOKE=true node test/stress.mjs > stress-smoke.jsonl
  node test/stress.mjs > stress-results.jsonl
)
```

For a focused rerun, set `STRESS_APPS=mysql` or `STRESS_APPS=pg` and/or
`STRESS_TRANSPORTS=stdio` or `STRESS_TRANSPORTS=http`. Progress goes to stderr;
stdout contains one JSON record per measured phase. The raw artifact records
the exact image digests because Docker tags may change on a future run.
