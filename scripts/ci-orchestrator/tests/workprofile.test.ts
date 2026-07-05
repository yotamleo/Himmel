import { describe, test, expect } from "vitest";
import { resolveProfile } from "../src/workprofile.js";

const quiet = { procCount: 2, load1: 0.2 };
const busy = { procCount: 40, load1: 5 };

describe("resolveProfile", () => {
  test("manual toggle always wins", () => {
    const r = resolveProfile({ manualToggle: "drain", now: new Date(2026, 6, 5, 12), sample: busy, threshold: 1 });
    expect(r.profile).toBe("drain");
    expect(r.reason).toMatch(/manual/);
  });

  test("in the drain window + low load → drain", () => {
    const r = resolveProfile({ manualToggle: null, now: new Date(2026, 6, 5, 3), sample: quiet, threshold: 1 });
    expect(r.profile).toBe("drain");
  });

  test("low load, outside the window → shared", () => {
    const r = resolveProfile({ manualToggle: null, now: new Date(2026, 6, 5, 12), sample: quiet, threshold: 1 });
    expect(r.profile).toBe("shared");
  });

  test("high load in the window → focus (window alone is never enough)", () => {
    const r = resolveProfile({ manualToggle: null, now: new Date(2026, 6, 5, 3), sample: busy, threshold: 1 });
    expect(r.profile).toBe("focus");
  });

  test("unknown/no signal (busy, no toggle) fails to focus (protect local)", () => {
    const r = resolveProfile({ manualToggle: null, now: new Date(2026, 6, 5, 12), sample: busy, threshold: 1 });
    expect(r.profile).toBe("focus");
  });
});
