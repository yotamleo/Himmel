import { spawn } from "bun";
import { killTree, SPAWN_OWN_GROUP } from "../lib/kill-tree.mjs";
import { buildGlmEnv, GLM_MODEL_ALIAS } from "./glm-env";
import { existsSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

// Bounded-run spawn helper. Runs an INTERACTIVE `claude "<prompt>"` with stdin
// closed (EOF) so the session does one turn then exits cleanly — empirically
// `claude "<p>" </dev/null` exits 0 (~6s, Max quota, no -p). Strips
// TELEGRAM_OWN_POLLER from the child env so the spawned session never owns the
// poller. NO -p/--print/--channels — interactive billing + behaviour only.
// PermissionMode (HIMMEL-578): "bypassPermissions" is the vault-session mode
// (see runSession). "dontAsk" (HIMMEL-1378) is the GLM/claudex WORKER default —
// verified (`claude --help`, v2.1.220) as one of the CLI's native
// --permission-mode values, and the one Claude Code docs confirm auto-DENIES
// any tool call not explicitly allow-listed rather than ever prompting. That
// is the load-bearing property for an unattended, stdin-closed worker: a
// prompt it cannot answer would otherwise hang until the external timeout
// kills it (the HIMMEL-203 native-permission-matcher-bails shape this hook
// comment documents: scripts/hooks/auto-approve-safe-bash.sh). bypassPermissions
// is NEVER used for an unattended worker (forbidden — see spawn-glm.ts's
// REFUSE_BYPASS_PERMISSIONS) precisely because it strips every guardrail
// instead of narrowing to what the worker legitimately needs. A union (not
// bare string) makes a typo a compile error instead of a malformed
// `--permission-mode` flag that only fails inside the spawned, stdin-closed
// claude run.
export type PermissionMode = "bypassPermissions" | "dontAsk";
// Model pin (HIMMEL-671): without an explicit --model, every bounded run
// inherits the operator's default model — currently Fable, whose quota is
// time-limited and reserved for the main thread (see the subagent policy).
// Opus over sonnet: bridge runs do real work (Jira writes, arming, vault
// filing) that warrants the reasoning tier, and the operator's standing
// guidance is opus/haiku for dispatches. Override via TELEGRAM_CLAUDE_MODEL
// (poller env; restart to apply); blank/whitespace falls back to the default.
export const DEFAULT_MODEL = "opus";
function resolveModel(): string {
  return process.env.TELEGRAM_CLAUDE_MODEL?.trim() || DEFAULT_MODEL;
}
// permissionMode (HIMMEL-578): when set, injected as `--permission-mode <mode>`
// BEFORE the prompt.
// modelOverride (HIMMEL-654 GLM lane): GLM runs pin their alias explicitly and
// MUST NOT consult TELEGRAM_CLAUDE_MODEL — a poller-pinned raw Anthropic model
// id must never leak to the Z.ai endpoint (spec D3).
// settings (HIMMEL-1040 plugin profiles): when set, injected as
// `--settings <json>` before the prompt — the lever-b per-dispatch plugin-profile
// payload spawn-glm resolves. Highest non-managed precedence, so a lane runs the
// lean profile while ~/.claude (shared, no CLAUDE_CONFIG_DIR) stays full for the
// operator. Omitted (operator profile / unset) => no flag, inherits ~/.claude.
export function buildRunArgs(prompt: string, permissionMode?: PermissionMode, modelOverride?: string, settings?: string) {
  const model = modelOverride ?? resolveModel();
  const cmd = ["claude", "--model", model];
  if (permissionMode) cmd.push("--permission-mode", permissionMode);
  if (settings) cmd.push("--settings", settings);
  cmd.push(prompt);
  return { cmd, stdin: "ignore" as const };
}

// fileURLToPath is the cross-platform form — new URL(...).pathname yields a
// broken leading-slash path on Windows (/C:/Users/...). Exported for the test.
export const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));

