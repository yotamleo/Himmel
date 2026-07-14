// HIMMEL-1000 - real per-bank quota readers for the flow exporter.
// Pure readers over local files (exporter charter: no writes, no network).
// Every reading is gated on a provably-LIVE window: resets_at parseable AND
// in the future (HIMMEL-920 guard precedent) - an expired window means the
// bank has reset since the value was written, so emitting it would fabricate.
import { existsSync, readFileSync, readdirSync, openSync, readSync, closeSync, fstatSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { quotaGaugeRead } from "../telegram/quota-gauge";

export const BANK_IDS = ["claude", "codex", "glm"] as const;
export type BankId = (typeof BANK_IDS)[number];
export type BankReading = { window: string; usedPct: number };
export type BankResult = { readings: BankReading[]; omitReason: string | null };

export function windowLabel(minutes: number): string {
  if (minutes === 300) return "5h";
  if (minutes === 10080) return "weekly";
  if (minutes === 43200) return "monthly";
  return `${minutes}m`;
}

// resets_at appears as epoch-seconds NUMBER (codex rollout), epoch-seconds
// STRING (claude statusline cache), or ISO (glm ledger rows). Null = cannot
// be tied to a window, so the caller must treat the value as unusable.
export function parseResetsAtMs(v: unknown): number | null {
  if (typeof v === "number" && Number.isFinite(v) && v > 0) return v * 1000;
  if (typeof v === "string") {
    const s = v.trim();
    if (/^[0-9]+$/.test(s)) return Number(s) * 1000;
    const ms = Date.parse(s);
    if (Number.isFinite(ms)) return ms;
  }
  return null;
}

function validPct(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 100;
}

// Must resolve the SAME file the statusline producer writes and the
// HIMMEL-920 guard reads: ${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}.
// POSIX keeps the literal /tmp (os.tmpdir() is /var/folders/... on macOS and
// honors $TMPDIR on Linux - a different file than the bash producer's target);
// Windows MSYS /tmp == os.tmpdir() (cygpath-verified), where a literal /tmp
// would NOT resolve from a Bun process.
export function defaultClaudeCachePath(env: Record<string, string | undefined>, platform: NodeJS.Platform): string {
  const override = env.CLAUDE_USAGE_CACHE?.trim();
  if (override) return override;
  return platform === "win32"
    ? join(tmpdir(), "claude", "statusline-usage-cache.json")
    : "/tmp/claude/statusline-usage-cache.json";
}

export function readClaudeBank(cachePath: string, nowMs: number): BankResult {
  if (!existsSync(cachePath)) return { readings: [], omitReason: "statusline cache not found" };
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(readFileSync(cachePath, "utf8")) as Record<string, unknown>;
    if (!parsed || typeof parsed !== "object") throw new Error("not an object");
  } catch {
    return { readings: [], omitReason: "statusline cache unparseable" };
  }
  const readings: BankReading[] = [];
  const windows: Array<[key: string, label: string]> = [["five_hour", "5h"], ["seven_day", "weekly"]];
  for (const [key, label] of windows) {
    const win = parsed[key];
    if (!win || typeof win !== "object") continue;
    const { utilization, resets_at } = win as Record<string, unknown>;
    const resetsMs = parseResetsAtMs(resets_at);
    if (!validPct(utilization) || resetsMs === null || resetsMs <= nowMs) continue;
    readings.push({ window: label, usedPct: utilization });
  }
  return { readings, omitReason: readings.length ? null : "no live window in statusline cache" };
}
const CODEX_TAIL_BYTES = 256 * 1024;
const CODEX_MAX_FILES = 5;

function listNewestRollouts(sessionsDir: string, cap: number): string[] {
  // <sessionsDir>/YYYY/MM/DD/rollout-*.jsonl: names sort chronologically,
  // so reverse-lexicographic traversal is newest-first with zero stat calls.
  const out: string[] = [];
  const dirsDesc = (p: string): string[] => {
    try {
      return readdirSync(p).sort().reverse();
    } catch {
      return [];
    }
  };
  for (const y of dirsDesc(sessionsDir)) {
    for (const m of dirsDesc(join(sessionsDir, y))) {
      for (const d of dirsDesc(join(sessionsDir, y, m))) {
        for (const f of dirsDesc(join(sessionsDir, y, m, d))) {
          if (!f.startsWith("rollout-") || !f.endsWith(".jsonl")) continue;
          out.push(join(sessionsDir, y, m, d, f));
          if (out.length >= cap) return out;
        }
      }
    }
  }
  return out;
}

