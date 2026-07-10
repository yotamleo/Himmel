/**
 * R4 — Day-level aggregation + derived metrics.
 *
 * aggregateRows: collapse multi-point same-day ExtractedRows into one row/date.
 * deriveRestingHeartRate: compute rhr_bpm from raw heart-rate samples (5th pctile/day).
 * deriveSleep: extract sleep_hours + sleep_in_bed_hours from sleep dataPoints.
 */
import type { Mapping } from './table';
import { type ExtractedRow, validateRow, isValidISODate } from '../../src/types';

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
  // True when this session's raw `stages` field was present but non-array (malformed).
  // The warning for this is deferred to the per-date main-session-selection loop
  // below (Fix B / HIMMEL-794 codex-adv-2): a malformed NAP alongside a clean main
  // session must not warn, since the emitted sleep_hours row never came from it.
  stagesMalformed: boolean;
};

// Internal warning shape carrying the date a warning pertains to, when one is
// known. `date` is undefined when no local calendar date could be derived at all
// (the pull-side window filter always keeps an undateable warning — see
// google-health.ts). Exported so google-health.ts can type its collected warnings.
export type SleepWarning = { date?: string; text: string };

/**
 * Derive sleep_hours and sleep_in_bed_hours from sleep dataPoints.
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
 * Emits UP TO TWO rows per date:
 *   sleep_hours        — sum of non-AWAKE stage durations in the main session, 1 decimal
 *                         (hours actually asleep). Emitted ONLY when > 0 AND the session's
 *                         stage data is not degraded (see below) — a stage-less session
 *                         (classic-era Fitbit sync, no stage breakdown) has no asleep figure
 *                         to report, so no row is emitted rather than a misleading 0.
 *   sleep_in_bed_hours — main session (end − start) in hours, 1 decimal (time in bed).
 *                         Always emitted for a valid session.
 *
 *   DEGRADED stage data: if ANY non-AWAKE stage in the main session has an unparseable
 *   start/end timestamp (Date.parse → NaN), the session is treated as DEGRADED for that
 *   date — sleep_hours is omitted regardless of what the remaining valid stages sum to
 *   (they would under-count sleep), while sleep_in_bed_hours is still emitted (derived
 *   from the session interval, not the stages) and a stderr warning is printed. Invalid
 *   AWAKE stages never enter the sum, so they do NOT trigger the degraded path.
 *
 * Returns { rows, warnings }: `rows` are the emitted ExtractedRows; `warnings` is a
 *   SleepWarning[] (`{ date?: string; text: string }`, possibly empty) of
 *   degradation/drop signals — `date` is the warning's local calendar date when one
 *   is derivable, undefined otherwise. Order is deterministic for identical input,
 *   but is NOT a single global encounter order across warning types: it is two-phase
 *   — parse-loop warnings (dropped sessions; the missing-interval path) come first
 *   in data-point order, then per-date warnings (degraded stage data; non-array
 *   stages on the MAIN session) in per-date main-session order. Each warning is
 *   ALSO printed to stderr as `[google-health] <text>` — the stderr behavior
 *   predates HIMMEL-794 and is unchanged; the returned copy is additive so `pull`
 *   can record it durably on the review artifact (window-scoped there, see
 *   google-health.ts). Five warning-producing paths, all with row emission
 *   unchanged: (1) a session dropped because its interval is missing
 *   startTime/endTime entirely (`sleep dataPoint <i> (<date>): missing interval …`,
 *   dated when an end date is still derivable from civilEndTime or
 *   endTime + endUtcOffset, `sleep dataPoint <i>: missing interval …` otherwise);
 *   (2) a session dropped because neither civilEndTime nor endUtcOffset is present
 *   (no date derivable — `sleep dataPoint <i> ending <endTime>: no civilEndTime …`);
 *   (3) a session dropped because its interval start/end is unparseable
 *   (`sleep dataPoint <i> (<date>): unparseable interval …`, undated when a garbage
 *   endTime makes the date underivable); (4) a degraded main session (see above);
 *   (5) a non-array `stages` field on the MAIN session for a date, coerced to
 *   stage-less (an absent `stages` field is the normal classic case and does NOT
 *   warn; a malformed shorter/nap session that loses main-session selection does
 *   NOT warn either — it contributes no rows, see Fix B / HIMMEL-794 codex-adv-2).
 *   Paths 1-3 (session-scoped) embed the dataPoint index in the text so distinct
 *   events never share a text — the merge CLI dedups warnings by exact text, so
 *   identical text must mean the same event (over-reporting across re-pulls with
 *   different windows is the accepted safe direction). A dataPoint with no typed
 *   payload field at all (the fieldKey lookup fails) is still skipped WITHOUT a
 *   warning — deliberate scope-out, tracked in HIMMEL-801.
 *
 * Source: 'google-health:sleep:<platform>'.
 * Each emitted row passes validateRow before being returned.
 */
