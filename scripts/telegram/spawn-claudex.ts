// scripts/telegram/spawn-claudex.ts
// Poller-free claudex-lane worker spawn (HIMMEL-1003 — the codex-lane twin of
// spawn-glm.ts, HIMMEL-654/800). Own-branch + shared-branch dispatch through
// scripts/claude-codex (HIMMEL-979), which owns the ENTIRE trust boundary
// (PHI/egress guard union, ANTHROPIC_*/CLAUDE_CODE_USE_*/proxy env sweeps,
// config-dir seeding, proxy pinning, the HIMMEL-1001 effort default). This
// file NEVER sets an ANTHROPIC_* var, NEVER builds a GLM-style env block, and
// NEVER re-implements any guard claude-codex already owns — it only mints the
// worktree/branch, composes the worker prompt, and dispatches THROUGH the
// launcher, mirroring spawn-glm's own+shared-branch lifecycle.
//
// Lane-agnostic helpers are IMPORTED from spawn-glm.ts (transcriptDirFor,
// poisonPushUrl, preflightWindowCheck, measureOverheadChars, finalMeta,
// POISON_SENTINEL) rather than copy-pasted. Everything GLM-branded (worker
// prompt, plan functions, args parser, the shared-dispatch lock lifecycle,
// main) is twinned here with codex/claudex wording and a claudex/<slug>
// branch — see the design brief (HIMMEL-1003) for the twin/import split.
//
// Fresh-context (HIMMEL-1001 D5): every dispatch is a NEW Claude Code
// session — Claude Code gives each subagent/session its own context, so
// there is no v2-subagent-history-copy and no fast-mode toggle to carry or
// disable here; nothing to implement for that requirement.
import { existsSync, mkdirSync, writeFileSync, appendFileSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { spawn } from "bun";
import { REPO_ROOT, killTree, detectContentFilter, type PermissionMode } from "./run";
import { transcriptDirFor, poisonPushUrl, preflightWindowCheck, measureOverheadChars, finalMeta, POISON_SENTINEL } from "./spawn-glm";

export function claudexSessionRoot(): string {
  return join(process.env.BRIDGE_ROOT ?? join(homedir(), ".claude", "handover", "bridge"), "claudex-sessions");
}

// ── worker prompt (twin of spawn-glm's composeWorkerPrompt/composePointerPrompt) ──

// HIMMEL-1003 v1 scope: deferred — the grants/escalation channel (spawn-glm's
// --grant/--autonomous/--carry-from, classifyShape/authorityGate/grants.jsonl,
// applyCarryFrom). A claudex worker gets no pre-seeded capability grants and
// has no escalation-outbox line to fall back on when a step is hard-blocked
// in v1 — it just skips and notes it in the final context.md summary via the
// generic HARD RULES line below. A followup ticket ports the channel if the
// codex lane needs the same graceful-degrade path GLM has.
export function composeClaudexWorkerPrompt(task: string, sessionDir: string, branch: string, opts?: { shared?: boolean }): string {
  const outbox = join(sessionDir, "outbox.jsonl");
  const context = join(sessionDir, "context.md");
  const branchLine = opts?.shared
    ? `Work ONLY inside your current directory (a dedicated git worktree). The branch ${branch} is a SHARED PR branch with EXISTING history, already checked out — do NOT create a new branch, do NOT reset/rebase/amend/force-anything; ADD new commits on top only. A lock serializes writers, so no other worker touches this branch while you run.`
    : `Work ONLY inside your current directory (a dedicated git worktree). Commit your work on the branch ${branch} which is already checked out.`;
  return [
    `You are an unattended claudex-lane worker session (himmel offload, codex weekly bank, HIMMEL-654/979/1003) — do the scoped chunk below and stop, do not expand scope.`,
    branchLine,
    `HARD RULES: never push, never open a PR — a validating session reviews your branch and owns the git/PR surface. Jira updates (status, comments, followup tickets) ARE allowed via node scripts/jira/dist/index.js (audited + recoverable). If a step is hard-blocked, skip it, continue the rest of the task, and note the skipped step in your final ${context} summary — v1 has no escalation channel to append to.`,
    `Report progress by APPENDING one JSON line {"text":"<note>"} per update to ${outbox}. That is the only channel to the operator.`,
    `THE TASK: ${task}`,
    `As your FINAL action, append a one-line summary of what you did to ${context}, then stop.`,
  ].join("\n");
}

// Pointer-prompt dispatch (HIMMEL-740 pattern, reused for this lane too): the
// SUBMITTED prompt is a SHORT pointer to the brief file written under
// claudex-sessions/ (outside the repo worktree), not the whole brief inlined.
export function composeClaudexPointerPrompt(briefPath: string): string {
  return [
    `You are an unattended claudex-lane worker session (himmel offload, codex weekly bank).`,
    `Read the file at ${briefPath} — it is your COMPLETE task brief — and execute it exactly, treating its instructions as if they were this prompt.`,
  ].join("\n");
}

// ── plan functions (twin of spawn-glm's planSpawn/planSharedSpawn) ──────────
//
// Deliberately SIMPLER than the GLM twins: GLM's planSpawn/planSharedSpawn run
// a settingsConflicts preflight (findSettingsConflicts) because spawn-glm
// itself builds the ANTHROPIC_* env block and needs to catch a settings layer
// that would fight it BEFORE dispatch. spawn-claudex never builds that block —
// scripts/claude-codex already walks every ancestor .claude/settings{,.local}.json
// (screen_project_settings_file, R5) and refuses on an env.ANTHROPIC_*/
// CLAUDE_CODE_USE_* key itself. Duplicating that check here would be
// re-implementing a guard claude-codex already owns (D1) and could drift out
// of sync with it — so the claudex plan functions skip it entirely.

export type ClaudexSpawnPlan = { ok: true; slug: string; worktree: string; branch: string } | { ok: false; reason: string };
export function planClaudexSpawn(cwd: string, name: string | undefined, deps: { isHimmelCheckout: (d: string) => boolean }): ClaudexSpawnPlan {
  if (!deps.isHimmelCheckout(cwd)) return { ok: false, reason: `spawn-claudex: ${cwd} is not a himmel checkout (v1 scope: himmel repo only)` };
  const slug = (name?.trim() || `t${Date.now()}`).replace(/[^a-zA-Z0-9-]/g, "-");
  return { ok: true, slug, worktree: join(cwd, ".claude", "worktrees", `claudex+${slug}`), branch: `claudex/${slug}` };
}

export type ClaudexSharedSpawnPlan = { ok: true; slug: string; worktree: string; branch: string; needsWorktreeAdd: boolean } | { ok: false; reason: string };
// Mirrors spawn-glm's planSharedSpawn rules (b)-(f) exactly (never mint on a
// typo'd branch, never dispatch at trunk, never into the primary checkout,
// reuse is scoped to lane-managed worktrees, a reused worktree must be clean).
export function planClaudexSharedSpawn(
  cwd: string, branch: string,
  deps: {
    isHimmelCheckout: (d: string) => boolean;
    branchExists: (branch: string) => boolean;
    worktreeOf: (branch: string) => { path: string; isPrimary: boolean } | null;
    isDirty: (path: string) => boolean;
  },
): ClaudexSharedSpawnPlan {
  if (!deps.isHimmelCheckout(cwd)) return { ok: false, reason: `spawn-claudex: ${cwd} is not a himmel checkout (v1 scope: himmel repo only)` };
  if (!deps.branchExists(branch)) return { ok: false, reason: `spawn-claudex: --branch ${branch} does not exist — shared mode never mints a branch (check for a typo)` };
  if (branch === "main" || branch === "master") return { ok: false, reason: `spawn-claudex: --branch ${branch} refused — shared mode never dispatches a worker at the trunk branch` };

  const found = deps.worktreeOf(branch);
  let worktree: string;
  let needsWorktreeAdd: boolean;
  if (found) {
    if (found.isPrimary) return { ok: false, reason: `spawn-claudex: --branch ${branch} is checked out in the primary checkout (${found.path}) — refusing to dispatch a worker into the primary checkout` };
    if (!found.path.replace(/\\/g, "/").includes("/.claude/worktrees/")) {
      return { ok: false, reason: `spawn-claudex: --branch ${branch} is checked out in ${found.path}, outside .claude/worktrees/ — shared mode reuses only lane-managed worktrees, refusing to dispatch a worker there` };
    }
    worktree = found.path;
    needsWorktreeAdd = false;
  } else {
    const slug0 = branch.replace(/[^a-zA-Z0-9-]/g, "-");
    worktree = join(cwd, ".claude", "worktrees", `claudex+${slug0}`);
    needsWorktreeAdd = true;
  }

  if (!needsWorktreeAdd && deps.isDirty(worktree)) return { ok: false, reason: `spawn-claudex: worktree for --branch ${branch} (${worktree}) has uncommitted changes — commit or stash before a shared-mode handoff` };

  const slug = branch.replace(/[^a-zA-Z0-9-]/g, "-");
  return { ok: true, slug, worktree, branch, needsWorktreeAdd };
}

// isHimmelCheckout real impl: a himmel checkout carries the codex launcher.
function isHimmelCheckout(d: string): boolean {
  return existsSync(join(d, "scripts", "claude-codex"));
}

// ── real git probes for planClaudexSharedSpawn's injected deps ──────────────
// Twinned (not imported) from spawn-glm.ts's gitBranchExists/gitWorktreeOf/
// gitIsDirty — those exist purely to feed planSharedSpawn's deps and are not
// on the D2 lane-agnostic import list; identical logic, no "glm" in either.

export function gitBranchExists(cwd: string, branch: string): boolean {
  const r = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], { stdout: "pipe", stderr: "pipe" });
  return r.exitCode === 0;
}

