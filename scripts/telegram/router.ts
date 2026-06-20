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

export function classify(raw: string): Route {
  const t = raw.trim();
  if (t === "status" || t === "sessions") return { kind: "control", verb: t as "status" | "sessions" };
  const stop = t.match(/^stop\s+(\S+)$/i);
  if (stop && KEY.test(stop[1])) return { kind: "control", verb: "stop", ticket: stop[1] };
  const disp = t.match(/^work on\s+(\S+)$/i);
  if (disp && KEY.test(disp[1])) return { kind: "dispatch", ticket: disp[1] };
  const arm = t.match(ARM);
  if (arm) return { kind: "auto", op: "arm-resume", arg: arm[1], time: arm[2] ?? arm[3] ?? "smart" };
  const fu = t.match(/^([A-Z][A-Z0-9]+-[0-9]+):\s*([\s\S]+)$/);
  if (fu) return { kind: "followup", ticket: fu[1], text: fu[2] };
  return { kind: "chat", text: t };
}
