// scripts/telegram/quota-gauge-codex.ts
// WS9 (HIMMEL-654) Codex lane probe — parse the weekly (secondary) used_percent
// out of a ~/.codex/logs_2.sqlite* rate-limit blob and build a canonical
// quota-gauge row. A best-effort PIGGYBACK on the (rare) hermes Codex dispatch:
// no standalone lean-invoke command (F5, YAGNI until a reader consumes it), no
// new poll. Pure parse + row-build are fixture-tested here; the thin append is
// wired at the hermes Codex dispatch touchpoint (deferred — see Task 4 verify /
// PR body: no such touchpoint on main yet, and the parallel HIMMEL-558 owns the
// hermes Codex surface).
import type { QuotaGaugeRecord } from "./quota-gauge";

// Extract the SECONDARY (weekly) window's used_percent — the real Codex cap
// signal. Missing/garbled → null (never a fabricated number, T6). The blob is
// scanned for the `secondary` object, then its `used_percent`.
export function parseCodexUsage(blob: string): { usedPct: number } | null {
  const m = blob.match(/"secondary"\s*:\s*\{[^}]*?"used_percent"\s*:\s*([0-9]+(?:\.[0-9]+)?)/);
  if (!m) return null;
  const n = Number(m[1]);
  if (!Number.isFinite(n)) return null;
  return { usedPct: n };
}

// Map the parsed reading to a canonical row. `null` → an `invisible`-source row
// with null fields (visible-not-silent, HIMMEL-275), never a fabricated number.
// glm_peak is null on every codex row (the peak band is a GLM-only concept).
export function buildCodexRow(parsed: { usedPct: number } | null, nowMs: number): QuotaGaugeRecord {
  const ts = new Date(nowMs).toISOString();
  if (parsed === null) {
    return { v: 1, ts, lane: "codex", source: "invisible", used_pct: null, window: null, reset_at: null, tier: null, glm_peak: null, note: "~/.codex/logs_2.sqlite unreadable" };
  }
  return { v: 1, ts, lane: "codex", source: "codex-sqlite", used_pct: parsed.usedPct, window: "weekly", reset_at: null, tier: "pro", glm_peak: null, note: null };
}

// Best-effort probe: read the sqlite blob (missing file → readBlob throws or
// returns "" → ONE invisible row + ONE stderr line, never a throw, T5), build
// the row, append. All I/O injected so it is unit-testable with no real sqlite.
export function codexProbeAppend(readBlob: () => string, nowMs: number, append: (row: QuotaGaugeRecord) => void): void {
  let blob = "";
  try { blob = readBlob(); } catch { blob = ""; }
  const parsed = blob ? parseCodexUsage(blob) : null;
  if (parsed === null) console.error("quota-gauge-codex: ~/.codex/logs_2.sqlite unreadable or no secondary used_percent — recording an invisible codex row");
  append(buildCodexRow(parsed, nowMs));
}