// BASH_BIN (HIMMEL-1279): every `bash <abs-script>` the bridge spawns must name
// Git Bash by absolute path. A bare "bash" resolves through the spawning
// process's PATH, and the supervisor is launched by the HimmelTelegramBridge
// schtask under `pwsh -NoProfile`, whose PATH has System32 ahead of Git\bin —
// so "bash" lands on the WSL stub C:\Windows\System32\bash.exe. That stub sees
// no C: drive at all: it exits 127 on BOTH `C:\...` (backslashes eaten by the
// WSL argv translation, hence the "C:UsersyotamDocuments..." in supervisor.log)
// and `C:/...`. POSIX-ifying the path does NOT help — resolving the interpreter
// does. Same candidate order as scripts/setup-hooks.sh, preflight-sim.sh and
// scripts/ci-orchestrator/tests/*.ts; see docs/internals/environment-gotchas.md.
const WIN_BASH_CANDIDATES = ["C:/Program Files/Git/bin/bash.exe", "C:/Program Files (x86)/Git/bin/bash.exe"];
export function resolveBash(): string {
  if (process.platform !== "win32") return "bash";
  // Derive from git.exe too — <GitRoot>/cmd/git.exe => <GitRoot>/bin/bash.exe —
  // so a non-default Git install location still resolves.
  const candidates = [...WIN_BASH_CANDIDATES];
  const gitExe = Bun.which("git");
  if (gitExe) candidates.push(dirname(dirname(gitExe.replace(/\\/g, "/"))) + "/bin/bash.exe");
  for (const c of candidates) if (existsSync(c)) return c;
  // PATH fallback, minus the two known stub locations.
  const pathBash = Bun.which("bash");
  if (pathBash && !/system32|windowsapps/i.test(pathBash)) return pathBash;
  // Nothing safe found. Returning the bare "bash" here would re-introduce the
  // exact defect this function exists to prevent: spawn would resolve it
  // through PATH straight back to the WSL stub, which "runs" and exits 127 —
  // silent, and indistinguishable from a script bug. Return the canonical Git
  // Bash path instead, which on this machine does NOT exist: spawn then fails
  // ENOENT naming the interpreter we actually require. Loud beats invisible.
  // Not a throw — run.ts is imported for far more than bash spawning, and
  // taking the whole poller down at module load over a missing classifier
  // dependency trades a narrow failure for a total one.
  console.error(
    `[bridge] no usable Git Bash found (checked ${candidates.join(", ")} and PATH minus the WSL stub); ` +
      `every bash child will fail ENOENT until Git for Windows is installed`,
  );
  return WIN_BASH_CANDIDATES[0];
}
export const BASH_BIN = resolveBash();

// glmChildEnv (HIMMEL-654): the GLM lane's child env — the current process env
// with the GLM block (buildGlmEnv) merged over it, and TELEGRAM_OWN_POLLER
// stripped so the spawned session never owns the poller.
export function glmChildEnv(): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...process.env, ...buildGlmEnv(REPO_ROOT) };
  delete env.TELEGRAM_OWN_POLLER;
  return env;
}

// HIMMEL-1753: a spawned worker runs with stdin CLOSED (see runSession), so it
// can never answer an interactive editor or prompt. Any tool that falls back to
// $EDITOR (git commit without -m, gh pr create without --body, ...) would open a
// window on the operator's desktop and then block forever behind it — a focus
// steal that also contaminates the LUNA-131 focus soak. Pinning every editor
// hook to the no-op `true` turns that silent hang into a fast, loud failure.
// DEFENCE-IN-DEPTH, not a confirmed root cause: gh detects a non-interactive
// context and errors ("must provide --title and --body ... when not running
// interactively") rather than opening an editor, so this closes the paths where
// a TTY *is* present rather than a proven live leak.
// These merge OVER the inherited process env on purpose — the poller itself is
// launched by a scheduled task whose environment carries none of them — but
// UNDER extraEnv, so an explicit per-route value still wins.
export const NON_INTERACTIVE_EDITOR_ENV: Record<string, string> = {
  GIT_EDITOR: "true",
  EDITOR: "true",
  VISUAL: "true",
  GH_PROMPT_DISABLED: "1",
};

// env selection per lane — exported so the lane wiring itself is unit-tested
// (not only the glmChildEnv helper).
// extraEnv (LUNA-101): per-route child-env additions, merged LAST so the
// TELEGRAM_OWN_POLLER strip (which both branches do) can never remove a marker,
// and an ambient poller var can never survive a marker merge. This is the only
// channel by which a route reaches the child env — the env is built here, not
// in the poller.
export function sessionEnv(lane?: "glm", extraEnv?: Record<string, string>): Record<string, string | undefined> {
  const base: Record<string, string | undefined> = lane === "glm" ? glmChildEnv() : { ...process.env };
  // Reads asymmetric but is not: glmChildEnv() ALREADY deletes it (see above), so
  // the glm branch's base arrives stripped and re-deleting would be dead code.
  // Both branches end up without it — asserted by a test that seeds the var and
  // calls sessionEnv("glm"). (Two independent critics have now read this line as
  // a glm leak; the note is here so a third does not.)
  if (lane !== "glm") delete base.TELEGRAM_OWN_POLLER;
  // The GGS markers are SET BY THE ROUTE, never inherited (CR CodeRabbit): if the
  // poller's own environment happens to carry them, every unrouted session would
  // silently claim to be a bounded read-only GGS run. Same posture as the
  // TELEGRAM_OWN_POLLER strip above — clear first, then let extraEnv grant them.
  delete base.HERMES_BOUNDED_RUN;
  delete base.GGS_ROLE;
  // NON_INTERACTIVE_EDITOR_ENV before extraEnv: a route may override an editor
  // key deliberately, but nothing ambient can reinstate an interactive one.
  return { ...base, ...NON_INTERACTIVE_EDITOR_ENV, ...(extraEnv ?? {}) };
}

