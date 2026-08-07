// scripts/observability/session-run-hook.ts
// HIMMEL-1052 writer side: the thin hook entrypoint that turns a Claude Code
// hook payload into one `session-runs.jsonl` row.
//
//   bun scripts/observability/session-run-hook.ts session-start   < SessionStart payload
//   bun scripts/observability/session-run-hook.ts session-end     < SessionEnd payload
//   bun scripts/observability/session-run-hook.ts subagent-start  < PreToolUse  (matcher "Agent")
//   bun scripts/observability/session-run-hook.ts subagent-end    < PostToolUse (matcher "Agent")
//
// FAIL-OPEN, ALWAYS. Every path exits 0 with empty stdout. This rides on
// existing hook chokepoints (piggyback, don't poll) and must never block, slow
// or fail the tool call it observes — a telemetry gap is always cheaper than a
// bricked session. It emits no permissionDecision and no additionalContext.
//
// It is also a PURE WRITER: it appends one line and exits. It reads no other
// state, controls no process, and takes no decision. The reader half lives in
// flow-exporter.ts and stays equally passive.
import { hostname } from "node:os";
import {
  appendSessionRun,
  classifyAgentOutcome,
  normalizeEndReason,
  subagentIdFor,
  truncateDescription,
  type SessionRunRow,
} from "./session-run-ledger";

export type HookEvent = "session-start" | "session-end" | "subagent-start" | "subagent-end";

export const HOOK_EVENTS: readonly HookEvent[] = [
  "session-start",
  "session-end",
  "subagent-start",
  "subagent-end",
] as const;

function str(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function toolInputOf(payload: Record<string, unknown>): Record<string, unknown> {
  const raw = payload.tool_input;
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Record<string, unknown> : {};
}

// Exported for unit tests: the whole payload -> row decision, with no I/O.
// Returns null when the payload cannot produce a usable row (no session id) —
// a silent skip, never a fabricated record.
export function recordFromPayload(
  event: HookEvent,
  payload: Record<string, unknown>,
  nowIso: string,
  host: string | null,
): SessionRunRow | null {
  const sessionId = str(payload.session_id);
  if (!sessionId) return null;

  if (event === "session-start") {
    const pid = typeof payload.pid === "number" && Number.isFinite(payload.pid) ? payload.pid : null;
    return {
      v: 1,
      kind: "session",
      ev: "start",
      session_id: sessionId,
      cwd: str(payload.cwd),
      transcript_path: str(payload.transcript_path),
      host,
      started_at: nowIso,
      pid,
    };
  }

  if (event === "session-end") {
    return {
      v: 1,
      kind: "session",
      ev: "end",
      session_id: sessionId,
      ended_at: nowIso,
      reason: normalizeEndReason(payload.reason),
    };
  }

  const toolInput = toolInputOf(payload);
  const subagentId = subagentIdFor(sessionId, toolInput, payload.tool_use_id);

  if (event === "subagent-start") {
    return {
      v: 1,
      kind: "subagent",
      ev: "start",
      subagent_id: subagentId,
      parent_session_id: sessionId,
      subagent_type: str(toolInput.subagent_type),
      description: truncateDescription(toolInput.description),
      started_at: nowIso,
    };
  }

  return {
    v: 1,
    kind: "subagent",
    ev: "end",
    subagent_id: subagentId,
    parent_session_id: sessionId,
    ended_at: nowIso,
    outcome: classifyAgentOutcome(payload.tool_response),
  };
}

export function isHookEvent(value: string | undefined): value is HookEvent {
  return typeof value === "string" && (HOOK_EVENTS as readonly string[]).includes(value);
}

export function utcIso(nowMs: number = Date.now()): string {
  return new Date(nowMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}

async function main(): Promise<void> {
  const event = process.argv[2];
  if (!isHookEvent(event)) return;
  let payload: Record<string, unknown>;
  try {
    const raw = await Bun.stdin.text();
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;
    payload = parsed as Record<string, unknown>;
  } catch {
    return;
  }
  let host: string | null = null;
  try {
    host = str(hostname());
  } catch {
    host = null;
  }
  const row = recordFromPayload(event, payload, utcIso(), host);
  if (!row) return;
  appendSessionRun(row);
}

if (import.meta.main) {
  // Belt and braces on the fail-open contract: even an unexpected throw inside
  // main() (a full disk, a permission error on the ledger dir) exits 0.
  main().catch(() => {}).finally(() => process.exit(0));
}
