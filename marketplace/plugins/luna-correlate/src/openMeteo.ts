// Open-Meteo response adapter (M2). Mirrors the M1 GFZ adapter pattern: a pure
// parser over the API's `hourly` arrays → per-day aggregates, so the fetcher and
// the offline proximity index both join on calendar dates. No PHI, no location
// here — this only reshapes a fetched public-dataset response.

export type DailyAgg = { date: string; mean: number; min: number; max: number };

const ISO = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Group hourly samples by calendar day (the UTC date sliced from each ISO
 * timestamp — the fetcher requests `timezone=UTC`) and reduce to per-day
 * mean/min/max. `null`/`NaN` samples are skipped (Open-Meteo emits `null` for
 * gaps); a day with no valid samples is dropped rather than emitting NaN.
 * Output is sorted ascending by date so the series joins deterministically.
 */
export function aggregateHourly(time: string[], values: (number | null)[]): DailyAgg[] {
  if (time.length !== values.length) {
    throw new Error(
      `[luna-correlate] open-meteo hourly arrays misaligned: ${time.length} times vs ${values.length} values`,
    );
  }
  const byDate = new Map<string, number[]>();
  for (let i = 0; i < time.length; i++) {
    const v = values[i];
    if (v === null || v === undefined || Number.isNaN(v)) continue;
    const date = time[i].slice(0, 10);
    // The downstream join is an exact YYYY-MM-DD string match against strictly
    // ISO-validated series/location dates, so a non-ISO date here would silently
    // never join. The live path requests timezone=UTC (ISO timestamps), but guard
    // the exported function against any other shape (same rationale as series.ts).
    if (!ISO.test(date)) {
      throw new Error(`[luna-correlate] open-meteo hourly timestamp is not ISO YYYY-MM-DD-prefixed: "${time[i]}"`);
    }
    let bucket = byDate.get(date);
    if (!bucket) { bucket = []; byDate.set(date, bucket); }
    bucket.push(v);
  }
  return [...byDate.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([date, vs]) => ({
      date,
      mean: vs.reduce((s, x) => s + x, 0) / vs.length,
      min: Math.min(...vs),
      max: Math.max(...vs),
    }));
}

/**
 * Parse an Open-Meteo JSON response, aggregating `hourly.<field>` to daily
 * values. Fails loudly if the expected arrays are absent — caching an empty
 * series would silently degrade every later correlation to a meaningless n=0
 * (same fail-loud rationale as the M1 Kp parser).
 */
export function parseOpenMeteoHourly(json: unknown, field: string): DailyAgg[] {
  const hourly = (json as { hourly?: Record<string, unknown> } | null)?.hourly;
  const time = hourly?.time;
  if (!Array.isArray(time)) {
    throw new Error("[luna-correlate] open-meteo response missing hourly.time array");
  }
  const values = hourly?.[field];
  if (!Array.isArray(values)) {
    throw new Error(`[luna-correlate] open-meteo response missing hourly.${field} array`);
  }
  return aggregateHourly(time as string[], values as (number | null)[]);
}