export function deriveSleep(response: { dataPoints?: unknown[] }): { rows: ExtractedRow[]; warnings: SleepWarning[] } {
  const sessions: SleepSession[] = [];
  const warnings: SleepWarning[] = [];
  // Each warning is recorded in `warnings` (durable, returned to the caller) AND
  // printed to stderr with the [google-health] prefix (the pre-HIMMEL-794 operator
  // signal, kept byte-identical). The stderr line is `[google-health] ` + text —
  // `date` is carried only in the returned copy, never in the stderr line.
  const warn = (text: string, date?: string): void => {
    warnings.push({ date, text });
    console.error(`[google-health] ${text}`);
  };

  // Parse-loop (session-scoped) warning texts embed the dataPoint index so two
  // DISTINCT dropped sessions can never share a text — the merge CLI dedups
  // warnings by exact text, so identical text must mean the same event. (Across
  // re-pulls with different windows the same session may carry a different index;
  // over-reporting there is the accepted safe direction.)
  for (const [i, dp] of (response.dataPoints ?? []).entries()) {
    const point = dp as DataPoint;
    const fieldKey = Object.keys(point).find((k) => k !== 'name' && k !== 'dataSource');
    if (!fieldKey) continue;
    const fo = point[fieldKey] as any;
    const interval = fo?.interval;

    // Local end date — derived BEFORE the missing-startTime/endTime guard below, so
    // that guard's warning can carry a date when one IS derivable (e.g. startTime
    // missing but civilEndTime present). An undated warning survives EVERY pull
    // window (conservative keep), so dating it whenever possible keeps an
    // out-of-window malformed session from polluting unrelated artifacts.
    let date: string | undefined;
    const civil = interval?.civilEndTime?.date as
      | { year: number; month: number; day: number }
      | undefined;
    if (civil) {
      date = toISODate(civil.year, civil.month, civil.day);
    } else if (interval?.endTime && interval?.endUtcOffset) {
      date = computeLocalDate(interval.endTime as string, interval.endUtcOffset as string);
      // A present-but-garbage endTime yields a "NaN-NaN-NaN" date here — treat it
      // as underivable so no warning ever embeds a garbage date (the unparseable
      // guard below then uses its undated variant).
      if (!isValidISODate(date)) date = undefined;
    }

    if (!interval?.startTime || !interval?.endTime) {
      // A missing interval entirely, or an interval missing startTime/endTime — no
      // duration computable, so drop the session (no row) and warn (the fifth
      // silent-drop path of this class; HIMMEL-794 Fix D), dated when derivable.
      warn(
        date !== undefined
          ? `sleep dataPoint ${i} (${date}): missing interval startTime/endTime - session dropped`
          : `sleep dataPoint ${i}: missing interval startTime/endTime - session dropped`,
        date,
      );
      continue;
    }

    const startMs = Date.parse(interval.startTime as string);
    const endMs = Date.parse(interval.endTime as string);
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      // Unparseable interval — cannot compute a duration, so drop the session.
      // Checked before the no-date guard below: a garbage endTime alongside a
      // present endUtcOffset lands here (undated via the NaN-date guard above),
      // not in the no-civilEndTime/no-endUtcOffset text, which would be wrong.
      warn(
        date !== undefined
          ? `sleep dataPoint ${i} (${date}): unparseable interval start/end - session dropped`
          : `sleep dataPoint ${i}: unparseable interval start/end - session dropped`,
        date,
      );
      continue;
    }

    if (date === undefined) {
      // No way to derive a local end date (endTime parsed fine above, so this
      // genuinely means neither civilEndTime nor endUtcOffset was present) — drop
      // the session (no row), but record it so the loss is visible on the review
      // artifact, not just stderr.
      warn(`sleep dataPoint ${i} ending ${interval.endTime}: no civilEndTime and no endUtcOffset - session dropped`);
      continue;
    }

    const platform =
      ((point.dataSource as any)?.platform as string | undefined) ?? 'unknown';

    const rawStages = fo?.stages;
    // A present-but-non-array `stages` is malformed — coerce to stage-less ([]
    // below: sleep_in_bed_hours still emits, sleep_hours naturally does not).
    // Recorded as stagesMalformed rather than warned here: the warning fires only
    // for the MAIN session for this date, decided after main-session selection
    // below (Fix B / HIMMEL-794 codex-adv-2) — a malformed shorter/nap session
    // that loses selection contributes no rows, so nothing needs correcting. An
    // absent `stages` field is the normal classic stage-less case: no warning.
    const stagesMalformed = rawStages !== undefined && !Array.isArray(rawStages);
    const stages: SleepStage[] = Array.isArray(rawStages) ? rawStages : [];

    sessions.push({ date, durationMs: endMs - startMs, stages, platform, stagesMalformed });
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

    // sleep_in_bed_hours: total time-in-bed, 1 decimal.
    const inBedHours = Math.round((main.durationMs / 3_600_000) * 10) / 10;

    // sleep_hours: sum non-AWAKE stage durations, 1 decimal (hours actually asleep).
    // A non-AWAKE stage with an unparseable start/end timestamp marks the session's
    // stage data as DEGRADED — the remaining valid stages would under-count sleep, so
    // sleep_hours is omitted below (sleep_in_bed_hours is derived from the session
    // interval and is unaffected). Invalid AWAKE stages never enter the sum, so they
    // do not trigger the degraded path.
    let asleepMs = 0;
    let degraded = false;
    for (const stage of main.stages) {
      if (stage.type === 'AWAKE') continue;
      const sMs = Date.parse(stage.startTime);
      const eMs = Date.parse(stage.endTime);
      if (Number.isFinite(sMs) && Number.isFinite(eMs)) {
        asleepMs += eMs - sMs;
      } else {
        degraded = true;
      }
    }
    const sleepHours = Math.round((asleepMs / 3_600_000) * 10) / 10;

    const rowInBed: ExtractedRow = {
      metric: 'sleep_in_bed_hours',
      date,
      value: inBedHours,
      source,
    };
    validateRow(rowInBed);
    rows.push(rowInBed);

    if (main.stagesMalformed) {
      // Non-array `stages` field on the MAIN session for this date (Fix B /
      // HIMMEL-794 codex-adv-2) — main.stages is [] so `degraded`/`sleepHours` above
      // are trivially false/0; warn here instead, scoped to the winning session.
      warn(`sleep ${date}: non-array "stages" field - treated as stage-less (sleep_hours unavailable)`, date);
    } else if (degraded) {
      // Malformed non-AWAKE stage timestamps: the remaining valid stages would
      // under-count sleep, so omit the sleep_hours row rather than emit a misleading
      // figure. sleep_in_bed_hours above is unaffected (derived from the interval).
      warn(`sleep ${date}: malformed stage timestamps - sleep_hours omitted (degraded stage data)`, date);
    } else if (sleepHours > 0) {
      // Stage-less sessions (classic-era Fitbit) yield sleepHours === 0 — skip rather
      // than emit a misleading 0-hours-asleep row.
      const rowAsleep: ExtractedRow = { metric: 'sleep_hours', date, value: sleepHours, source };
      validateRow(rowAsleep);
      rows.push(rowAsleep);
    }
  }

  return { rows, warnings };
}
