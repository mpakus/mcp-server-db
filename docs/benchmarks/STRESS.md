# Current four-mode stress benchmark

Measured on 2026-10-20 from server commit `ae54325`, with the benchmark harness
changes recorded by hash in [the raw results](stress-2026-10-20.json). This is
the current comparison for both MySQL and PostgreSQL; it supersedes the earlier
session, stdio-optimization and cache-only result tables.

## Results

| Engine | stdio RPS | HTTP RPS | stdio + cache RPS | HTTP + cache RPS |
| --- | ---: | ---: | ---: | ---: |
| MySQL | **9,210** | **9,192** | **63,938** | **88,063** |
| PostgreSQL | **7,948** | **7,982** | **63,793** | **87,865** |

All **64 measured phases** completed **23,155,439 validated responses**, with
**zero errors and zero busy replies**. The 24 confirmation runs account for
20,078,333 responses. Values above are medians of three 20-second samples per
engine/mode; percentiles below merge the same samples.

| Engine / mode | RPS range | p50 / p95 / p99 (ms) | Hit rate | SQL read executions/sec |
| --- | --- | --- | ---: | ---: |
| MySQL / stdio | 9,207–9,222 | 6.80 / 8.95 / 10.70 | — | 9,213.13 |
| MySQL / HTTP | 9,177–9,272 | 6.80 / 9.00 / 11.55 | — | 9,213.47 |
| MySQL / stdio + cache | 63,236–64,822 | 1.00 / 1.35 / 1.70 | 99.980% | 12.80 |
| MySQL / HTTP + cache | 86,620–88,742 | 0.75 / 0.95 / 1.05 | 99.985% | 12.80 |
| PostgreSQL / stdio | 7,942–8,017 | 7.90 / 10.20 / 12.35 | — | 7,969.04 |
| PostgreSQL / HTTP | 7,962–8,005 | 7.90 / 10.20 / 11.95 | — | 7,983.24 |
| PostgreSQL / stdio + cache | 55,680–64,030 | 1.00 / 1.45 / 1.70 | 99.979% | 12.80 |
| PostgreSQL / HTTP + cache | 84,927–88,999 | 0.75 / 0.95 / 1.05 | 99.985% | 12.80 |

| Engine / mode | Server CPU | Server peak RSS (MiB) | Generator CPU | Busiest generator event loop |
| --- | ---: | ---: | ---: | ---: |
| MySQL / stdio | 540.61% | 166.66 | 15.28% | 19% |
| MySQL / HTTP | 536.76% | 184.66 | 63.79% | 19% |
| MySQL / stdio + cache | 260.14% | 140.94 | 17.63% | 17% |
| MySQL / HTTP + cache | 1088.01% | 161.36 | 301.08% | 82% |
| PostgreSQL / stdio | 554.70% | 138.88 | 15.03% | 18% |
| PostgreSQL / HTTP | 565.09% | 152.36 | 59.41% | 17% |
| PostgreSQL / stdio + cache | 233.29% | 123.20 | 14.42% | 16% |
| PostgreSQL / HTTP + cache | 1118.19% | 134.34 | 298.84% | 82% |

CPU figures average the confirmation windows; 100% CPU is one core. RSS is the
highest sampled process value across those windows. Database/VM resources are
excluded. Cached headline RPS mostly reuses payloads; compare the SQL-read column
when assessing database load.

### Cold-cache and opt-out probes

| Engine / transport | All-miss cache RPS | Enabled cache, no opt-in RPS |
| --- | ---: | ---: |
| MySQL / stdio | 8,570 | 9,138 |
| MySQL / HTTP | 8,408 | 9,355 |
| PostgreSQL / stdio | 7,731 | 7,943 |
| PostgreSQL / HTTP | 7,457 | 7,924 |

These are single ten-second samples. Cold calls all missed; calls without opt-in
returned no cache metadata. Their SQL/payload differences and short duration do
not establish an isolated overhead percentage.

## Configuration and workload

| Mode | Transport | Server cache | Tool argument | Sessions / generator threads |
| --- | --- | --- | --- | --- |
| stdio | Newline-delimited JSON-RPC over pipes | Disabled | `cache` omitted | 1 / 1 |
| HTTP | Authenticated HTTP/1.1 keep-alive | Disabled | `cache` omitted | 4 / 4 |
| stdio + cache | Same stdio transport | Enabled | `cache: true` | 1 / 1 |
| HTTP + cache | Same HTTP transport | Enabled | `cache: true` | 4 / 4 |

All four modes use `SELECT id, label FROM users WHERE id = ?` (PostgreSQL `$1`),
bound to 1, against the same tiny disposable fixture. Every successful response
must have its expected JSON-RPC ID, exactly one row, ID 1 and label `sample`.
Policy, session tasks, transport, encoding and client validation are included.
Uncached calls execute a native read-only transaction and rollback. Cache hits
reuse the final JSON payload and avoid those database operations.

Total confirmation concurrency is **64** in every mode. MySQL pool/global worker
cap/per-session limit is 128; PostgreSQL is 96. HTTP divides the 64 requests
among four sessions, while stdio uses one. These are temporary benchmark
settings, not application defaults (pool 10, per-session limit 4).

Cache settings are explicitly fixed at TTL **5000 ms**, **1000 entries** and
**65536 payload bytes per entry**. Hits do not extend TTL. Warmed cache runs still
refresh during each 20-second confirmation, and simultaneous misses can execute
duplicate SQL. The measured hit/miss counts are retained in the raw artifact.

The client, server and Docker databases share one laptop. One MCP server runs
at a time; both fixture databases remain running. Dashboard and PII are disabled
for timing. HTTP uses loopback without TLS; database TCP uses Docker's loopback
port mapping. No application databases or writes are used by this benchmark.

