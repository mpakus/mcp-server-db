# Elixir database MCP servers

## Tasks

- [x] Inspect the TypeScript server, query executor, permissions, redaction, resources, configuration, tests, and MIT license.
- [x] Locate and read Ponytail; run development commands through RTK.
- [x] Install RTK skill and asdf Erlang/Elixir runtime.
- [x] Implement shared MCP, configuration, SQL policy, redaction, stdio, and HTTP code.
- [x] Implement MySQL adapter and executable in `mcp-ex-mysql/`.
- [x] Implement PostgreSQL adapter and executable in `mcp-ex-pg/`.
- [x] Verify formatting, compilation, policy/protocol tests, real databases, and MCP client interoperability.
- [x] Document configuration, startup, parity, deliberate limits, and final evidence.

## Progress

2026-09-30: Analysis complete. Source checkout is unchanged. Elixir is absent;
installing through asdf as requested. Existing application databases will not be
used for mutation tests; disposable databases will be provisioned separately.

2026-09-30: Installed Erlang 28.5 and Elixir 1.20.4-otp-28 through asdf and pinned
them in `.tool-versions`. Read the existing Ponytail skill; installed RTK skill
under `.worklog/skills/rtk/` and verified the installed RTK 0.49.0. Both escripts
build. Shared protocol/policy/redaction/HTTP checks pass (10 tests). Disposable
MySQL 8.4 and PostgreSQL 16 containers are running. Integration checks revealed
MySQL metadata column casing and PostgreSQL timestamp precision differences;
the metadata aliases and the PostgreSQL expectation have been corrected.

Decimal is pinned to patched 3.1.1; initial 2.4.1 resolution was discarded after
Hex reported EEF-CVE-2026-32686. Driver dependencies emit deprecation warnings
under Elixir 1.20; application compilation succeeds with warnings as errors.

## Decisions

- Two Mix applications use one small sibling `mcp-ex-core/` library, so protocol
  and security behavior stay consistent. Drivers and database SQL stay in the
  requested application folders.
- Default transport is stdio. Remote mode uses a stateless `/mcp` HTTP endpoint;
  no browser UI is needed. Plug/Bandit suffice without Phoenix scaffolding.
- Read queries execute inside database-enforced read-only transactions. Writes
  require operation and schema permissions; reject unsupported or ambiguous
  write shapes instead of guessing. Never execute multiple statements or change
  pooled connections' current database/schema through user SQL.
- PostgreSQL connects to one database and discovers its schemas. PostgreSQL
  cannot query a different database through `database.table` as MySQL can.

2026-09-30: Implementation and repeatable verification are complete. Added setup
and configuration READMEs, `.env.example` files, lockfiles, MIT attribution,
disposable fixtures and `bin/check`. The original TypeScript checkout is clean.

## Verification

Final command: `MCP_INTEGRATION=true ./bin/check`, through RTK.

| Check | Result |
| --- | --- |
| Mix format for all three projects | Passed |
| Application compilation with warnings as errors | Passed |
| Shared ExUnit policy/configuration/redaction/protocol/HTTP checks | 10 passed |
| MySQL adapter and real MySQL 8.4 integration | 2 passed |
| PostgreSQL adapter and real PostgreSQL 16 integration | 2 passed |
| Escript builds | Both passed |
| Official MCP TypeScript SDK stdio | Both passed |
| Official MCP SDK HTTP with four concurrent clients per server | Both passed |
| Exact bearer and rejected Origin checks | Passed |
| Shell and Node syntax checks | Passed |
| Test npm dependency audit | Zero reported vulnerabilities |

Integration evidence includes parameter binding, decimal/large-integer/date
encoding, database-enforced read-only rejection of a modifying function on both
engines, PostgreSQL modifying CTE and EXPLAIN ANALYZE rejection, committed writes,
rollback after duplicate-key errors, schema denials, table DDL, MySQL filtered
SHOW COLUMNS, PostgreSQL redacted RETURNING, metadata discovery and duplicate
table names across databases/schemas. Official SDK checks verify initialization,
tools/resources, root/table resource reads, PII schema hiding, bound SQL, denied
writes and denied sensitive references on each transport.

## Practical limits

- TLS/mTLS settings and Unix sockets are implemented through the drivers, but
  live TLS/mTLS and Unix-socket database endpoints were not part of this run.
- Verification used MySQL 8.4 and PostgreSQL 16; other database/runtime versions
  were not tested. Upstream driver dependencies emit Elixir 1.20 deprecations;
  the application code passes compilation with warnings as errors.
- Deliberate SQL/parser, result-size, PII heuristic and protocol limits are
  documented in `mcp-ex-core/README.md`. Schema permissions check explicit
  targets; database grants must constrain indirect function/trigger/view effects.
- No deployment or application-database mutation was performed. Test containers
  and their disposable storage are removed after verification.
