// Build both escripts and start compose.test.yml before running. Fixture reads only.
// stdout: JSONL results; stderr: progress. STRESS_SMOKE=true runs a short self-check.
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn, execFile } from "node:child_process";
import http from "node:http";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";
import { performance, monitorEventLoopDelay } from "node:perf_hooks";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";

const root = fileURLToPath(new URL("../", import.meta.url));
const exec = promisify(execFile);
const round = n => Math.round(n * 100) / 100;
const init = { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "local-stress", version: "1" } };
export const targets = {
  mysql: { app: "mysql", prefix: "MYSQL", port: 13307, http: 13107, placeholder: "?" },
  pg: { app: "pg", prefix: "PG", port: 15433, http: 13108, placeholder: "$1" },
};

export function httpClient(target) {
  const agent = new http.Agent({ keepAlive: true, maxSockets: 128 });
  let sequence = 0, session;
  async function send(message, status = 200) {
    const body = JSON.stringify(message);
    return new Promise((resolve, reject) => {
      const request = http.request({
        host: "127.0.0.1", port: target.http, path: "/mcp", method: "POST", agent,
        headers: {
          authorization: "Bearer local-stress", "content-type": "application/json",
          "content-length": Buffer.byteLength(body), accept: "application/json, text/event-stream",
          ...(session ? { "mcp-session-id": session } : {}),
        },
      }, response => {
        const chunks = [];
        response.on("data", chunk => chunks.push(chunk));
        response.on("error", reject);
        response.on("end", () => {
          try {
            assert.equal(response.statusCode, status);
            if (message.method === "initialize") {
              session = response.headers["mcp-session-id"];
              assert(session);
            }
            resolve(status === 202 ? null : JSON.parse(Buffer.concat(chunks)));
          } catch (error) { reject(error); }
        });
      });
      request.setTimeout(15000, () => request.destroy(new Error("HTTP timeout")));
      request.on("error", reject);
      request.end(body);
    });
  }
  return {
    async call(method, params = {}) {
      const id = ++sequence;
      const response = await send({ jsonrpc: "2.0", id, method, params });
      assert.equal(response.jsonrpc, "2.0");
      assert.equal(response.id, id);
      return response;
    },
    notify: () => send({ jsonrpc: "2.0", method: "notifications/initialized" }, 202),
    close: () => agent.destroy(),
  };
}

export async function startServer(target, transport, config) {
  const child = spawn(target.executable || `${root}mcp-ex-${target.app}/mcp-ex-${target.app}`, [`--${transport}`], {
    cwd: root, stdio: ["pipe", "pipe", "pipe"], env: {
      PATH: process.env.PATH, HOME: process.env.HOME, LANG: "en_US.UTF-8",
      [`${target.prefix}_HOST`]: "127.0.0.1", [`${target.prefix}_PORT`]: String(target.port),
      [`${target.prefix}_USER`]: "mcp_test", [`${target.prefix}_PASS`]: "mcp_test_password",
      [`${target.prefix}_DB`]: "mcp_test", [`${target.prefix}_POOL_SIZE`]: String(config.pool),
      MCP_MAX_INFLIGHT: String(config.inflight), MCP_DASHBOARD: "false",
      ...(config.cacheEnabled === undefined ? {} : { MCP_CACHE_ENABLED: String(config.cacheEnabled), MCP_CACHE_TTL_MS: String(config.cacheTtl || 5000), MCP_CACHE_MAX_ENTRIES: String(config.cacheMaxEntries || 1000), MCP_CACHE_MAX_ENTRY_BYTES: String(config.cacheMaxEntryBytes || 65536) }),
      ENABLE_PII_REDACTION: "false", REMOTE_SECRET_KEY: "local-stress", PORT: String(target.http),
    },
  });
  let stderr = "", buffer = "", sequence = 0, failure;
  const pending = new Map();
  const closed = new Promise(resolve => child.once("close", resolve));
  const fail = error => {
    failure = error;
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    pending.clear();
  };
  child.on("error", fail);
  child.on("exit", code => fail(new Error(`Server exited ${code}: ${stderr}`)));
  child.stderr.setEncoding("utf8").on("data", text => { stderr = (stderr + text).slice(-16000); });
  child.stdout.setEncoding("utf8").on("data", text => {
    buffer += text;
    let split;
    while ((split = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, split);
      buffer = buffer.slice(split + 1);
      try {
        const message = JSON.parse(line), entry = pending.get(message.id);
        assert(entry, "Unexpected stdout response");
        assert.equal(message.jsonrpc, "2.0");
        pending.delete(message.id);
        clearTimeout(entry.timer);
        entry.resolve(message);
      } catch (error) { fail(error); }
    }
  });
  const client = {
    call(method, params = {}) {
      if (failure) return Promise.reject(failure);
      const id = ++sequence;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id); reject(new Error("Stdio timeout"));
        }, 15000);
        pending.set(id, { resolve, reject, timer });
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n", error => {
          if (error) fail(error);
        });
      });
    },
  };
  const workers = [];
  const close = async () => {
    await Promise.all(workers.map(worker => worker.terminate()));
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    const timer = setTimeout(() => child.kill("SIGKILL"), 2000);
    await closed;
    clearTimeout(timer);
  };
  try {
    if (transport === "stdio") {
      assert.equal((await client.call("initialize", init)).error, undefined);
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    } else {
      let ready = false;
      for (let i = 0; i < 100; i++) {
        if (failure) throw failure;
        try { ready = (await fetch(`http://127.0.0.1:${target.http}/mcp`)).status === 401; } catch {}
        if (ready) break;
        await delay(100);
      }
      assert(ready, "HTTP server not ready");
      for (let i = 0; i < (config.sessions || 4); i++) {
        const worker = new Worker(new URL(import.meta.url), { workerData: target });
        workers.push(worker);
        await receive(worker);
      }
    }
    return { child, client, workers, close, assertHealthy: () => { if (failure) throw failure; } };
  } catch (error) { await close(); throw error; }
}

