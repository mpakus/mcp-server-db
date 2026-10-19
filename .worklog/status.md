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

## Documentation update — 2026-10-05

Requested a full user/developer reference under `docs/` and updated READMEs.
Source review, guide authoring and documentation validation are complete. The
reference covers installation, client usage, all 54 configuration variables,
security/SQL policy, operations, architecture, development, testing and
troubleshooting. Local links/anchors and JSON/shell examples passed checks.
Tasks and exact evidence are tracked in [docs.md](docs.md). The runtime
verification above remains dated 2026-09-30; application code was unchanged.

## Completion audit — 2026-10-19

The current full check passes: 14 ExUnit tests, both escript builds and official
SDK stdio/HTTP checks. Documentation links/examples and all 54 configuration
variables also pass verification.

Release readiness remains open. The audit reproduced a PostgreSQL three-part
ALTER schema-permission bypass, a failed stderr logger redirect that corrupts
stdio on MySQL timeout, and quoted MySQL LOAD_FILE bypassing the file-SQL guard
when native FILE privilege is present. Hex reports one high and two medium
advisories against the locked Bandit/Decimal versions; patched versions exist.
Application fixes and dependency upgrades were not applied during this audit.

Reproductions, current updates, passed checks, scope limits and the outstanding
fix checklist are recorded in [audit-2026-10-19.md](audit-2026-10-19.md).

## Audit fixes — 2026-10-19

All three reproduced defects are fixed. Shared write target parsing rejects a
third name component; file-SQL checks include quoted/mixed-case identifiers while
preserving string literals; the logger handler is recreated on stderr with its
formatter/settings preserved and checked setup, including the corrected primary
configuration map.

All three Mix projects now lock Bandit 1.13.1, Decimal 3.1.2 and Bandit's required
Thousand Island 1.6.0. Minimum constraints exclude the affected versions. All
three Hex audits report no retired or security-advisory packages.

`MCP_INTEGRATION=true ./bin/check` passed 16 tests (12 core, 2 MySQL, 2 PG),
both escript builds, SDK stdio/HTTP checks with four concurrent HTTP clients,
and real timeout/JSON-only stdout/stderr/EOF probes for both applications.
Regressions reproduced the failures before implementation changes. The
TypeScript reference and root runtime pins were untouched. See
[fixes-2026-10-19.md](fixes-2026-10-19.md) for exact evidence and scope limits.

## Dashboard planning — 2026-10-19

Analyzed a simple server dashboard. The recommended first release is a separate
CLI/watch viewer reading private opt-in instance snapshots, shared across MySQL
and PostgreSQL and working with both stdio and HTTP. No runtime implementation
was started. Architecture, tradeoffs, metric definitions, failure isolation,
privacy, file-level work and acceptance tests are in
[docs/DASHBOARD-PLAN.md](../docs/DASHBOARD-PLAN.md); planning progress is in
[dashboard-plan-2026-10-19.md](dashboard-plan-2026-10-19.md).


## Dashboard implemented — 2026-10-19

- Both escripts provide `status`, `resources`, `--json`, `--instance` and
  `--watch`, with viewer dispatch before database/HTTP configuration or startup.
- `MCP_DASHBOARD=true` enables isolated fixed-label ETS counters, private atomic
  snapshots and bounded health/pool/resource sampling. No runtime dependencies
  or listeners were added. Query/parameter/result/error/credential/client data
  are excluded from snapshots; topology/resource names remain visible.
- The README and canonical Markdown guides now document enablement, commands,
  counters, freshness, exit codes, privacy, contracts, failure behavior and a
  reproducible fixture demo. `docs/images/dashboard.jpg` is a rendered screenshot
  of actual CLI stdout; the text capture is retained beside it.
- `MCP_INTEGRATION=true ./bin/check` passed 24 ExUnit tests (20 core, two MySQL,
  two PG), warning-as-error compilation, escript builds and official SDK stdio/
  HTTP checks for both databases. Diagnostics was enabled during real SDK and
  raw timeout/framing/EOF checks. Viewer tests supplied invalid DB/HTTP settings,
  exercised JSONL watch cancellation and verified the server remained usable.
- Documentation checks passed for 14 Markdown files, 163 local links/anchors,
  16 JSON examples and 56 shell snippets (syntax only). Original TypeScript
  checkout stayed clean. Disposable demo/server/preview processes and Compose
  fixtures were stopped after verification.

Details and known limits: [dashboard-2026-10-19.md](dashboard-2026-10-19.md).
No production/load/overhead benchmark, full-disk fault injection or remote admin
interface is claimed. Earlier TLS/socket/deployment validation limits remain.