// The bounded-run PROMPT. Tells the spawned claude session what it is, where to
// read pending messages (inbox), where to reply (outbox — append JSON lines, no
// chat_id needed), where its cross-run memory lives (context.md), and to stop
// when done. Source of truth for run-prompt.md. A ticket-shaped session id does
// the ticket's work; anything else (e.g. "__chat__") just answers the operator.
// `vault` (HIMMEL-321): when set, an attached document OR image (a line with
// "document_path" / "image_path") is filed into that Obsidian vault; resolved
// per-chat by the poller via gate.vaultForChat.
// `cwd` vs `sessionCwd` (HIMMEL-578): the session SPAWNS in `sessionCwd` (the
// chat's vault when one is configured, so the vault's `.claude/hooks` — e.g. a
// medical PHI-egress floor — load), but the Jira-CLI path stays anchored on
// `cwd` (the himmel repo root) because `dist/` only exists there. The "running
// in" line reports the actual spawn cwd.
// `cwdRouted` (LUNA-101): this session spawns in a CODE REPO (access.json `cwd`),
// not a vault. Attachments are read and summarized in-reply, never filed —
// a code repo has no _CLAUDE.md filing conventions. The flag wins over `vault`
// so an inherited defaultVault cannot re-attach the filing clause.
export type BusPaths = { inbox: string; outbox: string; context: string; cwd: string; sessionCwd?: string };
export function buildPrompt(session: string, p: BusPaths, vault?: string | null, cwdRouted = false): string {
  const isTicket = /^[A-Z][A-Z0-9]+-[0-9]+$/.test(session);
  const job = isTicket
    ? `You are working on ticket ${session}. Do the ticket's work.`
    : `Answer the operator's message(s) conversationally.`;
  return [
    `You are Telegram bridge session "${session}", running in ${p.sessionCwd ?? p.cwd}.`,
    `First, read your cross-run memory at ${p.context} to resume where the last run left off (it may be empty on a first run).`,
    `Then read your pending messages from ${p.inbox} — each line is a JSON object {"text": "..."}; treat them as the operator's requests, in order.`,
    `If a line has an "image_path" field, use the Read tool on that path — it is a photo the operator attached; the line's "text" is its caption.`,
    `If a line has a "document_path" field, use the Read tool on that path — it is a file the operator attached (e.g. a PDF); the line's "text" is its caption and "document_name" is the original filename.`,
    job,
    ...(cwdRouted ? [
      `When a message carries a "document_path" or an "image_path", READ it and summarize its content in your reply. Do NOT file it anywhere — this is a code-repo session, not a vault.`,
    ] : vault ? [
      `When a message carries a "document_path" OR an "image_path", FILE that attachment's content into the Obsidian vault at ${vault} (not just read it): read that vault's _CLAUDE.md first and follow its filing conventions — if the vault has a "medic" skill (or another vault-local filing skill) use it, otherwise use the obsidian-second-brain skill. In your reply, confirm what you filed and where.`,
    ] : []),
    // Jira sanction (HIMMEL-424 followup): without this, the auto-mode classifier
    // VETOES ticket writes because the bridge session's stated workflow omits Jira —
    // the bridge would reply "I can't create the ticket (classifier veto)". Stating
    // it as in-scope lifts the veto. Non-destructive only: there is no delete op, and
    // move (closes the source ticket) / project-create (admin) are excluded.
    `Acting on Jira tickets for the operator is part of your job: when asked, run the change yourself rather than offering a command to paste. Use the Jira CLI by its absolute path: \`node ${p.cwd}/scripts/jira/dist/index.js <op>\` (JIRA_PROJECT_KEY comes from the repo .env; --help lists the ops). Creating, editing, commenting, transitioning, assigning, changing priority/labels, attaching, linking and reading tickets is sanctioned, non-destructive work. You may NOT delete tickets (there is no delete op), and do not use \`move\` (it closes the source ticket) or \`project-create\` (admin) unless the operator explicitly asks.`,
    `Reply to the operator by APPENDING one JSON line {"text":"<your reply>"} per message to ${p.outbox}. That is the only way to reach the operator.`,
    `Do NOT poll Telegram yourself and do NOT open a --channels session.`,
    `As your FINAL action, append a one-line progress note to ${p.context} (so the next run has context). Then stop — you are done.`,
  ].join("\n");
}

