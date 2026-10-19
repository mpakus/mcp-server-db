# Configuration reference

The process environment is read once at startup by
[`McpEx.Config`](../mcp-ex-core/lib/mcp_ex/config.ex). Neither application loads
`.env` automatically. Restart after changing values. The CLI accepts only
`--stdio` or `--http`; there are no configuration CLI flags.

Booleans accept exactly lowercase `true` or `false`. Missing values take the
defaults below. An empty boolean or numeric value is invalid; an empty string
setting generally means unset. Passwords are an exception and preserve their
literal value, including the empty string. CSV lists are trimmed and empty
entries ignored. Invalid configuration fails startup.

## MySQL connection

| Variable | Default | Meaning |
| --- | --- | --- |
| `MYSQL_HOST` | `127.0.0.1` | TCP hostname, also used for TLS server identity |
| `MYSQL_PORT` | `3306` | Port, 1–65535 |
| `MYSQL_USER` | `root` | Database user; configure a restricted account for normal use |
| `MYSQL_PASS` | Empty string | Database password |
| `MYSQL_DB` | Unset | Default database; unset/empty discovers accessible non-system databases |
| `MYSQL_CONNECTION_STRING` | Unset | `mysql://user:password@host:port/database` |
| `MYSQL_SOCKET_PATH` | Unset | Unix socket file; selects socket transport instead of TCP |
| `MYSQL_POOL_SIZE` | `10` | Pool size, 1–1000 |
| `MYSQL_CONNECT_TIMEOUT` | `10000` | Driver connection timeout in milliseconds |
| `MYSQL_QUERY_TIMEOUT` | `30000` | Driver query/checkout/transaction timeout in milliseconds |
| `MYSQL_SSL` | `false` | Enable database TLS |
| `MYSQL_SSL_REJECT_UNAUTHORIZED` | `true` when TLS is enabled | Verify the certificate chain and hostname |
| `MYSQL_SSL_CA` | Unset | PEM CA file; otherwise use system trust |
| `MYSQL_SSL_CERT` | Unset | PEM client certificate; requires the key below |
| `MYSQL_SSL_KEY` | Unset | PEM client key; requires the certificate above |

## PostgreSQL connection

| Variable | Default | Meaning |
| --- | --- | --- |
| `PG_HOST` | `127.0.0.1` | TCP hostname, also used for TLS server identity |
| `PG_PORT` | `5432` | Port, 1–65535 |
| `PG_USER` | `postgres` | Database user; configure a restricted account for normal use |
| `PG_PASS` | Empty string | Database password |
| `PG_DB` | `postgres` | Connected database; one database per process |
| `PG_SCHEMA` | `public` | Default discovery schema and configured search path; empty means no default schema |
| `PG_CONNECTION_STRING` | Unset | `postgres://user:password@host:port/database`; `postgresql://` also accepted |
| `PG_SOCKET_PATH` | Unset | Unix socket directory, not the socket filename; port selects the socket within it |
| `PG_POOL_SIZE` | `10` | Pool size, 1–1000 |
| `PG_CONNECT_TIMEOUT` | `10000` | Driver connection timeout in milliseconds |
| `PG_QUERY_TIMEOUT` | `30000` | Driver query/transaction timeout and PostgreSQL startup `statement_timeout`, in milliseconds |
| `PG_SSL` | `false` | Enable database TLS |
| `PG_SSL_REJECT_UNAUTHORIZED` | `true` when TLS is enabled | Verify the certificate chain and hostname |
| `PG_SSL_CA` | Unset | PEM CA file; otherwise use system trust |
| `PG_SSL_CERT` | Unset | PEM client certificate; requires the key below |
| `PG_SSL_KEY` | Unset | PEM client key; requires the certificate above |

Timeouts and `MCP_MAX_REQUEST_BYTES` accept integers from 1 to 2147483647.
There is no zero/unlimited timeout setting. Pool size and ports have the smaller
limits shown in their tables. Database/driver semantics still determine how a
timeout interrupts an operation; it is not a response-size limit.

## URL precedence, TLS and sockets

Individual connection fields are parsed first. A connection URL then replaces
host, username, password and database. An explicit URL port replaces the
environment port; if omitted, the environment/default port remains. A URL with
no userinfo replaces the user with an empty string, and no database path replaces
the database with unset. Use a complete URL rather than expecting missing fields
to merge. Numeric environment settings must still be valid before URL overrides.

Percent-encode reserved characters in credentials and database names. The URL
accepts one database path component, no query parameters and no fragment. The
decoded database name cannot contain `/`. MySQL command-line strings and
PostgreSQL libpq keyword strings are not supported.

Examples of shell-quoted complete URLs:

```sh
export MYSQL_CONNECTION_STRING='mysql://reader:p%40ssword@db.example.com:3306/app'
```

```sh
export PG_CONNECTION_STRING='postgresql://reader:p%40ssword@db.example.com:5432/app'
export PG_SCHEMA='legacy'
```

For MySQL, the effective URL database also supplies the default permission and
discovery scope. PostgreSQL's `PG_SCHEMA` is independent of the URL database.
Pool sizes, timeouts, TLS and sockets remain environment settings; URL options
such as `?sslmode=require` are rejected.

