import { join } from "path";
import type { KpPoint } from "./correlate";

// Resolve the cache against this module's dir (not cwd) so the cache location
// is stable no matter where the MCP server / CLI is launched from (#541 nit).
export const KP_CACHE = join(import.meta.dir, "..", "cache", "kp.json");

/**
 * Simplified fixture format: `YYYY-MM-DD kp1 kp2 ...` (date in one column).
 * Daily-max across the numeric columns. Kept for the M0 fixtures + tests.
 */
export function parseKpText(text: string): KpPoint[] {
  return text.split("\n").map(l => l.trim()).filter(l => Boolean(l) && !l.startsWith("#")).flatMap(line => {
    const cols = line.split(/\s+/);
    const date = cols[0];
    const nums = cols.slice(1).map(Number).filter(n => !Number.isNaN(n));
    if (!nums.length) return [];
    return [{ date, kp: Math.max(...nums) }];
  });
}

/**
 * Real GFZ archive format (Kp_ap_Ap_SN_F107_since_1932.txt): whitespace-separated
 * fixed columns, date split into `YYYY MM DD`, then Kp1..Kp8 at cols 7..14.
 * Missing Kp is the -1.000 sentinel. Daily-max over the valid (>= 0) Kp values;
 * rows with no valid Kp are skipped.
 */
export function parseKpGfz(text: string): KpPoint[] {
  return text.split("\n").map(l => l.trim()).filter(l => Boolean(l) && !l.startsWith("#")).flatMap(line => {
    const cols = line.split(/\s+/);
    if (cols.length < 15) return [];
    // Zero-pad month/day so the date is ISO even if the archive ever emits
    // unpadded components (the live file is fixed-width padded, but be robust).
    const date = `${cols[0]}-${cols[1].padStart(2, "0")}-${cols[2].padStart(2, "0")}`;
    const kps = cols.slice(7, 15).map(Number).filter(n => !Number.isNaN(n) && n >= 0);
    if (!kps.length) return [];
    return [{ date, kp: Math.max(...kps) }];
  });
}

/**
 * Detect the format from the first data row and dispatch: a hyphenated ISO date
 * in column 0 (`2026-05-01`) is the simplified fixture format; otherwise the
 * real GFZ archive format (date split into separate `YYYY MM DD` columns).
 */
export function parseKpAuto(text: string): KpPoint[] {
  const first = text.split("\n").map(l => l.trim()).find(l => Boolean(l) && !l.startsWith("#"));
  if (first && /^\d{4}-\d{2}-\d{2}$/.test(first.split(/\s+/)[0])) return parseKpText(text);
  return parseKpGfz(text);
}
