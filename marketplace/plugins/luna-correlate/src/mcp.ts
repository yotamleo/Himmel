import { fetchKpToCache } from "./fetchKp";
import { KP_CACHE, type KpPoint } from "./kp";
import { loadSeries } from "./loadSeries";
import { correlate } from "./correlate";
import type { FactorPoint, SeriesPoint, Signal } from "./correlate";
import { formatSignalsNote } from "./signalsNote";
import {
  fetchFactorToCache, factorCachePath, LOCATION_FACTORS, type FactorCache, type DateRange,
} from "./fetchFactors";
import { loadLocation, resolveFactorSeries } from "./proximity";
import { splitEra } from "./era";
import { lunarPhaseSeries } from "./lunar";
import { daylightSeries, bboxCentroidLat } from "./daylight";
import { analyze, type SeriesSpec, type FactorSpec } from "./analyze";
import { formatDashboard, dashboardJson } from "./dashboardNote";
import { join } from "path";

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

const DEFAULT_SERIES = ["sleep_hours", "rhr_bpm", "hrv_ms"];
const DEFAULT_FACTORS = ["kp", "lunar_phase", "daylight"];
const ERA_SPLIT = new Set(["sleep_hours", "rhr_bpm"]);

export function resolveSignalsDir(dir?: string): string {
  if (dir) return dir;
  const env = process.env.LUNA_SIGNALS_DIR;
  if (env) return env;
  throw new Error("signals dir unset — pass outDir or set LUNA_SIGNALS_DIR (e.g. luna-medic 60-Signals/)");
}

async function buildSeriesSpecs(names: string[], dir?: string): Promise<SeriesSpec[]> {
  const out: SeriesSpec[] = [];
  for (const name of names) {
    const points = await loadSeries(name, dir);
    if (points.length === 0) throw new Error(`[luna-correlate] series "${name}" loaded 0 points — empty CSV cannot contribute to the dashboard`);
    if (ERA_SPLIT.has(name)) out.push(...splitEra(name, points));
    else out.push({ name, points });
  }
  return out;
}

async function buildFactorSpecs(
  names: string[], allDates: string[], region?: string, location?: string,
): Promise<FactorSpec[]> {
  const out: FactorSpec[] = [];
  for (const f of names) {
    if (f === "kp") {
      const cached = await loadCachedFactor();
      out.push({
        name: f, label: KP_LABEL, highThreshold: KP_HIGH,
        points: cached.map(p => ({ date: p.date, value: p.kp })),
      });
    } else if (f === "lunar_phase") {
      out.push({ name: f, label: "lunar illumination (0=new,1=full)", points: lunarPhaseSeries(allDates) });
    } else if (f === "daylight") {
      const bbox = region ?? process.env.LUNA_REGION_BBOX;
      if (!bbox) throw new Error('region unset — pass region or set LUNA_REGION_BBOX="lat_min,lon_min,lat_max,lon_max"');
      out.push({
        name: f, label: "daylight (hours, region-centroid lat)",
        points: daylightSeries(allDates, bboxCentroidLat(bbox)),
      });
    } else {
      if (!LOCATION_FACTORS.includes(f)) {
        throw new Error(`[luna-correlate] unsupported factor "${f}" — supported: kp, lunar_phase, daylight, ${LOCATION_FACTORS.join(", ")}`);
      }
      // location factor (pressure/aq/pollen) — cached grid + proximity join
      const cache = await loadFactorCache(f);
      const loc = await loadLocation(location);
      const points = resolveFactorSeries(loc, cache);
      if (loc.length > 0 && points.length === 0) {
        throw new Error(
          `[luna-correlate] ${f}: none of ${loc.length} location-days joined to a cached cell-date ` +
          `(cache covers ${cache.dateRange.start}..${cache.dateRange.end})`,
        );
      }
      const dropped = loc.length - points.length;
      if (dropped > 0) console.error(`[luna-correlate] ${f}: ${dropped}/${loc.length} location-days had no cached cell-value (dropped from dashboard join)`);
      out.push({ name: f, label: cache.label, points });
    }
  }
  // Fail loud if any factor resolved to 0 points (e.g. an empty/unpopulated cache
  // — the kp-side analogue of the empty-CSV series guard above). A zero-point
  // factor would otherwise silently produce only below-min-n rows.
  for (const spec of out) {
    if (spec.points.length === 0) {
      throw new Error(`[luna-correlate] factor "${spec.name}" resolved to 0 points — cannot contribute to the dashboard (re-run factors.cache for this factor)`);
    }
  }
  return out;
}

/** signals.dashboard — lag-swept, FDR-ranked dashboard over multiple series ×
 *  factors. Offline: kp/lunar_phase/daylight need no location; pressure/aq/pollen are
 *  opt-in (cache + LUNA_LOCATION_FILE). Writes dashboard.md + dashboard.json. */
export async function signalsDashboardLogic(args: {
  seriesNames?: string[]; factors?: string[];
  lagWindow?: number; minN?: number; fdrQ?: number;
  region?: string; location?: string; dir?: string; outDir?: string;
}): Promise<{ markdown: string; outPath: string; jsonPath: string; survivorCount: number }> {
  const series = await buildSeriesSpecs(args.seriesNames ?? DEFAULT_SERIES, args.dir);
  if (series.length === 0) throw new Error("[luna-correlate] signals.dashboard: no series loaded — check seriesNames and LUNA_SERIES_DIR");
  const allDates = [...new Set(series.flatMap(s => s.points.map(p => p.date)))].sort();
  const factors = await buildFactorSpecs(args.factors ?? DEFAULT_FACTORS, allDates, args.region, args.location);
  if (factors.length === 0) throw new Error("[luna-correlate] signals.dashboard: no factors loaded — check the factors list");
  const result = analyze(series, factors, { lagWindow: args.lagWindow, minN: args.minN, fdrQ: args.fdrQ });
  const markdown = formatDashboard(result);
  const outDir = resolveSignalsDir(args.outDir);
  const outPath = join(outDir, "dashboard.md");
  const jsonPath = join(outDir, "dashboard.json");
  await Bun.write(outPath, markdown);
  await Bun.write(jsonPath, dashboardJson(result));
  return { markdown, outPath, jsonPath, survivorCount: result.survivorCount };
}
