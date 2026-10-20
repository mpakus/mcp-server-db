import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

// Uses only the disposable compose.test.yml users fixture; restores its label.
export async function checkCache(target, executable, environment) {
  for (const mode of ["stdio", "http"]) {
    const env = { ...environment, MCP_DASHBOARD: "false", MCP_CACHE_ENABLED: "true",
      MCP_CACHE_TTL_MS: "500", ALLOW_UPDATE_OPERATION: "true",
      REMOTE_SECRET_KEY: "cache-test", PORT: String(target.http + 20) };
    const clients = [];
    let server;
    const url = new URL(`http://127.0.0.1:${env.PORT}/mcp`);
    const call = (client, sql, extra = {}) => client.callTool({ name: target.tool, arguments: { sql, ...extra } });
    const sql = "SELECT id, label FROM users WHERE id = 1";
    const read = client => call(client, sql, { cache: true });
    const label = result => JSON.parse(result.content[0].text)[0].label;
    try {
      if (mode === "http") {
        server = spawn(executable, ["--http"], { env, stdio: ["ignore", "ignore", "pipe"] });
        let logs = "", ready = false;
        server.stderr.on("data", chunk => { logs = (logs + chunk).slice(-4000); });
        for (let i = 0; i < 100; i++) {
          if (server.exitCode !== null) throw new Error(logs);
          try { ready = (await fetch(url)).status === 401; } catch {}
          if (ready) break;
          await delay(50);
        }
        assert(ready, logs);
      }
      for (let i = 0; i < (mode === "http" ? 2 : 1); i++) {
        const client = new Client({ name: "cache-test", version: "1" });
        clients.push(client);
        await client.connect(mode === "stdio"
          ? new StdioClientTransport({ command: executable, args: ["--stdio"], env, stderr: "pipe" })
          : new StreamableHTTPClientTransport(url, { requestInit: { headers: { Authorization: "Bearer cache-test" } } }));
      }
      const [client] = clients, other = clients.at(-1);
      assert.equal((await client.listTools()).tools[0].inputSchema.properties.cache.type, "boolean");
      const miss = await read(client), hit = await read(other);
      assert.equal(miss._meta.cache, "miss");
      assert.equal(hit._meta.cache, "hit");
      assert.equal(label(hit), "sample");
      assert.equal((await call(client, sql))._meta, undefined);
      await delay(550);
      assert.equal((await read(other))._meta.cache, "miss");
      assert.equal((await call(client, "SELECT email FROM users", { cache: true })).isError, true);
      assert.equal((await call(client, "UPDATE users SET label = 'cache-test' WHERE id = 1", { cache: true })).isError, true);
      assert.equal((await call(client, "UPDATE users SET label = 'cache-test' WHERE id = 1")).isError, false);
      const fresh = await read(other);
      assert.equal(fresh._meta.cache, "miss");
      assert.equal(label(fresh), "cache-test");
      assert.equal((await read(client))._meta.cache, "hit");
      const placeholder = target.app === "mysql" ? "?" : "$1::integer";
      for (const value of [11, 12]) {
        const result = await call(client, `SELECT ${placeholder} AS value`, { params: [value], cache: true });
        assert.equal(result.isError, false, JSON.stringify(result));
        assert.equal(result._meta.cache, "miss");
        assert.equal(Number(JSON.parse(result.content[0].text)[0].value), value);
      }
      console.log(`${target.app}: SDK ${mode} cache TTL, opt-in, policy, params and write invalidation passed`);
    } finally {
      try {
        if (clients[0]) assert.equal((await call(clients[0], "UPDATE users SET label = 'sample' WHERE id = 1")).isError, false);
      } finally {
        await Promise.all(clients.map(client => client.close()));
        if (server && server.exitCode === null) {
          const exited = new Promise(resolve => server.once("exit", resolve));
          server.kill("SIGTERM");
          await exited;
        }
      }
    }
  }
}
