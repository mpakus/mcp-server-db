# Server dashboard

Both escripts include a browser dashboard and a separate CLI dashboard:
`status`, `resources`, and a refreshing `--watch` view. They show server identity, uptime, database health,
pool readiness/queue length, memory/process count, resources and aggregate
request/query statistics. Both reuse private local snapshots without opening
another database pool. The CLI reads files directly; the browser reads an
authenticated endpoint on the running server.

## Browser dashboard

With the existing database settings exported:

```sh
MCP_DASHBOARD=true ./mcp-ex-mysql/mcp-ex-mysql --stdio --host localhost --port 4000
```

Startup prints `MCP: stdio` and a private link shaped like
`http://localhost:4000/dashboard#token=...` to stderr. Open the full link in a
browser. The page refreshes every two seconds and shows only that server's
snapshot; it marks stale data or an unreachable server explicitly.

`HOST` and `PORT` default to `localhost` and `4000`; the flags override them.
`MCP_HTTP_HOST` remains a fallback when `HOST` is unset. In stdio mode the HTTP
listener serves only the dashboard, and stdout stays JSON-RPC. In `--http` mode
the same listener also serves `/mcp`, whose URL is printed after startup.
Use separate ports when running multiple dashboard-enabled servers.

The link contains a random, read-only viewing token that changes on restart.
Treat it as private: it reveals operational metadata and resource names. It is
separate from `REMOTE_SECRET_KEY` and cannot authorize MCP requests. The token
stays in the URL fragment; the page sends it in an Authorization header when
fetching data. It is not embedded in the served HTML or diagnostic snapshots.
No database password, SQL text, query result or MCP bearer token is displayed.
Keep the default loopback binding for local use; use a trusted TLS proxy before
exposing the HTTP listener to other machines.

Dashboard collection remains opt-in. Without `MCP_DASHBOARD=true`, startup
prints that the dashboard is disabled. If the configured port is occupied,
choose another with `--port` before restarting.

## Enable and inspect

1. Add `MCP_DASHBOARD=true` to the **server's** environment, together with your
   existing database settings, then restart the server. For a stdio client, add
   it to that client's server `env` object:

   ```json
   {"MCP_DASHBOARD":"true"}
   ```

   For HTTP, after exporting the existing database/token settings:

   ```sh
   MCP_DASHBOARD=true ./mcp-ex-pg/mcp-ex-pg --http
   ```

2. In a second terminal under the same operating-system account, inspect the
   corresponding server:

   ```sh
   ./mcp-ex-mysql/mcp-ex-mysql status
   ./mcp-ex-pg/mcp-ex-pg status --watch
   ```

3. Copy the full instance ID shown in `status` to select one process:

   ```sh
   ./mcp-ex-pg/mcp-ex-pg resources --instance INSTANCE_ID
   ./mcp-ex-pg/mcp-ex-pg status --instance INSTANCE_ID --json
   ./mcp-ex-pg/mcp-ex-pg status --watch --json
   ```

Replace `INSTANCE_ID` with the displayed 24-character ID. Each executable
filters its own database dialect. `status` lists all matching instances;
`resources` requires `--instance` when several match. Both commands accept
`--instance ID`, `--json` and `--watch`; transport flags are for starting a server.

The default directory is `$XDG_STATE_HOME/mcp-ex` when XDG_STATE_HOME is set,
otherwise `~/.local/state/mcp-ex`. To use a different location, export
`MCP_DASHBOARD_DIR=/absolute/private/path` in **both server and viewer** environments.
A GUI MCP client's environment may differ from your shell's. Setting
`MCP_DASHBOARD=true` only on the viewer cannot enable an already-running server.
The viewer ignores database, HTTP-token and PII environment settings.

## Screenshot and example

![MySQL and PostgreSQL CLI status output from disposable fixtures](images/dashboard.jpg)

This is a browser-rendered screenshot of actual `status` output, captured on
2026-10-19 against disposable MySQL 8.4 and PostgreSQL 16 fixtures. The presentation
frame is for documentation and illustrates the CLI view. The
[exact captured text](images/dashboard-output.txt) is also available.

Each server completed eight reads and rejected two policy checks. That produces
10 completed tools, eight successful tools, two tool failures and eight query
attempts. RPC errors remain zero because a tool failure is a successful JSON-RPC
response containing `isError: true`. The two resources are the root table list
and the fixture's `users` table. The latency and memory values are local samples,
not performance promises. Query rate is unknown on a one-shot view; watch mode
needs two snapshots to calculate it.

To reproduce with disposable fixtures only, first build both escripts and
install the test SDK as described in [Testing](TESTING.md), then:

```sh
docker compose -f compose.test.yml up -d --wait
node test/dashboard-demo.mjs
```

The demo prints a temporary `MCP_DASHBOARD_DIR` value. Export it in another
terminal before running the `status` commands. Ctrl+C in the demo terminal
closes both fixture clients and removes its snapshots. After stopping the demo:

```sh
docker compose -f compose.test.yml down
```

## Reading the view

Counters describe completed dispatcher work. Session admission errors,
cancellation notifications, killed workers and response-cap errors are not
included in dispatcher completion totals. The dashboard does not expose active
session identities or SQL.

