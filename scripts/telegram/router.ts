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
  | { kind: "chat"; text: string };

export function classify(raw: string): Route {
  const t = raw.trim();
  if (t === "status" || t === "sessions") return { kind: "control", verb: t as "status" | "sessions" };
  const stop = t.match(/^stop\s+(\S+)$/i);
  if (stop && KEY.test(stop[1])) return { kind: "control", verb: "stop", ticket: stop[1] };
  const disp = t.match(/^work on\s+(\S+)$/i);
  if (disp && KEY.test(disp[1])) return { kind: "dispatch", ticket: disp[1] };
  const fu = t.match(/^([A-Z][A-Z0-9]+-[0-9]+):\s*([\s\S]+)$/);
  if (fu) return { kind: "followup", ticket: fu[1], text: fu[2] };
  return { kind: "chat", text: t };
}
