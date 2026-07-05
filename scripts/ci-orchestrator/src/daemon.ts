// scripts/ci-orchestrator/src/daemon.ts
// HIMMEL-502 P3.7 — the daemon supervisor loop harness.
//
// Loops tick() every intervalMs, honoring a stop-marker file (the loop exits as
// soon as the marker exists). All I/O is injected (tickFn, sleep, existsFn,
// clock) so the loop MECHANISM is hermetically testable without a real timer or
// a real scheduler pass. The production wiring (assembling real adapters + git
// discovery into a tick) is layered on top by the CLI; this file owns only the
// loop + stop-marker contract.
export type DaemonOptions = {
  tickFn: () => Promise<unknown>;
  intervalMs: number;
  stopMarkerPath: string; // loop exits when this file exists
  sleep: (ms: number) => Promise<void>;
  existsFn: (p: string) => boolean;
  maxTicks?: number; // safety bound (mainly for tests)
  onError?: (e: unknown) => void; // a failing tick never kills the loop
};

// Run the loop. Returns the number of ticks executed. Exits promptly when the
// stop-marker appears (checked BEFORE each tick) or maxTicks is reached.
export async function runDaemon(opts: DaemonOptions): Promise<number> {
  let ticks = 0;
  while (!opts.existsFn(opts.stopMarkerPath)) {
    try {
      await opts.tickFn();
    } catch (e) {
      if (opts.onError) opts.onError(e);
      // A failing tick is logged and the loop continues — one bad pass must not
      // take the daemon down (a transient lane/GitHub error is expected).
    }
    ticks += 1;
    if (opts.maxTicks !== undefined && ticks >= opts.maxTicks) break;
    if (opts.existsFn(opts.stopMarkerPath)) break; // re-check before sleeping
    await opts.sleep(opts.intervalMs);
  }
  return ticks;
}
