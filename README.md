# Elixir database MCP servers

Connect an MCP client to MySQL or PostgreSQL through SQL tools and table metadata
resources. Both servers are written in Elixir, run over stdio or authenticated
HTTP, with a supervised Elixir process per MCP session. Writes are disabled by default.

Status as of 2026-10-19: the three defects from the
[completion audit](.worklog/audit-2026-10-19.md) are fixed, runtime security
dependencies are patched, and the full check and Hex audits pass. Both escripts now include an optional
[local CLI dashboard](docs/DASHBOARD.md). See the
[fix log](.worklog/fixes-2026-10-19.md) for regression evidence and verification limits.

2026-10-20: both transports now use supervised MCP session processes and bounded
query workers. Stdio input is buffered and pings remain responsive during SQL.
See the [session implementation and measurements](.worklog/session-implementation-2026-10-20.md).

| Project | Purpose | Tool | Resource URI |
| --- | --- | --- | --- |
| [mcp-ex-mysql](mcp-ex-mysql/README.md) | MySQL server using MyXQL | `mysql_query` | `mysql://tables[/database/table]` |
| [mcp-ex-pg](mcp-ex-pg/README.md) | PostgreSQL server using Postgrex | `pg_query` | `postgres://tables[/schema/table]` |
| [mcp-ex-core](mcp-ex-core/README.md) | Shared configuration, MCP, transports, SQL policy and PII masking | Used by both servers | Used by both servers |

The adjacent [mcp-server-mysql](mcp-server-mysql/README.md) is the TypeScript
reference implementation. Keep the three Elixir folders together: both
applications depend on `../mcp-ex-core`. Plug and Bandit serve HTTP; there is no
web UI or Phoenix application.

## Documentation

Start with the [documentation index](docs/README.md), or open a guide directly:

- [User guide](docs/USER-GUIDE.md): install with asdf, build, connect clients, query and discover tables.
- [Configuration reference](docs/CONFIGURATION.md): every environment variable, defaults and precedence.
- [Security and SQL policy](docs/SECURITY.md): write permissions, read-only transactions, PII and supported SQL.
- [Dashboard](docs/DASHBOARD.md): status, watch, resources, statistics and private snapshots.
- [Operations](docs/OPERATIONS.md): HTTP deployment, TLS, sockets, tunnels, monitoring and upgrades.
- [Developer guide](docs/DEVELOPER-GUIDE.md): architecture, module contracts, extension points and contribution workflow.
- [Testing](docs/TESTING.md): local checks, disposable databases and official MCP SDK interoperability.
- [Troubleshooting](docs/TROUBLESHOOTING.md): startup failures, protocol errors and query restrictions.

## Quick start

With asdf and its Erlang/Elixir plugins installed, run from this directory:

```sh
KERL_CONFIGURE_OPTIONS='--without-javac --without-wx --without-odbc' asdf install
mix local.hex --force
mix local.rebar --force
for project in mcp-ex-core mcp-ex-mysql mcp-ex-pg; do
  (cd "$project" && mix deps.get)
done
(cd mcp-ex-mysql && mix escript.build)
(cd mcp-ex-pg && mix escript.build)
```

