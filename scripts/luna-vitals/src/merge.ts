import type { ExtractedRow, Conflict, ReviewArtifact } from "./types";

const key = (r: ExtractedRow): string => `${r.metric} ${r.date}`;

export function mergeRows(
  input: { deterministic: ExtractedRow[]; llm: ExtractedRow[]; bucket: string },
): ReviewArtifact {
  // Group all candidates by (metric,date); remember which were authoritative (deterministic).
  const groups = new Map<string, { det: ExtractedRow[]; llm: ExtractedRow[] }>();
  for (const r of input.deterministic) {
    const g = groups.get(key(r)) ?? { det: [], llm: [] }; g.det.push(r); groups.set(key(r), g);
  }
  for (const r of input.llm) {
    const g = groups.get(key(r)) ?? { det: [], llm: [] }; g.llm.push(r); groups.set(key(r), g);
  }
  const rows: ExtractedRow[] = [];
  const conflicts: Conflict[] = [];
  for (const g of groups.values()) {
    const pool = g.det.length ? g.det : g.llm; // deterministic wins wholesale when present
    rows.push(pool[0]);
    const distinct = [...new Set(pool.map(r => r.value))];
    if (distinct.length > 1) {
      // `chosen` mirrors the emitted row (pool[0]) so the artifact records which
      // candidate won, not just that there was a disagreement.
      conflicts.push({
        metric: pool[0].metric,
        date: pool[0].date,
        values: pool.map(r => ({ value: r.value, source: r.source })),
        chosen: { value: pool[0].value, source: pool[0].source },
      });
    }
  }
  rows.sort((a, b) => (a.metric < b.metric ? -1 : a.metric > b.metric ? 1 : a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return { bucket: input.bucket, rows, conflicts };
}
