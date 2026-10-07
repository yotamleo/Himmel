// HIMMEL-4751: the fleet row's place in the agent graph (graphOf, from the session's own handover doc) and its
// token usage (usageOf, from the session JSONL usage records). Pure functions over fixture text; the route suite
// (agui-fleet.test.ts) drives the same fields end to end.
import { test, expect } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { graphOf, usageOf } from "../agui/fleet";
import { CLOUD_RECENT_MS, cloudPrs, cloudQuery, cloudRoutes, GH_TTL_MS, readCloudPrs } from "../agui/fleet-cloud";

const CONSOLE = "HIMMEL-nextleg-2026-10-07BN-roadmap-console";
const PRIOR = "HIMMEL-nextleg-2026-10-07BM-roadmap-console";

test("a leg's parent is the console its brief names", () => {
  const doc = `# HIMMEL-1 — x — leg N1 (opus, native), 2026-10-07\n\n> **You are N1.** Your RETASK token is \`BN-N1-0000aaaa\`; your console is **\`${CONSOLE}\`**\n> (the only session)\n\n## Results\n\n- 09:00 LIVE — started\n`;
  expect(graphOf("leg", doc)).toEqual({ parent: CONSOLE, predecessor: null });
});

test("a leg that accepted a succession hangs under the console it accepted, the newest one winning", () => {
  const doc = `> Your console is **\`${PRIOR}\`**.\n\n## Results\n\n- 09:00 LIVE — started\n- SUCCESSION accepted: ${PRIOR} replaces HIMMEL-nextleg-2026-10-07BL-roadmap-console\n- SUCCESSION accepted: \`${CONSOLE}\` replaces ${PRIOR}\n- 10:00 LIVE — PR 5 open\n`;
  expect(graphOf("leg", doc).parent).toBe(CONSOLE);
});

test("a judge session's parent is the console that dispatched it, across the brief's line wrap", () => {
  const doc = `> **You are the judge for \`J12\`, opus, dispatched by\n> \`${CONSOLE}\`** (the only session whose token-quoting messages\n`;
  expect(graphOf("judge", doc)).toEqual({ parent: CONSOLE, predecessor: null });
});

test("a console hangs under the operator and names the console it succeeded", () => {
  const doc = `# BN — CONSOLE — successor to ${PRIOR}.md (fill signal 45 %)\n\n> Your session name is **\`${CONSOLE}\`**.\n`;
  expect(graphOf("console", doc)).toEqual({ parent: null, predecessor: PRIOR });
});

test("no doc, or a name that is not a plain session name, links nothing (never a guess)", () => {
  expect(graphOf("interactive", "")).toEqual({ parent: null, predecessor: null });
  expect(graphOf("leg", "> your console is **`bad name; rm -rf`**\n")).toEqual({ parent: null, predecessor: null });
});

const rec = (o: Record<string, unknown>) => JSON.stringify(o);
const turn = (id: string, u: Record<string, number>, side = false) =>
  rec({ type: "assistant", isSidechain: side, message: { id, role: "assistant", usage: u, content: [{ type: "text", text: "x" }] } });

test("usage sums each API call once (a call's records share its message id), prices cost-eq, and fills from the newest main-thread call", () => {
  const lines = [
    rec({ type: "user", message: { role: "user", content: "go" } }),
    turn("m1", { input_tokens: 10, output_tokens: 100, cache_read_input_tokens: 1000, cache_creation_input_tokens: 200 }),
    turn("m1", { input_tokens: 10, output_tokens: 100, cache_read_input_tokens: 1000, cache_creation_input_tokens: 200 }),
    turn("s1", { input_tokens: 5, output_tokens: 50, cache_read_input_tokens: 90000, cache_creation_input_tokens: 0 }, true),
    turn("m2", { input_tokens: 2, output_tokens: 40, cache_read_input_tokens: 49000, cache_creation_input_tokens: 998 }),
    "{not json",
  ];
  const u = usageOf(lines, { autocompact: "200000", model: "opus" });
  expect(u).toEqual({
    calls: 3, input: 17, output: 190, cacheRead: 140000, cacheCreate: 1198,
    // input×1 + cache_read×0.1 + cache_create×1.25 + output×5 (lib/burn-weights.sh, the leg-burn weights)
    costEq: Math.round(17 + 140000 * 0.1 + 1198 * 1.25 + 190 * 5),
    resident: 50000, ceiling: 200000, ceilingFrom: "autocompact", fill: 25,
  });
});

