// scripts/telegram/spawn-glm.test.ts
import { expect, test } from "bun:test";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import {
  composeWorkerPrompt,
  transcriptDirFor,
  glmSessionRoot,
  poisonPushUrl,
  planSpawn,
  finalMeta,
  parseArgs,
  executeRun,
} from "./spawn-glm";
import type { SettingsConflict } from "./glm-env";

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

test("transcript dir derives from escaped cwd, not slug", () => {
  const d = transcriptDirFor("C:\\Users\\yotam\\Documents\\github\\himmel\\.claude\\worktrees\\glm+a");
  expect(d).toBe(join(homedir(), ".claude", "projects",
    "C--Users-yotam-Documents-github-himmel--claude-worktrees-glm-a"));
});

test("transcript dir escapes EVERY non-alphanumeric (underscore too — matches real CC dirs)", () => {
  // ground truth on this machine: ...\my_notes → ...-my-notes
  const d = transcriptDirFor("C:\\Users\\yotam\\Documents\\github\\my_notes");
  expect(d).toBe(join(homedir(), ".claude", "projects", "C--Users-yotam-Documents-github-my-notes"));
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

test("finalMeta maps exit codes to status", () => {
  expect(finalMeta(0, 42)).toEqual({ status: "done", exit_code: 0, pid: 42 });
  expect(finalMeta(1, 7)).toEqual({ status: "failed", exit_code: 1, pid: 7 });
  expect(finalMeta(-1, 9)).toEqual({ status: "failed", exit_code: -1, pid: 9 });
});

test("finalMeta surfaces capped/blocked and NEVER reports done when either is set", () => {
  expect(finalMeta(0, 5, true, false)).toEqual({ status: "capped", exit_code: 0, pid: 5 });
  expect(finalMeta(0, 5, false, true)).toEqual({ status: "blocked", exit_code: 0, pid: 5 });
  // capped/blocked outrank a zero exit code — a capped run is not "done"
  expect(finalMeta(0, 5, true, true).status).toBe("capped"); // capped takes precedence over blocked
  expect(finalMeta(1, 5, true, false)).toEqual({ status: "capped", exit_code: 1, pid: 5 });
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
