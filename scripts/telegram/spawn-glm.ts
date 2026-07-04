// scripts/telegram/spawn-glm.ts
// Poller-free GLM worker spawn (HIMMEL-654 offload spike; spec D4). Owns the
// glue the poller provides for bridge runs: prompt composition (minted session
// paths), run.log persistence from the returned tail, meta.json transitions.
// Sessions live under <BRIDGE_ROOT>/glm-sessions/ — the live poller scans ONLY
// <root>/sessions/, so nothing here can be double-spawned or Telegram-flushed.
import { existsSync, mkdirSync, writeFileSync, appendFileSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { runSession, REPO_ROOT, detectGlmCap, type PermissionMode, type GlmCapWindow } from "./run";
import { checkGlmGuards } from "./glm-guard";
import { buildGlmEnv, findSettingsConflicts, formatConflict, fetchGlmUsage, readZaiKey, type SettingsConflict, type GlmUsage } from "./glm-env";
import { appendQuotaGauge, buildGlmRow } from "./quota-gauge";
import { parseGrantFlag, composeGrantLine, nextGrantId, authorityGate, classifyShape, composeEscalationForRefusedGrant, carryGrants, seedCarriedGrants, type GrantSpec } from "./grants";

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
    `HARD RULES: never push, never open a PR — a validating session reviews your branch and owns the git/PR surface. Jira updates (status, comments, followup tickets) ARE allowed via node scripts/jira/dist/index.js (audited + recoverable).`,
    `Report progress by APPENDING one JSON line {"text":"<note>"} per update to ${outbox}. That is the only channel to the operator.`,
    `THE TASK: ${task}`,
    `If a step is hard-blocked by the GLM-lane guard, do NOT retry or give up: APPEND one escalation line {"type":"escalation","capability":"<the command>","arm":"<git-push|git-url|gh|network>","reason":"<why>","step":"<which step>","ts":"<ISO>"} to ${outbox}, SKIP that step, continue the rest of the task, and note the skipped step in your final ${context} summary.`,
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

// A capped/blocked/timed-out run must NEVER surface as `done` or a bare
// `failed`: each is a distinct terminal state the caller inspects. Precedence:
// capped (there is a reset to arm at — the actionable fact) > blocked > timeout.
export function finalMeta(code: number, pid: number, capped?: boolean, blocked?: boolean, timedOut?: boolean): { status: "done" | "failed" | "capped" | "blocked" | "timeout"; exit_code: number; pid: number; timed_out: boolean } {
  const status = capped ? "capped" : blocked ? "blocked" : timedOut ? "timeout" : code === 0 ? "done" : "failed";
  return { status, exit_code: code, pid, timed_out: !!timedOut };
}

// isHimmelCheckout real impl: a himmel checkout carries the GLM launcher.
function isHimmelCheckout(d: string): boolean {
  return existsSync(join(d, "scripts", "claude-glm"));
}

export type ParsedArgs = { task?: string; cwd: string; name?: string; timeoutMins?: number; permMode?: PermissionMode; armOnCap: boolean; grants: GrantSpec[]; autonomous: boolean; carryFrom?: string };
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
  let armOnCap = true;
  const grants: GrantSpec[] = [];
  let autonomous = false;
  let carryFrom: string | undefined;
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
    else if (a === "--arm-on-cap") armOnCap = true;
    else if (a === "--no-arm-on-cap") armOnCap = false;
    else if (a === "--grant") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--grant requires a value" }; const p = parseGrantFlag(v); if (!p.ok) return { ok: false, error: `--grant ${p.error}` }; grants.push(p.spec); }
    else if (a === "--autonomous") autonomous = true;
    else if (a === "--carry-from") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--carry-from requires a value" }; carryFrom = v; }
    else if (task === undefined) task = a;
  }
  return { ok: true, args: { task, cwd, name, timeoutMins, permMode, armOnCap, grants, autonomous, carryFrom } };
}

