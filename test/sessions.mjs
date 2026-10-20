import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const init = { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "session-test", version: "1" } };
const initialized = { jsonrpc: "2.0", method: "notifications/initialized" };
const rpc = (id, method, params = {}) => ({ jsonrpc: "2.0", id, method, params });
const query = (target, id, sql) => rpc(id, "tools/call", { name: target.tool, arguments: { sql } });

function stdio(executable, env) {
  const child = spawn(executable, ["--stdio"], { env, stdio: ["pipe", "pipe", "pipe"], timeout: 15000 });
  const messages = [];
  let buffer = "", stderr = "", failure;
  child.stdout.setEncoding("utf8").on("data", data => {
    buffer += data;
    while (buffer.includes("\n")) {
      const end = buffer.indexOf("\n");
      try { messages.push(JSON.parse(buffer.slice(0, end))); } catch (error) { failure = error; }
      buffer = buffer.slice(end + 1);
    }
  });
  child.stderr.setEncoding("utf8").on("data", data => { stderr += data; });
  const closed = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  const send = message => child.stdin.write(`${JSON.stringify(message)}\n`);
  const receive = async id => {
    for (let attempt = 0; attempt < 1000; attempt++) {
      if (failure) throw failure;
      const message = messages.find(message => message.id === id);
      if (message) return message;
      if (child.exitCode !== null) throw new Error(`Server exited: ${stderr}`);
      await delay(5);
    }
    throw new Error(`No response ${id}: ${stderr}`);
  };
  const stop = async () => {
    if (child.exitCode === null) child.kill("SIGTERM");
    await closed;
  };
  return { child, send, receive, messages, closed, stop };
}

export async function checkSessionStdio(target, executable, env) {
  const client = stdio(executable, { ...env, MCP_DASHBOARD: "false", ENABLE_PII_REDACTION: "false" });
  const sleep = target.app === "mysql" ? "SLEEP" : "pg_sleep";
  try {
    client.send(rpc(1, "initialize", init));
    await client.receive(1);
    client.send(initialized);
    client.send(query(target, 2, `SELECT ${sleep}(0.3) AS value`));
    client.send(rpc(3, "ping"));
    await client.receive(3);
    assert(!client.messages.some(message => message.id === 2), "ping waited for SQL");
    assert.equal((await client.receive(2)).result.isError, false);

    client.send(query(target, 4, `SELECT ${sleep}(2) AS value`));
    await delay(30);
    client.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 4 } });
    client.send(rpc(5, "ping"));
    await client.receive(5);
    client.send(query(target, 6, "SELECT 1 AS value"));
    assert.equal((await client.receive(6)).result.isError, false);
    assert(!client.messages.some(message => message.id === 4), "cancelled query produced a response");

    // Fragment UTF-8 inside a multibyte codepoint, then cross several port buffers.
    const frame = Buffer.from(JSON.stringify(rpc(7, "ping", { padding: "x".repeat(256 * 1024), value: "😀" })) + "\n");
    const split = frame.indexOf(Buffer.from("😀")) + 2;
    client.child.stdin.write(frame.subarray(0, split));
    await delay(20);
    client.child.stdin.write(frame.subarray(split));
    assert.deepEqual((await client.receive(7)).result, {});
    client.child.stdin.write("{invalid}\n");
    client.send(rpc(8, "ping"));
    await client.receive(8);
    assert(client.messages.some(message => message.error?.code === -32700));

    // EOF retains a final unterminated frame and drains already accepted queries.
    client.send(query(target, 9, `SELECT ${sleep}(0.1) AS value`));
    client.child.stdin.end(JSON.stringify(rpc(10, "ping")));
    assert.deepEqual(await client.closed, { code: 0, signal: null });
    assert.deepEqual(client.messages.find(message => message.id === 10).result, {});
    assert.equal(client.messages.find(message => message.id === 9).result.isError, false);
  } finally {
    await client.stop();
  }

  const oversized = stdio(executable, { ...env, MCP_DASHBOARD: "false", MCP_MAX_REQUEST_BYTES: "1024" });
  try {
    // No newline or EOF: crossing the cap must reject without waiting for either.
    oversized.child.stdin.write("x".repeat(1025));
    const result = await oversized.closed;
    assert.deepEqual(result, { code: 1, signal: null });
    assert.equal(oversized.messages[0].error.message, "Request too large");
  } finally {
    await oversized.stop();
  }

  // A pipelined lifecycle and response burst must survive batching and EOF intact.
  const burst = stdio(executable, { ...env, MCP_DASHBOARD: "false", ENABLE_PII_REDACTION: "false" });
  try {
    const pings = Array.from({ length: 300 }, (_, i) => rpc(i + 2, "ping"));
    const messages = [rpc(1, "initialize", init), initialized, ...pings,
      query(target, 302, "SELECT repeat('x', 131072) AS value")];
    burst.child.stdin.end(messages.map(message => JSON.stringify(message)).join("\n"));
    assert.deepEqual(await burst.closed, { code: 0, signal: null });
    assert.deepEqual(burst.messages.map(message => message.id), Array.from({ length: 302 }, (_, i) => i + 1));
    for (const message of burst.messages.slice(1, -1)) assert.deepEqual(message.result, {});
    const result = burst.messages.at(-1).result;
    assert.equal(result.isError, false);
    assert.equal(JSON.parse(result.content[0].text)[0].value, "x".repeat(131072));
  } finally {
    await burst.stop();
  }
  console.log(`${target.app}: stdio concurrency, cancellation, UTF-8/chunk framing, batched output, EOF and size checks passed`);
}

