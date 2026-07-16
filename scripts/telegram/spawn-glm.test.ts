// scripts/telegram/spawn-glm.test.ts
import { expect, test, beforeEach } from "bun:test";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import {
  composeWorkerPrompt,
  composePointerPrompt,
  measureOverheadChars,
  SKILLS_SYSTEM_OVERHEAD_CHARS,
  preflightWindowCheck,
  detectPromptTooLong,
  transcriptDirFor,
  glmSessionRoot,
  poisonPushUrl,
  planSpawn,
  planSharedSpawn,
  gitBranchExists,
  gitIsDirty,
  runSharedDispatch,
  finalMeta,
  parseArgs,
  executeRun,
  computeResumeAt,
  toArmHHMM,
  nextRetrySlug,
  composeRespawnHandover,
  applyCarryFrom,
  buildArmArgv,
  formatUsageWarn,
  parseWarnPct,
  resolveProfileSettings,
  DEFAULT_LANE_PROFILE,
  type CapGuardDeps,
} from "./spawn-glm";
import type { SettingsConflict } from "./glm-env";
import { composeGrantLine, nextGrantId, classifyShape, authorityGate, composeEscalationForRefusedGrant } from "./grants";

test("session root is OUTSIDE the poller's sessions/ tree", () => {
  const root = glmSessionRoot();
  expect(root).toContain("glm-sessions");
  expect(root).not.toContain(`${join("bridge", "sessions")}`);
});

test("worker prompt embeds minted session paths + contract", () => {
  const p = composeWorkerPrompt("Summarize X", "/tmp/gs/glm-a-1", "glm/a");
  expect(p).toContain(join("/tmp/gs/glm-a-1", "outbox.jsonl"));
  expect(p).toContain(join("/tmp/gs/glm-a-1", "context.md"));
  expect(p).toContain("glm/a");
  expect(p).toMatch(/never push/i);
  expect(p).toMatch(/never open a PR/i);
  expect(p).toContain("Summarize X");
});

test("composeWorkerPrompt shared mode (HIMMEL-800): teaches the no-rebase/no-new-branch/add-commits-only contract + names the branch", () => {
  const p = composeWorkerPrompt("fix the CR findings", "/tmp/gs/glm-a-1", "feat/live-pr", { shared: true });
  expect(p).toContain("feat/live-pr");
  expect(p).toMatch(/SHARED PR branch/i);
  expect(p).toMatch(/do NOT create a new branch/i);
  expect(p).toMatch(/do NOT reset\/rebase\/amend\/force-anything/i);
  expect(p).toMatch(/ADD new commits on top only/i);
  expect(p).toMatch(/lock serializes writers/i);
  // still carries the shared everything-else contract (task, escalation, no-push)
  expect(p).toContain("fix the CR findings");
  expect(p).toMatch(/never push/i);
});

test("composeWorkerPrompt default (no opts / shared:false) is UNCHANGED from the own-branch text", () => {
  const bare = composeWorkerPrompt("do X", "/tmp/gs/glm-a-1", "glm/a");
  const explicitFalse = composeWorkerPrompt("do X", "/tmp/gs/glm-a-1", "glm/a", { shared: false });
  expect(bare).toBe(explicitFalse);
  expect(bare).toContain("which is already checked out");
  expect(bare).not.toMatch(/SHARED PR branch/i);
});

// --- HIMMEL-740: pointer-prompt dispatch + window preflight ---

test("composePointerPrompt is SHORT and points at the brief file, not the inlined brief (HIMMEL-740)", () => {
  const p = composePointerPrompt("/sess/glm-a-1/brief.md");
  expect(p).toContain("/sess/glm-a-1/brief.md");
  expect(p).toMatch(/GLM-lane worker/i);
  expect(p).toMatch(/execute/i);
  expect(p.split("\n").length).toBeLessThanOrEqual(3);   // 2-3 lines max
  // materially shorter than the full brief it replaces (that's the whole point)
  expect(p.length).toBeLessThan(composeWorkerPrompt("do the thing", "/sess/glm-a-1", "glm/a").length);
});

test("preflightWindowCheck: under budget passes, boundary passes, one char over refuses (HIMMEL-740)", () => {
  // small window: 200000 tokens → 90% budget = floor(180000) tokens = 720000 chars
  expect(preflightWindowCheck({ briefChars: 1000, overheadChars: 1000, windowTokens: 1_000_000 }).ok).toBe(true);
  // exactly at budget: est ceil(720000/4)=180000 == budget 180000 → refuse only when est > budget
  expect(preflightWindowCheck({ briefChars: 720_000, overheadChars: 0, windowTokens: 200_000 }).ok).toBe(true);
  // one token over the boundary → refuse, reason names the numbers + the remedy
  const over = preflightWindowCheck({ briefChars: 720_000, overheadChars: 4, windowTokens: 200_000 });
  expect(over.ok).toBe(false);
  if (!over.ok) {
    expect(over.reason).toMatch(/too large/i);
    expect(over.reason).toContain("180001");        // est tokens
    expect(over.reason).toContain("200000");        // the window
    expect(over.reason).toMatch(/chunk|--context big/i);   // the remedy
  }
});

test("measureOverheadChars: fail-open on missing bootstrap files → just the constant (HIMMEL-740)", () => {
  const cwd = mkdtempSync(join(tmpdir(), "ovh-cwd-"));
  const home = mkdtempSync(join(tmpdir(), "ovh-home-"));   // empty: no CLAUDE.md, no memory index
  try {
    expect(measureOverheadChars(cwd, home)).toBe(SKILLS_SYSTEM_OVERHEAD_CHARS);
  } finally { rmSync(cwd, { recursive: true, force: true }); rmSync(home, { recursive: true, force: true }); }
});

test("measureOverheadChars: sums the bootstrap files it can see on top of the constant (HIMMEL-740)", () => {
  const cwd = mkdtempSync(join(tmpdir(), "ovh-cwd-"));
  const home = mkdtempSync(join(tmpdir(), "ovh-home-"));
  try {
    writeFileSync(join(cwd, "CLAUDE.md"), "A".repeat(100));
    mkdirSync(join(home, ".claude"), { recursive: true });
    writeFileSync(join(home, ".claude", "CLAUDE.md"), "B".repeat(50));
    // project memory index at ~/.claude/projects/<escaped-cwd>/memory/MEMORY.md
    const memDir = join(home, ".claude", "projects", resolve(cwd).replace(/[^a-zA-Z0-9]/g, "-"), "memory");
    mkdirSync(memDir, { recursive: true });
    writeFileSync(join(memDir, "MEMORY.md"), "C".repeat(25));
    expect(measureOverheadChars(cwd, home)).toBe(SKILLS_SYSTEM_OVERHEAD_CHARS + 175);
  } finally { rmSync(cwd, { recursive: true, force: true }); rmSync(home, { recursive: true, force: true }); }
});

test("detectPromptTooLong matches the submit-reject (case-insensitive), not other errors (HIMMEL-740)", () => {
  expect(detectPromptTooLong("API Error: Prompt is too long")).toBe(true);
  expect(detectPromptTooLong("prompt is too long: 250000 tokens > 200000 maximum")).toBe(true);
  expect(detectPromptTooLong("usage limit reached")).toBe(false);
  expect(detectPromptTooLong("")).toBe(false);
});

test("main() writes the composeWorkerPrompt brief to brief.md and submits a POINTER prompt (wiring pin, HIMMEL-740)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  // the FULL brief = composeWorkerPrompt output, written to brief.md
  expect(/const briefText = composeWorkerPrompt\(/.test(src)).toBe(true);
  expect(/writeFileSync\(briefPath, briefText\)/.test(src)).toBe(true);
  // the SUBMITTED prompt is the pointer, NOT the inlined brief
  expect(/const prompt = composePointerPrompt\(briefPath\)/.test(src)).toBe(true);
});

