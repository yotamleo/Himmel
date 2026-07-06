import { join } from "path";
import { parseSeriesCsv } from "./series";
import type { SeriesPoint } from "./correlate";

/**
 * Resolve the directory holding the (offline, local) health/status series CSVs.
 * Explicit `dir` wins; otherwise the LUNA_SERIES_DIR env var (set to the
 * salus vitals dir, e.g. 50-Vitals/). No network, no PHI leaves the box.
 */
export function resolveSeriesDir(dir?: string): string {
  if (dir) return dir;
  const env = process.env.LUNA_SERIES_DIR;
  if (env) return env;
  throw new Error("series dir unset — pass a dir or set LUNA_SERIES_DIR");
}

/**
 * Load a named series (e.g. "migraine", "pain", "sleep", "stress") as generic
 * (date,value) points from `<dir>/<name>.csv`. The series file stays local.
 */
export async function loadSeries(name: string, dir?: string): Promise<SeriesPoint[]> {
  if (!/^[A-Za-z0-9._-]+$/.test(name) || name.includes("..")) {
    throw new Error(`invalid series name: "${name}" (no path separators or ..)`);
  }
  const path = join(resolveSeriesDir(dir), `${name}.csv`);
  const file = Bun.file(path);
  if (!(await file.exists())) throw new Error(`series file not found: ${path}`);
  return parseSeriesCsv(await file.text());
}