function receive(worker) {
  return new Promise((resolve, reject) => {
    const cleanup = () => { worker.off("message", onMessage); worker.off("error", onError); worker.off("exit", onExit); };
    const onMessage = message => { cleanup(); message.failure ? reject(new Error(message.failure)) : resolve(message); };
    const onError = error => { cleanup(); reject(error); };
    const onExit = code => onError(new Error(`Load worker exited ${code}`));
    worker.once("message", onMessage); worker.once("error", onError); worker.once("exit", onExit);
  });
}

async function load(client, target, concurrency, seconds, workload) {
  const stats = { ok: 0, busy: 0, errors: 0, cache_status: {}, error_examples: [], histogram: {}, per_second_ok: [], latency_sum_ms: 0, latency_max_ms: 0 };
  const start = performance.now(), end = start + seconds * 1000;
  const elu = performance.eventLoopUtilization(), cpu = process.threadCpuUsage();
  const lag = monitorEventLoopDelay({ resolution: 10 }); lag.enable();
  const kind = typeof workload === "string" ? workload : workload.kind;
  let sequence = 0;
  const coldSql = `SELECT id, label FROM users WHERE id = ${target.placeholder} AND ${target.app === "mysql" ? "?" : "$2"} >= 0 /* ${randomUUID()} */`;
  const args = kind === "lookup"
    ? { sql: `SELECT id, label FROM users WHERE id = ${target.placeholder}`, params: [1] }
    : { sql: "SELECT 1 AS value" };
  if (workload.cache !== undefined) args.cache = workload.cache;
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (performance.now() < end) {
      const begin = performance.now();
      try {
        const response = await client.call("tools/call", { name: `${target.app}_query`, arguments: workload.unique ? { ...args, sql: coldSql, params: [1, ++sequence] } : args });
        if (response.error?.message === "Server busy; retry later") { stats.busy++; continue; }
        assert.equal(response.error, undefined, JSON.stringify(response.error));
        assert.equal(response.result.isError, false);
        const rows = JSON.parse(response.result.content[0].text);
        assert.equal(rows.length, 1);
        if (kind === "lookup") { assert.equal(rows[0].id, 1); assert.equal(rows[0].label, "sample"); }
        else assert.equal(rows[0].value, 1);
        if (workload.cache) {
          const status = response.result._meta?.cache;
          assert(["hit", "miss", "bypass", "disabled"].includes(status));
          stats.cache_status[status] = (stats.cache_status[status] || 0) + 1;
        } else if (typeof workload === "object") {
          assert.equal(response.result._meta?.cache, undefined);
        }
        const now = performance.now(), latency = now - begin;
        const bucket = Math.ceil(latency * 20); // 0.05 ms upper-bound histogram buckets.
        stats.histogram[bucket] = (stats.histogram[bucket] || 0) + 1;
        const second = Math.floor((now - start) / 1000);
        stats.per_second_ok[second] = (stats.per_second_ok[second] || 0) + 1;
        stats.latency_sum_ms += latency;
        stats.latency_max_ms = Math.max(stats.latency_max_ms, latency);
        stats.ok++;
      } catch (error) {
        stats.errors++;
        if (stats.error_examples.length < 3) stats.error_examples.push(error.message);
        await delay(1);
      }
    }
  }));
  lag.disable();
  stats.thread_cpu_us = process.threadCpuUsage(cpu);
  stats.event_loop_utilization = concurrency ? performance.eventLoopUtilization(elu).utilization : null;
  stats.event_loop_delay_p99_ms = concurrency ? lag.percentile(99) / 1e6 : null;
  return stats;
}

