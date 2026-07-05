import { describe, test, expect } from "vitest";
import { loadMatrix } from "../src/act-matrix.js";

// The seven real jobs in .github/workflows/ci.yml (keyed "ci:<job>").
const REAL_JOBS = [
  "ci:secret-scan",
  "ci:commit-lint",
  "ci:lint",
  "ci:node-suites",
  "ci:bun-suites",
  "ci:security-scan",
  "ci:shell-unit",
];

describe("act-matrix", () => {
  test("loadMatrix returns a well-formed entry for every real ci.yml job", () => {
    const m = loadMatrix();
    for (const key of REAL_JOBS) {
      const e = m[key];
      expect(e, `missing ${key}`).toBeDefined();
      expect(e.fidelity).toMatch(/^(act-faithful|needs-shim|gha-only)$/);
      expect(Array.isArray(e.os)).toBe(true);
      expect(e.os.length).toBeGreaterThan(0);
      for (const os of e.os) expect(["linux", "windows", "macos"]).toContain(os);
      expect(typeof e.heavy).toBe("boolean");
    }
  });

  test("shell-unit is the multi-OS job (linux+windows+macos)", () => {
    const m = loadMatrix();
    expect(m["ci:shell-unit"].os).toEqual(["linux", "windows", "macos"]);
  });

  test("matrix covers exactly the real ci.yml job set (no invented jobs)", () => {
    const m = loadMatrix();
    expect(Object.keys(m).sort()).toEqual([...REAL_JOBS].sort());
  });
});
