// scripts/telegram/spawn-claudex.test.ts
import { expect, test } from "bun:test";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import {
  claudexSessionRoot,
  composeClaudexWorkerPrompt,
  composeClaudexPointerPrompt,
  planClaudexSpawn,
  planClaudexSharedSpawn,
  gitBranchExists,
  gitIsDirty,
  runClaudexSharedDispatch,
  parseClaudexArgs,
  codexBankLogPath,
  parseCodexWeeklyUsedPercent,
  fetchCodexWeeklyUsedPercent,
  parsePct,
  evaluateCodexBankPreflight,
  detectClaudexCap,
  claudexLauncherPath,
  buildClaudexRunArgs,
  claudexChildEnv,
  executeClaudexRun,
} from "./spawn-claudex";

// --- claudexSessionRoot ------------------------------------------------------

test("claudexSessionRoot is OUTSIDE the poller's sessions/ tree and distinct from the GLM sessions root", () => {
  const root = claudexSessionRoot();
  expect(root).toContain("claudex-sessions");
  expect(root).not.toContain("glm-sessions");
  expect(root).not.toContain(join("bridge", "sessions"));
});

// --- worker prompt ------------------------------------------------------------

test("composeClaudexWorkerPrompt embeds minted session paths + the no-push/no-PR contract", () => {
  const p = composeClaudexWorkerPrompt("Summarize X", "/tmp/cs/claudex-a-1", "claudex/a");
  expect(p).toContain(join("/tmp/cs/claudex-a-1", "outbox.jsonl"));
  expect(p).toContain(join("/tmp/cs/claudex-a-1", "context.md"));
  expect(p).toContain("claudex/a");
  expect(p).toMatch(/never push/i);
  expect(p).toMatch(/never open a PR/i);
  expect(p).toContain("Summarize X");
});

test("composeClaudexWorkerPrompt shared mode: teaches the no-rebase/no-new-branch/add-commits-only contract + names the branch", () => {
  const p = composeClaudexWorkerPrompt("fix the CR findings", "/tmp/cs/claudex-a-1", "feat/live-pr", { shared: true });
  expect(p).toContain("feat/live-pr");
  expect(p).toMatch(/SHARED PR branch/i);
  expect(p).toMatch(/do NOT create a new branch/i);
  expect(p).toMatch(/do NOT reset\/rebase\/amend\/force-anything/i);
  expect(p).toMatch(/ADD new commits on top only/i);
  expect(p).toMatch(/lock serializes writers/i);
  expect(p).toContain("fix the CR findings");
});

test("composeClaudexWorkerPrompt default (no opts) is UNCHANGED from the own-branch text", () => {
  const bare = composeClaudexWorkerPrompt("do X", "/tmp/cs/claudex-a-1", "claudex/a");
  const explicitFalse = composeClaudexWorkerPrompt("do X", "/tmp/cs/claudex-a-1", "claudex/a", { shared: false });
  expect(bare).toBe(explicitFalse);
  expect(bare).toContain("which is already checked out");
  expect(bare).not.toMatch(/SHARED PR branch/i);
});

test("composeClaudexPointerPrompt is SHORT and points at the brief file, not the inlined brief", () => {
  const p = composeClaudexPointerPrompt("/sess/claudex-a-1/brief.md");
  expect(p).toContain("/sess/claudex-a-1/brief.md");
  expect(p).toMatch(/claudex-lane worker/i);
  expect(p).toMatch(/execute/i);
  expect(p.split("\n").length).toBeLessThanOrEqual(3);
  expect(p.length).toBeLessThan(composeClaudexWorkerPrompt("do the thing", "/sess/claudex-a-1", "claudex/a").length);
});

// --- planClaudexSpawn ---------------------------------------------------------

test("planClaudexSpawn refuses a non-himmel cwd", () => {
  const r = planClaudexSpawn("/some/dir", undefined, { isHimmelCheckout: () => false });
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("not a himmel checkout");
  expect((r as any).reason).toContain("/some/dir");
});

test("planClaudexSpawn ok-path returns claudex/<slug> branch + .claude/worktrees/claudex+<slug> path", () => {
  const r = planClaudexSpawn("/repo", "mytask", { isHimmelCheckout: () => true });
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.slug).toBe("mytask");
  expect(ok.branch).toBe("claudex/mytask");
  expect(ok.worktree).toBe(join("/repo", ".claude", "worktrees", "claudex+mytask"));
});

