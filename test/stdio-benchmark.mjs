// Compare preserved baseline escripts with the current build. Disposable fixtures only.
// BENCH_BEFORE_DIR must contain mcp-ex-mysql and mcp-ex-pg built before the change.
import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import { join } from "node:path";
import { targets, startServer, phase } from "./stress.mjs";

const before = process.env.BENCH_BEFORE_DIR;
assert(before, "Set BENCH_BEFORE_DIR to the preserved baseline executables");
const smoke = process.env.BENCH_SMOKE === "true";
const apps = (process.env.BENCH_APPS || "mysql,pg").split(",");
for (const app of apps) {
  assert(targets[app], "Unknown database adapter");
  await access(join(before, `mcp-ex-${app}`));
}

async function run(app, version, transport, config, jobs) {
  const target = { ...targets[app], ...(version === "before" ? { executable: join(before, `mcp-ex-${app}`) } : {}) };
  const settings = { ...config, version };
  const server = await startServer(target, transport, settings);
  try {
    await phase(server, target, transport, settings, "warmup", jobs[0].concurrency, smoke ? 0.2 : 2);
    for (const job of jobs) {
      const result = await phase(server, target, transport, settings,
        job.stage, job.concurrency, smoke ? 0.3 : job.seconds, job.workload);
      assert.equal(result.errors, 0, "Unexpected query/protocol/result error");
      if (job.stage !== "overload") assert.equal(result.busy, 0, "Busy replies invalidate this comparison");
      else assert(result.busy > 0, "Overload must exercise bounded admission");
    }
  } finally { await server.close(); }
}

for (const app of apps) {
  const pool = app === "mysql" ? 128 : 96;
  const concurrency = app === "mysql" ? 124 : 88;
  const expanded = { profile: "expanded", pool, inflight: pool };
  for (const version of ["before", "after"]) {
    await run(app, version, "stdio", { profile: "default", pool: 10, inflight: 4 },
      [{ stage: "default", concurrency: 4, seconds: 5 }]);
    await run(app, version, "stdio", expanded, [
      ...(smoke ? [4] : [1, 4, 16, 32, 64, concurrency]).map(c => ({ stage: "sweep", concurrency: c, seconds: 5 })),
      { stage: "overload", concurrency: pool * 2, seconds: 3 },
    ]);
  }
  const variants = [
    ["before", "stdio", 1], ["after", "stdio", 1],
    ["before", "http", 4], ["after", "http", 4], ["after", "http", 1],
  ];
  for (let round = 0; round < (smoke ? 1 : 3); round++) {
    // Alternate execution order to reduce systematic warm-up/time-of-run bias.
    for (const [version, transport, sessions] of round % 2 ? [...variants].reverse() : variants) {
      await run(app, version, transport, { ...expanded, sessions, round: round + 1 }, [
        { stage: "confirm", concurrency, seconds: 30 },
        ...round === (smoke ? 0 : 2) ? [{ stage: "lookup", concurrency, seconds: 10, workload: "lookup" }] : [],
      ]);
    }
  }
}
