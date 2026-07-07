// scripts/telegram/glm-guard.test.ts
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import * as realFs from "node:fs";

// Plain-object snapshot of the REAL fs, captured at module load (before any
// mock runs). ESM namespace props are live bindings, but spreading copies the
// current function REFERENCES into a fresh object whose props won't follow a
// later mock — so the surgical readFileSync mock below can pass through to real
// for every path except the one under test, and cannot starve other test files
// (bun runs them concurrently in one process; a global throw leaked once).
const realFsSnapshot = { ...realFs };
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checkGlmGuards } from "./glm-guard";

let cfg: string, work: string;
beforeEach(() => {
  cfg = mkdtempSync(join(tmpdir(), "glmcfg-"));
  work = mkdtempSync(join(tmpdir(), "glmwork-"));
});
afterEach(() => { for (const d of [cfg, work]) rmSync(d, { recursive: true, force: true }); });

test("clean cwd passes", () => {
  expect(checkGlmGuards(work, cfg)).toEqual({ ok: true });
});

test(".salus marker refuses", () => {
  writeFileSync(join(work, ".salus"), "");
  const r = checkGlmGuards(work, cfg);
  expect(r.ok).toBe(false);
  expect((r as any).reason).toMatch(/\.salus/);
});

test("phi-roots line refuses (no override exists)", () => {
  writeFileSync(join(cfg, "phi-roots"), work + "\n");
  expect(checkGlmGuards(work, cfg).ok).toBe(false);
});

test("phi-roots trailing slash still blocks descendant", () => {
  mkdirSync(join(work, "sub"));
  writeFileSync(join(cfg, "phi-roots"), work + "/\n");
  expect(checkGlmGuards(join(work, "sub"), cfg).ok).toBe(false);
});

test("denylist CRLF line refuses; blank CRLF line does not over-refuse", () => {
  writeFileSync(join(cfg, "egress-denylist"), work + "\r\n\r\n");
  expect(checkGlmGuards(work, cfg).ok).toBe(false);
  const other = mkdtempSync(join(tmpdir(), "glmother-"));
  expect(checkGlmGuards(other, cfg).ok).toBe(true);
  rmSync(other, { recursive: true, force: true });
});

test("guard file no trailing newline still blocks final line", () => {
  writeFileSync(join(cfg, "phi-roots"), work); // no trailing \n
  expect(checkGlmGuards(work, cfg).ok).toBe(false);
});

test("guard config as DIRECTORY fails closed", () => {
  mkdirSync(join(cfg, "phi-roots"));
  const r = checkGlmGuards(work, cfg);
  expect(r.ok).toBe(false);
  expect((r as any).reason).toMatch(/failing closed/);
});

test("sibling prefix does not false-positive", () => {
  writeFileSync(join(cfg, "egress-denylist"), work + "-sibling\n");
  expect(checkGlmGuards(work, cfg).ok).toBe(true);
});

// --- pathUnderAny catch branch (CR finding F2). The `!statSync().isFile()`
// branch is covered by the DIRECTORY test above; the TRY/CATCH (statSync or
// readFileSync THROW — e.g. permission-denied at read time) is not. Force the
// throw with a SURGICAL module mock (readFileSync throws ONLY for this listFile,
// passes through to real for every other path) and assert fail-closed. Without
// the mock this config would be a HIT (PHI-marked refuse), so the "failing
// closed" wording proves the catch fired rather than the happy isFile path.
// Kept LAST; mock.restore() in finally restores the registry.

test("guard config read THROW fails closed (catch branch — e.g. permission-denied)", () => {
  const listFile = join(cfg, "phi-roots");
  writeFileSync(listFile, work + "\n"); // exists; sans mock this is a HIT (REFUSED — PHI-marked)
  mock.module("node:fs", () => ({
    ...realFsSnapshot,
    readFileSync: (p: any, ...rest: any[]) => {
      if (typeof p === "string" && p === listFile) throw new Error("EACCES: permission denied");
      return realFsSnapshot.readFileSync(p, ...rest);
    },
  }));
  try {
    const r = checkGlmGuards(work, cfg);
    expect(r.ok).toBe(false);
    expect((r as any).reason).toMatch(/failing closed/);
  } finally {
    mock.restore();
  }
});

test(".salus stat THROW fails closed, not open (#850 — e.g. permission-denied)", () => {
  // Do NOT create .salus: the mock makes statSync throw EACCES (not ENOENT) for
  // it. existsSync-based code returns false → passes (fail-OPEN); the statSync
  // fix distinguishes non-ENOENT errors and fails CLOSED, matching the list checks.
  const salus = join(work, ".salus");
  mock.module("node:fs", () => ({
    ...realFsSnapshot,
    statSync: (p: any, ...rest: any[]) => {
      if (typeof p === "string" && p === salus) {
        const err: NodeJS.ErrnoException = new Error("EACCES: permission denied");
        err.code = "EACCES";
        throw err;
      }
      return realFsSnapshot.statSync(p, ...rest);
    },
  }));
  try {
    const r = checkGlmGuards(work, cfg);
    expect(r.ok).toBe(false);
    expect((r as any).reason).toMatch(/failing closed/);
  } finally {
    mock.restore();
  }
});
