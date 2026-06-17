import { fetchKpToCache } from "./fetchKp";
import { KP_CACHE } from "./kp";
import { loadSeries } from "./loadSeries";
import { correlate } from "./correlate";
import type { KpPoint, FactorPoint, SeriesPoint, Signal } from "./correlate";
import { formatSignalsNote } from "./signalsNote";
import {
  fetchFactorToCache, factorCachePath, LOCATION_FACTORS, type FactorCache, type DateRange,
} from "./fetchFactors";
import { loadLocation, resolveFactorSeries } from "./proximity";

// Kp is global + date-only (no location); pressure/pollen/aq are location factors
// resolved offline through the proximity index (M2). Kp keeps its geomagnetic-storm
// split at 5; continuous location factors use a median split (see correlate.ts).
const KP_LABEL = "Kp-index";
const KP_HIGH = 5;
const SUPPORTED_FACTORS: readonly string[] = ["kp", ...LOCATION_FACTORS];

function assertFactor(factor: string): void {
  if (!SUPPORTED_FACTORS.includes(factor)) {
    throw new Error(`unsupported factor "${factor}" — supports: ${SUPPORTED_FACTORS.join(", ")}`);
  }
}

/**
 * factors.cache — the ONLY network path (Posture A). Kp pulls the global,
 * date-only archive; location factors (pressure/pollen/aq) pull a country-level
 * GRID over `region` (LUNA_REGION_BBOX) for `dateRange` — NO operator coords ever
 * leave the box. Everything is cached locally for offline joins.
 */
// `cached` = number of records cached: Kp points (kp) or grid cells (location);
// `cells` is also set on the location branch for an unambiguous cell count.
export async function factorsCacheLogic(
  args: { factor: string; region?: string; dateRange?: DateRange; fetchImpl?: typeof fetch },
): Promise<{ factor: string; cached: number; cells?: number }> {
  assertFactor(args.factor);
  if (args.factor === "kp") {
    const cached = await fetchKpToCache({ fetchImpl: args.fetchImpl });
    return { factor: args.factor, cached };
  }
  if (!args.dateRange) {
    throw new Error(`factor "${args.factor}" requires a dateRange {start,end} (it is fetched per date over the region grid)`);
  }
  const r = await fetchFactorToCache({
    factor: args.factor, bbox: args.region, dateRange: args.dateRange, fetchImpl: args.fetchImpl,
  });
  return { factor: args.factor, cached: r.cells, cells: r.cells };
}

/** series.load — read a local (offline) health/status series by name. */
export async function seriesLoadLogic(
  args: { name: string; dir?: string },
): Promise<{ name: string; n: number; points: SeriesPoint[] }> {
  const points = await loadSeries(args.name, args.dir);
  return { name: args.name, n: points.length, points };
}

export async function loadCachedFactor(path: string = KP_CACHE): Promise<KpPoint[]> {
  const f = Bun.file(path);
  if (!(await f.exists())) {
    throw new Error(`factor cache not found at ${path} — run factors.cache first`);
  }
  return f.json();
}

export async function loadFactorCache(factor: string): Promise<FactorCache> {
  const path = factorCachePath(factor);
  const f = Bun.file(path);
  if (!(await f.exists())) {
    throw new Error(`factor cache not found at ${path} — run factors.cache({factor:"${factor}", region, dateRange}) first`);
  }
  const cache = (await f.json()) as FactorCache;
  // Validate shape on read: a truncated, hand-edited, or stale-schema cache would
  // otherwise fail far from the cause (a missing `metric` silently drops every day
  // via the undefined-value guard in resolveFactorSeries). Same fail-loud posture
  // as the fetch/parse boundary.
  if (!Array.isArray(cache.cells) || typeof cache.metric !== "string") {
    throw new Error(`factor cache at ${path} is malformed — re-run factors.cache({factor:"${factor}", region, dateRange})`);
  }
  return cache;
}

/**
 * correlate — offline join of a named series against a cached factor. Kp joins
 * the global archive directly; location factors resolve the operator's local-only
 * date×place (LUNA_LOCATION_FILE / `location`) to the nearest cached grid cell via
 * the proximity index, then run the identical date±lag join.
 */
export async function correlateLogic(
  args: { series: string; factor?: string; lag?: number; dir?: string; location?: string },
): Promise<Signal> {
  const factor = args.factor ?? "kp";
  assertFactor(factor);
  const series = await loadSeries(args.series, args.dir);
  const lag = args.lag ?? 0;
  if (factor === "kp") {
    const cached = await loadCachedFactor();
    const points: FactorPoint[] = cached.map(p => ({ date: p.date, value: p.kp }));
    return correlate(series, points, lag, { highThreshold: KP_HIGH, factorLabel: KP_LABEL, seriesName: args.series });
  }
  const cache = await loadFactorCache(factor);
  const location = await loadLocation(args.location);
  const points = resolveFactorSeries(location, cache);
  // Total proximity-join failure (location-days exist but NONE resolved to a cached
  // cell-date) is a pipeline misconfiguration — region/dateRange don't cover the
  // location file's dates — not a weak signal. Fail loud rather than degrade to a
  // meaningless n=0 (the location-path analogue of the M1 fetch 0-points guard).
  if (location.length > 0 && points.length === 0) {
    throw new Error(
      `[luna-correlate] ${factor}: none of ${location.length} location-days joined to a cached cell-date ` +
      `(cache covers ${cache.dateRange.start}..${cache.dateRange.end}) — check region/dateRange match the location dates`,
    );
  }
  // Partial drops are expected (a day at a place/date the cache doesn't cover), but
  // a large silent drop hides a shrinking cache — make the count observable.
  const dropped = location.length - points.length;
  if (dropped > 0) {
    console.error(`[luna-correlate] ${factor}: ${dropped}/${location.length} location-days had no cached cell-value (dropped from join)`);
  }
  return correlate(series, points, lag, { factorLabel: cache.label, seriesName: args.series });
}

/** signals.report — render the candidate-signal markdown note (offline). */
export async function signalsReportLogic(
  args: { series: string; factor?: string; lag?: number; dir?: string; location?: string; outPath?: string },
): Promise<{ markdown: string; outPath?: string }> {
  const sig = await correlateLogic(args);
  const markdown = formatSignalsNote([sig]);
  if (args.outPath) await Bun.write(args.outPath, markdown);
  return args.outPath ? { markdown, outPath: args.outPath } : { markdown };
}
