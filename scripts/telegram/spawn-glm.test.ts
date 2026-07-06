// scripts/telegram/spawn-glm.test.ts
import { expect, test, beforeEach } from "bun:test";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import {
  composeWorkerPrompt,
  transcriptDirFor,
  glmSessionRoot,
  poisonPushUrl,
  planSpawn,
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