export async function checkSessionHttp(target, url) {
  const headers = {
    Authorization: "Bearer interop-test-token",
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    "MCP-Protocol-Version": "2025-11-25",
  };
  const post = (message, id, extra = {}) => fetch(url, {
    method: "POST",
    headers: { ...headers, ...(id ? { "MCP-Session-Id": id } : {}), ...extra },
    body: JSON.stringify(message),
    signal: AbortSignal.timeout(5000),
  });
  assert.equal((await post(rpc(1, "ping"))).status, 400);
  const initializedResponse = await post(rpc(1, "initialize", init));
  const id = initializedResponse.headers.get("mcp-session-id");
  assert(id);
  assert.equal((await post(initialized, id)).status, 202);
  assert.equal((await post(rpc(2, "ping"), id, { Authorization: "Bearer wrong" })).status, 401);
  assert.equal((await post(rpc(2, "ping"), id, { Origin: "https://evil.test" })).status, 403);
  assert.equal((await post(rpc(2, "ping"), id, { "MCP-Protocol-Version": "2025-06-18" })).status, 400);

  // PII mode blocks pg_* catalog identifiers; this read-only fixture wraps pg_sleep.
  const sleep = target.app === "mysql" ? "SLEEP" : "mcp_test_sleep";
  const pending = post(query(target, 3, `SELECT ${sleep}(2) AS value`), id);
  await delay(50);
  assert.equal((await post({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3 } }, id)).status, 202);
  const cancelled = await pending;
  assert.equal(cancelled.status, 202, await cancelled.text());
  const recovered = await post(query(target, 4, "SELECT 1 AS value"), id);
  assert.equal((await recovered.json()).result.isError, false);

  const closed = await fetch(url, { method: "DELETE", headers: { ...headers, "MCP-Session-Id": id } });
  assert.equal(closed.status, 204);
  assert.equal((await post(rpc(5, "ping"), id)).status, 404);
  assert.equal((await fetch(url, { headers: { ...headers, "MCP-Session-Id": id } })).status, 404);
  console.log(`${target.app}: HTTP session IDs, authentication, cancellation, DELETE and expiry checks passed`);
}
