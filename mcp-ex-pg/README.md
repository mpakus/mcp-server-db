# mcp-ex-pg

Elixir/Postgrex MCP server with `pg_query`, schema resources, stdio and
authenticated stateless HTTP. Keep `../mcp-ex-core` beside this project.

## Build and run

Install the asdf runtime using the [root instructions](../README.md), then:

```sh
mix deps.get
mix escript.build
PG_HOST=127.0.0.1 PG_PORT=5432 PG_USER=reader PG_PASS=secret PG_DB=app ./mcp-ex-pg --stdio
```

Or copy `.env.example` to `.env`, fill it, and export before launching:

```sh
set -a
. ./.env
set +a
./mcp-ex-pg --stdio
```

MCP client configuration (replace the path/credentials; `escript` must be on PATH):

```json
{
  "mcpServers": {
    "mcp-ex-pg": {
      "command": "/absolute/path/mp/mcp-ex-pg/mcp-ex-pg",
      "args": ["--stdio"],
      "env": {
        "PG_HOST": "127.0.0.1",
        "PG_PORT": "5432",
        "PG_USER": "reader",
        "PG_PASS": "replace-me",
        "PG_DB": "app",
        "PG_SCHEMA": "public"
      }
    }
  }
}
```

Tool input uses PostgreSQL parameter placeholders:

```json
{"name":"pg_query","arguments":{"sql":"SELECT id, label FROM users WHERE id = $1","params":[1]}}
```

`postgres://tables` returns the table list; `postgres://tables/public/users`
returns columns. `postgres://tables/users` resolves against `PG_SCHEMA`.
Discovery scopes to the default schema; set `PG_SCHEMA=` to discover all
accessible non-system schemas and use qualified table names. That mode needs
`MULTI_DB_WRITE_MODE=true` before any writes, plus operation/schema permission.

PostgreSQL connects to one database per process. Multi-schema mode does not
cross databases; run another server to connect to another database. The search
path contains exactly the configured schema, with no `public` fallback. An
empty schema requires qualified SQL. `SET search_path` is disabled.

## Connection configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `PG_HOST`, `PG_PORT` | `127.0.0.1`, `5432` | TCP endpoint |
| `PG_USER`, `PG_PASS` | `postgres`, empty | Credentials; use a restricted user for actual use |
| `PG_DB`, `PG_SCHEMA` | `postgres`, `public` | Database and default schema |
| `PG_CONNECTION_STRING` | unset | `postgres://user:password@host:port/database` (also `postgresql://`), overriding connection fields |
| `PG_SOCKET_PATH` | unset | Unix socket directory; takes precedence over TCP |
| `PG_POOL_SIZE` | `10` | Connection pool size |
| `PG_CONNECT_TIMEOUT`, `PG_QUERY_TIMEOUT` | `10000`, `30000` | Milliseconds; query setting also supplies server statement_timeout |
| `PG_SSL` | `false` | Enable TLS |
| `PG_SSL_REJECT_UNAUTHORIZED` | `true` | Verify certificate and server identity |
| `PG_SSL_CA` | unset | PEM CA path; otherwise system trust |
| `PG_SSL_CERT`, `PG_SSL_KEY` | unset | mTLS client PEM paths; supply both |

Percent-encode URL credentials. URLs do not accept query parameters; configure
TLS/sockets through environment variables. An external SSH tunnel can expose
the database on a local port. `.env` files are not loaded automatically.

See [shared configuration](../mcp-ex-core/README.md) for operation flags,
schema overrides, PII options, SQL limits and HTTP headers. Permissions name
PostgreSQL schemas. Read-only transactions also protect EXPLAIN ANALYZE and
writing CTEs. RETURNING rows use the same redactor as SELECT results.

## HTTP and tests

With database variables exported:

```sh
REMOTE_SECRET_KEY=replace-with-a-long-secret PORT=3001 ./mcp-ex-pg --http
```

Endpoint: `http://127.0.0.1:3001/mcp`. Startup fails on connectivity errors.
`mix test` excludes real database checks; start the parent's `compose.test.yml`
and run `MCP_INTEGRATION=true mix test` for disposable fixtures on port 15433.
See [root verification](../README.md) for official SDK stdio/HTTP checks.
[License](../LICENSE).