function gitWorktreeOf(cwd: string, branch: string): { path: string; isPrimary: boolean } | null {
  const r = Bun.spawnSync(["git", "-C", cwd, "worktree", "list", "--porcelain"], { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) return null;
  const wantRef = `refs/heads/${branch}`;
  let currentPath: string | null = null;
  let firstPath: string | null = null;
  for (const line of r.stdout.toString().split("\n")) {
    if (line.startsWith("worktree ")) {
      currentPath = line.slice("worktree ".length).trim();
      if (firstPath === null) firstPath = currentPath;
    } else if (line.startsWith("branch ") && currentPath && line.slice("branch ".length).trim() === wantRef) {
      return { path: currentPath, isPrimary: currentPath === firstPath };
    }
  }
  return null;
}

export function gitIsDirty(worktreePath: string): boolean {
  const r = Bun.spawnSync(["git", "-C", worktreePath, "status", "--porcelain"], { stdout: "pipe", stderr: "pipe" });
  // FAIL-CLOSED (mirrors spawn-glm's gitIsDirty): a failed `git status`
  // (corrupt/stale worktree) must NOT read as clean and slip past the
  // reused-worktree-must-be-clean gate.
  if (r.exitCode !== 0) throw new Error(`cannot determine worktree state for ${worktreePath}: git status failed: ${r.stderr.toString().trim()}`);
  return r.stdout.toString().trim().length > 0;
}

// Under-the-lock revalidation of a REUSED shared worktree (HIMMEL-1037,
// codex-adv CR). The plan's pre-lock checks can go stale between then and lock
// acquisition — the worktree could be switched to another branch, recreated, or
// dirtied by a concurrent worker. Re-resolve identity + cleanliness so the
// worker never commits onto the WRONG branch or another worker's mixed state:
//   - fresh worktree (needsWorktreeAdd) ⇒ nothing to revalidate, ok.
//   - the branch must still map to the SAME non-primary worktree path.
//   - that worktree must be clean.
// Deps injected (worktreeOf/isDirty) so it is unit-tested without real git.
export function revalidateSharedWorktree(deps: {
  needsWorktreeAdd: boolean; branch: string; worktree: string;
  worktreeOf: (b: string) => { path: string; isPrimary: boolean } | null;
  isDirty: (p: string) => boolean;
}): { ok: true } | { ok: false; reason: string } {
  const norm = (p: string) => p.replace(/\\/g, "/").replace(/\/$/, "");
  const wtNow = deps.worktreeOf(deps.branch);
  if (deps.needsWorktreeAdd) {
    // Planned to CREATE the worktree — but under the lock a concurrent dispatch
    // may have created the branch→worktree mapping during the backoff; a second
    // `git worktree add` would then fail. Refuse cleanly instead (codex-adv/
    // coderabbit CR). Absent mapping ⇒ ours to create, proceed.
    if (wtNow) return { ok: false, reason: `spawn-claudex: worktree for ${deps.branch} was created by a concurrent dispatch during the preflight (now ${wtNow.path}) — refusing the duplicate worktree-add; re-dispatch (HIMMEL-1037).` };
    return { ok: true };
  }
  if (!wtNow || wtNow.isPrimary || norm(wtNow.path) !== norm(deps.worktree)) {
    return { ok: false, reason: `spawn-claudex: shared worktree for ${deps.branch} changed under the lock (no longer the expected non-primary worktree ${deps.worktree}) — refusing before launch (a worker could commit to the wrong branch); re-dispatch (HIMMEL-1037).` };
  }
  if (deps.isDirty(deps.worktree)) {
    return { ok: false, reason: `spawn-claudex: reused worktree ${deps.worktree} became dirty before the lock (a concurrent shared worker left uncommitted changes) — refusing rather than commit onto mixed state; commit/stash there and re-dispatch (HIMMEL-1037).` };
  }
  return { ok: true };
}

// ── args parsing ──────────────────────────────────────────────────────────

export type EffortLevel = "low" | "medium" | "high" | "xhigh";
export type ClaudexParsedArgs = { task?: string; cwd: string; name?: string; branch?: string; timeoutMins?: number; permMode?: PermissionMode; effort?: EffortLevel; force: boolean; skipAuthPreflight: boolean };

// Pure + validated, mirrors spawn-glm's parseArgs (a value-taking flag with no
// value, or a non-positive/non-finite --timeout-mins, is a usage refusal).
// --effort (HIMMEL-1001 D5): refuse `max` (undocumented codex juice) and
// `ultra` (unreachable from Claude Code — falls back to xhigh) with a message
// pointing at the operating-rules doc, rather than silently forwarding them.
export function parseClaudexArgs(argv: string[]): { ok: true; args: ClaudexParsedArgs } | { ok: false; error: string } {
  let task: string | undefined;
  let cwd = process.cwd();
  let name: string | undefined;
  let branch: string | undefined;
  let timeoutMins: number | undefined;
  let permMode: PermissionMode | undefined;
  let effort: EffortLevel | undefined;
  let force = false;
  let skipAuthPreflight = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cwd") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--cwd requires a value" }; cwd = v; }
    else if (a === "--name") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--name requires a value" }; name = v; }
    else if (a === "--branch") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--branch requires a value" }; branch = v; }
    else if (a === "--timeout-mins") {
      const v = argv[++i];
      if (v === undefined) return { ok: false, error: "--timeout-mins requires a value" };
      const n = Number(v);
      if (!Number.isFinite(n) || n <= 0) return { ok: false, error: `--timeout-mins must be a positive number (got "${v}")` };
      timeoutMins = n;
    }
    else if (a === "--permission-mode") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--permission-mode requires a value" }; permMode = v as PermissionMode; }
    else if (a === "--effort") {
      const v = argv[++i];
      if (v === undefined) return { ok: false, error: "--effort requires a value" };
      if (v === "max" || v === "ultra") return { ok: false, error: `--effort ${v} is refused — 'max' is undocumented codex juice and 'ultra' is unreachable from Claude Code (silently falls back to xhigh); the HIMMEL-1001 ladder tops out at xhigh. See docs/tooling-catalog.md#claude-codex.` };
      if (v !== "low" && v !== "medium" && v !== "high" && v !== "xhigh") return { ok: false, error: `--effort must be one of low|medium|high|xhigh (got "${v}"); see docs/tooling-catalog.md#claude-codex` };
      effort = v;
    }
    else if (a === "--force") force = true;
    // Auth-preflight override is an EXPLICIT per-invocation flag, never an env
    // var: an ambient/inherited setting must not be able to silently disable the
    // fail-closed auth gate and restore the original startup failure (codex-adv CR).
    else if (a === "--skip-auth-preflight") skipAuthPreflight = true;
    else if (task === undefined) task = a;
  }
  if (branch !== undefined && name !== undefined) return { ok: false, error: "--branch and --name are mutually exclusive (shared mode derives the slug from the branch)" };
  return { ok: true, args: { task, cwd, name, branch, timeoutMins, permMode, effort, force, skipAuthPreflight } };
}

