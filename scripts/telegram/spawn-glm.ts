// scripts/telegram/spawn-glm.ts
// Poller-free GLM worker spawn (HIMMEL-654 offload spike; spec D4). Owns the
// glue the poller provides for bridge runs: prompt composition (minted session
// paths), run.log persistence from the returned tail, meta.json transitions.
// Sessions live under <BRIDGE_ROOT>/glm-sessions/ — the live poller scans ONLY
// <root>/sessions/, so nothing here can be double-spawned or Telegram-flushed.
import { existsSync, mkdirSync, writeFileSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { runSession, REPO_ROOT, type PermissionMode } from "./run";
import { checkGlmGuards } from "./glm-guard";
import { buildGlmEnv, findSettingsConflicts, formatConflict, type SettingsConflict } from "./glm-env";

export function glmSessionRoot(): string {
  return join(process.env.BRIDGE_ROOT ?? join(homedir(), ".claude", "handover", "bridge"), "glm-sessions");
}

// Claude Code keys transcript dirs by the ESCAPED CWD — EVERY non-alphanumeric
// char → "-" (ground truth: real project dirs escape "_" and "." too, e.g.
// my_docs → my-docs). Not keyed by any name/slug.
export function transcriptDirFor(cwd: string): string {
  return join(homedir(), ".claude", "projects", resolve(cwd).replace(/[^a-zA-Z0-9]/g, "-"));
}

export function composeWorkerPrompt(task: string, sessionDir: string, branch: string): string {
  const outbox = join(sessionDir, "outbox.jsonl");
  const context = join(sessionDir, "context.md");
  return [
    `You are an unattended GLM-lane worker session (himmel offload spike).`,
    `Work ONLY inside your current directory (a dedicated git worktree). Commit your work on the branch ${branch} which is already checked out.`,
    `HARD RULES: never push, never open a PR, never write to Jira or any external tracker — a validating session reviews your branch and owns all external writes.`,
    `Report progress by APPENDING one JSON line {"text":"<note>"} per update to ${outbox}. That is the only channel to the operator.`,
    `THE TASK: ${task}`,
    `As your FINAL action, append a one-line summary of what you did to ${context}, then stop.`,
  ].join("\n");
}

// Default-path push tripwire (spec D4 — honest scope: blocks accidental/default
// pushes only; the load-bearing control is the CR gate). extensions.worktreeConfig
// is a REPO-GLOBAL toggle (documented, left permanent).
export function poisonPushUrl(repoRoot: string, worktree: string): void {
  const g = (args: string[], cwd: string) => { const r = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" }); if (r.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${r.stderr.toString()}`); };
  g(["config", "extensions.worktreeConfig", "true"], repoRoot);
  g(["config", "--worktree", "remote.origin.pushurl", "DISABLED-glm-quarantine"], worktree);
}

export type SpawnPlan = { ok: true; slug: string; worktree: string; branch: string; warnings: SettingsConflict[] } | { ok: false; reason: string };
// Pure decision logic — deps injected so every refusal branch is testable.
export function planSpawn(
  cwd: string, name: string | undefined,
  deps: { isHimmelCheckout: (d: string) => boolean; settingsConflicts: (files: string[]) => SettingsConflict[]; home: string },
): SpawnPlan {
  if (!deps.isHimmelCheckout(cwd)) return { ok: false, reason: `spawn-glm: ${cwd} is not a himmel checkout (v1 scope: himmel repo only)` };
  const conflicts = deps.settingsConflicts([
    join(deps.home, ".claude", "settings.json"),
    // checkout layers ≡ the worktree's at branch time; settings.local.json is
    // gitignored and lives ONLY in the checkout — checking here is intentional.
    join(cwd, ".claude", "settings.json"),
    join(cwd, ".claude", "settings.local.json"),
  ]);
  // A settings `model` key is downgraded to a WARNING: the CLI's explicit
  // --model flag beats a settings model key, and under the GLM env block a lost
  // precedence fails loudly at the endpoint, never silently (spec amendment,
  // acceptance finding). env (silent-wrong-lane) and unparseable (fail-closed)
  // stay HARD REFUSALS. Keyed on the structured `kind`, not a formatted string.
  const warnings = conflicts.filter((c) => c.kind === "model");
  const refusals = conflicts.filter((c) => c.kind !== "model");
  if (refusals.length) return { ok: false, reason: `spawn-glm: settings conflicts (remove these keys first): ${refusals.map(formatConflict).join("; ")}` };
  const slug = (name?.trim() || `t${Date.now()}`).replace(/[^a-zA-Z0-9-]/g, "-");
  return { ok: true, slug, worktree: join(cwd, ".claude", "worktrees", `glm+${slug}`), branch: `glm/${slug}`, warnings };
}

// A capped/blocked run must NEVER surface as `done`: capped (usage limit) and
// blocked (content filter) are distinct terminal states the caller inspects.
export function finalMeta(code: number, pid: number, capped?: boolean, blocked?: boolean): { status: "done" | "failed" | "capped" | "blocked"; exit_code: number; pid: number } {
  const status = capped ? "capped" : blocked ? "blocked" : code === 0 ? "done" : "failed";
  return { status, exit_code: code, pid };
}

// isHimmelCheckout real impl: a himmel checkout carries the GLM launcher.
function isHimmelCheckout(d: string): boolean {
  return existsSync(join(d, "scripts", "claude-glm"));
}

export type ParsedArgs = { task?: string; cwd: string; name?: string; timeoutMins?: number; permMode?: PermissionMode };
// Pure + validated: a value-taking flag with no value, or a non-positive /
// non-finite --timeout-mins, is a USAGE REFUSAL (main → exit 2) — NOT a silent
// NaN that setTimeout(NaN)≈0 turns into an instant kill, and NOT a bare
// resolve() throw from a trailing --cwd with no value.
export function parseArgs(argv: string[]): { ok: true; args: ParsedArgs } | { ok: false; error: string } {
  let task: string | undefined;
  let cwd = process.cwd();
  let name: string | undefined;
  let timeoutMins: number | undefined;
  let permMode: PermissionMode | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cwd") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--cwd requires a value" }; cwd = v; }
    else if (a === "--name") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--name requires a value" }; name = v; }
    else if (a === "--timeout-mins") {
      const v = argv[++i];
      if (v === undefined) return { ok: false, error: "--timeout-mins requires a value" };
      const n = Number(v);
      if (!Number.isFinite(n) || n <= 0) return { ok: false, error: `--timeout-mins must be a positive number (got "${v}")` };
      timeoutMins = n;
    }
    else if (a === "--permission-mode") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--permission-mode requires a value" }; permMode = v as PermissionMode; }
    else if (task === undefined) task = a;
  }
  return { ok: true, args: { task, cwd, name, timeoutMins, permMode } };
}

