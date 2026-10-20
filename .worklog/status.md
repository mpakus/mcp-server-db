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

## Performance and OTP review — 2026-10-20

Reviewed session state, process ownership, supervision, database pooling and
request execution. HTTP is stateless and concurrent across connections; stdio
keeps lifecycle state in a serial recursive loop. Diagnostics explicitly uses
a GenServer, spawned workers, messages, monitors and timers.

The full check passed 24 tests, both builds and SDK/diagnostics/transport checks.
A separate three-trial local probe reproduced stdio head-of-line blocking and
large framing overhead: four 200 ms queries took about 835 ms over stdio versus
210 ms over HTTP; a 256 KiB padded ping took 4.4–4.6 seconds over stdio versus
1–2 ms over HTTP. No application code was changed.

Evidence, source anchors, reproduction script and scope limits are in
[performance-review-2026-10-20.md](performance-review-2026-10-20.md).

## Elixir skills installed — 2026-10-20

Searched and reviewed community skills for Elixir/OTP/BEAM and Erlang. Installed
`staff-level-elixir` and `erlang-best-practice` into the personal Codex skills
directory from exact reviewed commits. All 32 installed files match the review
copies, metadata parses correctly and local references resolve. No executable
scripts or hooks were installed. Sources, rejected alternatives and limitations
are recorded in [elixir-skills-2026-10-20.md](elixir-skills-2026-10-20.md).

## Supervised MCP sessions — 2026-10-20

Implemented one temporary GenServer per logical MCP session, a shared registered
pool, Registry, bounded supervised query workers and dependent-component
supervision. Both transports retain initialization/version state. HTTP adds
session IDs, DELETE and idle expiry; stdio adds bounded raw input with exclusive
stdin ownership and response draining on EOF. Cancellation, request deadlines,
duplicate-ID protection, response-byte and session/worker limits are in place.

The first integration run passed existing SDK/dashboard checks and confirmed
responsive stdio pings. New framing tests caught competing OTP stdin ownership;
the escripts now embed `-noinput`, and a Registry death race is also fixed.
Final verification passed 38 ExUnit tests, both builds, official SDK and
dashboard checks, plus real cancellation/framing/EOF/session tests on both
databases. The independent local probe reduced four concurrent 200 ms stdio
queries from about 835 ms to 205–210 ms and 256 KiB pings from 4.4–4.6 seconds
to 0.7–1.4 ms. Disposable fixtures were removed. Exact results and limits are in
[session-implementation-2026-10-20.md](session-implementation-2026-10-20.md).

## Repeated before/after benchmarks — 2026-10-20

Built clean archived copies of `b542550` and `9646c0a` with identical lockfiles
and fresh compilation. Benchmarked both adapters over stdio and HTTP against
the same disposable fixtures, with five samples per workload and ten warm-up
queries. The shared harness checked 528 JSON-RPC responses; all eight scenarios
completed, producing 280 timing samples and 40 observed query/ping orders.

The stdio four-query batch improved from 831.15 to 206.93 ms for MySQL and
839.04 to 208.38 ms for PostgreSQL. Slow-query ping latency dropped below 0.4 ms,
and 256 KiB input latency fell from 4.3–4.5 seconds to about 1 ms. HTTP batch
latency remained 208–211 ms. Added the comparison to the root README and saved
the [raw samples/environment](../docs/benchmarks/session-processes-2026-10-20.json),
[reproduction instructions](../docs/benchmarks/README.md) and
[assert-based harness](../test/benchmark.mjs). These are local latency probes;
CPU/memory, production workloads, sustained throughput and tail latency remain
unmeasured. No application code was changed.

Validation: all README medians match the saved samples, benchmark JavaScript
and documented shell blocks parse, local documentation links resolve and
`git diff --check` passes. Removed disposable containers/network and isolated
build directories; retained the source revisions, build log and raw evidence.

## Local throughput stress test — 2026-10-20

