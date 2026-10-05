# Source analysis and implementation contract

The reference is `mcp-server-mysql` v2.0.9 (`package.json`), an MIT-licensed
TypeScript MCP server using MCP SDK 1.15.1, mysql2, node-sql-parser, and Express.

| Source | Behavior to implement |
| --- | --- |
| `index.ts` | `mysql_query`, `resources/list`, `resources/read`, stdio and stateless Streamable HTTP at `/mcp` |
| `src/config/index.ts` | TCP/socket, connection settings, pooling, TLS/mTLS, operation flags and schema overrides |
| `src/db/index.ts` | Read-only transactions, opt-in writes, rollback on failure, result data and timing |
| `src/db/permissions.ts` | Per-schema override with fallback to each global operation flag |
| `src/db/utils.ts` | Statement classification, qualified target detection, PII wildcard/reference/introspection guards |
| `src/security/redact.ts` | Recursive column and value masking, JSON strings, custom column substrings/patterns |
| `README-MULTI-DB.md` | MySQL connection without a default database; writes need `MULTI_DB_WRITE_MODE=true` |

Observed source issues to avoid: resource listing omits schema from table URIs,
making identical table names ambiguous; the tables root is not read as a table
list; remote authentication uses suffix matching; `USE` mutates pooled session
state; some parser helpers fail open; write results do not use the read-result
redactor. These are findings from source inspection, not reproduced incidents.

New resource URIs include the schema/database: `mysql://tables/db/table` and
`postgres://tables/schema/table`. Single-name URIs resolve only against the
configured default. The root resource returns the table list. Both apps apply
redaction to returned write rows as well as reads. Bearer comparison is exact;
HTTP validates Origin and protocol/content headers and binds to loopback by
default, per the [MCP transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports).

Driver references: [MyXQL](https://hexdocs.pm/myxql/MyXQL.html),
[Postgrex](https://hexdocs.pm/postgrex/Postgrex.html). The implementation uses
their connection pools, transactions, parameter binding, and TLS support.

Parity is functional rather than a compatibility promise for every environment
variable or arbitrary SQL syntax. Deliberate limits and verification results
will be recorded in the READMEs and status file.
