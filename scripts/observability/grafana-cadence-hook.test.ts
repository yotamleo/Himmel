// HIMMEL-4289: hermetic tests for the Grafana webhook -> cadence-alert.sh bridge.
// The runner is injected, so no case spawns a real script or sends a real DM.
import { expect, test } from "bun:test";
import { alertCalls, handleWebhook } from "./grafana-cadence-hook";

const payload = (alerts: unknown[]) => JSON.stringify({ status: "firing", alerts });

test("a firing alert becomes one `fail` call with the alertname as the reason", () => {
  const calls = alertCalls(JSON.parse(payload([
    { status: "firing", labels: { alertname: "HimmelFlowRunStalled" }, annotations: { summary: "flow stalled" }, generatorURL: "http://127.0.0.1:3000/x" },
  ])));
  expect(calls).toEqual([["fail", "grafana-HimmelFlowRunStalled", "HimmelFlowRunStalled", "flow stalled http://127.0.0.1:3000/x"]]);
});

test("a resolved alert becomes a `clear` call for its own leg only", () => {
  const calls = alertCalls(JSON.parse(payload([
    { status: "resolved", labels: { alertname: "HimmelFlowRunStalled" } },
  ])));
  expect(calls).toEqual([["clear", "grafana-HimmelFlowRunStalled"]]);
});

test("firing legs carry the alertname so a resolve clears only that alert", () => {
  const calls = alertCalls(JSON.parse(payload([
    { status: "firing", labels: { alertname: "A" } },
    { status: "firing", labels: { alertname: "B" } },
  ])));
  expect(calls.map((c) => c[1])).toEqual(["grafana-A", "grafana-B"]);
});

test("an alert without an alertname is reported as `unknown`, never dropped", () => {
  const calls = alertCalls(JSON.parse(payload([{ status: "firing", labels: {} }])));
  expect(calls[0].slice(0, 3)).toEqual(["fail", "grafana-unknown", "unknown"]);
});

test("handleWebhook runs every call and answers 200; bad JSON answers 400", async () => {
  const ran: string[][] = [];
  const ok = await handleWebhook(payload([{ status: "firing", labels: { alertname: "A" } }]), (a) => { ran.push(a); });
  expect(ok).toBe(200);
  expect(ran.length).toBe(1);
  const bad = await handleWebhook("not json", (a) => { ran.push(a); });
  expect(bad).toBe(400);
  expect(ran.length).toBe(1);
});

test("a runner that throws answers 500 so Grafana retries", async () => {
  const code = await handleWebhook(payload([{ status: "firing", labels: { alertname: "A" } }]), () => { throw new Error("boom"); });
  expect(code).toBe(500);
});