async function processInfo(pid) {
  const { stdout } = await exec("ps", ["-p", String(pid), "-o", "cputime=,rss="]);
  const [time, rss] = stdout.trim().split(/\s+/);
  assert(time && rss, "Server disappeared during sampling");
  const cpuSeconds = time.split(":").reduce((total, part) => total * 60 + Number(part), 0);
  return { cpuSeconds, rssKiB: Number(rss) };
}

function percentile(histogram, count, fraction) {
  const rank = Math.ceil(count * fraction);
  let n = 0;
  for (const [bucket, samples] of Object.entries(histogram).sort((a, b) => Number(a[0]) - Number(b[0]))) {
    n += samples; if (n >= rank) return Number(bucket) / 20;
  }
  return null;
}

export async function phase(server, target, transport, config, stage, concurrency, seconds, workload = "select1") {
  const before = await processInfo(server.child.pid);
  let peakRss = before.rssKiB, sampling = false, samplingError;
  const sampler = setInterval(async () => {
    if (sampling) return;
    sampling = true;
    try { peakRss = Math.max(peakRss, (await processInfo(server.child.pid)).rssKiB); }
    catch (error) { samplingError = error; }
    finally { sampling = false; }
  }, 1000);
  const cpu = process.cpuUsage(), start = performance.now();
  let samples;
  try {
    samples = transport === "stdio"
      ? [await load(server.client, target, concurrency, seconds, workload)]
      : await Promise.all(server.workers.map((worker, i) => {
        const result = receive(worker);
        const count = server.workers.length;
        worker.postMessage({ concurrency: Math.floor(concurrency / count) + (i < concurrency % count ? 1 : 0), seconds, workload });
        return result;
      }));
  } finally { clearInterval(sampler); }
  const elapsed = (performance.now() - start) / 1000;
  const clientCpu = process.cpuUsage(cpu), after = await processInfo(server.child.pid);
  while (sampling) await delay(1);
  if (samplingError) throw samplingError;
  server.assertHealthy();
  const sum = key => samples.reduce((total, sample) => total + sample[key], 0);
  const histogram = {}, perSecond = [], cacheStatus = {};
  for (const sample of samples) {
    for (const [status, n] of Object.entries(sample.cache_status)) cacheStatus[status] = (cacheStatus[status] || 0) + n;
    for (const [bucket, n] of Object.entries(sample.histogram)) histogram[bucket] = (histogram[bucket] || 0) + n;
    sample.per_second_ok.forEach((n, i) => { perSecond[i] = (perSecond[i] || 0) + (n || 0); });
  }
  const result = {
    app: target.app, transport, stage, workload, ...config, concurrency,
    http_sessions: server.workers.length, generator_threads: server.workers.length || 1,
    requested_seconds: seconds, elapsed_seconds: elapsed,
    successful: sum("ok"), busy: sum("busy"), errors: sum("errors"), successful_rps: round(sum("ok") / elapsed),
    latency_ms: { mean: round(sum("latency_sum_ms") / sum("ok")), p50: percentile(histogram, sum("ok"), 0.5), p95: percentile(histogram, sum("ok"), 0.95), p99: percentile(histogram, sum("ok"), 0.99), max: round(Math.max(...samples.map(s => s.latency_max_ms))) },
    server_cpu_percent: round((after.cpuSeconds - before.cpuSeconds) / elapsed * 100),
    server_peak_rss_mib: round(Math.max(peakRss, after.rssKiB) / 1024),
    generator_cpu_percent: round((clientCpu.user + clientCpu.system) / 1e6 / elapsed * 100),
    generator_rss_mib: round(process.memoryUsage().rss / 1048576),
    generator_event_loop_utilization: samples.map(s => s.event_loop_utilization === null ? null : round(s.event_loop_utilization)),
    generator_event_loop_delay_p99_ms: samples.map(s => s.event_loop_delay_p99_ms === null ? null : round(s.event_loop_delay_p99_ms)),
    per_second_successful: Array.from(perSecond, n => n || 0), latency_histogram_005ms: histogram,
    ...(typeof workload === "object" && workload.cache ? { cache_status: cacheStatus } : {}),
    error_examples: samples.flatMap(s => s.error_examples).slice(0, 5),
  };
  assert.equal(Object.values(histogram).reduce((a, b) => a + b, 0), result.successful);
  if (stage !== "warmup") {
    console.log(JSON.stringify(result));
    console.error(`${target.app} ${config.benchmarkMode || transport} ${stage} ${config.profile} c=${concurrency}: ${result.successful_rps} successful RPS, busy=${result.busy}, errors=${result.errors}, p99=${result.latency_ms.p99}ms`);
  }
  return result;
}

