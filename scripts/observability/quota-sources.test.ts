import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serializeQuotaGauge, type QuotaGaugeRecord } from "../telegram/quota-gauge";
import { defaultClaudeCachePath, parseResetsAtMs, readClaudeBank, readCodexBank, readGlmBank, readLaneQuotaTargets, windowLabel } from "./quota-sources";

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "quota-sources-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const NOW = Date.parse("2026-07-13T12:00:00Z");

test("windowLabel maps known windows and falls back to minutes", () => {
  expect(windowLabel(300)).toBe("5h");
  expect(windowLabel(10080)).toBe("weekly");
  expect(windowLabel(43200)).toBe("monthly");
  expect(windowLabel(1440)).toBe("1440m");
});

test("parseResetsAtMs accepts epoch seconds (number + string) and ISO; rejects garbage", () => {
  expect(parseResetsAtMs(1784487767)).toBe(1784487767000);
  expect(parseResetsAtMs("1783980000")).toBe(1783980000000);
  expect(parseResetsAtMs("2026-07-13T06:56:16.164Z")).toBe(Date.parse("2026-07-13T06:56:16.164Z"));
  expect(parseResetsAtMs("soon")).toBeNull();
  expect(parseResetsAtMs(null)).toBeNull();
  expect(parseResetsAtMs(undefined)).toBeNull();
});

test("readClaudeBank returns live 5h + weekly readings", () => {
  const cache = join(tmp, "cache.json");
  const future = String(Math.floor(NOW / 1000) + 3600);
  writeFileSync(cache, JSON.stringify({
    five_hour: { utilization: 17, resets_at: future },
    seven_day: { utilization: 56.00000000000001, resets_at: future },
  }));
  const r = readClaudeBank(cache, NOW);
  expect(r.omitReason).toBeNull();
  expect(r.readings).toEqual([
    { window: "5h", usedPct: 17 },
    { window: "weekly", usedPct: 56.00000000000001 },
  ]);
});

test("readClaudeBank drops an expired window and keeps the live one", () => {
  const cache = join(tmp, "cache.json");
  writeFileSync(cache, JSON.stringify({
    five_hour: { utilization: 99, resets_at: String(Math.floor(NOW / 1000) - 60) },
    seven_day: { utilization: 56, resets_at: String(Math.floor(NOW / 1000) + 3600) },
  }));
  expect(readClaudeBank(cache, NOW).readings).toEqual([{ window: "weekly", usedPct: 56 }]);
});

test("defaultClaudeCachePath honors CLAUDE_USAGE_CACHE, then the platform default", () => {
  expect(defaultClaudeCachePath({ CLAUDE_USAGE_CACHE: "/x/cache.json" }, "linux")).toBe("/x/cache.json");
  expect(defaultClaudeCachePath({}, "linux")).toBe("/tmp/claude/statusline-usage-cache.json");
  expect(defaultClaudeCachePath({}, "darwin")).toBe("/tmp/claude/statusline-usage-cache.json");
  expect(defaultClaudeCachePath({}, "win32")).toBe(join(tmpdir(), "claude", "statusline-usage-cache.json"));
});

test("readClaudeBank omits on missing file, bad JSON, out-of-range or unparseable resets_at", () => {
  expect(readClaudeBank(join(tmp, "absent.json"), NOW).omitReason).toBe("statusline cache not found");
  const bad = join(tmp, "bad.json");
  writeFileSync(bad, "{not json");
  expect(readClaudeBank(bad, NOW).omitReason).toBe("statusline cache unparseable");
  const weird = join(tmp, "weird.json");
  writeFileSync(weird, JSON.stringify({
    five_hour: { utilization: 240, resets_at: String(Math.floor(NOW / 1000) + 60) },
    seven_day: { utilization: 56, resets_at: "someday" },
  }));
  const r = readClaudeBank(weird, NOW);
  expect(r.readings).toEqual([]);
  expect(r.omitReason).toBe("no live window in statusline cache");
});
function rolloutLine(rateLimits: unknown): string {
  return JSON.stringify({ timestamp: "2026-07-13T06:01:43.012Z", type: "event_msg", payload: { type: "token_count", info: {}, rate_limits: rateLimits } });
}

function writeRollout(dir: string, day: string, name: string, lines: string[]): void {
  const d = join(dir, "2026", "07", day);
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, name), lines.join("\n") + "\n");
}

