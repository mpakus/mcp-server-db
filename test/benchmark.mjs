// Usage: node test/benchmark.mjs BEFORE_BUILD_ROOT AFTER_BUILD_ROOT
// Build both revisions independently, then start compose.test.yml fixtures.
// Uses only fixture credentials and SELECT statements. No application databases.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { resolve } from "node:path";

assert.equal(process.argv.length, 4, "Supply before and after build directories");
const versions = ["before", "after"].map((version, i) => ({
  version, root: resolve(process.argv[i + 2]),
}));
const repeats = 5;

const targets = [
  { app: "mysql", prefix: "MYSQL", port: "13307", http: 13107, sleep: "SLEEP" },
  { app: "pg", prefix: "PG", port: "15433", http: 13108, sleep: "pg_sleep" },
];
const initialize = {
  protocolVersion: "2025-11-25", capabilities: {},
  clientInfo: { name: "local-performance-probe", version: "1" },
};
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const round = value => Math.round(value * 1000) / 1000;

async function connect(target, transport, build) {
  const executable = resolve(build.root, `mcp-ex-${target.app}/mcp-ex-${target.app}`);
  const env = {
    PATH: process.env.PATH, HOME: process.env.HOME, LANG: "en_US.UTF-8",
    [`${target.prefix}_HOST`]: "127.0.0.1",
    [`${target.prefix}_PORT`]: target.port,
    [`${target.prefix}_USER`]: "mcp_test",
    [`${target.prefix}_PASS`]: "mcp_test_password",
    [`${target.prefix}_DB`]: "mcp_test",
    [`${target.prefix}_POOL_SIZE`]: "10",
    MCP_DASHBOARD: "false", ENABLE_PII_REDACTION: "false",
    MCP_MAX_INFLIGHT: "4", MCP_REQUEST_TIMEOUT: "11000",
    REMOTE_SECRET_KEY: "local-performance-probe", PORT: String(target.http),
  };
  const child = spawn(executable, [`--${transport}`], {
    env, cwd: build.root, stdio: ["pipe", "pipe", "pipe"],
  });
  let stderr = "", buffer = "", sequence = 0, sessionId;
  const pending = new Map();
  const closed = new Promise(resolve => child.once("close", resolve));
  const fail = error => {
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(error);
    }
    pending.clear();
  };
  child.on("error", fail);
  child.on("exit", code => fail(new Error(`Server exit ${code}: ${stderr}`)));
  child.stderr.setEncoding("utf8").on("data", data => { stderr += data; });
  child.stdout.setEncoding("utf8").on("data", data => {
    buffer += data;
    while (buffer.includes("\n")) {
      const split = buffer.indexOf("\n");
      const line = buffer.slice(0, split);
      buffer = buffer.slice(split + 1);
      try {
        const message = JSON.parse(line);
        const entry = pending.get(message.id);
        if (entry) {
          pending.delete(message.id);
          clearTimeout(entry.timer);
          entry.resolve(message);
        }
      } catch (error) { fail(error); }
    }
  });
  const close = async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 2000);
    await closed;
    clearTimeout(timer);
  };
  const url = `http://127.0.0.1:${target.http}/mcp`;
  const call = async (method, params = {}) => {
    const id = ++sequence;
    const message = { jsonrpc: "2.0", id, method, params };
    let response;
    if (transport === "stdio") {
      response = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`Timed out: ${method}`));
        }, 15000);
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify(message) + "\n", error => {
          if (error) fail(error);
        });
      });
    } else {
      const result = await fetch(url, {
        method: "POST",
        headers: {
          authorization: "Bearer local-performance-probe",
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          ...(sessionId ? { "mcp-session-id": sessionId } : {}),
        },
        body: JSON.stringify(message),
        signal: AbortSignal.timeout(15000),
      });
      assert.equal(result.status, 200);
      if (method === "initialize") {
        sessionId = result.headers.get("mcp-session-id");
        if (build.version === "after") assert(sessionId, "Missing HTTP session");
      }
      response = await result.json();
    }
    assert.equal(response.id, id);
    assert.equal(response.error, undefined, JSON.stringify(response));
    assert.notEqual(response.result?.isError, true, JSON.stringify(response));
    return response;
  };
  try {
    if (transport === "http") {
      let ready = false;
      for (let i = 0; i < 100; i++) {
        if (child.exitCode !== null) throw new Error(stderr);
        try {
          ready = (await fetch(url, { signal: AbortSignal.timeout(500) })).status === 401;
        } catch {}
        if (ready) break;
        await delay(100);
      }
      assert(ready, "HTTP server did not become ready");
    }
    await call("initialize", initialize);
    if (transport === "stdio") child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n",
    );
    if (transport === "http") {
      const response = await fetch(url, {
        method: "POST",
        headers: { authorization: "Bearer local-performance-probe", "content-type": "application/json", accept: "application/json, text/event-stream", ...(sessionId ? { "mcp-session-id": sessionId } : {}) },
        body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
        signal: AbortSignal.timeout(15000),
      });
      assert.equal(response.status, 202);
    }
    return { call, close };
  } catch (error) {
    await close();
    throw error;
  }
}

async function measure(target, transport, build) {
  process.stderr.write(`Benchmarking ${build.version} ${target.app} ${transport}\n`);
  const client = await connect(target, transport, build);
  const query = sql => client.call("tools/call", {
    name: `${target.app}_query`, arguments: { sql },
  });
  try {
    for (let i = 0; i < 10; i++) await query("SELECT 1 AS value");
    const result = {
      version: build.version, app: target.app, transport, pool_size: 10, repeats,
    };
    const selects = [];
    for (let i = 0; i < repeats; i++) {
      const start = performance.now();
      await query("SELECT 1 AS value");
      selects.push(performance.now() - start);
    }
    result.select_1_ms = round(median(selects));
    const batches = [], pings = [], order = [];
    for (let trial = 0; trial < repeats; trial++) {
      const start = performance.now();
      await Promise.all(Array.from({ length: 4 }, () =>
        query(`SELECT ${target.sleep}(0.2) AS value`)));
      batches.push(performance.now() - start);
      const completions = [];
      const slow = query(`SELECT ${target.sleep}(0.3) AS value`)
        .then(() => completions.push("query"));
      await delay(30);
      const pingStart = performance.now();
      await client.call("ping");
      pings.push(performance.now() - pingStart);
      completions.push("ping");
      await slow;
      order.push(completions.join(","));
    }
    result.four_200ms_queries_ms = round(median(batches));
    result.ping_behind_300ms_query_ms = round(median(pings));
    result.completion_order = order;
    result.padded_ping_ms = {};
    result.samples_ms = {
      select_1: selects.map(round),
      four_200ms_queries: batches.map(round),
      ping_behind_300ms_query: pings.map(round),
      padded_ping: {},
    };
    for (const bytes of [0, 1024, 65536, 262144]) {
      const samples = [];
      for (let trial = 0; trial < repeats; trial++) {
        const start = performance.now();
        await client.call("ping", { padding: "x".repeat(bytes) });
        samples.push(performance.now() - start);
      }
      result.padded_ping_ms[bytes] = round(median(samples));
      result.samples_ms.padded_ping[bytes] = samples.map(round);
    }
    console.log(JSON.stringify(result));
  } finally { await client.close(); }
}

for (const target of targets) {
  for (const transport of ["stdio", "http"]) {
    for (const build of versions) await measure(target, transport, build);
  }
}
