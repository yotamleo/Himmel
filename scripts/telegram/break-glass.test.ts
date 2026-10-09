// HIMMEL-5047: operator break-glass ops on the HIMMEL-4820 typed trusted path.
// Every mutating op is two messages: the op issues a one-time code, `/confirm
// <code>` from the same operator in the same chat runs it. Shell half:
// test-break-glass.sh.
import { expect, test } from "bun:test";
import { mkdtemp, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { KNOWN_OPS, CONFIRM_OPS, parseEnabledOps, type AuditFields } from "./auto-action";
import { classify, type Route } from "./router";
import { handleInbound, handleAutoCommand } from "./poller";

const BREAK_GLASS = ["station-status", "revert-main", "repin-hooks", "launch-leg", "cr-reset", "close-wrapped", "relaunch-console", "restart-bridge"];
const now = () => Math.floor(Date.now() / 1000);
const auto = (text: string): Extract<Route, { kind: "auto" }> => {
  const r = classify(text);
  if (r.kind !== "auto") throw new Error(`not an auto route: ${text}`);
  return r;
};

test("router: each break-glass command classifies to its op, arg and time", () => {
  for (const [text, op, arg, time] of [
    ["/station-status", "station-status", "-", "-"],
    ["/revert-main 2202", "revert-main", "2202", "-"],
    ["/revert-main #2202", "revert-main", "2202", "-"],
    ["/repin-hooks", "repin-hooks", "-", "-"],
    ["/launch-leg N1612", "launch-leg", "N1612", "-"],
    ["/launch-leg N1497d --hook-bypass", "launch-leg", "N1497d", "bypass"],
    ["/cr-reset #2210", "cr-reset", "2210", "-"],
    ["/close-wrapped", "close-wrapped", "-", "-"],
    ["/close-wrapped N1600", "close-wrapped", "N1600", "-"],
    ["/relaunch-console", "relaunch-console", "-", "-"],
    ["/relaunch-console roadmap-console", "relaunch-console", "roadmap-console", "-"],
    ["/restart-bridge", "restart-bridge", "-", "-"],
    ["/confirm 0a1b2c3d", "confirm", "0a1b2c3d", "-"],
  ]) {
    expect(classify(text)).toEqual({ kind: "auto", op, arg, time } as Route);
  }
});

test("router: malformed or embedded break-glass text stays chat", () => {
  for (const text of [
    "/revert-main", "/revert-main abc", "/revert-main 2202 now", "/launch-leg", "/launch-leg x/../y",
    "/launch-leg N1 --no-verify", "/launch-leg N1 --hook-bypass extra", "/cr-reset", "/close-wrapped N1 N2",
    "/relaunch-console Bad_Name", "/relaunch-console --hook-bypass", "/station-status now",
    "/confirm", "/confirm 0a1b2c3", "/confirm 0a1b2c3d9", "/confirm zzzzzzzz", "please /repin-hooks",
  ]) expect(classify(text).kind).toBe("chat");
});

test("every break-glass op is known and needs individual opt-in; all but station-status need a confirm code", () => {
  for (const op of BREAK_GLASS) {
    expect(KNOWN_OPS.has(op)).toBe(true);
    for (const flag of [undefined, "1", "all", "on", "arm-resume"]) expect(parseEnabledOps(flag, KNOWN_OPS).has(op)).toBe(false);
    expect(parseEnabledOps(op, KNOWN_OPS).has(op)).toBe(true);
    expect(CONFIRM_OPS.has(op)).toBe(op !== "station-status");
  }
  expect(KNOWN_OPS.has("confirm")).toBe(false);
});

test("handleInbound: non-operator, caption, forwarded-free disabled op and tagged text never fire", async () => {
  const cases: Array<[string, Partial<{ from: number; caption: boolean }>, string[], boolean]> = [
    ["/revert-main 1", {}, ["revert-main"], true],
    ["/revert-main 1", { from: 2 }, ["revert-main"], false],
    ["/revert-main 1", { caption: true }, ["revert-main"], false],
    ["/revert-main 1", {}, ["repin-hooks"], false],
    ["/revert-main 1", {}, [], false],
    ["model:opus /revert-main 1", {}, ["revert-main"], false],
    ["/confirm 0a1b2c3d", {}, ["revert-main"], true],
    ["/confirm 0a1b2c3d", {}, ["station-status"], false],
    ["/confirm 0a1b2c3d", { from: 2 }, ["revert-main"], false],
  ];
  for (const [text, over, enabled, want] of cases) {
    const root = await mkdtemp(join(tmpdir(), "bg-gate-"));
    let fired = false;
    await handleInbound(root, { from: over.from ?? 1, chat_id: 7, text, ts: now(), caption: over.caption ?? false, forwarded: false }, async () => {}, {
      authorize: (sender) => sender === 1, enabledOps: new Set(enabled), fire: () => { fired = true; },
    }, async () => "spawn-low", (from) => from === 1);
    expect([text, over, enabled, fired]).toEqual([text, over, enabled, want]);
  }
});

type Harness = { runs: string[][]; replies: string[]; audits: AuditFields[]; clock: { t: number }; deps: Parameters<typeof handleAutoCommand>[3] };
function harness(code = 0, stdout = "ok\n", stderr = ""): Harness {
  const h: Harness = { runs: [], replies: [], audits: [], clock: { t: Date.now() }, deps: undefined as never };
  h.deps = {
    runScript: async (op, arg, time) => { h.runs.push([op, arg, time]); return { code, stdout, stderr }; },
    reply: async (_c, text) => { h.replies.push(text); },
    audit: async (f) => { h.audits.push(f); },
    now: () => h.clock.t,
    enabledOps: new Set(BREAK_GLASS),
  };
  return h;
}
const msg = (text: string, over: Partial<{ from: number; chat_id: number; forwarded: boolean }> = {}) =>
  ({ from: over.from ?? 1, chat_id: over.chat_id ?? over.from ?? 1, text, ts: now(), caption: false, forwarded: over.forwarded ?? false });
const codeOf = (reply: string) => reply.match(/\/confirm ([0-9a-f]{8})/)?.[1] ?? "";
async function issue(root: string, h: Harness, text: string) {
  await handleAutoCommand(root, msg(text), auto(text), h.deps);
  return codeOf(h.replies[h.replies.length - 1] ?? "");
}
async function confirm(root: string, h: Harness, code: string, over: Partial<{ from: number; chat_id: number; forwarded: boolean }> = {}) {
  const text = `/confirm ${code}`;
  await handleAutoCommand(root, msg(text, over), auto(text), h.deps);
}

test("station-status is read-only: it runs at once, no confirm code", async () => {
  const root = await mkdtemp(join(tmpdir(), "bg-ss-"));
  const h = harness(0, "host=x\nload=0.1\n");
  await handleAutoCommand(root, msg("/station-status"), auto("/station-status"), h.deps);
  expect(h.runs).toEqual([["station-status", "-", "-"]]);
  expect(h.replies[0]).toContain("load=0.1");
  expect(h.audits.map((a) => a.result)).toEqual(["break-glass-ok"]);
});

test("a mutating op issues a code and runs nothing; the matching /confirm runs it once", async () => {
  for (const text of BREAK_GLASS.filter((op) => op !== "station-status").map((op) => ({
    "revert-main": "/revert-main 2202", "repin-hooks": "/repin-hooks", "launch-leg": "/launch-leg N7 --hook-bypass",
    "cr-reset": "/cr-reset 9", "close-wrapped": "/close-wrapped", "relaunch-console": "/relaunch-console", "restart-bridge": "/restart-bridge",
  } as Record<string, string>)[op])) {
    const root = await mkdtemp(join(tmpdir(), "bg-ok-"));
    const h = harness(0, "done=1\n");
    const code = await issue(root, h, text);
    const r = auto(text);
    expect(code).toMatch(/^[0-9a-f]{8}$/);
    expect(h.runs).toEqual([]);
    expect(h.audits.map((a) => [a.op, a.result])).toEqual([[r.op, "confirm-issued"]]);
    expect(JSON.stringify(h.audits)).not.toContain(code);
    await confirm(root, h, code);
    expect(h.runs).toEqual([[r.op, r.arg, r.time]]);
    expect(h.audits.map((a) => [a.op, a.result])).toEqual([[r.op, "confirm-issued"], [r.op, "break-glass-ok"]]);
    expect(h.replies[h.replies.length - 1]).toContain("done=1");
    await confirm(root, h, code);
    expect(h.runs.length).toBe(1);
    expect(h.audits[h.audits.length - 1].result).toBe("confirm-refused");
  }
});

test("a wrong, missing, expired, other-user, group-chat or forwarded confirm refuses and burns the code", async () => {
  const variants: Array<[string, (root: string, h: Harness, code: string) => Promise<void>]> = [
    ["wrong", (root, h, code) => confirm(root, h, code === "00000000" ? "11111111" : "00000000")],
    ["other-user", (root, h, code) => confirm(root, h, code, { from: 2 })],
    ["group-chat", (root, h, code) => confirm(root, h, code, { chat_id: -100 })],
    ["expired", async (root, h, code) => { h.clock.t += 5 * 60_000 + 1; await confirm(root, h, code); }],
  ];
  for (const [name, bad] of variants) {
    const root = await mkdtemp(join(tmpdir(), "bg-bad-"));
    const h = harness();
    const code = await issue(root, h, "/revert-main 2202");
    await bad(root, h, code);
    expect([name, h.runs]).toEqual([name, []]);
    expect([name, h.audits[h.audits.length - 1].result]).toEqual([name, name === "group-chat" ? "refused-group" : "confirm-refused"]);
    h.clock.t = Date.now();
    await confirm(root, h, code);
    expect([name, "burned", h.runs]).toEqual([name, "burned", []]);
    expect(existsSync(join(root, "break-glass-pending.json"))).toBe(false);
  }
  const root = await mkdtemp(join(tmpdir(), "bg-none-"));
  const h = harness();
  await confirm(root, h, "0a1b2c3d");
  expect(h.runs).toEqual([]);
  expect(h.audits.map((a) => a.result)).toEqual(["confirm-refused"]);
  const fwdRoot = await mkdtemp(join(tmpdir(), "bg-fwd-"));
  const f = harness();
  const code = await issue(fwdRoot, f, "/revert-main 2202");
  await confirm(fwdRoot, f, code, { forwarded: true });
  expect(f.runs).toEqual([]);
  expect(f.audits[f.audits.length - 1].result).toBe("refused-forwarded");
});

test("break-glass ops are DM-only: in a group every op refuses and issues no code", async () => {
  for (const text of ["/station-status", "/revert-main 2202", "/repin-hooks", "/launch-leg N7", "/cr-reset 9", "/close-wrapped", "/relaunch-console", "/restart-bridge"]) {
    const root = await mkdtemp(join(tmpdir(), "bg-group-"));
    const h = harness();
    await handleAutoCommand(root, msg(text, { chat_id: -100 }), auto(text), h.deps);
    expect([text, h.runs]).toEqual([text, []]);
    expect([text, h.audits.map((a) => a.result)]).toEqual([text, ["refused-group"]]);
    expect([text, /\/confirm [0-9a-f]{8}/.test(h.replies.join(" "))]).toEqual([text, false]);
    expect(h.replies[0]).toContain("private chat");
    expect(existsSync(join(root, "break-glass-pending.json"))).toBe(false);
  }
});

test("a forwarded mutating op issues no code; a new op replaces an older pending code", async () => {
  const root = await mkdtemp(join(tmpdir(), "bg-fwd2-"));
  const h = harness();
  await handleAutoCommand(root, msg("/repin-hooks", { forwarded: true }), auto("/repin-hooks"), h.deps);
  expect(h.replies.join(" ")).not.toMatch(/\/confirm [0-9a-f]{8}/);
  expect(existsSync(join(root, "break-glass-pending.json"))).toBe(false);
  const first = await issue(root, h, "/revert-main 1");
  const second = await issue(root, h, "/repin-hooks");
  await confirm(root, h, first);
  expect(h.runs).toEqual([]);
  const pending = JSON.parse(await readFile(join(root, "break-glass-pending.json"), "utf8").catch(() => "{}"));
  expect(pending.op).toBeUndefined();
  void second;
});

test("a pending code for an op disabled since it was issued refuses at /confirm", async () => {
  const root = await mkdtemp(join(tmpdir(), "bg-revoked-"));
  const h = harness();
  const code = await issue(root, h, "/revert-main 2202");
  h.deps.enabledOps = new Set(["repin-hooks"]);
  await confirm(root, h, code);
  expect(h.runs).toEqual([]);
  expect(h.audits[h.audits.length - 1].result).toBe("confirm-refused");
});

test("the agent marker refusal (rc 19) and other failures are reported, never as success", async () => {
  const root = await mkdtemp(join(tmpdir(), "bg-rc-"));
  const h = harness(19, "", "ERR break-glass: refused inside an agent session");
  const code = await issue(root, h, "/repin-hooks");
  await confirm(root, h, code);
  expect(h.audits[h.audits.length - 1]).toMatchObject({ op: "repin-hooks", rc: 19, result: "refused-agent" });
  expect(h.replies[h.replies.length - 1]).toContain("rc=19");
  expect(h.replies[h.replies.length - 1]).not.toContain("✅");
  const h2 = harness(24, "", "ERR break-glass: hooks still differ");
  await handleAutoCommand(root, msg("/station-status"), auto("/station-status"), h2.deps);
  expect(h2.audits[0].result).toBe("error");
  expect(h2.replies[0]).toContain("hooks still differ");
});
