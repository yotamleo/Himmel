// scripts/observability/session-run-ledger.ts
// HIMMEL-1052 session/subagent lifecycle ledger — the substrate the war-room
// folds for "what is running right now, as a session".
//
// SIBLING, NOT REPLACEMENT. `flow-runs.jsonl` (HIMMEL-919/921) tracks the five
// pipeline-cadence legs; `spawn-glm.ts`/`spawn-claudex.ts` already keep a
// per-session `meta.json` for DISPATCHED lane workers. Neither covers the
// operator's own interactive/foreground Claude Code sessions and the Task-tool
// subagents fanned out inside them — that population is what this ledger is
// for, and the two others are deliberately left alone.
//
// Shape discipline is copied from `scripts/telegram/flow-run-ledger.ts`: a
// small FIXED field list in a FIXED order, hand-serialized, so two writers
// (and a future bash twin) produce byte-identical rows and a consumer can
// diff/dedupe them textually. Rotation at 10MB, `mkdir -p` on demand, single
// O_APPEND write, never blocking the hook it rides on.
//
// THE RECORD THAT NEVER GETS WRITTEN IS THE IMPORTANT ONE. SessionEnd is a
// graceful-exit hook: a crash, an OOM, a SIGKILL, or a wedged session the
// operator eventually closes the window on emits `session_start` and NO
// `session_end`, ever. Liveness is therefore NOT decided here — it is decided
// by the reader (flow-exporter.ts), from transcript mtime. See that file's
// `foldSessionLedger`.
import { appendFileSync, existsSync, mkdirSync, renameSync, rmSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

export const SESSION_RUN_ROTATE_BYTES = 10 * 1024 * 1024;

// Schema version stamped on every row. v2 (HIMMEL-2022) only ADDS fields to
// the session rows, so a v1 row stays readable and the exporter accepts both.
export const SESSION_RUN_SCHEMA_VERSION = 2;
export type SessionRunSchemaVersion = 1 | 2;

// The failure log the fail-open contract used to lack. session-run-hook.ts
// swallowed every error and exited 0, which is how a five-day ledger outage
// (HIMMEL-2022) produced no evidence anywhere. One bounded line per failure,
// still exit 0 — the hook must never block a session start or teardown.
export const SESSION_RUN_ERROR_LOG_MAX_BYTES = 256 * 1024;

// A SessionEnd payload's `.reason` is normalized into this closed enum before
// it is written. It becomes a Prometheus label downstream, and an unbounded
// label value is a cardinality explosion; anything unrecognized lands on
// "other" (which is also Claude Code's own documented default).
export const SESSION_END_REASONS = ["clear", "logout", "prompt_input_exit", "other"] as const;
export type SessionEndReason = typeof SESSION_END_REASONS[number];

// HIMMEL-2294: a `close` row's `.evidence` is normalized into this closed
// enum before it is written, same discipline as SESSION_END_REASONS above
// (it becomes downstream label-ish data too). "queue_lock_release" is the
// operator-preferred writer call site (scripts/handover/queue-lock.sh's
// release path — every mission leg releases a lock at wrap, so coverage is
// automatic); "close_sentinel" is reserved for a future direct-close path;
// anything unrecognized normalizes to "other".
export const SESSION_CLOSE_EVIDENCE = ["queue_lock_release", "close_sentinel", "other"] as const;
export type SessionCloseEvidence = typeof SESSION_CLOSE_EVIDENCE[number];

export const SUBAGENT_OUTCOMES = ["success", "error", "unknown"] as const;
export type SubagentOutcome = typeof SUBAGENT_OUTCOMES[number];

// Bound on the free-text `description` copied out of the Agent tool_input. A
// dispatch brief in this harness can run to thousands of characters; the
// ledger wants a handle, not a prompt lake.
export const DESCRIPTION_MAX_CHARS = 200;

export const SESSION_START_FIELDS = [
  "v", "kind", "ev", "session_id", "cwd", "transcript_path", "host", "started_at", "pid",
  "source", "permission_mode",
] as const;

export const SESSION_END_FIELDS = [
  "v", "kind", "ev", "session_id", "ended_at", "reason", "permission_mode",
  "model", "effort", "duration_s", "tool_calls", "tool_call_errors",
  "input_tokens", "output_tokens", "cache_read_tokens", "context_tokens",
] as const;

export const SESSION_CLOSE_FIELDS = [
  "v", "kind", "ev", "session_id", "closed_at", "evidence",
] as const;

export const SUBAGENT_START_FIELDS = [
  "v", "kind", "ev", "subagent_id", "parent_session_id", "subagent_type", "description", "started_at",
] as const;

export const SUBAGENT_END_FIELDS = [
  "v", "kind", "ev", "subagent_id", "parent_session_id", "ended_at", "outcome",
] as const;

export type SessionStartRow = {
  v: SessionRunSchemaVersion;
  kind: "session";
  ev: "start";
  session_id: string;
  cwd: string | null;
  transcript_path: string | null;
  host: string | null;
  started_at: string;
  // Best-effort and NULLABLE by design: a SessionStart hook is a grandchild of
  // the Claude Code process and is not handed its parent's pid by the hook
  // contract. Nothing downstream may depend on it (liveness rests on
  // transcript mtime instead).
  pid: number | null;
  // v2. Straight off the SessionStart payload; `source` separates a real
  // startup from a resume/clear/compact re-entry into the same session id.
  source?: string | null;
  permission_mode?: string | null;
};

export type SessionEndRow = {
  v: SessionRunSchemaVersion;
  kind: "session";
  ev: "end";
  session_id: string;
  ended_at: string;
  reason: SessionEndReason;
  // v2. Everything below is DERIVED, best-effort and nullable: the payload
  // carries none of it, so it comes from one bounded pass over the session
  // transcript (see readTranscriptStats in session-run-hook.ts). A session
  // whose transcript is gone still gets a row — with nulls, never a guess.
  permission_mode?: string | null;
  model?: string | null;
  effort?: string | null;
  duration_s?: number | null;
  tool_calls?: number | null;
  tool_call_errors?: number | null;
  // Summed across the session's assistant turns.
  input_tokens?: number | null;
  output_tokens?: number | null;
  cache_read_tokens?: number | null;
  // NOT a sum: the LAST turn's context occupancy (input + cache read + cache
  // creation), i.e. how full the window was when the session ended.
  context_tokens?: number | null;
};

// HIMMEL-2294: a session that ran its close protocol WHILE STILL ALIVE
// declares its own closability by appending this row — the "close-evidence
// reconciler" for session_dead_total false positives (closing a terminal
// kills the process before SessionEnd ever fires, so no `end` row ever
// lands for it). See flow-exporter.ts's buildSessionMetrics for how this
// suppresses the ALERTING gauge only, never the dashboard-facing
// SessionView.status.
export type SessionCloseRow = {
  v: SessionRunSchemaVersion;
  kind: "session";
  ev: "close";
  session_id: string;
  closed_at: string;
  evidence: SessionCloseEvidence;
};

export type SubagentStartRow = {
  v: SessionRunSchemaVersion;
  kind: "subagent";
  ev: "start";
  subagent_id: string;
  parent_session_id: string;
  subagent_type: string | null;
  description: string | null;
  started_at: string;
};

export type SubagentEndRow = {
  v: SessionRunSchemaVersion;
  kind: "subagent";
  ev: "end";
  subagent_id: string;
  parent_session_id: string;
  ended_at: string;
  outcome: SubagentOutcome;
};

export type SessionRunRow = SessionStartRow | SessionEndRow | SessionCloseRow | SubagentStartRow | SubagentEndRow;

export function ledgerPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_SESSION_RUNS_LEDGER;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "session-runs.jsonl");
}

