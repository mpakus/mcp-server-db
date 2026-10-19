# Operations

Run one process per configured database identity and permission set. Configuration
is loaded at startup and shared by every connection in that process. Build and
database setup are covered in the [user guide](USER-GUIDE.md); all settings are
listed in [Configuration](CONFIGURATION.md).

## Process launch and lifecycle

Stdio is usually owned by an MCP client. HTTP requires a separately running
process. The CLI starts the driver pool, probes it with read-only `SELECT 1`,
then starts its transport. A failed startup exits with status 1. Stdio exits
when stdin closes; HTTP waits until the process is stopped. There is no built-in
daemon command, service installer, OTP release or administrative shutdown API.

For launchers that do not inherit asdf shims, use a wrapper with explicit paths.
For example, save this outside the repository as a private executable script,
replace the paths, and point the client at it:

```sh
#!/bin/sh
set -eu
cd /absolute/path/mp
exec /absolute/path/to/asdf exec escript ./mcp-ex-mysql/mcp-ex-mysql --stdio
```

For PostgreSQL, substitute `./mcp-ex-pg/mcp-ex-pg`. The workspace working
directory lets asdf select the pinned `.tool-versions`. Database settings should
be supplied by the client or a trusted wrapper environment. The wrapper must
emit no stdout before `exec`. A directly installed Erlang `escript` can also
launch a built artifact without Mix or a source checkout.

Use an external process manager to restart HTTP after failures and supply
private environment settings. The CLI links the pool and listener in its
process; it is not a custom application supervision/release tree. Stop/restart
may interrupt requests, and no custom drain protocol is implemented.

## Run HTTP

Export the chosen database settings first. For MySQL:

```sh
REMOTE_SECRET_KEY=replace-with-a-long-secret MCP_HTTP_HOST=127.0.0.1 PORT=3000 \
  ./mcp-ex-mysql/mcp-ex-mysql --http
```

For PostgreSQL:

```sh
REMOTE_SECRET_KEY=replace-with-a-long-secret MCP_HTTP_HOST=127.0.0.1 PORT=3001 \
  ./mcp-ex-pg/mcp-ex-pg --http
```

Replace the token; these example tokens are placeholders. `IS_REMOTE_MCP=true`
selects the same transport without a flag. Both applications otherwise default
to port 3000, so use separate ports when running both. `MCP_HTTP_HOST` is a
literal IP address, not a DNS hostname.

The endpoint is `http://127.0.0.1:3000/mcp` or the selected port. It implements
stateless MCP HTTP with JSON responses. Clients that require persistent sessions,
GET SSE streams, resumability or OAuth discovery need capabilities this server
does not supply. Use a client capable of authenticated stateless HTTP.

## HTTP request contract

| Header | Required behavior |
| --- | --- |
| `Authorization` | Exactly one header with `Bearer ` followed by the exact configured secret |
| `Content-Type` | `application/json`; media-type parameters are accepted |
| `Accept` | Must include both `application/json` and `text/event-stream`, even though responses use JSON |
| `MCP-Protocol-Version` | May be omitted; if supplied, one supported version. Use the negotiated version after initialization |
| `Origin` | May be omitted; if supplied, one exact entry in `MCP_ALLOWED_ORIGINS` |

No `Mcp-Session-Id` is issued or required. Initialize and notify normally for
client compatibility, but the server does not carry lifecycle state across HTTP
requests. Notifications return 202 with no body. Requests return 200 JSON even
when their JSON-RPC envelope or tool result contains an error.

In another shell, set the actual endpoint and bearer token, then initialize:

```sh
export MCP_ENDPOINT='http://127.0.0.1:3000/mcp'
export REMOTE_SECRET_KEY='replace-with-the-running-server-token'
curl --silent --show-error --include "$MCP_ENDPOINT" \
  -H "Authorization: Bearer $REMOTE_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data-binary '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"manual-check","version":"1.0.0"}}}'
```

The examples request a supported version, so the returned version is
`2025-11-25`. Send the notification:

```sh
curl --silent --show-error --include "$MCP_ENDPOINT" \
  -H "Authorization: Bearer $REMOTE_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  --data-binary '{"jsonrpc":"2.0","method":"notifications/initialized"}'
```

Discover tools or query MySQL:

```sh
curl --silent --show-error "$MCP_ENDPOINT" \
  -H "Authorization: Bearer $REMOTE_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  --data-binary '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

```sh
curl --silent --show-error "$MCP_ENDPOINT" \
  -H "Authorization: Bearer $REMOTE_SECRET_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-25' \
  --data-binary '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"mysql_query","arguments":{"sql":"SELECT 1 AS value","params":[]}}}'
