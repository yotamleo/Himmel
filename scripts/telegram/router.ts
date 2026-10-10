// Pure-code inbound router for the telegram bridge v2 (HIMMEL-207).
// Classifies a raw message string into control | dispatch | followup | chat.
// No side effects, no I/O — table-driven matching only.
//
// SECURITY: ticket keys must validate ^[A-Z][A-Z0-9]+-[0-9]+$. A bad key in
// "work on <X>" / "stop <X>" falls through to chat (never dispatch/control),
// so attacker-controlled text can never reach a ticket path.
const KEY = /^[A-Z][A-Z0-9]+-[0-9]+$/;

export type Route =
  | { kind: "control"; verb: "status" | "sessions" }
  | { kind: "control"; verb: "stop"; ticket: string }
  | { kind: "dispatch"; ticket: string }
  | { kind: "followup"; ticket: string; text: string }
  | { kind: "auto"; op: "arm-resume"; arg: string; time: string }
  | { kind: "auto"; op: "merge-public"; arg: string; time: string }
  | { kind: "auto"; op: "restart"; arg: string; time: string }
  | { kind: "auto"; op: "launch-bypass-leg" | "cr-grant-delta"; arg: string; time: string }
  | { kind: "auto"; op: "station-status" | "revert-main" | "repin-hooks" | "launch-leg" | "cr-reset" | "close-wrapped" | "relaunch-console" | "restart-bridge" | "allow-rule" | "confirm"; arg: string; time: string }
  | { kind: "console"; name: string; text: string }
  | { kind: "consoles" }
  | { kind: "fleet"; verb: "status" | "legs" | "go?" | "push" | "halt"; leg?: string }
  | { kind: "fleet-malformed" }
  | { kind: "lockdown" }
  | { kind: "chat"; text: string };

// Structured auto-command (HIMMEL-424 B2): `/arm <ticket|path> [at HH:MM|auto|smart]`.
// Anchored on the WHOLE trimmed message so a mid-text `/arm` never matches. SECURITY:
// the bridge invokes this op directly (agent OUT of the trust path), so the command
// must be a deliberate, message-fact-authenticated instruction — never text embedded
// in chat. `arg` is freeform (ticket OR path); it is validated/resolved downstream by
// auto-action.sh, NOT here. `time` defaults to "smart"; an unrecognized trailing
// modifier (e.g. "now", "at 99:99") fails the match → falls through to chat. `/arm`
// is the v1 alias for op `arm-resume` (the closed op allow-list at the parse layer).
const ARM = /^\/arm\s+(\S+)(?:\s+(?:at\s+((?:[01][0-9]|2[0-3]):[0-5][0-9])|(auto|smart)))?$/;

// Structured merge-authorization auto-command (HIMMEL-1213 design §3):
// `/mergepub <pr> <sha12>`. Anchored on the WHOLE trimmed message, same as /arm,
// so a mid-text or malformed `/mergepub` never matches — falls through to chat.
// SECURITY: the bridge invokes auto-action.sh directly on a match (agent OUT of
// the trust path) — this is the ONLY way a public squash-merge gets authorized.
// `<pr>` is 1-6 digits (optional leading `#`); `<sha>` is >=12 hex chars (up to a
// full 40-char SHA), matched case-insensitively but the operator's ready report
// always prints lowercase. The 12-hex floor (48 bits, was 7=28 bits) blunts a
// prefix-grinding attack: the agent may push fix-commits to the public branch, so
// a 7-hex prefix could be ground (~2^28) to a malicious commit sharing the
// operator-approved prefix and pass both the SHA gates and --match-head-commit —
// defeating even a diligent operator (HIMMEL-1213 Fable gate-review). This Route
// variant reuses arm-resume's EXACT shape (`arg`/`time`, not `pr`/`sha`) so
// poller.ts's generic auto-command plumbing (handleAutoCommand's audit-line
// construction reads route.arg/route.time for either op) needs no change: here
// `arg` carries the PR number, `time` carries the operator-approved head SHA.
// Per-shape validation of PR/SHA beyond this regex lives in auto-action.sh +
// merge-public-on-green.sh, not here.
const MERGEPUB = /^\/mergepub\s+#?(\d{1,6})\s+([0-9a-f]{12,40})$/i;

