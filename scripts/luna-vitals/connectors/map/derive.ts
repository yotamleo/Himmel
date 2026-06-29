/**
 * R4 — Day-level aggregation + derived metrics.
 *
 * aggregateRows: collapse multi-point same-day ExtractedRows into one row/date.
 * deriveRestingHeartRate: compute rhr_bpm from raw heart-rate samples (5th pctile/day).
 * deriveSleep: extract sleep_hours + sleep_asleep_hours from sleep dataPoints.
 */
import type { Mapping } from './table';
import { type ExtractedRow, validateRow } from '../../src/types';

// ── shared helpers ────────────────────────────────────────────────────────────

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function toISODate(year: number, month: number, day: number): string {
  return `${year}-${pad2(month)}-${pad2(day)}`;
}

function parseOffsetSeconds(offset: string): number {
  return parseInt(offset.replace('s', ''), 10);
}

/**
 * Compute the local calendar date from a UTC ISO timestamp + UTC-offset string.
 * Pure date math via UTC methods — no host-TZ dependence.
 */
function computeLocalDate(utcISO: string, offsetStr: string): string {
  const localMs = Date.parse(utcISO) + parseOffsetSeconds(offsetStr) * 1000;
  const d = new Date(localMs);
  return toISODate(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
}

/**
 * nth-percentile via linear interpolation (same as NumPy's default / Excel PERCENTILE.INC).
 * Expects `sorted` to already be sorted ascending. Does NOT mutate the input.
 */
function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  if (sorted.length === 1) return sorted[0];
  const h = (sorted.length - 1) * (p / 100);
  const lo = Math.floor(h);
  const hi = Math.ceil(h);
  return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo]);
}

// ── aggregateRows ─────────────────────────────────────────────────────────────

/**
 * Metrics whose summed value should be rounded to an integer.
 * These represent discrete counts or whole-minute durations.
 */
const INTEGER_SUM_METRICS = new Set([
  'steps',
  'active_minutes',
  'active_zone_minutes',
  'sedentary_minutes',
  'swim_strokes',
  'exercise_minutes',
  'active_energy_kcal',
  'hydration_ml',
]);

/**
 * Metrics whose summed value should keep 3 decimal places (km-scale distances).
 */
const KM_SUM_METRICS = new Set(['distance_km', 'altitude_gain_km']);

/**
 * Round a summed value according to metric-specific precision rules.
 *   - integer metrics: Math.round
 *   - km metrics: 3 decimal places
 *   - everything else: 3 decimal places (safe default for physiological values)
 */
function roundSum(metric: string, value: number): number {
  if (INTEGER_SUM_METRICS.has(metric)) return Math.round(value);
  if (KM_SUM_METRICS.has(metric)) return Math.round(value * 1000) / 1000;
  return Math.round(value * 1000) / 1000;
}

/**
 * Collapse multi-point same-day rows into one row per date per mapping.aggregate:
 *
 *   'none'     — pass through as-is (daily aggregates from Fitbit/Samsung are already 1/day).
 *   'sum'      — sum values; round per INTEGER_SUM_METRICS / KM_SUM_METRICS rules above.
 *   'duration' — same as 'sum': per-point durations were already computed in extractRows;
 *                aggregate by summing all durations for the day.
 *   'mean'     — arithmetic mean; 3 decimal places.
 *   'last'     — keep the row whose source string is lexicographically latest (tiebreak
 *                documented: same-date weight/height/body-fat samples share a source, so
 *                `>=` in the reduce keeps the last row in input order, which matches the
 *                API's chronological ordering for same-source, same-platform readings).
 *   'derive'   — rows with aggregate='derive' should not reach aggregateRows (handled by
 *                deriveRestingHeartRate); passed through as-is if they somehow arrive.
 *
 * Source on the aggregated row: first/representative group[0].source. If mixed sources
 * (unusual — same dataTypeId can come from multiple platforms), the first is kept. The
 * dataTypeId component is preserved in all `google-health:<id>:<platform>` source strings.
 *
 * All emitted rows are validated via validateRow before returning.
 */
