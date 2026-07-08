import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { capabilityShape, escalationId, readEscalations } from "../aggregator/escalations";
import { startServer } from "../server";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "fleet-esc-"));
  const s = join(root, "glm-sessions", "demo");
  mkdirSync(s, { recursive: true });
  const granted = { type: "escalation", capability: "net.fetch", step: 3, ts: "2026-07-07T00:00:00Z" };
  const open = { type: "escalation", capability: "fs.write", step: "ship", ts: "2026-07-07T00:01:00Z" };
  const id = escalationId({ sessionDir: s, step: granted.step, capability: granted.capability, ts: granted.ts });
  writeFileSync(join(s, "outbox.jsonl"), `${JSON.stringify(granted)}\n${JSON.stringify(open)}\n`);
  writeFileSync(join(s, "grants.jsonl"), `${JSON.stringify({ escalation_id: id, capability: "net.fetch" })}\n`);
  return { root, id };
}

test("escalationId is deterministic first-12-hex of sha256 over the tuple", () => {
  const a = escalationId({ sessionDir: "/s", step: 3, capability: "net.fetch", ts: "2026-07-07T00:00:00Z" });
  const b = escalationId({ sessionDir: "/s", step: 3, capability: "net.fetch", ts: "2026-07-07T00:00:00Z" });
  expect(a).toBe(b);
  expect(a).toMatch(/^[0-9a-f]{12}$/);
});

test("adjudicated escalations drop out and open escalations remain", () => {
  const { root, id } = fixture();
  const { escalations: open } = readEscalations(root);
  expect(open.find((e) => e.escalation_id === id)).toBeUndefined();
  expect(open.some((e) => e.capability === "fs.write" && e.shape === "write")).toBe(true);
});

test("malformed escalation lines are skipped but counted as parseErrors (finding 13)", () => {
  const root = mkdtempSync(join(tmpdir(), "fleet-esc-bad-"));
  const s = join(root, "glm-sessions", "demo");
  mkdirSync(s, { recursive: true });
  const good = { type: "escalation", capability: "fs.write", step: 1, ts: "2026-07-07T00:00:00Z" };
  writeFileSync(join(s, "outbox.jsonl"), `${JSON.stringify(good)}\n{not json\n`);

  const { escalations, parseErrors } = readEscalations(root);
  expect(escalations.some((e) => e.capability === "fs.write")).toBe(true);
  expect(parseErrors).toBe(1);
});

test("capabilityShape maps per the charter taxonomy", () => {
  expect(capabilityShape("net.fetch")).toBe("read");
  expect(capabilityShape("fs.read")).toBe("read");
  expect(capabilityShape("gh.list")).toBe("read");
  expect(capabilityShape("fs.write")).toBe("write");
  expect(capabilityShape("tool.delete")).toBe("write");
  expect(capabilityShape("mystery.cap")).toBe("write");
});

test("GET /escalations returns open escalations", async () => {
  const { root } = fixture();
  const { server, port } = startServer({ port: 0, stateRoot: root, bridgeRoot: root });
  try {
    const body = await (await fetch(`http://127.0.0.1:${port}/escalations`)).json();
    expect(body.escalations.some((e: any) => e.capability === "fs.write")).toBe(true);
    expect(typeof body.parseErrors).toBe("number");
  } finally { server.stop(); }
});