async function main() {
  const smoke = process.env.STRESS_SMOKE === "true";
  const apps = (process.env.STRESS_APPS || "mysql,pg").split(",");
  const transports = (process.env.STRESS_TRANSPORTS || "stdio,http").split(",");
  for (const app of apps) {
    assert(targets[app]);
    for (const transport of transports) {
      assert(["stdio", "http"].includes(transport));
      const candidates = [];
      // Leave database connection capacity for administration (limits: MySQL 151, PG 100).
      const capacity = app === "mysql" ? 128 : 96;
      const profiles = [{ profile: "default", pool: 10, inflight: 4 }, ...smoke ? [] : [{ profile: "expanded", pool: capacity, inflight: capacity }]];
      for (const config of profiles) {
        const server = await startServer(targets[app], transport, config);
        try {
          await phase(server, targets[app], transport, config, "warmup", 4, smoke ? 0.2 : 2);
          const expanded = app === "mysql" ? [1, 4, 8, 16, 32, 64, 80, 96, 112, 124, 128, 256] : [1, 4, 8, 16, 32, 64, 80, 88, 92, 94, 96, 192];
          const levels = smoke ? [1, 4] : config.profile === "default" ? [1, 4, 8, 16] : expanded;
          for (const concurrency of levels) candidates.push(await phase(server, targets[app], transport, config, "sweep", concurrency, smoke ? 0.3 : 5));
        } finally { await server.close(); }
      }
      // Full-pool concurrency produced a rare busy reply in a longer pilot run.
      // Retain full/over-cap sweep results, but confirm with worker headroom.
      const eligible = candidates.filter(r => !r.busy && !r.errors && r.concurrency < r.pool)
        .sort((a, b) => b.successful_rps - a.successful_rps);
      let confirmed = false;
      for (const best of eligible) {
        const config = { profile: best.profile, pool: best.pool, inflight: best.inflight };
        const server = await startServer(targets[app], transport, config);
        try {
          await phase(server, targets[app], transport, config, "warmup", best.concurrency, smoke ? 0.2 : 2);
          let stable = true;
          for (let i = 0; i < (smoke ? 1 : 3); i++) {
            const result = await phase(server, targets[app], transport, config, "confirm", best.concurrency, smoke ? 0.3 : 30);
            assert.equal(result.errors, 0, "Request/result validation failed");
            if (result.busy) { stable = false; break; }
          }
          if (!stable) { console.error("Candidate rejected; testing the next error-free sweep setting"); continue; }
          const lookup = await phase(server, targets[app], transport, config, "lookup", best.concurrency, smoke ? 0.3 : 15, "lookup");
          assert.equal(lookup.errors, 0, "Lookup validation failed");
          if (lookup.busy) continue;
          confirmed = true;
          break;
        } finally { await server.close(); }
      }
      assert(confirmed, "No candidate passed sustained confirmation");
    }
  }
}

if (isMainThread && process.argv[1] === fileURLToPath(import.meta.url)) await main();
else if (!isMainThread) {
  const client = httpClient(workerData);
  assert.equal((await client.call("initialize", init)).error, undefined);
  await client.notify();
  parentPort.postMessage({ ready: true });
  parentPort.on("message", async job => {
    try { parentPort.postMessage(await load(client, workerData, job.concurrency, job.seconds, job.workload)); }
    catch (error) { parentPort.postMessage({ failure: error.stack }); }
  });
}