Using RTK/Ponytail and disposable Compose fixtures, added an assert-based stress
harness for both adapters over stdio and HTTP. Captured benchmark-relevant
hardware, power, runtime, database, dependency and Docker VM versions without
device serial numbers or network identifiers. The harness separates successful
RPS from busy replies, validates returned rows, and measures latency, BEAM CPU,
sampled RSS and generator utilization.

Exploratory pool-64 measurements found one busy reply in a long full-cap run;
the final campaign confirms candidates below the worker cap. The sweep was
expanded to pools 128 (MySQL) and 96 (PostgreSQL), within the existing database
connection limits. An overlapping restart attempt was discarded; its timings
are not included in the final campaign. Completed uncontaminated exploratory
phases are retained separately. No server code/settings were persisted.

Completed 82 final phases: 6,740,570 validated successful responses, zero
unexpected errors and 1,202,096 separately counted busy replies, predominantly
from intentional overload. PostgreSQL HTTP's 94-concurrency confirmation was
rejected after a busy reply; 92 passed. The four selected settings completed
3,645,110 responses across twelve 30-second runs with no errors or busy replies.
Median successful RPS: MySQL stdio 9,002.58, MySQL HTTP 12,963.17, PostgreSQL stdio
8,399.46, PostgreSQL HTTP 10,220.55. All four 15-second bound lookups also passed.

Added hardware/software versions and a throughput/latency summary to the root
README, with [methodology and resource tables](../docs/benchmarks/STRESS.md) and
[raw phases, histograms and environment](../docs/benchmarks/stress-2026-10-20.json).
Source/build hashes, phase durations, histogram counts, per-second totals,
successful-RPS calculations and selected zero-error runs were cross-checked.
These are observed local rates under finite tested settings; production SQL,
network/TLS workloads, database/VM resource use and long-term soak behavior remain
outside the measurements. Full ExUnit checks were not rerun; server code is unchanged.

Final checks passed: harness syntax, 44 local documentation links, documented
shell syntax, exact README/result agreement and `git diff --check`. All fixture
containers and their network were removed after the completed run.

## Stdio throughput improvement — 2026-10-20

Using RTK, Ponytail, staff-level-elixir and erlang-best-practice. The existing
stdio session is already a supervised GenServer. Preserve that lifecycle and
bounded query workers; optimize overhead around the single stream. Saved freshly
built baseline escripts from `ffce357` before editing. First candidate coalesces
already queued responses into bounded writes without a batching delay and indexes
active request IDs for direct duplicate/cancellation lookup. Regression checks
cover typed IDs, ID reuse, pipelined lifecycle, response bursts and EOF draining.
Fresh before/after measurements and HTTP session-count controls are in progress.

Full correctness gate passed: 39 ExUnit tests (35 core, two per adapter),
formatting, application compilation with warnings as errors, both builds and
all SDK/dashboard/raw transport checks on disposable MySQL/PostgreSQL. The
32-phase comparison smoke check passed. The first full engine comparison
confirms MySQL stdio median 8,726.54 -> 12,754.74 RPS at concurrency 124, with
zero busy/error responses in all confirmations. PostgreSQL and the remaining
HTTP controls are running sequentially; no parallel load generators are used.

Completed the full comparison: 72 measured phases, 11,268,662 validated successful
responses, zero unexpected errors and 300,374 busy replies confined to deliberate
overload phases. All 30 confirmations completed 9,427,093 successful responses
with zero busy/errors. Fresh stdio medians improved 8,726.54 -> 12,754.74 RPS
(+46.2%) for MySQL and 8,031.31 -> 9,581.55 RPS (+19.3%) for PostgreSQL. The
comparison kept pool/limit/concurrency fixed within each engine; one- and
four-session HTTP controls reached similar rates. HTTP four-session median
changes (-2.0% MySQL, -0.3% PG), ranges and latency/resource results are explicitly
reported rather than assuming no change. No individual-change ablation was run.