function jsonStr(s: string): string {
  return '"' + s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t") + '"';
}

function jsonVal(v: number | string | null | undefined): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return String(v);
  return jsonStr(v);
}

function serializeFields(fields: readonly string[], vals: string[]): string {
  return "{" + fields.map((k, i) => `"${k}":${vals[i]}`).join(",") + "}";
}

export function serializeSessionRun(row: SessionRunRow): string {
  if (row.kind === "session" && row.ev === "start") {
    return serializeFields(SESSION_START_FIELDS, [
      jsonVal(row.v),
      jsonStr(row.kind),
      jsonStr(row.ev),
      jsonStr(row.session_id),
      jsonVal(row.cwd),
      jsonVal(row.transcript_path),
      jsonVal(row.host),
      jsonStr(row.started_at),
      jsonVal(row.pid),
      jsonVal(row.source),
      jsonVal(row.permission_mode),
    ]);
  }
  if (row.kind === "session" && row.ev === "end") {
    return serializeFields(SESSION_END_FIELDS, [
      jsonVal(row.v),
      jsonStr(row.kind),
      jsonStr(row.ev),
      jsonStr(row.session_id),
      jsonStr(row.ended_at),
      jsonStr(row.reason),
      jsonVal(row.permission_mode),
      jsonVal(row.model),
      jsonVal(row.effort),
      jsonVal(row.duration_s),
      jsonVal(row.tool_calls),
      jsonVal(row.tool_call_errors),
      jsonVal(row.input_tokens),
      jsonVal(row.output_tokens),
      jsonVal(row.cache_read_tokens),
      jsonVal(row.context_tokens),
    ]);
  }
  if (row.kind === "session") {
    // ev === "close"
    return serializeFields(SESSION_CLOSE_FIELDS, [
      jsonVal(row.v),
      jsonStr(row.kind),
      jsonStr(row.ev),
      jsonStr(row.session_id),
      jsonStr(row.closed_at),
      jsonStr(row.evidence),
    ]);
  }
  if (row.ev === "start") {
    return serializeFields(SUBAGENT_START_FIELDS, [
      jsonVal(row.v),
      jsonStr(row.kind),
      jsonStr(row.ev),
      jsonStr(row.subagent_id),
      jsonStr(row.parent_session_id),
      jsonVal(row.subagent_type),
      jsonVal(row.description),
      jsonStr(row.started_at),
    ]);
  }
  return serializeFields(SUBAGENT_END_FIELDS, [
    jsonVal(row.v),
    jsonStr(row.kind),
    jsonStr(row.ev),
    jsonStr(row.subagent_id),
    jsonStr(row.parent_session_id),
    jsonStr(row.ended_at),
    jsonStr(row.outcome),
  ]);
}

