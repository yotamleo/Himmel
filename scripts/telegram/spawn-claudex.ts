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
// preflightWindowCheck, measureOverheadChars, finalMeta) rather than
// copy-pasted. Everything GLM-branded (worker
// prompt, plan functions, args parser, the shared-dispatch lock lifecycle,
// main) is twinned here with codex/claudex wording and a claudex/<slug>
// branch — see the design brief (HIMMEL-1003) for the twin/import split.
//
// Fresh-context (HIMMEL-1001 D5): every dispatch is a NEW Claude Code
// session — Claude Code gives each subagent/session its own context, so
// there is no v2-subagent-history-copy and no fast-mode toggle to carry or
// disable here; nothing to implement for that requirement.
import { existsSync, mkdirSync, writeFileSync, appendFileSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { spawn } from "bun";
import { BASH_BIN, REPO_ROOT, killTree, detectContentFilter, NON_INTERACTIVE_EDITOR_ENV, type PermissionMode } from "./run";
import { SPAWN_OWN_GROUP } from "../lib/kill-tree.mjs";
import { transcriptDirFor, PUSH_PROTECTION_DISCLOSURE, ensureWorkspaceTrust, preflightWindowCheck, measureOverheadChars, finalMeta, resolveProfileSettings, teardownMintedWorktree, DEFAULT_LANE_PROFILE, mintRetaskNonce, composeRetaskBlock, STASH_BAN_LINE, composeBashShapeWarning, composeOutboxWriteHint, composeWorkerSettings, refuseBypassPermissions, refuseUnknownPermissionMode, isHelpFlag, writeLiveWorkerMeta, readBriefFile } from "./spawn-glm";
// HIMMEL-1553: symptom-brief loop breaker, two-stage — shared with spawn-glm
// so both worker lanes carry one decision table: invariant required at the
// warn stage, cheap lane refused at the escalate stage. Thresholds live in
// round-guard.ts (ROUND_WARN_THRESHOLD / ROUND_ESCALATE_THRESHOLD) — not
// restated here, so this comment cannot drift off the code (glm-4, CR round 2).
import { checkRoundGuard } from "./round-guard";
// HIMMEL-1778: huge-diff lane guard — shared module (one predicate, both
// lanes; never copy-pasted — see huge-diff-guard.ts for the incident).
import { checkHugeDiff } from "./huge-diff-guard";
// HIMMEL-1040 plugin profiles: same per-dispatch lean-profile injection as the
// GLM lane. spawn-claudex dispatches through scripts/claude-codex, which already
// screens + forwards --settings — so the resolved payload just rides its argv.
import { parseAddPlugins } from "../lanes/plugin-profiles.mjs";
// HIMMEL-2154: shared declarative flag-table parser — see spawn-glm.ts's
// GLM_FLAG_TABLE for the twin.
import { parseLaneArgs, type FlagTable } from "./lane-args";
import { CODEX_BANK_PROBE_REMEDY, readCodexBankCache } from "../lanes/bank-status-core.mjs";

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
export function composeClaudexWorkerPrompt(task: string, sessionDir: string, branch: string, opts?: { shared?: boolean; model?: string }): string {
  const outbox = join(sessionDir, "outbox.jsonl");
  const context = join(sessionDir, "context.md");
  const rawModel = opts?.model ?? "gpt-5.6-sol";
  // HIMMEL-1927 CR: opts.model is exported/programmatic-caller-facing (the
  // CLI --model path is already restricted to a fixed enum at parse time —
  // see parseClaudexArgs below), so a newline-bearing value must not land
  // verbatim in the dispatched worker's prompt. Degrade to a generic phrase
  // outside a plain slug shape; gpt-5.6-sol/terra/luna are unaffected.
  const resolvedModel = /^[A-Za-z0-9._-]+$/.test(rawModel) ? rawModel : "an unrecognized codex slug";
  // HIMMEL-1342: shared mode's ONE sanctioned base-integration verb is
  // `git merge main`. An earlier revision of this PR permitted `git rebase
  // main` instead (per-commit conflict surfacing is gentler on a stale
  // branch: one merge once produced a ~400-file conflict set where a rebase
  // would have surfaced ~7 small ones) — but a rebase REWRITES the branch's
  // published SHAs, and publishing a rewritten branch requires the force-push
  // this same brief bans, so the carve-out was inert as written: permitted,
  // never publishable (PR #1458 CR round). A merge commit ADDS to history
  // without touching any existing SHA, so the validating session that owns
  // the git surface publishes the result with an ordinary fast-forward push.
  // reset/rebase/amend/force stay banned wholesale. Single-writer is
  // unaffected: the merge runs under the lock during runBody, exactly like
  // any other worker git op.
  const branchLine = opts?.shared
    ? `Work ONLY inside your current directory (a dedicated git worktree). The branch ${branch} is a SHARED PR branch with EXISTING history, already checked out — do NOT create a new branch, do NOT reset/rebase/amend/force-anything. To make a change, ADD new commits on top only — never rewrite an existing commit to alter what it did. To bring this branch up to date with its PR base, run \`git merge main\` and resolve any conflicts — a merge commit ADDS to history without rewriting any existing SHA, so the session that publishes your branch needs only an ordinary fast-forward push; a rebase would rewrite the branch's published SHAs and force a force-push, and both stay banned (HIMMEL-1342). A lock serializes writers, so no other worker touches this branch while you run.`
    : `Work ONLY inside your current directory (a dedicated git worktree). Commit your work on the branch ${branch} which is already checked out.`;
  return [
    `You are an unattended claudex-lane worker session (himmel offload, codex weekly bank, HIMMEL-654/979/1003) — do the scoped chunk below and stop, do not expand scope.`,
    // HIMMEL-1927: outbound HTTP captured the resolved Codex slug, and worker
    // transcripts echoed it on every assistant message; Claude Code's Opus 4.8
    // assertion is only its fallback for an unrecognized model slug.
    `Your backend model is ${resolvedModel} (OpenAI, via the local CLIProxyAPI codex proxy). Claude Code does not recognize that slug, so it asserts 'You are powered by the model named Opus 4.8' in your system prompt — that is a slug-recognition artifact, not your identity. You are NOT an Anthropic model and NOT an orchestrator tier; do not reason about your own capabilities or delegation tier from that line.`,
    branchLine,
    `HARD RULES: never push, never open a PR — a validating session reviews your branch and owns the git/PR surface. Jira updates (status, comments, followup tickets) ARE allowed via node scripts/jira/dist/index.js (audited + recoverable). If a step is hard-blocked, skip it, continue the rest of the task, and note the skipped step in your final ${context} summary — v1 has no escalation channel to append to.`,
    // HIMMEL-1755: shared with the GLM lane so both briefs carry identical text.
    STASH_BAN_LINE,
    // HIMMEL-1218: RETASK channel — see spawn-glm.ts's composeWorkerPrompt for
    // the same block; imported verbatim so both lanes carry identical rules text.
    composeRetaskBlock(mintRetaskNonce()),
    // HIMMEL-1378: same HIMMEL-203 bash-shape warning as the GLM twin — see
    // spawn-glm.ts's composeBashShapeWarning for the root-cause evidence.
    composeBashShapeWarning(outbox),
    composeOutboxWriteHint(outbox),
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

// ── HIMMEL-1503: primary-checkout cwd guard ─────────────────────────────
//
// Twinned (not imported — deliberately duplicated per the ticket's brief:
// a small guard duplicated across the two lane wrappers, not a new shared
// layer) from spawn-glm.ts's own detectNonPrimaryCwd/refuseNonPrimaryCwd —
// see that file's comment for the full incident + detection rationale.
// Same detection, same message shape, only the "spawn-claudex:" prefix
// differs.
function gitDirs(cwd: string): { gitDir: string; commonDir: string } | null {
  const gd = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--git-dir"], { stdout: "pipe", stderr: "pipe" });
  const cd = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--git-common-dir"], { stdout: "pipe", stderr: "pipe" });
  if (gd.exitCode !== 0 || cd.exitCode !== 0) return null;
  return { gitDir: gd.stdout.toString().trim(), commonDir: cd.stdout.toString().trim() };
}

export function detectNonPrimaryCwd(cwd: string, probe: (cwd: string) => { gitDir: string; commonDir: string } | null = gitDirs): { ok: true } | { ok: false; primaryPath?: string } {
  const norm = (p: string) => p.replace(/\\/g, "/");
  const pathLooksLikeWorktree = norm(cwd).includes("/.claude/worktrees/");
  const dirs = probe(cwd);
  const gitSaysWorktree = dirs !== null && norm(dirs.gitDir) !== norm(dirs.commonDir);
  if (!pathLooksLikeWorktree && !gitSaysWorktree) return { ok: true };
  const primary = dirs ? dirname(resolve(cwd, dirs.commonDir)) : undefined;
  // Only name a primary that is somewhere ELSE — see spawn-glm.ts's twin for
  // the full rationale (a standalone repo nested under .claude/worktrees/
  // resolves to the very cwd being refused).
  const usable = primary !== undefined && norm(resolve(primary)) !== norm(resolve(cwd));
  return { ok: false, primaryPath: usable ? primary : undefined };
}

export function refuseNonPrimaryCwd(cwd: string, probe?: (cwd: string) => { gitDir: string; commonDir: string } | null): string | undefined {
  const r = probe ? detectNonPrimaryCwd(cwd, probe) : detectNonPrimaryCwd(cwd);
  if (r.ok) return undefined;
  return r.primaryPath
    ? `spawn-claudex: refusing to dispatch from ${cwd} — this is not the PRIMARY checkout (resolved primary: ${r.primaryPath}); cd there and retry (HIMMEL-1503).`
    : `spawn-claudex: refusing to dispatch from ${cwd} — this looks like a worktree cwd (path contains /.claude/worktrees/), not the PRIMARY checkout; cd to the primary checkout and retry (HIMMEL-1503).`;
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
// HIMMEL-1464: per-dispatch codex tier selector. Kept to the three tiers the
// local CLIProxyAPI proxy exposes for the codex subscription (verified live).
// scripts/claude-codex's own CODEX_MODEL knob stays UNVALIDATED by design — it
// documents "all overridable per task" against whatever the proxy's /v1/models
// serves, and the proxy currently serves other models beyond these three, so a
// hardcoded allowlist at the launcher would be a regression, not a fix. This
// allowlist is scoped to the NEW spawn-claudex flag only: a fresh interface can
// be strict without breaking the launcher's existing direct-invocation contract.
// Broader launcher-side validation (against the proxy's LIVE /v1/models) stays
// open on HIMMEL-1464.
export type CodexModelTier = "gpt-5.6-sol" | "gpt-5.6-terra" | "gpt-5.6-luna";
export type ClaudexParsedArgs = { task?: string; briefFile?: string; cwd: string; name?: string; branch?: string; timeoutMins?: number; permMode?: PermissionMode; effort?: EffortLevel; model?: CodexModelTier; force: boolean; skipAuthPreflight: boolean; profile: string; addPlugins: string[]; roundsOverride?: string };

// HIMMEL-2154: the declarative flag table for parseClaudexArgs — mirrors
// spawn-glm.ts's GLM_FLAG_TABLE (shared loop mechanics live in
// lane-args.ts's parseLaneArgs). Each entry is the exact per-flag validation
// the old inline if/else chain had.
const CLAUDEX_FLAG_TABLE: FlagTable<ClaudexParsedArgs> = {
  "--cwd": { kind: "value", apply: (s, v) => { s.cwd = v; return undefined; } },
  "--name": { kind: "value", apply: (s, v) => { s.name = v; return undefined; } },
  "--branch": { kind: "value", apply: (s, v) => { s.branch = v; return undefined; } },
  "--timeout-mins": {
    kind: "value",
    apply: (s, v) => {
      const n = Number(v);
      if (!Number.isFinite(n) || n <= 0) return `--timeout-mins must be a positive number (got "${v}")`;
      s.timeoutMins = n;
      return undefined;
    },
  },
  "--permission-mode": {
    kind: "value",
    apply: (s, v) => {
      const err = refuseUnknownPermissionMode(v);
      if (err) return err;
      s.permMode = v as PermissionMode;
      return undefined;
    },
  },
  // --effort (HIMMEL-1001 D5): refuse `max` (undocumented codex juice) and
  // `ultra` (unreachable from Claude Code — falls back to xhigh) with a message
  // pointing at the operating-rules doc, rather than silently forwarding them.
  "--effort": {
    kind: "value",
    apply: (s, v) => {
      if (v === "max" || v === "ultra") return `--effort ${v} is refused — 'max' is undocumented codex juice and 'ultra' is unreachable from Claude Code (silently falls back to xhigh); the HIMMEL-1001 ladder tops out at xhigh. See docs/tooling-catalog.md#claude-codex.`;
      if (v !== "low" && v !== "medium" && v !== "high" && v !== "xhigh") return `--effort must be one of low|medium|high|xhigh (got "${v}"); see docs/tooling-catalog.md#claude-codex`;
      s.effort = v;
      return undefined;
    },
  },
  // HIMMEL-1464: per-dispatch codex tier pin (e.g. to bench gpt-5.6-luna).
  // Sets CODEX_MODEL in the worker's child env — validated ONLY here, not by
  // scripts/claude-codex (its CODEX_MODEL knob stays unvalidated by design;
  // see the CodexModelTier comment above).
  "--model": {
    kind: "value",
    apply: (s, v) => {
      if (v !== "gpt-5.6-sol" && v !== "gpt-5.6-terra" && v !== "gpt-5.6-luna") return `--model must be one of gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna (got "${v}"); see docs/tooling-catalog.md#claude-codex`;
      s.model = v;
      return undefined;
    },
  },
  "--force": { kind: "bool", apply: (s) => { s.force = true; } },
  // Auth-preflight override is an EXPLICIT per-invocation flag, never an env
  // var: an ambient/inherited setting must not be able to silently disable the
  // fail-closed auth gate and restore the original startup failure (codex-adv CR).
  "--skip-auth-preflight": { kind: "bool", apply: (s) => { s.skipAuthPreflight = true; } },
  // HIMMEL-1040: --profile (default lane-impl) + --add-plugins overlay, resolved
  // in main() so a bad name/id is a clean pre-side-effect refusal (mirrors spawn-glm).
  "--profile": { kind: "value", apply: (s, v) => { s.profile = v; return undefined; } },
  "--add-plugins": { kind: "value", apply: (s, v) => { s.addPlugins.push(...parseAddPlugins(v)); return undefined; } },
  // HIMMEL-1553: recorded operator override for the round guard's cheap-lane
  // refusal — same contract as spawn-glm (substance enforced by the guard).
  "--rounds-override": {
    kind: "value",
    missingValueError: "--rounds-override requires a value (why another cheap-lane round is justified)",
    apply: (s, v) => { s.roundsOverride = v; return undefined; },
  },
  // HIMMEL-1780: --brief-file reads the TASK from a file, so a multi-line
  // dispatch is ONE literal command (`bun scripts/telegram/spawn-claudex.ts
  // --brief-file <path> ...`) instead of the cd/$(cat)/var compound that
  // defeats both the allow-rule prefix and the native permission matcher
  // (HIMMEL-203). The file is READ in main(), not here — parseClaudexArgs
  // stays pure (fs-free); the read itself is spawn-glm's exported
  // readBriefFile (one fail-closed implementation across both lanes).
  "--brief-file": { kind: "value", apply: (s, v) => { s.briefFile = v; return undefined; } },
};

// Pure + validated, mirrors spawn-glm's parseArgs (a value-taking flag with no
// value, or a non-positive/non-finite --timeout-mins, is a usage refusal).
export function parseClaudexArgs(argv: string[]): { ok: true; args: ClaudexParsedArgs } | { ok: false; error: string } {
  const args: ClaudexParsedArgs = {
    task: undefined, briefFile: undefined, cwd: process.cwd(), name: undefined, branch: undefined,
    timeoutMins: undefined, permMode: undefined, effort: undefined, model: undefined, force: false,
    skipAuthPreflight: false, profile: DEFAULT_LANE_PROFILE, addPlugins: [], roundsOverride: undefined,
  };
  const result = parseLaneArgs(argv, CLAUDEX_FLAG_TABLE, args, (s, token) => { if (s.task === undefined) s.task = token; });
  if (!result.ok) return result;
  if (args.branch !== undefined && args.name !== undefined) return { ok: false, error: "--branch and --name are mutually exclusive (shared mode derives the slug from the branch)" };
  // HIMMEL-1780: --brief-file and a positional prompt are mutually exclusive —
  // the file's contents BECOME the task, so a co-supplied positional would be
  // silently dropped (or ambiguous about which brief wins). Refuse instead.
  if (args.briefFile !== undefined && args.task !== undefined) return { ok: false, error: "--brief-file and a positional prompt are mutually exclusive (pass the brief as a file or inline, not both)" };
  return { ok: true, args };
}

// ── codex weekly bank preflight (HIMMEL-1003 D4) ────────────────────────────
//
// HIMMEL-1003 v1 scope: deferred — quota-gauge ledger rows (parity with GLM's
// appendQuotaGauge/buildGlmRow observability). This preflight is the ONLY
// quota signal recorded for a claudex dispatch; a followup ticket adds a
// claudex row to the shared quota-gauge ledger.

// SOURCE (HIMMEL-1678): the TTL'd cache written by
// scripts/lanes/codex-bank-probe.ts, whose source of truth is
// `codex -s read-only -a untrusted app-server` -> JSON-RPC
// account/rateLimits/read. That is the ONLY surface that reports codex quota.
//
// What this replaced, kept as history so nobody resurrects it: a tail scan of
// ~/.codex/logs_2.sqlite for `"secondary":{"used_percent":N}`. That file is a
// LOG database and never carried a quota field at all, so the scan could only
// ever return null -> "unreadable" -> refuse. Every claudex dispatch was
// refused before it started; the verdict was the right answer to the wrong
// question.
//
// This preflight does NOT spawn the probe: spawning `codex app-server` per
// dispatch leaks a process whenever the kill fails, and the dispatch path is
// exactly where that would compound. A stale/absent cache refuses, and the
// refusal names the probe as the remedy.
const CODEX_BANK_CACHE_TTL_DEFAULT_SECONDS = 6 * 60 * 60; // matches bank-status.ts

export function codexBankCachePath(home: string, env: Record<string, string | undefined> = process.env): string {
  return env.CODEX_BANK_CACHE || join(home, ".himmel", "cache", "codex-bank.json");
}

export type CodexBankRead = { usedPct: number | null; reason: string | null };

// FAIL-CLOSED: every path that cannot establish a live weekly number returns
// usedPct null WITH a reason, and evaluateCodexBankPreflight turns that into a
// refusal. readFile is injected so this is testable without a real cache.
export function fetchCodexWeeklyUsedPercent(
  home: string,
  nowMs: number = Date.now(),
  ttlSeconds: number = CODEX_BANK_CACHE_TTL_DEFAULT_SECONDS,
  readFile: (path: string) => string = (path) => readFileSync(path, "utf8"),
): CodexBankRead {
  const path = codexBankCachePath(home);
  let text: string;
  try {
    text = readFile(path);
  } catch {
    return { usedPct: null, reason: `codex bank cache missing/unreadable at ${path} — ${CODEX_BANK_PROBE_REMEDY}` };
  }
  const result = readCodexBankCache(text, nowMs, ttlSeconds);
  if (result.kind !== "measured") return { usedPct: null, reason: result.reason };
  // The weekly window is the bank this lane spends. readCodexBankCache has
  // already dropped any limit whose window reset and kept the GOVERNING
  // (highest-used) limit per window, so this is the number to gate on. Other
  // windows keep their own reset instants and are none of this lane's business
  // (HIMMEL-1725: no single global reset is ever synthesized).
  const weekly = result.readings.find((r) => r.window === "weekly");
  if (weekly === undefined) return { usedPct: null, reason: `codex bank cache holds no live WEEKLY window — ${CODEX_BANK_PROBE_REMEDY}` };
  return { usedPct: weekly.usedPct, reason: null };
}

// env-knob coercion, pure + tested (mirrors spawn-glm's parseWarnPct).
export function parsePct(raw: string | undefined, fallback: number): number {
  const s = raw?.trim();
  const n = Number(s);
  return s !== undefined && s !== "" && Number.isFinite(n) && n >= 0 && n <= 100 ? n : fallback;
}

export type BankPreflightResult = { action: "ok" | "warn" | "refuse"; usedPct: number | null; message?: string };

// Pure decision fn (D4): WARN at warnPct, REFUSE at refusePct unless
// overridden (CLAUDEX_BANK_OK=1 / --force). An unreadable weekly bank refuses
// loudly: this preflight must never claim success when no check occurred.
// Rationale for refusing BEFORE any worktree side-effect: a capped worker
// dies mid-run — the tree survives but the work is lost.
export function evaluateCodexBankPreflight(usedPct: number | null, opts: { warnPct: number; refusePct: number; override: boolean; reason?: string | null }): BankPreflightResult {
  if (usedPct === null) {
    const why = opts.reason ?? `codex weekly bank unreadable — ${CODEX_BANK_PROBE_REMEDY}`;
    return opts.override
      ? { action: "warn", usedPct: null, message: `${why} — proceeding under explicit override after no bank preflight was possible` }
      : { action: "refuse", usedPct: null, message: `${why} — refusing because no bank preflight was possible. Override with CLAUDEX_BANK_OK=1 or --force only after checking capacity manually.` };
  }
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
// cancellable, so bound it at the source). HIMMEL-1380 (codex-adv CR): the old
// 12s cap left too little headroom once curl's own budget rose to -m 10 — the
// launcher's bash/guard overhead ALONE (sourcing config, egress checks, etc.,
// with no real network latency) was independently measured at several
// seconds on Windows Git Bash, so 10s curl + that overhead could exceed 12s
// and get the probe KILLED (misread as "unavailable") even on a healthy lane
// — the exact misclassification this ticket exists to fix. Raised to 25s:
// curl's 10s ceiling + a generous overhead allowance + margin.
export const PROBE_TIMEOUT_MS = 25_000;
export type AuthProbeResult = "ok" | "unavailable" | "fatal";

// Run the launcher's --preflight-only auth probe (no worker spawned). The
// launcher exercises the REAL upstream provider (a 16-token /v1/messages call,
// HIMMEL-1380 — a reasoning model emits reasoning tokens before content, so a
// 1-token budget was a poor liveness test), so this distinguishes:
//   exit 0                        ⇒ "ok"        (auth healthy, or a non-gap
//                                                 status the real run surfaces)
//   exit CLAUDEX_PREFLIGHT_GAP_EXIT⇒ "unavailable" (transient 503 refresh gap,
//                                                 408 probe timeout, etc. → retry)
//   any other nonzero             ⇒ "fatal"     (missing key / config / egress
//                                                 refusal — permanent; abort, do
//                                                 NOT retry or mint a worktree)
// A probe KILLED at PROBE_TIMEOUT_MS (spawnSync timeout → exitCode null +
// signalCode) is TRANSIENT, not fatal — the gate couldn't complete, so retry
// within the deadline rather than abort. TELEGRAM_OWN_POLLER is stripped
// (claudexChildEnv) so the probe never adopts poller ownership.
export function probeClaudexAuth(repoRoot: string, cwd: string, timeoutMs: number = PROBE_TIMEOUT_MS): AuthProbeResult {
  const launcherPath = claudexLauncherPath(repoRoot);
  const r = Bun.spawnSync([BASH_BIN, launcherPath, "--preflight-only"], { cwd, stdout: "pipe", stderr: "pipe", env: claudexChildEnv(process.env) as Record<string, string>, timeout: timeoutMs });
  if (r.exitCode === null || r.signalCode != null) return "unavailable"; // killed / timed out
  if (r.exitCode === 0) return "ok";
  if (r.exitCode === CLAUDEX_PREFLIGHT_GAP_EXIT) return "unavailable";
  // HIMMEL-1380: the launcher already logged "HTTP <code> — body: …" to its own
  // stderr right before this exit — forward it verbatim so the operator-facing
  // fatal message (below, in the caller) is backed by what was actually
  // measured instead of a fixed list of suspected causes.
  const evidence = r.stderr?.toString().trim();
  if (evidence) console.error(`spawn-claudex: ${evidence}`);
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
// script from a worktree copy of itself resolves REPO_ROOT to that worktree;
// claude-codex then self-heals its .env lookup via the worktree→primary fallback
// (HIMMEL-1482, scripts/lib/load-dotenv.sh _load_dotenv_primary_for), so no
// explicit CLAUDE_CODEX_DOTENV_ROOT is required for the key to resolve.
export function claudexLauncherPath(repoRoot: string): string {
  return join(repoRoot, "scripts", "claude-codex");
}

// cmd construction only — the launcher's own arg screen passes
// --permission-mode/--settings/the prompt through verbatim to `exec claude "$@"`
// (D1). NO --model flag is ever added to `cmd`: claude-codex pins the model via
// ANTHROPIC_MODEL/ANTHROPIC_DEFAULT_*_MODEL itself, derived from its OWN
// CODEX_MODEL env var (a `claude` CLI flag here would fight that). spawn-claudex's
// --model (HIMMEL-1464) sets CODEX_MODEL in the child env instead — see
// claudexChildEnv — never a cmd-line flag.
// settings (HIMMEL-1040): the resolved plugin-profile `--settings` payload —
// claude-codex screens it (env-injection) then forwards it to claude. Omitted
// (operator profile) => no flag. Placed before the prompt, after --permission-mode.
export function buildClaudexRunArgs(launcherPath: string, prompt: string, permMode?: PermissionMode, settings?: string): { cmd: string[] } {
  const cmd = [BASH_BIN, launcherPath];
  if (permMode) cmd.push("--permission-mode", permMode);
  if (settings) cmd.push("--settings", settings);
  cmd.push(prompt);
  return { cmd };
}

// Child env (D1): the base env passed straight through — NO ANTHROPIC_* var,
// NO GLM-style env block; scripts/claude-codex owns the entire trust
// boundary and sweeps ambient ANTHROPIC_*/CLAUDE_CODE_USE_* itself. The ONLY
// overrides this lane makes are the optional per-dispatch effort pin (D5,
// unset => the launcher's own `${CLAUDE_CODE_EFFORT_LEVEL:-high}` default
// applies), the optional per-dispatch model pin (HIMMEL-1464, unset =>
// the launcher's own `${CODEX_MODEL:-gpt-5.6-sol}` default applies), the
// unconditional HIMMEL_WORKER worker-ness marker (HIMMEL-2085, see below) —
// plus stripping TELEGRAM_OWN_POLLER so a spawned worker never adopts poller
// ownership (mirrors run.ts's sessionEnv/glmChildEnv). `base` is injected so
// this is testable without touching the real process.env.
export function claudexChildEnv(base: Record<string, string | undefined>, effort?: EffortLevel, model?: CodexModelTier): Record<string, string | undefined> {
  // HIMMEL-1753: same no-op-editor pin as the glm/default lanes (see
  // NON_INTERACTIVE_EDITOR_ENV in run.ts) — a claudex worker also spawns with
  // stdin closed and could otherwise block behind an editor window.
  const env: Record<string, string | undefined> = { ...base, ...NON_INTERACTIVE_EDITOR_ENV };
  if (effort) env.CLAUDE_CODE_EFFORT_LEVEL = effort;
  if (model) env.CODEX_MODEL = model;
  // HIMMEL-2085: this lane had NO worker-ness marker at all — buildGlmEnv's
  // HIMMEL_GLM_WORKER only ever reached the GLM lane, so a native (Sonnet/
  // Opus-via-codex-proxy) dispatched worker carried no positive signal a hook
  // could gate on, leaving block-glm-external-writes.sh's pin-dir write-fence
  // (and any future worker-scoped guard keyed the same way) unable to see
  // this lane at all. HIMMEL_WORKER is the general marker every dispatched
  // worker lane's child-env builder sets — see glm-env.ts's buildGlmEnv for
  // the GLM twin.
  env.HIMMEL_WORKER = "1";
  delete env.TELEGRAM_OWN_POLLER;
  return env;
}

export type ClaudexEndReason = "clean" | "nonzero-exit" | "killed-at-deadline";
export type ClaudexRunResult = {
  code: number; capped: boolean; blocked: boolean; timedOut: boolean; pid: number; tail?: string;
  endReason?: ClaudexEndReason; elapsedMs?: number; stdoutBytes?: number; stderrBytes?: number;
  outputAnomaly?: "no-output-captured"; liveLogHandled?: boolean; unpersistedLogTail?: Uint8Array;
  timeoutForensicsPath?: string;
};

type ClaudexRunOpts = {
  permMode?: PermissionMode; effort?: EffortLevel; model?: CodexModelTier; repoRoot: string; settings?: string;
  runLogPath?: string; timeoutForensicsPath?: string;
};

const EMPTY_OUTPUT_NOTE = (endReason: ClaudexEndReason) =>
  `[spawn-claudex anomaly] child produced no stdout or stderr (0 bytes captured; end_reason=${endReason})\n`;

const LIVE_LOG_DISCONTINUITY_NOTE =
  "[spawn-claudex anomaly] live run.log persistence was incomplete; retained tail follows and may overlap earlier output\n";
const LIVE_LOG_APPEND_FAILURE_NOTE =
  "[spawn-claudex anomaly] live run.log append failed; queued suffix follows and may overlap only at the failed append boundary\n";
export const MAX_UNPERSISTED_LOG_BYTES = 1024 * 1024;

type CapturedByteCounts = {
  stdout: number | null;
  stderr: number | null;
  retainedTailBytes?: number;
};

function capturedByteCounts(res: ClaudexRunResult): CapturedByteCounts {
  // Injected/alternate runners written before HIMMEL-1943 only return `tail`.
  // The tail may be truncated and combines both channels, so its encoded size
  // describes only the retained artifact, not either channel's byte total.
  if (res.stdoutBytes === undefined && res.stderrBytes === undefined) {
    return {
      stdout: null,
      stderr: null,
      retainedTailBytes: new TextEncoder().encode(res.tail ?? "").byteLength,
    };
  }
  return { stdout: res.stdoutBytes ?? null, stderr: res.stderrBytes ?? null };
}

function noOutputCaptured(bytes: CapturedByteCounts): boolean {
  if (bytes.stdout === null || bytes.stderr === null) return false;
  return bytes.stdout + bytes.stderr === 0;
}

function finalClaudexMeta(res: ClaudexRunResult): ReturnType<typeof finalMeta> & Record<string, unknown> {
  const endReason = res.endReason ?? (res.timedOut ? "killed-at-deadline" : res.code === 0 ? "clean" : "nonzero-exit");
  const bytes = capturedByteCounts(res);
  const outputAnomaly = res.outputAnomaly ?? (noOutputCaptured(bytes) ? "no-output-captured" : undefined);
  return {
    ...finalMeta(res.code, res.pid, res.capped, res.blocked, res.timedOut),
    end_reason: endReason,
    elapsed_ms: res.elapsedMs ?? null,
    stdout_bytes: bytes.stdout,
    stderr_bytes: bytes.stderr,
    ...(bytes.retainedTailBytes !== undefined ? {
      retained_tail_utf8_bytes: bytes.retainedTailBytes,
      byte_counts_note: "unknown-legacy-tail-only",
    } : {}),
    ...(outputAnomaly ? { output_anomaly: outputAnomaly } : {}),
    ...(res.timeoutForensicsPath ? { timeout_forensics: res.timeoutForensicsPath } : {}),
  };
}

export function captureTimeoutForensics(path: string | undefined, cwd: string, elapsedMs: number, stdoutBytes: number, stderrBytes: number): boolean {
  if (!path) return false;
  const git = (args: string[]): string => {
    try {
      const r = Bun.spawnSync(["git", "-C", cwd, ...args], { stdout: "pipe", stderr: "pipe", timeout: 2_000 });
      const output = `${r.stdout.toString()}${r.stderr.toString()}`.trimEnd();
      if (r.exitCode === null || r.signalCode != null) return `[probe timed out or was killed]${output ? `\n${output}` : ""}`;
      return output || `[no output; exit ${r.exitCode}]`;
    } catch (e) {
      return `[probe threw: ${String((e as any)?.message ?? e)}]`;
    }
  };
  const status = git(["status", "--short"]);
  const head = git(["log", "-1", "--oneline"]);
  const report = [
    "spawn-claudex timeout forensics (captured after process exit and pipe drain)",
    `elapsed_ms: ${elapsedMs}`,
    "byte_counts_scope: final-after-process-exit-and-pipe-drain",
    `stdout_bytes: ${stdoutBytes}`,
    `stderr_bytes: ${stderrBytes}`,
    "",
    `$ git -C ${cwd} status --short`, status,
    "",
    `$ git -C ${cwd} log -1 --oneline`, head,
    "",
  ].join("\n");
  try { writeFileSync(path, report); return true; }
  catch (e) {
    console.error(`spawn-claudex: timeout forensics write failed (non-fatal): ${String((e as any)?.message ?? e)}`);
    return false;
  }
}

export async function killThenCaptureTimeoutForensics(kill: () => void, drain: () => Promise<void>, capture: () => boolean): Promise<boolean> {
  // The deadline is the kill boundary. The probes only observe the worktree,
  // so waiting for process exit + both pipes to drain before probing preserves
  // the evidence and makes the captured byte counts final without extending
  // the worker's execution beyond its configured deadline.
  kill();
  await drain();
  return capture();
}

const TIMEOUT_DRAIN_GRACE_MS = 5_000;

export async function awaitDrainWithBound(drain: Promise<unknown>, cancelPipes: () => void, graceMs: number = TIMEOUT_DRAIN_GRACE_MS): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const drained = await Promise.race([
    drain.then(() => true),
    new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(false), graceMs); }),
  ]);
  if (timer !== undefined) clearTimeout(timer);
  if (!drained) {
    // A descendant can inherit and retain the direct child's pipe handles even
    // after that child is reaped. Stop waiting on those OS handles after a
    // bounded grace period; cancelling the readers settles both consume()
    // promises, which are still awaited below before forensics are captured.
    cancelPipes();
    await drain;
  }
}

export function createClaudexLiveLogAppender(
  runLogPath: string | undefined,
  append: (path: string, chunk: Uint8Array) => void = (path, chunk) => appendFileSync(path, chunk),
): {
  append: (chunk: Uint8Array) => void;
  result: () => Pick<ClaudexRunResult, "liveLogHandled" | "unpersistedLogTail">;
} {
  let liveLogHandled = !!runLogPath;
  let liveLogBroken = false;
  let unpersistedLogBytes = 0;
  let unpersistedLogDropped = false;
  const unpersistedLogChunks: Uint8Array[] = [];
  const retain = (chunk: Uint8Array) => {
    if (unpersistedLogDropped) return;
    if (unpersistedLogBytes + chunk.byteLength > MAX_UNPERSISTED_LOG_BYTES) {
      // run.log is cosmetic: once exact recovery would exceed 1 MiB, release
      // the queued suffix and let executeClaudexRun persist its bounded tail
      // behind the existing discontinuity marker instead.
      unpersistedLogChunks.length = 0;
      unpersistedLogBytes = 0;
      unpersistedLogDropped = true;
      return;
    }
    unpersistedLogChunks.push(chunk.slice());
    unpersistedLogBytes += chunk.byteLength;
  };
  return {
    append(chunk) {
      if (!runLogPath) return;
      // Once an append fails, retain that chunk and every later chunk. This
      // gives the post-run fallback an exact suffix boundary and preserves
      // chronology without replaying output already written successfully.
      if (liveLogBroken) {
        retain(chunk);
        return;
      }
      try { append(runLogPath, chunk); }
      catch (e) {
        liveLogHandled = false;
        liveLogBroken = true;
        retain(chunk);
        console.error(`spawn-claudex: run.log append failed (non-fatal): ${String((e as any)?.message ?? e)}`);
      }
    },
    result() {
      let unpersistedLogTail: Uint8Array | undefined;
      if (!unpersistedLogDropped && unpersistedLogChunks.length > 0) {
        const note = new TextEncoder().encode(LIVE_LOG_APPEND_FAILURE_NOTE);
        // This final contiguous copy is bounded to the 1 MiB retained suffix
        // plus the fixed note; peak recovery storage is therefore ~2 MiB.
        unpersistedLogTail = new Uint8Array(note.byteLength + unpersistedLogBytes);
        unpersistedLogTail.set(note);
        let offset = note.byteLength;
        for (const chunk of unpersistedLogChunks) {
          unpersistedLogTail.set(chunk, offset);
          offset += chunk.byteLength;
        }
      }
      return { liveLogHandled, unpersistedLogTail };
    },
  };
}

// The real bounded-run spawn (mirrors run.ts's runSession: stdin closed,
// hard process-TREE kill on timeout via the imported killTree, tail kept for
// run.log persistence). NOT unit-tested directly (it launches a real
// process) — executeClaudexRun below takes it as an injected dependency so
// tests stub it and never launch claude-codex/claude for real.
export async function runClaudexSession(prompt: string, cwd: string, opts: ClaudexRunOpts, onSpawn?: (pid: number) => void): Promise<ClaudexRunResult> {
  const launcherPath = claudexLauncherPath(opts.repoRoot);
  const { cmd } = buildClaudexRunArgs(launcherPath, prompt, opts.permMode, opts.settings);
  const env = claudexChildEnv(process.env, opts.effort, opts.model);
  const startedAt = Date.now();
  // SPAWN_OWN_GROUP (HIMMEL-1956): killTree's POSIX half signals the process
  // GROUP, which only exists if the child leads one. Without it a timed-out
  // claudex worker's descendants survive and keep these pipes open.
  const p = spawn(cmd, { ...SPAWN_OWN_GROUP, cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe", env });
  const pid = p.pid;
  onSpawn?.(pid);
  const timeoutMs = Number(process.env.RUN_TIMEOUT_MS ?? 30 * 60 * 1000);
  let timedOut = false;
  let timeoutForensicsWritten = false;
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let stdoutTail = "";
  let stderrTail = "";
  const liveLog = createClaudexLiveLogAppender(opts.runLogPath);
  const consume = (stream: ReadableStream<Uint8Array>, channel: "stdout" | "stderr") => {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    const done = (async () => {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (channel === "stdout") stdoutBytes += value.byteLength;
        else stderrBytes += value.byteLength;
        liveLog.append(value);
        if (channel === "stdout") stdoutTail = (stdoutTail + decoder.decode(value, { stream: true })).slice(-65536);
        else stderrTail = (stderrTail + decoder.decode(value, { stream: true })).slice(-65536);
      }
      if (channel === "stdout") stdoutTail = (stdoutTail + decoder.decode()).slice(-65536);
      else stderrTail = (stderrTail + decoder.decode()).slice(-65536);
    })();
    return { done, cancel: () => { void reader.cancel().catch(() => {}); } };
  };
  const stdout = consume(p.stdout, "stdout");
  const stderr = consume(p.stderr, "stderr");
  const exited = p.exited;
  const drained = Promise.all([exited, stdout.done, stderr.done] as const);
  let timeoutTask: Promise<void> | undefined;
  const timer = setTimeout(() => {
    timedOut = true;
    timeoutTask = killThenCaptureTimeoutForensics(
      () => killTree(pid, (s) => p.kill(s as any)),
      () => awaitDrainWithBound(drained, () => { stdout.cancel(); stderr.cancel(); }),
      () => captureTimeoutForensics(opts.timeoutForensicsPath, cwd, Date.now() - startedAt, stdoutBytes, stderrBytes),
    ).then((written) => { timeoutForensicsWritten = written; });
  }, timeoutMs);
  let code: number;
  try {
    [code] = await drained;
  } finally {
    clearTimeout(timer);
  }
  // If the deadline fired, the timeout task owns the ordered cleanup. Do not
  // return while its drain/capture work is still in flight.
  if (timeoutTask) await timeoutTask;
  // Preserve the old read-once contract for callers: stdout followed by
  // stderr, capped to the final 64KiB-equivalent JS string slice.
  const tail = (stdoutTail + stderrTail).slice(-65536);
  const endReason: ClaudexEndReason = timedOut ? "killed-at-deadline" : code === 0 ? "clean" : "nonzero-exit";
  const outputAnomaly = stdoutBytes + stderrBytes === 0 ? "no-output-captured" as const : undefined;
  if (outputAnomaly && opts.runLogPath) {
    liveLog.append(new TextEncoder().encode(EMPTY_OUTPUT_NOTE(endReason)));
  }
  const { liveLogHandled, unpersistedLogTail } = liveLog.result();
  return {
    code: timedOut ? -1 : code,
    capped: detectClaudexCap(tail), blocked: detectContentFilter(tail), timedOut, pid, tail,
    endReason, elapsedMs: Date.now() - startedAt, stdoutBytes, stderrBytes, outputAnomaly,
    liveLogHandled, unpersistedLogTail,
    timeoutForensicsPath: timedOut && timeoutForensicsWritten ? opts.timeoutForensicsPath : undefined,
  };
}

export function writeClaudexLiveMeta(
  metaPath: string,
  runningMeta: Record<string, unknown>,
  extra: Record<string, unknown>,
  replace?: (tmpPath: string, destPath: string, json: string) => void,
): void {
  if (replace) writeLiveWorkerMeta(metaPath, runningMeta, extra, "spawn-claudex", replace);
  else writeLiveWorkerMeta(metaPath, runningMeta, extra, "spawn-claudex");
}

// The run-and-record step (mirrors spawn-glm's executeRun, minus the
// prompt-too-long classification and cap-guard resume scheduling — both
// GLM-specific / deferred here). meta.json ALWAYS leaves "running": the
// success path writes finalMeta (done/failed/capped/blocked/timeout), and a
// thrown run() writes {status:"failed", exit_code:-1} THEN rethrows.
export async function executeClaudexRun(deps: {
  run: (prompt: string, cwd: string, opts: ClaudexRunOpts, onSpawn?: (pid: number) => void) => Promise<ClaudexRunResult>;
  prompt: string; worktree: string; permMode?: PermissionMode; effort?: EffortLevel; model?: CodexModelTier; repoRoot: string;
  sessionDir: string; metaPath: string; runningMeta: Record<string, unknown>;
  // HIMMEL-1040: the resolved --settings plugin-profile payload (undefined = operator / no injection).
  settings?: string;
}): Promise<{ code: number }> {
  const recordLivePid = (pid: number) => {
    // Match spawn-glm's live metadata contract: arm-resume can only protect a
    // running claudex worker if meta.json stops advertising the bootstrap pid 0.
    // Write-then-rename keeps concurrent census readers off partial JSON; a
    // failed replace leaves an explicit unprobeable marker, never pid:0.
    writeClaudexLiveMeta(deps.metaPath, deps.runningMeta, { pid });
  };
  try {
    const runLogPath = join(deps.sessionDir, "run.log");
    const timeoutForensicsPath = join(deps.sessionDir, "timeout-forensics.txt");
    const res = await deps.run(deps.prompt, deps.worktree, { permMode: deps.permMode, effort: deps.effort, model: deps.model, repoRoot: deps.repoRoot, settings: deps.settings, runLogPath, timeoutForensicsPath }, recordLivePid);
    // run.log append is COSMETIC persistence — isolated so an I/O failure here
    // never flips a successful run to failed. Real runs stream live; injected
    // test/alternate runners retain the old post-run tail persistence fallback.
    if (!res.liveLogHandled) {
      const bytes = capturedByteCounts(res);
      const fallbackLog = res.unpersistedLogTail ?? (noOutputCaptured(bytes)
        ? EMPTY_OUTPUT_NOTE(res.endReason ?? (res.timedOut ? "killed-at-deadline" : res.code === 0 ? "clean" : "nonzero-exit"))
        : res.liveLogHandled === false
          ? `${LIVE_LOG_DISCONTINUITY_NOTE}${res.tail ?? ""}`
          : res.tail);
      try { if (fallbackLog !== undefined) appendFileSync(runLogPath, fallbackLog); }
      catch (e) { console.error(`spawn-claudex: run.log append failed (non-fatal): ${String((e as any)?.message ?? e)}`); }
    }
    const fm = finalClaudexMeta(res);
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
// (acquire -> runBody -> release in a finally) is identical. The pushurl
// quarantine both twins used to carry is gone (HIMMEL-1961 — see the removal
// note in spawn-glm.ts); this dispatch leaves the operator's git config
// untouched in every scope, and its report says push protection is
// contract-only.
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
  const acquire = Bun.spawnSync([BASH_BIN, p.lockScript, "acquire", p.repoDir, p.branch, "codex"], {
    stdout: "pipe", stderr: "pipe",
    env: { ...process.env, SHARED_BRANCH_LOCK_HOLDER_PID: String(process.pid) },
  });
  if (acquire.exitCode !== 0) return { ok: false, reason: acquire.stderr.toString().trim() || `spawn-claudex: shared-branch-lock acquire failed (rc=${acquire.exitCode})` };
  try {
    if (p.revalidateClean) { const rv = p.revalidateClean(); if (!rv.ok) return rv; } // stale-clean guard, lock released in finally
    if (p.needsWorktreeAdd) p.gitAdd(); // NO -b: an existing branch, never minted here
    // Unconditional (codex-adv, HIMMEL-1096 CR round): a REUSED managed
    // worktree (needsWorktreeAdd=false) from a pre-change or failed dispatch
    // may never have been trust-seeded — seeding is idempotent, so cover both.
    ensureWorkspaceTrust(p.worktree);
    const code = await p.runBody();
    return { ok: true, code };
  } finally {
    // Releasing the lock is the only cleanup left (HIMMEL-1961): a leaked lock
    // blocks the next writer on this branch, so a THROWING Bun.spawnSync must
    // degrade to a warning rather than out-rank an error already propagating.
    try {
      const rel = Bun.spawnSync([BASH_BIN, p.lockScript, "release", p.repoDir, p.branch], { stdout: "pipe", stderr: "pipe" });
      if (rel.exitCode !== 0) console.error(`spawn-claudex: WARNING - shared-branch-lock release failed (rc=${rel.exitCode}); the lock for ${p.branch} may stay held: ${rel.stderr.toString().trim()}`);
    } catch (e) {
      console.error(`spawn-claudex: WARNING - shared-branch-lock release threw (${String((e as any)?.message ?? e)}); the lock for ${p.branch} may stay held`);
    }
  }
}

// ── main ─────────────────────────────────────────────────────────────────
//
// Exit codes: 0 = --help/-h (usage printed to stdout, HIMMEL-1225) · 1 =
// uncaught error (main().catch) · 2 = a refusal (usage, bank preflight,
// himmel-checkout / shared-branch plan, window preflight, --effort
// max/ultra) · 4 = shared-branch-lock acquire failure (parity with spawn-glm;
// there is no exit-3 GLM-guard equivalent here — claude-codex owns PHI/egress
// guarding itself, D1).
async function main(): Promise<void> {
  const usage = "usage: spawn-claudex [<prompt> | --brief-file <path>] [--cwd <dir>] [--name <slug>] [--branch <existing-branch>] [--timeout-mins <n>] [--permission-mode dontAsk] [--effort low|medium|high|xhigh] [--model gpt-5.6-sol|gpt-5.6-terra|gpt-5.6-luna] [--profile <name>] [--add-plugins a@m,b@m] [--rounds-override <why>] [--force] [--skip-auth-preflight] (the prompt is the task brief, inline, or read verbatim from --brief-file — HIMMEL-1780; default --permission-mode: dontAsk; bypassPermissions is refused — HIMMEL-1378)";
  const rawArgv = process.argv.slice(2);
  // HIMMEL-1225: help short-circuit — before parseClaudexArgs, before any side effect.
  if (isHelpFlag(rawArgv)) { console.log(usage); process.exit(0); }
  const parsed = parseClaudexArgs(rawArgv);
  if (!parsed.ok) { console.error(`spawn-claudex: ${parsed.error}`); console.error(usage); process.exit(2); }
  const { task: taskArg, briefFile, cwd, name, branch: branchArg, timeoutMins, permMode: permModeArg, effort, model, force, skipAuthPreflight, profile, addPlugins, roundsOverride } = parsed.args;
  // HIMMEL-1780: --brief-file's contents BECOME the task (readBriefFile is
  // spawn-glm's exported fail-closed helper — one implementation across both
  // lanes). Read here — before any side effect and before every task-consuming
  // consumer below (round guard, bank preflight, plan, worker-prompt compose)
  // — so a missing/unreadable/empty file is a clean exit-2 usage refusal that
  // leaves no orphan worktree/branch/meta, and the file's brief flows into the
  // EXISTING <session-dir>/brief.md + pointer-prompt machinery unchanged.
  let task: string | undefined = taskArg;
  if (briefFile !== undefined) {
    const brief = readBriefFile(briefFile);
    if (!brief.ok) { console.error(`spawn-claudex: ${brief.error}`); console.error(usage); process.exit(2); }
    task = brief.task;
  }
  if (!task) { console.error(usage); process.exit(2); }
  // HIMMEL-1378: same structural forbid + worker default as spawn-glm.ts — see
  // its composeWorkerSettings/refuseBypassPermissions comment for the full
  // design rationale (twin lane, identical hang class + fix).
  const bypassRefusal = refuseBypassPermissions(permModeArg);
  if (bypassRefusal) { console.error(`spawn-claudex: ${bypassRefusal}`); console.error(usage); process.exit(2); }
  const unknownModeRefusal = refuseUnknownPermissionMode(permModeArg);
  if (unknownModeRefusal) { console.error(`spawn-claudex: ${unknownModeRefusal}`); console.error(usage); process.exit(2); }
  const permMode: PermissionMode = permModeArg ?? "dontAsk";
  const absCwd = resolve(cwd);
  // HIMMEL-1503: refuse BEFORE any worktree/branch side-effect if this
  // dispatch is not running from the PRIMARY checkout — see
  // detectNonPrimaryCwd above for the incident + detection rationale.
  const nonPrimaryRefusal = refuseNonPrimaryCwd(absCwd);
  if (nonPrimaryRefusal) { console.error(nonPrimaryRefusal); process.exit(2); }
  // HIMMEL-1553: refuse a symptom-loop dispatch BEFORE any side effect — same
  // two-stage guard + rationale as spawn-glm.ts (round-guard.ts has the
  // incident): invariant required at 2 reviewed rounds, cheap lane refused at 3.
  const roundGuard = checkRoundGuard("spawn-claudex", { task, branch: branchArg, name, cwd: absCwd, roundsOverride });
  if (roundGuard.refusal) { console.error(roundGuard.refusal); process.exit(2); }
  if (roundGuard.note) console.error(roundGuard.note);
  // HIMMEL-1040: validate the profile NAME + overlay ids BEFORE any side effect —
  // an unknown --profile / malformed --add-plugins id is a clean usage refusal
  // (exit 2), never an orphan worktree/branch. `installed: []` keeps this to pure
  // validation: the REAL deny baseline is computed later, in runBody, from the
  // WORKER'S worktree (CR) — that is the cwd claude actually runs in, and its
  // branch-local .claude/settings{,.local}.json can differ from the dispatcher's.
  try { resolveProfileSettings(profile, addPlugins, absCwd, []); }
  catch (e) { console.error(`spawn-claudex: ${String((e as any)?.message ?? e)}`); console.error(usage); process.exit(2); }

  // Codex weekly bank preflight (D4) BEFORE any worktree/branch side-effect.
  const bankRead = fetchCodexWeeklyUsedPercent(homedir());
  const bankOverride = force || process.env.CLAUDEX_BANK_OK === "1";
  const bank = evaluateCodexBankPreflight(bankRead.usedPct, {
    warnPct: parsePct(process.env.CLAUDEX_BANK_WARN_PCT, 80),
    refusePct: parsePct(process.env.CLAUDEX_BANK_REFUSE_PCT, 90),
    override: bankOverride,
    reason: bankRead.reason,
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
  const briefText = composeClaudexWorkerPrompt(task, sessionDir, branch, { shared: sharedMode, model });
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
        // HIMMEL-1380: name what was measured, not an asserted cause — the
        // "spawn-claudex: preflight probe observed HTTP …" line above (forwarded
        // from the launcher's own stderr) carries the actual status + body
        // excerpt. Only a 401/403 is a deterministic invalid-key signal; curl
        // unavailable and egress refusal are the other permanent causes, but a
        // bare CLIPROXY_API_KEY accusation is no longer asserted here.
        ? "spawn-claudex: codex auth preflight reports a PERMANENT failure — see the preflight-probe evidence line above for the observed status/body (only 401/403 means an invalid CLIPROXY_API_KEY; other causes: curl unavailable, or a config/egress refusal — NOT a transient 5xx/408/timeout, which is retried) — aborting before any worktree; fix the claude-codex config, then re-dispatch (HIMMEL-1037/1380)."
        : "spawn-claudex: codex auth still unavailable (503 refresh gap / transient 5xx/408/timeout) after the full backoff budget — refusing rather than launch into a known-doomed auth state (would reproduce the failure and strand a worktree); re-dispatch once the gateway recovers (HIMMEL-1037).");
      process.exit(2);
    }
  }

  const g = (args: string[]) => { const r = Bun.spawnSync(["git", "-C", absCwd, ...args], { stdout: "pipe", stderr: "pipe" }); if (r.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${r.stderr.toString()}`); };

  // The run body (mkdir sessionDir through executeClaudexRun) is IDENTICAL
  // between own-branch and shared modes; only the surrounding worktree
  // creation/mutation + lock ownership differ, below (mirrors spawn-glm).
  // HIMMEL-1094: onSetupFail runs ONLY if the profile resolve below throws —
  // i.e. before ANY of the worker's state exists. The own-branch caller passes a
  // teardown; shared mode passes nothing (runSharedDispatch calls runBody()).
  const runBody = async (onSetupFail?: () => void): Promise<number> => {
    // HIMMEL-1778: same seam as spawn-glm's twin — runBody runs in BOTH modes
    // after the branch exists and before the worker launches. Warn-only.
    const hugeDiff = checkHugeDiff("spawn-claudex", { cwd: worktree, branch });
    if (hugeDiff.note) console.error(hugeDiff.note);
    // HIMMEL-1040 (CR): resolve the profile FIRST — before meta.json is written.
    // resolveProfileSettings throws on an unreadable/malformed settings layer and
    // sits OUTSIDE executeClaudexRun's failure-transition guard; after the
    // "running" write a throw would leave meta stuck at running (a phantom worker
    // for fleet control). Resolving here keeps the "meta.json ALWAYS leaves
    // running" invariant. Uses the WORKTREE — the cwd the worker runs in.
    let settings: string;
    try {
      // HIMMEL-1378: same permission-hardening overlay as spawn-glm.ts's twin —
      // never optional, so --settings is now unconditionally passed.
      settings = composeWorkerSettings(resolveProfileSettings(profile, addPlugins, worktree), worktree, sessionDir);
    } catch (e) {
      // HIMMEL-1094: the resolve NEEDS the worktree cwd (branch-local settings
      // layers), so it necessarily runs after `worktree add` — which is why a
      // throw here would otherwise strand the worktree+branch we just minted.
      // Undo them, then rethrow the ORIGINAL error unchanged.
      onSetupFail?.();
      throw e;
    }
    mkdirSync(sessionDir, { recursive: true });
    const metaPath = join(sessionDir, "meta.json");
    const started_at = new Date().toISOString();
    // HIMMEL-1693 CR round 2: worker_worktree is what stop-worker.sh's
    // checkpoint_worker_worktree reads before signalling a worker -- without
    // it every Claudex session refused the stop (exit 5, "no worker worktree
    // recorded"). Same field spawn-glm.ts's baseMeta already writes.
    const baseMeta = { status: "running", pid: 0, started_at, lane: "codex", task_name: slug, worker_worktree: worktree };
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
    const { code } = await executeClaudexRun({ run: runClaudexSession, prompt, worktree, permMode, effort, model, repoRoot: REPO_ROOT, sessionDir, metaPath, runningMeta, settings });
    return code;
  };

  let code: number;
  if (!sharedMode) {
    g(["worktree", "add", worktree, "-b", branch]);
    ensureWorkspaceTrust(worktree);
    // HIMMEL-1094: this dispatch MINTED both the worktree and the branch (-b), so
    // it owns them until the worker starts. Teardown is passed ONLY here — shared
    // mode must never tear down a caller-owned worktree/branch.
    code = await runBody(() => teardownMintedWorktree(absCwd, worktree, branch));
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
  console.log(PUSH_PROTECTION_DISCLOSURE);
  console.log(`exit: ${code}`);
  process.exit(code);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`spawn-claudex: ${String(e?.message ?? e)}`); process.exit(1); });
}
