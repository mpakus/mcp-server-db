// Four-mode current-build comparison: stdio, HTTP, stdio + cache, HTTP + cache.
// Disposable fixtures only; stdout is JSONL.
// CACHE_BENCH_SMOKE=true checks the harness quickly; defaults measure 3 x 20s.
import assert from "node:assert/strict";
import { targets, startServer, phase } from "./stress.mjs";

const smoke = process.env.CACHE_BENCH_SMOKE === "true";
const apps = (process.env.CACHE_BENCH_APPS || "mysql,pg").split(",");
const transports = (process.env.CACHE_BENCH_TRANSPORTS || "stdio,http").split(",");
const seconds = smoke ? 0.3 : 20;
const rounds = smoke ? 1 : 3;

async function run(app, transport, mode, round, jobs) {
  const target = targets[app];
  const config = { profile: "four-mode", mode, round, benchmarkMode: `${transport}${mode === "disabled" ? "" : ` + cache${mode === "hot" ? "" : ` (${mode})`}`}`, pool: app === "mysql" ? 128 : 96,
    inflight: app === "mysql" ? 128 : 96, sessions: transport === "http" ? 4 : 1,
    cacheEnabled: mode !== "disabled", cacheTtl: 5000, cacheMaxEntries: 1000, cacheMaxEntryBytes: 65536 };
  const workload = { kind: "lookup", ...(["hot", "cold"].includes(mode) ? { cache: true } : {}), unique: mode === "cold" };
  const server = await startServer(target, transport, config);
  try {
    await phase(server, target, transport, config, "warmup", jobs[0].concurrency, smoke ? 0.2 : 2, workload);
    for (const job of jobs) {
      const result = await phase(server, target, transport, config, job.stage, job.concurrency, job.seconds, workload);
      assert.equal(result.errors, 0, "Result/protocol validation failed");
      assert.equal(result.busy, 0, "Busy replies invalidate the comparison");
      if (workload.cache) {
        assert.equal(Object.values(result.cache_status).reduce((a, b) => a + b, 0), result.successful);
        if (mode === "cold") assert.equal(result.cache_status.miss, result.successful);
        if (mode === "hot") assert(result.cache_status.hit / result.successful > 0.95);
        assert.equal(result.cache_status.bypass || 0, 0);
      }
    }
  } finally { await server.close(); }
}

for (const transport of transports) assert(["stdio", "http"].includes(transport));
const variants = ["disabled", "hot"].flatMap(mode => transports.map(transport => ({ mode, transport })));
for (const app of apps) {
  assert(targets[app], "Unknown adapter");
  for (const { transport, mode } of variants) {
    await run(app, transport, mode, 0, (smoke ? [4] : [1, 4, 16, 64]).map(concurrency =>
      ({ stage: "sweep", concurrency, seconds: smoke ? 0.3 : 3 })));
  }
  for (let round = 1; round <= rounds; round++) {
    // Interleave all four modes, reversing their order each round.
    for (const { transport, mode } of round % 2 ? variants : [...variants].reverse()) {
      await run(app, transport, mode, round, [{ stage: "confirm", concurrency: smoke ? 4 : 64, seconds }]);
    }
  }
  // Check unique-key misses and enabled caching without per-query opt-in.
  for (const transport of transports) {
    for (const mode of ["cold", "bypass"]) {
      await run(app, transport, mode, 0, [{ stage: "probe", concurrency: smoke ? 4 : 64, seconds: smoke ? 0.3 : 10 }]);
    }
  }
}