// HIMMEL-682 (Task L1): read a capped session's grants.jsonl and compute the
// carried grant + escalation lines to seed into a respawned session. The
// shape-split (READ → seed, autonomous WRITE → re-escalate) lives in the pure
// seedCarriedGrants; this adds the fs read + fail-open + observability.
// Exported so the security wiring (autonomousEff → gate) is unit-tested
// end-to-end against a temp dir, not just by inspection. FAIL-OPEN: a missing OR
// UNREADABLE grants.jsonl (EACCES/EISDIR/TOCTOU) → no carry (F4 reset), NEVER
// throws — carry is best-effort side work that must not abort the dispatch it
// exists to perform (mirrors the buildGlmEnv / quota-gauge guards).
export function applyCarryFrom(carryFrom: string, autonomous: boolean, existing: string[], now: Date): { grantLines: string[]; escalationLines: string[]; summary: string } {
  const src = join(carryFrom, "grants.jsonl");
  if (!existsSync(src)) return { grantLines: [], escalationLines: [], summary: `--carry-from ${carryFrom} has no grants.jsonl — no grants carried (F4 reset).` };
  try {
    const lines = readFileSync(src, "utf8").split("\n").filter(Boolean);
    const { grantLines, escalationLines } = seedCarriedGrants(carryGrants(lines, now), autonomous, existing, now);
    const esc = escalationLines.length ? `; ${escalationLines.length} write grant(s) re-escalated (F4 not preserved for writes on the autonomous path)` : "";
    return { grantLines, escalationLines, summary: `carried ${grantLines.length} grant(s) from ${carryFrom} (${lines.length} line(s) seen)${esc}.` };
  } catch (e) {
    return { grantLines: [], escalationLines: [], summary: `--carry-from ${carryFrom} grants.jsonl unreadable (${String((e as { message?: string })?.message ?? e)}) — no grants carried (F4 reset).` };
  }
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
  capGuard?: CapGuardDeps;
}): Promise<{ code: number }> {
  try {
    const res = await deps.runSession(deps.prompt, deps.worktree, deps.permMode, "glm");
    if (res.tail !== undefined) appendFileSync(join(deps.sessionDir, "run.log"), res.tail);
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...finalMeta(res.code, res.pid, res.capped, res.blocked, res.timedOut) }, null, 2));
    if (deps.capGuard && res.capped) {
      // Cap-guard post-processing is BEST-EFFORT armor around an already-honest
      // terminal state: the capped meta above is the base layer. A throw below
      // (Bun.spawnSync THROWS on an unspawnable binary — distinct from a nonzero
      // rc — and writeFileSync can throw on I/O) must degrade to a loud warn,
      // never fall to the outer catch: that would clobber the capped meta to
      // "failed" and flip spawn-glm's exit code (CR round finding).
      try {
        const g = deps.capGuard;
        const now = g.now?.() ?? new Date();
        const cls = detectGlmCap(res.tail ?? "");
        const cap_window: MetaCapWindow = cls?.window ?? "generic";
        const base = { ...deps.runningMeta, ...finalMeta(res.code, res.pid, res.capped, res.blocked, res.timedOut), cap_window };
        if (cap_window === "long") {
          writeFileSync(deps.metaPath, JSON.stringify({ ...base, cap_source: "no-arm-long-window" }, null, 2));
          console.error("spawn-glm: long-window GLM cap — NOT auto-armed; recover manually after the documented reset");
          return { code: res.code };
        }
        const usage = await g.fetchUsage();
        appendQuotaGauge(buildGlmRow(usage, Date.now())); // WS9 (HIMMEL-654): observe the cap-time GLM reading (null -> invisible row); passive, no new fetch
        // HIMMEL-275 spirit at cap time too: a null re-query is visible, not a
        // silent fall-through to the floor (preflight has its own line).
        if (usage === null) console.error("spawn-glm: usage invisible at cap time (monitor endpoint unavailable) — resume slot falls back to error-body/cycle-floor");
        const { resumeAt, capSource } = computeResumeAt({ now, startedAt: g.startedAt, usage, tail: res.tail });
        writeFileSync(deps.metaPath, JSON.stringify({ ...base, resume_at: resumeAt.toISOString(), cap_source: capSource }, null, 2)); // meta FIRST (base layer)
        if (g.armOnCap) {
          const snap = join(deps.sessionDir, "respawn-handover.md");
          writeFileSync(snap, composeRespawnHandover({ task: g.task, cwd: g.cwd, slug: g.slug, timeoutMins: g.timeoutMins, permMode: g.permMode, sessionDir: deps.sessionDir, branch: g.branch, resumeAtIso: resumeAt.toISOString() }));
          const rc = g.arm(toArmHHMM(resumeAt), snap);
          // rc=3 honesty (CR round): --dedup-any defers to ANY queued resume job,
          // possibly an UNRELATED handover — this task's respawn handover is then
          // NOT independently scheduled; the meta resume_at is the breadcrumb.
          if (rc === 0) console.error(`spawn-glm: GLM cap — resume ARMED at ${toArmHHMM(resumeAt)} (${capSource})`);
          else if (rc === 3) console.error(`spawn-glm: GLM cap — resume deferred: another resume job is already armed (dedup-any); this task is NOT independently scheduled — if that job does not cover this work, recover via resume_at in meta.json`);
          else console.error(`spawn-glm: GLM cap — arm FAILED (rc=${rc}); resume_at ${resumeAt.toISOString()} recorded in meta for manual recovery`);
        }
      } catch (e) {
        console.error(`spawn-glm: GLM cap — post-processing threw (${String((e as any)?.message ?? e)}); capped meta preserved, resume NOT armed — recover via resume_at/started_at in meta.json`);
      }
      return { code: res.code };
    }
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
  const { task, cwd, name, timeoutMins, permMode, armOnCap, grants, autonomous, carryFrom } = parsed.args;
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
  const preflightUsage = await fetchGlmUsage(readZaiKey(REPO_ROOT).key);
  // WS9 (HIMMEL-654): observe the preflight GLM reading; passive, reuses the
  // existing fetch. GUARDED — this runs BEFORE the worktree exists, so an
  // unguarded ledger-write throw would propagate to main().catch and ABORT the
  // dispatch; the passive layer must never block a dispatch (mirrors the
  // cap-time site's try/catch and the bash twin's `|| true`).
  try { appendQuotaGauge(buildGlmRow(preflightUsage, Date.now())); } catch (e) { console.error(`spawn-glm: quota-gauge preflight append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
  const warn = formatUsageWarn(preflightUsage, parseWarnPct(process.env.GLM_USAGE_WARN_PCT));
  if (warn) console.error(warn);

  const g = (args: string[]) => { const r = Bun.spawnSync(["git", "-C", absCwd, ...args], { stdout: "pipe", stderr: "pipe" }); if (r.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${r.stderr.toString()}`); };
  g(["worktree", "add", plan.worktree, "-b", plan.branch]);
  poisonPushUrl(absCwd, plan.worktree);

  const guard = checkGlmGuards(plan.worktree);
  if (!guard.ok) { console.error(guard.reason); process.exit(3); }

  const sessionDir = join(glmSessionRoot(), `glm-${plan.slug}-${Date.now()}`);
  mkdirSync(sessionDir, { recursive: true });
  // GLM_SESSION_DIR (spec D5): the deny hook (running inside the worker child)
  // reads ${GLM_SESSION_DIR}/grants.jsonl. sessionEnv('glm') spreads process.env
  // into the child, so setting it here propagates; unset => hook skips grants.
  process.env.GLM_SESSION_DIR = sessionDir;
  // Pre-seed operator/parent grants into the session ledger (escalation channel,
  // spec D8): classify each grant's shape and, under autonomous authority, refuse
  // a write-shaped grant — recording a pending operator escalation instead of a
  // grant. accumulated feeds nextGrantId so repeated --grant flags get distinct
  // ids (g1, g2, …) rather than all colliding on g1 against the empty file.
  const autonomousEff = autonomous || !!process.env.HIMMEL_OVERNIGHT;
  const grantsPath = join(sessionDir, "grants.jsonl");
  const seedOutbox = join(sessionDir, "outbox.jsonl");
  const accumulated: string[] = [];
  // HIMMEL-682 (Task L1): carry the capped session's still-valid grants forward
  // (absolute expires_at + remaining budget) BEFORE the --grant loop, so
  // nextGrantId continues past the carried ids. Shape-split (reads seed, autonomous
  // writes re-escalate), fail-open, and observability all live in applyCarryFrom.
  if (carryFrom) {
    const { grantLines, escalationLines, summary } = applyCarryFrom(carryFrom, autonomousEff, accumulated, new Date());
    for (const line of grantLines) { appendFileSync(grantsPath, line + "\n"); accumulated.push(line); }
    for (const esc of escalationLines) appendFileSync(seedOutbox, esc + "\n");
    console.error(`spawn-glm: ${summary}`);
  }
  for (const spec of grants) {
    const shape = classifyShape(spec.arm, spec.pattern);
    if (authorityGate(shape, autonomousEff).action === "grant") {
      const line = composeGrantLine(spec, { capability: spec.pattern, grantId: nextGrantId(accumulated), grantedBy: "parent:spawn-glm", now: new Date() });
      appendFileSync(grantsPath, line + "\n");
      accumulated.push(line);
    } else {
      appendFileSync(seedOutbox, composeEscalationForRefusedGrant({ capability: spec.pattern, arm: spec.arm, reason: "autonomous refuses write grant — operator adjudication required", step: "pre-seed", now: new Date() }) + "\n");
      console.error(`spawn-glm: --grant ${spec.arm} is write-shaped and refused under autonomous authority; recorded a pending operator escalation.`);
    }
  }
  const metaPath = join(sessionDir, "meta.json");
  const started_at = new Date().toISOString();
  const runningMeta = { status: "running", pid: 0, started_at, lane: "glm", task_name: plan.slug };
  writeFileSync(metaPath, JSON.stringify(runningMeta, null, 2));

  const prompt = composeWorkerPrompt(task, sessionDir, plan.branch);
  if (timeoutMins !== undefined) process.env.RUN_TIMEOUT_MS = String(timeoutMins * 60 * 1000);

  const capGuard: CapGuardDeps = {
    startedAt: new Date(started_at),
    task, cwd: absCwd, slug: plan.slug, branch: plan.branch, timeoutMins, permMode,
    armOnCap,
    fetchUsage: () => fetchGlmUsage(readZaiKey(REPO_ROOT).key),
    arm: (hhmm, snap) => Bun.spawnSync(buildArmArgv(REPO_ROOT, hhmm, snap), { stdout: "inherit", stderr: "inherit" }).exitCode ?? 1,
  };
  const { code } = await executeRun({ runSession, prompt, worktree: plan.worktree, permMode, sessionDir, metaPath, runningMeta, capGuard });

  console.log(`session-dir: ${sessionDir}`);
  console.log(`transcript-dir: ${transcriptDirFor(plan.worktree)}`);
  console.log(`exit: ${code}`);
  process.exit(code);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`spawn-glm: ${String(e?.message ?? e)}`); process.exit(1); });
}