// ── codex weekly bank preflight (HIMMEL-1003 D4) ────────────────────────────
//
// HIMMEL-1003 v1 scope: deferred — quota-gauge ledger rows (parity with GLM's
// appendQuotaGauge/buildGlmRow observability). This preflight is the ONLY
// quota signal recorded for a claudex dispatch; a followup ticket adds a
// claudex row to the shared quota-gauge ledger.

// Bounded tail read: the codex rollout log is a live-growing sqlite file that
// can reach several hundred MB (verified live on the dev machine, 2026-07-14:
// ~469MB) — a full-file synchronous read on every dispatch would be a
// multi-hundred-MB memory spike + a slow scan for what must stay a cheap
// preflight. This bounds the read to the file's last N bytes (where recent
// rollout rows land in practice) rather than the brief's literal
// `grep -a -o ... <whole file> | tail -1` — same "read the LAST occurrence"
// semantics, verified against the live shape (`"secondary":{"used_percent":85`),
// bounded for a file this large.
const CODEX_BANK_LOG_TAIL_BYTES = 8 * 1024 * 1024; // 8 MiB

export function codexBankLogPath(home: string): string {
  return join(home, ".codex", "logs_2.sqlite");
}

// latin1 (not utf8): the file is a binary sqlite container, but the JSON text
// fragments being scanned are pure ASCII — a byte-for-byte latin1 mapping is
// lossless for a text/grep-style scan and can't produce replacement chars at
// a tail-cut boundary the way a multi-byte utf8 decode could.
function readFileTail(path: string, maxBytes: number): string {
  const size = statSync(path).size;
  const start = Math.max(0, size - maxBytes);
  const length = size - start;
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(length);
    readSync(fd, buf, 0, length, start);
    return buf.toString("latin1");
  } finally {
    closeSync(fd);
  }
}

// Pure parser: the LAST "secondary":{...,"used_percent":<N>,...} match in the
// scanned text (secondary = weekly bank, primary = 5h — per the rollout log
// shape; not this lane's concern, the 5h bank is the Claude-tier guard's job).
export function parseCodexWeeklyUsedPercent(raw: string): number | null {
  const re = /"secondary"\s*:\s*\{[^}]*?"used_percent"\s*:\s*([0-9]+(?:\.[0-9]+)?)/g;
  let m: RegExpExecArray | null;
  let last: number | null = null;
  while ((m = re.exec(raw)) !== null) {
    const n = Number(m[1]);
    if (Number.isFinite(n)) last = n;
  }
  return last;
}

// FAIL-OPEN (D4): any read error (missing/cold/unreadable log, a torn read,
// etc.) returns null — this must never brick a dispatch on a cold log.
// readTail is injected so this is testable without a real multi-hundred-MB
// file on disk.
export function fetchCodexWeeklyUsedPercent(home: string, readTail: (path: string, maxBytes: number) => string = readFileTail): number | null {
  try {
    return parseCodexWeeklyUsedPercent(readTail(codexBankLogPath(home), CODEX_BANK_LOG_TAIL_BYTES));
  } catch {
    return null;
  }
}

