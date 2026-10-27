# Elixir database MCP servers

Connect an MCP client to MySQL or PostgreSQL through SQL tools and table metadata
resources. Both servers are written in Elixir, run over stdio or authenticated
HTTP, with a supervised Elixir process per MCP session. Writes are disabled by default.

Status as of 2026-10-19: the three defects from the
[completion audit](.worklog/audit-2026-10-19.md) are fixed, runtime security
dependencies are patched, and the full check and Hex audits pass. Both escripts now include an optional
[browser and CLI dashboard](docs/DASHBOARD.md). See the
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

## Optional ETS + TTL query cache

Caching is **disabled by default**. Enable it in the server/client launch
environment and restart the server:

```sh
export MCP_CACHE_ENABLED=true
export MCP_CACHE_TTL_MS=5000
export MCP_CACHE_MAX_ENTRIES=1000
export MCP_CACHE_MAX_ENTRY_BYTES=65536
```

Then pass `"cache": true` on individual reads that may be reused:

```json
{"name":"mysql_query","arguments":{"sql":"SELECT id, label FROM users WHERE id = ?","params":[1],"cache":true}}
```

This is the `params` object of a `tools/call` request. For PostgreSQL use
`pg_query` and `$1`. The result's `_meta.cache` reports `hit`, `miss`, `disabled`
or `bypass`. Omitting `cache` keeps reads live. Both transports share the same
implementation; HTTP sessions share one instance's cache. Protected ETS serves
hits directly, with a supervised owner handling bounded storage and TTL cleanup.

Entries contain normalized/masked payloads. Policy still runs on hits. Writes
through this server invalidate all entries; writes elsewhere rely on TTL.
Resource discovery remains live. Use uncached calls for immediate freshness or
volatile functions. See [configuration and consistency limits](docs/CONFIGURATION.md#optional-query-cache),
[client usage](docs/USER-GUIDE.md#optional-cached-reads) and
[four-mode benchmarks](docs/benchmarks/STRESS.md).

## Server dashboard

Add `MCP_DASHBOARD=true` to your MCP server's environment and restart it.

Startup prints a private browser dashboard link to stderr. Both servers default
to `HOST=localhost PORT=4000`; `--host` and `--port` override them. For example,
with the existing database settings exported:

```sh
MCP_DASHBOARD=true ./mcp-ex-mysql/mcp-ex-mysql --stdio --host localhost --port 4000
```

Stdio exposes only the dashboard over HTTP. `--http` also prints the MCP URL
at `/mcp`. Use separate ports for simultaneous servers. See
[browser access and privacy](docs/DASHBOARD.md#browser-dashboard).
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

Each tool accepts one SQL statement, an optional array of bound values and an
optional cache opt-in. Executed reads use database-enforced read-only transactions. Simple writes and table DDL
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

## Local stress benchmark

The current comparison covers **stdio**, **HTTP**, **stdio + cache**, and
**HTTP + cache** for both databases, using the same bound primary-key lookup
and 64 concurrent requests. Each value is the median of three 20-second runs.
Cache runs keep the five-second TTL active; cached responses are not SQL-query
throughput. Older before/after tables are superseded by this comparison.

| Engine | stdio RPS | HTTP RPS | stdio + cache RPS | HTTP + cache RPS |
| --- | ---: | ---: | ---: | ---: |
| MySQL | **9,210** | **9,192** | **63,938** | **88,063** |
| PostgreSQL | **7,948** | **7,982** | **63,793** | **87,865** |

**23,155,439 validated responses across 64 phases; zero errors or busy replies.**
Stdio uses one session; HTTP uses four. Pool/global worker cap and per-session
limits are 128 for MySQL and 96 for PostgreSQL; dashboard/PII are off. These are
benchmark overrides, not changed defaults. This is a local hot-read comparison,
not a production-capacity or absolute-maximum claim.

MacBook Pro `Mac17,6`, Apple M5 Max (18 cores), 64 GiB RAM, macOS 27.0.1;
Elixir 1.20.4, Erlang/OTP 28.5 / ERTS 16.4; MySQL 8.4.11, PostgreSQL 16.15;
Node 26.8.2, Docker Engine 29.8.0 (18 CPUs / about 7.75 GiB VM RAM).

See [STRESS.md](docs/benchmarks/STRESS.md) for latency, CPU/RSS, cache-hit rates,
cold-cache probes, exact configuration, laptop/software versions and reproduction.
[Raw measurements](docs/benchmarks/stress-2026-10-20.json) include every phase,
histogram, per-second count and source/build hash.

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
13307 and 15433. SDK tests also need ports 13007/13008, 13017/13018 and 13027/13028. Node and Docker are
needed only for integration checks. Tests mutate fixtures; use the supplied test environment.
[Testing instructions and coverage](docs/TESTING.md) explain the checks and
remaining verification limits. `bin/check` uses RTK when available.

Tasks and evidence are tracked in [.worklog/status.md](.worklog/status.md);
implementation decisions are in [.worklog/analysis.md](.worklog/analysis.md).

## License and author

Copyright © 2026 Renat "MpaK" Ibragimov — [aomega.co](https://aomega.co).

**Free for noncommercial use and noncommercial open-source projects** under
[PolyForm Noncommercial 1.0.0](LICENSES/PolyForm-Noncommercial-1.0.0.txt), including
its expressly permitted organization uses. **Commercial projects outside those
permissions require a separate paid commercial license**, even if they publish
source code. Contact [the author](https://aomega.co) to arrange terms.

This is a source-available license. See [LICENSE](LICENSE) and the
[licensing guide](docs/LICENSING.md) for scope and conditions. Existing MIT grants
and third-party licenses remain intact; Ben Borla's reference-project attribution
and MIT terms are preserved in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
