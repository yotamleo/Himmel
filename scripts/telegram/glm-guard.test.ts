// scripts/telegram/glm-guard.test.ts
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
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
