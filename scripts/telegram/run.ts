import { spawn } from "bun";

// Bounded-run spawn helper. Runs an INTERACTIVE `claude "<prompt>"` with stdin
// closed (EOF) so the session does one turn then exits cleanly — empirically
// `claude "<p>" </dev/null` exits 0 (~6s, Max quota, no -p). Strips
// TELEGRAM_OWN_POLLER from the child env so the spawned session never owns the
// poller. NO -p/--print/--channels — interactive billing + behaviour only.
export function buildRunArgs(prompt: string) {
  return { cmd: ["claude", prompt], stdin: "ignore" as const };
}

// The bounded-run PROMPT. Tells the spawned claude session what it is, where to
// read pending messages (inbox), where to reply (outbox — append JSON lines, no
// chat_id needed), where its cross-run memory lives (context.md), and to stop
// when done. Source of truth for run-prompt.md. A ticket-shaped session id does
// the ticket's work; anything else (e.g. "__chat__") just answers the operator.
// `vault` (HIMMEL-321): when set, an attached document (a line with
// "document_path") is filed into that Obsidian vault; resolved per-chat by the
// poller via gate.vaultForChat.
export type BusPaths = { inbox: string; outbox: string; context: string; cwd: string };
export function buildPrompt(session: string, p: BusPaths, vault?: string | null): string {
  const isTicket = /^[A-Z][A-Z0-9]+-[0-9]+$/.test(session);
  const job = isTicket
    ? `You are working on ticket ${session}. Do the ticket's work.`
    : `Answer the operator's message(s) conversationally.`;
  return [
    `You are Telegram bridge session "${session}", running in ${p.cwd}.`,
    `First, read your cross-run memory at ${p.context} to resume where the last run left off (it may be empty on a first run).`,
    `Then read your pending messages from ${p.inbox} — each line is a JSON object {"text": "..."}; treat them as the operator's requests, in order.`,
    `If a line has an "image_path" field, use the Read tool on that path — it is a photo the operator attached; the line's "text" is its caption.`,
    `If a line has a "document_path" field, use the Read tool on that path — it is a file the operator attached (e.g. a PDF); the line's "text" is its caption and "document_name" is the original filename.`,
    job,
    ...(vault ? [
      `When a message carries a "document_path", file the document's content into the Obsidian vault at ${vault}: read that vault's _CLAUDE.md first and follow its filing conventions (use the obsidian-second-brain skill). In your reply, confirm what you filed and where.`,
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
export function detectCap(output: string): boolean { return CAP_SENTINELS.some(r => r.test(output)); }

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

export async function runSession(prompt: string, cwd: string): Promise<{ code: number; capped: boolean; blocked: boolean; pid: number; tail?: string }> {
  const env = { ...process.env }; delete (env as any).TELEGRAM_OWN_POLLER;
  // PERMISSION POSTURE (HIMMEL-314; see also HIMMEL-203):
  // the bounded run inherits the operator's default permission mode (accept-edits)
  // and runs with stdin closed (EOF) so it CANNOT answer a permission prompt. Any
  // tool the `auto-approve-safe-bash` hook doesn't grant falls through to a prompt
  // that the harness auto-mode then denies (e.g. the intermittent Jira ticket-create
  // denials). The first-line fix is broadening the auto-approve matcher; if denials
  // recur, the escalation is `--permission-mode bypassPermissions` here — the himmel
  // PreToolUse hooks (block-edit-on-main, block-read-secrets, …) still fire and
  // enforce, only the un-answerable prompt goes away. Tracked so we don't relitigate.
  const p = spawn(["claude", prompt], { cwd, stdin: "ignore", stdout: "pipe", stderr: "pipe", env });
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
  return { code: timedOut ? -1 : code, capped: detectCap(tail), blocked: detectContentFilter(tail), pid, tail };
}
