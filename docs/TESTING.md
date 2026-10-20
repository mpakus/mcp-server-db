# Testing

Use [`bin/check`](../bin/check) as the repeatable verification entry point.
It runs formatting checks, application compilation with warnings as errors,
ExUnit tests and builds both escripts. It uses `rtk proxy` when RTK is installed,
falling back to direct commands otherwise.

## Prerequisites

Install the pinned asdf runtime and Mix package tools as described in the
[user guide](USER-GUIDE.md#install-and-build). Fetch dependencies for each
project from the workspace root:

```sh
for project in mcp-ex-core mcp-ex-mysql mcp-ex-pg; do
  (cd "$project" && rtk proxy mix deps.get)
done
```

`bin/check` does not fetch dependencies, install Node packages or start databases.
The default checks need only Erlang/Elixir and fetched Mix dependencies. Full
integration needs a running Docker engine with Compose and a Node runtime that
supports the SDK and native `fetch`. Node is a test dependency, not a server
runtime dependency. SDK packages are locked by
[`test/package-lock.json`](../test/package-lock.json).

## Default check

From the workspace root:

```sh
./bin/check
```

Ensure `MCP_INTEGRATION` is unset or `false` for the default check. Both adapters'
test helpers exclude tests tagged `:integration` unless that variable is exactly
`true`. The current suite contains 47 core tests, one non-integration MySQL test
and one non-integration PostgreSQL test: 49 executed tests in total, with two
database tests excluded. Counts are a description of this checkout, not a
substitute for checking the actual output.

For an affected project alone:

```sh
(cd mcp-ex-core && rtk proxy mix format --check-formatted)
(cd mcp-ex-core && rtk proxy mix compile --warnings-as-errors)
(cd mcp-ex-core && rtk proxy mix test)
```

Substitute `mcp-ex-mysql` or `mcp-ex-pg` as needed. This targeted check does not
replace adapter/integration verification when a shared change affects both.

## Full integration check

Run the complete sequence from the workspace root. The subshell trap removes
the test Compose project even if a check fails:

```sh
(
  set -eu
  trap 'docker compose -f compose.test.yml down' EXIT
  rtk proxy docker compose -f compose.test.yml up -d --wait
  rtk proxy npm --prefix test ci --ignore-scripts
  MCP_INTEGRATION=true ./bin/check
)
```

The database integration tests insert/delete fixture rows, create/drop test
tables and exercise failure/rollback paths. Use the supplied disposable
fixtures, never application databases. The current full run executes 47 core,
2 MySQL and 2 PostgreSQL ExUnit tests (51 total), then the official MCP SDK
script over both stdio and HTTP, plus raw escript timeout/framing checks. It also
rebuilds the escripts before SDK use.

The Compose project is named `mp-mcp-test` and stores database files in tmpfs.
Removing it discards fixture state. Initial SQL is mounted read-only from
[`test/mysql.sql`](../test/mysql.sql) and
[`test/postgres.sql`](../test/postgres.sql). To reset fixtures after an interrupted
manual run:

```sh
rtk proxy docker compose -f compose.test.yml down
rtk proxy docker compose -f compose.test.yml up -d --wait
```

If tests race database initialization, inspect this project's Compose logs and
retry after fixture initialization completes. The health checks indicate server
readiness, not a full assertion that every seed object has been created.

## Fixture endpoints and credentials

These are public test credentials for the disposable local fixtures only.

| Component | Host/port | Database or schema | User/password |
| --- | --- | --- | --- |
| MySQL 8.4 | `127.0.0.1:13307` | `mcp_test`, also `mcp_locked` | `mcp_test` / `mcp_test_password` |
| MySQL fixture administration | Same endpoint | Fixture setup | `root` / `test-root-password` |
| PostgreSQL 16 Alpine | `127.0.0.1:15433` | Database `mcp_test`; `public` and `locked` schemas | `mcp_test` / `mcp_test_password` |
| SDK MySQL HTTP process | `127.0.0.1:13007/mcp` | Uses MySQL fixture | Temporary token `interop-test-token` |
| SDK PostgreSQL HTTP process | `127.0.0.1:13008/mcp` | Uses PostgreSQL fixture | Temporary token `interop-test-token` |

Both adapter tests can override their database port with
`MCP_TEST_MYSQL_PORT` or `MCP_TEST_PG_PORT`. These overrides apply only to the
Elixir tests. The JavaScript SDK script currently fixes database ports 13307 and
15433 and HTTP ports 13007/13008 and cache-check ports 13027/13028; changing an
Elixir variable does not reconfigure it or Compose. Keep the supplied ports for
the full suite.

## Individual integration stages

With fixture containers running, run a single adapter's real-database test:

```sh
(cd mcp-ex-mysql && MCP_INTEGRATION=true rtk proxy mix test)
```

```sh
(cd mcp-ex-pg && MCP_INTEGRATION=true rtk proxy mix test)
```

To run SDK checks separately, first build both escripts and install test packages:

```sh
(cd mcp-ex-mysql && rtk proxy mix escript.build)
(cd mcp-ex-pg && rtk proxy mix escript.build)
rtk proxy npm --prefix test ci --ignore-scripts
rtk proxy node test/client.mjs
```

[`test/client.mjs`](../test/client.mjs) launches its own stdio processes, then
starts/stops HTTP processes for each adapter. It uses four independent HTTP
clients concurrently to check that reused request IDs do not collide. Its child
environments supply fixture credentials and PII mode rather than inheriting
application database credentials. The escripts still need `escript` on `PATH`.

The same script also launches each built escript directly with a 500 ms query
timeout, sends initialization, a two-second slow query and a final ping, then
closes stdin. It requires JSON-only stdout, a failed-query result, the ping
response and exit status 0. The MySQL probe additionally requires the real
driver timeout log on stderr, so a logger-routing regression cannot pass just
because the query happened to fail silently. This probe disables PII for its
controlled slow-query function; normal SDK checks keep PII enabled.

[`test/sessions.mjs`](../test/sessions.mjs) also checks responsive pings during
SQL, cancellation and connection recovery, fragmented UTF-8, 256 KiB frames,
oversized input without newline/EOF, final unterminated frames and draining on
EOF. A pipelined initialization/300-ping burst plus a 128 KiB query result checks
complete output through batching and EOF. HTTP checks cover session IDs,
per-request authentication/Origin/version,
cancellation, DELETE and invalidated IDs. PostgreSQL uses a read-only fixture
function around `pg_sleep` because PII policy rejects `pg_*` identifiers.

[`test/cache.mjs`](../test/cache.mjs), invoked by the same SDK runner, checks
cache schema discovery, opt-in/hit/miss behavior, TTL, bound-value isolation,
PII policy and write invalidation on both transports and engines. HTTP uses two
sessions sharing an entry. It temporarily updates only the disposable fixture's
label and restores it in `finally`.

For dependency security checks, run from the workspace root:

```sh
for project in mcp-ex-core mcp-ex-mysql mcp-ex-pg; do
  (cd "$project" && rtk proxy mix hex.audit)
done
```

These checks use the current advisory registry and are separate from the normal
offline-capable format/compile/test steps.

## Coverage

| Layer | Checks |
| --- | --- |
| Core ExUnit | Configuration validation, permissions, SQL literals/comments/targets, quoted file-SQL guards, extra write-target qualification, PII guards/masking, numeric encoding, initialization, safe errors, resource URIs and Plug HTTP boundaries |
| MySQL real database | Binding, metadata aliases, decimal/large-integer/date results, native read-only rejection of a modifying function, quoted file-SQL rejection, committed writes, duplicate-key rollback, schema denials, table DDL and filtered SHOW COLUMNS |
| PostgreSQL real database | Binding, numeric/large-integer/date precision, read-only rejection of modifying functions/CTEs/EXPLAIN ANALYZE, writes, rollback, schema isolation, denied quoted/unquoted three-part ALTER targets, table DDL and masked RETURNING |
| Official MCP SDK | Initialize, tools/resources, root/table reads, bound queries, denied writes and sensitive references, stdio and session-based HTTP for both servers |
| Cache ExUnit | Disabled/default configuration, key scope, fixed TTL, slow queries, capacity/byte bounds, errors, concurrent writes, cancelled writers, stale fills, restart invalidation and redacted payloads |
| Session/runtime ExUnit | Initialization/version binding, duplicate IDs, per-session/global capacity, cancellation isolation, worker crashes/deadlines, owner death, idle expiry, response cap and pool/listener restart |
| Raw escripts | Actual timeout results, responsive ping, cancellation/recovery, JSON-only stdout, MySQL driver logging on stderr, UTF-8/buffer framing, oversized partial input and draining on EOF |
| Dashboard | Fixed counters/outcomes, private atomic files, invalid/symlink/oversized files, distinct instances, inventory cap, collector loss, hung sampler, storage-permission recovery, freshness and terminal escaping; built viewers with invalid DB settings, JSONL watch cancellation and live MySQL/PG stdio/HTTP snapshots |
| HTTP boundaries | Exact bearer matching, rejected Origin, protocol version, size and media types; SDK concurrent clients |

## Benchmark checks

The current [four-mode report](benchmarks/STRESS.md) replaces older result tables.
Run its smoke/full commands only against the disposable fixtures, after building
both escripts. `test/cache-benchmark.mjs` covers stdio, HTTP, stdio + cache and
HTTP + cache with the same lookup/concurrency and alternating execution order.
Every result row and request ID is checked; busy replies and unexpected errors
fail the run. Additional probes check all-miss behavior and live reads without
cache opt-in. Performance runs are separate from SDK tests that mutate fixtures.

## Recorded evidence and limits

The 2026-10-20 cache implementation passed `MCP_INTEGRATION=true rtk proxy ./bin/check`:
**51 ExUnit tests** (47 core and two per adapter), both builds, official SDK,
dashboard, raw-escript/session and cache checks. This includes cache expiry,
key scope, bounded admission, PII policy, write invalidation, cancellation,
restart behavior and query counters that exclude hits. The current benchmark
refresh changes only harnesses and documentation; application behavior is unchanged.

The refresh's default `rtk proxy ./bin/check` passed **49 tests** with two live
adapter tests excluded, plus format, warnings-as-errors compilation and both
builds. The four-mode smoke passed **24 phases**, and the standalone stress
runner passed its **16-phase smoke** with zero errors or busy replies. Full
campaign evidence and exact source/build hashes are in [STRESS.md](benchmarks/STRESS.md) and its raw
artifact. The earlier full integration result above remains explicitly separate.

Dashboard tests cover private snapshots, invalid/symlink/oversized files, collector
loss, hung sampling, storage-permission recovery and viewers without database
credentials. The [screenshot](DASHBOARD.md#screenshot-and-example) is from the
fixture demo. Hex audits were recorded separately in the
[fix log](../.worklog/fixes-2026-10-19.md); they are not part of the benchmark.

Verification covers the pinned runtime, MySQL 8.4 and PostgreSQL 16 on local
fixtures. Live TLS/mTLS, Unix sockets, SSH tunnels, reverse proxies, production
deployments, other versions, full-disk faults and dashboard performance overhead
were not checked in this campaign. Config tests do not prove a live TLS handshake.
The tiny hot-read workload is not production capacity or an absolute hardware
maximum. Historical implementation evidence remains in
[.worklog/status.md](../.worklog/status.md).

For new behavior, add regression coverage at the affected boundary and record
the exact commands actually run. Do not infer deployment, database recovery or
PII compliance from local test success.
