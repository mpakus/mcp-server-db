# User guide

Both applications expose one SQL tool and metadata resources through MCP. Choose
MySQL for MySQL databases and PostgreSQL for PostgreSQL databases. A database
must already exist and be reachable with the configured account; the servers do
not create accounts or provision application databases.

## Install and build

Use asdf for Erlang and Elixir. From the workspace root, add any missing plugins:

```sh
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
```

Skip a plugin-add command when that plugin is already installed. Install the
versions pinned in [.tool-versions](../.tool-versions), initialize Mix package
tools, fetch dependencies for all three projects and build the executables:

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

The pinned runtime is Erlang 28.5 and Elixir 1.20.4-otp-28. Compiling Erlang
requires a compiler toolchain and its platform build prerequisites; the options
above omit Java, wx and ODBC features that these servers do not use. If the
build fails, inspect the asdf/kerl log and install the missing prerequisite
reported there. The projects' Elixir requirement is `~> 1.18`; this does not
mean every matching runtime has been exercised.

The outputs are `mcp-ex-mysql/mcp-ex-mysql` and `mcp-ex-pg/mcp-ex-pg`. Escript
bundles Elixir and dependencies, but requires Erlang and `escript` on `PATH`.
Mix builds require the sibling core directory; do not copy an application
source folder without it. There is no Node requirement for server execution.

## Configure a database

Settings come from the process environment. Start with a restricted database
account and the appropriate example file:

```sh
cp mcp-ex-mysql/.env.example mcp-ex-mysql/.env
```

Or, for PostgreSQL:

```sh
cp mcp-ex-pg/.env.example mcp-ex-pg/.env
```

Edit the chosen file before launching. A `.env` file is not loaded automatically.
To export a trusted shell-format file and start MySQL:

```sh
(
  cd mcp-ex-mysql
  set -a
  . ./.env
  set +a
  ./mcp-ex-mysql --stdio
)
```

For PostgreSQL:

```sh
(
  cd mcp-ex-pg
  set -a
  . ./.env
  set +a
  ./mcp-ex-pg --stdio
)
```

Quote shell values containing spaces or shell metacharacters. Sourcing executes
shell syntax; keep secrets in a trusted private file or inject them through the
client/process manager. These local `.env` files are ignored by their projects'
Git ignore rules. The complete settings are in [Configuration](CONFIGURATION.md).

Startup validates configuration, starts the pool and executes a read-only
`SELECT 1` before accepting MCP traffic. A stdio process waiting silently for
input is normal. Logs and startup failures go to stderr; stdout is reserved for
newline-delimited JSON-RPC.

## Connect a stdio client

For MCP clients that accept an `mcpServers` configuration, use the following
shape. Replace `/absolute/path/mp` and credentials. Only configure the servers
you need; the client launches each process itself.

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
    },
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

Client configuration storage and environment inheritance depend on the client.
Ensure its launch environment includes Erlang's `escript`. A GUI client may not
inherit your shell's asdf setup. For a wrapper that selects the pinned runtime
from the workspace, see [process launch](OPERATIONS.md#process-launch-and-lifecycle).

Without flags, transport defaults to stdio unless `IS_REMOTE_MCP=true`. Explicit
`--stdio` chooses stdio; `--http` chooses HTTP. The only supported CLI flags are
these two and they cannot be combined. Settings, including database credentials,
are environment variables. HTTP usage is in [Operations](OPERATIONS.md#run-http).

## Query tools

Use `tools/list` to discover `mysql_query` or `pg_query`. Both accept:

| Argument | Required | Meaning |
| --- | --- | --- |
| `sql` | Yes | One nonempty SQL statement |
| `params` | No | Array of bound values; defaults to `[]` |

Additional argument keys are rejected. Parameters bind values, not SQL
identifiers. Use `?` placeholders for MySQL and `$1`, `$2`, etc. for PostgreSQL.
JSON scalars map naturally to common parameter types; more specific database
types depend on the driver's encoding and may require SQL casts. There is no
custom binary or typed-parameter JSON envelope.

Example MySQL `tools/call` request, after MCP initialization:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "mysql_query",
    "arguments": {
      "sql": "SELECT id, label FROM users WHERE id = ? LIMIT 10",
      "params": [1]
    }
  }
}
```

The equivalent PostgreSQL request:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "pg_query",
    "arguments": {
      "sql": "SELECT id, label FROM public.users WHERE id = $1 LIMIT 10",
      "params": [1]
    }
  }
}
```

