import { spawn } from "bun";
import { buildGlmEnv, GLM_MODEL_ALIAS } from "./glm-env";
import { fileURLToPath } from "node:url";

// Bounded-run spawn helper. Runs an INTERACTIVE `claude "<prompt>"` with stdin
// closed (EOF) so the session does one turn then exits cleanly — empirically
// `claude "<p>" </dev/null` exits 0 (~6s, Max quota, no -p). Strips
// TELEGRAM_OWN_POLLER from the child env so the spawned session never owns the
// poller. NO -p/--print/--channels — interactive billing + behaviour only.
// PermissionMode (HIMMEL-578): the only mode the bridge ever injects is
// "bypassPermissions" (for vault sessions — see runSession). A union (not bare
// string) makes a typo a compile error instead of a malformed `--permission-mode`
// flag that only fails inside the spawned, stdin-closed claude run.
export type PermissionMode = "bypassPermissions";
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
export function buildRunArgs(prompt: string, permissionMode?: PermissionMode, modelOverride?: string) {
  const model = modelOverride ?? resolveModel();
  const cmd = permissionMode
    ? ["claude", "--model", model, "--permission-mode", permissionMode, prompt]
    : ["claude", "--model", model, prompt];
  return { cmd, stdin: "ignore" as const };
}

// fileURLToPath is the cross-platform form — new URL(...).pathname yields a
// broken leading-slash path on Windows (/C:/Users/...). Exported for the test.
export const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));

// glmChildEnv (HIMMEL-654): the GLM lane's child env — the current process env
// with the GLM block (buildGlmEnv) merged over it, and TELEGRAM_OWN_POLLER
// stripped so the spawned session never owns the poller.
export function glmChildEnv(): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = { ...process.env, ...buildGlmEnv(REPO_ROOT) };
  delete env.TELEGRAM_OWN_POLLER;
  return env;
}

// env selection per lane — exported so the lane wiring itself is unit-tested
// (not only the glmChildEnv helper).
export function sessionEnv(lane?: "glm"): Record<string, string | undefined> {
  if (lane === "glm") return glmChildEnv();
  const e: Record<string, string | undefined> = { ...process.env };
  delete e.TELEGRAM_OWN_POLLER;
  return e;
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
export type BusPaths = { inbox: string; outbox: string; context: string; cwd: string; sessionCwd?: string };
export function buildPrompt(session: string, p: BusPaths, vault?: string | null): string {
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
    ...(vault ? [
      `When a message carries a "document_path" OR an "image_path", FILE that attachment's content into the Obsidian vault at ${vault} (not just read it): read that vault's _CLAUDE.md first and follow its filing conventions — if the vault has a "medic" skill (or another vault-local filing skill) use it, otherwise use the obsidian-second-brain skill. In your reply, confirm what you filed and where.`,
    ] : []),
    // Jira sanction (HIMMEL-424 followup): without this, the auto-mode classifier
    // VETOES ticket writes because the bridge session's stated workflow omits Jira —
    // the bridge would reply "I can't create the ticket (classifier veto)". Stating
    // it as in-scope lifts the veto. Non-destructive only: there is no delete op, and
    // move (closes the source ticket) / project-create (admin) are excluded.
    `Acting on Jira tickets for the operator is part of your job — when asked, DO IT DIRECTLY (don't just offer a paste-ready command). Use the Jira CLI by its ABSOLUTE path: \`node ${p.cwd}/scripts/jira/dist/index.js <op>\` (JIRA_PROJECT_KEY comes from the repo .env; run it with --help for the ops). You MAY create, edit/update, comment, transition, assign, change priority/labels, attach files, link, and read tickets — this is sanctioned, non-destructive work. You may NOT delete tickets (there is no delete op), and do NOT use \`move\` (it closes the source ticket) or \`project-create\` (admin) unless the operator explicitly asks.`,
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
// the same session's context.md/outbox (single-writer violation). taskkill /T /F
// takes the whole tree; SIGKILL is the POSIX equivalent + fallback.
export function killTree(pid: number, kill: (sig?: number | NodeJS.Signals) => void): void {
  if (process.platform === "win32") {
    try { Bun.spawnSync(["taskkill", "/PID", String(pid), "/T", "/F"], { stdout: "ignore", stderr: "ignore" }); } catch {}
  }
  try { kill("SIGKILL"); } catch {}
}

// Lane → model pin: the GLM lane pins its alias (→ glm-5.2[1m] via
// ANTHROPIC_DEFAULT_OPUS_MODEL) and MUST NOT inherit TELEGRAM_CLAUDE_MODEL; any
// other lane leaves the model to resolveModel. Extracted so the seam is unit-tested.
export function laneModel(lane?: "glm"): string | undefined {
  return lane === "glm" ? GLM_MODEL_ALIAS : undefined;
}

export async function runSession(prompt: string, cwd: string, permissionMode?: PermissionMode, lane?: "glm"): Promise<{ code: number; capped: boolean; blocked: boolean; timedOut: boolean; pid: number; tail?: string }> {
  const env = sessionEnv(lane);
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
  const { cmd } = buildRunArgs(prompt, permissionMode, laneModel(lane));
  const p = spawn(cmd, { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe", env });
  const pid = p.pid;
  const timeoutMs = Number(process.env.RUN_TIMEOUT_MS ?? 30 * 60 * 1000);
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; killTree(pid, (s) => p.kill(s as any)); }, timeoutMs);
  // clearTimeout in finally: if any of the awaited promises reject, the 30-min
  // timer must still be cleared, else it later fires killTree on a pid that may
  // have been recycled by the OS.
  let out: string, err: string, code: number;
  try {
    [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  } finally {
    clearTimeout(timer);
  }
  const tail = (out + err).slice(-65536);
  // tail returned for run.log persistence (HIMMEL-262)
  return { code: timedOut ? -1 : code, capped: detectCap(tail, lane), blocked: detectContentFilter(tail), timedOut, pid, tail };
}
