import { join } from "path";
import { parseOpenMeteoHourly, type DailyAgg } from "./openMeteo";

// Region-grid fetcher (M2) — the ONLY network path for location factors, and the
// real Posture-A boundary test. Given a region bbox it fetches a coarse country-
// level GRID of cells from Open-Meteo; the request reveals only country extent and
// NEVER the operator's coordinates. Everything is cached locally; the offline
// proximity index (proximity.ts) is the only place the operator's location meets
// this data. Mirrors fetchKp.ts (gated + logged + fail-loud on empty).

export type BBox = { latMin: number; lonMin: number; latMax: number; lonMax: number };
export type GridCell = { lat: number; lon: number };
export type DateRange = { start: string; end: string };
export type CachedCell = { lat: number; lon: number; daily: DailyAgg[] };
export type AggMetric = "min" | "mean" | "max";
export type FactorCache = {
  factor: string; field: string; unit: string; metric: AggMetric; label: string;
  bbox: BBox; dateRange: DateRange; cells: CachedCell[];
};

// Factor → Open-Meteo endpoint config. `pressure` is the M2 primary (archive API,
// long history). `pollen`/`aq` ride the same code path via the air-quality API
// (which serves only a recent rolling window). Each names the daily metric that carries the
// signal: barometric migraine trigger = daily-MIN (front-passage pressure drop);
// pollen/AQ exposure = daily MEAN.
export const FACTOR_CONFIG: Record<
  string,
  { api: string; field: string; unit: string; metric: AggMetric; label: string }
> = {
  pressure: {
    api: "https://archive-api.open-meteo.com/v1/archive",
    field: "pressure_msl", unit: "hPa", metric: "min",
    label: "barometric pressure (daily min, hPa)",
  },
  aq: {
    api: "https://air-quality-api.open-meteo.com/v1/air-quality",
    field: "pm2_5", unit: "ug/m3", metric: "mean",
    label: "PM2.5 (daily mean, ug/m3)",
  },
  pollen: {
    api: "https://air-quality-api.open-meteo.com/v1/air-quality",
    field: "grass_pollen", unit: "grains/m3", metric: "mean",
    label: "grass pollen (daily mean, grains/m3)",
  },
};

export const LOCATION_FACTORS = Object.keys(FACTOR_CONFIG);

/** Parse `"lat_min,lon_min,lat_max,lon_max"` (the LUNA_REGION_BBOX shape). */
export function parseBbox(s: string): BBox {
  const parts = s.split(",").map(p => Number(p.trim()));
  if (parts.length !== 4 || parts.some(n => Number.isNaN(n))) {
    throw new Error(`invalid region bbox "${s}" — expected "lat_min,lon_min,lat_max,lon_max"`);
  }
  const [latMin, lonMin, latMax, lonMax] = parts;
  if (latMin > latMax || lonMin > lonMax) {
    throw new Error(`region bbox has min > max: "${s}"`);
  }
  return { latMin, lonMin, latMax, lonMax };
}

export function resolveBbox(bbox?: string): BBox {
  const v = bbox ?? process.env.LUNA_REGION_BBOX;
  if (!v) {
    throw new Error(
      'region unset — pass region or set LUNA_REGION_BBOX="lat_min,lon_min,lat_max,lon_max"',
    );
  }
  return parseBbox(v);
}

/**
 * Coarse grid over the bbox (both ends inclusive), 1° spacing by default. Coarse
 * on purpose: pressure is synoptic-scale (varies over 100s of km), so 1° is plenty
 * and keeps the request country-level. Rounds each step to 1e-6 so float drift
 * doesn't accumulate across many additions.
 */