// env-knob coercion, pure + tested (mirrors spawn-glm's parseWarnPct).
export function parsePct(raw: string | undefined, fallback: number): number {
  const s = raw?.trim();
  const n = Number(s);
  return s !== undefined && s !== "" && Number.isFinite(n) && n >= 0 && n <= 100 ? n : fallback;
}

export type BankPreflightResult = { action: "ok" | "warn" | "refuse"; usedPct: number | null; message?: string };

// Pure decision fn (D4): WARN at warnPct, REFUSE at refusePct unless
// overridden (CLAUDEX_BANK_OK=1 / --force), null usedPct fails OPEN (HIMMEL-275
// spirit: an invisible reading is visible-invisible, never a silent skip).
// Rationale for refusing BEFORE any worktree side-effect: a capped worker
// dies mid-run — the tree survives but the work is lost.
export function evaluateCodexBankPreflight(usedPct: number | null, opts: { warnPct: number; refusePct: number; override: boolean }): BankPreflightResult {
  if (usedPct === null) return { action: "ok", usedPct: null, message: "codex weekly bank unreadable (~/.codex/logs_2.sqlite missing/cold/unparseable) — fail-open, proceeding without a bank preflight" };
  if (usedPct >= opts.refusePct) {
    if (opts.override) return { action: "warn", usedPct, message: `codex weekly bank at ${usedPct}% (>= refuse threshold ${opts.refusePct}%) — proceeding under override (CLAUDEX_BANK_OK=1/--force)` };
    return { action: "refuse", usedPct, message: `codex weekly bank at ${usedPct}% (>= refuse threshold ${opts.refusePct}%) — refusing before any worktree side-effect (a capped worker dies mid-run; the tree survives but the work is lost). Override with CLAUDEX_BANK_OK=1 or --force.` };
  }
  if (usedPct >= opts.warnPct) return { action: "warn", usedPct, message: `codex weekly bank at ${usedPct}% (>= warn threshold ${opts.warnPct}%) — consider a lighter dispatch or another lane` };
  return { action: "ok", usedPct };
}

// ── cap detection (HIMMEL-1003 v1 scope: deferred — see below) ─────────────

// HIMMEL-1003 v1 scope: deferred — GLM-style cap-WINDOW classification (5h vs
// long) and the auto-arm-on-cap resume scheduling that spawn-glm's
// executeRun/capGuard performs (computeResumeAt/buildArmArgv/
// composeRespawnHandover). detectClaudexCap only lets a capped run surface as
// meta status "capped" (via finalMeta, imported) instead of vanishing as a
// bare "failed" — no resume is armed. evaluateCodexBankPreflight above is the
// real quota control for this lane; a followup ticket adds resume scheduling
// if the cap-mid-run loss rate warrants it.
const CLAUDEX_CAP_SENTINELS = [/usage limit reached/i, /rate limit/i, /try again later/i];
export function detectClaudexCap(output: string): boolean {
  return CLAUDEX_CAP_SENTINELS.some((r) => r.test(output));
}

// ── transient codex OAuth refresh-gap PRE-LAUNCH preflight (HIMMEL-1037) ────
//
// The CLIProxyAPI codex gateway (127.0.0.1:8317) returns 503 auth_unavailable
// during the ~seconds window while the codex OAuth *access* token is
// mid-refresh — a transient ~1h-lapse window, NOT a dead credential. A
// BACKGROUND dispatch that starts up inside that window dies immediately; the
// proven 2026-07-15 incident was 3 back-to-back immediate retries all landing
// in the SAME gap (an interactive retry a minute later worked, because the
// human waited).
//
// We fix this BEFORE launching the worker — never by re-running one. `probe`
// runs `claude-codex --preflight-only` (the launcher's OWN authed 1-token
// /v1/messages check — the registry /v1/models stays 200 during the gap, so it
// must exercise the real upstream; exits 0=healthy / 20=transient-retry /
// 21=fatal WITHOUT spinning a worker) and is retried with backoff until auth is
// healthy or fatal/exhausted; only then does the caller mint
// the worktree and spawn the worker, exactly once. A worker's allowed side
// effects (Jira writes, outbox appends — see the worker prompt) can therefore
// never be duplicated by a re-run: post-hoc "did the worker do work?" inference
// is unsound (codex-adv CR), so a pre-execution auth signal is the only safe
// gate. It also avoids minting a worktree for a doomed run. Interactive
// cc-codex needs none of this — its human provides the retry delay — so this
// lives only in the background dispatcher; claude-codex still owns the authed
// call (the probe just asks it), keeping the D1 trust boundary intact.

// Backoff schedule between preflight probe attempts: 10s/20s/30s (=60s total).
// The refresh gap is a ~seconds window, so a modest schedule catches the common
// case; a gap that outlasts the whole schedule hits the refuse-on-exhaustion
// path (main), not an ever-longer wait. The total is deliberately BOUNDED and
// small because the preflight runs in the FOREGROUND before the worker — a
// long backoff plus a multi-minute worker could exceed a caller's foreground
// dispatch budget (codex-adv CR). Immediate (0-delay) retries are futile (the
// gap outlasts them). Overridable via CLAUDEX_AUTH_RETRY_DELAYS (comma-separated
// SECONDS); an empty/invalid value falls back (parsePct style).
export const DEFAULT_AUTH_RETRY_DELAYS_MS = [10_000, 20_000, 30_000];
export function parseAuthRetryDelaysMs(raw: string | undefined, fallbackMs: number[]): number[] {
  const s = raw?.trim();
  if (s === undefined || s === "") return fallbackMs;
  const toks = s.split(",").map((t) => t.trim()).filter((t) => t !== "");
  if (toks.length === 0) return fallbackMs;
  const secs = toks.map((t) => Number(t));
  if (secs.some((n) => !Number.isFinite(n) || n < 0)) return fallbackMs;
  const ms = secs.map((n) => Math.round(n * 1000));
  // Reject an absurd schedule rather than defeat the backoff (both CR):
  //  - 1e308 s overflows to Infinity once scaled to ms (coderabbit);
  //  - a finite value past Bun/Node's signed-32-bit setTimeout cap
  //    (2147483647 ms) is silently reset to ~1ms → immediate retry (codex-adv);
  //  - too many attempts, OR an aggregate that exceeds the bounded FOREGROUND
  //    deadline, would strand the invoking parent (codex-adv: a per-value cap
  //    alone still allows a ~25-day single sleep). Require a safe integer within
  //    the timer cap, at most MAX_AUTH_RETRY_ATTEMPTS delays, summing within
  //    MAX_TOTAL_BACKOFF_MS — else fall back to the small default.
  if (ms.some((n) => !Number.isSafeInteger(n) || n > MAX_TIMER_MS)) return fallbackMs;
  if (ms.length > MAX_AUTH_RETRY_ATTEMPTS) return fallbackMs;
  const totalMs = ms.reduce((a, b) => a + b, 0);
  // An all-zero schedule (e.g. "0,0") has budgetMs 0 → the deadline is `now()`,
  // so the very first probe gets a 0ms timeout and the loop breaks before any
  // re-probe: zero effective retries AND a killed first probe. Immediate retries
  // are documented futile anyway, so fall back to the real default (coderabbit CR).
  if (totalMs === 0 || totalMs > MAX_TOTAL_BACKOFF_MS) return fallbackMs;
  return ms;
}
// Bun/Node setTimeout delay is a signed 32-bit int; a larger value fires ~immediately.
export const MAX_TIMER_MS = 2_147_483_647;
// The preflight runs in the FOREGROUND before the worker, so its total wall-clock
// is hard-bounded: at most 8 backoff delays summing to ≤3 min, even under an
// operator override (codex-adv CR — otherwise a single huge delay strands the parent).
export const MAX_AUTH_RETRY_ATTEMPTS = 8;
export const MAX_TOTAL_BACKOFF_MS = 180_000;