// Structured self-restart auto-command (HIMMEL-1272): `/restart` (rung 1, poller
// bounce) or `/restart full` (rung 2, whole-supervisor relaunch via the registered
// scheduled task). Anchored on the WHOLE trimmed message like /arm and /mergepub,
// so `/restart now` or a mid-text `/restart` falls through to chat rather than
// bouncing the bridge on a stray word. The RUNG rides in `arg` (the Route variant
// reuses the same {arg,time} shape as the other two ops so poller.ts's generic
// auto-command plumbing — the audit-line builder in particular — needs no change);
// `time` is the fixed placeholder "-" since a restart has no schedule.
// Why two rungs: the supervisor already respawns an exited poller, but that respawn
// INHERITS the supervisor's environment, frozen at its launching shell. So rung 1
// picks up anything re-read from a file (post-HIMMEL-1270 that includes
// TELEGRAM_AUTO_ACTIONS) but NOT a changed User-scope env var. Only a
// scheduler-service-launched process reads the current User environment at fire
// time — that is rung 2.
const RESTART = /^\/restart(?:\s+(full))?$/i;

// Operator -> running console (HIMMEL-3355): `/console <session-name> <text>`.
// Slash-prefixed and anchored on the whole message like /arm, so prose such as
// "console output: foo" never matches. The router only checks SHAPE (name charset,
// non-empty text); the path-safety refusal and the sender gate live downstream
// (console-route.ts, poller.ts handleInbound), where a non-operator's match falls
// back to ordinary chat.
// HIMMEL-5148: the verb is case-insensitive and may carry Telegram's `/cmd@<bot>`
// addressing; a suffix naming another bot (when `botUsername` is known) is chat.
// Only the leading verb is matched, so a mid-text or trailing /console stays chat.
const CONSOLE_VERB = /^\/(consoles?)(?:@([A-Za-z0-9_]+))?(?=\s|$)/i;

const FLEET_VERB = /^\/(lockdown|fleet|legs|halt|go|push)(?:@([A-Za-z0-9_]+))?(?![A-Za-z0-9_@])/i;

