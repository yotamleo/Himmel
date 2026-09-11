import { describe, test, expect } from "vitest";
import { loadMatrix, loadIntentionallyAbsent } from "../src/act-matrix.js";

// Full ci.yml job-set coverage (every job present or intentionally-absent) is
// tests/ci-coverage.test.ts's job — this file only checks the SHAPE of what's
// modeled, not which jobs are.
describe("act-matrix", () => {
  test("loadMatrix returns a well-formed entry for every modeled job", () => {
    const m = loadMatrix();
    expect(Object.keys(m).length).toBeGreaterThan(0);
    for (const [key, e] of Object.entries(m)) {
      expect(key, "job key must be workflow:job").toMatch(/^ci:/);
      expect(e.fidelity).toMatch(/^(act-faithful|needs-shim|gha-only)$/);
      expect(Array.isArray(e.os)).toBe(true);
      expect(e.os.length).toBeGreaterThan(0);
      for (const os of e.os) expect(["linux", "windows", "macos"]).toContain(os);
      expect(typeof e.heavy).toBe("boolean");
    }
  });

  test("shell-unit-shard is the heavy multi-OS matrix job; shell-unit is the cheap aggregator (HIMMEL-2880)", () => {
    const m = loadMatrix();
    expect(m["ci:shell-unit-shard"].os).toEqual(["linux", "windows", "macos"]);
    expect(m["ci:shell-unit-shard"].heavy).toBe(true);
    expect(m["ci:shell-unit"].os).toEqual(["linux"]);
    expect(m["ci:shell-unit"].heavy).toBe(false);
  });

  test("loadIntentionallyAbsent returns a non-empty reason for every entry", () => {
    const absent = loadIntentionallyAbsent();
    for (const [key, reason] of Object.entries(absent)) {
      expect(key).toMatch(/^ci:/);
      expect(typeof reason).toBe("string");
      expect(reason.length).toBeGreaterThan(0);
    }
  });
});