test("readCodexBank emits used_percent verbatim from the newest rollout's newest row", () => {
  const sessions = join(tmp, "sessions");
  const future = Math.floor(NOW / 1000) + 86400;
  writeRollout(sessions, "12", "rollout-2026-07-12T08-00-00-old.jsonl", [
    rolloutLine({ primary: { used_percent: 90.0, window_minutes: 10080, resets_at: future } }),
  ]);
  writeRollout(sessions, "13", "rollout-2026-07-13T08-00-03-new.jsonl", [
    JSON.stringify({ timestamp: "t", type: "event_msg", payload: { type: "agent_message" } }),
    rolloutLine({ primary: { used_percent: 15.0, window_minutes: 10080, resets_at: future } }),
    rolloutLine({ primary: { used_percent: 19.0, window_minutes: 10080, resets_at: future } }),
  ]);
  const r = readCodexBank(sessions, NOW);
  expect(r.omitReason).toBeNull();
  expect(r.readings).toEqual([{ window: "weekly", usedPct: 19 }]);
});

test("readCodexBank reads primary + secondary windows and skips expired ones", () => {
  const sessions = join(tmp, "sessions2");
  const future = Math.floor(NOW / 1000) + 3600;
  const past = Math.floor(NOW / 1000) - 60;
  writeRollout(sessions, "13", "rollout-2026-07-13T09-00-00-x.jsonl", [
    rolloutLine({
      primary: { used_percent: 76.0, window_minutes: 10080, resets_at: past },
      secondary: { used_percent: 40.0, window_minutes: 300, resets_at: future },
    }),
  ]);
  expect(readCodexBank(sessions, NOW).readings).toEqual([{ window: "5h", usedPct: 40 }]);
});

test("readCodexBank falls back to an older file when the newest has no rate_limits", () => {
  const sessions = join(tmp, "sessions3");
  const future = Math.floor(NOW / 1000) + 3600;
  writeRollout(sessions, "13", "rollout-2026-07-13T10-00-00-b.jsonl", [
    JSON.stringify({ timestamp: "t", type: "event_msg", payload: { type: "agent_message" } }),
  ]);
  writeRollout(sessions, "13", "rollout-2026-07-13T09-00-00-a.jsonl", [
    rolloutLine({ primary: { used_percent: 50.0, window_minutes: 10080, resets_at: future } }),
  ]);
  expect(readCodexBank(sessions, NOW).readings).toEqual([{ window: "weekly", usedPct: 50 }]);
});

test("readCodexBank widens to the whole file when the newest tail has no rate_limits", () => {
  const sessions = join(tmp, "sessions5");
  const future = Math.floor(NOW / 1000) + 3600;
  const filler = JSON.stringify({ timestamp: "t", type: "event_msg", payload: { type: "agent_message", text: "x".repeat(1024) } });
  const lines = [rolloutLine({ primary: { used_percent: 70.0, window_minutes: 10080, resets_at: future } })];
  while (lines.join("\n").length < 300 * 1024) lines.push(filler);
  writeRollout(sessions, "13", "rollout-2026-07-13T11-00-00-big.jsonl", lines);
  // an older file with a DIFFERENT value must NOT win over the widened newest file
  writeRollout(sessions, "12", "rollout-2026-07-12T11-00-00-old.jsonl", [
    rolloutLine({ primary: { used_percent: 10.0, window_minutes: 10080, resets_at: future } }),
  ]);
  expect(readCodexBank(sessions, NOW).readings).toEqual([{ window: "weekly", usedPct: 70 }]);
});

test("readCodexBank clamps out-of-range used_percent to [0,100]", () => {
  const sessions = join(tmp, "sessions6");
  const future = Math.floor(NOW / 1000) + 3600;
  writeRollout(sessions, "13", "rollout-2026-07-13T09-00-00-neg.jsonl", [
    rolloutLine({ primary: { used_percent: -10.0, window_minutes: 10080, resets_at: future } }),
  ]);
  expect(readCodexBank(sessions, NOW).readings).toEqual([{ window: "weekly", usedPct: 0 }]);
  const sessions2 = join(tmp, "sessions7");
  writeRollout(sessions2, "13", "rollout-2026-07-13T09-00-00-big.jsonl", [
    rolloutLine({ primary: { used_percent: 150.0, window_minutes: 10080, resets_at: future } }),
  ]);
  expect(readCodexBank(sessions2, NOW).readings).toEqual([{ window: "weekly", usedPct: 100 }]);
});

test("readCodexBank keeps primary's reading when primary and secondary share a window", () => {
  const sessions = join(tmp, "sessions8");
  const future = Math.floor(NOW / 1000) + 3600;
  writeRollout(sessions, "13", "rollout-2026-07-13T09-00-00-x.jsonl", [
    rolloutLine({
      primary: { used_percent: 20.0, window_minutes: 300, resets_at: future },
      secondary: { used_percent: 90.0, window_minutes: 300, resets_at: future },
    }),
  ]);
  expect(readCodexBank(sessions, NOW).readings).toEqual([{ window: "5h", usedPct: 20 }]);
});