```

For PostgreSQL, change the endpoint and tool name to `pg_query`. These requests
do not depend on application tables. An HTTP 200 alone is insufficient to decide
whether a query succeeded; inspect `error` and `result.isError`.

Only `POST /mcp` is supported. GET, DELETE and OPTIONS return 405 after
authentication/origin/version checks. Other paths return 404. An allowed Origin
does not add CORS response headers or support browser preflight. See the complete
[HTTP status table](TROUBLESHOOTING.md#http-status-codes).

## Network exposure

Keep the listener on loopback when a reverse proxy runs on the same host. For a
container/network interface, set an appropriate literal bind IP and restrict
access at the network boundary. The included Compose file provisions test
databases only; it is not an application deployment stack.

For network clients, configure a reverse proxy to terminate HTTPS, route `/mcp`
POST bodies and responses, preserve Authorization and protocol headers, and
apply suitable request/concurrency limits. The application has no HTTPS listener
configuration or built-in rate limiter. Configure exact Origin values when
clients send them, for example:

```sh
export MCP_ALLOWED_ORIGINS='https://client.example.com,https://another.example.com'
```

Origin checks do not restrict non-browser callers that omit Origin. Store bearer
tokens and database credentials privately. Rotate the static bearer by changing
the environment and restarting; there is no token management API. Proxy access
logs should not capture Authorization headers or SQL request bodies.

## Database TLS

Database TLS is separate from HTTPS between a client and the MCP endpoint.
Set the effective database hostname to the name on the server certificate and
use verified TLS. MySQL example, after exporting credentials/database:

```sh
export MYSQL_HOST='db.example.com'
export MYSQL_SSL=true
export MYSQL_SSL_REJECT_UNAUTHORIZED=true
export MYSQL_SSL_CA='/absolute/path/ca.pem'
```

For PostgreSQL:

```sh
export PG_HOST='db.example.com'
export PG_SSL=true
export PG_SSL_REJECT_UNAUTHORIZED=true
export PG_SSL_CA='/absolute/path/ca.pem'
```

Omit the CA setting to use system trust. A connection URL overrides the host
used for SNI/hostname verification. For client-certificate authentication, supply
both `*_SSL_CERT` and `*_SSL_KEY` as readable PEM paths. The server validates
presence and PEM syntax; the database and driver perform the actual handshake.
Setting `*_SSL_REJECT_UNAUTHORIZED=false` disables certificate verification and
does not establish trusted server identity.

TLS/mTLS is implemented through the drivers but was not exercised against live
TLS endpoints in the recorded integration run. Validate your CA, hostname and
client-certificate setup before relying on it operationally.

## Unix sockets and SSH tunnels

MySQL expects a socket file; PostgreSQL expects the socket directory:

```sh
export MYSQL_SOCKET_PATH='/tmp/mysql.sock'
```

```sh
export PG_SOCKET_PATH='/var/run/postgresql'
export PG_PORT=5432
```

The process user needs filesystem permissions and a compatible database
authentication rule. PostgreSQL's port selects the `.s.PGSQL.<port>` socket in
that directory. Socket transport overrides the TCP endpoint. Live Unix-socket
connections were not exercised in the recorded test run.

The Elixir servers do not launch SSH tunnels. An external tunnel can expose a
remote database on a local port; for example, run separately and keep open:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:13306:db.internal:3306 user@bastion.example.com
```

Then set `MYSQL_HOST=127.0.0.1`, `MYSQL_PORT=13306` and clear any MySQL socket or
URL override. For PostgreSQL, forward port 5432 to a chosen local port. Verified
database TLS still compares the effective configured hostname; connecting as
`127.0.0.1` will fail when the certificate names only the database DNS name. Use
a locally resolvable certificate hostname for the tunnel when retaining TLS
identity checks.

## Monitoring, upgrades and recovery

`ping` reports MCP responsiveness only. A `SELECT 1 AS value` tool call checks
the pool and query path. No `/health`, `/metrics`, query audit log or query
history API is provided. Logs use stderr at warning level; database failures
returned to clients deliberately suppress SQL and failed-row values. Monitor
process restarts, query error results, latency, pool pressure and database health
through your external tooling. For local inspection, enable `MCP_DASHBOARD=true`
on the server and use the separate [status/watch CLI](DASHBOARD.md). Its private
snapshots expose aggregate counters, cached resources and bounded health/pool
samples without a new listener or a viewer database connection. Fresh heartbeat,
health and resource ages are separate signals. A dead collector leaves stale
data; restart the MCP server to resume collection. Normal EOF cleanup is best
effort, so inspect stale instance files before removing them.

Before upgrading, retain the previous built artifact and private configuration,
fetch locked dependencies, rebuild both applications when core changes, and run
the [appropriate checks](TESTING.md). Restart with the new artifact and verify
initialization, resource discovery and a bounded read. Roll back by restoring
the previous artifact/configuration and restarting. Binary rollback does not
undo committed SQL or MySQL DDL; database recovery is a separate operation.

After a timeout/disconnect during a write, determine whether it committed before
retrying. Shut down the process manager/client before removing credentials or
artifacts. Dispose of test containers with the test Compose project, keeping
application databases separate.
