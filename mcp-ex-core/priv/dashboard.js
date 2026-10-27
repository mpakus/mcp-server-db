"use strict";

const token = new URLSearchParams(location.hash.slice(1)).get("token");
const element = id => document.getElementById(id);
const text = (id, value) => { element(id).textContent = value; };
const count = value => Number(value ?? 0).toLocaleString();
const ms = value => value == null ? "—" : `${Number(value).toFixed(1)} ms`;
const age = value => value == null ? "Unknown" : `${Math.floor(value / 1000).toLocaleString()} s`;

function notice(message) {
  text("message", message);
  element("message").hidden = !message;
}

function state(value) {
  text("state", value[0].toUpperCase() + value.slice(1));
  element("state").dataset.state = value;
}

function render(snapshot) {
  const db = snapshot.database, c = snapshot.counters, pool = snapshot.pool;
  text("server", snapshot.server.name);
  document.title = `${snapshot.server.name} · MCP dashboard`;
  text("connection", `${db.host}:${db.port} / ${db.name ?? "all databases"}`);
  state(snapshot.state);
  text("tools", count(c.tools));
  text("tool-detail", `${count(c.tool_success)} successful · ${count(c.tool_failed)} failed`);
  text("latency", ms(snapshot.tool_avg_ms));
  text("latency-detail", `Maximum ${ms(snapshot.tool_max_ms)}`);
  text("pool", pool.status === "ok" ? `${count(pool.ready)} / ${count(db.pool_size)}` : pool.status);
  text("pool-detail", `${count(pool.queued)} queued · sampled ${age(snapshot.pool_age_ms)} ago`);
  text("memory", `${(snapshot.beam.memory_bytes / 1048576).toFixed(1)} MiB`);
  text("memory-detail", `${count(snapshot.beam.processes)} VM processes`);
  text("requests", `${count(c.requests)} / ${count(c.rpc_errors)}`);
  text("queries", [c.queries_read, c.queries_write, c.queries_ddl].map(count).join(" / "));
  text("cache", `${count(c.cache_hit)} / ${count(c.cache_miss)}`);
  text("rejections", count(c.policy_rejections));
  text("uptime", age(snapshot.uptime_ms));
  text("transport", snapshot.transport.toUpperCase());
  text("health", `${snapshot.health.status} · checked ${age(snapshot.health_age_ms)} ago`);
  text("schema", db.schema ?? "All allowed schemas");
  text("policy", `${db.read_only ? "Read only" : "Writes enabled"} / ${db.pii ? "On" : "Off"}`);
  text("updated", age(snapshot.snapshot_age_ms));
  text("instance", `Instance ${snapshot.instance_id} · PID ${snapshot.pid}`);

  const resources = snapshot.resources;
  text("resource-count", `${count(resources.total)} resources · ${resources.status}${resources.truncated ? " · first 200 shown" : ""}`);
  const rows = resources.items.map(resource => {
    const row = document.createElement("tr");
    for (const value of [resource.title || resource.name, resource.uri]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    return row;
  });
  if (!rows.length) {
    const row = document.createElement("tr"), cell = document.createElement("td");
    cell.colSpan = 2;
    cell.textContent = resources.status === "ok" ? "No resources found." : "Inventory is being sampled.";
    row.append(cell);
    rows.push(row);
  }
  element("resources").replaceChildren(...rows);
  notice(snapshot.state === "healthy" ? "" : "This snapshot is stale or the database health check is degraded. Values may be out of date.");
}

async function refresh() {
  if (!token) {
    state("offline");
    notice("Open the full private dashboard link printed in the server console.");
    return;
  }
  let retry = true;
  try {
    const response = await fetch("/dashboard/data", {
      headers: { Authorization: `Bearer ${token}` }, cache: "no-store", signal: AbortSignal.timeout(5000),
    });
    if (response.status === 401) {
      retry = false;
      throw new Error("This dashboard link is invalid or the server restarted. Open the new link from the server console.");
    }
    if (!response.ok) throw new Error("The diagnostic snapshot is unavailable. Retrying…");
    render(await response.json());
  } catch (error) {
    state("offline");
    notice(error instanceof TypeError || error.name === "TimeoutError" ? "Cannot reach this server. Displayed values may be out of date. Retrying…" : error.message);
  } finally {
    if (retry) setTimeout(refresh, 2000);
  }
}

refresh();
