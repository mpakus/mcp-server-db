# Security and SQL policy

The servers combine a conservative SQL policy, native read-only transactions,
explicit write permissions and optional PII masking. Database grants remain the
authority for which objects and indirect effects an account can access. Configure
a restricted database account even when all MCP write flags are disabled.

## Write permissions

For each operation required by a statement, the policy:

1. Resolves the explicit target to a MySQL database or PostgreSQL schema. An
   unqualified target uses the configured default; without a default, writes
   require a qualified table name.
2. Requires a configured default scope or `MULTI_DB_WRITE_MODE=true`.
3. Looks up the operation's schema override; if absent, uses its global flag.
4. Rejects the statement if any required operation is denied.
5. Applies SQL-shape and PII guards, then executes under the database account's
   native grants.

Schema overrides can enable a particular schema while the global flag stays
false. For example, allow inserts and updates only in a MySQL development
database:

```sh
export MYSQL_DB='development'
export ALLOW_INSERT_OPERATION=false
export ALLOW_UPDATE_OPERATION=false
export SCHEMA_INSERT_PERMISSIONS='development:true,production:false'
export SCHEMA_UPDATE_PERMISSIONS='development:true,production:false'
```

Or allow PostgreSQL updates only in `legacy`:

```sh
export PG_DB='app'
export PG_SCHEMA='legacy'
export ALLOW_UPDATE_OPERATION=false
export SCHEMA_UPDATE_PERMISSIONS='legacy:true,public:false'
```

Restart the server after exporting settings. The examples assume other write
settings remain at their default `false`. An upsert containing `UPDATE` requires
both insert and update permission. DDL has its own permission and does not imply
insert/update/delete permission, even though `TRUNCATE TABLE` removes rows.