test("window preflight runs BEFORE git worktree add — a refusal leaves no orphan (wiring pin, HIMMEL-740)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  const preIdx = src.indexOf("preflightWindowCheck({");
  const wtIdx = src.indexOf('"worktree", "add"');
  expect(preIdx).toBeGreaterThan(-1);
  expect(wtIdx).toBeGreaterThan(-1);
  expect(preIdx).toBeLessThan(wtIdx);
});

test("GLM guard check runs BEFORE git worktree add — a refusal leaves no orphan (wiring pin, #848)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  const guardIdx = src.indexOf("checkGlmGuards(");
  const wtIdx = src.indexOf('"worktree", "add"');
  const poisonIdx = src.indexOf("poisonPushUrl(absCwd");
  expect(guardIdx).toBeGreaterThan(-1);
  expect(wtIdx).toBeGreaterThan(-1);
  expect(guardIdx).toBeLessThan(wtIdx);
  expect(guardIdx).toBeLessThan(poisonIdx);
});

// --- HIMMEL-800: shared-branch mode wiring pins (main() source-text checks,
// mirroring the HIMMEL-740/#848 wiring-pin style above — these assert ORDER
// and PRESENCE of the shared-mode lock/mutation wiring that a pure unit test
// can't reach without spinning up real git + the lock script).

test("main() writes shared_branch into runningMeta only in shared mode (wiring pin, I8 typed construction)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  expect(/const runningMeta = sharedMode \? \{ \.\.\.baseMeta, shared_branch: branch \} : baseMeta;/.test(src)).toBe(true);
});

test("shared-branch lock is acquired BEFORE any worktree mutation, and main() guards before dispatching (wiring pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  // acquire → worktree add → poison ordering inside runSharedDispatch
  const acquireIdx = src.indexOf('"acquire", p.repoDir, p.branch, "glm"');
  const addIdx = src.indexOf("if (p.needsWorktreeAdd) p.gitAdd()");
  const poisonIdx = src.indexOf("poisonPushUrl(p.repoDir, p.worktree)");
  expect(acquireIdx).toBeGreaterThan(-1);
  expect(addIdx).toBeGreaterThan(-1);
  expect(poisonIdx).toBeGreaterThan(-1);
  expect(acquireIdx).toBeLessThan(addIdx);      // lock before worktree add
  expect(acquireIdx).toBeLessThan(poisonIdx);   // lock before poison
  // main() runs the GLM guard before it dispatches into the shared lifecycle
  const guardIdx = src.indexOf("checkGlmGuards(worktree)");
  const callIdx = src.indexOf("runSharedDispatch({");
  expect(guardIdx).toBeGreaterThan(-1);
  expect(callIdx).toBeGreaterThan(-1);
  expect(guardIdx).toBeLessThan(callIdx);
});

test("runSharedDispatch releases the shared-branch lock via a finally (wiring pin — every exit path after acquire)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  expect(/finally\s*\{[\s\S]*?"release", p\.repoDir, p\.branch/.test(src)).toBe(true);
});

test("main() exits 4 on a lock-acquire failure, distinct from the existing 1/2/3 codes (wiring pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  // runSharedDispatch reports the acquire failure; main() maps it to exit 4.
  expect(src.includes("if (acquire.exitCode !== 0) return { ok: false")).toBe(true);
  expect(/if \(!shared\.ok\) \{ console\.error\(shared\.reason\); process\.exit\(4\); \}/.test(src)).toBe(true);
});

test("own-branch (flag-less) path is untouched — mints its own branch with -b, no shared lock (regression pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-glm.ts", "utf8");
  const ownAddIdx = src.indexOf('g(["worktree", "add", worktree, "-b", branch])');
  const dispatchIdx = src.indexOf("runSharedDispatch({");
  expect(ownAddIdx).toBeGreaterThan(-1);      // own-branch still mints via -b
  expect(dispatchIdx).toBeGreaterThan(-1);    // shared path is separate
  // own-branch poison stays the direct call (not routed through runSharedDispatch)
  expect(src.includes("poisonPushUrl(absCwd, worktree)")).toBe(true);
});

test("transcript dir derives from escaped cwd, not slug", () => {
  const d = transcriptDirFor("C:\\Users\\alice\\Documents\\github\\himmel\\.claude\\worktrees\\glm+a");
  expect(d).toBe(join(homedir(), ".claude", "projects",
    "C--Users-alice-Documents-github-himmel--claude-worktrees-glm-a"));
});

test("transcript dir escapes EVERY non-alphanumeric (underscore too — matches real CC dirs)", () => {
  // ground truth from real CC project dirs: ...\my_docs → ...-my-docs
  const d = transcriptDirFor("C:\\Users\\alice\\Documents\\github\\my_docs");
  expect(d).toBe(join(homedir(), ".claude", "projects", "C--Users-alice-Documents-github-my-docs"));
});

test("pushurl poison makes bare git push fail in the worktree", () => {
  const repo = mkdtempSync(join(tmpdir(), "glmgit-"));
  const run = (args: string[], cwd: string) => Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  run(["init", "-b", "main"], repo);
  run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"], repo);
  run(["remote", "add", "origin", repo], repo); // self-remote: push would otherwise succeed
  const wt = join(repo, "wt");
  run(["worktree", "add", wt, "-b", "glm/x"], repo);
  // control: prove the target IS pushable pre-poison (guards against a false
  // positive from a broken remote/worktree setup)
  const control = run(["push", "--dry-run", "origin", "HEAD"], wt);
  expect(control.exitCode).toBe(0);
  poisonPushUrl(repo, wt);
  const push = run(["push", "origin", "HEAD"], wt);
  expect(push.exitCode).not.toBe(0);
  // and the failure is the POISON, not some other breakage
  expect(push.stderr.toString()).toContain("DISABLED-glm-quarantine");
  rmSync(repo, { recursive: true, force: true });
});

// --- runSharedDispatch (HIMMEL-800 I6/I7): pushurl capture/restore + lock
// lifecycle, exercised against a REAL temp git repo + worktree + the REAL lock
// script (mirrors the codex suite's section-14 pattern). ---

function makeSharedRepo() {
  const repo = mkdtempSync(join(tmpdir(), "glmshared-"));
  const run = (args: string[], cwd: string) => Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  run(["init", "-b", "main"], repo);
  run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"], repo);
  run(["remote", "add", "origin", repo], repo); // self-remote so a real push would resolve
  const wt = join(repo, ".claude", "worktrees", "glm+feat-live-pr");
  run(["worktree", "add", "-b", "feat/live-pr", wt], repo);
  return { repo, wt, run };
}
const LOCK_SCRIPT = resolve("scripts/lib/shared-branch-lock.sh");
const lockStatus = (repo: string, branch: string) =>
  Bun.spawnSync(["bash", LOCK_SCRIPT, "status", repo, branch], { stdout: "pipe", stderr: "pipe" }).stdout.toString().trim();

test("runSharedDispatch (I6a): a pre-existing worktree pushurl is restored to its exact value after a successful run, lock freed", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    run(["config", "extensions.worktreeConfig", "true"], repo);
    run(["config", "--worktree", "remote.origin.pushurl", "git@example.com:orig/repo.git"], wt);
    const res = await runSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => 0 });
    expect(res.ok).toBe(true);
    if (res.ok) expect(res.code).toBe(0);
    expect(run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt).stdout.toString().trim()).toBe("git@example.com:orig/repo.git");
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runSharedDispatch (I6b): no prior pushurl → pushurl is UNSET after run (not left poisoned)", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    const res = await runSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => 0 });
    expect(res.ok).toBe(true);
    const got = run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt);
    expect(got.exitCode).not.toBe(0);   // key absent (unset)
    expect(got.stdout.toString()).not.toContain("DISABLED-glm-quarantine");
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runSharedDispatch (I6c): runBody throwing still restores pushurl AND releases the lock", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    run(["config", "extensions.worktreeConfig", "true"], repo);
    run(["config", "--worktree", "remote.origin.pushurl", "git@example.com:orig/repo.git"], wt);
    await expect(runSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => { throw new Error("boom"); } }))
      .rejects.toThrow("boom");
    expect(run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt).stdout.toString().trim()).toBe("git@example.com:orig/repo.git"); // restored despite throw
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");                                                                                     // released despite throw
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runSharedDispatch (I2/I6d): a prior pushurl equal to the poison sentinel is treated as absent → UNSET, not re-poisoned", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    // simulate a prior crashed shared-mode run: pushurl left as the sentinel
    run(["config", "extensions.worktreeConfig", "true"], repo);
    run(["config", "--worktree", "remote.origin.pushurl", "DISABLED-glm-quarantine"], wt);
    const res = await runSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => 0 });
    expect(res.ok).toBe(true);
    const got = run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt);
    expect(got.exitCode).not.toBe(0);   // unset, NOT restored to the sentinel
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runSharedDispatch (I7): a held lock refuses (ok:false), body never runs, pre-existing owner.json intact", async () => {
  const { repo, wt } = makeSharedRepo();
  try {
    const acq = Bun.spawnSync(["bash", LOCK_SCRIPT, "acquire", repo, "feat/live-pr", "external-holder"], { stdout: "pipe", stderr: "pipe" });
    expect(acq.exitCode).toBe(0);
    let ran = false;
    const res = await runSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => { ran = true; return 0; } });
    expect(res.ok).toBe(false);
    expect(ran).toBe(false);                                       // body never ran (mirror codex 14e)
    expect(lockStatus(repo, "feat/live-pr")).toContain("external-holder"); // pre-existing lock not clobbered
    Bun.spawnSync(["bash", LOCK_SCRIPT, "release", repo, "feat/live-pr"], { stdout: "pipe", stderr: "pipe" });
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runSharedDispatch (I7): needsWorktreeAdd:true invokes gitAdd exactly once inside the lock", async () => {
  const { repo, wt } = makeSharedRepo();
  try {
    let adds = 0;
    const res = await runSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: true, lockScript: LOCK_SCRIPT, gitAdd: () => { adds++; }, runBody: async () => 0 });
    expect(res.ok).toBe(true);
    expect(adds).toBe(1);
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

