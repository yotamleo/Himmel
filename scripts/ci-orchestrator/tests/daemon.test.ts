import { describe, test, expect } from "vitest";
import { runDaemon } from "../src/daemon.js";

describe("runDaemon loop", () => {
  test("loops tick until the stop-marker appears, honoring it before sleeping", async () => {
    let ticks = 0;
    let markerPresent = false;
    const n = await runDaemon({
      tickFn: async () => {
        ticks += 1;
        if (ticks === 3) markerPresent = true; // the 3rd tick drops the stop-marker
      },
      intervalMs: 0,
      stopMarkerPath: "/stop",
      sleep: async () => {},
      existsFn: () => markerPresent,
      maxTicks: 100,
    });
    expect(n).toBe(3); // exits promptly after the marker appears, no extra tick
  });

  test("stop-marker present from the start → zero ticks", async () => {
    let ticks = 0;
    const n = await runDaemon({
      tickFn: async () => {
        ticks += 1;
      },
      intervalMs: 0,
      stopMarkerPath: "/stop",
      sleep: async () => {},
      existsFn: () => true,
    });
    expect(n).toBe(0);
    expect(ticks).toBe(0);
  });

  test("a failing tick does not kill the loop (onError observed)", async () => {
    let ticks = 0;
    const errors: unknown[] = [];
    await runDaemon({
      tickFn: async () => {
        ticks += 1;
        throw new Error("transient");
      },
      intervalMs: 0,
      stopMarkerPath: "/stop",
      sleep: async () => {},
      existsFn: () => ticks >= 2,
      onError: (e) => errors.push(e),
    });
    expect(errors).toHaveLength(2); // loop survived both failing ticks
  });
});