// ── cap guard (HIMMEL-654): resume-time helpers ──────────────────────────────
export type CapSource = "monitor-endpoint" | "error-body" | "cycle-floor";
// On-disk meta unions are WIDER than the helpers' return types (CR round —
// types must not lie to meta.json readers): cap_window adds the "generic"
// fallback (base sentinel matched, no GLM classification), cap_source adds
// the long-window no-arm marker.
export type MetaCapWindow = GlmCapWindow | "generic";
export type MetaCapSource = CapSource | "no-arm-long-window";
const TWO_MIN = 120_000, DAY = 24 * 3600_000, FIVE_H = 5 * 3600_000;
// Clamp window [now+2min, now+24h]: arm-resume HH:MM expresses only the next
// future occurrence; 2min mirrors auto-arm-on-cap's registration-latency floor.
// Out-of-range candidates FALL THROUGH to the next source; a past cycle floor
// (capped >5h after start) arms at now+2min.
export function computeResumeAt(p: { now: Date; startedAt: Date; usage: GlmUsage | null; tail?: string }): { resumeAt: Date; capSource: CapSource } {
  const lo = p.now.getTime() + TWO_MIN, hi = p.now.getTime() + DAY;
  const inRange = (t: number) => t >= lo && t <= hi;
  const m = p.usage?.nextResetTime;
  if (typeof m === "number" && inRange(m)) return { resumeAt: new Date(m), capSource: "monitor-endpoint" };
  const b = p.tail?.match(/your limit will reset at ([0-9T:. Z+-]+)/i)?.[1]?.trim();
  if (b) {
    const t = /^\d{12,}$/.test(b) ? Number(b) : Date.parse(b);
    if (Number.isFinite(t) && inRange(t)) return { resumeAt: new Date(t), capSource: "error-body" };
  }
  const floor = p.startedAt.getTime() + FIVE_H;
  return { resumeAt: new Date(Math.min(Math.max(floor, lo), hi)), capSource: "cycle-floor" };
}
export function toArmHHMM(d: Date): string {
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}
// -rN retry suffix (spec D7): a capped run leaves its worktree+branch behind;
// a same-name respawn would refuse on the existing worktree.
export function nextRetrySlug(slug: string): string {
  const m = slug.match(/^(.*)-r(\d+)$/);
  return m ? `${m[1]}-r${Number(m[2]) + 1}` : `${slug}-r1`;
}

