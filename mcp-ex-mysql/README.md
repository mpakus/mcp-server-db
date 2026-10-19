# mcp-ex-mysql

Elixir/MyXQL MCP server with `mysql_query`, schema resources, stdio and
authenticated stateless HTTP. Keep `../mcp-ex-core` beside this project.

## Documentation

The complete documentation is maintained in the parent's [docs/](../docs/README.md):

- [User guide](../docs/USER-GUIDE.md): asdf installation, client setup, queries, results and resources.
- [Configuration](../docs/CONFIGURATION.md#mysql-connection): MySQL settings and all shared flags.
- [Security and SQL](../docs/SECURITY.md): permissions, read-only transactions, DDL and PII limits.
- [Operations](../docs/OPERATIONS.md): HTTP headers, TLS, sockets, tunnels and process lifecycle.
- [Developer guide](../docs/DEVELOPER-GUIDE.md), [testing](../docs/TESTING.md) and [troubleshooting](../docs/TROUBLESHOOTING.md).

The sections below provide a MySQL quick reference. Commands run from this
application directory unless they explicitly use a parent path.

## Build and run

Install the asdf runtime using the [root instructions](../README.md), then:

```sh
mix deps.get
mix escript.build
MYSQL_HOST=127.0.0.1 MYSQL_PORT=3306 MYSQL_USER=reader MYSQL_PASS=secret MYSQL_DB=app ./mcp-ex-mysql --stdio
```

Or copy `.env.example` to `.env`, fill it, and export before launching:

```sh
set -a
. ./.env
set +a
./mcp-ex-mysql --stdio
```

MCP client configuration (replace the path/credentials; `escript` must be on PATH):

```json
{
  "mcpServers": {
    "mcp-ex-mysql": {
      "command": "/absolute/path/mp/mcp-ex-mysql/mcp-ex-mysql",
      "args": ["--stdio"],
      "env": {
        "MYSQL_HOST": "127.0.0.1",
        "MYSQL_PORT": "3306",
        "MYSQL_USER": "reader",
        "MYSQL_PASS": "replace-me",
        "MYSQL_DB": "app"
      }
    }
  }
}
```

Tool input:

```json
{"name":"mysql_query","arguments":{"sql":"SELECT id, label FROM users WHERE id = ?","params":[1]}}
```

`mysql://tables` returns the table list; `mysql://tables/app/users` returns
columns. `mysql://tables/users` resolves against the configured database.
Single-database discovery scopes to that database. Empty/unset `MYSQL_DB`
discovers all accessible non-system databases; use `database.table` in SQL.
Writes in that mode additionally require `MULTI_DB_WRITE_MODE=true`.

## Connection configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `MYSQL_HOST`, `MYSQL_PORT` | `127.0.0.1`, `3306` | TCP endpoint |
| `MYSQL_USER`, `MYSQL_PASS` | `root`, empty | Credentials; use a restricted user for actual use |
| `MYSQL_DB` | unset | Default database |
| `MYSQL_CONNECTION_STRING` | unset | `mysql://user:password@host:port/database`, overriding connection fields |
| `MYSQL_SOCKET_PATH` | unset | Unix socket; takes precedence over TCP |
| `MYSQL_POOL_SIZE` | `10` | Connection pool size |
| `MYSQL_CONNECT_TIMEOUT`, `MYSQL_QUERY_TIMEOUT` | `10000`, `30000` | Milliseconds |
| `MYSQL_SSL` | `false` | Enable TLS |
| `MYSQL_SSL_REJECT_UNAUTHORIZED` | `true` | Verify certificate and server identity |
| `MYSQL_SSL_CA` | unset | PEM CA path; otherwise system trust |
| `MYSQL_SSL_CERT`, `MYSQL_SSL_KEY` | unset | mTLS client PEM paths; supply both |

Percent-encode URL credentials. URLs do not accept query parameters; configure
TLS/sockets through environment variables. TLS uses the URL host when provided.
An external SSH tunnel can expose the database on a local port. CLI-format
connection strings and automatic dotenv loading from the source are not supported.

See [shared configuration](../mcp-ex-core/README.md) for operation flags,
schema overrides, PII options, SQL limits and HTTP headers. Writes default to
disabled. `USE` is refused to keep pooled connections consistent. Supported
MySQL table DDL implicitly commits and cannot be rolled back.

## HTTP and tests

With database variables exported:

```sh
REMOTE_SECRET_KEY=replace-with-a-long-secret PORT=3000 ./mcp-ex-mysql --http
```

Endpoint: `http://127.0.0.1:3000/mcp`. Startup fails on connectivity errors.
`mix test` excludes real database checks; start the parent's `compose.test.yml`
and run `MCP_INTEGRATION=true mix test` for disposable fixtures on port 13307.
See [root verification](../README.md) for official SDK stdio/HTTP checks.
[License](../LICENSE).


## Dashboard

Add `MCP_DASHBOARD=true` to the server environment and restart. From this
application directory, run `./mcp-ex-mysql status --watch` in another terminal.
Use `status --json` for scripting or `resources --instance INSTANCE_ID` for
cached resources. Inspection uses private snapshots and needs no database
credentials. See the [dashboard guide and screenshot](../docs/DASHBOARD.md)
for setup, metrics, exit codes and privacy limits.