export function classify(raw: string, botUsername?: string | null): Route {
  const t = raw.trim();
  // HIMMEL-5150: fleet verbs and /lockdown take the same case-insensitive verb and
  // `/cmd@<bot>` addressing as /console; a suffix naming another bot (when
  // `botUsername` is known) is chat. With no known bot name an `@` suffix cannot
  // be checked, so only the fail-safe verbs (/halt, /lockdown) accept it. The leg
  // label stays case-exact. The auto ops below are deliberately NOT loosened.
  const fv = t.match(FLEET_VERB);
  const fvVerb = fv ? fv[1].toLowerCase() : "";
  const fvAddressed = !fv || !fv[2] || (botUsername ? fv[2].toLowerCase() === botUsername.toLowerCase() : fvVerb === "halt" || fvVerb === "lockdown");
  if (fv && fvAddressed) {
    const verb = fvVerb;
    const rest = t.slice(fv[0].length);
    if (rest === "") {
      if (verb === "lockdown") return { kind: "lockdown" };
      if (verb === "fleet") return { kind: "fleet", verb: "status" };
      if (verb === "legs") return { kind: "fleet", verb: "legs" };
      if (verb === "halt") return { kind: "fleet", verb: "halt" };
    }
    const label = rest.match(/^ ([A-Za-z0-9_.-]{1,64})$/);
    if (label && !label[1].includes("..") && (verb === "go" || verb === "push" || verb === "halt")) return { kind: "fleet", verb: verb === "go" ? "go?" : verb, leg: label[1] };
    // HIMMEL-4947: a reserved fleet verb with any other shape (bad/oversized/
    // traversal label, control char, extra args, missing label) is a terminal
    // refusal, never agent chat. FLEET_VERB's lookahead keeps `/gopher` and
    // `/legsx` ordinary chat; /lockdown with trailing text is chat.
    if (verb !== "lockdown") return { kind: "fleet-malformed" };
  }
  if (t === "status" || t === "sessions") return { kind: "control", verb: t as "status" | "sessions" };
  const stop = t.match(/^stop\s+(\S+)$/i);
  if (stop && KEY.test(stop[1])) return { kind: "control", verb: "stop", ticket: stop[1] };
  const disp = t.match(/^work on\s+(\S+)$/i);
  if (disp && KEY.test(disp[1])) return { kind: "dispatch", ticket: disp[1] };
  const arm = t.match(ARM);
  if (arm) return { kind: "auto", op: "arm-resume", arg: arm[1], time: arm[2] ?? arm[3] ?? "smart" };
  const mergepub = t.match(MERGEPUB);
  // Lowercase the captured SHA: the verb+hex match case-insensitively (/i) for a
  // forgiving paste, but git oids are lowercase and auto-action.sh + the
  // chokepoint validate/compare lowercase-only — so an uppercase paste must be
  // normalized HERE, else it classifies as executable then fails downstream
  // validation (HIMMEL-1213 codex CR-2). arg (PR digits) has no case.
  if (mergepub) return { kind: "auto", op: "merge-public", arg: mergepub[1], time: mergepub[2].toLowerCase() };
  // Closed typed ops; the shell half validates containment and the live PR head.
  const launch = t.match(/^\/launch-bypass-leg\s+(\S+)\s+([A-Z][A-Z0-9_]+)$/);
  if (launch) return { kind: "auto", op: "launch-bypass-leg", arg: launch[1], time: launch[2] };
  const grant = t.match(/^\/cr-grant-delta\s+#?(\d{1,6})\s+([0-9a-f]{40})$/i);
  if (grant) return { kind: "auto", op: "cr-grant-delta", arg: grant[1], time: grant[2].toLowerCase() };
  // HIMMEL-5047 break-glass ops: whole-message, closed shapes; "-" fills an
  // absent arg/time because auto-action.sh requires all three argv slots.
  if (/^\/(?:station-status|repin-hooks|restart-bridge)$/.test(t)) return { kind: "auto", op: t.slice(1) as "station-status", arg: "-", time: "-" };
  const pr = t.match(/^\/(revert-main|cr-reset)\s+#?(\d{1,6})$/);
  if (pr) return { kind: "auto", op: pr[1] as "revert-main" | "cr-reset", arg: pr[2], time: "-" };
  const leg = t.match(/^\/launch-leg\s+(N\d+[a-z]*)(\s+--hook-bypass)?$/);
  if (leg) return { kind: "auto", op: "launch-leg", arg: leg[1], time: leg[2] ? "bypass" : "-" };
  const closeW = t.match(/^\/close-wrapped(?:\s+(N\d+[a-z]*))?$/);
  if (closeW) return { kind: "auto", op: "close-wrapped", arg: closeW[1] ?? "-", time: "-" };
  const relaunch = t.match(/^\/relaunch-console(?:\s+([a-z0-9][a-z0-9-]{0,63}))?$/);
  if (relaunch) return { kind: "auto", op: "relaunch-console", arg: relaunch[1] ?? "-", time: "-" };
  const allowRule = t.match(/^\/allow-rule\s+([a-z0-9][a-z0-9-]{0,63})$/);
  if (allowRule) return { kind: "auto", op: "allow-rule", arg: allowRule[1], time: "-" };
  const confirmCode = t.match(/^\/confirm\s+([0-9a-f]{8})$/);
  if (confirmCode) return { kind: "auto", op: "confirm", arg: confirmCode[1], time: "-" };
  const restart = t.match(RESTART);
  // Bare `/restart` => rung 1 ("poller"); `/restart full` => rung 2 ("full").
  if (restart) return { kind: "auto", op: "restart", arg: restart[1] ? "full" : "poller", time: "-" };
  const verb = t.match(CONSOLE_VERB);
  if (verb && (!verb[2] || !botUsername || verb[2].toLowerCase() === botUsername.toLowerCase())) {
    const rest = t.slice(verb[0].length);
    if (verb[1].toLowerCase() === "consoles") { if (rest === "") return { kind: "consoles" }; }
    else {
      const con = rest.match(/^\s+([A-Za-z0-9_.-]+)\s+([\s\S]+)$/);
      if (con) return { kind: "console", name: con[1], text: con[2] };
      const bare = rest.match(/^\s+([\s\S]+)$/);
      if (bare) return { kind: "console", name: "", text: bare[1] };
    }
  }
  const fu = t.match(/^([A-Z][A-Z0-9]+-[0-9]+):\s*([\s\S]+)$/);
  if (fu) return { kind: "followup", ticket: fu[1], text: fu[2] };
  return { kind: "chat", text: t };
}