Updated the root README, developer/testing guides and benchmark index. Saved
[all phases, histograms, environment and source/build hashes](../docs/benchmarks/stdio-2026-10-20.json)
and [methodology, resource tables and reproduction](../docs/benchmarks/STDIO.md).
The standalone original stress entrypoint also passed its 16-phase smoke check.
All recorded source/build hashes, histogram/per-second counts, RPS calculations
and README/detailed result tables were verified; 94 local links, 20 shell
blocks, all three touched JavaScript syntax checks and git diff --check passed.
Disposed of the fixture containers/network and temporary baseline executables
after verification. Repository settings remain unchanged. Measurements cover
tiny hot reads, not production SQL, TLS, large results or long soak behavior.


## 2026-10-20 — optional query cache

Implemented disabled-by-default ETS + fixed TTL caching, per-read opt-in,
bounded admission, monitored write invalidation and generation-safe fills.
Full integration
check passed 51 ExUnit tests and both SDK transports/engines. The
[cache benchmark](../docs/benchmarks/CACHE.md) measured 23.48 million validated
responses with zero errors/rejections; cached hot-read RPS improved 6.94–10.85x.


## 2026-10-20 — consolidated four-mode benchmark and licensing

Request: refresh stdio, HTTP, stdio + cache and HTTP + cache benchmarks;
replace older README/STRESS tables and align related documentation.
Using RTK and Ponytail on base `ae54325`. Server code remains unchanged.
The harness now omits cache opt-in in uncached modes, explicitly fixes cache
bounds, labels each mode and interleaves all four modes in alternating rounds.
Completed 64 measured phases and 23,155,439 validated responses with zero errors
or busy replies. The 24 confirmations use three fresh 20-second runs per
engine/mode at concurrency 64 with a five-second cache TTL. Median stdio / HTTP /
stdio + cache / HTTP + cache RPS: MySQL 9,210 / 9,192 / 63,938 / 88,063;
PostgreSQL 7,948 / 7,982 / 63,793 / 87,865. Preserved all ranges, including the
55,680–64,030 PostgreSQL cached-stdio range. HTTP has four sessions/generator
threads versus one for stdio; tiny cached reads do not establish production
capacity or an absolute maximum.

Replaced README and [STRESS](../docs/benchmarks/STRESS.md) tables and the current
[raw artifact](../docs/benchmarks/stress-2026-10-20.json); related adapter, cache,
stdio, testing, configuration, operations and developer docs point to that report.
Earlier revision/cache raw artifacts are explicitly historical. Captured laptop,
runtime, database, driver, Docker versions/digests and 22 source/build SHA-256
hashes without hardware identifiers. Recomputed RPS, histograms, per-second totals
and summary medians and verified every recorded hash against the measured build.

Validation: default `rtk proxy ./bin/check` passed 49 ExUnit tests (two live
adapter tests excluded), format, warnings-as-errors compilation and both builds.
Four-mode smoke passed 24 phases; the standalone stress entrypoint passed 16
phases, both without errors/busy replies. The earlier full SDK/integration run
remains separate evidence; this refresh changes no application code. Checked
232 relative documentation links, 59 shell blocks and both JS syntax checks.

User also requested free noncommercial/open-source use, paid commercial use and
copyright attribution. Added Renat "MpaK" Ibragimov and https://aomega.co to the
root license, README and application READMEs. With the commercial-open-source
clarification unanswered, used the stated assumption that commercial use still
requires payment even when source is published. Free covered use is under
unmodified PolyForm Noncommercial 1.0.0, retaining its express organization
permissions; other commercial use requires a separate written paid agreement.
The [licensing guide](../docs/LICENSING.md) describes this as source-available,
explains scope and preserves previous MIT grants. Kept Ben Borla's original MIT
notice verbatim in [third-party notices](../THIRD-PARTY-NOTICES.md), and left the
reference project's MIT file unchanged. Verified the standard license text
against the official download hash. Ownership and commercial agreement terms
still require legal review before release; no price or contract was invented.

Final `git diff --check` passed. Removed the task-owned fixture containers and
network; `docker compose -f compose.test.yml ps -a` is empty. No commits or
publication were performed.
