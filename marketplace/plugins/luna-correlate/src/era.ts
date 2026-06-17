import type { SeriesPoint } from "./correlate";

// The Fitbit→Galaxy sensor boundary. Absolute sleep/HR values are NOT comparable
// across it (different sensors/algorithms; ~2024-10→2025-01 data gap), so the
// correlator treats it as an instrument step-change: split device series here and
// correlate WITHIN an era. The boundary sits inside the data gap, so the exact day
// is not sensitive. hrv_ms is Galaxy-only and yields a single era.
export const GALAXY_BOUNDARY = "2025-01-01";

export type EraSeries = { name: string; points: SeriesPoint[] };

export function splitEra(
  name: string, points: SeriesPoint[], boundary = GALAXY_BOUNDARY,
): EraSeries[] {
  const before = points.filter(p => p.date < boundary);
  const after = points.filter(p => p.date >= boundary);
  const out: EraSeries[] = [];
  if (before.length) out.push({ name: `${name} (pre ${boundary})`, points: before });
  if (after.length) out.push({ name: `${name} (${boundary}+)`, points: after });
  return out;
}