// Self-contained cold-start respawn handover (spec (b) 3): the armed session
// may be a fresh cold start — everything needed to re-dispatch is inline.
export function composeRespawnHandover(p: { task: string; cwd: string; slug: string; timeoutMins?: number; permMode?: string; sessionDir: string; branch: string; resumeAtIso: string }): string {
  const respawnName = nextRetrySlug(p.slug);
  const flags = [`--cwd ${p.cwd}`, `--name ${respawnName}`, p.timeoutMins !== undefined ? `--timeout-mins ${p.timeoutMins}` : "", p.permMode ? `--permission-mode ${p.permMode}` : "", `--carry-from ${p.sessionDir}`].filter(Boolean).join(" ");
  return [
    "---",
    "type: handover",
    "task: respawn a GLM worker capped on the z.ai 5-hour cycle",
    "armed-by: spawn-glm cap guard (HIMMEL-654)",
    `resume_cwd: ${p.cwd}`,
    "---",
    "",
    "# Capped GLM worker — respawn at cycle reset",
    "",
    `A GLM-lane worker hit the z.ai usage cap; a resume was armed for ${p.resumeAtIso}.`,
    "",
    "## Before spending quota",
    "",
    `1. Check whether this work was already validated/merged meanwhile (branch ${p.branch}, capped session dir ${p.sessionDir}) — if merged, just clean up; do NOT re-dispatch.`,
    `2. Inspect the capped worktree for ${p.branch}: if it holds unpushed commits, re-dispatch with a "continue from the existing branch state on ${p.branch}" preamble; else re-dispatch fresh.`,
    "",
    "## Re-dispatch command",
    "",
    "```",
    `bun scripts/telegram/spawn-glm.ts ${JSON.stringify(p.task)} ${flags}`,
    "```",
  ].join("\n");
}

