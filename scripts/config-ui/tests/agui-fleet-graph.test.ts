// HIMMEL-4751: the fleet row's place in the agent graph (graphOf, from the session's own handover doc) and its
// token usage (usageOf, from the session JSONL usage records). Pure functions over fixture text; the route suite
// (agui-fleet.test.ts) drives the same fields end to end.
import { test, expect } from "bun:test";
import { graphOf, usageOf } from "../agui/fleet";

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
