// scripts/observability/session-run-hook.ts
// HIMMEL-1052 writer side: the thin hook entrypoint that turns a Claude Code
// hook payload into one `session-runs.jsonl` row.
//
//   bun scripts/observability/session-run-hook.ts session-start   < SessionStart payload
//   bun scripts/observability/session-run-hook.ts session-end     < SessionEnd payload
//   bun scripts/observability/session-run-hook.ts subagent-start  < PreToolUse  (matcher "Agent")
//   bun scripts/observability/session-run-hook.ts subagent-end    < PostToolUse (matcher "Agent")
//   bun scripts/observability/session-run-hook.ts session-close --evidence <token>
//     HIMMEL-2294: NOT a hook payload verb. Called directly from a close-protocol
//     call site (e.g. scripts/handover/queue-lock.sh's release path) WHILE THE
//     SESSION IS STILL ALIVE, so it takes no stdin — the session id comes from
//     $CLAUDE_CODE_SESSION_ID and the evidence token from argv.
//
// FAIL-OPEN, ALWAYS. Every path exits 0 with empty stdout. This rides on
// existing hook chokepoints (piggyback, don't poll) and must never block, slow
// or fail the tool call it observes — a telemetry gap is always cheaper than a
// bricked session. It emits no permissionDecision and no additionalContext.
//
// It is also a PURE WRITER: it appends one line and exits. It controls no
// process and takes no decision. Its ONE read is the session transcript, at
// SessionEnd only, to derive the v2 fields the hook payload does not carry
// (model, effort, token usage, tool-call counts) — read-only, bounded, and
// discarded. The reader half lives in flow-exporter.ts and stays equally
// passive.
import { existsSync, readFileSync, statSync } from "node:fs";
import { hostname } from "node:os";
import {
  appendSessionRun,
  classifyAgentOutcome,
  logSessionRunError,
  normalizeCloseEvidence,
  normalizeEndReason,
  SESSION_RUN_SCHEMA_VERSION,
  subagentIdFor,
  truncateDescription,
  type SessionCloseRow,
  type SessionRunRow,
} from "./session-run-ledger";

export type HookEvent = "session-start" | "session-end" | "subagent-start" | "subagent-end" | "session-close";

export const HOOK_EVENTS: readonly HookEvent[] = [
  "session-start",
  "session-end",
  "subagent-start",
  "subagent-end",
  "session-close",
] as const;

