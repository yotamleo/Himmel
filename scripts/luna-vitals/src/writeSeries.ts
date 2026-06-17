import { join } from "path";
import { validateRow, isValidISODate, type ReviewArtifact } from "./types";

export async function writeSeries(
  artifact: ReviewArtifact, dir: string, opts: { allowConflicts?: boolean } = {},
): Promise<{ metric: string; path: string; n: number }[]> {
  if (!opts.allowConflicts && artifact.conflicts.length) {
    const ms = [...new Set(artifact.conflicts.map(c => c.metric))].join(", ");
    throw new Error(`refusing to write: unresolved conflict(s) in ${ms} — resolve in the review artifact first`);
  }
  const byMetric = new Map<string, Map<string, number>>();
  // seed from existing CSVs, then overlay the artifact (new wins on same date)
  const metrics = [...new Set(artifact.rows.map(r => r.metric))];
  for (const metric of metrics) {
    const path = join(dir, `${metric}.csv`);
    const map = new Map<string, number>();
    const f = Bun.file(path);
    if (await f.exists()) {
      const [, ...rows] = (await f.text()).split("\n").map(l => l.trim()).filter(Boolean);
      for (const line of rows) {
        // Defend the medical-series contract: only import well-formed `date,value`
        // rows (exactly two fields, ISO date, finite value). A malformed/hand-edited
        // existing CSV must not silently seed a NaN, a non-ISO date, or a misaligned
        // value back into the series — and a dropped row is WARNED, never silent, so
        // an operator can audit lost data.
        const parts = line.split(",");
        const [d] = parts;
        const n = Number(parts[1]);
        if (parts.length !== 2 || !d || !isValidISODate(d) || !Number.isFinite(n)) {
          console.error(`[luna-vitals] warning: skipping malformed row in ${path}: ${JSON.stringify(line)}`);
          continue;
        }
        map.set(d, n);
      }
    }
    byMetric.set(metric, map);
  }
  // Validate every incoming row before it reaches a CSV — closes the in-memory
  // path (mergeRows -> writeSeries) that bypasses the readArtifact/writeArtifact gate.
  for (const r of artifact.rows) { validateRow(r); byMetric.get(r.metric)!.set(r.date, r.value); }

  const out: { metric: string; path: string; n: number }[] = [];
  for (const [metric, map] of byMetric) {
    const path = join(dir, `${metric}.csv`);
    const dates = [...map.keys()].sort();
    const body = dates.map(d => `${d},${map.get(d)}`).join("\n");
    await Bun.write(path, `date,value\n${body}\n`);
    out.push({ metric, path, n: dates.length });
  }
  return out;
}