export function gridCells(bbox: BBox, spacingDeg = 1): GridCell[] {
  if (spacingDeg <= 0) throw new Error(`grid spacing must be > 0; got ${spacingDeg}`);
  const r = (n: number): number => Math.round(n * 1e6) / 1e6;
  const cells: GridCell[] = [];
  for (let lat = bbox.latMin; lat <= bbox.latMax + 1e-9; lat = r(lat + spacingDeg)) {
    for (let lon = bbox.lonMin; lon <= bbox.lonMax + 1e-9; lon = r(lon + spacingDeg)) {
      cells.push({ lat: r(lat), lon: r(lon) });
    }
  }
  return cells;
}

// Resolve the per-factor cache against this module's dir (not cwd), like KP_CACHE.
export function factorCachePath(factor: string): string {
  return join(import.meta.dir, "..", "cache", `${factor}.json`);
}

function buildUrl(api: string, cell: GridCell, field: string, range: DateRange): string {
  const u = new URL(api);
  u.searchParams.set("latitude", String(cell.lat));
  u.searchParams.set("longitude", String(cell.lon));
  u.searchParams.set("start_date", range.start);
  u.searchParams.set("end_date", range.end);
  u.searchParams.set("hourly", field);
  u.searchParams.set("timezone", "UTC");
  return u.toString();
}

const ISO = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Bulk-fetch a location factor over the region grid into `cache/<factor>.json`.
 * Gated + logged; fails loud if the whole grid yields 0 daily points (so a format
 * drift or empty range can't silently degrade every correlation to n=0).
 */
export async function fetchFactorToCache(opts: {
  factor: string;
  bbox?: string;
  dateRange: DateRange;
  spacingDeg?: number;
  fetchImpl?: typeof fetch;
}): Promise<{ factor: string; cells: number; cached: string }> {
  const cfg = FACTOR_CONFIG[opts.factor];
  if (!cfg) {
    throw new Error(
      `[luna-correlate] unsupported location factor "${opts.factor}" — supports: ${LOCATION_FACTORS.join(", ")}`,
    );
  }
  const range = opts.dateRange;
  if (!ISO.test(range.start) || !ISO.test(range.end)) {
    throw new Error(`[luna-correlate] dateRange must be ISO YYYY-MM-DD; got ${range.start}..${range.end}`);
  }
  if (range.start > range.end) {
    throw new Error(`[luna-correlate] dateRange start after end: ${range.start}..${range.end}`);
  }
  const bbox = resolveBbox(opts.bbox);
  const cells = gridCells(bbox, opts.spacingDeg ?? 1);
  const f = opts.fetchImpl ?? fetch;
  console.error(
    `[luna-correlate] FETCH ${opts.factor} grid (${cells.length} cells, country-level, NO operator coords): ${cfg.api} ${range.start}..${range.end}`,
  );
  const cached: CachedCell[] = [];
  for (const cell of cells) {
    const res = await f(buildUrl(cfg.api, cell, cfg.field, range));
    if (!res.ok) {
      throw new Error(
        `[luna-correlate] ${opts.factor} fetch failed for cell ${cell.lat},${cell.lon}: HTTP ${res.status}`,
      );
    }
    const daily = parseOpenMeteoHourly(await res.json(), cfg.field);
    cached.push({ lat: cell.lat, lon: cell.lon, daily });
  }
  const totalDays = cached.reduce((s, c) => s + c.daily.length, 0);
  if (totalDays === 0) {
    throw new Error(
      `[luna-correlate] ${opts.factor} fetch produced 0 daily points across ${cells.length} cells — empty date range or API response`,
    );
  }
  const out: FactorCache = {
    factor: opts.factor, field: cfg.field, unit: cfg.unit, metric: cfg.metric,
    label: cfg.label, bbox, dateRange: range, cells: cached,
  };
  const path = factorCachePath(opts.factor);
  await Bun.write(path, JSON.stringify(out));
  console.error(`[luna-correlate] cached ${opts.factor}: ${cells.length} cells, ${totalDays} cell-days -> ${path}`);
  return { factor: opts.factor, cells: cells.length, cached: path };
}