function str(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function num(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

// Ceiling on the SessionEnd transcript read. The largest transcript in the
// live corpus is 69 MB and reads + parses in 82 ms, so this bound never fires
// in practice — it exists only so a pathological file cannot wedge a teardown
// hook against its timeout.
export const TRANSCRIPT_MAX_BYTES = 200 * 1024 * 1024;

export type TranscriptStats = {
  model: string | null;
  effort: string | null;
  duration_s: number | null;
  tool_calls: number;
  tool_call_errors: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  context_tokens: number | null;
};

// ONE bounded pass over the session transcript, for the fields the hook
// payload does not carry (model, effort, token usage, tool-call counts).
//
// Transcript shape is the one `tool-call-census.sh` already documents, checked
// again 2026-08-22: assistant records carry `message.model`, a top-level
// `effort`, `message.usage`, and `message.content[]` blocks of
// `type:"tool_use"`; tool results arrive as `type:"tool_result"` blocks with
// `.is_error`.
//
// ponytail: two known ceilings, both deliberate. (1) Subagent (`isSidechain`)
// records live in the SAME transcript, so tool_calls / tool_call_errors are
// whole-session totals including fan-out, not parent-only. (2) `duration_s`
// spans the first to the last record this pass parses — first model turn to
// last — not the true SessionStart instant, which the transcript never
// records. Join against the session start row if that gap ever matters.
export function readTranscriptStats(path: string | null): TranscriptStats | null {
  if (!path || !existsSync(path)) return null;
  if (statSync(path).size > TRANSCRIPT_MAX_BYTES) return null;
  const text = readFileSync(path, "utf8");

  let model: string | null = null;
  let effort: string | null = null;
  let firstTs: string | null = null;
  let lastTs: string | null = null;
  let toolCalls = 0;
  let toolCallErrors = 0;
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheReadTokens = 0;
  let contextTokens: number | null = null;

  for (const line of text.split("\n")) {
    // Prefilter before JSON.parse: only assistant records, and records
    // carrying a tool_result block, hold anything this pass wants. On a 69 MB
    // transcript that is ~700 parses instead of ~30 000.
    if (!line.includes('"type":"assistant"') && !line.includes('"tool_result"')) continue;
    let rec: Record<string, any>;
    try {
      rec = JSON.parse(line) as Record<string, any>;
    } catch {
      continue;
    }
    if (typeof rec?.timestamp === "string") {
      if (!firstTs) firstTs = rec.timestamp;
      lastTs = rec.timestamp;
    }
    const content = rec?.message?.content;
    if (Array.isArray(content)) {
      for (const block of content) {
        if (block?.type === "tool_use") toolCalls += 1;
        else if (block?.type === "tool_result" && block?.is_error === true) toolCallErrors += 1;
      }
    }
    if (rec?.type !== "assistant") continue;
    if (typeof rec.message?.model === "string") model = rec.message.model;
    if (typeof rec.effort === "string") effort = rec.effort;
    const usage = rec.message?.usage;
    if (usage && typeof usage === "object") {
      inputTokens += num(usage.input_tokens);
      outputTokens += num(usage.output_tokens);
      cacheReadTokens += num(usage.cache_read_input_tokens);
      // Overwritten every turn on purpose: the LAST turn is the one that says
      // how full the context window was when the session ended.
      contextTokens = num(usage.input_tokens) + num(usage.cache_read_input_tokens)
        + num(usage.cache_creation_input_tokens);
    }
  }

  const spanMs = firstTs && lastTs ? Date.parse(lastTs) - Date.parse(firstTs) : NaN;
  return {
    model,
    effort,
    duration_s: Number.isFinite(spanMs) ? Math.max(0, Math.round(spanMs / 1000)) : null,
    tool_calls: toolCalls,
    tool_call_errors: toolCallErrors,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    cache_read_tokens: cacheReadTokens,
    context_tokens: contextTokens,
  };
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
  stats: TranscriptStats | null = null,
): SessionRunRow | null {
  const sessionId = str(payload.session_id);
  if (!sessionId) return null;

  if (event === "session-start") {
    const pid = typeof payload.pid === "number" && Number.isFinite(payload.pid) ? payload.pid : null;
    return {
      v: SESSION_RUN_SCHEMA_VERSION,
      kind: "session",
      ev: "start",
      session_id: sessionId,
      cwd: str(payload.cwd),
      transcript_path: str(payload.transcript_path),
      host,
      started_at: nowIso,
      pid,
      source: str(payload.source),
      permission_mode: str(payload.permission_mode),
    };
  }

  if (event === "session-end") {
    return {
      v: SESSION_RUN_SCHEMA_VERSION,
      kind: "session",
      ev: "end",
      session_id: sessionId,
      ended_at: nowIso,
      reason: normalizeEndReason(payload.reason),
      permission_mode: str(payload.permission_mode),
      // Payload first (a future harness build may start carrying these),
      // transcript second. Never a guess: no stats and no payload field is
      // null, not a default.
      model: str(payload.model) ?? stats?.model ?? null,
      effort: str(payload.effort) ?? stats?.effort ?? null,
      duration_s: stats?.duration_s ?? null,
      tool_calls: stats?.tool_calls ?? null,
      tool_call_errors: stats?.tool_call_errors ?? null,
      input_tokens: stats?.input_tokens ?? null,
      output_tokens: stats?.output_tokens ?? null,
      cache_read_tokens: stats?.cache_read_tokens ?? null,
      context_tokens: stats?.context_tokens ?? null,
    };
  }

  const toolInput = toolInputOf(payload);
  const subagentId = subagentIdFor(sessionId, toolInput, payload.tool_use_id);

  if (event === "subagent-start") {
    return {
      v: SESSION_RUN_SCHEMA_VERSION,
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
    v: SESSION_RUN_SCHEMA_VERSION,
    kind: "subagent",
    ev: "end",
    subagent_id: subagentId,
    parent_session_id: sessionId,
    ended_at: nowIso,
    outcome: classifyAgentOutcome(payload.tool_response),
  };
}

// Exported for unit tests: env + argv -> row decision, no I/O. Returns null
// when CLAUDE_CODE_SESSION_ID is absent/blank — a silent skip, matching
// recordFromPayload's "no session id, no row" contract.
export function recordSessionClose(
  env: Record<string, string | undefined>,
  argv: readonly string[],
  nowIso: string,
): SessionCloseRow | null {
  const sessionId = str(env.CLAUDE_CODE_SESSION_ID);
  if (!sessionId) return null;
  const flagIndex = argv.indexOf("--evidence");
  const rawEvidence = flagIndex !== -1 ? argv[flagIndex + 1] : undefined;
  return {
    v: SESSION_RUN_SCHEMA_VERSION,
    kind: "session",
    ev: "close",
    session_id: sessionId,
    closed_at: nowIso,
    evidence: normalizeCloseEvidence(rawEvidence),
  };
}

export function isHookEvent(value: string | undefined): value is HookEvent {
  return typeof value === "string" && (HOOK_EVENTS as readonly string[]).includes(value);
}

export function utcIso(nowMs: number = Date.now()): string {
  return new Date(nowMs).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function main(): void {
  const event = process.argv[2];
  if (!isHookEvent(event)) return;

  // HIMMEL-2294: session-close is not a hook payload verb and takes no
  // stdin (the session that calls it is still alive, mid close-protocol —
  // there is no payload to read). Handled entirely separately from the
  // stdin-driven hook path below.
  if (event === "session-close") {
    const row = recordSessionClose(process.env, process.argv, utcIso());
    if (!row) return;
    try {
      appendSessionRun(row);
    } catch (err) {
      logSessionRunError(event, err);
    }
    return;
  }

  let payload: Record<string, unknown>;
  try {
    // SYNCHRONOUS ON PURPOSE (HIMMEL-2022). This used to be
    // `await Bun.stdin.text()` inside a floating `main().catch().finally()`.
    // Under Bun 1.4.0 a pending stdin read does not ref the event loop, so Bun
    // drained the loop and exited 0 BEFORE stdin was ever consumed: every hook
    // invocation "succeeded" and wrote nothing, and the ledger went quiet for
    // five days without leaving one line of evidence anywhere. A blocking fd-0
    // read cannot lose that race.
    const parsed = JSON.parse(readFileSync(0, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;
    payload = parsed as Record<string, unknown>;
  } catch (err) {
    logSessionRunError(event, err);
    return;
  }
  let host: string | null = null;
  try {
    host = str(hostname());
  } catch {
    host = null;
  }
  // Enrichment is SessionEnd-only: at SessionStart the transcript is empty or
  // absent, so there is nothing to read and nothing to pay for.
  let stats: TranscriptStats | null = null;
  if (event === "session-end") {
    try {
      stats = readTranscriptStats(str(payload.transcript_path));
    } catch (err) {
      // A transcript this hook cannot read costs the enriched fields, not the
      // row: the v2 end row still lands, with nulls.
      logSessionRunError(event, err);
    }
  }
  const row = recordFromPayload(event, payload, utcIso(), host, stats);
  if (!row) return;
  appendSessionRun(row);
}

if (import.meta.main) {
  // Belt and braces on the fail-open contract: even an unexpected throw inside
  // main() (a full disk, a permission error on the ledger dir) exits 0 — but
  // it now leaves a line behind first.
  try {
    main();
  } catch (err) {
    logSessionRunError(process.argv[2] ?? "?", err);
  }
  process.exit(0);
}
