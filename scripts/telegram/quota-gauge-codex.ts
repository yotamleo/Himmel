// scripts/telegram/quota-gauge-codex.ts
// WS9 (HIMMEL-654) Codex lane probe — parse the primary (5h) and secondary
// (weekly) banks' used_percent + reset_at out of a ~/.codex/logs_2.sqlite*
// rate-limit blob and build canonical quota-gauge rows. A best-effort
// PIGGYBACK on the (rare) hermes Codex dispatch: no standalone lean-invoke
// command (F5, YAGNI until a reader consumes it), no new poll. Pure parse +
// row-build are fixture-tested here; the thin append is wired at the hermes
// Codex dispatch touchpoint (deferred — see Task 4 verify / PR body: no such
// touchpoint on main yet, and the parallel HIMMEL-558 owns the hermes Codex
// surface).
import type { QuotaGaugeRecord } from "./quota-gauge";

// One rate-limit bank reading. `usedPct` is always returned when the bank is
// found; `resetAtMs` is null when reset_at is missing/garbled (never a
// fabricated instant).
export type CodexBank = { usedPct: number; resetAtMs: number | null };

// Both banks, either of which may be null when absent/unusable. `null` at the
// top level means NEITHER bank was found (T6: no fabricated number).
export type ParsedCodex = { primary: CodexBank | null; secondary: CodexBank | null };

// Extract ONE bank's newest reading. The blob concatenates many rate-limit
// snapshots; the LAST `"bank":{...}` occurrence is the newest, so its
// used_percent AND reset_at are taken together (never mixed across snapshots).
// Missing used_percent -> null (bank unusable); garbled/missing reset_at ->
// resetAtMs null (usedPct still returned).
function parseBank(blob: string, bank: "primary" | "secondary"): CodexBank | null {
  const matches = [...blob.matchAll(new RegExp(`"${bank}"\\s*:\\s*\\{([^}]*)\\}`, "g"))];
  if (matches.length === 0) return null;
  const body = matches[matches.length - 1][1];
  const up = body.match(/"used_percent"\s*:\s*([0-9]+(?:\.[0-9]+)?)/);
  if (!up) return null;
  const usedPct = Number(up[1]);
  if (!Number.isFinite(usedPct)) return null;
  let resetAtMs: number | null = null;
  const ra = body.match(/"reset_at"\s*:\s*([0-9]+)/); // epoch SECONDS; quoted/non-numeric won't match -> null
  if (ra) {
    const secs = Number(ra[1]);
    if (Number.isFinite(secs)) resetAtMs = secs * 1000;
  }
  return { usedPct, resetAtMs };
}

// Parse both banks out of the blob. Returns null when NEITHER bank is found
// (T6 — never a fabricated number). One bank found is enough to return a
// non-null result with the other slot null.
export function parseCodexUsage(blob: string): ParsedCodex | null {
  const primary = parseBank(blob, "primary");
  const secondary = parseBank(blob, "secondary");
  if (primary === null && secondary === null) return null;
  return { primary, secondary };
}

function isoOrNull(ms: number | null): string | null {
  return ms === null ? null : new Date(ms).toISOString();
}

// Map the parsed reading to canonical rows — one per found bank. `null` ->
// exactly one `invisible`-source row with null fields (visible-not-silent,
// HIMMEL-275), never a fabricated number. glm_peak is null on every codex row
// (the peak band is a GLM-only concept).
export function buildCodexRows(parsed: ParsedCodex | null, nowMs: number): QuotaGaugeRecord[] {
  const ts = new Date(nowMs).toISOString();
  if (parsed === null) {
    return [{ v: 1, ts, lane: "codex", source: "invisible", used_pct: null, window: null, reset_at: null, tier: null, glm_peak: null, note: "~/.codex/logs_2.sqlite unreadable" }];
  }
  const rows: QuotaGaugeRecord[] = [];
  if (parsed.primary) {
    rows.push({ v: 1, ts, lane: "codex", source: "codex-sqlite", used_pct: parsed.primary.usedPct, window: "5h", reset_at: isoOrNull(parsed.primary.resetAtMs), tier: "pro", glm_peak: null, note: null });
  }
  if (parsed.secondary) {
    rows.push({ v: 1, ts, lane: "codex", source: "codex-sqlite", used_pct: parsed.secondary.usedPct, window: "weekly", reset_at: isoOrNull(parsed.secondary.resetAtMs), tier: "pro", glm_peak: null, note: null });
  }
  // Guard the latent illegal state {primary:null, secondary:null}: parseCodexUsage
  // funnels it to top-level null today, but if a row-less ParsedCodex is ever
  // constructed elsewhere it must collapse to the honest invisible row, not a
  // silent zero-row append (visible-not-silent, HIMMEL-275 / CR type-design).
  if (rows.length === 0) {
    return [{ v: 1, ts, lane: "codex", source: "invisible", used_pct: null, window: null, reset_at: null, tier: null, glm_peak: null, note: "~/.codex/logs_2.sqlite unreadable" }];
  }
  return rows;
}

// Best-effort probe: read the sqlite blob (missing file -> readBlob throws or
// returns "" -> ONE invisible row + ONE stderr line, never a throw, T5), build
// the rows, append every one. All I/O injected so it is unit-testable with no
// real sqlite.
export function codexProbeAppend(readBlob: () => string, nowMs: number, append: (row: QuotaGaugeRecord) => void): void {
  let blob = "";
  try { blob = readBlob(); } catch { blob = ""; }
  const parsed = blob ? parseCodexUsage(blob) : null;
  if (parsed === null) console.error("quota-gauge-codex: ~/.codex/logs_2.sqlite unreadable or no primary/secondary used_percent — recording an invisible codex row");
  for (const row of buildCodexRows(parsed, nowMs)) append(row);
}
