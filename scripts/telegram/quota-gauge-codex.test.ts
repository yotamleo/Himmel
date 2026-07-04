import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { parseCodexUsage, buildCodexRow, codexProbeAppend } from "./quota-gauge-codex";
import type { QuotaGaugeRecord } from "./quota-gauge";

const REPO_ROOT = join(import.meta.dir, "..", "..");
const NOW_MS = Date.parse("2026-07-04T12:00:00Z");

test("T4 parseCodexUsage extracts the SECONDARY weekly used%; buildCodexRow -> codex weekly row", () => {
  const blob = readFileSync(join(REPO_ROOT, "tests", "fixtures", "quota-gauge", "codex-logs.sqlite-blob.txt"), "utf8");
  const parsed = parseCodexUsage(blob);
  expect(parsed).not.toBeNull();
  expect(parsed?.usedPct).toBe(47.3); // secondary, NOT the primary 12.5
  const row = buildCodexRow(parsed, NOW_MS);
  expect(row.lane).toBe("codex");
  expect(row.source).toBe("codex-sqlite");
  expect(row.used_pct).toBe(47.3);
  expect(row.window).toBe("weekly");
  expect(row.glm_peak).toBeNull(); // peak band is GLM-only
});

test("T5 missing/empty blob -> ONE invisible row + ONE stderr line per probe, never throws", () => {
  const rows: QuotaGaugeRecord[] = [];
  let stderrCount = 0;
  const origErr = console.error;
  console.error = () => { stderrCount++; };
  try {
    codexProbeAppend(() => { throw new Error("ENOENT"); }, NOW_MS, (r) => rows.push(r)); // missing file
    codexProbeAppend(() => "", NOW_MS, (r) => rows.push(r));                              // empty blob
  } finally { console.error = origErr; }
  expect(rows.length).toBe(2);
  expect(rows.every((r) => r.source === "invisible" && r.used_pct === null)).toBe(true);
  expect(stderrCount).toBe(2);
});

test("T6 garbled rate_limits blob -> parseCodexUsage null, invisible row, no fabrication", () => {
  expect(parseCodexUsage('{"rate_limits":{"secondary":{"window_minutes":10080}}}')).toBeNull(); // no used_percent
  expect(parseCodexUsage("not json at all")).toBeNull();
  const row = buildCodexRow(parseCodexUsage("garbage"), NOW_MS);
  expect(row.source).toBe("invisible");
  expect(row.used_pct).toBeNull();
});