// Dedicated launcher exit code for the transient codex OAuth-refresh gap
// (claude-codex --preflight-only). Keeps the retry from ever firing on a
// PERMANENT error (missing key = the launcher's early exit 2, egress refusal =
// 3, etc.), which would otherwise waste the whole backoff then launch a doomed
// worker (codex-adv CR). Keep in sync with scripts/claude-codex{,.ps1}.
export const CLAUDEX_PREFLIGHT_GAP_EXIT = 20;
// Hard per-probe wall-clock cap so ONE synchronous probe can never blow the
// preflight's absolute deadline (codex/coderabbit CR: spawnSync is not
// cancellable, so bound it at the source). Comfortably above the launcher's own
// curl -m 8 plus bash/guard overhead; a probe killed at this cap is transient.
export const PROBE_TIMEOUT_MS = 12_000;
export type AuthProbeResult = "ok" | "unavailable" | "fatal";

// Run the launcher's --preflight-only auth probe (no worker spawned). The
// launcher exercises the REAL upstream provider (a 1-token /v1/messages call),
// so this distinguishes:
//   exit 0                        ⇒ "ok"        (auth healthy, or a non-gap
//                                                 status the real run surfaces)
//   exit CLAUDEX_PREFLIGHT_GAP_EXIT⇒ "unavailable" (transient 503 refresh gap → retry)
//   any other nonzero             ⇒ "fatal"     (missing key / config / egress
//                                                 refusal — permanent; abort, do
//                                                 NOT retry or mint a worktree)
// A probe KILLED at PROBE_TIMEOUT_MS (spawnSync timeout → exitCode null +
// signalCode) is TRANSIENT, not fatal — the gate couldn't complete, so retry
// within the deadline rather than abort. TELEGRAM_OWN_POLLER is stripped
// (claudexChildEnv) so the probe never adopts poller ownership.
export function probeClaudexAuth(repoRoot: string, cwd: string, timeoutMs: number = PROBE_TIMEOUT_MS): AuthProbeResult {
  const launcherPath = claudexLauncherPath(repoRoot);
  const r = Bun.spawnSync(["bash", launcherPath, "--preflight-only"], { cwd, stdout: "pipe", stderr: "pipe", env: claudexChildEnv(process.env) as Record<string, string>, timeout: timeoutMs });
  if (r.exitCode === null || r.signalCode != null) return "unavailable"; // killed / timed out
  if (r.exitCode === 0) return "ok";
  if (r.exitCode === CLAUDEX_PREFLIGHT_GAP_EXIT) return "unavailable";
  return "fatal";
}

// Poll the auth probe with backoff BEFORE any worktree side-effect. Returns as
// soon as the probe is decisive:
//   {ready:true}              — auth healthy, spin the worker.
//   {fatal:true}             — a permanent config error; the caller aborts
//                              WITHOUT minting a worktree (no doomed run, no
//                              wasted backoff).
//   {ready:false,fatal:false}— still the transient gap after the whole schedule:
//                              REFUSED by the caller (don't launch into a known
//                              outage).
// An ABSOLUTE wall-clock deadline (start + Σdelays) bounds the WHOLE preflight —
// sleeps AND synchronous probe time — so it can NEVER exceed the budget (codex-adv
// CR: a per-delay cap alone ignored probe latency, and even a hard per-probe cap
// let the FINAL probe overshoot). Each backoff AND each probe timeout is clamped
// to the budget remaining at that instant, and the loop stops the moment the
// budget is spent — total elapsed ≤ deadline. `probe` receives its clamped
// timeout (ms); `probe`/`sleep`/`now` are injected so tests never spawn or wait.
export async function runAuthPreflightWithBackoff(
  probe: (timeoutMs: number) => AuthProbeResult,
  deps: { delaysMs: number[]; sleep: (ms: number) => Promise<void>; log?: (m: string) => void; now?: () => number },
): Promise<{ ready: boolean; fatal: boolean; attempts: number }> {
  const now = deps.now ?? (() => Date.now());
  const budgetMs = deps.delaysMs.reduce((a, b) => a + b, 0);
  // The deadline covers the configured SLEEPS **plus** a probe allowance — one
  // bounded probe per attempt (n delays ⇒ n+1 attempts). Without the allowance
  // probe time eats the sleep budget, silently truncating the last delay and
  // dropping the final probe, so recovery after the last wait is undetectable
  // and the advertised schedule never runs (coderabbit CR). Worst-case foreground
  // is therefore Σdelays + (n+1)·PROBE_TIMEOUT_MS — larger, but honest and hard.
  const probeAllowanceMs = (deps.delaysMs.length + 1) * PROBE_TIMEOUT_MS;
  const deadline = now() + budgetMs + probeAllowanceMs;
  const probeBudget = () => Math.min(PROBE_TIMEOUT_MS, Math.max(0, deadline - now()));
  let res = probe(probeBudget());
  let attempts = 1;
  if (res === "ok") return { ready: true, fatal: false, attempts };
  if (res === "fatal") return { ready: false, fatal: true, attempts };
  for (let i = 0; i < deps.delaysMs.length; i++) {
    const remaining = deadline - now();
    if (remaining <= 0) break; // out of the foreground budget (probes consumed it)
    const wait = Math.min(deps.delaysMs[i], remaining);
    deps.log?.(`spawn-claudex: codex auth unavailable (503 refresh gap?) on preflight ${i + 1}/${deps.delaysMs.length + 1}; backing off ${Math.round(wait / 1000)}s before re-probing (HIMMEL-1037)`);
    await deps.sleep(wait);
    if (deadline - now() <= 0) break; // budget spent by the sleep — do NOT probe past the deadline
    res = probe(probeBudget());
    attempts++;
    if (res === "ok") return { ready: true, fatal: false, attempts };
    if (res === "fatal") return { ready: false, fatal: true, attempts };
  }
  deps.log?.(`spawn-claudex: codex auth still unavailable after ${attempts} preflight attempt(s) across the ${Math.round(budgetMs / 1000)}s backoff schedule — refusing (likely a real outage, not the transient gap) (HIMMEL-1037)`);
  return { ready: false, fatal: false, attempts };
}