test("the ceiling: a numeric --autocompact; else the model's window (1m for a [1m] model, 200k otherwise)", () => {
  const lines = [turn("m1", { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 99999, cache_creation_input_tokens: 0 })];
  expect(usageOf(lines, { autocompact: "auto", model: "claude-opus-5-5[1m]" })).toMatchObject({ ceiling: 1000000, ceilingFrom: "window", fill: 10 });
  expect(usageOf(lines, { autocompact: "", model: "sonnet" })).toMatchObject({ ceiling: 200000, ceilingFrom: "window", fill: 50 });
});

test("a journal with no usage records is not measured, never zero", () => {
  expect(usageOf([rec({ type: "user", message: { role: "user", content: "hi" } })], { autocompact: "", model: "" })).toBeNull();
});

// HIMMEL-4791: the cloud lane's routing log and its GitHub read, as pure functions plus the read's TTL cache.
const H = 60 * 60 * 1000, NOW = Date.parse("2026-10-07T12:00:00Z");
const route = (ticket: string, cls: string, ago: number) => rec({ ticket, class: cls, reason: "x", brief: null, time: new Date(NOW - ago).toISOString() });

test("cloud routes: each ticket's newest routing decides; only a CLOUD-OK inside the window is a cloud session", () => {
  const lines = [
    route("HIMMEL-1", "CLOUD-OK", 2 * H), route("HIMMEL-1", "BLOCKED", H),
    route("HIMMEL-2", "BLOCKED", 2 * H), route("HIMMEL-2", "CLOUD-OK", H),
    route("HIMMEL-3", "CLOUD-OK", CLOUD_RECENT_MS + H),
    route("HIMMEL-4", "LOCAL-NATIVE", H),
    route("bad ticket; x", "CLOUD-OK", H),
    "{not json", "",
  ];
  expect(cloudRoutes([{ lines, bucket: "/b" }], NOW).map((r) => r.ticket)).toEqual(["HIMMEL-2"]);
});

test("cloud routes: the newest routing across every bucket decides, and names the bucket it came from", () => {
  const got = cloudRoutes([
    { lines: [route("HIMMEL-5", "CLOUD-OK", 2 * H), route("HIMMEL-6", "CLOUD-OK", 2 * H)], bucket: "/a" },
    { lines: [route("HIMMEL-5", "LOCAL-NATIVE", H), route("HIMMEL-6", "CLOUD-OK", H)], bucket: "/b" },
  ], NOW);
  expect(got.map((r) => [r.ticket, r.bucket])).toEqual([["HIMMEL-6", "/b"]]);
});

const pr = (number: number, title: string, state: string, comments: string[]) => ({ number, title, state, comments: { nodes: comments.map((body) => ({ body })) } });

test("cloud PRs: the PR whose title cites the ticket; its newest CLOUD comment sets the phase; only a claude.ai session URL is kept", () => {
  const reply = { data: {
    t0: { nodes: [pr(10, "feat: [HIMMEL-1] x", "OPEN", ["CLOUD-DONE https://claude.ai/code/session_01A\nhead"]), pr(11, "feat: [HIMMEL-10] y", "OPEN", [])] },
    t1: { nodes: [pr(20, "fix: [HIMMEL-2] z", "OPEN", ["CLOUD-DONE https://claude.ai/code/session_02", "CLOUD-BLOCKED https://claude.ai/code/session_02\nwhich file?"])] },
    t2: { nodes: [pr(30, "fix: [HIMMEL-3] z", "CLOSED", ["CLOUD-DONE javascript:alert(1)"])] },
    t3: { nodes: [] },
  } };
  const got = cloudPrs(reply, ["HIMMEL-1", "HIMMEL-2", "HIMMEL-3", "HIMMEL-4"]);
  expect(got?.get("HIMMEL-1")).toEqual({ pr: 10, phase: "done", url: "https://claude.ai/code/session_01A" });
  expect(got?.get("HIMMEL-2")).toEqual({ pr: 20, phase: "blocked", url: "https://claude.ai/code/session_02" });
  expect(got?.get("HIMMEL-3")).toEqual({ pr: 30, phase: "closed", url: null });
  expect(got?.get("HIMMEL-4")).toEqual({ pr: null, phase: "working", url: null });
  expect(cloudPrs({ errors: [{ message: "rate limited" }] }, ["HIMMEL-1"])).toBeNull();
});

