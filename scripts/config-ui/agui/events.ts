// events.ts — the AG-UI events the journal mapper emits (HIMMEL-4480).
//
// Plain object types, pinned by hand to the @ag-ui/core 1.0.2 schemas
// (dist/schemas.mjs, PROTOCOL_VERSION "1.0"): the type names, the required
// fields, and `timestamp` as an integer of epoch milliseconds. Only the
// subset the mapper produces is declared. No runtime import of @ag-ui/core:
// the mapper stays dependency-free, and tests/agui-schema.ts checks every
// emitted event against these same required fields.

export const AGUI_PROTOCOL_VERSION = "1.0";

type Base = { timestamp?: number; metadata?: Record<string, unknown> };

export type RunStartedEvent = Base & { type: "RUN_STARTED"; threadId: string; runId: string };
export type RunFinishedEvent = Base & {
  type: "RUN_FINISHED";
  threadId: string;
  runId: string;
  outcome?: { type: "success" } | { type: "cancelled" };
};
// RUN_ERROR carries no threadId/runId in the 1.0 schema; the run it ends is the open one.
export type RunErrorEvent = Base & { type: "RUN_ERROR"; message: string; code?: string };

export type TextMessageStartEvent = Base & {
  type: "TEXT_MESSAGE_START";
  messageId: string;
  role: "assistant" | "user";
};
export type TextMessageContentEvent = Base & { type: "TEXT_MESSAGE_CONTENT"; messageId: string; delta: string };
export type TextMessageEndEvent = Base & { type: "TEXT_MESSAGE_END"; messageId: string };

export type ToolCallStartEvent = Base & {
  type: "TOOL_CALL_START";
  toolCallId: string;
  toolCallName: string;
  parentMessageId?: string;
};
export type ToolCallArgsEvent = Base & { type: "TOOL_CALL_ARGS"; toolCallId: string; delta: string };
export type ToolCallEndEvent = Base & { type: "TOOL_CALL_END"; toolCallId: string };
export type ToolCallResultEvent = Base & {
  type: "TOOL_CALL_RESULT";
  messageId: string;
  toolCallId: string;
  content: string;
  role: "tool";
  isError?: true; // extra field (the schema is loose): the tool reported a failure
};

// RFC 6902 operations; the mapper only ever adds.
export type JsonPatchOp = { op: "add" | "replace"; path: string; value: unknown };
export type StateSnapshotEvent = Base & { type: "STATE_SNAPSHOT"; snapshot: unknown };
export type StateDeltaEvent = Base & { type: "STATE_DELTA"; delta: JsonPatchOp[] };

export type AguiEvent =
  | RunStartedEvent
  | RunFinishedEvent
  | RunErrorEvent
  | TextMessageStartEvent
  | TextMessageContentEvent
  | TextMessageEndEvent
  | ToolCallStartEvent
  | ToolCallArgsEvent
  | ToolCallEndEvent
  | ToolCallResultEvent
  | StateSnapshotEvent
  | StateDeltaEvent;

export type AguiEventType = AguiEvent["type"];