// ── dispatch through scripts/claude-codex (D1) ──────────────────────────────

// REPO_ROOT is derived from run.ts's OWN file location (see run.ts) —
// reliable when spawn-claudex.ts runs from the primary checkout (the common
// case for a parent/orchestrator session, per the design brief's explicit
// "resolved like run.ts's REPO_ROOT" instruction). A parent invoking this
// script from a worktree copy of itself would need CLAUDE_CODEX_DOTENV_ROOT
// set explicitly in its own env — out of v1 scope.
export function claudexLauncherPath(repoRoot: string): string {
  return join(repoRoot, "scripts", "claude-codex");
}

// cmd construction only — the launcher's own arg screen passes
// --permission-mode/the prompt through verbatim to `exec claude "$@"` (D1).
// NO --model flag: claude-codex pins CODEX_MODEL via ANTHROPIC_MODEL/
// ANTHROPIC_DEFAULT_*_MODEL itself; passing one here would fight that.
export function buildClaudexRunArgs(launcherPath: string, prompt: string, permMode?: PermissionMode): { cmd: string[] } {
  const cmd = permMode ? ["bash", launcherPath, "--permission-mode", permMode, prompt] : ["bash", launcherPath, prompt];
  return { cmd };
}

// Child env (D1): the base env passed straight through — NO ANTHROPIC_* var,
// NO GLM-style env block; scripts/claude-codex owns the entire trust
// boundary and sweeps ambient ANTHROPIC_*/CLAUDE_CODE_USE_* itself. The ONLY
// override this lane makes is the optional per-dispatch effort pin (D5,
// unset => the launcher's own `${CLAUDE_CODE_EFFORT_LEVEL:-high}` default
// applies), plus stripping TELEGRAM_OWN_POLLER so a spawned worker never
// adopts poller ownership (mirrors run.ts's sessionEnv/glmChildEnv).
// `base` is injected so this is testable without touching the real process.env.
export function claudexChildEnv(base: Record<string, string | undefined>, effort?: EffortLevel): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...base };
  if (effort) env.CLAUDE_CODE_EFFORT_LEVEL = effort;
  delete env.TELEGRAM_OWN_POLLER;
  return env;
}

export type ClaudexRunResult = { code: number; capped: boolean; blocked: boolean; timedOut: boolean; pid: number; tail?: string };

