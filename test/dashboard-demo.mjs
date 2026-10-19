// Disposable Compose fixtures only. Ctrl+C closes both MCP clients and removes snapshots.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const directory = mkdtempSync(join(tmpdir(), "mcp-ex-demo-"));
const clients = [];
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await Promise.allSettled(clients.map(client => client.close()));
  rmSync(directory, { recursive: true, force: true });
}
process.once("SIGINT", () => { void stop().then(() => process.exit(0)); });
process.once("SIGTERM", () => { void stop().then(() => process.exit(0)); });
try {
  for (const app of ["mysql", "pg"]) {
    const prefix = app === "mysql" ? "MYSQL" : "PG";
    const client = new Client({ name: "dashboard-fixture-demo", version: "1" });
    clients.push(client);
    await client.connect(new StdioClientTransport({
      command: fileURLToPath(new URL(`../mcp-ex-${app}/mcp-ex-${app}`, import.meta.url)),
      args: ["--stdio"], stderr: "pipe",
      env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "en_US.UTF-8",
        [`${prefix}_HOST`]: "127.0.0.1", [`${prefix}_PORT`]: app === "mysql" ? "13307" : "15433",
        [`${prefix}_USER`]: "mcp_test", [`${prefix}_PASS`]: "mcp_test_password", [`${prefix}_DB`]: "mcp_test",
        MCP_DASHBOARD: "true", MCP_DASHBOARD_DIR: directory, ENABLE_PII_REDACTION: "true" }
    }));
    for (let i = 0; i < 8; i++) {
      await client.callTool({ name: `${app}_query`, arguments: { sql: "SELECT id, label FROM users LIMIT 1" } });
    }
    await client.callTool({ name: `${app}_query`, arguments: { sql: "DELETE FROM users" } });
    await client.callTool({ name: `${app}_query`, arguments: { sql: "SELECT email FROM users" } });
    await client.listResources();
  }
  console.log(`MCP_DASHBOARD_DIR=${directory}`);
  console.log("Both fixture servers are running. Run status/resources in a second terminal; Ctrl+C here stops the demo.");
  // Keep the SDK connections alive without adding artificial query traffic to the example.
  await new Promise(() => {});
} catch (error) {
  console.error(error.message);
  await stop();
  process.exitCode = 1;
}
