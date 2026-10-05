// HIMMEL-4289: hermetic tests for the Grafana webhook -> cadence-alert.sh bridge.
// The runner is injected, so no case spawns a real script or sends a real DM.
import { expect, test } from "bun:test";
import { LISTEN_HOST, MAX_BODY_BYTES, alertCalls, createHandler, startServer } from "./grafana-cadence-hook";

const TOKEN = "t0ken-0123456789abcdef"; // gitleaks:allow (test fixture, not a credential)
const payload = (alerts: unknown[]) => JSON.stringify({ status: "firing", alerts });
const post = (body: string, headers: Record<string, string> = {}) =>
  new Request("http://127.0.0.1/alert", {
    method: "POST",
    body,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json", ...headers },
  });
const rig = (now = () => 0) => {
  const ran: string[][] = [];
  const handle = createHandler({ token: TOKEN, run: (a) => { ran.push(a); }, now });
  return { ran, handle };
};

test("a firing alert becomes one `fail` call with the alertname as the reason", () => {
  const calls = alertCalls(JSON.parse(payload([
    { status: "firing", labels: { alertname: "HimmelFlowRunStalled" }, annotations: { summary: "flow stalled" }, generatorURL: "http://127.0.0.1:3000/x" },
  ])));
  expect(calls).toEqual([["fail", "grafana-HimmelFlowRunStalled", "HimmelFlowRunStalled", "flow stalled http://127.0.0.1:3000/x"]]);
});

test("a resolved alert becomes a `clear` call for its own leg only", () => {
  const calls = alertCalls(JSON.parse(payload([{ status: "resolved", labels: { alertname: "HimmelFlowRunStalled" } }])));
  expect(calls).toEqual([["clear", "grafana-HimmelFlowRunStalled"]]);
});

test("an alert without an alertname is reported as `unknown`, never dropped", () => {
  const calls = alertCalls(JSON.parse(payload([{ status: "firing", labels: {} }])));
  expect(calls[0].slice(0, 3)).toEqual(["fail", "grafana-unknown", "unknown"]);
});

test("a valid authorized firing POST runs the sink and answers 200", async () => {
  const { ran, handle } = rig();
  const res = await handle(post(payload([{ status: "firing", labels: { alertname: "A" } }])));
  expect(res.status).toBe(200);
  expect(ran.length).toBe(1);
});

test("a wrong or missing token answers 401 and runs nothing", async () => {
  const { ran, handle } = rig();
  const body = payload([{ status: "firing", labels: { alertname: "A" } }]);
  expect((await handle(post(body, { authorization: "Bearer wrong-token-0123456789" }))).status).toBe(401);
  expect((await handle(post(body, { authorization: "" }))).status).toBe(401);
  expect((await handle(new Request("http://127.0.0.1/alert", { method: "POST", body, headers: { "content-type": "application/json" } }))).status).toBe(401);
  expect(ran.length).toBe(0);
});

test("an oversized body answers 413 and runs nothing", async () => {
  const { ran, handle } = rig();
  const big = payload([{ status: "firing", labels: { alertname: "A" }, annotations: { summary: "x".repeat(MAX_BODY_BYTES) } }]);
  expect((await handle(post(big))).status).toBe(413);
  expect(ran.length).toBe(0);
});

test("non-JSON answers 415 (wrong type) or 400 (bad body) and runs nothing", async () => {
  const { ran, handle } = rig();
  expect((await handle(post("alertname=A", { "content-type": "text/plain" }))).status).toBe(415);
  expect((await handle(post("not json"))).status).toBe(400);
  expect((await handle(post("[1,2]"))).status).toBe(400);
  expect(ran.length).toBe(0);
});

test("shell metacharacters and control bytes stay inert, sanitized argv", async () => {
  const { ran, handle } = rig();
  const evil = "$(touch /tmp/pwn); `id` | rm -rf / \n\u0000x";
  const res = await handle(post(payload([
    { status: "firing", labels: { alertname: "A;$(touch /tmp/pwn)`id`/../x" }, annotations: { summary: evil } },
  ])));
  expect(res.status).toBe(200);
  const [, leg, reason, log] = ran[0];
  expect(leg).toMatch(/^grafana-[A-Za-z0-9_.-]+$/);
  expect(reason).toMatch(/^[A-Za-z0-9_.-]+$/);
  expect(log).not.toMatch(/[\u0000-\u001f]/);
  expect(log.length).toBeLessThanOrEqual(300);
});