MySQL override matching is case-insensitive; conflicting case variants deny.
PostgreSQL matching is exact after SQL identifier normalization: unquoted
`Legacy.users` means `legacy.users`, while `"Legacy".users` preserves the case.
Permission CSV syntax is in [Configuration](CONFIGURATION.md#write-permissions).

For multi-database MySQL writes, unset/empty `MYSQL_DB` and set
`MULTI_DB_WRITE_MODE=true` plus operation or schema permission. For PostgreSQL,
set `PG_SCHEMA=` and use schema-qualified targets in the connected database.
Multi mode never crosses PostgreSQL databases.

The default discovery scope does not restrict all qualified SQL targets. If a
global write flag is true, explicitly qualified writes to another schema can be
permitted unless an override or database grant denies them. Use false global
defaults plus explicit true overrides for a narrow write scope.

Tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`) describe
configured capabilities for clients; they are hints, not an authorization
decision for each statement.

## Transaction boundaries

| Operation | MySQL | PostgreSQL |
| --- | --- | --- |
| Read | Checks out one connection, sets the next transaction read-only, executes and rolls back after obtaining results | Opens a transaction, sets it read-only, executes and rolls back after obtaining results |
| Insert/update/delete | Executes in a transaction and commits on success | Executes in a transaction and commits on success |
| Table DDL | Executes directly because MySQL DDL implicitly commits | Executes in a transaction and commits on success |
| Failed transactional query | Driver transaction rolls back | Driver transaction rolls back |

There is no cross-call transaction state. `WITH` and `EXPLAIN` are routed as
reads; enabling write flags does not turn modifying CTEs or `EXPLAIN ANALYZE`
on writes into write operations. The database's read-only transaction rejects
prohibited mutations. Native read-only behavior has engine-specific exceptions;
it does not prevent every external effect of functions or extensions.

Permissions inspect the explicit target, not every object touched by a trigger,
view, function, foreign key or extension. Native grants and database design must
constrain those effects. A query timeout or lost connection does not, by itself,
prove whether a write committed. Inspect the database before retrying a write
with uncertain outcome. MySQL DDL cannot be undone by rolling back an MCP call.

## Supported SQL

The policy is a lexer plus a small statement classifier, not a full SQL parser.
Passing the policy means a statement may be sent to the database, not that its
syntax is valid or its execution will succeed. Supported shapes include:

| Shape | Conditions |
| --- | --- |
| `SELECT`, `WITH`, `SHOW`, `DESCRIBE`, `DESC`, `EXPLAIN`, `VALUES` | Read-only transaction; engine syntax, token and PII restrictions still apply |
| `INSERT INTO table (...) VALUES (...)` | One explicit target; no SELECT/JOIN/WITH/DELETE/INSERT in the remainder |
| `UPDATE table SET ...` | Target followed immediately by SET; no joins, FROM, subselects or additional modifying keywords |
| `DELETE FROM table [WHERE ...] [RETURNING ...]` | One target; no aliases, USING, joins or subselects |
| `CREATE TABLE table (...)` | Explicit column definitions; no SELECT or cross-object constructs listed below |
| `ALTER TABLE table ...` | One target; no schema moves, renames or cross-object constructs |
| `DROP TABLE [IF EXISTS] table` | One table; no trailing options, additional tables or CASCADE |
| `TRUNCATE [TABLE] table` | One table; no trailing options or CASCADE |

Examples of tool argument objects for already-authorized writes:

```json
{"sql":"INSERT INTO users (id, label) VALUES (?, ?)","params":[99,"sample"]}
```

```json
{"sql":"UPDATE legacy.users SET label = $1 WHERE id = $2 RETURNING id, label","params":["sample",99]}
```

```json
{"sql":"DELETE FROM legacy.users WHERE id = $1 RETURNING id","params":[99]}
```

```json
{"sql":"CREATE TABLE legacy.mcp_example (id bigint PRIMARY KEY, label text)","params":[]}
```

These examples require the relevant permissions and database objects; they are
not setup commands to run against an application database. Bound values avoid
SQL string construction. Identifier names cannot be bound as parameters.

The policy rejects multiple statements, allowing only an optional final
semicolon. It also rejects file SQL (`OUTFILE`, `DUMPFILE`, `LOAD_FILE`), session
or transaction commands, stored-program DDL, grants and unsupported statement
types such as `REPLACE`, `MERGE` or `CALL`. Complex writes and cross-object DDL
are refused, including references/foreign keys, rename/exchange, attach/detach,
inheritance and CASCADE. There is no bypass flag for these SQL restrictions.

Quoted strings use doubled quotes rather than backslash escapes. MySQL uses
backticks for quoted identifiers; double-quoted MySQL SQL is rejected because
its meaning depends on `sql_mode`. PostgreSQL uses double quotes for identifiers
and supports dollar-quoted strings and `$n` placeholders; backticks are rejected.
MySQL executable comments and nested MySQL block comments are rejected. Normal
comments are skipped; semicolons inside ordinary string literals do not create
extra statements. Unsupported tokens, such as MySQL `@` variables, fail before
database execution.

Conservative keyword/token checks can reject valid database SQL. Simplify the
statement to an explicit single-table form, or use a separate controlled
database administration workflow for operations this server does not support.

## PII mode

Enable `ENABLE_PII_REDACTION=true` to activate all three layers:

- SQL guards reject sensitive identifiers and wildcard projections by default.
- Table resources omit sensitive column entries. Recognized SQL column metadata
  also has sensitive rows filtered unless introspection is explicitly allowed.
- Tool results, including write `RETURNING` rows, are recursively masked.

Built-in case-insensitive sensitive name substrings are:

```text
email e_mail ssn social_security phone mobile
first_name last_name full_name middle_name given_name family_name surname
forename maiden_name preferred_name legal_name
address street zip postal_code dob date_of_birth
credit_card card_number cc_number cvv
password passwd pwd api_key secret token ip_address ipaddress
```

`PII_EXTRA_COLUMNS` adds substrings; `PII_EXTRA_COLUMN_PATTERNS` adds
case-insensitive regular expressions. Matching is conservative: words,
identifiers, aliases, table names and function names can all trigger the SQL
reference guard. Literal strings and bound values are not checked by that
identifier guard.

The wildcard guard permits `COUNT(*)`. Other `*` tokens, including multiplication
and qualified/nested wildcards, are rejected by default. Set
`PII_ALLOW_SELECT_STAR=true` to override that guard; result masking still runs.

### Introspection

Under default PII settings, MySQL column metadata forms such as
`SHOW COLUMNS`, `SHOW FIELDS`, `SHOW INDEX`, `SHOW KEYS`, `DESCRIBE` and table-form
`EXPLAIN` are recognized and filtered. Unknown column-result shapes fail closed.
Recognized topology queries such as `SHOW TABLES` and `SHOW DATABASES` can pass.

Catalog identifiers (`information_schema`, `mysql`, `performance_schema`, `sys`,
`pg_catalog` and names beginning `pg_`) and other SHOW forms are blocked by
default. The prefix rule can also reject an ordinary object named `pg_*`.
PostgreSQL users should use MCP resources for column discovery.

`PII_BLOCK_INTROSPECTION=true` blocks recognized SQL introspection including
topology. `PII_ALLOW_INTROSPECTION=true` overrides that rejection and disables
SQL column-row filtering. It does not override the star/reference guards, and
MCP resource column filtering remains enabled. Resource metadata receives type
normalization; default expressions and other metadata fields do not receive the
full tool-result value-masking pass.

### Masking and limits

Sensitive keys cause their descendants to be masked. Sensitive numeric and
boolean values become `***`; null remains null. Strings are masked by detected
email, US phone/SSN, IPv4 and Luhn-valid card patterns, or become `***` when a
sensitive key has no recognized value pattern. Empty strings remain empty.
Patterns can also mask strings under non-sensitive keys. Examples include partial
email masking and retaining
only the last four digits of a recognized phone, SSN or card.

With `PII_REDACT_JSON_STRINGS=true`, object/array JSON strings are parsed,
recursively masked and serialized back to strings. Actual maps and arrays are
processed recursively regardless of that setting.

Detection is heuristic. Encoded, obfuscated or derived PII may evade it. Allowing
sensitive SQL references can expose derived values under a non-sensitive alias;
numeric values under non-sensitive keys are not scanned like strings. Binary
base64 normalization is not decoded-content PII analysis. PII mode is not a
replacement for access control or evidence of a compliance certification.

## Transport and resource boundaries

Stdio delegates process access to the client and operating system; it has no
per-message authentication. HTTP requires one exact `Bearer <token>` header,
rejects unapproved Origin values and limits request bodies. All HTTP clients
using a token share the same configured database identity and permission set.
There is no per-client role, OAuth server, token-expiration store or session ACL.

HTTP defaults to loopback and serves plain HTTP. Terminate HTTPS at a reverse
proxy for network exposure. Database TLS is configured separately. Origin
checking does not authenticate a caller that can omit the header. Browser CORS
preflight and GET event streams are unsupported. See [Operations](OPERATIONS.md).

Request limits and timeouts bound input/work, not output size or client
concurrency. Table/resource lists and query results are returned in full, without
pagination, rate limiting or a result-byte cap. Use database restrictions,
explicit columns and bounded queries for large or shared deployments.