| Field | Meaning |
| --- | --- |
| Instance / PID | Random per-start identity and informational OS PID; PID reuse is never used to decide liveness |
| Uptime / snapshot age | Monotonic process uptime and age of the last published file |
| Database | Configured host, port, database, schema, write-capability hint and PII flag; socket transport still shows the configured host/port |
| Health | Last read-only `SELECT 1` result and check age; a timeout can mean pool pressure rather than an unreachable database; JSON also reports the last successful probe timestamp/duration |
| Pool | Ready connections / configured pool size, and checkout queue length; these are sampled DBConnection values, not active clients |
| RPC | Completed dispatcher requests, JSON-RPC errors, and valid dispatcher notifications; incoming response envelopes are ignored |
| Tools | Completed calls to the known SQL tool, success/failure totals and elapsed average/max |
| Failures | Tool argument validation, policy rejection, driver operation failure, or result-processing failure |
| Query attempts | Read/write/DDL driver calls after successful policy validation; neither executed statements nor committed writes are guaranteed |
| Cache (JSON counters) | `cache_hit`, `cache_miss`, `cache_bypass`, `cache_disabled` count successful opted-in tool calls; misses may be ineligible for storage |
| Rate | Change in query attempts divided by change in sampled monotonic uptime for the same instance; first sample, unchanged uptime or counter reset is unknown |
| Transport | JSON parse/oversize failures and rejected HTTP status totals; HTTP status counters also appear individually in JSON |
| BEAM | Whole server VM memory and process count, including driver/library processes |
| Resources | Cached MCP resource inventory, status, last successful sample age and optional truncation; status previews five entries |

Tool latency covers argument validation, policy, database work and result
processing, including failed tools. It differs from the existing result text's
query execution time. Unknown tool names are RPC errors and do not count as
known SQL-tool calls. Invalid SQL types are validation failures; SQL rejected
by policy is a policy failure. Counts are sampled independently and may briefly
show an operation in progress. Internal startup, health probes and inventory
sampling are excluded from client counters. Query-attempt counters and their
rate exclude cache hits; tool/RPC totals include them. Cache counters expose no
SQL, bound parameters or cached payloads. Resource reads are RPC activity,
not SQL-tool attempts. No SQL, bound parameters, result values, raw error text,
column metadata/defaults, credentials, bearer tokens or client IDs are retained.
Resource names/URIs and database topology are intentionally visible.

## Freshness and exit codes

Snapshots publish every two seconds. Heartbeats continue while the single
sampling worker is busy. Pool metrics are sampled about every five seconds,
health about every 30 seconds and resources about every 60 seconds. Work is
serialized, so intervals are approximate. Pool work has a 500 ms deadline;
health/metadata jobs have a two-second deadline and reuse the existing pool.
The startup connectivity probe supplies the initial healthy database sample.

`healthy` means the snapshot is at most ten seconds old and its successful
database-health sample is at most 90 seconds old. Pool/resource status and ages
remain separate; a healthy heartbeat does not guarantee fresh inventory or spare
connections. A failed inventory refresh retains the last successful items and
sample time while showing `timeout` or `unavailable`. `pending` means no sample
has completed. Future-dated snapshots are `unknown`; old snapshots are `stale`,
which is not proof that a process has died. Check system clocks and the server
before interpreting those states.

| Exit code | One-shot status/resources result |
| --- | --- |
| `0` | At least one selected instance; every selected instance has fresh snapshots and healthy database samples |
| `1` | No matching instance, stale/unknown snapshot or failed/expired database health |
| `2` | Usage error, ambiguous resources selection, unsupported schema, unsafe permissions, oversized/malformed file or read failure |

JSON output is `{"schema_version":1,"instances":[...]}`. Watch JSON emits one
complete JSON object per line. Terminal watch clears/redraws every two seconds;
redirected or `TERM=dumb` output uses plain timestamped blocks without ANSI.
Ctrl+C stops only the viewer. It does not send a shutdown command to the MCP
server. Watch keeps running through valid stale/degraded samples; unreadable or
invalid storage exits with code 2. Ctrl+C/signal termination has the OS exit status.

## Storage, privacy and lifecycle

Diagnostics default to disabled and add no runtime dependency. When enabled,
the browser view shares the HTTP listener or starts a dashboard-only listener
for stdio. The CLI viewer itself starts no listener.
On Unix systems the server obtains the effective UID through `/usr/bin/id -u`,
creates a missing snapshot directory with mode `0700`, and atomically replaces
per-instance JSON files with mode `0600`. Existing directories must already be
private and owned by the current user. Directory/file symlinks, foreign owners
and group/world access are rejected. Do not share the directory across accounts
or put it in a public/static web root. Files are limited to 1 MiB; inventories
retain at most 200 entries and include the uncapped resource count and truncation.
The native catalog query can still materialize a larger inventory transiently.

The collector is unlinked from request handling. Requests update bounded ETS
counters and never wait for sampling or disk I/O. Collection/storage failure
leaves MCP available and can leave a stale snapshot; a constant stderr warning
reports failed publication. It does not restart a dead publisher automatically;
restart the server to restore it. Unsupported UID lookup disables collection.

Normal stdio EOF removes the current instance file on a best-effort basis. A
crash, forced kill or HTTP VM shutdown may leave a file. Stale files are retained
for inspection, not auto-pruned. Remove a specific stale `INSTANCE_ID.json` only
after verifying that its server is stopped; each restart has a new identity.
There is no persistent history, raw-keyboard TUI, p95 histogram,
active-client count or process-control command. The implementation design is in
[the developer guide](DEVELOPER-GUIDE.md#dashboard-implementation).
