// scripts/telegram/glm-env.test.ts
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildGlmEnv, findSettingsConflicts, formatConflict, GLM_MODEL_ALIAS, pickFiveHourLimit, fetchGlmUsage } from "./glm-env";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "glmenv-")); delete process.env.ZAI_API_KEY; });
afterEach(() => { rmSync(root, { recursive: true, force: true }); });

test("env block from process.env key", () => {
  process.env.ZAI_API_KEY = "k-123";
  const e = buildGlmEnv(root);
  expect(e.ANTHROPIC_BASE_URL).toBe("https://api.z.ai/api/anthropic");
  expect(e.ANTHROPIC_AUTH_TOKEN).toBe("k-123");
  expect(e.ANTHROPIC_MODEL).toBe("glm-5.2");
  expect(e.ANTHROPIC_DEFAULT_HAIKU_MODEL).toBe("glm-4.7");
  expect(e.ANTHROPIC_DEFAULT_SONNET_MODEL).toBe("glm-5.2");
  expect(e.ANTHROPIC_DEFAULT_OPUS_MODEL).toBe("glm-5.2");
  expect(Object.keys(e)).not.toContain("CLAUDE_CONFIG_DIR");
});

test("key from repo .env, surrounding quotes stripped", () => {
  writeFileSync(join(root, ".env"), 'ZAI_API_KEY="quoted-456"\n'); // gitleaks:allow
  expect(buildGlmEnv(root).ANTHROPIC_AUTH_TOKEN).toBe("quoted-456");
});

test("missing key throws", () => {
  expect(() => buildGlmEnv(root)).toThrow(/ZAI_API_KEY/);
});

