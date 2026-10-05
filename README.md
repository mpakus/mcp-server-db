# Elixir database MCP servers

| Project | Database | Tool | Resources |
| --- | --- | --- | --- |
| [mcp-ex-mysql](mcp-ex-mysql/README.md) | MySQL | `mysql_query` | `mysql://tables[/database/table]` |
| [mcp-ex-pg](mcp-ex-pg/README.md) | PostgreSQL | `pg_query` | `postgres://tables[/schema/table]` |
| [mcp-ex-core](mcp-ex-core/README.md) | Shared library | Protocol, configuration, SQL policy, masking, transports | Used by both applications |

Elixir implementations of the adjacent `mcp-server-mysql` project. The original
project is unchanged. Keep the three Elixir folders together; applications
depend on the shared library by path. They run as escripts over stdio or as
stateless HTTP MCP servers. No web UI is needed.

## Install and build

With [asdf](https://asdf-vm.com/) installed, run from this directory:

```sh
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
KERL_CONFIGURE_OPTIONS='--without-javac --without-wx --without-odbc' asdf install
mix local.hex --force
mix local.rebar --force
cd mcp-ex-mysql
mix deps.get
mix escript.build
cd ../mcp-ex-pg
mix deps.get
mix escript.build
```

Skip plugin-add commands for plugins already installed. `.tool-versions` pins
Erlang 28.5 and Elixir 1.20.4-otp-28. Projects require Elixir 1.18 or newer.
Escript bundles Elixir and dependencies; Erlang and `escript` must remain on PATH.
See each application's README for startup and client configuration.

## Verify

After fetching dependencies for all three projects, run `./bin/check`.
For real database and official MCP SDK checks:

```sh
docker compose -f compose.test.yml up -d --wait
npm --prefix test ci --ignore-scripts
MCP_INTEGRATION=true ./bin/check
docker compose -f compose.test.yml down
```

The disposable containers use loopback ports 13307 and 15433 and tmpfs storage.
Tests mutate only those fixtures; do not redirect them to application databases.
Client checks start and stop their own HTTP processes on ports 13007 and 13008.
Node is needed only for official SDK interoperability tests. RTK is used by
`bin/check` when available.

See [.worklog/status.md](.worklog/status.md) for tasks and verification, and
[.worklog/analysis.md](.worklog/analysis.md) for source analysis and decisions.
MIT license, including reference-project attribution: [LICENSE](LICENSE).
