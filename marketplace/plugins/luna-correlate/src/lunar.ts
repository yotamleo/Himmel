import type { FactorPoint } from "./correlate";

// Offline lunar-illumination factor (date-only, zero location leak). Illumination
// fraction from the synodic phase relative to a known new moon. Astronomical
// precision is unnecessary — we only need a smooth 0(new)…1(full) daily signal to
// correlate against, not an ephemeris.
const SYNODIC_DAYS = 29.530588853;
// 2000-01-06 18:14 UTC — a reference new moon.
const NEW_MOON_ANCHOR_MS = Date.UTC(2000, 0, 6, 18, 14, 0);

export function lunarIllumination(date: string): number {
  const t = new Date(date + "T00:00:00Z").getTime();
  const days = (t - NEW_MOON_ANCHOR_MS) / 86_400_000;
  const phase = (((days % SYNODIC_DAYS) + SYNODIC_DAYS) % SYNODIC_DAYS) / SYNODIC_DAYS;
  return (1 - Math.cos(2 * Math.PI * phase)) / 2; // 0 at new, 1 at full
}

export function lunarPhaseSeries(dates: string[]): FactorPoint[] {
  return dates.map(d => ({ date: d, value: lunarIllumination(d) }));
}