test("key resolved from MAIN checkout .env when run from a git worktree", () => {
  const repo = mkdtempSync(join(tmpdir(), "glmmain-"));
  const sh = (args: string[], cwd: string) => {
    const r = Bun.spawnSync(args, { cwd, stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) throw new Error(`${args.join(" ")} failed: ${r.stderr.toString()}`);
  };
  try {
    sh(["git", "init"], repo);
    sh(["git", "config", "user.email", "t@t.t"], repo);
    sh(["git", "config", "user.name", "t"], repo);
    writeFileSync(join(repo, ".env"), "ZAI_API_KEY=from-main-checkout\n"); // gitleaks:allow
    writeFileSync(join(repo, "f.txt"), "x");
    sh(["git", "add", "f.txt"], repo); // .env stays out of the commit (mirrors gitignore)
    sh(["git", "commit", "-m", "init"], repo);
    const wt = join(repo, "wt");
    sh(["git", "worktree", "add", wt], repo); // wt has no .env → forces main-checkout fallback
    expect(buildGlmEnv(wt).ANTHROPIC_AUTH_TOKEN).toBe("from-main-checkout");
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("GLM model alias is pinned to opus", () => {
  expect(GLM_MODEL_ALIAS).toBe("opus");
});

test("settings conflict: model key flagged", () => {
  const f = join(root, "settings.json");
  writeFileSync(f, JSON.stringify({ model: "claude-fable-5" }));
  expect(findSettingsConflicts([f])).toEqual([{ file: f, kind: "model" }]);
});

test("settings conflict: env.ANTHROPIC_* flagged, other env keys pass", () => {
  const f = join(root, "settings.json");
  writeFileSync(f, JSON.stringify({ env: { ANTHROPIC_MODEL: "x", HIMMEL_INITIATIVE: "1" } }));
  expect(findSettingsConflicts([f])).toEqual([{ file: f, kind: "env", key: "ANTHROPIC_MODEL" }]);
});

test("settings conflict: missing file skipped, unparseable fails closed", () => {
  const bad = join(root, "bad.json");
  writeFileSync(bad, "{not json");
  expect(findSettingsConflicts([join(root, "absent.json"), bad])).toEqual([{ file: bad, kind: "unparseable" }]);
});

test("formatConflict renders the file:key strings the print/refusal sites emit", () => {
  expect(formatConflict({ file: "/a", kind: "model" })).toBe("/a: model");
  expect(formatConflict({ file: "/a", kind: "env", key: "ANTHROPIC_MODEL" })).toBe("/a: env.ANTHROPIC_MODEL");
  expect(formatConflict({ file: "/a", kind: "unparseable" })).toBe("/a: unparseable");
});

// --- Worker context diet (HIMMEL-654): the GLM env block force-disables the
// env-gated session-shaping injections (initiative, where-are-we, doc-freshness,
// update-check). Two prompt-too-long deaths showed every injected block costs
// context the GLM lane cannot spare, and none of them is meaningful to an
// unattended worker. The falsy values beat an operator-exported gate because
// they merge over process.env in glmChildEnv (see the override-seam test in
// run.test.ts).

test("context diet: GLM env block force-disables the env-gated session injections", () => {
  process.env.ZAI_API_KEY = "k-123";
  const e = buildGlmEnv(root);
  expect(e.HIMMEL_INITIATIVE).toBe("0");
  expect(e.HIMMEL_INITIATIVE_OVERNIGHT).toBe("0");
  expect(e.HIMMEL_OVERNIGHT).toBe("0");
  expect(e.HIMMEL_WHERE_ARE_WE).toBe("0");
  expect(e.HIMMEL_DOC_FRESHNESS).toBe("0");
  expect(e.UPDATE_CHECK_DISABLE).toBe("1");
});

// --- .env precedence when sources COEXIST (CR finding F3). Existing tests prove
// each source in isolation; these pin the ordering readZaiKey promises:
// process.env > repo(worktree) .env > main-checkout .env.

test("precedence: process.env beats repo .env when both present", () => {
  process.env.ZAI_API_KEY = "from-process-env";
  writeFileSync(join(root, ".env"), "ZAI_API_KEY=from-repo-env\n"); // gitleaks:allow
  expect(buildGlmEnv(root).ANTHROPIC_AUTH_TOKEN).toBe("from-process-env");
});

test("precedence: worktree .env beats main-checkout .env fallback when both present", () => {
  const repo = mkdtempSync(join(tmpdir(), "glmmain2-"));
  const sh = (args: string[], cwd: string) => {
    const r = Bun.spawnSync(args, { cwd, stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) throw new Error(`${args.join(" ")} failed: ${r.stderr.toString()}`);
  };
  try {
    sh(["git", "init"], repo);
    sh(["git", "config", "user.email", "t@t.t"], repo);
    sh(["git", "config", "user.name", "t"], repo);
    writeFileSync(join(repo, ".env"), "ZAI_API_KEY=from-main-checkout\n"); // gitleaks:allow
    writeFileSync(join(repo, "f.txt"), "x");
    sh(["git", "add", "f.txt"], repo); // .env stays out of the commit (mirrors gitignore)
    sh(["git", "commit", "-m", "init"], repo);
    const wt = join(repo, "wt");
    sh(["git", "worktree", "add", wt], repo);
    // worktree's OWN .env present → must win over the main-checkout fallback
    writeFileSync(join(wt, ".env"), "ZAI_API_KEY=from-worktree\n"); // gitleaks:allow
    expect(buildGlmEnv(wt).ANTHROPIC_AUTH_TOKEN).toBe("from-worktree");
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

const NOW = 1783100000000;
const OK = { code: 200, data: { level: "pro", limits: [
  { type: "TOKENS_LIMIT", unit: 3, percentage: 84, nextResetTime: NOW + 2 * 3600_000 },
  { type: "TOKENS_LIMIT", unit: 5, percentage: 12, nextResetTime: NOW + 6 * 86400_000 },
] } };

test("pickFiveHourLimit picks the SMALLEST <=5h future entry", () => {
  expect(pickFiveHourLimit(OK, NOW)).toEqual({ percentage: 84, nextResetTime: NOW + 2 * 3600_000, level: "pro" });
  // two entries both <=5h out: the smallest future reset wins (0c ambiguity guard —
  // a shorter sub-window entry sorting first must not shadow the true 5h window,
  // and among <=5h candidates the nearest reset is the conservative arm slot)
  const TWO = { code: 200, data: { limits: [
    { type: "TOKENS_LIMIT", percentage: 40, nextResetTime: NOW + 4 * 3600_000 },
    { type: "TOKENS_LIMIT", percentage: 84, nextResetTime: NOW + 2 * 3600_000 },
  ] } };
  // strict shape: no data.level in TWO -> the level key is OMITTED entirely
  expect(pickFiveHourLimit(TWO, NOW)).toEqual({ percentage: 84, nextResetTime: NOW + 2 * 3600_000 });
  expect(pickFiveHourLimit({ code: 200, data: { limits: [{ type: "TOKENS_LIMIT", percentage: 5, nextResetTime: NOW - 1 }] } }, NOW)).toBeNull(); // past reset = drift
  expect(pickFiveHourLimit({ nonsense: true }, NOW)).toBeNull();
  expect(pickFiveHourLimit(null, NOW)).toBeNull();
});

test("pickFiveHourLimit parses the Task-0c live capture", () => {
  // real captured schema (redacted); capture-time NOW_0C is recorded in the fixture README
  const cap = JSON.parse(readFileSync("tests/fixtures/glm-cap/monitor-0c.json", "utf8"));
  const NOW_0C = Number(readFileSync("tests/fixtures/glm-cap/monitor-0c.captured-at", "utf8").trim());
  const got = pickFiveHourLimit(cap, NOW_0C);
  expect(got).not.toBeNull();
  expect(got!.percentage).toBeGreaterThanOrEqual(0);
  expect(got!.percentage).toBeLessThanOrEqual(100);
});

test("fetchGlmUsage: null on blank key, non-200, network throw, drift; value on 200", async () => {
  expect(await fetchGlmUsage(undefined)).toBeNull();
  expect(await fetchGlmUsage("", (() => { throw new Error("must not be called"); }) as any)).toBeNull();
  expect(await fetchGlmUsage("k", (async () => new Response("nope", { status: 503 })) as any)).toBeNull();
  expect(await fetchGlmUsage("k", (async () => { throw new Error("ECONNREFUSED"); }) as any)).toBeNull();
  // clock INJECTED (3rd param) — pinning to the fixture's NOW keeps this
  // green on any wall-clock date (the OK resets are relative to NOW)
  const got = await fetchGlmUsage("k", (async () => Response.json(OK)) as any, NOW);
  expect(got?.percentage).toBe(84);
});
