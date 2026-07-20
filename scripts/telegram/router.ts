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

export function classify(raw: string): Route {
  const t = raw.trim();
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
  const fu = t.match(/^([A-Z][A-Z0-9]+-[0-9]+):\s*([\s\S]+)$/);
  if (fu) return { kind: "followup", ticket: fu[1], text: fu[2] };
  return { kind: "chat", text: t };
}