test("an over-long alertname and summary are length-capped", () => {
  const [call] = alertCalls({ alerts: [{ status: "firing", labels: { alertname: "n".repeat(500) }, annotations: { summary: "s".repeat(5000) } }] });
  expect(call[2].length).toBe(64);
  expect(call[3].length).toBe(300);
});

test("an identical alert inside the dedupe window runs the sink once", async () => {
  let t = 0;
  const { ran, handle } = rig(() => t);
  const body = payload([{ status: "firing", labels: { alertname: "A" } }]);
  expect((await handle(post(body))).status).toBe(200);
  t = 10_000;
  expect((await handle(post(body))).status).toBe(200);
  expect(ran.length).toBe(1);
  t = 70_000;
  await handle(post(body));
  expect(ran.length).toBe(2);
});

test("a flood of distinct alerts is rate limited with 429", async () => {
  const { ran, handle } = rig();
  let last = 200;
  for (let i = 0; i < 10; i++) {
    const alerts = Array.from({ length: 20 }, (_, j) => ({ status: "firing", labels: { alertname: `A${i}-${j}` } }));
    last = (await handle(post(payload(alerts)))).status;
  }
  expect(last).toBe(429);
  expect(ran.length).toBeLessThanOrEqual(60);
});

test("a runner that throws answers 500 so Grafana retries", async () => {
  const handle = createHandler({ token: TOKEN, run: () => { throw new Error("boom"); } });
  expect((await handle(post(payload([{ status: "firing", labels: { alertname: "A" } }])))).status).toBe(500);
});

test("the server binds loopback only and enforces the token over real HTTP", async () => {
  const ran: string[][] = [];
  const server = startServer({ port: 0, token: TOKEN, run: (a) => { ran.push(a); } });
  try {
    expect(LISTEN_HOST).toBe("127.0.0.1");
    expect(server.hostname).toBe("127.0.0.1");
    const base = `http://127.0.0.1:${server.port}`;
    expect((await fetch(`${base}/healthz`)).status).toBe(200);
    const body = payload([{ status: "firing", labels: { alertname: "A" } }]);
    expect((await fetch(`${base}/alert`, { method: "POST", body, headers: { "content-type": "application/json" } })).status).toBe(401);
    expect((await fetch(`${base}/alert`, { method: "POST", body, headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` } })).status).toBe(200);
    expect(ran.length).toBe(1);
  } finally {
    server.stop(true);
  }
});

test("a failed sink call is not deduped: the Grafana retry runs it again", async () => {
  let fail = true;
  const ran: string[][] = [];
  const handle = createHandler({ token: TOKEN, run: (a) => { if (fail) throw new Error("x"); ran.push(a); }, now: () => 0 });
  const body = payload([{ status: "firing", labels: { alertname: "A" } }]);
  expect((await handle(post(body))).status).toBe(500);
  fail = false;
  expect((await handle(post(body))).status).toBe(200);
  expect(ran.length).toBe(1);
});

test("a firing alert re-fires after a resolve inside the dedupe window", async () => {
  const { ran, handle } = rig();
  const firing = payload([{ status: "firing", labels: { alertname: "A" } }]);
  await handle(post(firing));
  await handle(post(payload([{ status: "resolved", labels: { alertname: "A" } }])));
  await handle(post(firing));
  expect(ran.map((c) => c[0])).toEqual(["fail", "clear", "fail"]);
});

test("a batch larger than 20 alerts is processed in full, not truncated", () => {
  const alerts = Array.from({ length: 25 }, (_, i) => ({ status: "firing", labels: { alertname: `A${i}` } }));
  expect(alertCalls(JSON.parse(payload(alerts))).length).toBe(25);
});

test("expired dedupe entries do not accumulate", async () => {
  let t = 0;
  const ran: string[][] = [];
  const handle = createHandler({ token: TOKEN, run: (a) => { ran.push(a); }, now: () => t });
  await handle(post(payload([{ status: "firing", labels: { alertname: "A" }, annotations: { summary: "one" } }])));
  t = 120_000;
  await handle(post(payload([{ status: "firing", labels: { alertname: "A" }, annotations: { summary: "one" } }])));
  expect(ran.length).toBe(2);
});
