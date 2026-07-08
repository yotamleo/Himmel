/**
 * Per-dataPoint shape adapters: turn ONE Google Health API dataPoint into
 * ONE luna-vitals ExtractedRow.
 *
 * Cross-point aggregation (rhr_bpm 5th-percentile derivation,
 * sleep main-session selection + stage summation) is handled in R4 — NOT here.
 */
import type { Mapping } from './table';
import { type ExtractedRow, validateRow } from '../../src/types';

// Unit transforms keyed by metric name.
// Each entry encodes one unit conversion from SCHEMA.md.
const UNIT_TRANSFORMS: Record<string, (v: number) => number> = {
  weight_kg: (v) => v / 1000,          // weightGrams → kg
  distance_km: (v) => v / 1_000_000,   // millimeters → km
  height_cm: (v) => v / 10,            // heightMillimeters → cm
  altitude_gain_km: (v) => v / 1_000_000, // gainMillimeters → km
};

/** Return the metric-object key on a dataPoint: the key that is not 'name' or 'dataSource'. */
function getFieldKey(dp: Record<string, unknown>): string | undefined {
  return Object.keys(dp).find((k) => k !== 'name' && k !== 'dataSource');
}

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function toISODate(year: number, month: number, day: number): string {
  return `${year}-${pad2(month)}-${pad2(day)}`;
}

/** Parse "7200s" → 7200 (seconds). */
function parseOffsetSeconds(offset: string): number {
  return parseInt(offset.replace('s', ''), 10);
}

/**
 * Compute the local calendar date from a UTC ISO timestamp + a UTC-offset string,
 * without relying on the host timezone. Pure date math via UTC methods.
 */
function computeLocalDate(utcISO: string, offsetStr: string): string {
  const localMs = Date.parse(utcISO) + parseOffsetSeconds(offsetStr) * 1000;
  const d = new Date(localMs);
  return toISODate(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
}

function extractDate(mapping: Mapping, fieldObj: unknown): string | undefined {
  const fo = fieldObj as any;

  if (mapping.category === 'daily') {
    const d: { year: number; month: number; day: number } | undefined = fo?.date;
    if (!d) return undefined;
    return toISODate(d.year, d.month, d.day);
  }

  if (mapping.category === 'sample') {
    const d: { year: number; month: number; day: number } | undefined =
      fo?.sampleTime?.civilTime?.date;
    if (!d) return undefined;
    return toISODate(d.year, d.month, d.day);
  }

  // interval: prefer civilEndTime.date; fallback to endTime + endUtcOffset.
  const interval = fo?.interval;
  if (!interval) return undefined;

  const civil: { year: number; month: number; day: number } | undefined =
    interval?.civilEndTime?.date;
  if (civil) return toISODate(civil.year, civil.month, civil.day);

  if (!interval.endTime || !interval.endUtcOffset) return undefined;
  return computeLocalDate(interval.endTime as string, interval.endUtcOffset as string);
}

/**
 * Extract the civil date (YYYY-MM-DD) of ONE raw dataPoint, or undefined if
 * the point lacks the expected shape. Used by the fetch layer's early-stop
 * pagination guard (which needs point dates before extractRows runs).
 */
export function pointDate(mapping: Mapping, dp: unknown): string | undefined {
  const point = dp as Record<string, unknown>;
  const fieldKey = getFieldKey(point);
  if (!fieldKey) return undefined;
  return extractDate(mapping, point[fieldKey]);
}

/** Traverse a dot-path into an object (e.g. "amountConsumed.milliliters"). */
function getByPath(obj: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((cur, key) => (cur as any)?.[key], obj);
}

function extractValue(mapping: Mapping, fieldObj: unknown): number | undefined {
  const fo = fieldObj as any;

  // duration: (endTime − startTime) in minutes, from UTC timestamps.
  if (mapping.aggregate === 'duration') {
    const interval = fo?.interval;
    if (!interval?.startTime || !interval?.endTime) return undefined;
    const diffMs =
      Date.parse(interval.endTime as string) - Date.parse(interval.startTime as string);
    return diffMs / 60_000;
  }

  // active-minutes: sum activeMinutesByActivityLevel[].activeMinutes (strings).
  if (mapping.dataTypeId === 'active-minutes') {
    const arr: unknown[] | undefined = fo?.activeMinutesByActivityLevel;
    if (!Array.isArray(arr)) return undefined;
    return arr.reduce<number>((sum, item) => sum + Number((item as any)?.activeMinutes ?? 0), 0);
  }

  // Scalar: read by dot-path, coerce strings to number, apply unit transform.
  if (!mapping.valuePath) return undefined;
  const raw = getByPath(fo, mapping.valuePath);
  if (raw === undefined || raw === null) return undefined;
  const n = Number(raw);
  if (!Number.isFinite(n)) return undefined;

  const transform = UNIT_TRANSFORMS[mapping.metric];
  return transform ? transform(n) : n;
}

/**
 * Turn every dataPoint in `response` into one ExtractedRow for the given mapping.
 * Points that lack the mapped field or produce an invalid date/value are skipped.
 *
 * Mappings R3 cannot resolve per-point (handled in R4):
 *   - aggregate === 'derive'   → rhr_bpm (5th-percentile of raw HR samples)
 *   - dataTypeId === 'sleep'   → sleep_hours / sleep_asleep_hours (main-session selection)
 *   - method === 'dailyRollUp' → rollup shape TBD; requires a different fetch method
 */
export function extractRows(
  mapping: Mapping,
  response: { dataPoints?: unknown[] },
): ExtractedRow[] {
  if (mapping.aggregate === 'derive') return []; // handled in R4
  if (mapping.dataTypeId === 'sleep') return []; // handled in R4
  if (mapping.method === 'dailyRollUp') return []; // handled in R4

  const rows: ExtractedRow[] = [];

  for (const dp of response.dataPoints ?? []) {
    const point = dp as Record<string, unknown>;
    const fieldKey = getFieldKey(point);
    if (!fieldKey) continue;

    const fieldObj = point[fieldKey];

    const date = extractDate(mapping, fieldObj);
    if (date === undefined) continue;

    const value = extractValue(mapping, fieldObj);
    if (value === undefined) continue;

    const platform =
      ((point.dataSource as any)?.platform as string | undefined) ?? 'unknown';
    const source = `google-health:${mapping.dataTypeId}:${platform}`;

    const row: ExtractedRow = { metric: mapping.metric, date, value, source };
    validateRow(row); // throws loudly on bad date / non-finite value
    rows.push(row);
  }

  return rows;
}