export function normalizeEndReason(raw: unknown): SessionEndReason {
  if (typeof raw !== "string") return "other";
  const trimmed = raw.trim();
  return (SESSION_END_REASONS as readonly string[]).includes(trimmed) ? trimmed as SessionEndReason : "other";
}

export function normalizeCloseEvidence(raw: unknown): SessionCloseEvidence {
  if (typeof raw !== "string") return "other";
  const trimmed = raw.trim();
  return (SESSION_CLOSE_EVIDENCE as readonly string[]).includes(trimmed) ? trimmed as SessionCloseEvidence : "other";
}

// Coarse success/error read of an Agent tool_response. This is deliberately
// shallow: the hook must not parse a subagent's prose to guess at semantic
// success, only report whether the tool call itself came back as an error.
// Anything it cannot tell is `unknown`, never optimistically `success`.
export function classifyAgentOutcome(toolResponse: unknown): SubagentOutcome {
  if (toolResponse === undefined || toolResponse === null) return "unknown";
  if (typeof toolResponse === "string") return toolResponse.trim() ? "success" : "unknown";
  if (typeof toolResponse === "object") {
    const r = toolResponse as Record<string, unknown>;
    if (r.is_error === true || r.isError === true) return "error";
    if (typeof r.error === "string" && r.error.trim()) return "error";
    return "success";
  }
  return "unknown";
}

// PAIRING KEY for the two subagent rows.
//
// Claude Code's PreToolUse/PostToolUse payloads carry a native `tool_use_id`
// (verified against the documented hook contract — see the header of
// scripts/hooks/orchestrator-inline-guard.sh, which enumerates the same
// payload). When it is present it IS the correlator: exact, no derivation.
//
// The fallback exists only for a payload that somehow lacks it (an older
// harness build, a different runner). It hashes ONLY fields both events carry
// unchanged — session id and the tool_input — deliberately NOT a timestamp,
// which PostToolUse cannot re-derive and which would therefore break pairing
// outright. Its weakness is honest and documented: two identical Agent
// dispatches from one session collide onto one id, so their start/end rows
// pair arbitrarily. That is a degraded reading, not a wrong one — the count of
// live subagents stays right; only per-instance identity blurs.
export function subagentIdFor(sessionId: string, toolInput: unknown, toolUseId?: unknown): string {
  if (typeof toolUseId === "string" && toolUseId.trim()) return toolUseId.trim();
  let inputText: string;
  try {
    inputText = JSON.stringify(toolInput ?? null) ?? "null";
  } catch {
    inputText = "null";
  }
  return createHash("sha256").update(`${sessionId}\x00${inputText}`).digest("hex").slice(0, 12);
}

export function truncateDescription(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  return trimmed.length > DESCRIPTION_MAX_CHARS ? trimmed.slice(0, DESCRIPTION_MAX_CHARS) : trimmed;
}

export function sessionRunErrorLogPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_SESSION_RUNS_ERROR_LOG;
  if (override && override.trim()) return override;
  return ledgerPath(env).replace(/\.jsonl$/, "") + ".errors.log";
}

// Bounded, best-effort, and itself incapable of throwing: an observability
// hook that fails must leave a trace, but must never become the reason a
// session cannot start or exit.
export function logSessionRunError(event: string, err: unknown, path?: string): void {
  try {
    const p = path ?? sessionRunErrorLogPath();
    if (existsSync(p) && statSync(p).size >= SESSION_RUN_ERROR_LOG_MAX_BYTES) return;
    const dir = dirname(p);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const msg = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
    appendFileSync(p, `${new Date().toISOString()} ${event} ${msg.replace(/[\r\n\t]+/g, " ").slice(0, 500)}\n`, "utf8");
  } catch {
    // Deliberately empty: nothing left to report to.
  }
}

export function appendSessionRun(row: SessionRunRow, path?: string): void {
  const p = path ?? ledgerPath();
  const dir = dirname(p);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  if (existsSync(p) && statSync(p).size >= SESSION_RUN_ROTATE_BYTES) {
    try {
      rmSync(p + ".1", { force: true });
      renameSync(p, p + ".1");
    } catch {
      // Best-effort rotation, mirroring appendFlowRun: a concurrent writer may
      // already have rotated the file away.
    }
  }
  appendFileSync(p, serializeSessionRun(row) + "\n", "utf8");
}