export function aggregateRows(mapping: Mapping, rows: ExtractedRow[]): ExtractedRow[] {
  if (rows.length === 0) return [];
  if (mapping.aggregate === 'none') return rows;

  // Group rows by date.
  const groups = new Map<string, ExtractedRow[]>();
  for (const row of rows) {
    let bucket = groups.get(row.date);
    if (!bucket) {
      bucket = [];
      groups.set(row.date, bucket);
    }
    bucket.push(row);
  }

  const result: ExtractedRow[] = [];

  for (const [date, group] of groups) {
    let out: ExtractedRow;

    if (mapping.aggregate === 'sum' || mapping.aggregate === 'duration') {
      const total = group.reduce((acc, r) => acc + r.value, 0);
      const value = roundSum(mapping.metric, total);
      out = { metric: group[0].metric, date, value, source: group[0].source };

    } else if (mapping.aggregate === 'mean') {
      const avg = group.reduce((acc, r) => acc + r.value, 0) / group.length;
      const value = Math.round(avg * 1000) / 1000;
      out = { metric: group[0].metric, date, value, source: group[0].source };

    } else if (mapping.aggregate === 'last') {
      // Tiebreak: the row with the lexicographically latest source wins.
      // When sources are equal (same platform), the last row in input order wins
      // (>= keeps replacing), assuming the API returns readings chronologically.
      const kept = group.reduce((best, r) => (r.source >= best.source ? r : best));
      out = { metric: kept.metric, date: kept.date, value: kept.value, source: kept.source };

    } else {
      // 'derive' — should not arrive here; pass through the first row.
      out = group[0];
    }

    validateRow(out);
    result.push(out);
  }

  return result;
}

// ── deriveRestingHeartRate ────────────────────────────────────────────────────

type DataPoint = Record<string, unknown>;

/**
 * Derive rhr_bpm from raw heart-rate dataPoints.
 *
 * Algorithm: per civil day, compute the 5th percentile of all bpm samples
 * (linear interpolation; see `percentile()`), then round to the nearest integer.
 *
 * Rationale: resting heart rate is measured during quiet periods; a spot-sample
 * HR feed from Samsung Health captures both resting and activity readings. The
 * 5th percentile filters out activity spikes while being more robust than a bare
 * minimum (which is vulnerable to artefact readings). This mirrors the estimate
 * that Fitbit's stopped daily-resting-heart-rate aggregate used to provide.
 *
 * Date extraction: sampleTime.civilTime.date {year,month,day} (category: sample).
 * Source: 'google-health:heart-rate:<platform>'.
 */
export function deriveRestingHeartRate(response: { dataPoints?: unknown[] }): ExtractedRow[] {
  const byDate = new Map<string, { bpms: number[]; platform: string }>();

  for (const dp of response.dataPoints ?? []) {
    const point = dp as DataPoint;
    const fieldKey = Object.keys(point).find((k) => k !== 'name' && k !== 'dataSource');
    if (!fieldKey) continue;
    const fo = point[fieldKey] as any;

    const civilDate = fo?.sampleTime?.civilTime?.date as
      | { year: number; month: number; day: number }
      | undefined;
    if (!civilDate) continue;
    const date = toISODate(civilDate.year, civilDate.month, civilDate.day);

    const bpm = Number(fo?.beatsPerMinute);
    if (!Number.isFinite(bpm)) continue;

    const platform =
      ((point.dataSource as any)?.platform as string | undefined) ?? 'unknown';

    let bucket = byDate.get(date);
    if (!bucket) {
      bucket = { bpms: [], platform };
      byDate.set(date, bucket);
    }
    bucket.bpms.push(bpm);
  }

  const rows: ExtractedRow[] = [];

  for (const [date, { bpms, platform }] of byDate) {
    const sorted = [...bpms].sort((a, b) => a - b);
    const value = Math.round(percentile(sorted, 5));
    const source = `google-health:heart-rate:${platform}`;
    const row: ExtractedRow = { metric: 'rhr_bpm', date, value, source };
    validateRow(row);
    rows.push(row);
  }

  return rows;
}

