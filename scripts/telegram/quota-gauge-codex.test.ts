import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseCodexUsage, buildCodexRows, codexProbeAppend } from "./quota-gauge-codex";
import type { QuotaGaugeRecord } from "./quota-gauge";

const REPO_ROOT = join(import.meta.dir, "..", "..");
const NOW_MS = Date.parse("2026-07-04T12:00:00Z");

// Real blob shape (HIMMEL-690): each bank carries reset_at (unix epoch SECONDS),
// and each bank appears MANY times in the log — the LAST occurrence is the
// newest reading, so used_percent AND reset_at come from the same last object.
const PRIMARY_RESET_AT = 1782864579;    // epoch seconds
const SECONDARY_RESET_AT = 1783451379;  // epoch seconds
const REAL_BLOB = [
  '{"rate_limits":{"primary":{"used_percent":2,"window_minutes":300,"reset_after_seconds":9999,"reset_at":1782800000},"secondary":{"used_percent":0,"window_minutes":10080,"reset_after_seconds":11111,"reset_at":1783400000}}}',
  '{"rate_limits":{"primary":{"used_percent":5,"window_minutes":300,"reset_after_seconds":10325,"reset_at":' + PRIMARY_RESET_AT + '},"secondary":{"used_percent":1,"window_minutes":10080,"reset_after_seconds":597125,"reset_at":' + SECONDARY_RESET_AT + '}}}',
].join("\n");

test("both banks: LAST occurrence wins; buildCodexRows emits a 5h + a weekly row with ISO reset_at", () => {
  const parsed = parseCodexUsage(REAL_BLOB);
  expect(parsed).not.toBeNull();
  expect(parsed?.primary).not.toBeNull();
  expect(parsed?.secondary).not.toBeNull();
  // LAST occurrence (5 / 1), not the earlier (2 / 0)
  expect(parsed?.primary?.usedPct).toBe(5);
  expect(parsed?.secondary?.usedPct).toBe(1);
  expect(parsed?.primary?.resetAtMs).toBe(PRIMARY_RESET_AT * 1000);
  expect(parsed?.secondary?.resetAtMs).toBe(SECONDARY_RESET_AT * 1000);

  const rows = buildCodexRows(parsed, NOW_MS);
  expect(rows.length).toBe(2);
  const [p, s] = rows;
  expect(p.window).toBe("5h");
  expect(p.used_pct).toBe(5);
  expect(p.reset_at).toBe(new Date(PRIMARY_RESET_AT * 1000).toISOString());
  expect(s.window).toBe("weekly");
  expect(s.used_pct).toBe(1);
  expect(s.reset_at).toBe(new Date(SECONDARY_RESET_AT * 1000).toISOString());
  for (const r of rows) {
    expect(r.v).toBe(1);
    expect(r.lane).toBe("codex");
    expect(r.source).toBe("codex-sqlite");
    expect(r.tier).toBe("pro");
    expect(r.glm_peak).toBeNull(); // peak band is GLM-only
    expect(r.note).toBeNull();
  }
});

test("primary-only blob -> one 5h row; secondary null", () => {
  const blob = '{"rate_limits":{"primary":{"used_percent":7,"window_minutes":300,"reset_after_seconds":10325,"reset_at":1782864579}}}';
  const parsed = parseCodexUsage(blob);
  expect(parsed).not.toBeNull();
  expect(parsed?.primary?.usedPct).toBe(7);
  expect(parsed?.secondary).toBeNull();
  const rows = buildCodexRows(parsed, NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].window).toBe("5h");
  expect(rows[0].used_pct).toBe(7);
  expect(rows[0].reset_at).toBe(new Date(1782864579 * 1000).toISOString());
});

test("secondary-only blob -> one weekly row; primary null", () => {
  const blob = '{"rate_limits":{"secondary":{"used_percent":42,"window_minutes":10080,"reset_after_seconds":597125,"reset_at":1783451379}}}';
  const parsed = parseCodexUsage(blob);
  expect(parsed).not.toBeNull();
  expect(parsed?.primary).toBeNull();
  expect(parsed?.secondary?.usedPct).toBe(42);
  const rows = buildCodexRows(parsed, NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].window).toBe("weekly");
  expect(rows[0].used_pct).toBe(42);
  expect(rows[0].reset_at).toBe(new Date(1783451379 * 1000).toISOString());
});