// Cap / rate-limit detection default = output sentinel (per spec).
const CAP_SENTINELS = [/usage limit reached/i, /Claude usage limit/i, /try again later/i];
// GLM lane (HIMMEL-654 cap guard): z.ai official 429 message substrings
// (docs.z.ai/api-reference/api-code; fixtures promoted from the Task-0 live
// capture). Exact substrings only — the tail carries task text/diffs/issue
// numbers like #1316, so no bare code-number matching. `try again later` is
// DROPPED on-lane: z.ai 1305 is documented-transient and would otherwise arm
// a resume up to 5h out for a seconds-transient condition.
export type GlmCapWindow = "5h" | "long";
const GLM_LONG = [/usage limit reached for the past 7 days/i, /weekly\/monthly limit exhausted/i, /insufficient balance or no resource package/i, /glm coding plan package has expired/i];
export function detectGlmCap(output: string): { window: GlmCapWindow } | null {
  if (GLM_LONG.some(r => r.test(output))) return { window: "long" };
  if (/usage limit reached for the past 5 hours/i.test(output)) return { window: "5h" };
  // 1308 shape: the reset phrase alone is NOT enough (spec defines the PAIR) —
  // co-require the usage-limit prefix so an unrelated "reset at" line can't
  // classify as a cap. 1318-1321 verbatim strings are undocumented; per the
  // research they are "past 5 hours / past 7 days" variants, so the two
  // substring rules above are expected to catch them — Task 0/criterion 7
  // live captures are the guard if they don't.
  if (/usage limit reached for/i.test(output) && /your limit will reset at/i.test(output)) return { window: "5h" };
  return null;
}
export function detectCap(output: string, lane?: "glm"): boolean {
  if (lane === "glm") return detectGlmCap(output) !== null || /usage limit reached/i.test(output) || /Claude usage limit/i.test(output);
  return CAP_SENTINELS.some(r => r.test(output));
}

// Content-filter detection (HIMMEL-313). A run that exits non-zero
// because Anthropic's API blocked the model's OUTPUT under the content-filtering
// policy (observed tail: "API Error: Output blocked by content filtering policy")
// is NOT a usage cap (run.log correctly logs capped=false) and is DETERMINISTIC —
// the same generated output is blocked on every retry. The poller special-cases
// this so it parks immediately instead of burning MAX_RETRIES on a block that
// can never succeed, and reports it accurately instead of mislabelling it a cap.
const FILTER_SENTINELS = [/content filtering policy/i, /blocked by .*content filter/i];
export function detectContentFilter(output: string): boolean { return FILTER_SENTINELS.some(r => r.test(output)); }

// Hard process-TREE kill (HIMMEL-246). A bare p.kill() on Windows kills only the
// direct child; claude's own subprocess tree survives as an orphan that keeps
// holding stdout/stderr — p.exited never resolves, the session sticks "running"
// (the live 1.5h DM wedge), and a later retry would spawn a SECOND child against
// the same session's context.md/outbox (single-writer violation).
//
// HIMMEL-1956: the implementation moved to scripts/lib/kill-tree.mjs, shared
// with the codex-bank-probe copy that carried the same defect (HIMMEL-1835).
// It is re-exported here because "./run" is the import path four modules and
// the bun suite already use. The POSIX half only works for a child spawned
// with SPAWN_OWN_GROUP — see that file for the measured matrix.
export { killTree };

// Lane → model pin: the GLM lane pins its alias (→ glm-5.2[1m] via
// ANTHROPIC_DEFAULT_OPUS_MODEL) and MUST NOT inherit TELEGRAM_CLAUDE_MODEL; any
// other lane leaves the model to resolveModel. Extracted so the seam is unit-tested.
export function laneModel(lane?: "glm"): string | undefined {
  return lane === "glm" ? GLM_MODEL_ALIAS : undefined;
}

