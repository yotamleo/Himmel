// journal-mapper.ts — Claude Code session journal (JSONL) → AG-UI events (HIMMEL-4480).
//
// Source: the transcript Claude Code writes per session at
// ~/.claude/projects/<cwd-slug>/<session-id>.jsonl, one JSON record per line.
// The format is not a documented API, so this module is tolerant by design and
// pinned by the fixtures in tests/fixtures/agui/. Shapes it relies on (Claude
// Code 2.1.x):
//   user       message.content is a string or an array of {type:"text"} blocks
//              (a prompt), or of {type:"tool_result", tool_use_id, content,
//              is_error} blocks (tool output). isMeta marks injected context.
//   assistant  ONE content block per record (text | tool_use | thinking); the
//              blocks of one API message share message.id. isApiErrorMessage
//              marks a synthetic API error record.
//   system     subtype "turn_duration" closes a turn.
//   others     (attachment, permission-mode, file-history-*, ...) carry no
//              agent output.
//
// Mapping:
//   prompt                     → RUN_STARTED, then TEXT_MESSAGE_* (role user)
//   assistant text             → TEXT_MESSAGE_START / CONTENT / END (role assistant)
//   assistant tool_use         → TOOL_CALL_START / ARGS (the input as JSON) / END
//   tool_result                → TOOL_CALL_RESULT (isError: true on a failure)
//   turn_duration              → RUN_FINISHED {outcome: success}
//   "[Request interrupted…"    → RUN_FINISHED {outcome: cancelled}
//   API error record           → RUN_ERROR
//   a prompt while a run is open → RUN_FINISHED (no outcome) for the old run first
//   critic-panel report result → STATE_SNAPSHOT { review }
//   a verdict-recording Bash   → STATE_DELTA, once its result comes back without error:
//     write-verdicts.sh (its --from-file is the text an earlier successful
//     Write left at that path) or ledger-append.sh finding/amend rows
// A tool call's parentMessageId is the first text its API message streamed;
// a call whose message streamed no text has none.
// threadId is the journal's sessionId (or the caller's), runId the prompt
// record's uuid. Agent output with no prompt before it opens an implicit run.
//
// API (consumed by the SSE endpoint and the AG-UI page):
//   createJournalMapper({threadId?}) → JournalMapper, stateful and incremental:
//     pushLine(line)    map one complete JSONL line
//     pushChunk(text)   map raw appended bytes of a growing file; a partial
//                       last line is held until its newline arrives
//     flush()           end of input: map (or count as malformed) a held tail
//     stats             { lines, events, ignored, unknown, malformed }
//     state             the current { review } state, or undefined
//   mapJournal(text, opts) / mapFile(path, opts) → { events, stats } for a whole file.
// A run still open at the end of input stays open: the session may be live.
// Nothing here throws on bad input; a bad line is counted and skipped.

import { readFileSync } from "node:fs";
import type { AguiEvent, JsonPatchOp } from "./events.ts";
import { commandVerdicts, extractHead, extractVerdicts, parsePanelReport, type ReviewState, type VerdictUpdate } from "./review-panel.ts";

export type MapperStats = {
  lines: number; // non-blank lines seen
  events: number; // events emitted
  ignored: number; // known records that carry no agent output (and duplicates)
  unknown: number; // well-formed records of a type this mapper does not know
  malformed: number; // unparseable lines, non-objects, or known types of the wrong shape
};

export type MapperOptions = { threadId?: string };

export type JournalMapper = {
  pushLine(line: string): AguiEvent[];
  pushChunk(chunk: string): AguiEvent[];
  flush(): AguiEvent[];
  readonly stats: MapperStats;
  readonly state: { review: ReviewState } | undefined;
};

// Record types seen in real journals that never produce events.
const SILENT_TYPES = new Set([
  "attachment", "permission-mode", "mode", "last-prompt", "atis-latch", "agent-name",
  "custom-title", "ai-title", "file-history-snapshot", "file-history-delta", "pr-link",
  "cost-state", "summary", "queue-operation", "relocated", "worktree-state", "frame-link",
  "artifact-autoreact-ledger", "artifact-comment-monitor",
]);
const INTERRUPT = /^\[Request interrupted by user/;

type Rec = Record<string, unknown>;
type Block = Rec & { type?: unknown };
// What a tool call does to review state once it succeeds.
type PendingCall = {
  verdicts: VerdictUpdate[]; // recorded by a Bash command
  head?: string; // the --head a Bash command names
  write?: { path: string; text?: string }; // a Write call: its file, and the text when it holds VERDICT lines
};

const isObject = (v: unknown): v is Rec => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

function epochMs(rec: Rec): { timestamp?: number } {
  const ms = Date.parse(str(rec.timestamp) ?? "");
  return Number.isFinite(ms) ? { timestamp: ms } : {};
}

// Tool-result content is a string or an array of content parts; flatten to text.
function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => (isObject(part) && part.type === "text" ? (str(part.text) ?? "") : `[${isObject(part) ? String(part.type) : "part"}]`))
    .join("\n");
}