// The run-and-record step, extracted so the meta-transition contract is
// testable with an injected runSession. meta.json ALWAYS leaves "running": the
// success path writes finalMeta (done/failed/capped/blocked), and a thrown
// runSession writes {status:"failed", exit_code:-1} THEN rethrows to
// main().catch — never a stuck "running" meta orphaned by a mid-run throw.
export async function executeRun(deps: {
  runSession: typeof runSession;
  prompt: string; worktree: string; permMode?: PermissionMode;
  sessionDir: string; metaPath: string; runningMeta: Record<string, unknown>;
}): Promise<{ code: number }> {
  try {
    const res = await deps.runSession(deps.prompt, deps.worktree, deps.permMode, "glm");
    if (res.tail !== undefined) appendFileSync(join(deps.sessionDir, "run.log"), res.tail);
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...finalMeta(res.code, res.pid, res.capped, res.blocked) }, null, 2));
    return { code: res.code };
  } catch (e) {
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, status: "failed", exit_code: -1, pid: 0 }, null, 2));
    throw e;
  }
}

async function main(): Promise<void> {
  const parsed = parseArgs(process.argv.slice(2));
  const usage = "usage: spawn-glm <prompt> [--cwd <dir>] [--name <slug>] [--timeout-mins <n>] [--permission-mode bypassPermissions]";
  if (!parsed.ok) { console.error(`spawn-glm: ${parsed.error}`); console.error(usage); process.exit(2); }
  const { task, cwd, name, timeoutMins, permMode } = parsed.args;
  if (!task) { console.error(usage); process.exit(2); }
  const absCwd = resolve(cwd);

  const plan = planSpawn(absCwd, name, { isHimmelCheckout, settingsConflicts: findSettingsConflicts, home: homedir() });
  if (!plan.ok) { console.error(plan.reason); process.exit(2); }
  for (const w of plan.warnings) console.error(`spawn-glm: WARNING — settings model key present (${formatConflict(w)}); explicit --model flag takes precedence, verify via the transcript model id.`);

  // Preflight the ZAI key BEFORE any side effect (before worktree add): a
  // missing key must be a clean refusal (exit 2), not a failure AFTER the
  // worktree+branch+running-meta exist (orphans + a stuck "running" meta).
  // runSession re-derives the env internally — the double build is cheap.
  try { buildGlmEnv(REPO_ROOT); } catch (e) { console.error(`spawn-glm: ${String((e as any)?.message ?? e)}`); process.exit(2); }

  const g = (args: string[]) => { const r = Bun.spawnSync(["git", "-C", absCwd, ...args], { stdout: "pipe", stderr: "pipe" }); if (r.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${r.stderr.toString()}`); };
  g(["worktree", "add", plan.worktree, "-b", plan.branch]);
  poisonPushUrl(absCwd, plan.worktree);

  const guard = checkGlmGuards(plan.worktree);
  if (!guard.ok) { console.error(guard.reason); process.exit(3); }

  const sessionDir = join(glmSessionRoot(), `glm-${plan.slug}-${Date.now()}`);
  mkdirSync(sessionDir, { recursive: true });
  const metaPath = join(sessionDir, "meta.json");
  const started_at = new Date().toISOString();
  const runningMeta = { status: "running", pid: 0, started_at, lane: "glm", task_name: plan.slug };
  writeFileSync(metaPath, JSON.stringify(runningMeta, null, 2));

  const prompt = composeWorkerPrompt(task, sessionDir, plan.branch);
  if (timeoutMins !== undefined) process.env.RUN_TIMEOUT_MS = String(timeoutMins * 60 * 1000);

  const { code } = await executeRun({ runSession, prompt, worktree: plan.worktree, permMode, sessionDir, metaPath, runningMeta });

  console.log(`session-dir: ${sessionDir}`);
  console.log(`transcript-dir: ${transcriptDirFor(plan.worktree)}`);
  console.log(`exit: ${code}`);
  process.exit(code);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`spawn-glm: ${String(e?.message ?? e)}`); process.exit(1); });
}
