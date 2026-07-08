import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readGlmWorkers } from "../aggregator/glm";

function fixtureRoot() {
  return mkdtempSync(join(tmpdir(), "fleet-glm-"));
}

test("readGlmWorkers reads meta, artifacts, last outbox line, and grants presence", () => {
  const root = fixtureRoot();
  const sessionDir = join(root, "glm-sessions", "demo");
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(join(sessionDir, "meta.json"), JSON.stringify({ name: "demo", branch: "glm/demo", status: "running", sessionDir }));
  writeFileSync(join(sessionDir, "outbox.jsonl"), '{"text":"first"}\n{"type":"escalation","capability":"net.fetch"}\n');
  writeFileSync(join(sessionDir, "grants.jsonl"), "");

  const workers = readGlmWorkers(root);
  expect(workers).toHaveLength(1);
  expect(workers[0]).toMatchObject({ lane: "glm", name: "demo", status: "running", branch: "glm/demo", sessionDir, hasGrants: true });
  expect(workers[0].lastOutboxLine).toEqual({ type: "escalation", capability: "net.fetch" });
  expect(workers[0].artifacts).toContain(join(sessionDir, "meta.json"));
  expect(workers[0].artifacts).toContain(join(sessionDir, "outbox.jsonl"));
});

test("readGlmWorkers tolerates missing outbox", () => {
  const root = fixtureRoot();
  const sessionDir = join(root, "glm-sessions", "no-outbox");
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(join(sessionDir, "meta.json"), JSON.stringify({ task_name: "no-outbox", status: "done" }));

  const [worker] = readGlmWorkers(root);
  expect(worker.lastOutboxLine).toBeUndefined();
  expect(worker.hasGrants).toBe(false);
});

test("session with unparseable meta.json renders a degraded worker (finding 4)", () => {
  const root = fixtureRoot();
  const sessionDir = join(root, "glm-sessions", "corrupt");
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(join(sessionDir, "meta.json"), "{not valid json");

  const workers = readGlmWorkers(root);
  expect(workers).toHaveLength(1);
  expect(workers[0]).toMatchObject({ lane: "glm", name: "corrupt", status: "failed" });
  expect(workers[0].artifacts).toContain(join(sessionDir, "meta.json"));
});

test("session with no meta.json is skipped entirely (finding 4)", () => {
  const root = fixtureRoot();
  const sessionDir = join(root, "glm-sessions", "no-meta");
  mkdirSync(sessionDir, { recursive: true });

  expect(readGlmWorkers(root)).toHaveLength(0);
});

test("unknown meta.status fails closed to 'failed' at the glm boundary", () => {
  const bridgeRoot = mkdtempSync(join(tmpdir(), "fleet-glm-"));
  const sessionDir = join(bridgeRoot, "glm-sessions", "glm-weird-1");
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(join(sessionDir, "meta.json"), JSON.stringify({ name: "weird", status: "exploded" }));
  const workers = readGlmWorkers(bridgeRoot);
  expect(workers.find((w) => w.name === "weird")?.status).toBe("failed");
});
