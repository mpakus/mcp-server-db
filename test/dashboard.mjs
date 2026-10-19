import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, readdirSync, readFileSync, statSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";

async function run(executable, args, env) {
  const child = spawn(executable, args, { env, stdio: ["ignore", "pipe", "pipe"], timeout: 10000 });
  let stdout = "", stderr = "";
  child.stdout.on("data", data => { stdout += data; });
  child.stderr.on("data", data => { stderr += data; });
  const code = await new Promise((resolve, reject) => { child.once("error", reject); child.once("close", resolve); });
  return { code, stdout, stderr };
}

export async function checkDashboard(target, transport, directory, executable, env, client) {
  chmodSync(directory, 0o700);
  let snapshot;
  for (let attempt = 0; attempt < 100; attempt++) {
    const snapshots = readdirSync(directory).filter(name => /^[a-f0-9]{24}\.json$/.test(name))
      .map(name => JSON.parse(readFileSync(`${directory}/${name}`, "utf8")));
    snapshot = snapshots.find(s => s.database.dialect === target.app && s.transport === transport &&
      s.counters.tools >= (transport === "stdio" ? 3 : 12) && s.pool.status === "ok" && s.resources.status === "ok");
    if (snapshot) break;
    await delay(100);
  }
  assert(snapshot, `${target.app}/${transport}: no complete dashboard snapshot`);
  assert.equal(statSync(`${directory}/${snapshot.instance_id}.json`).mode & 0o777, 0o600);
  assert(snapshot.resources.items.some(r => r.uri === `${target.scheme}://tables/${target.schema}/users`));
  assert(snapshot.counters.policy_rejections >= 2);
  assert(snapshot.counters.queries_read >= 1);
  assert(snapshot.counters.tool_success >= 1);
  assert.equal(typeof snapshot.health.last_success_at, "number");
  assert.equal(typeof snapshot.health.last_success_duration_ms, "number");
  assert(snapshot.health.last_success_duration_ms >= 0);
  if (transport === "http") {
    assert(snapshot.counters["http.401"] >= 1);
    assert(snapshot.counters["http.403"] >= 1);
  }
  for (const secret of ["mcp_test_password", "interop-test-token", "SELECT", "john@example.com", "clientInfo"]) {
    assert(!JSON.stringify(snapshot).includes(secret), `snapshot leaked ${secret}`);
  }
  // Deliberately invalid database configuration proves viewers branch before config/pool startup.
  const viewerEnv = { ...env, MYSQL_PORT: "invalid", PG_PORT: "invalid", IS_REMOTE_MCP: "invalid" };
  const status = await run(executable, ["status", "--json", "--instance", snapshot.instance_id], viewerEnv);
  assert.equal(status.code, 0, status.stderr);
  assert(!status.stdout.includes("\x1b"));
  const instances = JSON.parse(status.stdout).instances;
  assert.equal(instances.length, 1);
  assert.equal(instances[0].state, "healthy");
  const resources = await run(executable, ["resources", "--instance", snapshot.instance_id], viewerEnv);
  assert.equal(resources.code, 0, resources.stderr);
  assert(resources.stdout.includes(`${target.scheme}://tables/${target.schema}/users`));
  if (transport === "stdio") {
    const viewer = spawn(executable, ["status", "--watch", "--json", "--instance", snapshot.instance_id], { env: viewerEnv, stdio: ["ignore", "pipe", "pipe"] });
    const closed = new Promise(resolve => viewer.once("close", resolve));
    let output = "";
    viewer.stdout.on("data", data => { output += data; });
    try {
      for (let i = 0; i < 70 && output.trim().split("\n").length < 2; i++) await delay(100);
      const lines = output.trim().split("\n").map(line => JSON.parse(line));
      assert(lines.length >= 2, "watch did not produce JSON Lines");
      assert.equal(lines[0].instances[0].queries_per_second, null);
      assert.equal(typeof lines[1].instances[0].queries_per_second, "number");
      assert(!output.includes("\x1b"));
    } finally {
      viewer.kill("SIGTERM");
      await closed;
    }
    await client.ping();
  }
  console.log(`${target.app}: ${transport} dashboard privacy, inventory and independent CLI checks passed`);
}
