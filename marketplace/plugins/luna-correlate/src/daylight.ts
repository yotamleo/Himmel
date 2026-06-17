import type { FactorPoint } from "./correlate";
import { parseBbox } from "./fetchFactors";

// Offline daylight-duration factor. Daylight hours from date + latitude only.
// The latitude is the region-centroid of LUNA_REGION_BBOX (already country-level,
// no precise location) — so this stays inside the Posture-A boundary and needs no
// network. Uses Cooper's solar-declination approximation; sub-minute accuracy is
// unnecessary for a daily correlation signal.
export function daylightHours(date: string, latDeg: number): number {
  const d = new Date(date + "T00:00:00Z");
  const yearStart = Date.UTC(d.getUTCFullYear(), 0, 0);
  const dayOfYear = Math.floor((d.getTime() - yearStart) / 86_400_000);
  const lat = (latDeg * Math.PI) / 180;
  const decl = 0.409 * Math.sin((2 * Math.PI / 365) * dayOfYear - 1.39); // radians
  const cosH = -Math.tan(lat) * Math.tan(decl);
  if (cosH >= 1) return 0;   // polar night
  if (cosH <= -1) return 24; // polar day
  const halfDay = Math.acos(cosH); // radians
  return (2 * halfDay * 24) / (2 * Math.PI); // hours
}

export function daylightSeries(dates: string[], latDeg: number): FactorPoint[] {
  return dates.map(d => ({ date: d, value: daylightHours(d, latDeg) }));
}

/** Region-centroid latitude of a "lat_min,lon_min,lat_max,lon_max" bbox. */
export function bboxCentroidLat(bbox: string): number {
  const b = parseBbox(bbox);
  return (b.latMin + b.latMax) / 2;
}
