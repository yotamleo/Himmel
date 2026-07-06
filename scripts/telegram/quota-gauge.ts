// scripts/telegram/quota-gauge.ts
// WS9 (HIMMEL-654) cross-lane quota-gauge ledger — append helper + reader
// (Task 2 adds the reader; this file ships the path resolver, the record
// schema, and the append helper).
//
// A PASSIVE observability layer: one append-only JSONL ledger keyed by
// lane, ONE read-only reader. Writers piggyback existing touchpoints; this
// module NEVER routes/arms/spawns/blocks (AC10). The ledger rests on atomic
// single-line O_APPEND (AC0 — Windows Git Bash atomicity gate PASSED 5/5).
//
// Byte-identical twin of scripts/lib/quota-gauge-ledger.sh (the bash append
// helper used by the in-hook Claude writer, Task 3): both emit the canonical
// record line in the exact QUOTA_GAUGE_FIELDS order (AC12/T22).
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

export type Lane = "glm" | "codex" | "claude" | "alibaba";

// Canonical record schema — keys in this EXACT order (the byte-identical
// contract with the bash twin). ALL keys always present; null where
// unobservable — never omit, never fabricate. The schema stays
// observation-only: no per-row TTL, no token-cost counter, no
// parallel-writer column (the atomic single-line append is the integrity
// guarantee, not a lock) (AC23/T23).
export const QUOTA_GAUGE_FIELDS = [
  "v", "ts", "lane", "source", "used_pct", "window", "reset_at", "tier", "glm_peak", "note",
] as const;

export type QuotaGaugeRecord = {
  v: 1;
  ts: string;             // ISO-UTC (e.g. 2026-07-04T12:00:00Z)
  lane: Lane;
  source: string;
  used_pct: number | null;
  window: string | null;   // "5h" | "weekly" | "long" (coarse long-window cap, sub-window unknown) | null
  reset_at: string | null; // ISO instant, or null when the host shows "unknown"
  tier: string | null;
  glm_peak: boolean | null;
  note: string | null;
};

// Ledger path resolver. $HIMMEL_QUOTA_GAUGE_LEDGER if set, else
// <HOME>/.himmel/quota-gauge.jsonl. PURE — no fs mutation; the dir is created
// on append (appendQuotaGauge), not on resolve. `env` is injectable for tests.
export function ledgerPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_QUOTA_GAUGE_LEDGER;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "quota-gauge.jsonl");
}

// Minimal JSON string escape — matches the bash twin's _qg_json_str.
function jsonStr(s: string): string {
  return '"' + s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t") + '"';
}

function jsonVal(v: number | string | boolean | null | undefined): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return String(v); // 62, not 62.0
  if (typeof v === "boolean") return v ? "true" : "false";
  return jsonStr(v);
}

// Canonical serialization — QUOTA_GAUGE_FIELDS order, byte-identical with the
// bash twin's quota_gauge_row. Exported so the byte-identical test (T22) can
// compare against bash --emit directly.
export function serializeQuotaGauge(row: QuotaGaugeRecord): string {
  const vals = [
    jsonVal(row.v),
    jsonStr(row.ts),
    jsonStr(row.lane),
    jsonStr(row.source),
    jsonVal(row.used_pct),
    jsonVal(row.window),
    jsonVal(row.reset_at),
    jsonVal(row.tier),
    jsonVal(row.glm_peak),
    jsonVal(row.note),
  ];
  const pairs = QUOTA_GAUGE_FIELDS.map((k, i) => `"${k}":${vals[i]}`);
  return "{" + pairs.join(",") + "}";
}

// Append one canonical line to the ledger (atomic single-line O_APPEND).
// Creates the parent dir on append. `path` override is for tests; real
// callers resolve via ledgerPath().
export function appendQuotaGauge(row: QuotaGaugeRecord, path?: string): void {
  const p = path ?? ledgerPath();
  const dir = dirname(p);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  appendFileSync(p, serializeQuotaGauge(row) + "\n", "utf8");
}

// ── Task 2: the single reader (D10) ─────────────────────────────────────────
// Freshness budget per lane (seconds): a row older than its lane's budget is
// stale. GLM re-queries on a ~5h cycle but is polled per-dispatch (2min); Codex
// is a rare piggyback probe (weekly window → 1h); Claude (budget 0) is the
// "dimly observed" lane — a threshold trip writes the ACTUAL %, but with budget
// 0 it is never fresh unless a trip fired at `nowMs`, so it reads UNKNOWN
// between trips (dim-lane honesty, never a fabricated number).
export const LANE_BUDGET_S: Record<Lane, number> = { glm: 120, codex: 3600, claude: 0, alibaba: 3600 };
export const QUOTA_GAUGE_LOOKBACK_N = 500;
const LANES: Lane[] = ["glm", "codex", "claude", "alibaba"];