TLS settings are applied after the URL, using the effective hostname for SNI and
hostname verification. Certificate and key must be supplied together even if
TLS is disabled. When TLS is enabled, configured PEM files must exist, be
nonempty and contain parseable PEM; startup validation alone does not prove a
successful TLS handshake or a valid trust chain. A socket setting then selects
the driver socket transport. See [network examples](OPERATIONS.md#database-tls).

## Write permissions

All writes are disabled by default. Schema here means a MySQL database or a
PostgreSQL schema, not a PostgreSQL database.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ALLOW_INSERT_OPERATION` | `false` | Default permission for simple inserts |
| `ALLOW_UPDATE_OPERATION` | `false` | Default permission for simple updates, also required for upserts containing `UPDATE` |
| `ALLOW_DELETE_OPERATION` | `false` | Default permission for simple deletes |
| `ALLOW_DDL_OPERATION` | `false` | Default permission for supported table DDL |
| `SCHEMA_INSERT_PERMISSIONS` | Empty | Insert overrides, e.g. `development:true,production:false` |
| `SCHEMA_UPDATE_PERMISSIONS` | Empty | Update overrides in the same format |
| `SCHEMA_DELETE_PERMISSIONS` | Empty | Delete overrides in the same format |
| `SCHEMA_DDL_PERMISSIONS` | Empty | Table DDL overrides in the same format |
| `MULTI_DB_WRITE_MODE` | `false` | Additional opt-in for writes when the default database/schema is unset |

Overrides replace the operation default for that schema; a `true` override can
enable a schema while the global operation flag is `false`. Values must be
`schema:true` or `schema:false`, with no space before the boolean. MySQL matches
schema keys case-insensitively and denies if any matching case variant denies.
PostgreSQL matches schema keys exactly; unquoted SQL identifiers are normalized
to lowercase. An exactly repeated key in the CSV takes its last value.

Write authorization also requires a default database/schema or
`MULTI_DB_WRITE_MODE=true`. Multi mode does not itself enable an operation.
The [permission examples](SECURITY.md#write-permissions) show how scope,
overrides and database grants combine.

## PII settings

These flags govern SQL query guards and value masking only when
`ENABLE_PII_REDACTION=true`, except the normalization of result types, which is
always applied. Extra regex syntax is validated at startup even when PII is off.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ENABLE_PII_REDACTION` | `false` | Enable identifier guards, column filtering and recursive value masking |
| `PII_EXTRA_COLUMNS` | Empty | CSV of additional sensitive name substrings, case-insensitive |
| `PII_EXTRA_COLUMN_PATTERNS` | Empty | Semicolon-separated regex bodies, compiled case-insensitively |
| `PII_REDACT_JSON_STRINGS` | `true` | Recursively mask objects/arrays encoded as JSON strings |
| `PII_ALLOW_SELECT_STAR` | `false` | Allow `*` tokens otherwise blocked by the wildcard guard; value masking remains |
| `PII_ALLOW_REFERENCES` | `false` | Allow sensitive SQL identifiers; value masking remains |
| `PII_ALLOW_INTROSPECTION` | `false` | Bypass SQL introspection rejection and SQL column-row filtering; MCP resource column filtering remains |
| `PII_BLOCK_INTROSPECTION` | `false` | Block all recognized SQL introspection, including topology; the allow-introspection flag takes precedence |

`COUNT(*)` is allowed by the default wildcard guard; other stars, including
arithmetic multiplication, are blocked. Sensitive identifiers include table,
alias and function tokens, not just selected columns. See
[PII behavior and limitations](SECURITY.md#pii-mode) before enabling overrides.

```sh
export ENABLE_PII_REDACTION=true
export PII_EXTRA_COLUMNS='customer_name,private_note'
export PII_EXTRA_COLUMN_PATTERNS='^billing_;national_id$'
```

## Transport and request settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `IS_REMOTE_MCP` | `false` | Select HTTP by default and require a remote secret |
| `REMOTE_SECRET_KEY` | Unset | Exact static bearer token, required for HTTP |
| `MCP_HTTP_HOST` | `127.0.0.1` | Literal IPv4 or IPv6 bind address; hostnames are rejected |
| `PORT` | `3000` | HTTP listen port, 1–65535; applies to both applications |
| `MCP_ALLOWED_ORIGINS` | Empty | CSV of exact permitted Origin header values; no wildcards |
| `MCP_MAX_REQUEST_BYTES` | `1048576` | Maximum HTTP body/stdio frame and independent SQL byte length check |

`--http` selects HTTP without needing `IS_REMOTE_MCP=true`, but still requires
`REMOTE_SECRET_KEY`. `--stdio` overrides transport selection; however,
`IS_REMOTE_MCP=true` still requires the secret during configuration and CLI
validation, even with `--stdio`. Remove that variable or set it to `false` for
a normal local setup. Both flags together are invalid.

Shared HTTP settings are parsed even for stdio, so an invalid HTTP bind
address/port can also fail a stdio launch. HTTP accepts a missing Origin; if
present, it must match one allowed value exactly. An empty allowlist therefore
rejects every request carrying an Origin header. It does not grant browser CORS
support. See [HTTP headers and status codes](OPERATIONS.md#http-request-contract).

The request limit measures bytes, not characters. A JSON body has overhead
beyond its SQL string, so SQL at the limit may not fit in a transport frame.
Oversized stdio input emits a parse error and exits; HTTP rejects it with 413.
There is no corresponding result-byte limit.