// ── cap guard (HIMMEL-654): orchestration deps + arm argv builder ────────────
export type CapGuardDeps = {
  startedAt: Date;
  task: string; cwd: string; slug: string; branch: string;
  timeoutMins?: number; permMode?: string;
  armOnCap: boolean;
  fetchUsage: () => Promise<GlmUsage | null>;
  arm: (hhmm: string, handoverPath: string) => number;   // rc of arm-resume.sh
  now?: () => Date;
};
// argv builder for the real arm invoker — pure so the flag contract
// (--dedup-any --time <HH:MM> --handover <path>) is unit-asserted.
export function buildArmArgv(repoRoot: string, hhmm: string, handoverPath: string): string[] {
  return ["bash", join(repoRoot, "scripts", "handover", "arm-resume.sh"), "--dedup-any", "--time", hhmm, "--handover", handoverPath];
}

// Preflight warn (spec (c)): warn-only — a heuristic-threshold refusal would
// strand work on a miscount (D4). Null = HIMMEL-275 visible-invisible line.
export function formatUsageWarn(u: GlmUsage | null, warnPct: number): string | null {
  if (u === null) return "spawn-glm: usage invisible (monitor endpoint unavailable)";
  if (u.percentage < warnPct) return null;
  return `spawn-glm: WARNING — GLM 5h cycle ${u.percentage}% used${u.level ? ` (${u.level} tier)` : ""}; resets ${toArmHHMM(new Date(u.nextResetTime))} local`;
}
// env-knob coercion, pure + tested (main() wiring must not hide coercion rules)
export function parseWarnPct(raw: string | undefined): number {
  const s = raw?.trim(); // whitespace-only must not coerce to 0 (= warn-always)
  const n = Number(s);
  return s !== undefined && s !== "" && Number.isFinite(n) && n >= 0 && n <= 100 ? n : 80;
}