test("garbled/missing reset_at -> usedPct still returned, resetAtMs null -> reset_at null", () => {
  // primary: reset_at is a non-numeric string (garbled); secondary: reset_at absent.
  const blob = '{"rate_limits":{"primary":{"used_percent":9,"window_minutes":300,"reset_after_seconds":10325,"reset_at":"unknown"},"secondary":{"used_percent":3,"window_minutes":10080,"reset_after_seconds":597125}}}';
  const parsed = parseCodexUsage(blob);
  expect(parsed?.primary?.usedPct).toBe(9);
  expect(parsed?.primary?.resetAtMs).toBeNull();
  expect(parsed?.secondary?.usedPct).toBe(3);
  expect(parsed?.secondary?.resetAtMs).toBeNull();
  const rows = buildCodexRows(parsed, NOW_MS);
  expect(rows.length).toBe(2);
  expect(rows[0].reset_at).toBeNull();
  expect(rows[1].reset_at).toBeNull();
});

test("legacy fixture (no reset_at) -> both banks parse, reset_at degrades to null", () => {
  const blob = readFileSync(join(REPO_ROOT, "tests", "fixtures", "quota-gauge", "codex-logs.sqlite-blob.txt"), "utf8");
  const parsed = parseCodexUsage(blob);
  expect(parsed).not.toBeNull();
  expect(parsed?.primary?.usedPct).toBe(12.5);
  expect(parsed?.secondary?.usedPct).toBe(47.3);
  expect(parsed?.primary?.resetAtMs).toBeNull();
  expect(parsed?.secondary?.resetAtMs).toBeNull();
  const rows = buildCodexRows(parsed, NOW_MS);
  expect(rows.length).toBe(2);
  expect(rows[0].window).toBe("5h");
  expect(rows[1].window).toBe("weekly");
  expect(rows.every((r) => r.reset_at === null)).toBe(true);
});

test("empty/garbage blob -> parseCodexUsage null; buildCodexRows -> exactly ONE invisible row (no fabrication)", () => {
  expect(parseCodexUsage("")).toBeNull();
  expect(parseCodexUsage("not json at all")).toBeNull();
  expect(parseCodexUsage('{"rate_limits":{"secondary":{"window_minutes":10080}}}')).toBeNull(); // no used_percent anywhere
  const rows = buildCodexRows(parseCodexUsage("garbage"), NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].source).toBe("invisible");
  expect(rows[0].used_pct).toBeNull();
  expect(rows[0].window).toBeNull();
  expect(rows[0].reset_at).toBeNull();
});

test("codexProbeAppend: ONE invisible row + ONE stderr on missing/empty; appends every row when banks present (no stderr)", () => {
  const rows: QuotaGaugeRecord[] = [];
  let stderrCount = 0;
  const origErr = console.error;
  console.error = () => { stderrCount++; };
  try {
    codexProbeAppend(() => { throw new Error("ENOENT"); }, NOW_MS, (r) => rows.push(r)); // missing file -> invisible
    codexProbeAppend(() => "", NOW_MS, (r) => rows.push(r));                              // empty blob -> invisible
    codexProbeAppend(() => REAL_BLOB, NOW_MS, (r) => rows.push(r));                      // both banks -> 2 rows
  } finally { console.error = origErr; }
  // missing -> 1 invisible, empty -> 1 invisible, real -> 2 codex-sqlite rows
  expect(rows.length).toBe(4);
  expect(rows[0].source).toBe("invisible");
  expect(rows[1].source).toBe("invisible");
  expect(rows[2].source).toBe("codex-sqlite");
  expect(rows[2].window).toBe("5h");
  expect(rows[3].source).toBe("codex-sqlite");
  expect(rows[3].window).toBe("weekly");
  // stderr fires only on the two invisible probes, never on a found-banks probe
  expect(stderrCount).toBe(2);
});

test("latent illegal state {primary:null, secondary:null} -> invisible row, never a silent zero-row append", () => {
  // parseCodexUsage funnels both-null to top-level null today; this guards the
  // representable-but-illegal ParsedCodex constructed any other way (CR type-design:
  // visible-not-silent must hold regardless of construction path).
  const rows = buildCodexRows({ primary: null, secondary: null }, NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].source).toBe("invisible");
  expect(rows[0].used_pct).toBeNull();
  expect(rows[0].window).toBeNull();
});