// --- gitIsDirty / gitBranchExists (CR round 2 F1): the REAL git-probe
// implementations that feed planSharedSpawn's injected deps — previously only
// the injected planSharedSpawn STUB (sharedOkDeps' isDirty/branchExists) was
// exercised; these hit the real Bun.spawnSync-backed functions, including the
// FAIL-CLOSED (C3) throw path, against real git state (mirrors the
// makeSharedRepo real-temp-repo pattern used by the I6/I7 suite above).

test("gitIsDirty (F1): a real clean temp repo -> false; with an uncommitted file -> true", () => {
  const repo = mkdtempSync(join(tmpdir(), "gitdirty-"));
  const run = (args: string[]) => Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
  try {
    run(["init", "-b", "main"]);
    run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"]);
    expect(gitIsDirty(repo)).toBe(false);
    writeFileSync(join(repo, "untracked.txt"), "x");
    expect(gitIsDirty(repo)).toBe(true);
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("gitIsDirty (F1, C3 fail-closed): a non-git dir THROWS with the worktree-state message, never reads as clean", () => {
  const dir = mkdtempSync(join(tmpdir(), "gitdirty-nogit-"));
  try {
    expect(() => gitIsDirty(dir)).toThrow(/cannot determine worktree state/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("gitIsDirty (F1, C3 fail-closed): a dir with a bogus .git FILE (corrupt gitdir pointer) THROWS, not a false clean", () => {
  const dir = mkdtempSync(join(tmpdir(), "gitdirty-bogus-"));
  try {
    writeFileSync(join(dir, ".git"), "not a real gitdir pointer\n");
    expect(() => gitIsDirty(dir)).toThrow(/cannot determine worktree state/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("gitBranchExists (F1): real repo — existing branch true, missing branch false", () => {
  const repo = mkdtempSync(join(tmpdir(), "branchexists-"));
  const run = (args: string[]) => Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
  try {
    run(["init", "-b", "main"]);
    run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"]);
    run(["branch", "feat/x"]);
    expect(gitBranchExists(repo, "feat/x")).toBe(true);
    expect(gitBranchExists(repo, "feat/does-not-exist")).toBe(false);
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

// --- planSpawn / finalMeta (pure decision logic) ---

const okDeps = (overrides: Partial<Parameters<typeof planSpawn>[2]> = {}) => ({
  isHimmelCheckout: () => true,
  settingsConflicts: () => [] as SettingsConflict[],
  home: "/home/t",
  ...overrides,
});

test("planSpawn refuses a non-himmel cwd", () => {
  const r = planSpawn("/some/dir", undefined, okDeps({ isHimmelCheckout: () => false }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("not a himmel checkout");
  expect((r as any).reason).toContain("/some/dir");
});

test("planSpawn refuses on an env.ANTHROPIC_* settings conflict, naming the file+key", () => {
  const r = planSpawn("/repo", undefined, okDeps({ settingsConflicts: () => [{ file: "/home/t/.claude/settings.json", kind: "env", key: "ANTHROPIC_MODEL" }] }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("settings conflicts");
  expect((r as any).reason).toContain("/home/t/.claude/settings.json: env.ANTHROPIC_MODEL");
});

test("planSpawn downgrades a model-only conflict to a warning (ok: true)", () => {
  const r = planSpawn("/repo", "mytask", okDeps({ settingsConflicts: () => [{ file: "/home/t/.claude/settings.json", kind: "model" }] }));
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.warnings).toEqual([{ file: "/home/t/.claude/settings.json", kind: "model" }]);
  expect(ok.branch).toBe("glm/mytask");
});

test("planSpawn still refuses on an unparseable settings file (fail-closed)", () => {
  const r = planSpawn("/repo", undefined, okDeps({ settingsConflicts: () => [{ file: "/repo/.claude/settings.json", kind: "unparseable" }] }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("settings conflicts");
  expect((r as any).reason).toContain("/repo/.claude/settings.json: unparseable");
});

test("planSpawn ok-path returns glm/<slug> branch + .claude/worktrees/glm+<slug> path", () => {
  const r = planSpawn("/repo", "mytask", okDeps());
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.slug).toBe("mytask");
  expect(ok.branch).toBe("glm/mytask");
  expect(ok.worktree).toBe(join("/repo", ".claude", "worktrees", "glm+mytask"));
});

test("planSpawn sanitizes slug punctuation", () => {
  const r = planSpawn("/repo", "my task/foo:bar", okDeps());
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.slug).toBe("my-task-foo-bar");
  expect(ok.branch).toBe("glm/my-task-foo-bar");
});

// --- planSharedSpawn (HIMMEL-800: shared-branch mode) ---

const sharedOkDeps = (overrides: Partial<Parameters<typeof planSharedSpawn>[2]> = {}) => ({
  isHimmelCheckout: () => true,
  settingsConflicts: () => [] as SettingsConflict[],
  home: "/home/t",
  branchExists: () => true,
  worktreeOf: () => null,
  isDirty: () => false,
  ...overrides,
});

test("planSharedSpawn refuses a non-himmel cwd (same as planSpawn)", () => {
  const r = planSharedSpawn("/some/dir", "feat/x", sharedOkDeps({ isHimmelCheckout: () => false }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("not a himmel checkout");
});

test("planSharedSpawn refuses on a settings conflict (non-model), downgrades model to a warning", () => {
  const refused = planSharedSpawn("/repo", "feat/x", sharedOkDeps({ settingsConflicts: () => [{ file: "/home/t/.claude/settings.json", kind: "env", key: "ANTHROPIC_MODEL" }] }));
  expect(refused.ok).toBe(false);
  expect((refused as any).reason).toContain("settings conflicts");

  const warned = planSharedSpawn("/repo", "feat/x", sharedOkDeps({ settingsConflicts: () => [{ file: "/home/t/.claude/settings.json", kind: "model" }] }));
  expect(warned.ok).toBe(true);
  const ok = warned as Extract<typeof warned, { ok: true }>;
  expect(ok.warnings).toEqual([{ file: "/home/t/.claude/settings.json", kind: "model" }]);
});

test("planSharedSpawn (b) refuses a branch that does not exist, naming it — never silently mints", () => {
  const r = planSharedSpawn("/repo", "feat/typo-branch", sharedOkDeps({ branchExists: () => false }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("--branch feat/typo-branch");
  expect((r as any).reason).toMatch(/does not exist/);
});

test("planSharedSpawn (c) refuses main/master — never point a worker at the trunk", () => {
  expect((planSharedSpawn("/repo", "main", sharedOkDeps()) as any).ok).toBe(false);
  expect((planSharedSpawn("/repo", "master", sharedOkDeps()) as any).ok).toBe(false);
  expect((planSharedSpawn("/repo", "master", sharedOkDeps()) as any).reason).toMatch(/trunk/);
});

test("planSharedSpawn (d) refuses when the branch is checked out in the PRIMARY checkout", () => {
  const r = planSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => ({ path: "/repo", isPrimary: true }) }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("primary checkout");
  expect((r as any).reason).toContain("/repo");
});

test("planSharedSpawn (d) refuses a non-primary worktree OUTSIDE .claude/worktrees/ (I11: reuse is lane-scoped)", () => {
  const r = planSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => ({ path: "/some/external/checkout", isPrimary: false }) }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toMatch(/outside \.claude\/worktrees|lane-managed/);
  expect((r as any).reason).toContain("/some/external/checkout");
});

test("planSharedSpawn (d) reuses an existing non-primary worktree — needsWorktreeAdd:false", () => {
  const r = planSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => ({ path: "/repo/.claude/worktrees/feat+live-pr", isPrimary: false }) }));
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.needsWorktreeAdd).toBe(false);
  expect(ok.worktree).toBe("/repo/.claude/worktrees/feat+live-pr");
  expect(ok.branch).toBe("feat/live-pr");
});

test("planSharedSpawn (d) mints a fresh glm+<slug> worktree path when the branch is not checked out anywhere — needsWorktreeAdd:true", () => {
  const r = planSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => null }));
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.needsWorktreeAdd).toBe(true);
  expect(ok.worktree).toBe(join("/repo", ".claude", "worktrees", "glm+feat-live-pr"));
});

test("planSharedSpawn (e) refuses a REUSED worktree with uncommitted changes — clean-start requirement", () => {
  const r = planSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({
    worktreeOf: () => ({ path: "/repo/.claude/worktrees/feat+live-pr", isPrimary: false }),
    isDirty: () => true,
  }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toMatch(/uncommitted changes/);
  expect((r as any).reason).toContain("feat/live-pr");
});

test("planSharedSpawn does NOT check isDirty when minting a fresh worktree (needsWorktreeAdd:true path)", () => {
  let dirtyCalled = false;
  const r = planSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => null, isDirty: () => { dirtyCalled = true; return true; } }));
  expect(r.ok).toBe(true);
  expect(dirtyCalled).toBe(false);
});

test("planSharedSpawn (f) sanitizes slug from the branch name", () => {
  const r = planSharedSpawn("/repo", "feat/HIMMEL-800_shared branch", sharedOkDeps());
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.slug).toBe("feat-HIMMEL-800-shared-branch");
});

test("finalMeta maps exit codes to status", () => {
  expect(finalMeta(0, 42)).toEqual({ status: "done", exit_code: 0, pid: 42, timed_out: false });
  expect(finalMeta(1, 7)).toEqual({ status: "failed", exit_code: 1, pid: 7, timed_out: false });
  expect(finalMeta(-1, 9)).toEqual({ status: "failed", exit_code: -1, pid: 9, timed_out: false });
});

test("finalMeta surfaces capped/blocked and NEVER reports done when either is set", () => {
  expect(finalMeta(0, 5, true, false)).toEqual({ status: "capped", exit_code: 0, pid: 5, timed_out: false });
  expect(finalMeta(0, 5, false, true)).toEqual({ status: "blocked", exit_code: 0, pid: 5, timed_out: false });
  // capped/blocked outrank a zero exit code — a capped run is not "done"
  expect(finalMeta(0, 5, true, true).status).toBe("capped"); // capped takes precedence over blocked
  expect(finalMeta(1, 5, true, false)).toEqual({ status: "capped", exit_code: 1, pid: 5, timed_out: false });
});

test("finalMeta precedence incl. timeout", () => {
  expect(finalMeta(0, 1).status).toBe("done");
  expect(finalMeta(1, 1).status).toBe("failed");
  expect(finalMeta(-1, 1, false, false, true)).toEqual({ status: "timeout", exit_code: -1, pid: 1, timed_out: true });
  expect(finalMeta(-1, 1, true, false, true).status).toBe("capped");   // capped beats timeout
  expect(finalMeta(-1, 1, false, true, true).status).toBe("blocked");  // blocked beats timeout
  expect(finalMeta(1, 1, true).status).toBe("capped");
  expect(finalMeta(0, 1).timed_out).toBe(false);
});

// --- parseArgs (F2: pure + validated, table-driven) ---

test("parseArgs table: valid flags / positional-only / NaN timeout / trailing flag", () => {
  const full = parseArgs(["do the thing", "--cwd", "/repo", "--name", "task1", "--timeout-mins", "45", "--permission-mode", "bypassPermissions"]);
  expect(full.ok).toBe(true);
  expect((full as any).args).toMatchObject({ task: "do the thing", cwd: "/repo", name: "task1", timeoutMins: 45, permMode: "bypassPermissions" });

  const positional = parseArgs(["just a prompt"]);
  expect(positional.ok).toBe(true);
  expect((positional as any).args.task).toBe("just a prompt");
  expect((positional as any).args.timeoutMins).toBeUndefined();

  const nan = parseArgs(["p", "--timeout-mins", "abc"]);
  expect(nan.ok).toBe(false);
  expect((nan as any).error).toMatch(/timeout-mins/);

  const nonPositive = parseArgs(["p", "--timeout-mins", "0"]);
  expect(nonPositive.ok).toBe(false);

  const trailing = parseArgs(["p", "--cwd"]);
  expect(trailing.ok).toBe(false);
  expect((trailing as any).error).toMatch(/--cwd requires a value/);

  const trailingTimeout = parseArgs(["p", "--timeout-mins"]);
  expect(trailingTimeout.ok).toBe(false);
});

// --- HIMMEL-1040: --profile / --add-plugins parsing + resolution ---

test("parseArgs: profile defaults to lane-impl, addPlugins empty", () => {
  const d = parseArgs(["do it"]);
  expect((d as any).args.profile).toBe(DEFAULT_LANE_PROFILE);
  expect((d as any).args.profile).toBe("lane-impl");
  expect((d as any).args.addPlugins).toEqual([]);
});

test("parseArgs: --profile overrides, --add-plugins accumulates + splits CSV", () => {
  const r = parseArgs(["do it", "--profile", "lane-content", "--add-plugins", "a@m,b@m", "--add-plugins", "c@m"]);
  expect(r.ok).toBe(true);
  expect((r as any).args.profile).toBe("lane-content");
  expect((r as any).args.addPlugins).toEqual(["a@m", "b@m", "c@m"]);
});

test("parseArgs: --profile / --add-plugins with no value is a usage refusal", () => {
  expect(parseArgs(["p", "--profile"]).ok).toBe(false);
  expect(parseArgs(["p", "--add-plugins"]).ok).toBe(false);
});

// `installed: []` pins these to the registry alone — the live-settings default is
// covered by the plugin-profiles resolver suite + the project/local test below.
test("resolveProfileSettings: lane-impl → complete enabledPlugins JSON with floor on", () => {
  const s = resolveProfileSettings("lane-impl", [], "/nonexistent-cwd", []);
  expect(typeof s).toBe("string");
  const parsed = JSON.parse(s as string);
  expect(parsed.enabledPlugins["qmd@himmel"]).toBe(true); // floor
  expect(parsed.enabledPlugins["pr-review-toolkit-himmel@himmel"]).toBe(true);
  expect(parsed.enabledPlugins["claude-obsidian@himmel"]).toBe(false); // dropped content
});

test("resolveProfileSettings: overlay enables the named plugin", () => {
  const s = resolveProfileSettings("lane-impl", ["claude-obsidian@himmel"], "/nonexistent-cwd", []);
  expect(JSON.parse(s as string).enabledPlugins["claude-obsidian@himmel"]).toBe(true);
});

test("resolveProfileSettings: operator → undefined (no injection); operator + overlay refuses", () => {
  expect(resolveProfileSettings("operator", [], "/nonexistent-cwd", [])).toBeUndefined();
  expect(() => resolveProfileSettings("operator", ["claude-obsidian@himmel"], "/nonexistent-cwd", []))
    .toThrow(/incompatible with --add-plugins/);
});

test("main() validates the profile pre-side-effect but resolves the BASELINE from the worktree (wiring pin)", () => {
  const src = _rf("scripts/telegram/spawn-glm.ts", "utf8");
  // pre-side-effect validation passes installed:[] (pure name/overlay check)
  expect(src).toMatch(/resolveProfileSettings\(profile, addPlugins, absCwd, \[\]\)/);
  // the REAL resolve happens in runBody against the worktree the worker runs in
  expect(src).toMatch(/const settings = resolveProfileSettings\(profile, addPlugins, worktree\)/);
});

test("resolveProfileSettings: unknown profile / bad overlay id throws (main → exit 2)", () => {
  expect(() => resolveProfileSettings("nope", [], "/nonexistent-cwd", [])).toThrow(/unknown profile/);
  expect(() => resolveProfileSettings("lane-impl", ["no-marketplace"], "/nonexistent-cwd", [])).toThrow(/not a valid plugin@marketplace/);
});

test("resolveProfileSettings: a PROJECT/LOCAL-scoped plugin is explicitly disabled (deny-by-default spans all layers)", () => {
  // A plugin enabled only in <cwd>/.claude/settings.local.json and unknown to the
  // catalog must still be turned OFF for the lane — project/local scopes override
  // user scope, so missing them would let it inherit `true` in the worker.
  const dir = mkdtempSync(join(tmpdir(), "spawn-proj-"));
  try {
    mkdirSync(join(dir, ".claude"), { recursive: true });
    writeFileSync(join(dir, ".claude", "settings.json"), JSON.stringify({ enabledPlugins: { "proj-only@somewhere": true } }));
    writeFileSync(join(dir, ".claude", "settings.local.json"), JSON.stringify({ enabledPlugins: { "local-only@somewhere": true } }));
    const s = resolveProfileSettings("lane-impl", [], dir);
    const p = JSON.parse(s as string).enabledPlugins;
    expect(p["proj-only@somewhere"]).toBe(false);
    expect(p["local-only@somewhere"]).toBe(false);
    expect(p["qmd@himmel"]).toBe(true); // floor still wins
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("resolveProfileSettings: an unparseable settings layer FAILS CLOSED (main → exit 2)", () => {
  const dir = mkdtempSync(join(tmpdir(), "spawn-bad-"));
  try {
    mkdirSync(join(dir, ".claude"), { recursive: true });
    writeFileSync(join(dir, ".claude", "settings.json"), "not json");
    expect(() => resolveProfileSettings("lane-impl", [], dir)).toThrow(/cannot determine the active plugin universe/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeRun threads the resolved settings into runSession's 6th arg", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    let seen: unknown;
    const cap = (async (_p: string, _c: string, _pm: unknown, _lane: unknown, _model: unknown, settings: unknown) => {
      seen = settings;
      return { code: 0, capped: false, blocked: false, pid: 1, tail: "" };
    }) as any;
    await executeRun({ runSession: cap, prompt: "p", worktree: "/wt", sessionDir: dir, metaPath, runningMeta, settings: '{"enabledPlugins":{"qmd@himmel":true}}' });
    expect(seen).toBe('{"enabledPlugins":{"qmd@himmel":true}}');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// --- executeRun (F6: meta ALWAYS leaves "running") ---

const seedRunningMeta = () => {
  const dir = mkdtempSync(join(tmpdir(), "glmexec-"));
  const metaPath = join(dir, "meta.json");
  const runningMeta = { status: "running", pid: 0, started_at: "t0", lane: "glm", task_name: "x" };
  writeFileSync(metaPath, JSON.stringify(runningMeta, null, 2));
  return { dir, metaPath, runningMeta };
};

test("executeRun: a THROWING runSession transitions meta running→failed(-1) then rethrows", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const boom = (async () => { throw new Error("runSession exploded"); }) as any;
    await expect(executeRun({ runSession: boom, prompt: "p", worktree: "/wt", sessionDir: dir, metaPath, runningMeta }))
      .rejects.toThrow("runSession exploded");
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("failed");
    expect(meta.exit_code).toBe(-1);
    expect(meta.status).not.toBe("running");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeRun: a capped result writes status:capped (F4 wiring)", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const capped = (async () => ({ code: 0, capped: true, blocked: false, pid: 99, tail: "usage limit reached" })) as any;
    const { code } = await executeRun({ runSession: capped, prompt: "p", worktree: "/wt", sessionDir: dir, metaPath, runningMeta });
    expect(code).toBe(0);
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("capped");
    expect(meta.pid).toBe(99);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeRun: a failed run whose tail says 'prompt is too long' gets failure_class:prompt-too-long (HIMMEL-740)", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const ptl = (async () => ({ code: 1, capped: false, blocked: false, timedOut: false, pid: 5, tail: "API Error: prompt is too long: 250000 tokens > 200000 maximum" })) as any;
    const { code } = await executeRun({ runSession: ptl, prompt: "p", worktree: "/wt", sessionDir: dir, metaPath, runningMeta });
    expect(code).toBe(1);
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("failed");                    // base status unchanged (no new union member)
    expect(meta.failure_class).toBe("prompt-too-long");
    // the raw tail is preserved for cross-checking a quota-side masquerade
    expect(readFileSync(join(dir, "run.log"), "utf8")).toContain("prompt is too long");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeRun: a plain failed run (no prompt-too-long tail) has NO failure_class (HIMMEL-740)", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const fail = (async () => ({ code: 1, capped: false, blocked: false, timedOut: false, pid: 5, tail: "some other error" })) as any;
    await executeRun({ runSession: fail, prompt: "p", worktree: "/wt", sessionDir: dir, metaPath, runningMeta });
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("failed");
    expect(meta.failure_class).toBeUndefined();
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeRun: a run.log append failure does NOT flip a successful run to failed (#849)", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    // Force the cosmetic run.log append to throw (EISDIR) by making run.log a
    // directory. The append is isolated from the terminal-state write, so a
    // successful run (code 0) must stay "done", not throw into the outer catch.
    mkdirSync(join(dir, "run.log"));
    const ok = (async () => ({ code: 0, capped: false, blocked: false, timedOut: false, pid: 5, tail: "done tail" })) as any;
    const { code } = await executeRun({ runSession: ok, prompt: "p", worktree: "/wt", sessionDir: dir, metaPath, runningMeta });
    expect(code).toBe(0);
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("done");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// --- poisonPushUrl scope (CR finding F1: tripwire must be worktree-scoped, not
// repo-global). The poison sets remote.origin.pushurl via `--worktree`, which
// only lands in the worktree's private config when extensions.worktreeConfig is
// on. This pins that scope: a SIBLING worktree (shares the repo's origin config)
// and the repo-global config itself must both stay clean.

test("pushurl poison is worktree-scoped, not repo-global (sibling worktree still pushes; repo-global pushurl unset)", () => {
  const repo = mkdtempSync(join(tmpdir(), "glmgit-"));
  const run = (args: string[], cwd: string) => Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  run(["init", "-b", "main"], repo);
  run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"], repo);
  run(["remote", "add", "origin", repo], repo); // self-remote: a real push would land in-repo
  const wtPoison = join(repo, "wtp");
  const wtSibling = join(repo, "wts");
  run(["worktree", "add", wtPoison, "-b", "glm/p"], repo);
  run(["worktree", "add", wtSibling, "-b", "glm/s"], repo);
  poisonPushUrl(repo, wtPoison);
  // anchor: the poisoned worktree's push fails on the POISON
  const pushPoison = run(["push", "origin", "HEAD"], wtPoison);
  expect(pushPoison.exitCode).not.toBe(0);
  expect(pushPoison.stderr.toString()).toContain("DISABLED-glm-quarantine");
  // sibling worktree shares the repo's origin url (its own worktree config is
  // empty) → its push is UNAFFECTED. If the poison had leaked repo-global, this
  // sibling push --dry-run would hit DISABLED-glm-quarantine and fail.
  const drySibling = run(["push", "--dry-run", "origin", "HEAD"], wtSibling);
  expect(drySibling.exitCode).toBe(0);
  // direct repo-global proof: remote.origin.pushurl was never written to the
  // shared .git/config (git config --get exits 1 when the key is unset).
  const cfgGlobal = run(["config", "--get", "remote.origin.pushurl"], repo);
  expect(cfgGlobal.exitCode).not.toBe(0);
  rmSync(repo, { recursive: true, force: true });
});

// --- planSpawn refusal when ONE settings file mixes model + env.ANTHROPIC_*
// (CR finding F4: the combination is untested — assert the env conflict still
// refuses and is not masked by the co-located model downgrade).

test("planSpawn refuses when ONE settings file mixes model + env.ANTHROPIC_* (env conflict not masked by co-located model)", () => {
  const r = planSpawn("/repo", undefined, okDeps({ settingsConflicts: () => [
    { file: "/home/t/.claude/settings.json", kind: "model" },
    { file: "/home/t/.claude/settings.json", kind: "env", key: "ANTHROPIC_MODEL" },
  ] }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("settings conflicts");
  // the env refusal is surfaced (not swallowed by the model→warning downgrade)
  expect((r as any).reason).toContain("/home/t/.claude/settings.json: env.ANTHROPIC_MODEL");
});

const NOW = new Date("2026-07-03T23:40:00");
test("computeResumeAt chain + clamps", () => {
  const started = new Date(NOW.getTime() - 60 * 60_000);
  // 1. monitor wins
  let r = computeResumeAt({ now: NOW, startedAt: started, usage: { percentage: 100, nextResetTime: NOW.getTime() + 90 * 60_000 }, tail: "Your limit will reset at 1783300000000" });
  expect(r.capSource).toBe("monitor-endpoint");
  expect(r.resumeAt.getTime()).toBe(NOW.getTime() + 90 * 60_000);
  // 2. error-body next (epoch-ms form)
  const bodyTs = NOW.getTime() + 30 * 60_000;
  r = computeResumeAt({ now: NOW, startedAt: started, usage: null, tail: `429 Your limit will reset at ${bodyTs}` });
  expect(r.capSource).toBe("error-body");
  expect(r.resumeAt.getTime()).toBe(bodyTs);
  // 2b. error-body ISO form (Date.parse branch — CR round: was dead-in-test)
  r = computeResumeAt({ now: NOW, startedAt: started, usage: null, tail: "429 Your limit will reset at 2026-07-04T00:10:00Z" });
  expect(r.capSource).toBe("error-body");
  expect(r.resumeAt.getTime()).toBe(Date.parse("2026-07-04T00:10:00Z"));
  // 2c. error-body OUT of [now+2min, now+24h] falls through to cycle floor
  r = computeResumeAt({ now: NOW, startedAt: started, usage: null, tail: `429 Usage limit reached for the past 5 hours. Your limit will reset at ${NOW.getTime() + 25 * 3600_000}` });
  expect(r.capSource).toBe("cycle-floor");
  // 3. cycle floor
  r = computeResumeAt({ now: NOW, startedAt: started, usage: null, tail: "429 Usage limit reached for the past 5 hours" });
  expect(r.capSource).toBe("cycle-floor");
  expect(r.resumeAt.getTime()).toBe(started.getTime() + 5 * 3600_000);
  // floor already past -> now+2min
  const old = new Date(NOW.getTime() - 6 * 3600_000);
  r = computeResumeAt({ now: NOW, startedAt: old, usage: null });
  expect(r.resumeAt.getTime()).toBe(NOW.getTime() + 120_000);
  // monitor beyond 24h falls through to floor
  r = computeResumeAt({ now: NOW, startedAt: started, usage: { percentage: 1, nextResetTime: NOW.getTime() + 25 * 3600_000 } });
  expect(r.capSource).toBe("cycle-floor");
});

test("toArmHHMM cross-midnight + padding", () => {
  expect(toArmHHMM(new Date("2026-07-04T02:05:00"))).toBe("02:05"); // next-day date -> HH:MM; arm-resume resolves next-future occurrence
  expect(toArmHHMM(new Date("2026-07-03T09:07:00"))).toBe("09:07");
});

test("nextRetrySlug increments", () => {
  expect(nextRetrySlug("cr-sweep")).toBe("cr-sweep-r1");
  expect(nextRetrySlug("cr-sweep-r1")).toBe("cr-sweep-r2");
  expect(nextRetrySlug("cr-sweep-r9")).toBe("cr-sweep-r10");
});

test("composeRespawnHandover is self-contained + cold-start executable", () => {
  const s = composeRespawnHandover({ task: "fix ALL the things --verbatim", cwd: "C:/repo", slug: "job-r1", timeoutMins: 60, permMode: "bypassPermissions", sessionDir: "C:/sess/glm-job-123", branch: "glm/job", resumeAtIso: "2026-07-04T02:10:00.000Z" });
  expect(s).toContain("type: handover");
  expect(s).toContain("armed-by: spawn-glm cap guard");
  expect(s).toContain("resume_cwd: C:/repo");
  expect(s).toContain("fix ALL the things --verbatim");                       // verbatim task
  expect(s).toContain('--cwd C:/repo --name job-r2 --timeout-mins 60 --permission-mode bypassPermissions'); // next -rN
  expect(s).toContain("C:/sess/glm-job-123");                                  // capped session dir
  expect(s).toContain("glm/job");                                              // branch-state instruction anchor
  expect(s).toMatch(/already .*(validated|merged)/i);                          // re-check-before-respend
});

test("composeRespawnHandover emits --carry-from <capped sessionDir> (HIMMEL-682)", () => {
  const s = composeRespawnHandover({ task: "t", cwd: "C:/repo", slug: "job-r1", sessionDir: "C:/sess/glm-job-123", branch: "glm/job", resumeAtIso: "2026-07-04T02:10:00.000Z" });
  expect(s).toContain("--carry-from C:/sess/glm-job-123");   // carry the capped session's grants forward
  expect(s).toMatch(/-r\d+/);                                 // -rN name preserved
});

test("composeRespawnHandover (HIMMEL-1040): carries a non-default --profile + --add-plugins; omits both on defaults", () => {
  const withProfile = composeRespawnHandover({ task: "t", cwd: "C:/repo", slug: "job-r1", sessionDir: "C:/s", branch: "glm/job", resumeAtIso: "2026-07-04T02:10:00.000Z", profile: "lane-content", addPlugins: ["a@m", "b@m"] });
  expect(withProfile).toContain("--profile lane-content");
  expect(withProfile).toContain("--add-plugins a@m,b@m");
  // the lane-impl default + empty overlay add no flags (keeps the respawn lean)
  const dflt = composeRespawnHandover({ task: "t", cwd: "C:/repo", slug: "job-r1", sessionDir: "C:/s", branch: "glm/job", resumeAtIso: "2026-07-04T02:10:00.000Z", profile: DEFAULT_LANE_PROFILE, addPlugins: [] });
  expect(dflt).not.toContain("--profile");
  expect(dflt).not.toContain("--add-plugins");
});

test("composeRespawnHandover shared mode (HIMMEL-800): re-dispatch command carries --branch, not --name -rN", () => {
  const s = composeRespawnHandover({ task: "t", cwd: "C:/repo", slug: "feat-live-pr", sessionDir: "C:/sess/glm-feat-live-pr-123", branch: "feat/live-pr", resumeAtIso: "2026-07-04T02:10:00.000Z", shared: true });
  expect(s).toContain("--branch feat/live-pr");
  expect(s).not.toMatch(/--name /);
  expect(s).toMatch(/shared worktree/i);
  expect(s).toContain("--carry-from C:/sess/glm-feat-live-pr-123");
});

// --- cap-guard orchestration (Task 6) ---
// fresh per test (beforeEach): a scratch session dir + meta path
let sd: string, mp: string, wt: string;
const rm = { status: "running", pid: 0, started_at: "2026-07-03T18:00:00.000Z", lane: "glm", task_name: "job" };
beforeEach(() => {
  sd = mkdtempSync(join(tmpdir(), "capguard-")); mp = join(sd, "meta.json"); wt = sd;
  // WS9 (HIMMEL-654): the cap-time path now appendQuotaGauge()s a GLM row; redirect
  // the ledger into the scratch dir so the suite never touches the real
  // ~/.himmel/quota-gauge.jsonl (hermetic).
  process.env.HIMMEL_QUOTA_GAUGE_LEDGER = join(sd, "quota-gauge.jsonl");
});
// a stub runSession resolving a capped result with the given tail
const cappedRun = (tail: string) => async () => ({ code: 1, capped: true, blocked: false, timedOut: false, pid: 7, tail });

function guardDeps(over: Partial<CapGuardDeps> = {}): CapGuardDeps {
  return { startedAt: new Date(Date.now() - 3600_000), task: "t", cwd: "C:/repo", slug: "job", branch: "glm/job", armOnCap: true, fetchUsage: async () => null, arm: () => 0, ...over };
}
const T5H = "429 Usage limit reached for the past 5 hours";
const TLONG = "429 Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-08-01T00:00:00Z";
const TGENERIC = "Claude usage limit reached";

test("5h cap: meta fields + arm invoked with snapshot", async () => {
  const calls: any[] = [];
  await executeRun({ runSession: cappedRun(T5H) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: (h, p2) => { calls.push([h, p2]); return 0; } }) });
  const meta = JSON.parse(readFileSync(mp, "utf8"));
  expect(meta.status).toBe("capped");
  expect(meta.cap_window).toBe("5h");
  expect(meta.cap_source).toBe("cycle-floor");
  expect(meta.resume_at).toBeTruthy();
  expect(calls.length).toBe(1);
  expect(calls[0][1]).toContain("respawn-handover.md");
  expect(existsSync(join(sd, "respawn-handover.md"))).toBe(true);
});

test("F2 (CR round 2): a capped SHARED run's respawn-handover.md carries --branch <branch>, not --name <slug>-rN (capGuard.shared threading end-to-end)", async () => {
  const calls: any[] = [];
  await executeRun({ runSession: cappedRun(T5H) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ shared: true, branch: "feat/live-pr", arm: (h, p2) => { calls.push([h, p2]); return 0; } }) });
  expect(calls.length).toBe(1);
  const snap = readFileSync(join(sd, "respawn-handover.md"), "utf8");
  expect(snap).toContain("--branch feat/live-pr");
  expect(snap).not.toMatch(/--name /);
});

test("generic cap arms like 5h with cap_window generic", async () => {
  const calls: any[] = [];
  await executeRun({ runSession: cappedRun(TGENERIC) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: (h, p2) => { calls.push([h, p2]); return 0; } }) });
  const meta = JSON.parse(readFileSync(mp, "utf8"));
  expect(meta.cap_window).toBe("generic");
  expect(meta.resume_at).toBeTruthy();
  expect(calls.length).toBe(1);
});

test("long-window cap: labeled, NO resume_at, NO arm, ONE cap-long ledger row", async () => {
  const calls: any[] = [];
  await executeRun({ runSession: cappedRun(TLONG) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: () => { calls.push(1); return 0; } }) });
  const meta = JSON.parse(readFileSync(mp, "utf8"));
  expect(meta.status).toBe("capped");
  expect(meta.cap_window).toBe("long");
  expect(meta.cap_source).toBe("no-arm-long-window");
  expect(meta.resume_at).toBeUndefined();
  expect(calls.length).toBe(0);
  // HIMMEL-690 chunk B: a long-window (weekly/monthly/balance/expired) cap
  // writes exactly ONE passive ledger row (source cap-long, window "long" —
  // the detector cannot distinguish weekly from monthly, so a specific
  // sub-window would be fabricated precision, CR [codex-1]); no new fetch,
  // glm_peak stamped from now. Ledger isolated to the scratch dir by
  // beforeEach (HIMMEL_QUOTA_GAUGE_LEDGER) — the real ~/.himmel file is never touched.
  const rows = readFileSync(process.env.HIMMEL_QUOTA_GAUGE_LEDGER!, "utf8").split("\n").filter(Boolean);
  expect(rows.length).toBe(1);
  const row = JSON.parse(rows[0]);
  expect(row.lane).toBe("glm");
  expect(row.source).toBe("cap-long");
  expect(row.window).toBe("long");
});

test("arm rc=3 is success; rc=4 warns but exit code unchanged", async () => {
  const r3 = await executeRun({ runSession: cappedRun(T5H) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: () => 3 }) });
  expect(r3.code).toBe(1); // the worker's own exit code, not the arm's
  const r4 = await executeRun({ runSession: cappedRun(T5H) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: () => 4 }) });
  expect(r4.code).toBe(1);
  expect(JSON.parse(readFileSync(mp, "utf8")).resume_at).toBeTruthy(); // breadcrumb survives a failed arm
});

test("--no-arm-on-cap writes resume_at but never arms", async () => {
  const calls: any[] = [];
  await executeRun({ runSession: cappedRun(T5H) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ armOnCap: false, arm: () => { calls.push(1); return 0; } }) });
  expect(JSON.parse(readFileSync(mp, "utf8")).resume_at).toBeTruthy();
  expect(calls.length).toBe(0);
});

test("parseArgs arm flags", () => {
  expect((parseArgs(["t"]) as any).args.armOnCap).toBe(true);
  expect((parseArgs(["t", "--no-arm-on-cap"]) as any).args.armOnCap).toBe(false);
  expect((parseArgs(["t", "--arm-on-cap"]) as any).args.armOnCap).toBe(true);
});

test("buildArmArgv matches arm-resume's documented flag contract", () => {
  const a = buildArmArgv("C:/repo", "04:10", "C:/sess/respawn-handover.md");
  expect(a[0]).toBe("bash");
  expect(a[1]).toContain("arm-resume.sh");
  expect(a.slice(2)).toEqual(["--dedup-any", "--time", "04:10", "--handover", "C:/sess/respawn-handover.md"]);
});

test("formatUsageWarn tiers", () => {
  expect(formatUsageWarn(null, 80)).toBe("spawn-glm: usage invisible (monitor endpoint unavailable)");
  expect(formatUsageWarn({ percentage: 30, nextResetTime: Date.now() + 3600_000 }, 80)).toBeNull();
  const w = formatUsageWarn({ percentage: 91, nextResetTime: Date.now() + 3600_000, level: "pro" }, 80)!;
  expect(w).toContain("91%");
  expect(w).toContain("pro");
  expect(w).toMatch(/\d{2}:\d{2}/); // local reset render
});

test("parseWarnPct coercion", () => {
  expect(parseWarnPct("90")).toBe(90);
  expect(parseWarnPct("abc")).toBe(80);
  expect(parseWarnPct("")).toBe(80);
  expect(parseWarnPct(undefined)).toBe(80);
  expect(parseWarnPct("-5")).toBe(80);   // out of [0,100] -> default
  expect(parseWarnPct("101")).toBe(80);
  expect(parseWarnPct("   ")).toBe(80);  // whitespace-only must NOT coerce to 0 (= warn-always)
  expect(parseWarnPct(" 90 ")).toBe(90); // trimmed numeric still accepted
});

test("capGuard wired but run NOT capped: no cap fields, no arm (spurious-arm guard)", async () => {
  const calls: unknown[] = [];
  const okRun = async () => ({ code: 0, capped: false, blocked: false, timedOut: false, pid: 7, tail: "all done" });
  await executeRun({ runSession: okRun as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: () => { calls.push(1); return 0; } }) });
  const meta = JSON.parse(readFileSync(mp, "utf8"));
  expect(meta.status).toBe("done");
  expect(meta.cap_window).toBeUndefined();
  expect(meta.resume_at).toBeUndefined();
  expect(meta.cap_source).toBeUndefined();
  expect(calls.length).toBe(0);
});

test("a THROWING arm preserves capped meta + exit code (Bun.spawnSync throw class)", async () => {
  const r = await executeRun({ runSession: cappedRun(T5H) as any, prompt: "p", worktree: wt, sessionDir: sd, metaPath: mp, runningMeta: rm, capGuard: guardDeps({ arm: () => { throw new Error("spawn ENOENT: bash unresolvable"); } }) });
  expect(r.code).toBe(1); // the worker's own exit code, not the arm's throw
  const meta = JSON.parse(readFileSync(mp, "utf8"));
  expect(meta.status).toBe("capped");           // NOT clobbered to failed by the outer catch
  expect(meta.resume_at).toBeTruthy();          // breadcrumb survives
  expect(meta.cap_source).toBe("cycle-floor");
});

// WS9 Task 6: the GLM writer is wired at cap-guard's two existing fetchGlmUsage
// call-sites — no new fetch, no new poll (AC1-wiring / AC9). Source-pinned so a
// future refactor that drops a call-site fails loudly.
test("WS9 Task 6: both fetchGlmUsage call-sites appendQuotaGauge(buildGlmRow(...)) (wiring pin)", () => {
  const src = readFileSync(join(import.meta.dir, "spawn-glm.ts"), "utf8");
  // cap-time site: append immediately after the existing re-query
  expect(/const usage = await g\.fetchUsage\(\);\s*\n\s*appendQuotaGauge\(buildGlmRow\(usage,/.test(src)).toBe(true);
  // preflight site: append on the reading formatUsageWarn already consumes,
  // GUARDED (runs before the worktree exists -> a throw must not abort dispatch)
  expect(/try\s*\{\s*appendQuotaGauge\(buildGlmRow\(preflightUsage,/.test(src)).toBe(true);
  // still exactly the two pre-existing fetchGlmUsage uses (fn call + closure) — no NEW poll added
  expect((src.match(/fetchGlmUsage\(/g) ?? []).length).toBe(2);
});

test("worker child env carries GLM_SESSION_DIR (inherited-env seam, spec D5)", async () => {
  // Task 0 seam confirmation: sessionEnv('glm') spreads process.env, so a
  // GLM_SESSION_DIR set on process.env before runSession propagates to the child.
  const { sessionEnv } = await import("./run");
  const prev = process.env.GLM_SESSION_DIR;
  process.env.GLM_SESSION_DIR = "C:/sess/glm-probe-1";
  try {
    const env = sessionEnv("glm");
    expect(env.GLM_SESSION_DIR).toBe("C:/sess/glm-probe-1");
  } finally {
    if (prev === undefined) delete process.env.GLM_SESSION_DIR; else process.env.GLM_SESSION_DIR = prev;
  }
});

import { readFileSync as _rf } from "node:fs";
test("spawn-glm main() sets process.env.GLM_SESSION_DIR before executeRun (wiring pin)", () => {
  const src = _rf("scripts/telegram/spawn-glm.ts", "utf8");
  const setIdx = src.indexOf("process.env.GLM_SESSION_DIR = sessionDir");
  const runIdx = src.indexOf("executeRun({");
  expect(setIdx).toBeGreaterThan(-1);           // the wiring exists
  expect(setIdx).toBeLessThan(runIdx);          // …and precedes the run
});

test("T1 parseArgs collects repeatable --grant + rejects malformed", () => {
  const ok = parseArgs(["job", "--grant", "gh|gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)", "--grant", "git-push|git([[:space:]]+-[a-z-]+)*[[:space:]]+push([[:space:]]|$)|30|2"]);
  expect(ok.ok).toBe(true); if (ok.ok) { expect(ok.args.grants.length).toBe(2); expect(ok.args.grants[1].maxUses).toBe(2); }
  const bad = parseArgs(["job", "--grant", "gh|.*"]);
  expect(bad.ok).toBe(false);                          // fails §D4 validity gate -> usage refusal
  expect((parseArgs(["job", "--autonomous"]) as any).args.autonomous).toBe(true);
  expect((parseArgs(["job"]) as any).args.autonomous).toBe(false);
});

test("parseArgs --carry-from (HIMMEL-682): value captured, required", () => {
  const ok = parseArgs(["job", "--carry-from", "/s/dir"]);
  expect(ok.ok).toBe(true); if (ok.ok) expect(ok.args.carryFrom).toBe("/s/dir");
  expect((parseArgs(["job"]) as any).args.carryFrom).toBeUndefined();
  expect(parseArgs(["job", "--carry-from"]).ok).toBe(false);   // --carry-from requires a value
});

test("parseArgs --branch (HIMMEL-800): value captured, missing value refuses, mutually exclusive with --name", () => {
  const ok = parseArgs(["job", "--branch", "feat/live-pr"]);
  expect(ok.ok).toBe(true);
  if (ok.ok) expect(ok.args.branch).toBe("feat/live-pr");
  expect((parseArgs(["job"]) as any).args.branch).toBeUndefined();

  const trailing = parseArgs(["job", "--branch"]);
  expect(trailing.ok).toBe(false);
  expect((trailing as any).error).toMatch(/--branch requires a value/);

  const both = parseArgs(["job", "--branch", "feat/x", "--name", "t1"]);
  expect(both.ok).toBe(false);
  expect((both as any).error).toMatch(/--branch and --name are mutually exclusive/);
  // order-independent
  const bothReversed = parseArgs(["job", "--name", "t1", "--branch", "feat/x"]);
  expect(bothReversed.ok).toBe(false);
});

test("parseArgs --context big|small (HIMMEL-718): value captured, validated, default undefined", () => {
  expect((parseArgs(["t", "--context", "big"]) as any).args.context).toBe("big");
  expect((parseArgs(["t", "--context", "small"]) as any).args.context).toBe("small");
  // parseArgs leaves context unset when omitted; main() applies the big default.
  expect((parseArgs(["t"]) as any).args.context).toBeUndefined();
  const invalid = parseArgs(["t", "--context", "huge"]);
  expect(invalid.ok).toBe(false);
  expect((invalid as any).error).toMatch(/--context must be big or small/);
  const trailing = parseArgs(["t", "--context"]);
  expect(trailing.ok).toBe(false);
  expect((trailing as any).error).toMatch(/--context requires a value/);
});

// applyCarryFrom (HIMMEL-682) — exercises the autonomousEff→gate SECURITY wiring
// end-to-end against a real temp dir (pr-test-analyzer I1), not just inspection.
const GH_READ_P = "gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)";
const GP_WRITE_P = "git([[:space:]]+-[a-z-]+)*[[:space:]]+push([[:space:]]|$)";
const carryLine = (o: Record<string, unknown>) => JSON.stringify({ type: "grant", capability: "cap", shape: "read", granted_by: "operator", expires_at: "2999-01-01T00:00:00Z", ...o });

test("applyCarryFrom: shape-split against a real temp dir — autonomous seeds read, re-escalates write", () => {
  const dir = mkdtempSync(join(tmpdir(), "carry-"));
  writeFileSync(join(dir, "grants.jsonl"),
    carryLine({ grant_id: "g1", arm: "gh", pattern: GH_READ_P, max_uses: 2 }) + "\n" +
    carryLine({ grant_id: "g2", arm: "git-push", pattern: GP_WRITE_P, max_uses: 2 }) + "\n");
  const now = new Date("2026-07-04T09:00:00Z");
  const auto = applyCarryFrom(dir, true, [], now);
  expect(auto.grantLines.length).toBe(1);        // read seeded
  expect(auto.escalationLines.length).toBe(1);   // write re-escalated under autonomous authority
  expect(JSON.parse(auto.grantLines[0]).shape).toBe("read");
  expect(auto.summary).toContain("carried 1 grant");
  const op = applyCarryFrom(dir, false, [], now);
  expect(op.grantLines.length).toBe(2);          // operator present → both seed
  rmSync(dir, { recursive: true, force: true });
});

test("applyCarryFrom: missing grants.jsonl → no carry, no throw (F4 reset)", () => {
  const dir = mkdtempSync(join(tmpdir(), "carry-"));  // empty — no grants.jsonl
  const r = applyCarryFrom(dir, true, [], new Date());
  expect(r.grantLines.length).toBe(0);
  expect(r.summary).toContain("no grants.jsonl");
  rmSync(dir, { recursive: true, force: true });
});

test("applyCarryFrom: unreadable grants.jsonl (EISDIR) → fail-open, no throw (codex-7)", () => {
  const dir = mkdtempSync(join(tmpdir(), "carry-"));
  mkdirSync(join(dir, "grants.jsonl"));   // a DIRECTORY named grants.jsonl → readFileSync throws EISDIR
  const r = applyCarryFrom(dir, true, [], new Date());   // must NOT throw
  expect(r.grantLines.length).toBe(0);
  expect(r.summary).toContain("unreadable");
  rmSync(dir, { recursive: true, force: true });
});

test("T9 writer path: autonomous refuses write grant -> escalation line, NO grant line; read grant is written", () => {
  const now = new Date("2026-07-03T18:30:04.210Z");
  const write = { arm: "git-push", pattern: "git([[:space:]]+-[a-z-]+)*[[:space:]]+push([[:space:]]|$)", ttlMins: 60, maxUses: 1 } as const;
  const read  = { arm: "gh", pattern: "gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)", ttlMins: 60, maxUses: 1 } as const;
  // (a) write-shaped + autonomous -> pending-escalation -> escalation line, NO grant line
  expect(authorityGate(classifyShape(write.arm, write.pattern), true)).toEqual({ action: "pending-escalation" });
  const esc = JSON.parse(composeEscalationForRefusedGrant({ capability: write.pattern, arm: write.arm, reason: "autonomous refuses write grant", step: "pre-seed", now }));
  expect(esc.type).toBe("escalation"); expect(esc.arm).toBe("git-push"); expect(esc.capability).toBe(write.pattern);
  // (b) read-shaped + autonomous -> grant -> grant line written
  expect(authorityGate(classifyShape(read.arm, read.pattern), true)).toEqual({ action: "grant" });
  const g = JSON.parse(composeGrantLine(read, { capability: read.pattern, grantId: "g1", grantedBy: "parent:spawn-glm", now }));
  expect(g.type).toBe("grant"); expect(g.shape).toBe("read");
});

test("grant_id accumulates across repeated pre-seed grants (distinct g1/g2)", () => {
  // the pre-seed loop must feed the GROWING line-set into nextGrantId, not the empty file each time
  const read = { arm: "gh", pattern: "gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)", ttlMins: 60, maxUses: 1 } as const;
  const l1 = composeGrantLine(read, { capability: "c", grantId: nextGrantId([]),   grantedBy: "parent:spawn-glm", now: new Date() });
  const l2 = composeGrantLine(read, { capability: "c", grantId: nextGrantId([l1]), grantedBy: "parent:spawn-glm", now: new Date() });
  expect(JSON.parse(l1).grant_id).toBe("g1");
  expect(JSON.parse(l2).grant_id).toBe("g2");
});

test("T5 composeWorkerPrompt teaches the escalation contract", () => {
  const p = composeWorkerPrompt("do X", "/tmp/gs/glm-a-1", "glm/a");
  expect(p).toMatch(/escalation/i);
  expect(p).toContain('"type":"escalation"');
  expect(p).toMatch(/git-push.*git-url.*gh.*network|arm/i);   // the arm enum is named
  expect(p).toMatch(/skip/i);                                  // skip the gated step
  expect(p).toMatch(/continue|context\.md/i);                  // continue + note it
});
