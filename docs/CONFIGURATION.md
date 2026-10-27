# Configuration reference

The process environment is read once at startup by
[`McpEx.Config`](../mcp-ex-core/lib/mcp_ex/config.ex). Neither application loads
`.env` automatically. Restart after changing values. Server launch accepts
`--stdio` or `--http`; configuration uses environment variables. Separate
[dashboard commands](DASHBOARD.md) accept inspection/watch flags and bypass
database/HTTP configuration loading.

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
| `HOST` | `localhost` | HTTP/dashboard bind host: `localhost` (IPv4 loopback), or a literal IPv4/IPv6 address |
| `MCP_HTTP_HOST` | Unset | Compatibility fallback when `HOST` is unset |
| `PORT` | `4000` | HTTP/dashboard listen port, 1–65535; applies to both applications |
| `MCP_ALLOWED_ORIGINS` | Empty | CSV of exact permitted Origin header values; no wildcards |
| `MCP_MAX_REQUEST_BYTES` | `1048576` | Maximum HTTP body/stdio frame and independent SQL byte length check |
| `MCP_MAX_RESPONSE_BYTES` | `8388608` | Maximum encoded response bytes; oversized results become a small RPC error |
| `MCP_MAX_SESSIONS` | `1000` | Maximum active session processes per server |
| `MCP_MAX_INFLIGHT` | `4` | Active query/resource workers per session; excess requests receive a busy RPC error |
| `MCP_SESSION_IDLE_TIMEOUT` | `300000` | HTTP idle session lifetime in milliseconds; active work prevents expiry |
| `MCP_REQUEST_TIMEOUT` | Query timeout + `1000` | Total query/resource worker deadline, including checkout and result encoding, in milliseconds |

`--http` selects HTTP without needing `IS_REMOTE_MCP=true`, but still requires
`REMOTE_SECRET_KEY`. `--stdio` overrides transport selection; however,
`IS_REMOTE_MCP=true` still requires the secret during configuration and CLI
validation, even with `--stdio`. Remove that variable or set it to `false` for
a normal local setup. Both flags together are invalid.

`--host HOST` and `--port PORT` override these environment variables. For example,
`--http --host localhost --port 4001` listens on loopback port 4001. With
`MCP_DASHBOARD=true`, stdio also starts a dashboard-only HTTP listener at this
address; it does not expose `/mcp`. Use different ports for simultaneous servers.

Shared HTTP settings are parsed even for stdio, so an invalid HTTP bind
address/port can also fail a stdio launch. HTTP accepts a missing Origin; if
present, it must match one allowed value exactly. An empty allowlist therefore
rejects every request carrying an Origin header. It does not grant browser CORS
support. See [HTTP headers and status codes](OPERATIONS.md#http-request-contract).

The request limit measures bytes, not characters. A JSON body has overhead
beyond its SQL string, so SQL at the limit may not fit in a transport frame.
Oversized stdio input emits a parse error and exits; HTTP rejects it with 413.
The response limit is checked after result materialization, so it bounds sent
responses rather than peak database/encoding memory. Its error envelope is
exempt. All six limits/timeouts above accept positive integers up to 2147483647.
The default request timeout is capped at that maximum.

The global query/resource worker limit equals `MYSQL_POOL_SIZE` or `PG_POOL_SIZE`;
all sessions share that pool. Worker and session capacity errors reject new work
instead of growing a work queue. These are not connection or request-rate limits;
apply those at the HTTP proxy. Stdio sessions live until EOF/owner exit and do not
use the HTTP idle timer. Await each dependent write before issuing the next.

## Optional query cache

| Variable | Default | Meaning |
| --- | --- | --- |
| `MCP_CACHE_ENABLED` | `false` | Enable the per-process SQL result cache; reads still require `cache: true` |
| `MCP_CACHE_TTL_MS` | `5000` | Fixed TTL in milliseconds, 1–2147483647, starting before SQL execution |
| `MCP_CACHE_MAX_ENTRIES` | `1000` | Maximum cached payloads, 1–100000 |
| `MCP_CACHE_MAX_ENTRY_BYTES` | `65536` | Maximum encoded payload bytes per entry, 1–8388608 |

Restart the server after changing these settings. All four are validated even
when caching is disabled. Enable the feature in the process/client environment,
then opt in on each suitable read with the boolean tool argument `cache: true`:

```sh
export MCP_CACHE_ENABLED=true
export MCP_CACHE_TTL_MS=5000
export MCP_CACHE_MAX_ENTRIES=1000
export MCP_CACHE_MAX_ENTRY_BYTES=65536
```

This cache is shared by sessions within one server process, for both transports.
It stores the normalized, PII-masked JSON payload when PII mode is enabled.
Resource discovery remains live. Policy validation runs before every lookup.
Keys include SQL, bound values, schema/dialect and redaction settings; request
IDs and timing are generated per call. The configured database identity is fixed
for the lifetime of its isolated runtime.

TTL is fixed, not extended by hits. Expired entries are never served; a sweep
reclaims them every 100–1000 ms. Slow reads that outlast TTL, oversized payloads,
errors and new entries when full are not cached. The full cache keeps existing
unexpired entries; it does not evict the least recently used entry. Concurrent
misses may issue duplicate SQL. Defaults bound stored payloads to about 62.5 MiB
plus ETS/key overhead; driver results, in-flight payloads and encoding memory
are outside that bound.

Writes/DDL through this server invalidate the entire cache before and after
execution, including failures. Reads bypass it while a server write is active.
External writes, database grant changes and writes from another server instance
become visible when entries expire or the process restarts. Use `cache: false`
(or omit it) whenever freshness is required, including time/random/session-sensitive
functions. Cache opt-in does not certify that a read is deterministic or free of
external side effects. Await dependent writes; cancellation does not prove that
a database write has stopped or rolled back. This is a TTL cache, not a transaction
consistency mechanism.

Successful opted-in calls return `result._meta.cache`: `hit` reused a payload,
`miss` executed SQL (admission is not guaranteed), `disabled` executed SQL because
the feature is off, or `bypass` executed SQL because a write is active or the cache
is unavailable. Calls without opt-in have no cache metadata. `cache: true` on a
write is rejected. Hits report `Cache lookup time`; other calls report
`Query execution time`. See [usage](USER-GUIDE.md#optional-cached-reads) and
[current four-mode results](benchmarks/STRESS.md).

## Dashboard

| Variable | Default | Meaning |
| --- | --- | --- |
| `MCP_DASHBOARD` | `false` | Enable private snapshots and the browser dashboard in the running server; exactly `true` or `false` |
| `MCP_DASHBOARD_DIR` | `$XDG_STATE_HOME/mcp-ex` or `~/.local/state/mcp-ex` | Snapshot directory, expanded to an absolute path; set identically for server and viewer |

`XDG_STATE_HOME` is the standard operating-system directory override, not a
server-specific setting. Empty directory overrides are treated as unset; prefer absolute paths.
A custom existing directory must be owned by the current user with no group/world
permissions (`chmod 700 /your/private/directory`). Files use mode `0600`.
Diagnostics fail independently of MCP when storage/UID lookup is unavailable.
The status/resources viewer reads only directory selection from the environment;
it does not validate database credentials or start a pool. See
[Dashboard](DASHBOARD.md) for metrics, sampling intervals and exit codes.
