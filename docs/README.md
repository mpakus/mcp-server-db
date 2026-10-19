# Documentation

This documentation describes the Elixir implementations in `mcp-ex-mysql/`,
`mcp-ex-pg/` and their shared `mcp-ex-core/` library. Commands start in the
workspace root unless a guide says otherwise. Replace example database names,
credentials and absolute paths with your own values.

The [2026-10-19 audit](../.worklog/audit-2026-10-19.md) identified three application
defects and dependency security patches. They are resolved in
[the follow-up fixes](../.worklog/fixes-2026-10-19.md), with regression coverage,
passing database/SDK/timeout checks and clean Hex audits.

| Guide | Audience | Contents |
| --- | --- | --- |
| [User guide](USER-GUIDE.md) | Users and client integrators | Installation, builds, stdio client configuration, tool calls, results and resources |
| [Configuration](CONFIGURATION.md) | Users and operators | Complete environment reference, URL precedence, scopes and validation |
| [Security and SQL policy](SECURITY.md) | Users, operators and developers | Permission evaluation, transaction boundaries, SQL restrictions and PII behavior |
| [Operations](OPERATIONS.md) | Operators | HTTP requests, process lifecycle, networking, TLS, sockets, tunnels and upgrades |
| [Developer guide](DEVELOPER-GUIDE.md) | Developers | Architecture, source map, internal contracts, change workflow and compatibility |
| [Testing](TESTING.md) | Developers and operators | Unit checks, disposable database setup, SDK checks and evidence limits |
| [Troubleshooting](TROUBLESHOOTING.md) | All audiences | Startup, transport, SQL and metadata problems; error/status reference |
| [Dashboard](DASHBOARD.md) | Users, operators and developers | CLI/watch setup, resources, metric definitions, privacy, screenshot and demo |
| [Dashboard design](DASHBOARD-PLAN.md) | Developers | Original design and implementation scope |

For a first connection, follow the user guide, select the database settings in
the configuration reference, then use table resources before querying. For HTTP,
also follow the operations guide. Before enabling writes or relaxing PII guards,
read the security guide.

For development, read the module map and request flow, run the default checks,
then run integration checks for changes involving adapters, SQL policy,
serialization or transports. Current task tracking is in
[.worklog/status.md](../.worklog/status.md).

The [root README](../README.md) provides the quick start. Application entry
points are [MySQL](../mcp-ex-mysql/README.md),
[PostgreSQL](../mcp-ex-pg/README.md) and [shared core](../mcp-ex-core/README.md).
The [TypeScript reference](../mcp-server-mysql/README.md) has its own
documentation; its configuration and deployment instructions do not automatically
apply to the Elixir servers.

Documentation and the latest full runtime verification were updated on
2026-10-19; see
[test evidence and limits](TESTING.md#recorded-evidence-and-limits).