function readTail(path: string, maxBytes: number): { text: string; truncated: boolean } | null {
  try {
    const fd = openSync(path, "r");
    try {
      const size = fstatSync(fd).size;
      const len = Math.min(size, maxBytes);
      const buf = Buffer.alloc(len);
      readSync(fd, buf, 0, len, size - len);
      return { text: buf.toString("utf8"), truncated: size > len };
    } finally {
      closeSync(fd);
    }
  } catch {
    return null;
  }
}

type CodexLimit = { used_percent?: unknown; window_minutes?: unknown; resets_at?: unknown };

function codexReadingsFromLine(line: string, nowMs: number): BankReading[] | null {
  let row: { payload?: { rate_limits?: { primary?: CodexLimit | null; secondary?: CodexLimit | null } } };
  try {
    row = JSON.parse(line);
  } catch {
    return null;
  }
  const rl = row?.payload?.rate_limits;
  if (!rl || typeof rl !== "object") return null;
  const readings: BankReading[] = [];
  const seen = new Set<string>();
  for (const limit of [rl.primary, rl.secondary]) {
    if (!limit || typeof limit !== "object") continue;
    const { used_percent, window_minutes, resets_at } = limit;
    if (typeof used_percent !== "number" || !Number.isFinite(used_percent)) continue;
    if (typeof window_minutes !== "number" || !Number.isFinite(window_minutes) || window_minutes <= 0) continue;
    const resetsMs = parseResetsAtMs(resets_at);
    if (resetsMs === null || resetsMs <= nowMs) continue;
    const window = windowLabel(window_minutes);
    if (seen.has(window)) continue;
    seen.add(window);
    // used_percent counts USED — live-verified (HIMMEL-1000): within one
    // dispatch session it rose 15.0 -> 19.0 while the session consumed
    // ~185k tokens, and 15 used matches the operator's "85% remaining"
    // reading at that session's start. (The older "counts REMAINING" ops
    // note described a different display surface.) Emit verbatim, clamped.
    readings.push({ window, usedPct: Math.min(100, Math.max(0, used_percent)) });
  }
  return readings.length ? readings : null;
}

function scanLinesForCodexReadings(text: string, nowMs: number): BankReading[] | null {
  const lines = text.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line.includes('"rate_limits"')) continue;
    const readings = codexReadingsFromLine(line, nowMs);
    if (readings) return readings;
  }
  return null;
}

export function readCodexBank(sessionsDir: string, nowMs: number): BankResult {
  if (!existsSync(sessionsDir)) return { readings: [], omitReason: "codex sessions dir not found" };
  for (const file of listNewestRollouts(sessionsDir, CODEX_MAX_FILES)) {
    const tail = readTail(file, CODEX_TAIL_BYTES);
    if (tail === null) continue;
    let readings = scanLinesForCodexReadings(tail.text, nowMs);
    if (!readings && tail.truncated) {
      // Newest-row fidelity (spec: "the newest rollout row"): a truncated tail
      // with no usable row must widen to the WHOLE file before falling back to
      // an older, staler file.
      try {
        readings = scanLinesForCodexReadings(readFileSync(file, "utf8"), nowMs);
      } catch {
        readings = null;
      }
    }
    if (readings) return { readings, omitReason: null };
  }
  return { readings: [], omitReason: "no live rate_limits row in recent rollouts" };
}

export function readGlmBank(ledgerPath: string, nowMs: number): BankResult {
  const omit = (): BankResult => ({ readings: [], omitReason: "no live glm row in quota-gauge ledger" });
  let row;
  try {
    row = quotaGaugeRead({ path: ledgerPath, nowMs }).glm.row;
  } catch {
    return omit();
  }
  if (!row || !validPct(row.used_pct)) return omit();
  const resetsMs = parseResetsAtMs(row.reset_at);
  if (resetsMs === null || resetsMs <= nowMs) return omit();
  return { readings: [{ window: row.window ?? "5h", usedPct: row.used_pct }], omitReason: null };
}

export type LaneQuotaTargets = { withBank: Array<{ lane: string; bank: BankId }>; without: string[] };

export function readLaneQuotaTargets(lanesPath: string): LaneQuotaTargets {
  const out: LaneQuotaTargets = { withBank: [], without: [] };
  if (!existsSync(lanesPath)) return out;
  let registry: { lanes?: Array<{ id?: unknown; quota?: { bank?: unknown } }> };
  try {
    registry = JSON.parse(readFileSync(lanesPath, "utf8"));
  } catch {
    return out;
  }
  for (const lane of registry?.lanes ?? []) {
    if (typeof lane?.id !== "string" || !lane.id) continue;
    const bank = lane.quota?.bank;
    if (typeof bank === "string" && (BANK_IDS as readonly string[]).includes(bank)) {
      out.withBank.push({ lane: lane.id, bank: bank as BankId });
    } else {
      out.without.push(lane.id);
    }
  }
  return out;
}
