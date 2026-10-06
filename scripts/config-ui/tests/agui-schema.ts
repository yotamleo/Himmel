// agui-schema.ts — a test-only check of emitted events against the @ag-ui/core
// 1.0.2 event schemas (dist/schemas.mjs), transcribed by hand: config-ui has no
// package manifest, so the zod schemas themselves are not importable here.
// Covers each emitted type's required fields and their JSON types, the integer
// timestamp, and the RFC 6902 shape of a STATE_DELTA.

type Spec = Record<string, "string" | "array" | "any">;

const REQUIRED: Record<string, Spec> = {
  RUN_STARTED: { threadId: "string", runId: "string" },
  RUN_FINISHED: { threadId: "string", runId: "string" },
  RUN_ERROR: { message: "string" },
  TEXT_MESSAGE_START: { messageId: "string" },
  TEXT_MESSAGE_CONTENT: { messageId: "string", delta: "string" },
  TEXT_MESSAGE_END: { messageId: "string" },
  TOOL_CALL_START: { toolCallId: "string", toolCallName: "string" },
  TOOL_CALL_ARGS: { toolCallId: "string", delta: "string" },
  TOOL_CALL_END: { toolCallId: "string" },
  TOOL_CALL_RESULT: { messageId: "string", toolCallId: "string", content: "string" },
  STATE_SNAPSHOT: { snapshot: "any" },
  STATE_DELTA: { delta: "array" },
};

const OPTIONAL_STRINGS = ["parentMessageId", "code", "role"];
const PATCH_OPS = new Set(["add", "remove", "replace", "move", "copy", "test"]);
const JSON_POINTER = /^(\/([^~]|~[01])*)*$/;

// Returns a list of violations; empty means the event validates.
export function aguiViolations(ev: Record<string, unknown>): string[] {
  const out: string[] = [];
  const spec = REQUIRED[ev.type as string];
  if (!spec) return [`unknown event type ${String(ev.type)}`];
  for (const [key, kind] of Object.entries(spec)) {
    const v = ev[key];
    if (kind === "string" && typeof v !== "string") out.push(`${ev.type}.${key} must be a string`);
    if (kind === "array" && !Array.isArray(v)) out.push(`${ev.type}.${key} must be an array`);
    if (kind === "any" && (v === undefined)) out.push(`${ev.type}.${key} is required`);
  }
  if ("timestamp" in ev && !Number.isSafeInteger(ev.timestamp)) out.push(`${ev.type}.timestamp must be an integer`);
  for (const key of OPTIONAL_STRINGS) {
    if (key in ev && typeof ev[key] !== "string") out.push(`${ev.type}.${key} must be a string`);
  }
  if (ev.type === "TEXT_MESSAGE_START" && "role" in ev && !["developer", "system", "assistant", "user"].includes(ev.role as string)) {
    out.push("TEXT_MESSAGE_START.role is not a text role");
  }
  if (ev.type === "TOOL_CALL_RESULT" && "role" in ev && ev.role !== "tool") out.push("TOOL_CALL_RESULT.role must be tool");
  if (ev.type === "RUN_FINISHED" && "outcome" in ev) {
    const t = (ev.outcome as { type?: unknown })?.type;
    if (!["success", "interrupt", "cancelled"].includes(t as string)) out.push("RUN_FINISHED.outcome.type is invalid");
  }
  if (ev.type === "STATE_DELTA" && Array.isArray(ev.delta)) {
    for (const op of ev.delta as Record<string, unknown>[]) {
      if (!PATCH_OPS.has(op.op as string)) out.push(`STATE_DELTA op ${String(op.op)} is not RFC 6902`);
      if (typeof op.path !== "string" || !JSON_POINTER.test(op.path)) out.push(`STATE_DELTA path ${String(op.path)} is not a JSON Pointer`);
      if ((op.op === "add" || op.op === "replace" || op.op === "test") && !("value" in op)) out.push(`STATE_DELTA ${op.op} needs a value`);
    }
  }
  if ("metadata" in ev && (typeof ev.metadata !== "object" || ev.metadata === null || Array.isArray(ev.metadata))) {
    out.push(`${ev.type}.metadata must be an object`);
  }
  return out;
}
