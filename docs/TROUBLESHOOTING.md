# Troubleshooting

Start by checking the exact executable, launch environment, database endpoint,
default schema and transport. A working shell connection does not prove that a
GUI-launched server inherits the same credentials or asdf `PATH`. Configuration
changes require a process restart and source changes require rebuilding the
affected escript.

## Installation and startup

| Symptom | Cause/check | Action |
| --- | --- | --- |
| `mix` or `elixir` not found | asdf/runtime is missing from the shell | Install the pinned versions from the workspace root and check asdf's selected runtime |
| Erlang compilation fails | Missing native build prerequisite | Inspect the asdf/kerl build log; install the reported prerequisite and retry |
| Missing dependencies or core path | Dependencies not fetched in that project, or sibling core missing | Keep the three folders together and fetch dependencies in each |
| `escript` not found in a client | GUI/service launch does not inherit your shell PATH | Supply an explicit launch environment or use the [asdf wrapper](OPERATIONS.md#process-launch-and-lifecycle) |
| `.env` edits have no effect | Files are not loaded by the server | Export a trusted file or configure the client environment, then restart |
| `... must be true or false` | Empty, uppercase, numeric or another invalid boolean | Use exact `true`/`false`, or unset it for the default |
| `... must be an integer from 1 to ...` | Invalid port, pool size, timeout or request limit | Use the range in [Configuration](CONFIGURATION.md); zero is not an unlimited setting |
| `MCP_HTTP_HOST must be an IP address` | A hostname such as `localhost` was supplied | Use `127.0.0.1`, `::1` or another literal bind address |
| `Use --stdio or --http` | Unknown flag, including `--help` or `--version` | Use the supported transport flags and environment settings |
| `Choose one transport` | Both flags were provided | Launch with only one transport flag |
| Remote secret required during stdio startup | `IS_REMOTE_MCP=true` is inherited | Set it to `false`/unset it for local mode, or supply the required secret |
| `Server startup failed; check database connectivity and configuration` | Pool startup or SELECT 1 probe failed | Verify host/port, user/password, database, reachability, TLS and socket settings using the same launch environment |

The generic startup error deliberately omits database error text. Check database
server logs with appropriate access rather than expecting passwords/SQL to be
echoed. A URL overrides several individual settings: remove stale
`*_CONNECTION_STRING` or socket values when testing another TCP endpoint.
Connection URLs do not accept SSL query options or CLI/libpq keyword strings.

TLS certificate and key must be provided together. Invalid/missing/empty PEM
files fail when TLS reads them; a parseable file can still fail trust or hostname
verification during the handshake. Use the effective URL/environment hostname
matching the certificate and the correct CA. PostgreSQL's socket setting is a
directory; MySQL's is a file.

## Stdio and initialization

A silent process is waiting for input. Use a configured MCP client, or send
newline-delimited JSON-RPC with this sequence: `initialize`,
`notifications/initialized`, then tool/resource requests. Do not paste HTTP
headers or an array of requests into stdio. Pretty-printed multiline JSON is
not a stdio frame; each message must occupy one line.

If the client reports invalid JSON from stdout, launch the built escript and
check any wrapper for banner/echo/Mix compilation output. Startup diagnostics
and logging must use stderr. An oversized input frame emits `-32700` and exits;
reduce the request or configure the limit before restarting. Ordinary malformed
JSON emits a parse error but the loop can continue.

If a rebuilt source test passes but a client still behaves differently, verify
that the client points to the newly built artifact. Rebuild both applications
after shared-core changes.

## Query and metadata problems

| Symptom | Explanation/action |
| --- | --- |
| Wrong placeholder or parameter encoding | Use `?` for MySQL and `$1`/`$2` for PostgreSQL; provide an array with driver-compatible values, not SQL identifiers |
| `SQL statement type is disabled` | Session commands, explicit transactions, unsupported DML/DDL and stored programs are outside the policy |
| `Exactly one SQL statement is required` | Remove additional statements; one final semicolon is allowed |
| `Complex writes are disabled` | Simplify to an explicit single-table statement without joins/subselects; see [supported SQL](SECURITY.md#supported-sql) |
| Operation is not permitted for a schema | Check explicit target, global flag, schema override and multi-write gate; database grants are also required |
| Upsert fails despite insert permission | An INSERT containing UPDATE also requires update permission |
| `Writes require a schema-qualified table` | Default database/schema is unset; qualify the target and configure the multi-write/operation permissions |
| Modifying function/CTE/EXPLAIN fails | Read forms run in native read-only transactions, even when write flags are enabled |
| PII wildcard error for multiplication | The conservative guard rejects other `*` tokens as well as wildcard projections; use another expression or review the explicit star override |
| Protected PII identifier error | A column, predicate, alias, table or function token matches a sensitive substring/regex; inspect the name before relaxing reference guards |
| Catalog query blocked in PII mode | Use MCP table resources; catalog identifiers and `pg_*` tokens are blocked by default |
| Cannot safely filter introspection | A recognized SQL metadata result has an unsupported column shape; use resources |
| Resource URI not accessible | Use the scheme/URI returned by discovery and check the default scope and database grants |
| Resource missing sensitive columns | PII mode deliberately omits their column entries |
| PostgreSQL table not found | Verify `PG_DB`, `PG_SCHEMA` and quoted identifier case; there is no configured public fallback from another selected schema |
| MySQL row count differs from COUNT | Table resource counts are metadata estimates |
| Repeated output column disappears | Row maps overwrite duplicate names; select unique aliases |
| Decimal or large integer arrives as a string | This preserves exact values through JSON/JavaScript; parse with an appropriate numeric library if needed |
| HTTP 200 contains a failed query | Inspect the JSON-RPC `error` or tool `result.isError`; status alone does not indicate query success |

PII masking is heuristic. A result that contains unexpected sensitive data should
be treated as a detection gap; narrow database access and review the configured
patterns/output names rather than assuming a flag provides complete coverage.

Read-only schema scope controls discovery/default name resolution, not a SQL
allowlist. If another qualified schema can be read, inspect the database user's
grants. PostgreSQL multi mode is multi-schema within one database; use another
process for another database.

There is no result-byte cap or pagination. For large results/timeouts, reduce
selected columns and row count, inspect the query plan through an allowed read,
and review driver/server timeouts. Increasing the input limit does not improve
result-size control. After an uncertain write outcome, inspect committed state
before retrying. MySQL DDL cannot be rolled back by a later MCP call.

## HTTP status codes

Checks occur in this order: path, bearer, Origin, protocol version, method,
Accept, Content-Type, body size/JSON. Fix the earliest failing check first.

| Status | Meaning/action |
| --- | --- |
| `200` | JSON-RPC response, including RPC errors or failed tool results; inspect the body |
| `202` | Accepted notification/client response envelope; no body |
| `400` | Unsupported/duplicate protocol header, unreadable body or malformed JSON; malformed JSON uses RPC code -32700 |
| `401` | Missing/duplicate/wrong Authorization; the prefix is exactly `Bearer ` and the token must match exactly |
| `403` | Origin not in the exact allowlist, or multiple Origin values |
| `404` | Wrong path; use `/mcp` |
| `405` | Authenticated request uses a method other than POST; `Allow: POST` is returned |
| `406` | Accept omits `application/json` or `text/event-stream` |
| `413` | Body exceeds `MCP_MAX_REQUEST_BYTES` |
| `415` | Content-Type is not application/json |

Use the [curl examples](OPERATIONS.md#http-request-contract) to separate client
configuration errors from server behavior. A browser OPTIONS preflight is
unsupported even with an allowed Origin. An unauthenticated GET returns 401
before the method check; that does not mean a GET stream is supported.

## JSON-RPC and tool errors

| Code/envelope | Meaning |
| --- | --- |
| `-32700` | Invalid JSON or stdio framing/input error |
| `-32600` | Invalid request structure/ID; only string or integer request IDs are supported |
| `-32601` | Method not implemented |
| `-32602` | Invalid RPC parameters, initialize fields, resource URI type or unknown tool |
| `-32603` | Internal/driver failure at RPC dispatch; details are sanitized |
| `-32000` | Stdio tool/resource request before initialization finishes |
| `-32002` | Unknown, invalid, nonexistent or inaccessible resource URI |
| `result.isError: true` | Tool validation, policy or execution failure; inspect its single text item |

Database failures normally return `Database operation failed` with an available
database code, not the full engine message, SQL or failed-row values. Policy and
argument errors can return specific validation text. A resource failure may be
a JSON-RPC error rather than a failed tool envelope because resources are a
separate dispatch path.

## Test failures

Use the [testing guide](TESTING.md) to confirm fixture ports, credentials and
build steps. `bin/check` does not start databases or install npm dependencies.
An Elixir `MCP_TEST_*_PORT` override does not change SDK ports. Stop stale test
HTTP processes if ports 13007/13008 are occupied, and inspect the test Compose
logs if fixture initialization is incomplete. Reset only the `mp-mcp-test`
Compose project when a failed mutation leaves fixture state behind.

Upstream driver deprecation warnings under Elixir 1.20 were observed during the
recorded run; they are distinct from warnings/errors in application code.
Record the actual failed stage and command in `.worklog/` before claiming a fix.