// Observability hooks (HIMMEL-1378): a silently-hung worker (native permission
// matcher bails to an unanswerable prompt on stdin="ignore" — HIMMEL-203) used
// to be INVISIBLE for the entire RUN_TIMEOUT_MS window — run.log was appended
// only from the FINAL tail (spawn-glm.ts executeRun), post-exit, so a session
// that never exits leaves zero trace until its caller's timeout fires. onSpawn
// fires once, synchronously after spawn, with the real child pid (meta.json
// previously stayed pid:0 for the whole "running" window — no way for an
// external watcher to check process liveness). onChunk fires once per stdout/
// stderr chunk AS IT ARRIVES, so a caller can append it to run.log live and/or
// stamp a last-output timestamp a watchdog can compare against "now" to detect
// a stall well before the full timeout. Both are best-effort observability —
// a throwing callback must never abort the run, so each call is wrapped.
export type RunObserver = { onSpawn?: (pid: number) => void; onChunk?: (chunk: string) => void };

// Drain a stdout/stderr stream chunk-by-chunk (replaces the old buffer-until-
// EOF `new Response(stream).text()`, which made onChunk impossible — that
// helper does not expose intermediate chunks, only the final joined text).
// Bun's ReadableStream supports async iteration; each chunk is decoded with
// `stream: true` so a multi-byte UTF-8 character split across two chunks
// decodes correctly, and a trailing decode() flush after the loop empties the
// decoder's internal buffer.
async function drain(stream: ReadableStream<Uint8Array>, onChunk?: (s: string) => void): Promise<string> {
  const decoder = new TextDecoder();
  let acc = "";
  for await (const c of stream) {
    const s = decoder.decode(c, { stream: true });
    acc += s;
    if (s && onChunk) { try { onChunk(s); } catch { /* best-effort observability, never abort the run */ } }
  }
  acc += decoder.decode();
  return acc;
}

export async function runSession(prompt: string, cwd: string, permissionMode?: PermissionMode, lane?: "glm", modelOverride?: string, settings?: string, observe?: RunObserver, extraEnv?: Record<string, string>): Promise<{ code: number; capped: boolean; blocked: boolean; timedOut: boolean; pid: number; tail?: string }> {
  const env = sessionEnv(lane, extraEnv);
  // PERMISSION POSTURE (HIMMEL-314; see also HIMMEL-203, HIMMEL-578):
  // the bounded run inherits the operator's default permission mode (accept-edits)
  // and runs with stdin closed (EOF) so it CANNOT answer a permission prompt. Any
  // tool the `auto-approve-safe-bash` hook doesn't grant falls through to a prompt
  // that the harness auto-mode then denies (e.g. the intermittent Jira ticket-create
  // denials). The first-line fix is broadening the auto-approve matcher.
  // HIMMEL-578: when the session spawns in a VAULT cwd (sessionCwd != repoCwd),
  // himmel's OWN project hooks (incl. auto-approve-safe-bash) no longer load — so
  // the poller passes permissionMode="bypassPermissions" for vault sessions ONLY,
  // else the FILE-and-commit flow deadlocks on un-answerable prompts. bypass does
  // NOT loosen containment: the VAULT's PreToolUse hooks (e.g. block-cloud-egress)
  // still fire and HARD-block web/cloud/push. Non-vault sessions keep the default.
  const { cmd } = buildRunArgs(prompt, permissionMode, modelOverride ?? laneModel(lane), settings);
  // SPAWN_OWN_GROUP (HIMMEL-1956): the timeout below calls killTree, and its
  // POSIX half signals the process GROUP -- which has to exist before it can
  // be signalled. Without this the claude worker's own children survive the
  // deadline and keep holding these pipes.
  const p = spawn(cmd, { ...SPAWN_OWN_GROUP, cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe", env });
  const pid = p.pid;
  if (observe?.onSpawn) { try { observe.onSpawn(pid); } catch { /* best-effort, never abort the run */ } }
  const timeoutMs = Number(process.env.RUN_TIMEOUT_MS ?? 30 * 60 * 1000);
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; killTree(pid, (s) => p.kill(s as any)); }, timeoutMs);
  // clearTimeout in finally: if any of the awaited promises reject, the 30-min
  // timer must still be cleared, else it later fires killTree on a pid that may
  // have been recycled by the OS.
  let out: string, err: string, code: number;
  try {
    [out, err, code] = await Promise.all([drain(p.stdout, observe?.onChunk), drain(p.stderr, observe?.onChunk), p.exited]);
  } finally {
    clearTimeout(timer);
  }
  const tail = (out + err).slice(-65536);
  // tail returned for run.log persistence (HIMMEL-262)
  return { code: timedOut ? -1 : code, capped: detectCap(tail, lane), blocked: detectContentFilter(tail), timedOut, pid, tail };
}