export function createJournalMapper(opts: MapperOptions = {}): JournalMapper {
  const stats: MapperStats = { lines: 0, events: 0, ignored: 0, unknown: 0, malformed: 0 };
  let threadId = opts.threadId;
  let runId: string | undefined;
  let review: ReviewState | undefined;
  let tail = "";
  const seen = new Set<string>(); // record uuids already mapped
  const pending = new Map<string, PendingCall>(); // tool calls awaiting their result
  const verdictFiles = new Map<string, string>(); // path → text with VERDICT lines a successful Write left there
  const firstText = new Map<string, string>(); // API message.id → messageId of its first emitted text

  function startRun(rec: Rec, out: AguiEvent[], id: string) {
    threadId ??= str(rec.sessionId) ?? "journal";
    runId = id;
    out.push({ type: "RUN_STARTED", threadId, runId, ...epochMs(rec) });
  }

  function finishRun(rec: Rec, out: AguiEvent[], outcome?: "success" | "cancelled") {
    if (runId === undefined) return;
    out.push({
      type: "RUN_FINISHED", threadId: threadId!, runId, ...epochMs(rec),
      ...(outcome ? { outcome: { type: outcome } } : {}),
    });
    runId = undefined;
  }

  function ensureRun(rec: Rec, out: AguiEvent[]) {
    if (runId === undefined) startRun(rec, out, str(rec.uuid) ?? `run-${stats.lines}`);
  }

  function textMessage(rec: Rec, out: AguiEvent[], messageId: string, role: "user" | "assistant", text: string) {
    const ts = epochMs(rec);
    out.push({ type: "TEXT_MESSAGE_START", messageId, role, ...ts });
    out.push({ type: "TEXT_MESSAGE_CONTENT", messageId, delta: text, ...ts });
    out.push({ type: "TEXT_MESSAGE_END", messageId, ...ts });
  }

  // Returns false when the record has the wrong shape (counted as malformed).
  function mapUser(rec: Rec, out: AguiEvent[]): boolean {
    const message = rec.message;
    if (!isObject(message)) return false;
    const content = message.content;
    if (typeof content !== "string" && !Array.isArray(content)) return false;
    const blocks: Block[] = typeof content === "string" ? [{ type: "text", text: content }] : content.filter(isObject);

    const results = blocks.filter((b) => b.type === "tool_result");
    if (results.length) {
      ensureRun(rec, out);
      for (const block of results) mapToolResult(rec, block, out);
      return true;
    }
    const text = blocks.filter((b) => b.type === "text").map((b) => str(b.text) ?? "").join("\n");
    if (rec.isMeta === true || !text) {
      stats.ignored++;
      return true;
    }
    if (INTERRUPT.test(text)) {
      finishRun(rec, out, "cancelled");
      return true;
    }
    const id = str(rec.uuid) ?? `prompt-${stats.lines}`;
    finishRun(rec, out);
    startRun(rec, out, id);
    textMessage(rec, out, id, "user", text);
    return true;
  }

  function mapToolResult(rec: Rec, block: Block, out: AguiEvent[]) {
    const toolCallId = str(block.tool_use_id);
    if (!toolCallId) return;
    const isError = block.is_error === true;
    out.push({
      type: "TOOL_CALL_RESULT", messageId: `${toolCallId}:result`, toolCallId, role: "tool",
      content: resultText(block.content), ...(isError ? { isError: true as const } : {}), ...epochMs(rec),
    });
    const call = pending.get(toolCallId);
    pending.delete(toolCallId);
    if (isError) return;
    if (call?.write) {
      if (call.write.text !== undefined) verdictFiles.set(call.write.path, call.write.text);
      else verdictFiles.delete(call.write.path);
    }
    const panel = parsePanelReport(resultText(block.content));
    if (panel) {
      review = { ...(call?.head ? { head: call.head } : {}), ...panel };
      out.push({ type: "STATE_SNAPSHOT", snapshot: { review: structuredClone(review) }, ...epochMs(rec) });
    }
    if (call?.verdicts.length && review) applyVerdicts(rec, call.verdicts, out);
  }

  function applyVerdicts(rec: Rec, verdicts: VerdictUpdate[], out: AguiEvent[]) {
    const delta: JsonPatchOp[] = [];
    for (const v of verdicts) {
      const i = review!.findings.findIndex((f) => f.id === v.id);
      if (i < 0) continue; // a verdict for a finding this journal never showed
      const finding = review!.findings[i];
      finding.verdict = v.verdict;
      delta.push({ op: "add", path: `/review/findings/${i}/verdict`, value: v.verdict });
      if (v.ticket) {
        finding.ticket = v.ticket;
        delta.push({ op: "add", path: `/review/findings/${i}/ticket`, value: v.ticket });
      }
    }
    if (delta.length) out.push({ type: "STATE_DELTA", delta, ...epochMs(rec) });
  }

  // Only a Bash command records verdicts or names a panel head; a Write only
  // stages the VERDICT lines a later write-verdicts.sh --from-file reads.
  function reviewEffect(name: string, input: unknown): PendingCall {
    const args = isObject(input) ? input : {};
    const command = str(args.command);
    if (name === "Bash" && command) {
      return { verdicts: commandVerdicts(command, (path) => verdictFiles.get(path)), head: extractHead(command) };
    }
    const path = str(args.file_path);
    const content = str(args.content);
    if (name === "Write" && path && content !== undefined) {
      return { verdicts: [], write: { path, ...(extractVerdicts(content).length ? { text: content } : {}) } };
    }
    return { verdicts: [] };
  }

  function mapAssistant(rec: Rec, out: AguiEvent[]): boolean {
    const message = rec.message;
    if (!isObject(message) || !Array.isArray(message.content)) return false;
    const blocks = message.content.filter(isObject) as Block[];
    if (rec.isApiErrorMessage === true) {
      const text = blocks.map((b) => str(b.text) ?? "").join("\n") || "API error";
      out.push({ type: "RUN_ERROR", message: text, ...(str(rec.error) ? { code: str(rec.error) } : {}), ...epochMs(rec) });
      runId = undefined;
      return true;
    }
    const messageId = str(message.id);
    let mapped = false;
    blocks.forEach((block, i) => {
      if (block.type === "text" && str(block.text)) {
        ensureRun(rec, out);
        const id = str(rec.uuid) ?? `${messageId ?? "message"}:${i}`;
        textMessage(rec, out, id, "assistant", str(block.text)!);
        if (messageId && !firstText.has(messageId)) firstText.set(messageId, id);
        mapped = true;
      } else if (block.type === "tool_use" && str(block.id) && str(block.name)) {
        ensureRun(rec, out);
        const toolCallId = str(block.id)!;
        const toolCallName = str(block.name)!;
        // The text the same API message streamed before this call, if any.
        const parentMessageId = messageId ? firstText.get(messageId) : undefined;
        const ts = epochMs(rec);
        out.push({ type: "TOOL_CALL_START", toolCallId, toolCallName, ...(parentMessageId ? { parentMessageId } : {}), ...ts });
        out.push({ type: "TOOL_CALL_ARGS", toolCallId, delta: JSON.stringify(block.input ?? {}), ...ts });
        out.push({ type: "TOOL_CALL_END", toolCallId, ...ts });
        pending.set(toolCallId, reviewEffect(toolCallName, block.input));
        mapped = true;
      }
    });
    if (!mapped) stats.ignored++; // thinking, empty text
    return true;
  }

  function mapRecord(rec: Rec, out: AguiEvent[]): void {
    const type = str(rec.type);
    const uuid = str(rec.uuid);
    if (uuid && seen.has(uuid)) {
      stats.ignored++;
      return;
    }
    let ok = true;
    if (type === "user") ok = mapUser(rec, out);
    else if (type === "assistant") ok = mapAssistant(rec, out);
    else if (type === "system") {
      if (rec.subtype === "turn_duration") finishRun(rec, out, "success");
      else stats.ignored++;
    } else if (type && SILENT_TYPES.has(type)) stats.ignored++;
    else if (type) stats.unknown++;
    else ok = false;
    if (!ok) stats.malformed++;
    else if (uuid) seen.add(uuid);
  }

  function pushLine(line: string): AguiEvent[] {
    if (!line.trim()) return [];
    stats.lines++;
    let rec: unknown;
    try {
      rec = JSON.parse(line);
    } catch {
      stats.malformed++;
      return [];
    }
    if (!isObject(rec)) {
      stats.malformed++;
      return [];
    }
    const out: AguiEvent[] = [];
    mapRecord(rec, out);
    stats.events += out.length;
    return out;
  }

  function pushChunk(chunk: string): AguiEvent[] {
    const lines = (tail + chunk).split("\n");
    tail = lines.pop()!;
    return lines.flatMap(pushLine);
  }

  function flush(): AguiEvent[] {
    const rest = tail;
    tail = "";
    return pushLine(rest);
  }

  return {
    pushLine, pushChunk, flush, stats,
    get state() {
      return review ? { review: structuredClone(review) } : undefined;
    },
  };
}

export function mapJournal(text: string, opts: MapperOptions = {}): { events: AguiEvent[]; stats: MapperStats } {
  const mapper = createJournalMapper(opts);
  const events = [...mapper.pushChunk(text), ...mapper.flush()];
  return { events, stats: { ...mapper.stats } };
}

export function mapFile(path: string, opts: MapperOptions = {}): { events: AguiEvent[]; stats: MapperStats } {
  return mapJournal(readFileSync(path, "utf8"), opts);
}
