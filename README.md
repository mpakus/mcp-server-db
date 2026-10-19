# Elixir database MCP servers

Connect an MCP client to MySQL or PostgreSQL through SQL tools and table metadata
resources. Both servers are written in Elixir, run over stdio or authenticated
stateless HTTP, and disable writes by default.

Status as of 2026-10-19: the three defects from the
[completion audit](.worklog/audit-2026-10-19.md) are fixed, runtime security
dependencies are patched, and the full check and Hex audits pass. See the
[fix log](.worklog/fixes-2026-10-19.md) for regression evidence and verification limits.

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

## Behavior and limits

Each tool accepts one SQL statement and an optional array of bound values.
Reads use database-enforced read-only transactions. Simple writes and table DDL
require operation/schema permissions. PostgreSQL connects to one database per
process; its multi mode discovers schemas in that database. MySQL table DDL
implicitly commits.

Optional PII mode guards SQL identifiers, filters column metadata and masks
returned values. Detection is heuristic. Database grants govern indirect effects
through functions, triggers and views. The SQL policy deliberately rejects
ambiguous or unsupported statements. Results have no pagination or byte limit;
use explicit projections and `LIMIT`. See the [security guide](docs/SECURITY.md).

HTTP uses `POST /mcp`, exact static bearer authentication and JSON responses.
It has no SSE stream, session storage, OAuth server or browser CORS preflight.
See [HTTP operation](docs/OPERATIONS.md#run-http) for headers and examples.

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