test("planClaudexSpawn sanitizes slug punctuation", () => {
  const r = planClaudexSpawn("/repo", "my task/foo:bar", { isHimmelCheckout: () => true });
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.slug).toBe("my-task-foo-bar");
  expect(ok.branch).toBe("claudex/my-task-foo-bar");
});

// --- planClaudexSharedSpawn ----------------------------------------------------

const sharedOkDeps = (overrides: Partial<Parameters<typeof planClaudexSharedSpawn>[2]> = {}) => ({
  isHimmelCheckout: () => true,
  branchExists: () => true,
  worktreeOf: () => null,
  isDirty: () => false,
  ...overrides,
});

test("planClaudexSharedSpawn refuses a non-himmel cwd", () => {
  const r = planClaudexSharedSpawn("/some/dir", "feat/x", sharedOkDeps({ isHimmelCheckout: () => false }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("not a himmel checkout");
});

test("planClaudexSharedSpawn refuses a branch that does not exist, naming it — never silently mints", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/typo-branch", sharedOkDeps({ branchExists: () => false }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("--branch feat/typo-branch");
  expect((r as any).reason).toMatch(/does not exist/);
});

test("planClaudexSharedSpawn refuses main/master — never point a worker at the trunk", () => {
  expect((planClaudexSharedSpawn("/repo", "main", sharedOkDeps()) as any).ok).toBe(false);
  expect((planClaudexSharedSpawn("/repo", "master", sharedOkDeps()) as any).reason).toMatch(/trunk/);
});

test("planClaudexSharedSpawn refuses when the branch is checked out in the PRIMARY checkout", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => ({ path: "/repo", isPrimary: true }) }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toContain("primary checkout");
});

test("planClaudexSharedSpawn refuses a non-primary worktree OUTSIDE .claude/worktrees/", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => ({ path: "/some/external/checkout", isPrimary: false }) }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toMatch(/outside \.claude\/worktrees|lane-managed/);
});

test("planClaudexSharedSpawn reuses an existing non-primary worktree — needsWorktreeAdd:false", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => ({ path: "/repo/.claude/worktrees/feat+live-pr", isPrimary: false }) }));
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.needsWorktreeAdd).toBe(false);
  expect(ok.worktree).toBe("/repo/.claude/worktrees/feat+live-pr");
});

test("planClaudexSharedSpawn mints a fresh claudex+<slug> worktree path when the branch is not checked out anywhere", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => null }));
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.needsWorktreeAdd).toBe(true);
  expect(ok.worktree).toBe(join("/repo", ".claude", "worktrees", "claudex+feat-live-pr"));
});

test("planClaudexSharedSpawn refuses a REUSED worktree with uncommitted changes", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({
    worktreeOf: () => ({ path: "/repo/.claude/worktrees/feat+live-pr", isPrimary: false }),
    isDirty: () => true,
  }));
  expect(r.ok).toBe(false);
  expect((r as any).reason).toMatch(/uncommitted changes/);
});

test("planClaudexSharedSpawn does NOT check isDirty when minting a fresh worktree", () => {
  let dirtyCalled = false;
  const r = planClaudexSharedSpawn("/repo", "feat/live-pr", sharedOkDeps({ worktreeOf: () => null, isDirty: () => { dirtyCalled = true; return true; } }));
  expect(r.ok).toBe(true);
  expect(dirtyCalled).toBe(false);
});

test("planClaudexSharedSpawn sanitizes slug from the branch name", () => {
  const r = planClaudexSharedSpawn("/repo", "feat/HIMMEL-1003_shared branch", sharedOkDeps());
  expect(r.ok).toBe(true);
  const ok = r as Extract<typeof r, { ok: true }>;
  expect(ok.slug).toBe("feat-HIMMEL-1003-shared-branch");
});

// --- real git probes (mirrors spawn-glm's F1 suite) --------------------------