// The real bounded-run spawn (mirrors run.ts's runSession: stdin closed,
// hard process-TREE kill on timeout via the imported killTree, tail kept for
// run.log persistence). NOT unit-tested directly (it launches a real
// process) — executeClaudexRun below takes it as an injected dependency so
// tests stub it and never launch claude-codex/claude for real.
export async function runClaudexSession(prompt: string, cwd: string, opts: { permMode?: PermissionMode; effort?: EffortLevel; repoRoot: string }): Promise<ClaudexRunResult> {
  const launcherPath = claudexLauncherPath(opts.repoRoot);
  const { cmd } = buildClaudexRunArgs(launcherPath, prompt, opts.permMode);
  const env = claudexChildEnv(process.env, opts.effort);
  const p = spawn(cmd, { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe", env });
  const pid = p.pid;
  const timeoutMs = Number(process.env.RUN_TIMEOUT_MS ?? 30 * 60 * 1000);
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; killTree(pid, (s) => p.kill(s as any)); }, timeoutMs);
  let out: string, err: string, code: number;
  try {
    [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  } finally {
    clearTimeout(timer);
  }
  const tail = (out + err).slice(-65536);
  return { code: timedOut ? -1 : code, capped: detectClaudexCap(tail), blocked: detectContentFilter(tail), timedOut, pid, tail };
}

// The run-and-record step (mirrors spawn-glm's executeRun, minus the
// prompt-too-long classification and cap-guard resume scheduling — both
// GLM-specific / deferred here). meta.json ALWAYS leaves "running": the
// success path writes finalMeta (done/failed/capped/blocked/timeout), and a
// thrown run() writes {status:"failed", exit_code:-1} THEN rethrows.
export async function executeClaudexRun(deps: {
  run: (prompt: string, cwd: string, opts: { permMode?: PermissionMode; effort?: EffortLevel; repoRoot: string }) => Promise<ClaudexRunResult>;
  prompt: string; worktree: string; permMode?: PermissionMode; effort?: EffortLevel; repoRoot: string;
  sessionDir: string; metaPath: string; runningMeta: Record<string, unknown>;
}): Promise<{ code: number }> {
  try {
    const res = await deps.run(deps.prompt, deps.worktree, { permMode: deps.permMode, effort: deps.effort, repoRoot: deps.repoRoot });
    // run.log append is COSMETIC persistence — isolated so an I/O failure here
    // never flips a successful run to failed (mirrors spawn-glm's executeRun).
    if (res.tail !== undefined) {
      try { appendFileSync(join(deps.sessionDir, "run.log"), res.tail); }
      catch (e) { console.error(`spawn-claudex: run.log append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
    }
    const fm = finalMeta(res.code, res.pid, res.capped, res.blocked, res.timedOut);
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, ...fm }, null, 2));
    return { code: res.code };
  } catch (e) {
    writeFileSync(deps.metaPath, JSON.stringify({ ...deps.runningMeta, status: "failed", exit_code: -1, pid: 0 }, null, 2));
    throw e;
  }
}

// ── shared-branch dispatch (twin of spawn-glm's runSharedDispatch) ─────────
//
// Twinned rather than imported: spawn-glm's runSharedDispatch hardcodes
// "glm" as the lane argument to shared-branch-lock.sh acquire and its
// messages are "spawn-glm:"-prefixed — reusing it as-is would record a
// claudex dispatch's lock under the wrong lane name. The lifecycle itself
// (acquire -> capture prior pushurl -> poison -> runBody -> restore -> release
// in a finally) is identical; POISON_SENTINEL is imported so the I2
// crash-recovery compare can't drift from spawn-glm's own definition.
export async function runClaudexSharedDispatch(p: {
  repoDir: string; worktree: string; branch: string; needsWorktreeAdd: boolean;
  lockScript: string; gitAdd: () => void; runBody: () => Promise<number>;
  // codex-adv CR: re-validate the reused worktree AFTER the lock. The plan's
  // pre-lock cleanliness check can go stale — another shared worker may run
  // (and leave uncommitted changes) between it and this acquire. Called right
  // after acquire, before gitAdd/poison; returns ok:false to refuse (the finally
  // still releases the lock). Absent ⇒ skipped (own-mode / tests).
  revalidateClean?: () => { ok: true } | { ok: false; reason: string };
}): Promise<{ ok: true; code: number } | { ok: false; reason: string }> {
  const acquire = Bun.spawnSync(["bash", p.lockScript, "acquire", p.repoDir, p.branch, "codex"], { stdout: "pipe", stderr: "pipe" });
  if (acquire.exitCode !== 0) return { ok: false, reason: acquire.stderr.toString().trim() || `spawn-claudex: shared-branch-lock acquire failed (rc=${acquire.exitCode})` };
  let priorPushUrl: string | undefined;
  let poisoned = false;
  try {
    if (p.revalidateClean) { const rv = p.revalidateClean(); if (!rv.ok) return rv; } // stale-clean guard, lock released in finally
    if (p.needsWorktreeAdd) p.gitAdd(); // NO -b: an existing branch, never minted here
    const priorRes = Bun.spawnSync(["git", "-C", p.worktree, "config", "--worktree", "--get", "remote.origin.pushurl"], { stdout: "pipe", stderr: "pipe" });
    if (priorRes.exitCode === 0) {
      const got = priorRes.stdout.toString().trim();
      if (got !== POISON_SENTINEL) priorPushUrl = got;
    }
    poisonPushUrl(p.repoDir, p.worktree);
    poisoned = true;
    const code = await p.runBody();
    return { ok: true, code };
  } finally {
    try {
      if (poisoned) {
        const restore = priorPushUrl !== undefined
          ? Bun.spawnSync(["git", "-C", p.worktree, "config", "--worktree", "remote.origin.pushurl", priorPushUrl], { stdout: "pipe", stderr: "pipe" })
          : Bun.spawnSync(["git", "-C", p.worktree, "config", "--worktree", "--unset", "remote.origin.pushurl"], { stdout: "pipe", stderr: "pipe" });
        if (restore.exitCode !== 0 && !(priorPushUrl === undefined && restore.exitCode === 5)) {
          console.error(`spawn-claudex: WARNING - pushurl restore failed (rc=${restore.exitCode}); ${p.worktree} may stay push-poisoned: ${restore.stderr.toString().trim()}`);
        }
      }
    } catch (e) {
      console.error(`spawn-claudex: WARNING - pushurl restore threw (${String((e as any)?.message ?? e)}); ${p.worktree} may stay push-poisoned`);
    } finally {
      try {
        const rel = Bun.spawnSync(["bash", p.lockScript, "release", p.repoDir, p.branch], { stdout: "pipe", stderr: "pipe" });
        if (rel.exitCode !== 0) console.error(`spawn-claudex: WARNING - shared-branch-lock release failed (rc=${rel.exitCode}); the lock for ${p.branch} may stay held: ${rel.stderr.toString().trim()}`);
      } catch (e) {
        console.error(`spawn-claudex: WARNING - shared-branch-lock release threw (${String((e as any)?.message ?? e)}); the lock for ${p.branch} may stay held`);
      }
    }
  }
}

// ── main ─────────────────────────────────────────────────────────────────
//
// Exit codes: 1 = uncaught error (main().catch) · 2 = a refusal (usage, bank
// preflight, himmel-checkout / shared-branch plan, window preflight, --effort
// max/ultra) · 4 = shared-branch-lock acquire failure (parity with spawn-glm;
// there is no exit-3 GLM-guard equivalent here — claude-codex owns PHI/egress
// guarding itself, D1).
async function main(): Promise<void> {
  const parsed = parseClaudexArgs(process.argv.slice(2));
  const usage = "usage: spawn-claudex <prompt> [--cwd <dir>] [--name <slug>] [--branch <existing-branch>] [--timeout-mins <n>] [--permission-mode bypassPermissions] [--effort low|medium|high|xhigh] [--force] [--skip-auth-preflight]";
  if (!parsed.ok) { console.error(`spawn-claudex: ${parsed.error}`); console.error(usage); process.exit(2); }
  const { task, cwd, name, branch: branchArg, timeoutMins, permMode, effort, force, skipAuthPreflight } = parsed.args;
  if (!task) { console.error(usage); process.exit(2); }
  const absCwd = resolve(cwd);

  // Codex weekly bank preflight (D4) BEFORE any worktree/branch side-effect.
  const usedPct = fetchCodexWeeklyUsedPercent(homedir());
  const bankOverride = force || process.env.CLAUDEX_BANK_OK === "1";
  const bank = evaluateCodexBankPreflight(usedPct, {
    warnPct: parsePct(process.env.CLAUDEX_BANK_WARN_PCT, 80),
    refusePct: parsePct(process.env.CLAUDEX_BANK_REFUSE_PCT, 90),
    override: bankOverride,
  });
  if (bank.message) console.error(`spawn-claudex: ${bank.message}`);
  if (bank.action === "refuse") process.exit(2);

  const sharedMode = branchArg !== undefined;
  let slug: string, worktree: string, branch: string, needsWorktreeAdd: boolean;
  if (branchArg !== undefined) {
    const plan = planClaudexSharedSpawn(absCwd, branchArg, {
      isHimmelCheckout,
      branchExists: (b) => gitBranchExists(absCwd, b),
      worktreeOf: (b) => gitWorktreeOf(absCwd, b),
      isDirty: (p) => gitIsDirty(p),
    });
    if (!plan.ok) { console.error(plan.reason); process.exit(2); }
    ({ slug, worktree, branch, needsWorktreeAdd } = plan);
  } else {
    const plan = planClaudexSpawn(absCwd, name, { isHimmelCheckout });
    if (!plan.ok) { console.error(plan.reason); process.exit(2); }
    ({ slug, worktree, branch } = plan);
    needsWorktreeAdd = true;
  }

  // Per-model window preflight (HIMMEL-740 pattern, reused): refuse a brief
  // that cannot fit BEFORE any side effect. 272_000 is the GPT-5.6 2x-billing
  // ceiling documented in docs/tooling-catalog.md#claude-codex — kept under
  // it rather than a raw context-window max, since going past it silently
  // doubles the codex-bank spend for this dispatch.
  const CLAUDEX_WINDOW_TOKENS = 272_000;
  const sessionDir = join(claudexSessionRoot(), `claudex-${slug}-${Date.now()}`);
  const briefText = composeClaudexWorkerPrompt(task, sessionDir, branch, { shared: sharedMode });
  const overheadChars = measureOverheadChars(absCwd, homedir());
  const pre = preflightWindowCheck({ briefChars: briefText.length, overheadChars, windowTokens: CLAUDEX_WINDOW_TOKENS });
  if (!pre.ok) { console.error(pre.reason); process.exit(2); }

  // Auth preflight (HIMMEL-1037): wait out a transient codex OAuth-refresh gap
  // (503 auth_unavailable) BEFORE any worktree side-effect but AFTER all the
  // side-effect-free local validation (bank/plan/window) — so a deterministic
  // refusal (bad branch, dirty/primary/trunk worktree, brief-too-big) fails
  // FAST and locally, never wasting billable probes or masking itself behind an
  // auth failure (codex-adv CR). The shared-worktree race a long backoff could
  // open is handled under the lock by runClaudexSharedDispatch.revalidateClean.
  // REFUSES (no worktree, no worker) on `!ready` — BOTH a permanent failure
  // (pf.fatal) AND an exhausted transient gap. The probe is claude-codex's own
  // authed check, so no key is handled here (D1). The ONLY override is the
  // EXPLICIT per-invocation --skip-auth-preflight flag, never an env var: an
  // ambient/inherited setting that silently disabled this gate would restore the
  // exact unattended startup failure this branch fixes (codex-adv CR).
  if (skipAuthPreflight) {
    console.error("spawn-claudex: WARNING - --skip-auth-preflight given: the codex auth gate is DISABLED for this dispatch. The worker may launch straight into a 503 refresh gap / invalid auth, die at startup, and strand a worktree (HIMMEL-1037).");
  } else {
    const preflightDelaysMs = parseAuthRetryDelaysMs(process.env.CLAUDEX_AUTH_RETRY_DELAYS, DEFAULT_AUTH_RETRY_DELAYS_MS);
    const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
    const pf = await runAuthPreflightWithBackoff((t) => probeClaudexAuth(REPO_ROOT, absCwd, t), { delaysMs: preflightDelaysMs, sleep, log: (m) => console.error(m) });
    if (!pf.ready) {
      console.error(pf.fatal
        ? "spawn-claudex: codex auth preflight reports a PERMANENT failure (missing/invalid CLIPROXY_API_KEY, a deterministic auth 4xx like 401/403, curl unavailable, or a config/egress refusal — NOT a transient 5xx/timeout, which is retried) — aborting before any worktree; fix the claude-codex config, then re-dispatch (HIMMEL-1037)."
        : "spawn-claudex: codex auth still unavailable (503 refresh gap / transient 5xx/timeout) after the full backoff budget — refusing rather than launch into a known-doomed auth state (would reproduce the failure and strand a worktree); re-dispatch once the gateway recovers (HIMMEL-1037).");
      process.exit(2);
    }
  }

  const g = (args: string[]) => { const r = Bun.spawnSync(["git", "-C", absCwd, ...args], { stdout: "pipe", stderr: "pipe" }); if (r.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${r.stderr.toString()}`); };

  // The run body (mkdir sessionDir through executeClaudexRun) is IDENTICAL
  // between own-branch and shared modes; only the surrounding worktree
  // creation/mutation + lock ownership differ, below (mirrors spawn-glm).
  const runBody = async (): Promise<number> => {
    mkdirSync(sessionDir, { recursive: true });
    const metaPath = join(sessionDir, "meta.json");
    const started_at = new Date().toISOString();
    const baseMeta = { status: "running", pid: 0, started_at, lane: "codex", task_name: slug };
    const runningMeta = sharedMode ? { ...baseMeta, shared_branch: branch } : baseMeta;
    writeFileSync(metaPath, JSON.stringify(runningMeta, null, 2));

    const briefPath = join(sessionDir, "brief.md");
    writeFileSync(briefPath, briefText);
    const prompt = composeClaudexPointerPrompt(briefPath);
    if (timeoutMins !== undefined) process.env.RUN_TIMEOUT_MS = String(timeoutMins * 60 * 1000);

    // The worker runs EXACTLY ONCE — the transient codex OAuth gap is waited out
    // by the pre-launch auth preflight in main() (HIMMEL-1037), never by
    // re-running a worker (which could duplicate the worker's allowed side
    // effects). No retry wrapper here.
    const { code } = await executeClaudexRun({ run: runClaudexSession, prompt, worktree, permMode, effort, repoRoot: REPO_ROOT, sessionDir, metaPath, runningMeta });
    return code;
  };

  let code: number;
  if (!sharedMode) {
    g(["worktree", "add", worktree, "-b", branch]);
    poisonPushUrl(absCwd, worktree);
    code = await runBody();
  } else {
    // Serialize writers on the shared branch (single-writer invariant,
    // CLAUDE.md Subagent policy). Lock acquired AFTER guards pass, BEFORE any
    // worktree mutation, released in a finally on every catchable exit path.
    const lockScript = join(REPO_ROOT, "scripts", "lib", "shared-branch-lock.sh");
    const shared = await runClaudexSharedDispatch({
      repoDir: absCwd, worktree, branch, needsWorktreeAdd, lockScript,
      gitAdd: () => g(["worktree", "add", worktree, branch]), runBody,
      // codex-adv CR: re-resolve the REUSED worktree's identity + cleanliness
      // under the lock (branch could be switched/dirtied since the plan).
      revalidateClean: () => revalidateSharedWorktree({
        needsWorktreeAdd, branch, worktree,
        worktreeOf: (b) => gitWorktreeOf(absCwd, b),
        isDirty: (p) => gitIsDirty(p),
      }),
    });
    if (!shared.ok) { console.error(shared.reason); process.exit(4); }
    code = shared.code;
  }

  console.log(`session-dir: ${sessionDir}`);
  console.log(`transcript-dir: ${transcriptDirFor(worktree)}`);
  console.log(`exit: ${code}`);
  process.exit(code);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`spawn-claudex: ${String(e?.message ?? e)}`); process.exit(1); });
}