## Method

The [four-mode harness](../../test/cache-benchmark.mjs) reuses the transport and
metric implementation in [stress.mjs](../../test/stress.mjs):

1. Build both escripts with `MIX_ENV=dev`, start disposable fixtures, and run the
   smoke check to exercise every mode and probe.
2. For each engine/mode, warm for two seconds and sweep concurrency 1, 4, 16 and
   64 for three seconds each. These exploratory samples are not headline rates.
3. Confirm each mode in three independent 20-second runs at concurrency 64, with
   a fresh server and two-second warm-up for each run. Interleave all four modes
   within each round and reverse their order in the next round.
4. Run ten-second probes per engine/transport: unique-key cache misses (`cold`)
   and enabled cache with `cache` omitted (`bypass`). The cold probe varies a
   second bound predicate that preserves the row and uses a fresh per-generator
   SQL comment. It exercises admission, capacity and expiration without hits.
5. Validate every response. Any busy reply or query/protocol/result error fails
   this comparison. Cache runs require at least 95% hits; cold probes require
   every successful response to be a miss. Uncached responses must have no cache
   metadata.

The fixed 64-request setting makes the four modes comparable. This run does
not select a separate best concurrency for each mode or test overload, and it
does not establish an absolute maximum RPS. The older standalone `stress.mjs`
sweep remains available for exploring pool limits and deliberate overload, but
its `SELECT 1` workload produces a different experiment.

## Metrics and interpretation

- **RPS:** validated successful responses divided by actual elapsed time,
  including draining the final requests. Startup, initialization and warm-up
  are excluded. The headline is the median of the three confirmations.
- **Latency:** successful round trips, including result validation. p50/p95/p99
  merge all three 0.05 ms upper-bound histograms, rather than averaging percentiles.
- **CPU:** BEAM process CPU time from `ps`, divided by wall time; 100% is one
  core. Generator CPU includes its Node worker threads. Database/VM CPU is excluded.
- **Memory:** highest process RSS sampled at start/end and one-second intervals;
  this is not an instantaneous peak or total server-plus-database memory.
- **Cache:** hit percentages and SQL read execution rates derive from validated
  `result._meta.cache` statuses (or successful uncached responses). These count
  read executions, not transaction-control statements or database-side telemetry.
  High cached RPS is mostly payload reuse, not improved database execution capacity.
- **Load shape:** closed-loop clients issue their next request after a response.
  This can understate queueing compared with an external fixed arrival rate.
  A partial final per-second bin includes request drain, not a throughput collapse.

HTTP uses four sessions/generator threads while stdio uses one, so cross-transport
figures do not isolate transport overhead alone. Generator utilization and CPU
are included to show potential client limits. The one-row hot fixture does not
represent large results, expensive SQL, writes, production networks, TLS, PII,
dashboard overhead or thousands of sessions. Cold/bypass probes are single short
samples and cannot establish small regressions statistically; cold SQL also has
an extra predicate/parameter. A one-key hot cache does not measure full-cache
memory usage. Power, temperature and other laptop workloads can affect results.

## Machine and software

| Component | Recorded value |
| --- | --- |
| Laptop | MacBook Pro `Mac17,6`, AC power |
| CPU / memory | Apple M5 Max, 18 physical/logical cores, arm64, 64 GiB RAM |
| OS | macOS 27.0.1, build 26A434 |
| Elixir | 1.20.4, compiled for OTP 28 |
| Erlang/OTP | 28.5, ERTS 16.4, JIT, 18 online schedulers |
| MySQL | 8.4.11; Docker `mysql:8.4` |
| PostgreSQL | 16.15, aarch64; Docker `postgres:16-alpine` |
| Drivers / pool | MyXQL 0.9.0, Postgrex 0.22.4, DBConnection 2.10.2 |
| HTTP stack | Bandit 1.13.1, Plug 1.20.3 |
| Docker | Engine 29.8.0, LinuxKit 7.0.12; VM 18 CPUs, 8,317,267,968 bytes RAM (about 7.75 GiB) |
| Generator | Node.js 26.8.2 |
| Build / source | `MIX_ENV=dev`, server `ae54325`, locked dependencies, updated harness hashes in artifact |

Hardware metadata excludes serial numbers, hardware UUIDs, hostnames and network
identifiers. The artifact records exact Docker image digests and source/build
hashes, since tags and dependencies may change in future runs.

## Reproduce

Install the pinned Erlang/Elixir from `.tool-versions`, Mix dependencies, Node and
Docker as described in the root README. Use free database ports 13307/15433 and
MCP ports 13107/13108. Run from the repository root. This command owns and removes
the disposable fixture containers on exit; allow about twelve minutes for the
full measurement, plus builds/startup.

```sh
(
  set -eu
  trap 'docker compose -f compose.test.yml down' EXIT
  (cd mcp-ex-mysql && MIX_ENV=dev rtk proxy mix escript.build)
  (cd mcp-ex-pg && MIX_ENV=dev rtk proxy mix escript.build)
  rtk proxy docker compose -f compose.test.yml up -d --wait
  CACHE_BENCH_SMOKE=true rtk proxy node test/cache-benchmark.mjs > four-mode-smoke.jsonl
  rtk proxy node test/cache-benchmark.mjs > four-mode-results.jsonl
)
```

Progress goes to stderr; stdout is one JSON record per phase. Restrict a rerun
with `CACHE_BENCH_APPS=mysql` or `pg`, and/or `CACHE_BENCH_TRANSPORTS=stdio` or
`http`. Smoke uses one 0.3-second run per mode at concurrency 4 and must not be
reported as sustained capacity. Published summaries use the full campaign.