// ── deriveSleep ───────────────────────────────────────────────────────────────

type SleepStage = { startTime: string; endTime: string; type: string };

type SleepSession = {
  date: string;
  durationMs: number;
  stages: SleepStage[];
  platform: string;
};

/**
 * Derive sleep_hours and sleep_asleep_hours from sleep dataPoints.
 *
 * Session date: local calendar date of the interval's END.
 *   Prefer interval.civilEndTime.date; fall back to endTime + endUtcOffset.
 *   A midnight-crossing session (e.g. 22:30 local → 07:30 local next day) is
 *   assigned to the END date, so "I slept on the night of Jun 26" → date Jun 27.
 *
 * Main session: the LONGEST sleep interval ending on a given date.
 *   Naps (shorter sessions ending the same date) are intentionally excluded from
 *   the main-session values — they represent separate rest periods and stacking
 *   them would overstate a single night's time-in-bed.
 *
 * Emits TWO rows per date:
 *   sleep_hours       — main session (end − start) in hours, 1 decimal (time in bed).
 *   sleep_asleep_hours — sum of non-AWAKE stage durations in the main session, 1 decimal.
 *
 * Source: 'google-health:sleep:<platform>'.
 * Both rows pass validateRow before being returned.
 */
export function deriveSleep(response: { dataPoints?: unknown[] }): ExtractedRow[] {
  const sessions: SleepSession[] = [];

  for (const dp of response.dataPoints ?? []) {
    const point = dp as DataPoint;
    const fieldKey = Object.keys(point).find((k) => k !== 'name' && k !== 'dataSource');
    if (!fieldKey) continue;
    const fo = point[fieldKey] as any;
    const interval = fo?.interval;
    if (!interval?.startTime || !interval?.endTime) continue;

    // Local end date.
    let date: string | undefined;
    const civil = interval?.civilEndTime?.date as
      | { year: number; month: number; day: number }
      | undefined;
    if (civil) {
      date = toISODate(civil.year, civil.month, civil.day);
    } else if (interval.endUtcOffset) {
      date = computeLocalDate(interval.endTime as string, interval.endUtcOffset as string);
    } else {
      continue;
    }

    const startMs = Date.parse(interval.startTime as string);
    const endMs = Date.parse(interval.endTime as string);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) continue;

    const platform =
      ((point.dataSource as any)?.platform as string | undefined) ?? 'unknown';

    const stages: SleepStage[] = Array.isArray(fo?.stages) ? fo.stages : [];

    sessions.push({ date, durationMs: endMs - startMs, stages, platform });
  }

  // Pick the main (longest) session per date.
  const byDate = new Map<string, SleepSession>();
  for (const session of sessions) {
    const existing = byDate.get(session.date);
    if (!existing || session.durationMs > existing.durationMs) {
      byDate.set(session.date, session);
    }
  }

  const rows: ExtractedRow[] = [];

  for (const [date, main] of byDate) {
    const source = `google-health:sleep:${main.platform}`;

    // sleep_hours: total time-in-bed, 1 decimal.
    const sleepHours = Math.round((main.durationMs / 3_600_000) * 10) / 10;

    // sleep_asleep_hours: sum non-AWAKE stage durations, 1 decimal.
    let asleepMs = 0;
    for (const stage of main.stages) {
      if (stage.type === 'AWAKE') continue;
      const sMs = Date.parse(stage.startTime);
      const eMs = Date.parse(stage.endTime);
      if (Number.isFinite(sMs) && Number.isFinite(eMs)) {
        asleepMs += eMs - sMs;
      }
    }
    const sleepAsleepHours = Math.round((asleepMs / 3_600_000) * 10) / 10;

    const rowHours: ExtractedRow = { metric: 'sleep_hours', date, value: sleepHours, source };
    const rowAsleep: ExtractedRow = {
      metric: 'sleep_asleep_hours',
      date,
      value: sleepAsleepHours,
      source,
    };

    validateRow(rowHours);
    validateRow(rowAsleep);

    rows.push(rowHours, rowAsleep);
  }

  return rows;
}