test("gitIsDirty: a real clean temp repo -> false; with an uncommitted file -> true", () => {
  const repo = mkdtempSync(join(tmpdir(), "cxdirty-"));
  const run = (args: string[]) => Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
  try {
    run(["init", "-b", "main"]);
    run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"]);
    expect(gitIsDirty(repo)).toBe(false);
    writeFileSync(join(repo, "untracked.txt"), "x");
    expect(gitIsDirty(repo)).toBe(true);
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("gitIsDirty (fail-closed): a non-git dir THROWS, never reads as clean", () => {
  const dir = mkdtempSync(join(tmpdir(), "cxdirty-nogit-"));
  try {
    expect(() => gitIsDirty(dir)).toThrow(/cannot determine worktree state/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("gitBranchExists: real repo — existing branch true, missing branch false", () => {
  const repo = mkdtempSync(join(tmpdir(), "cxbranch-"));
  const run = (args: string[]) => Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
  try {
    run(["init", "-b", "main"]);
    run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"]);
    run(["branch", "feat/x"]);
    expect(gitBranchExists(repo, "feat/x")).toBe(true);
    expect(gitBranchExists(repo, "feat/does-not-exist")).toBe(false);
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

// --- runClaudexSharedDispatch (mirrors spawn-glm's I6/I7 suite, lane="codex") --

function makeSharedRepo() {
  const repo = mkdtempSync(join(tmpdir(), "cxshared-"));
  const run = (args: string[], cwd: string) => Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  run(["init", "-b", "main"], repo);
  run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"], repo);
  run(["remote", "add", "origin", repo], repo);
  const wt = join(repo, ".claude", "worktrees", "claudex+feat-live-pr");
  run(["worktree", "add", "-b", "feat/live-pr", wt], repo);
  return { repo, wt, run };
}
const LOCK_SCRIPT = resolve("scripts/lib/shared-branch-lock.sh");
const lockStatus = (repo: string, branch: string) =>
  Bun.spawnSync(["bash", LOCK_SCRIPT, "status", repo, branch], { stdout: "pipe", stderr: "pipe" }).stdout.toString().trim();

test("runClaudexSharedDispatch: acquires under lane 'codex' (not 'glm'), restores prior pushurl, releases the lock", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    run(["config", "extensions.worktreeConfig", "true"], repo);
    run(["config", "--worktree", "remote.origin.pushurl", "git@example.com:orig/repo.git"], wt);
    const res = await runClaudexSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => 0 });
    expect(res.ok).toBe(true);
    if (res.ok) expect(res.code).toBe(0);
    expect(run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt).stdout.toString().trim()).toBe("git@example.com:orig/repo.git");
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runClaudexSharedDispatch: owner.json records lane 'codex'", async () => {
  const { repo, wt } = makeSharedRepo();
  try {
    let captured = "";
    await runClaudexSharedDispatch({
      repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {},
      runBody: async () => {
        const st = Bun.spawnSync(["bash", LOCK_SCRIPT, "status", repo, "feat/live-pr"], { stdout: "pipe", stderr: "pipe" });
        captured = st.stdout.toString();
        return 0;
      },
    });
    expect(captured).toContain('"lane":"codex"');
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runClaudexSharedDispatch: no prior pushurl -> UNSET after run (not left poisoned)", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    const res = await runClaudexSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => 0 });
    expect(res.ok).toBe(true);
    const got = run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt);
    expect(got.exitCode).not.toBe(0);
    expect(got.stdout.toString()).not.toContain("DISABLED-glm-quarantine");
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runClaudexSharedDispatch: runBody throwing still restores pushurl AND releases the lock", async () => {
  const { repo, wt, run } = makeSharedRepo();
  try {
    run(["config", "extensions.worktreeConfig", "true"], repo);
    run(["config", "--worktree", "remote.origin.pushurl", "git@example.com:orig/repo.git"], wt);
    await expect(runClaudexSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => { throw new Error("boom"); } }))
      .rejects.toThrow("boom");
    expect(run(["config", "--worktree", "--get", "remote.origin.pushurl"], wt).stdout.toString().trim()).toBe("git@example.com:orig/repo.git");
    expect(lockStatus(repo, "feat/live-pr")).toBe("free");
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

test("runClaudexSharedDispatch: a held lock refuses (ok:false), body never runs", async () => {
  const { repo, wt } = makeSharedRepo();
  try {
    const acq = Bun.spawnSync(["bash", LOCK_SCRIPT, "acquire", repo, "feat/live-pr", "external-holder"], { stdout: "pipe", stderr: "pipe" });
    expect(acq.exitCode).toBe(0);
    let ran = false;
    const res = await runClaudexSharedDispatch({ repoDir: repo, worktree: wt, branch: "feat/live-pr", needsWorktreeAdd: false, lockScript: LOCK_SCRIPT, gitAdd: () => {}, runBody: async () => { ran = true; return 0; } });
    expect(res.ok).toBe(false);
    expect(ran).toBe(false);
    Bun.spawnSync(["bash", LOCK_SCRIPT, "release", repo, "feat/live-pr"], { stdout: "pipe", stderr: "pipe" });
  } finally { rmSync(repo, { recursive: true, force: true }); }
});

// --- parseClaudexArgs ----------------------------------------------------------

test("parseClaudexArgs table: valid flags / positional-only / NaN timeout / trailing flag", () => {
  const full = parseClaudexArgs(["do the thing", "--cwd", "/repo", "--name", "task1", "--timeout-mins", "45", "--permission-mode", "bypassPermissions", "--effort", "high"]);
  expect(full.ok).toBe(true);
  expect((full as any).args).toMatchObject({ task: "do the thing", cwd: "/repo", name: "task1", timeoutMins: 45, permMode: "bypassPermissions", effort: "high", force: false });

  const positional = parseClaudexArgs(["just a prompt"]);
  expect(positional.ok).toBe(true);
  expect((positional as any).args.task).toBe("just a prompt");
  expect((positional as any).args.timeoutMins).toBeUndefined();

  const nan = parseClaudexArgs(["p", "--timeout-mins", "abc"]);
  expect(nan.ok).toBe(false);
  expect((nan as any).error).toMatch(/timeout-mins/);

  const nonPositive = parseClaudexArgs(["p", "--timeout-mins", "0"]);
  expect(nonPositive.ok).toBe(false);

  const trailing = parseClaudexArgs(["p", "--cwd"]);
  expect(trailing.ok).toBe(false);
  expect((trailing as any).error).toMatch(/--cwd requires a value/);

  const force = parseClaudexArgs(["p", "--force"]);
  expect(force.ok).toBe(true);
  expect((force as any).args.force).toBe(true);
});

test("parseClaudexArgs: --branch and --name are mutually exclusive", () => {
  const r = parseClaudexArgs(["p", "--branch", "feat/x", "--name", "y"]);
  expect(r.ok).toBe(false);
  expect((r as any).error).toMatch(/mutually exclusive/);
});

test("parseClaudexArgs: --effort refuses max and ultra with a docs pointer, every refusal branch", () => {
  const maxR = parseClaudexArgs(["p", "--effort", "max"]);
  expect(maxR.ok).toBe(false);
  expect((maxR as any).error).toMatch(/undocumented codex juice/);
  expect((maxR as any).error).toContain("docs/tooling-catalog.md#claude-codex");

  const ultraR = parseClaudexArgs(["p", "--effort", "ultra"]);
  expect(ultraR.ok).toBe(false);
  expect((ultraR as any).error).toMatch(/unreachable/);
  expect((ultraR as any).error).toContain("docs/tooling-catalog.md#claude-codex");

  const bogus = parseClaudexArgs(["p", "--effort", "turbo"]);
  expect(bogus.ok).toBe(false);
  expect((bogus as any).error).toMatch(/must be one of low\|medium\|high\|xhigh/);

  const trailingEffort = parseClaudexArgs(["p", "--effort"]);
  expect(trailingEffort.ok).toBe(false);
  expect((trailingEffort as any).error).toMatch(/--effort requires a value/);

  for (const v of ["low", "medium", "high", "xhigh"] as const) {
    const ok = parseClaudexArgs(["p", "--effort", v]);
    expect(ok.ok).toBe(true);
    expect((ok as any).args.effort).toBe(v);
  }
});

// --- codex weekly bank preflight (D4) -------------------------------------------

test("codexBankLogPath joins home + .codex/logs_2.sqlite", () => {
  expect(codexBankLogPath("/home/t")).toBe(join("/home/t", ".codex", "logs_2.sqlite"));
});

test("parseCodexWeeklyUsedPercent: takes the LAST secondary/used_percent occurrence, integer and decimal", () => {
  const raw = 'junk...{"primary":{"used_percent":12}}...{"secondary":{"used_percent":62,"x":1}}...garbage...{"secondary":{"used_percent":85.5,"window_minutes":10080}}...';
  expect(parseCodexWeeklyUsedPercent(raw)).toBe(85.5);
});

test("parseCodexWeeklyUsedPercent: no match -> null", () => {
  expect(parseCodexWeeklyUsedPercent("nothing here")).toBeNull();
  expect(parseCodexWeeklyUsedPercent("")).toBeNull();
});

test("parseCodexWeeklyUsedPercent: matches the live-verified shape (no space after colon)", () => {
  expect(parseCodexWeeklyUsedPercent('"secondary":{"used_percent":85,"other":1}')).toBe(85);
});

test("fetchCodexWeeklyUsedPercent: fail-open (null) when the read throws (missing/cold log)", () => {
  const throwingRead = () => { throw new Error("ENOENT"); };
  expect(fetchCodexWeeklyUsedPercent("/nonexistent/home", throwingRead)).toBeNull();
});

test("fetchCodexWeeklyUsedPercent: parses through an injected reader (no real file touched)", () => {
  const fakeRead = (path: string) => {
    expect(path).toBe(join("/home/t", ".codex", "logs_2.sqlite"));
    return '"secondary":{"used_percent":42}';
  };
  expect(fetchCodexWeeklyUsedPercent("/home/t", fakeRead)).toBe(42);
});

test("parsePct: valid/invalid/whitespace-only coercion, default fallback", () => {
  expect(parsePct("80", 999)).toBe(80);
  expect(parsePct(undefined, 80)).toBe(80);
  expect(parsePct("", 80)).toBe(80);
  expect(parsePct("  ", 80)).toBe(80); // whitespace-only must not coerce to 0
  expect(parsePct("abc", 80)).toBe(80);
  expect(parsePct("150", 80)).toBe(80); // out of [0,100]
  expect(parsePct("-1", 80)).toBe(80);
  expect(parsePct("0", 999)).toBe(0);
});

test("evaluateCodexBankPreflight: ok below warn, warn between warn/refuse, refuse at/above refuse threshold", () => {
  const opts = { warnPct: 80, refusePct: 90, override: false };
  expect(evaluateCodexBankPreflight(50, opts).action).toBe("ok");
  const warn = evaluateCodexBankPreflight(85, opts);
  expect(warn.action).toBe("warn");
  expect(warn.message).toMatch(/warn threshold 80/);
  const refuse = evaluateCodexBankPreflight(90, opts);
  expect(refuse.action).toBe("refuse");
  expect(refuse.message).toMatch(/refuse threshold 90/);
  expect(refuse.message).toMatch(/CLAUDEX_BANK_OK=1 or --force/);
});

test("evaluateCodexBankPreflight: override downgrades a refuse to warn, names the override", () => {
  const r = evaluateCodexBankPreflight(95, { warnPct: 80, refusePct: 90, override: true });
  expect(r.action).toBe("warn");
  expect(r.message).toMatch(/proceeding under override/);
});

test("evaluateCodexBankPreflight: null usedPct fails OPEN (action ok) with a visible-invisible message", () => {
  const r = evaluateCodexBankPreflight(null, { warnPct: 80, refusePct: 90, override: false });
  expect(r.action).toBe("ok");
  expect(r.usedPct).toBeNull();
  expect(r.message).toMatch(/unreadable/);
});

// --- cap detection -------------------------------------------------------------

test("detectClaudexCap: generic sentinels match, unrelated text does not", () => {
  expect(detectClaudexCap("429 usage limit reached")).toBe(true);
  expect(detectClaudexCap("please try again later")).toBe(true);
  expect(detectClaudexCap("rate limit exceeded")).toBe(true);
  expect(detectClaudexCap("some other error")).toBe(false);
  expect(detectClaudexCap("")).toBe(false);
});

// --- dispatch-command construction (D1: through claude-codex, no ANTHROPIC_*) ---

test("claudexLauncherPath joins repoRoot + scripts/claude-codex", () => {
  expect(claudexLauncherPath("/repo")).toBe(join("/repo", "scripts", "claude-codex"));
});

test("buildClaudexRunArgs: invokes bash <launcher> --permission-mode <mode> <prompt> when permMode is set", () => {
  const { cmd } = buildClaudexRunArgs("/repo/scripts/claude-codex", "read the brief", "bypassPermissions");
  expect(cmd).toEqual(["bash", "/repo/scripts/claude-codex", "--permission-mode", "bypassPermissions", "read the brief"]);
});

test("buildClaudexRunArgs: omits --permission-mode when unset — bash <launcher> <prompt>", () => {
  const { cmd } = buildClaudexRunArgs("/repo/scripts/claude-codex", "read the brief");
  expect(cmd).toEqual(["bash", "/repo/scripts/claude-codex", "read the brief"]);
});

test("buildClaudexRunArgs: NEVER includes a --model flag (claude-codex pins the model itself)", () => {
  const { cmd } = buildClaudexRunArgs("/repo/scripts/claude-codex", "p", "bypassPermissions");
  expect(cmd).not.toContain("--model");
});

test("claudexChildEnv: adds ONLY CLAUDE_CODE_EFFORT_LEVEL when effort is given, sets no ANTHROPIC_* var", () => {
  const base = { FOO: "bar", PATH: "/usr/bin" };
  const withEffort = claudexChildEnv(base, "high");
  expect(withEffort.CLAUDE_CODE_EFFORT_LEVEL).toBe("high");
  expect(withEffort.FOO).toBe("bar");
  expect(Object.keys(withEffort).some((k) => k.startsWith("ANTHROPIC_"))).toBe(false);

  const noEffort = claudexChildEnv(base);
  expect(noEffort.CLAUDE_CODE_EFFORT_LEVEL).toBeUndefined();
  expect(noEffort.FOO).toBe("bar");
});

test("claudexChildEnv: strips TELEGRAM_OWN_POLLER so a spawned worker never adopts poller ownership", () => {
  const env = claudexChildEnv({ TELEGRAM_OWN_POLLER: "1", OTHER: "x" });
  expect(env.TELEGRAM_OWN_POLLER).toBeUndefined();
  expect(env.OTHER).toBe("x");
});

test("claudexChildEnv: does not mutate the base object it was given", () => {
  const base = { TELEGRAM_OWN_POLLER: "1" };
  claudexChildEnv(base, "low");
  expect(base.TELEGRAM_OWN_POLLER).toBe("1"); // original untouched
});

// --- executeClaudexRun (finalMeta transitions, mirrors spawn-glm's F6 suite) ----

const seedRunningMeta = () => {
  const dir = mkdtempSync(join(tmpdir(), "cxexec-"));
  const metaPath = join(dir, "meta.json");
  const runningMeta = { status: "running", pid: 0, started_at: "t0", lane: "codex", task_name: "x" };
  writeFileSync(metaPath, JSON.stringify(runningMeta, null, 2));
  return { dir, metaPath, runningMeta };
};

test("executeClaudexRun: a THROWING run() transitions meta running->failed(-1) then rethrows", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const boom = (async () => { throw new Error("run exploded"); }) as any;
    await expect(executeClaudexRun({ run: boom, prompt: "p", worktree: "/wt", repoRoot: "/repo", sessionDir: dir, metaPath, runningMeta }))
      .rejects.toThrow("run exploded");
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("failed");
    expect(meta.exit_code).toBe(-1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeClaudexRun: a capped result writes status:capped", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const capped = (async () => ({ code: 0, capped: true, blocked: false, timedOut: false, pid: 99, tail: "usage limit reached" })) as any;
    const { code } = await executeClaudexRun({ run: capped, prompt: "p", worktree: "/wt", repoRoot: "/repo", sessionDir: dir, metaPath, runningMeta });
    expect(code).toBe(0);
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("capped");
    expect(meta.pid).toBe(99);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeClaudexRun: a plain failed run has status:failed", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const fail = (async () => ({ code: 1, capped: false, blocked: false, timedOut: false, pid: 5, tail: "some other error" })) as any;
    const { code } = await executeClaudexRun({ run: fail, prompt: "p", worktree: "/wt", repoRoot: "/repo", sessionDir: dir, metaPath, runningMeta });
    expect(code).toBe(1);
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("failed");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeClaudexRun: a run.log append failure does NOT flip a successful run to failed", async () => {
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    mkdirSync(join(dir, "run.log")); // force the appendFileSync to throw (EISDIR)
    const ok = (async () => ({ code: 0, capped: false, blocked: false, timedOut: false, pid: 5, tail: "done tail" })) as any;
    const { code } = await executeClaudexRun({ run: ok, prompt: "p", worktree: "/wt", repoRoot: "/repo", sessionDir: dir, metaPath, runningMeta });
    expect(code).toBe(0);
    const meta = JSON.parse(readFileSync(metaPath, "utf8"));
    expect(meta.status).toBe("done");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("executeClaudexRun: passes permMode/effort/repoRoot through to run() unchanged", async () => {
  const seen: any[] = [];
  const { dir, metaPath, runningMeta } = seedRunningMeta();
  try {
    const run = (async (prompt: string, cwd: string, opts: any) => { seen.push({ prompt, cwd, opts }); return { code: 0, capped: false, blocked: false, timedOut: false, pid: 1, tail: "" }; }) as any;
    await executeClaudexRun({ run, prompt: "the prompt", worktree: "/wt", permMode: "bypassPermissions", effort: "xhigh", repoRoot: "/repo", sessionDir: dir, metaPath, runningMeta });
    expect(seen[0]).toEqual({ prompt: "the prompt", cwd: "/wt", opts: { permMode: "bypassPermissions", effort: "xhigh", repoRoot: "/repo" } });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// --- wiring pins (main() source-text checks, mirrors spawn-glm's ordering pins) --

test("bank preflight runs BEFORE git worktree add — a refusal leaves no orphan (wiring pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-claudex.ts", "utf8");
  const bankIdx = src.indexOf("evaluateCodexBankPreflight(");
  const wtIdx = src.indexOf('"worktree", "add"');
  expect(bankIdx).toBeGreaterThan(-1);
  expect(wtIdx).toBeGreaterThan(-1);
  expect(bankIdx).toBeLessThan(wtIdx);
});

test("window preflight runs BEFORE git worktree add — a refusal leaves no orphan (wiring pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-claudex.ts", "utf8");
  const preIdx = src.indexOf("preflightWindowCheck({");
  const wtIdx = src.indexOf('"worktree", "add"');
  expect(preIdx).toBeGreaterThan(-1);
  expect(preIdx).toBeLessThan(wtIdx);
});

test("own-branch (flag-less) path mints its own branch with -b, no shared lock (regression pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-claudex.ts", "utf8");
  const ownAddIdx = src.indexOf('g(["worktree", "add", worktree, "-b", branch])');
  const dispatchIdx = src.indexOf("runClaudexSharedDispatch({");
  expect(ownAddIdx).toBeGreaterThan(-1);
  expect(dispatchIdx).toBeGreaterThan(-1);
  expect(src.includes("poisonPushUrl(absCwd, worktree)")).toBe(true);
});

test("shared-branch lock is acquired BEFORE any worktree mutation (wiring pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-claudex.ts", "utf8");
  const acquireIdx = src.indexOf('"acquire", p.repoDir, p.branch, "codex"');
  const addIdx = src.indexOf("if (p.needsWorktreeAdd) p.gitAdd()");
  const poisonIdx = src.indexOf("poisonPushUrl(p.repoDir, p.worktree)");
  expect(acquireIdx).toBeGreaterThan(-1);
  expect(acquireIdx).toBeLessThan(addIdx);
  expect(acquireIdx).toBeLessThan(poisonIdx);
});

test("no ANTHROPIC_* var is ever assigned in spawn-claudex.ts (source-text guard on the trust boundary)", () => {
  const src = readFileSync("scripts/telegram/spawn-claudex.ts", "utf8");
  // an ASSIGNMENT (env.ANTHROPIC_FOO = ..., or a JS-object key ANTHROPIC_FOO:)
  // — not a mere prose MENTION of the pattern (this file's own comments
  // reference claude-codex's ANTHROPIC_*/CLAUDE_CODE_USE_* settings screen).
  expect(/\bANTHROPIC_[A-Z_]*\s*=[^=]/.test(src)).toBe(false);
  expect(/\bANTHROPIC_[A-Z_]*\s*:/.test(src)).toBe(false);
});

test("runSharedDispatch releases the lock via a finally (wiring pin)", () => {
  const src = readFileSync("scripts/telegram/spawn-claudex.ts", "utf8");
  expect(/finally\s*\{[\s\S]*?"release", p\.repoDir, p\.branch/.test(src)).toBe(true);
});