// `known` iff the latest row for the lane is VISIBLE (used_pct !== null) AND
// fresh; otherwise `unknown` (no row / invisible / stale). `row` still carries
// the last-known reading even when unknown-because-stale, so a consumer can
// show it as "last seen" — `fresh`/`status` gate whether to TRUST it.
export type LaneStatus = { lane: Lane; row: QuotaGaugeRecord | null; fresh: boolean; status: "known" | "unknown" };

function laneVerdict(lane: Lane, row: QuotaGaugeRecord, nowMs: number): LaneStatus {
  // Invisible (null used_pct) → unknown regardless of age (F10): an invisible
  // latest reading is NOT overridden by an earlier real one.
  if (row.used_pct === null || row.used_pct === undefined) return { lane, row, fresh: false, status: "unknown" };
  const ageS = (nowMs - Date.parse(row.ts)) / 1000;
  const fresh = ageS <= LANE_BUDGET_S[lane];
  return { lane, row, fresh, status: fresh ? "known" : "unknown" };
}

// Latest-per-lane over the append-only ledger, scanning NEWEST→oldest. A lane
// with no row (or not found within `lookbackN` scanned rows) is UNKNOWN with a
// null row — never a fabricated 0/100. The bounded look-back keeps an absent
// lane from forcing a full-file walk and stops a GLM burst from evicting a
// still-fresh row of another lane (both lanes are found before the bound bites).
export function quotaGaugeRead(p: { path?: string; nowMs?: number; lookbackN?: number } = {}): Record<Lane, LaneStatus> {
  const path = p.path ?? ledgerPath();
  const nowMs = p.nowMs ?? Date.now();
  const lookbackN = p.lookbackN ?? QUOTA_GAUGE_LOOKBACK_N;
  const result: Record<Lane, LaneStatus> = {
    glm: { lane: "glm", row: null, fresh: false, status: "unknown" },
    codex: { lane: "codex", row: null, fresh: false, status: "unknown" },
    claude: { lane: "claude", row: null, fresh: false, status: "unknown" },
    alibaba: { lane: "alibaba", row: null, fresh: false, status: "unknown" },
  };
  if (!existsSync(path)) return result;

  const lines = readFileSync(path, "utf8").split("\n");
  const found = new Set<Lane>();
  let visited = 0;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (found.size === LANES.length || visited >= lookbackN) break;
    const line = lines[i];
    if (line.trim() === "") continue;              // trailing newline / blank — not a row
    visited++;
    let row: QuotaGaugeRecord;
    try { row = JSON.parse(line) as QuotaGaugeRecord; } catch { continue; }  // truncated/garbled last line skipped (T15)
    const lane = (row as { lane?: unknown }).lane;
    if (lane !== "glm" && lane !== "codex" && lane !== "claude" && lane !== "alibaba") continue;
    if (found.has(lane)) continue;                 // an older row for a lane already resolved by its newest
    found.add(lane);
    result[lane] = laneVerdict(lane, row, nowMs);
  }
  return result;
}

// ── Task 5: GLM row-builder + peak-band advisory (pure) ──────────────────────
// z.ai bills the GLM 5h cycle at a 3× multiplier during a fixed daily window
// (14:00-18:00 UTC+8, z.ai-fixed, does NOT track local DST). `glm_peak` is an
// advisory COST flag on GLM rows — the reader/consumer may defer bulk fanout;
// it never gates a dispatch (passivity). Single source for the window bounds.
export const GLM_PEAK_START_H = 14;
export const GLM_PEAK_END_H = 18;
export const GLM_PEAK_TZ_OFFSET_H = 8;

// True iff `nowMs`, converted to UTC+8, falls in [14:00, 18:00). Pure — derives
// the UTC+8 hour from the absolute instant, never reads a lane/arm/dispatch.
export function isGlmPeak(nowMs: number): boolean {
  const utc8Hour = Math.floor(((nowMs / 3600000) + GLM_PEAK_TZ_OFFSET_H) % 24 + 24) % 24;
  return utc8Hour >= GLM_PEAK_START_H && utc8Hour < GLM_PEAK_END_H;
}

// Map the GLM monitor-endpoint reading to a canonical row. `null` (usage
// invisible) is visible-not-silent: an `invisible`-source row with null fields,
// NEVER a fabricated number (HIMMEL-275). `glm_peak` is stamped in both cases.
export function buildGlmRow(reading: { percentage: number; nextResetTime: number; level?: string } | null, nowMs: number): QuotaGaugeRecord {
  const peak = isGlmPeak(nowMs);
  if (reading === null) {
    return { v: 1, ts: new Date(nowMs).toISOString(), lane: "glm", source: "invisible", used_pct: null, window: null, reset_at: null, tier: null, glm_peak: peak, note: "usage invisible (monitor endpoint unavailable)" };
  }
  return { v: 1, ts: new Date(nowMs).toISOString(), lane: "glm", source: "monitor-endpoint", used_pct: reading.percentage, window: "5h", reset_at: new Date(reading.nextResetTime).toISOString(), tier: reading.level ?? null, glm_peak: peak, note: null };
}
