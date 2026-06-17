import type { FactorCache, CachedCell } from "./fetchFactors";
import type { FactorPoint } from "./correlate";

// Offline proximity index (M2). The operator's date×place (derived from Google
// Timeline, lives in luna-medic) is local-only and NEVER egressed. This is the
// single place it meets the public factor cache: each location-day resolves to
// the nearest cached grid cell and reads that cell's daily factor value. No
// network, no PHI leaves the box — mirrors loadSeries.ts's offline-only posture.

export type LocationDay = { date: string; lat: number; lon: number };

export function resolveLocationFile(path?: string): string {
  if (path) return path;
  const env = process.env.LUNA_LOCATION_FILE;
  if (env) return env;
  throw new Error("location file unset — pass a path or set LUNA_LOCATION_FILE");
}

const ISO = /^\d{4}-\d{2}-\d{2}$/;

/** Parse the operator's local date×place CSV (header `date,lat,lon`). */
export function parseLocationCsv(text: string): LocationDay[] {
  const [head, ...rows] = text.split("\n").map(l => l.trim()).filter(l => Boolean(l) && !l.startsWith("#"));
  if (!head) throw new Error("location CSV has no header/data rows");
  const cols = head.split(",");
  const di = cols.indexOf("date"), lati = cols.indexOf("lat"), loni = cols.indexOf("lon");
  if (di === -1 || lati === -1 || loni === -1) {
    throw new Error(`location CSV missing date/lat/lon header; got: ${cols.join(",")}`);
  }
  return rows.map(r => {
    const c = r.split(",");
    const date = (c[di] ?? "").trim();
    if (!ISO.test(date)) throw new Error(`location CSV row has a non-ISO (YYYY-MM-DD) date "${date}": "${r}"`);
    const lat = Number((c[lati] ?? "").trim()), lon = Number((c[loni] ?? "").trim());
    if (Number.isNaN(lat) || Number.isNaN(lon)) throw new Error(`location CSV row has non-numeric lat/lon: "${r}"`);
    return { date, lat, lon };
  });
}

export async function loadLocation(path?: string): Promise<LocationDay[]> {
  const resolved = resolveLocationFile(path);
  const file = Bun.file(resolved);
  if (!(await file.exists())) throw new Error(`location file not found: ${resolved}`);
  return parseLocationCsv(await file.text());
}

/**
 * Nearest cached cell by cos-lat-weighted squared-degree distance. Weighting the
 * longitude delta by cos(lat) corrects for E-W degrees shrinking with latitude —
 * adequate for nearest-cell-within-a-country-bbox without full haversine cost.
 */
export function nearestCell(lat: number, lon: number, cells: CachedCell[]): CachedCell {
  if (!cells.length) throw new Error("factor cache has no cells");
  const cosLat = Math.cos((lat * Math.PI) / 180);
  let best = cells[0];
  let bestD = Infinity;
  for (const c of cells) {
    const dLat = c.lat - lat;
    const dLon = (c.lon - lon) * cosLat;
    const d = dLat * dLat + dLon * dLon;
    if (d < bestD) { bestD = d; best = c; }
  }
  return best;
}

/**
 * The offline proximity join: for each operator location-day, find the nearest
 * cached grid cell and read that cell's daily factor metric (cache.metric) for
 * that date → a date-keyed FactorPoint[] aligned to where the operator actually
 * was. Days the cache has no value for are dropped (they simply won't join).
 */
export function resolveFactorSeries(location: LocationDay[], cache: FactorCache): FactorPoint[] {
  const metric = cache.metric;
  // Memoise each cell's date→value map so repeated days at one place don't rescan.
  // Keyed by cell object identity — safe because nearestCell returns elements of
  // cache.cells, never copies (a future change to return a copy would only cost a
  // re-scan, not correctness).
  const byCell = new Map<CachedCell, Map<string, number>>();
  const dateIndex = (cell: CachedCell): Map<string, number> => {
    let m = byCell.get(cell);
    if (!m) { m = new Map(cell.daily.map(d => [d.date, d[metric]])); byCell.set(cell, m); }
    return m;
  };
  const out: FactorPoint[] = [];
  for (const loc of location) {
    const v = dateIndex(nearestCell(loc.lat, loc.lon, cache.cells)).get(loc.date);
    if (v === undefined) continue;
    out.push({ date: loc.date, value: v });
  }
  return out;
}