[First-time plugin setup](docs/USER-GUIDE.md#install-and-build) is in the user
guide. [.tool-versions](.tool-versions) pins Erlang 28.5 and Elixir
1.20.4-otp-28; the Mix projects require Elixir 1.18 or newer. Built escripts
bundle Elixir and dependencies and still require Erlang's `escript` on `PATH`.

Choose a server and supply credentials for an existing database account. These
commands start the stdio transport; an MCP client supplies the protocol messages.

```sh
MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER=reader MYSQL_PASS=replace-me MYSQL_DB=app \
  ./mcp-ex-mysql/mcp-ex-mysql --stdio
```

```sh
PG_HOST=127.0.0.1 PG_PORT=5432 PG_USER=reader PG_PASS=replace-me PG_DB=app PG_SCHEMA=public \
  ./mcp-ex-pg/mcp-ex-pg --stdio
```

Use [client configuration](docs/USER-GUIDE.md#connect-a-stdio-client) for normal
usage. `.env` files must be exported explicitly. Restart the process after
changing configuration.

## Server dashboard

Add `MCP_DASHBOARD=true` to your MCP server's environment and restart it.
In another terminal under the same account:

```sh
./mcp-ex-mysql/mcp-ex-mysql status
./mcp-ex-pg/mcp-ex-pg status --watch
./mcp-ex-pg/mcp-ex-pg status --json
./mcp-ex-pg/mcp-ex-pg resources --instance INSTANCE_ID
```

Copy `INSTANCE_ID` from `status`. The viewer reads private local snapshots and
needs no database credentials. It shows uptime, database-health/sample ages,
pool readiness/queue length, BEAM memory/processes, aggregate request/query
statistics and cached resource names. Ctrl+C stops only the viewer.

![MySQL and PostgreSQL dashboard CLI example](docs/images/dashboard.jpg)

Browser-rendered screenshot of real CLI output from the disposable fixtures:
each server completed eight reads and rejected two policy checks. The
application runs in your terminal; the screenshot frame is documentation only.
SQL, parameters, returned rows and credentials are excluded from snapshots.
Read [dashboard setup, metric definitions and reproduction](docs/DASHBOARD.md)
for custom directories, JSON/watch behavior, freshness and exit codes.

## Behavior and limits

Each tool accepts one SQL statement and an optional array of bound values.
Reads use database-enforced read-only transactions. Simple writes and table DDL
require operation/schema permissions. PostgreSQL connects to one database per
process; its multi mode discovers schemas in that database. MySQL table DDL
implicitly commits.

Optional PII mode guards SQL identifiers, filters column metadata and masks
returned values. Detection is heuristic. Database grants govern indirect effects
through functions, triggers and views. The SQL policy deliberately rejects
ambiguous or unsupported statements. Responses default to an 8 MiB limit and have no pagination;
use explicit projections and `LIMIT`. See the [security guide](docs/SECURITY.md).

HTTP uses `POST /mcp`, exact static bearer authentication and JSON responses.
Initialization issues an `MCP-Session-Id` that clients reuse on subsequent requests.
Sessions support cancellation and DELETE, and expire after five idle minutes by
default. There is no SSE stream, durable session storage, OAuth server or browser CORS preflight.
See [HTTP operation](docs/OPERATIONS.md#run-http) for headers and examples.

## Performance before and after MCP sessions

Benchmarked on 2026-10-20 using clean builds of `b542550` (before) and `9646c0a`
(after session processes, bounded query workers and buffered stdio). Values below
are **before → after, in milliseconds**, using the median of five samples after
ten warm-up queries. Lower is better.

| Server | Transport | `SELECT 1` | Four concurrent 200 ms queries | Ping behind a 300 ms query | Ping with 256 KiB input padding |
| --- | --- | ---: | ---: | ---: | ---: |
| MySQL | stdio | 1.77 → 1.16 | 831.15 → 206.93 | 278.76 → 0.39 | 4,531.43 → 1.03 |
| PostgreSQL | stdio | 1.83 → 1.60 | 839.04 → 208.38 | 277.39 → 0.36 | 4,311.52 → 1.11 |
| MySQL | HTTP | 1.99 → 1.66 | 208.12 → 207.94 | 2.13 → 2.09 | 1.50 → 1.27 |
| PostgreSQL | HTTP | 2.22 → 2.09 | 208.40 → 211.19 | 1.49 → 1.72 | 0.99 → 1.38 |

Stdio completed the four-query batch **about 4× faster** on both servers.
Pings finished ahead of the slow query in every after sample; previously stdio
pings waited for it. Buffered input reduced the large padded ping from over four
seconds to about one millisecond. HTTP already handled concurrent requests, and
its batch latency remained around 208–211 ms.

Both revisions used the same disposable Docker fixtures, pool size 10, one
client/session at a time, and disabled dashboard/PII redaction; the new session
allowed four query workers. Host: Apple M5 Max, 64 GiB RAM, macOS 27.0.1,
Erlang 28.5 / Elixir 1.20.4; databases: MySQL 8.4.11 and PostgreSQL 16.15.
Initialization/startup is excluded. The ping was sent 30 ms after the slow query.

These local sleep-query and framing tests measure concurrency and latency, not
production SQL throughput. Five samples do not establish tail latency or the
significance of small timing differences. CPU/memory usage and sustained load
were not measured. See [methodology and reproduction](docs/benchmarks/README.md),
[all samples and environment](docs/benchmarks/session-processes-2026-10-20.json),
and the [benchmark harness](test/benchmark.mjs).

## Verify

After fetching dependencies for all three projects:

```sh
./bin/check
```

For real database and SDK checks, run from the workspace root:

```sh
(
  set -eu
  trap 'docker compose -f compose.test.yml down' EXIT
  docker compose -f compose.test.yml up -d --wait
  npm --prefix test ci --ignore-scripts
  MCP_INTEGRATION=true ./bin/check
)
```

The fixtures use disposable tmpfs storage and loopback database ports
13307 and 15433. SDK tests also need ports 13007 and 13008. Node and Docker are
needed only for integration checks. Tests mutate fixtures; use the supplied test environment.
[Testing instructions and coverage](docs/TESTING.md) explain the checks and
remaining verification limits. `bin/check` uses RTK when available.

Tasks and evidence are tracked in [.worklog/status.md](.worklog/status.md);
implementation decisions are in [.worklog/analysis.md](.worklog/analysis.md).
MIT license and reference-project attribution: [LICENSE](LICENSE).
