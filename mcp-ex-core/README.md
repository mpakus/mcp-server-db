# mcp-ex-core

Shared library for the two Elixir database MCP applications. Database adapters
own pools, transactions and metadata SQL; the core owns MCP, transports,
configuration, single-statement SQL policy and PII masking.

## Documentation

The canonical [documentation index](../docs/README.md) covers both applications:

- [Developer guide](../docs/DEVELOPER-GUIDE.md): architecture, source map, contracts and extension workflow.
- [Configuration](../docs/CONFIGURATION.md): every database, permission, PII and transport variable.
- [Security and SQL policy](../docs/SECURITY.md): exact permission evaluation and practical boundaries.
- [User guide](../docs/USER-GUIDE.md), [operations](../docs/OPERATIONS.md), [testing](../docs/TESTING.md) and [troubleshooting](../docs/TROUBLESHOOTING.md).

This library has no standalone server executable. The sections below summarize
shared behavior; commands in the Checks section run from this library directory.

## Common configuration

Process environment supplies settings; `.env` is not loaded automatically.
Booleans accept exactly `true` or `false`; invalid settings fail startup.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ALLOW_INSERT_OPERATION`, `ALLOW_UPDATE_OPERATION`, `ALLOW_DELETE_OPERATION`, `ALLOW_DDL_OPERATION` | `false` | Independently permit simple writes/table DDL |
| `SCHEMA_INSERT_PERMISSIONS`, `SCHEMA_UPDATE_PERMISSIONS`, `SCHEMA_DELETE_PERMISSIONS`, `SCHEMA_DDL_PERMISSIONS` | empty | Per-operation overrides, e.g. `development:true,production:false` |
| `MULTI_DB_WRITE_MODE` | `false` | Extra write opt-in when MySQL has no database or PG schema is empty |
| `ENABLE_PII_REDACTION` | `false` | Query guards, schema filtering, recursive masking |
| `PII_EXTRA_COLUMNS` | empty | Comma-separated sensitive column substrings |
| `PII_EXTRA_COLUMN_PATTERNS` | empty | Semicolon-separated regex bodies, case-insensitive |
| `PII_REDACT_JSON_STRINGS` | `true` | Parse JSON strings and redact nested values |
| `PII_ALLOW_SELECT_STAR` | `false` | Override wildcard guard; result masking remains active |
| `PII_ALLOW_REFERENCES` | `false` | Override sensitive identifier guard |
| `PII_ALLOW_INTROSPECTION` | `false` | Override SQL metadata guards; resource filtering stays active |
| `PII_BLOCK_INTROSPECTION` | `false` | Block otherwise filterable SQL metadata too |
| `IS_REMOTE_MCP` | `false` | Select HTTP transport |
| `REMOTE_SECRET_KEY` | unset | Required for HTTP; exact bearer token |
| `MCP_HTTP_HOST`, `PORT` | `127.0.0.1`, `3000` | HTTP bind IP and port |
| `MCP_ALLOWED_ORIGINS` | empty | Comma-separated accepted Origins; Origin-bearing requests denied by default |
| `MCP_DASHBOARD` | `false` | Enable private local diagnostic snapshots |
| `MCP_DASHBOARD_DIR` | XDG state directory or `~/.local/state/mcp-ex` | Same private directory for publisher and viewer |
| `MCP_MAX_REQUEST_BYTES` | `1048576` | Maximum SQL/message input bytes |

Schema overrides replace each operation's global default. MySQL permission
matching is case-insensitive and conflicting denies win. PostgreSQL unquoted
names are lowercased; quoted schema names match exactly.

## SQL and transaction boundaries

Accepts one statement with an optional trailing semicolon. SELECT, WITH,
EXPLAIN, SHOW, DESCRIBE/DESC and VALUES execute in native read-only transactions
and roll back. Permitted ordinary writes commit on success and roll back on
error. PostgreSQL DDL is transactional. **MySQL DDL implicitly commits and
cannot be rolled back by this server.**

The lexer is conservative, not a general SQL AST parser. Writes require an
unambiguous single-table target. INSERT SELECT, modifying write CTEs, joined or
multi-table writes, table inheritance modifiers, schema moves, foreign-key
definitions, CREATE AS/LIKE, CASCADE and stored-program DDL are refused. USE,
SET, CALL, COPY, file-access SQL, manual transaction control and executable
comments are disabled. Use doubled single quotes in strings; backslash escapes
are refused. MySQL identifiers use backticks; double-quoted MySQL SQL and nested
MySQL comments are refused to avoid sql_mode-dependent interpretation.

Operation/schema checks apply to the explicit target. Database grants remain
the authority for function, trigger, view and foreign-key effects. Native
read-only enforcement constrains writes within the current transaction. There is
no cross-call transaction/current-database state. Results return in full; use
LIMIT for large reads. Timeouts bound work, not result size.

## PII and result encoding

PII mode hides sensitive columns in MCP resources and rejects sensitive SQL
identifiers, including predicates and aliases. Wildcards are refused, while
COUNT(*) is allowed. The conservative star check also rejects multiplication;
use an expression without `*` or opt in with `PII_ALLOW_SELECT_STAR`.

MySQL SHOW COLUMNS/FIELDS/INDEX/KEYS, DESCRIBE and EXPLAIN table results have PII
rows filtered. Unrecognized shapes fail closed. Arbitrary catalog SQL is blocked
by default; use MCP resources for PostgreSQL column discovery.

Returned values, including PostgreSQL RETURNING rows, are masked recursively by
column substrings/regex and email, US phone/SSN, IPv4 and Luhn-valid card patterns.
Numeric sensitive values and JSON strings are covered. Detection is heuristic;
encoded/obfuscated PII can evade patterns. Allowing sensitive references can
expose derived values without a sensitive output name.

DECIMAL/NUMERIC and integers outside JavaScript's exact range become strings.
Date/time values use ISO strings; invalid UTF-8 uses `{"base64":"..."}`.
Database errors return codes without SQL/failed-row values. Logs use stderr;
stdio stdout contains only MCP messages.

## HTTP and parity

POST `/mcp` returns stateless JSON responses. Headers:
`Authorization: Bearer <REMOTE_SECRET_KEY>`, `Content-Type: application/json`,
`Accept: application/json, text/event-stream`; send the negotiated
`MCP-Protocol-Version` on subsequent requests. Notifications return 202; GET and
DELETE return 405. No SSE subscriptions, sessions, prompts, OAuth server or
resumability are advertised. Initialization supports MCP 2025-11-25,
2025-06-18, 2025-03-26 and 2024-11-05.
[Transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).

For public HTTP use, terminate HTTPS at a reverse proxy. Remote static bearer
authentication follows the source's remote mode.

Differences from the reference: qualified resource URIs, working root resource
reads, exact token matching, write-result redaction, and default-scoped table
discovery. Native read-only protection cannot be disabled. Connection strings
are database URLs, not mysql CLI commands. No dotenv loader, SSH-tunnel launcher,
arbitrary DDL, or aliases for every mysql2 setting; use an external SSH tunnel.
Pool size uses `*_POOL_SIZE`.

## Checks

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

ExUnit covers configuration, SQL policy, masking, protocol lifecycle, resource
shapes and HTTP boundaries without a database. [License](../LICENSE).


## Dashboard internals

`McpEx.Diagnostics` owns optional aggregate counters, bounded background samples
and private atomic snapshots. `McpEx.Monitor` provides status/resources, JSON and
watch views. The escript dispatches viewer commands before database configuration
or pool startup. The adapter supplies `pool_metrics(context)` through
DBConnection. No dashboard dependencies, new connections or listener are added.
See [developer contracts](../docs/DEVELOPER-GUIDE.md#dashboard-implementation)
and [operator instructions](../docs/DASHBOARD.md).