test("readCodexBank falls through to an older file when the widened newest file has no usable row", () => {
  const sessions = join(tmp, "sessions9");
  const future = Math.floor(NOW / 1000) + 3600;
  const filler = JSON.stringify({ timestamp: "t", type: "event_msg", payload: { type: "agent_message", text: "x".repeat(1024) } });
  const lines: string[] = [];
  while (lines.join("\n").length < 300 * 1024) lines.push(filler);
  writeRollout(sessions, "13", "rollout-2026-07-13T11-00-00-empty-big.jsonl", lines);
  writeRollout(sessions, "12", "rollout-2026-07-12T11-00-00-old.jsonl", [
    rolloutLine({ primary: { used_percent: 42.0, window_minutes: 10080, resets_at: future } }),
  ]);
  expect(readCodexBank(sessions, NOW).readings).toEqual([{ window: "weekly", usedPct: 42 }]);
});

test("readCodexBank omits on missing dir or no usable rows", () => {
  expect(readCodexBank(join(tmp, "nope"), NOW).omitReason).toBe("codex sessions dir not found");
  const sessions = join(tmp, "sessions4");
  writeRollout(sessions, "13", "rollout-2026-07-13T09-00-00-a.jsonl", ["{not json"]);
  expect(readCodexBank(sessions, NOW).omitReason).toBe("no live rate_limits row in recent rollouts");
});

function glmRow(partial: Partial<QuotaGaugeRecord>): string {
  return serializeQuotaGauge({
    v: 1, ts: "2026-07-13T11:00:00Z", lane: "glm", source: "monitor-endpoint",
    used_pct: 3, window: "5h", reset_at: "2026-07-13T13:00:00Z", tier: "pro", glm_peak: false, note: null,
    ...partial,
  });
}

test("readGlmBank emits the latest in-window glm row even when routing-stale", () => {
  const ledger = join(tmp, "quota-gauge.jsonl");
  writeFileSync(ledger, [
    glmRow({ ts: "2026-07-13T09:00:00Z", used_pct: 1 }),
    glmRow({ ts: "2026-07-13T11:00:00Z", used_pct: 3 }),
  ].join("\n") + "\n");
  const r = readGlmBank(ledger, NOW);
  expect(r.omitReason).toBeNull();
  expect(r.readings).toEqual([{ window: "5h", usedPct: 3 }]);
});

test("readGlmBank defaults a null window to 5h and rejects out-of-range used_pct", () => {
  const nullWindow = join(tmp, "null-window.jsonl");
  writeFileSync(nullWindow, glmRow({ window: null }) + "\n");
  expect(readGlmBank(nullWindow, NOW).readings).toEqual([{ window: "5h", usedPct: 3 }]);
  const outOfRange = join(tmp, "out-of-range.jsonl");
  writeFileSync(outOfRange, glmRow({ used_pct: 250 }) + "\n");
  expect(readGlmBank(outOfRange, NOW).omitReason).toBe("no live glm row in quota-gauge ledger");
});

test("readGlmBank omits expired-window, invisible, and missing-ledger cases", () => {
  expect(readGlmBank(join(tmp, "absent.jsonl"), NOW).omitReason).toBe("no live glm row in quota-gauge ledger");
  const expired = join(tmp, "expired.jsonl");
  writeFileSync(expired, glmRow({ reset_at: "2026-07-13T06:56:16.164Z" }) + "\n");
  expect(readGlmBank(expired, NOW).omitReason).toBe("no live glm row in quota-gauge ledger");
  const invisible = join(tmp, "invisible.jsonl");
  writeFileSync(invisible, glmRow({ used_pct: null, source: "invisible" }) + "\n");
  expect(readGlmBank(invisible, NOW).omitReason).toBe("no live glm row in quota-gauge ledger");
});

test("readLaneQuotaTargets splits lanes by declared quota bank, preserving order", () => {
  const lanes = join(tmp, "lanes.json");
  writeFileSync(lanes, JSON.stringify({ lanes: [
    { id: "sonnet", probe: { kind: "always" }, quota: { bank: "claude" } },
    { id: "hermes-critics", probe: { kind: "installed" } },
    { id: "glm", probe: { kind: "env" }, quota: { bank: "glm" } },
    { id: "bogus-bank", quota: { bank: "monopoly" } },
    { id: "" },
  ] }));
  expect(readLaneQuotaTargets(lanes)).toEqual({
    withBank: [{ lane: "sonnet", bank: "claude" }, { lane: "glm", bank: "glm" }],
    without: ["hermes-critics", "bogus-bank"],
  });
});

test("readLaneQuotaTargets is empty on a missing or malformed registry", () => {
  expect(readLaneQuotaTargets(join(tmp, "absent-lanes.json"))).toEqual({ withBank: [], without: [] });
  const malformed = join(tmp, "malformed-lanes.json");
  writeFileSync(malformed, "{not json");
  expect(readLaneQuotaTargets(malformed)).toEqual({ withBank: [], without: [] });
});