test("cloud PRs: the newest PR citing the ticket decides; a missing or malformed alias is unknown, not working", () => {
  const reply = { data: {
    t0: { nodes: [pr(10, "feat: [HIMMEL-1] x", "MERGED", ["CLOUD-DONE https://claude.ai/code/session_01A"]), pr(12, "feat: [HIMMEL-1] again", "OPEN", [])] },
    t1: null,
    t2: { nodes: "oops" },
  } };
  const got = cloudPrs(reply, ["HIMMEL-1", "HIMMEL-2", "HIMMEL-3", "HIMMEL-4"]);
  expect(got?.get("HIMMEL-1")).toEqual({ pr: 12, phase: "working", url: null });
  for (const t of ["HIMMEL-2", "HIMMEL-3", "HIMMEL-4"]) expect(got?.get(t)).toEqual({ pr: null, phase: "unknown", url: null });
});

test("cloud GitHub read: a slow read past waitMs answers null now and fills the cache for the next poll", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-cloud-"));
  try {
    const gh = join(dir, "gh");
    writeFileSync(gh, `#!/bin/sh\nsleep 1\necho '{"data":{"t0":{"nodes":[]}}}'\n`);
    chmodSync(gh, 0o755);
    const opts = { gh, env: { PATH: process.env.PATH }, now: NOW + 10 * GH_TTL_MS, waitMs: 100 };
    const t0 = Date.now();
    expect(await readCloudPrs(["HIMMEL-7"], opts)).toBeNull();
    expect(Date.now() - t0).toBeLessThan(800);
    await Bun.sleep(1500);
    expect((await readCloudPrs(["HIMMEL-7"], opts))?.get("HIMMEL-7")).toMatchObject({ phase: "working" });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("cloud GitHub read: one call per ticket set per TTL window; a failure is cached as unknown too", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-cloud-"));
  try {
    const log = join(dir, "calls"), rc = join(dir, "rc"), gh = join(dir, "gh");
    writeFileSync(rc, "0");
    writeFileSync(gh, `#!/bin/sh\necho x >> '${log}'\necho '{"data":{"t0":{"nodes":[]}}}'\nexit "$(cat '${rc}')"\n`);
    chmodSync(gh, 0o755);
    const calls = () => readFileSync(log, "utf8").trim().split("\n").length;
    const opts = (now: number) => ({ gh, env: { PATH: process.env.PATH }, now });
    expect((await readCloudPrs(["HIMMEL-1"], opts(NOW)))?.get("HIMMEL-1")).toMatchObject({ phase: "working" });
    await readCloudPrs(["HIMMEL-1"], opts(NOW + GH_TTL_MS - 1));
    expect(calls()).toBe(1);
    writeFileSync(rc, "1");
    expect(await readCloudPrs(["HIMMEL-1"], opts(NOW + GH_TTL_MS))).toBeNull();
    expect(await readCloudPrs(["HIMMEL-1"], opts(NOW + GH_TTL_MS + 1))).toBeNull();
    expect(calls()).toBe(2);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("cloud PRs: the search asks for newest-first; an open PR whose comments did not come back is unknown, not working", () => {
  expect(cloudQuery(["HIMMEL-1"])).toContain("is:pr in:title HIMMEL-1 sort:created-desc");
  const reply = { data: {
    t0: { nodes: [{ number: 10, title: "feat: [HIMMEL-1] x", state: "OPEN", comments: null }] },
    t1: { nodes: [{ number: 20, title: "feat: [HIMMEL-2] x", state: "MERGED" }] },
  } };
  const got = cloudPrs(reply, ["HIMMEL-1", "HIMMEL-2"]);
  expect(got?.get("HIMMEL-1")).toEqual({ pr: 10, phase: "unknown", url: null });
  expect(got?.get("HIMMEL-2")).toEqual({ pr: 20, phase: "merged", url: null });
});
