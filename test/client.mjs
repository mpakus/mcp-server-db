import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const targets = [
  { app: "mysql", tool: "mysql_query", scheme: "mysql", schema: "mcp_test", http: 13007,
    env: { MYSQL_HOST: "127.0.0.1", MYSQL_PORT: "13307", MYSQL_USER: "mcp_test", MYSQL_PASS: "mcp_test_password", MYSQL_DB: "mcp_test" } },
  { app: "pg", tool: "pg_query", scheme: "postgres", schema: "public", http: 13008,
    env: { PG_HOST: "127.0.0.1", PG_PORT: "15433", PG_USER: "mcp_test", PG_PASS: "mcp_test_password", PG_DB: "mcp_test" } },
];
const environment = target => ({ PATH: process.env.PATH, HOME: process.env.HOME, LANG: "en_US.UTF-8", ...target.env, ENABLE_PII_REDACTION: "true" });
const executable = target => fileURLToPath(new URL(`../mcp-ex-${target.app}/mcp-ex-${target.app}`, import.meta.url));

async function exercise(client, target) {
  const tools = await client.listTools();
  assert.equal(tools.tools[0].name, target.tool);
  assert.equal(tools.tools[0].annotations.readOnlyHint, true);
  const resources = await client.listResources();
  assert(resources.resources.some(r => r.uri === `${target.scheme}://tables/${target.schema}/users`));
  const root = await client.readResource({ uri: `${target.scheme}://tables` });
  assert(JSON.parse(root.contents[0].text).some(t => t.name === "users"));
  const table = await client.readResource({ uri: `${target.scheme}://tables/${target.schema}/users` });
  const columns = JSON.parse(table.contents[0].text);
  assert(columns.some(c => c.column_name === "id"));
  assert(!columns.some(c => c.column_name === "email"));
  const placeholder = target.app === "mysql" ? "?" : "$1";
  const result = await client.callTool({ name: target.tool, arguments: { sql: `SELECT id, label FROM users WHERE id=${placeholder}`, params: [1] } });
  assert.equal(result.isError, false, JSON.stringify(result));
  assert.equal(JSON.parse(result.content[0].text)[0].label, "sample");
  const pii = await client.callTool({ name: target.tool, arguments: { sql: "SELECT email AS harmless FROM users" } });
  assert.equal(pii.isError, true);
  const write = await client.callTool({ name: target.tool, arguments: { sql: "DELETE FROM users" } });
  assert.equal(write.isError, true);
}

async function checkStdioTimeout(target) {
  const child = spawn(executable(target), ["--stdio"], {
    env: { ...environment(target), ENABLE_PII_REDACTION: "false", [`${target.app === "mysql" ? "MYSQL" : "PG"}_QUERY_TIMEOUT`]: "500" },
    stdio: ["pipe", "pipe", "pipe"],
    timeout: 10000,
  });
  let stdout = "", stderr = "";
  child.stdout.setEncoding("utf8").on("data", chunk => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", chunk => { stderr += chunk; });
  const closed = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  const messages = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "stdio-timeout-test", version: "1" } } },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: target.tool, arguments: { sql: target.app === "mysql" ? "SELECT SLEEP(2) AS value" : "SELECT pg_sleep(2) AS value" } } },
    { jsonrpc: "2.0", id: 3, method: "ping" },
  ];
  try {
    child.stdin.end(messages.map(message => JSON.stringify(message) + "\n").join(""));
    const { code, signal } = await closed;
    assert.equal(signal, null, stderr);
    assert.equal(code, 0, stderr);
    const responses = stdout.trimEnd().split("\n").map(line => JSON.parse(line));
    assert.deepEqual(responses.map(response => response.id), [1, 2, 3]);
    assert.equal(responses[1].result.isError, true);
    assert.match(responses[1].result.content[0].text, /^Error: Database operation failed/);
    assert.deepEqual(responses[2].result, {});
    if (target.app === "mysql") assert.match(stderr, /MyXQL\.Connection.*disconnected:/);
    console.log(`${target.app}: stdio timeout, JSON-only stdout and EOF checks passed`);
  } finally {
    if (child.exitCode === null && !child.killed) child.kill("SIGTERM");
  }
}

for (const target of targets) {
  const client = new Client({ name: "mcp-ex-interop", version: "1.0.0" });
  const transport = new StdioClientTransport({ command: executable(target), args: ["--stdio"], env: environment(target), stderr: "pipe" });
  try {
    await client.connect(transport);
    await exercise(client, target);
    console.log(`${target.app}: official SDK stdio checks passed`);
  } finally {
    await client.close();
  }

  await checkStdioTimeout(target);

  const process = spawn(executable(target), ["--http"], { env: { ...environment(target), REMOTE_SECRET_KEY: "interop-test-token", PORT: String(target.http) }, stdio: ["ignore", "pipe", "pipe"] });
  let logs = "";
  process.stderr.on("data", chunk => { logs += chunk; });
  const url = new URL(`http://127.0.0.1:${target.http}/mcp`);
  const clients = [];
  try {
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      if (process.exitCode !== null) throw new Error(`HTTP server exited: ${logs}`);
      try { const response = await fetch(url); ready = response.status === 401; } catch {}
      if (ready) break;
      await delay(100);
    }
    assert(ready, `HTTP server did not start: ${logs}`);
    // Independent transports must not collide when clients reuse request IDs.
    for (let i = 0; i < 4; i++) {
      const client = new Client({ name: `mcp-ex-http-${i}`, version: "1.0.0" });
      clients.push(client);
      await client.connect(new StreamableHTTPClientTransport(url, { requestInit: { headers: { Authorization: "Bearer interop-test-token" } } }));
    }
    await Promise.all(clients.map(client => exercise(client, target)));
    const wrongToken = await fetch(url, { method: "POST", headers: { Authorization: "Bearer prefix-interop-test-token", "Content-Type": "application/json", Accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }) });
    assert.equal(wrongToken.status, 401);
    const badOrigin = await fetch(url, { headers: { Authorization: "Bearer interop-test-token", Origin: "https://evil.test" } });
    assert.equal(badOrigin.status, 403);
    console.log(`${target.app}: official SDK HTTP checks passed with four concurrent clients`);
  } finally {
    await Promise.all(clients.map(client => client.close()));
    process.kill("SIGTERM");
    if (process.exitCode === null) await new Promise(resolve => process.once("exit", resolve));
  }
}
