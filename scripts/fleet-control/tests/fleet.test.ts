import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { buildFleet } from "../aggregator/fleet";

function makeRoot() {
  const root = mkdtempSync(join(tmpdir(), "fleet-doc-"));
  const glm = join(root, "glm-sessions", "demo");
  mkdirSync(glm, { recursive: true });
  writeFileSync(join(glm, "meta.json"), JSON.stringify({ task_name: "demo", branch: "glm/demo", status: "running" }));
  const codex = join(root, "codex-plugin-data", "state", "himmel-abc");
  mkdirSync(codex, { recursive: true });
  writeFileSync(join(codex, "state.json"), JSON.stringify({ jobs: [{ id: "dead", status: "running", pid: 999999 }] }));
  const logs = join(root, "logs");
  mkdirSync(logs, { recursive: true });
  writeFileSync(join(logs, "hermes-foo.log"), "ok\n");
  writeFileSync(join(root, "quota-gauge.jsonl"), '{"lane":"glm"}\n');
  return root;
}

test("GET /fleet returns unified lanes, feeds, and coverage", async () => {
  const root = makeRoot();
  process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL = JSON.stringify({ name: "armed", handover: "/h.md" });
  const { server, port } = startServer({ port: 0, stateRoot: root, bridgeRoot: root, pluginDataRoot: join(root, "codex-plugin-data") });
  try {
    const doc = await (await fetch(`http://127.0.0.1:${port}/fleet`)).json();
    expect(doc.lanes.glm[0].branch).toBe("glm/demo");
    expect(doc.lanes.codex[0].status).toBe("dead");
    expect(doc.lanes.hermes[0].name).toBe("foo");
    expect(doc.lanes.armed[0].status).toBe("armed");
    expect(doc.feeds.quota).toHaveLength(1);
    expect(doc.coverage.hermesNativeChildren).toBe("blind");
  } finally {
    delete process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL;
    server.stop();
  }
});

test("fleet builder remains passive: no interval polling loop", () => {
  const source = readFileSync(join(import.meta.dir, "..", "aggregator", "fleet.ts"), "utf8");
  expect(source).not.toContain("setInterval");
  const root = makeRoot();
  const doc = buildFleet({ bridgeRoot: root, stateRoot: root, pluginDataRoot: join(root, "codex-plugin-data") });
  expect(doc.generatedAt).toMatch(/T/);
});

test("one throwing lane degrades to a failed marker while other lanes render (finding 1)", () => {
  const root = mkdtempSync(join(tmpdir(), "fleet-degrade-"));
  // glm-sessions as a FILE makes readdirSync throw (ENOTDIR) -> lane must isolate.
  writeFileSync(join(root, "glm-sessions"), "not a dir");
  const logs = join(root, "logs");
  mkdirSync(logs, { recursive: true });
  writeFileSync(join(logs, "hermes-ok.log"), "ok\n");

  const doc = buildFleet({ bridgeRoot: root, stateRoot: root, pluginDataRoot: join(root, "codex-plugin-data") });
  expect(doc.lanes.glm).toHaveLength(1);
  expect(doc.lanes.glm[0].status).toBe("failed");
  expect(doc.lanes.glm[0].name).toBe("<reader error>");
  expect(typeof doc.lanes.glm[0].error).toBe("string");
  expect(doc.lanes.hermes[0].name).toBe("ok"); // other lane rendered normally
});

test("GET /fleet returns 200 with other lanes populated when one lane throws (finding 1)", async () => {
  const root = mkdtempSync(join(tmpdir(), "fleet-degrade-http-"));
  writeFileSync(join(root, "glm-sessions"), "not a dir");
  const logs = join(root, "logs");
  mkdirSync(logs, { recursive: true });
  writeFileSync(join(logs, "hermes-ok.log"), "ok\n");
  const { server, port } = startServer({ port: 0, stateRoot: root, bridgeRoot: root, pluginDataRoot: join(root, "codex-plugin-data") });
  try {
    const res = await fetch(`http://127.0.0.1:${port}/fleet`);
    expect(res.status).toBe(200);
    const doc = await res.json();
    expect(doc.lanes.glm[0].status).toBe("failed");
    expect(doc.lanes.hermes[0].name).toBe("ok");
  } finally {
    server.stop();
  }
});