These examples assume a `users` table with `id` and `label` columns. Reads run
inside read-only transactions and are rolled back after obtaining the result.
Do not send `BEGIN`, `COMMIT`, `USE` or `SET search_path`; calls do not share a
transaction or current-database state. SQL support and write examples are in
[Security and SQL policy](SECURITY.md#supported-sql).

## Read tool results

A successful response contains two text items: JSON data and elapsed execution
time. For a row query, the first item is a JSON array of objects, including an
empty array when no rows match. For example:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {"type": "text", "text": "[{\"id\":1,\"label\":\"sample\"}]"},
      {"type": "text", "text": "Query execution time: 1.23 ms"}
    ],
    "isError": false
  }
}
```

Parse `result.content[0].text` as JSON. Statements for which the driver returns
no column list produce an object with `affectedRows` and `insertId`; PostgreSQL
does not supply a MySQL insert ID, so it is `null`. Writes with `RETURNING`
produce row objects when the driver supplies columns. Use unique column aliases:
duplicate output names overwrite earlier values in each row object.

Decimals/numerics and integers beyond JavaScript's exact integer range are
strings. Date/time values use ISO strings; fractional precision follows the
driver value. Invalid UTF-8 binaries become `{"base64":"..."}`. PII mode can
mask values or reject the query before execution. Execution time measures the
driver call and result processing after SQL policy checking, not full client
latency.

Tool execution/argument/policy failures normally return `isError: true` with a
single `Error: ...` text item. Unknown tool names and malformed RPC parameters
can instead produce JSON-RPC errors. Check both envelopes. Full database error
text is suppressed; the database code is returned when available.

## Discover tables and columns

`resources/list` returns a root table resource followed by accessible table and
view resources. Read the root or a table with `resources/read`:

```json
{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"mysql://tables"}}
```

```json
{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"mysql://tables/app/users"}}
```

```json
{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"postgres://tables/public/users"}}
```

The result has a `contents` array with `uri`, `mimeType: application/json` and
JSON serialized into `text`. Use the URIs returned by discovery; schema/table
path components are percent-encoded when needed. Resource URIs accept no query
parameters, fragment, user credentials or port.

| Resource | MySQL fields | PostgreSQL fields |
| --- | --- | --- |
| Root table list | `schema`, `name`, `type`, `row_count`, `data_size`, `index_size` | `schema`, `name`, `type` |
| Table columns, in ordinal order | `column_name`, `data_type`, `is_nullable`, `column_default`, `column_key` | `column_name`, `data_type`, `is_nullable`, `column_default` |

MySQL row counts are metadata estimates, not a reconciled count. Resources
describe tables/views; they do not return table data. PII mode omits sensitive
column entries from table resources. Other metadata values receive serialization
normalization, not the query result's full value-masking pass.

## Database and schema scope

With `MYSQL_DB=app`, discovery is scoped to `app` and unqualified SQL resolves
there. With `MYSQL_DB` unset or empty, discovery covers accessible non-system
databases and queries should use `database.table`. Writes additionally need
`MULTI_DB_WRITE_MODE=true` in that mode.

PostgreSQL always connects to one database. `PG_SCHEMA=public` scopes discovery
and the configured search path to `public`; `PG_SCHEMA=legacy` selects `legacy`
without adding a `public` fallback. PostgreSQL's own implicit catalog/temp
lookup rules still apply. Set `PG_SCHEMA=` for discovery across accessible
non-system schemas; use qualified names and opt into multi writes separately.
Run another process to reach another PostgreSQL database.

Short URIs such as `mysql://tables/users` or `postgres://tables/users` resolve
against the configured default database/schema. They require that default to
be present. Qualified resources still have to appear in the discovery scope.
Discovery scope is not a SQL read allowlist: explicitly qualified SQL can reach
other objects allowed by the database account. Write permissions apply to the
explicit target. See [permissions](SECURITY.md#write-permissions).

## MCP lifecycle and feature support

Stdio clients send `initialize`, then `notifications/initialized`, before calling
tools or resources. `ping` is available before initialization. Requests have
`jsonrpc: "2.0"`, a method, object parameters and an integer or string ID;
notifications omit the ID and produce no stdio response. Send one complete JSON
object per line. JSON-RPC batches are unsupported.

Supported protocol versions in this implementation are `2025-11-25`,
`2025-06-18`, `2025-03-26` and `2024-11-05`. Initialization echoes a supported
requested version or offers `2025-11-25`; the client must accept that negotiation.
HTTP is stateless and does not preserve initialization state between requests.

Only tools and resources are advertised. There are no prompts, subscriptions,
resource templates, pagination cursors, cancellation handlers or persistent
sessions. `ping` checks protocol responsiveness and does not run a database
query. See [Troubleshooting](TROUBLESHOOTING.md) when startup or requests fail.

For a manual stdio check, export the MySQL database settings first, then run
from the workspace root. Each quoted string becomes one input line; closing
the pipe lets the process exit after responding:

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual-check","version":"1.0.0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mysql_query","arguments":{"sql":"SELECT 1 AS value","params":[]}}}' \
  | ./mcp-ex-mysql/mcp-ex-mysql --stdio
```

For PostgreSQL, use its exported settings, executable and `pg_query` tool name.
The notification has no response; the three requests do. This is a protocol
smoke check, not a replacement for the database and SDK [tests](TESTING.md).
