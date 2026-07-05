// scripts/ci-orchestrator/src/workprofile.ts
// HIMMEL-502 P2.4 — host work-profile resolver (resolves OQ4).
//
// Decides whether the local host will lend CI capacity: `focus` (protect local —
// never run local CI), `shared` (spare cycles), `drain` (idle window, run freely).
// FAIL TO `focus` when the signal is unknown — protect the operator's machine by
// default. Idle-detect is an optional advisory enhancer, off by default, and is
// NEVER the sole basis for opening `drain`.
export type WorkProfile = "focus" | "shared" | "drain";
export type LoadSample = { procCount: number; load1: number }; // injected in tests

export function resolveProfile(opts: {
  manualToggle?: WorkProfile | null; // $HOME/.himmel/ci-workprofile contents
  now: Date;
  scheduleDrain?: [number, number]; // [startHour, endHour] local, default [1,7]
  sample: LoadSample;
  threshold: number; // load1 threshold; below it the host is "quiet"
  idleAdvisory?: boolean; // off by default; advisory enhancer only, never sole basis
}): { profile: WorkProfile; reason: string } {
  // Manual toggle always wins.
  if (opts.manualToggle) {
    return { profile: opts.manualToggle, reason: `manual toggle: ${opts.manualToggle}` };
  }

  const below = opts.sample.load1 < opts.threshold;
  const [start, end] = opts.scheduleDrain ?? [1, 7];
  const h = opts.now.getHours(); // local hour
  // Window membership, wrap-around aware (e.g. [22, 6] spans midnight).
  const inWindow = start <= end ? h >= start && h < end : h >= start || h < end;

  // Drain: inside the schedule window AND quiet. The window alone is never
  // enough — load must be below threshold (idleAdvisory could further gate this
  // when enabled, but is never the sole basis; off by default → not consulted).
  if (inWindow && below) {
    return { profile: "drain", reason: "schedule drain window + load below threshold" };
  }
  // Shared: quiet but outside the window.
  if (below) {
    return { profile: "shared", reason: "load below threshold, outside drain window" };
  }
  // Fail-to-focus: busy host, or no usable signal → protect local.
  return { profile: "focus", reason: "load at/above threshold (or unknown) → protect local" };
}
