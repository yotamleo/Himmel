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
//   a bus delivery (isMeta)    → STATE_DELTA add /bus/msgs/<n>/delivered (HIMMEL-4835; <n> is the recipient's
//     sequence number, the one id the delivery text carries); mcp__himmel-bus__send and its plugin-prefixed
//     form both appear as mcp__himmel-bus__send
//   a verdict-recording Bash   → STATE_DELTA, once its result comes back without error:
//     write-verdicts.sh (its --from-file is the text an earlier successful
//     Write left at that path, as later successful Edits changed it) or
//     ledger-append.sh finding/amend rows its output confirms (HIMMEL-4655)
// A tool call's parentMessageId is the first text its API message streamed;
// a call whose message streamed no text has none.
// Agents (HIMMEL-4669): every TEXT_MESSAGE_START and TOOL_CALL_START carries
// `agent`. The session's own agent is id "main", named by the latest
// agent-name record (role from that name: -console, a leg's -N<digits>-, judge),
// its model the latest assistant message.model. A sidechain record
// (isSidechain + agentId, inline or fed from subagents/agent-<id>.jsonl) is a
// subagent's: it is bound to the Agent call whose prompt equals its first
// prompt (else to the call whose result names its agentId), taking that call's
// description, subagent_type and model. A sidechain prompt, interrupt or turn
// end is never a run boundary; a sidechain API error is a text, not RUN_ERROR.
// Failures: TOOL_CALL_RESULT.failure is "denied" (a hook or permission
// refusal), "suite" (a test run that exited non-zero), "error" (any other
// is_error), or "blocked" (a call reporting a BLOCKED marker, error or not);
// an assistant text that reports BLOCKED carries failure "blocked", and a
// subagent's API-error text failure "error". When only an Agent call's result
// names its subagent, that result carries the identity as `subagent`.
// threadId is the journal's sessionId (or the caller's), runId the prompt
// record's uuid. Agent output with no prompt before it opens an implicit run.
//
// API (consumed by the SSE endpoint and the AG-UI page):
//   createJournalMapper({threadId?, lane?}) → JournalMapper, stateful and incremental:
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
import type { AgentInfo, AgentRole, AguiEvent, Failure, JsonPatchOp } from "./events.ts";
import { commandVerdicts, extractHead, extractLedgerVerdicts, extractVerdicts, parsePanelReport, type ReviewState, type VerdictUpdate } from "./review-panel.ts";

export type MapperStats = {
  lines: number; // non-blank lines seen
  events: number; // events emitted
  ignored: number; // known records that carry no agent output (and duplicates)
  unknown: number; // well-formed records of a type this mapper does not know
  malformed: number; // unparseable lines, non-objects, or known types of the wrong shape
};

// HIMMEL-4817: `lane` stamps every RUN_STARTED with metadata { lane } (the journal's config dir says which lane wrote it).
export type MapperOptions = { threadId?: string; lane?: string };

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
// Bumped when a failure's classification changes, so an eval-runs series never mixes two meanings (HIMMEL-4670).
export const MAPPER_SCHEMA = 1;
// A refusal by a PreToolUse/permission hook, by the operator's permission prompt, or by the auto-mode classifier.
const DENIED = /^(PreToolUse|PermissionRequest):\w+ hook error|permission to use .* has been denied|doesn't want to proceed|tool use was rejected|was denied by the Claude Code auto mode classifier/i;
export const SUITE =/quiet-run\.sh suite|\bbun test\b|run-shell-tests\.sh|\btest-[\w.-]+\.sh\b|\bplaywright test\b|\bpytest\b|\bnpm (run )?test\b/;
// A status line that leads with BLOCKED: a message, or a Results bullet ("- 12:00 BLOCKED ...").
const BLOCKED = /^\s*(?:-\s+(?:\d\d:\d\d\s+)?)?BLOCKED\b/m;
// HIMMEL-4835: the bus delivery hook's header lines (every body line is `| `-prefixed, so none can forge one) and
// the two names the send tool goes by (bare, and the plugin-prefixed form).
const BUS_HEADER = /^bus #(\d+) (?:data )?from /gm;
const BUS_SEND = /^mcp__(?:plugin_himmel-bus_)?himmel-bus__send$/;
const busDeliveries = (text: string) => [...text.matchAll(BUS_HEADER)].map((m) => Number(m[1]));

// HIMMEL-4655: ledger-append.sh says so when it has written a verdict (an amend, or a finding's verdict appended as
// one); a fresh finding row prints nothing, so for it only a refusal line in the result says it was not written.
// ponytail: a fresh finding row in a branch that never ran still shows, have ledger-append.sh confirm every finding append if a real journal shows one
const LEDGER_CONFIRMED = /^ledger-append\.sh: (?:amended|appended verdict amend for) (\S+) at ([0-9a-f]+)/gm;
const LEDGER_REFUSED = /^ledger-append\.sh: (?!amended |appended verdict amend for )/m;

const roleOfName = (name: string): AgentRole =>
  /-console$/.test(name) ? "console" : /judge/i.test(name) ? "judge" : /(^|-)N\d+(-|$)/.test(name) ? "leg" : "agent";
const roleOfKind = (kind: string): AgentRole => (/critic|review/i.test(kind) ? "critic" : /judge/i.test(kind) ? "judge" : "subagent");

type Rec = Record<string, unknown>;
type Block = Rec & { type?: unknown };
// What a tool call does to review state once it succeeds.
type LedgerRow = VerdictUpdate & { amend: boolean };
type PendingCall = {
  name?: string;
  input?: Rec;
  verdicts: VerdictUpdate[]; // recorded by a Bash command's write-verdicts.sh run
  ledger: LedgerRow[]; // ledger-append.sh rows, applied once the result confirms them
  head?: string; // the --head a Bash command names
  write?: { path: string; text?: string }; // a Write call: its file, and the text when it holds VERDICT lines
  edit?: { path: string; old: string; next: string; all: boolean }; // an Edit call's replacement
};

const isObject = (v: unknown): v is Rec => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

function epochMs(rec: Rec): { timestamp?: number } {
  const ms = Date.parse(str(rec.timestamp) ?? "");
  return Number.isFinite(ms) ? { timestamp: ms } : {};
}

// Tool-result content is a string or an array of content parts; flatten to text.
// A prompt's text, joined as mapUser joins it (a string, or its text blocks).
function promptText(content: unknown): string | undefined {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  return content.filter((b) => isObject(b) && b.type === "text").map((b) => str((b as Rec).text) ?? "").join("\n");
}

function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => (isObject(part) && part.type === "text" ? (str(part.text) ?? "") : `[${isObject(part) ? String(part.type) : "part"}]`))
    .join("\n");
}

// The ledger rows a tool result confirms: one its output names (id, and head when the row has one), or a finding
// row when the output carries no refusal. An amend always prints its confirmation, so none means not written.
function confirmedRows(rows: LedgerRow[], text: string): VerdictUpdate[] {
  if (!rows.length) return [];
  const said = [...text.matchAll(LEDGER_CONFIRMED)];
  const refused = LEDGER_REFUSED.test(text);
  return rows
    .filter((r) => said.some(([, id, sha]) => id === r.id && (!r.head || r.head.startsWith(sha) || sha.startsWith(r.head))) || (!r.amend && !refused))
    .map(({ amend: _, ...v }) => v);
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
  let main: AgentInfo = { id: "main", name: "session", role: "agent" };
  const agents = new Map<string, AgentInfo>(); // sidechain agentId → identity
  const spawns = new Map<string, AgentInfo & { prompt?: string }>(); // Agent toolCallId → the subagent it asked for

  const clean = (a: AgentInfo & { prompt?: string }): AgentInfo =>
    Object.fromEntries(Object.entries(a).filter(([k, v]) => v !== undefined && k !== "prompt")) as AgentInfo;

  // The agent a record belongs to, learning what the record says about it.
  function agentOf(rec: Rec): AgentInfo {
    const model = isObject(rec.message) ? str(rec.message.model) : undefined;
    const known = model && model !== "<synthetic>" ? model : undefined;
    const sub = rec.isSidechain === true ? str(rec.agentId) : undefined;
    if (!sub) {
      if (known) main = { ...main, model: known };
      return clean(main);
    }
    let a = agents.get(sub);
    if (!a) {
      const prompt = rec.type === "user" && isObject(rec.message) ? promptText(rec.message.content) : undefined;
      const spawn = prompt !== undefined ? [...spawns.values()].find((x) => x.prompt === prompt && !x.id) : undefined;
      if (spawn) spawn.id = sub;
      a = spawn ? { ...spawn, id: sub } : { id: sub, name: `agent ${sub}`, role: "subagent" };
    }
    if (known) a = { ...a, model: known };
    a = clean(a);
    agents.set(sub, a);
    return a;
  }

  // An Agent call's result names the subagent it ran: bind it if its prompt did not. The identity it learns
  // rides that result as `subagent`, since the subagent may already have sent its last START.
  function bindResult(rec: Rec, toolCallId: string): AgentInfo | undefined {
    const spawn = spawns.get(toolCallId);
    if (!spawn) return undefined;
    spawns.delete(toolCallId);
    const r = isObject(rec.toolUseResult) ? rec.toolUseResult : undefined;
    const id = str(r?.agentId);
    if (!id || spawn.id) return undefined;
    const info = clean({ ...spawn, id, model: agents.get(id)?.model ?? str(r?.resolvedModel) ?? spawn.model });
    agents.set(id, info);
    return info;
  }

  function classify(call: PendingCall | undefined, isError: boolean, text: string): Failure | undefined {
    const input = call?.input ?? {};
    const command = str(input.command) ?? "";
    const reported = call?.name === "SendMessage" ? BLOCKED.test(str(input.message) ?? "")
      : call?.name === "Bash" && /append-results\.sh/.test(command) && /["'\s]BLOCKED\b/.test(command);
    if (!isError) return reported ? "blocked" : undefined;
    if (DENIED.test(text.slice(0, 2000))) return "denied"; // a refusal says so up front; never scan a huge output
    if (call?.name === "Bash" && SUITE.test(command)) return "suite";
    return reported ? "blocked" : "error";
  }

  function startRun(rec: Rec, out: AguiEvent[], id: string) {
    threadId ??= str(rec.sessionId) ?? "journal";
    runId = id;
    out.push({ type: "RUN_STARTED", threadId, runId, ...epochMs(rec), ...(opts.lane ? { metadata: { lane: opts.lane } } : {}) });
  }

  function finishRun(rec: Rec, out: AguiEvent[], outcome?: "success" | "cancelled") {
    if (runId === undefined) return;
    out.push({
      type: "RUN_FINISHED", threadId: threadId!, runId, ...epochMs(rec),
      ...(outcome ? { outcome: { type: outcome } } : {}),
    });
    runId = undefined;
  }

  // A subagent still working after its session's turn ended (a background agent) has no run to join and no
  // turn end of its own: its record gets a run of its own, closed once the record is mapped (mapRecord), and
  // RUN_STARTED names that agent so a reader can tell it from a turn.
  let sideRun = false;
  function ensureRun(rec: Rec, out: AguiEvent[]) {
    if (runId !== undefined) return;
    startRun(rec, out, str(rec.uuid) ?? `run-${stats.lines}`);
    if (rec.isSidechain === true && str(rec.agentId)) {
      sideRun = true;
      (out[out.length - 1] as { agent?: AgentInfo }).agent = agentOf(rec);
    }
  }

  function textMessage(rec: Rec, out: AguiEvent[], messageId: string, role: "user" | "assistant", text: string, failed?: "error") {
    const ts = epochMs(rec);
    const failure = failed ?? (role === "assistant" && BLOCKED.test(text) ? "blocked" as const : undefined);
    out.push({ type: "TEXT_MESSAGE_START", messageId, role, agent: agentOf(rec), ...(failure ? { failure } : {}), ...ts });
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
      const delivered = rec.isMeta === true ? busDeliveries(text) : [];
      if (delivered.length) {
        ensureRun(rec, out);
        const ts = epochMs(rec);
        if (ts.timestamp !== undefined) out.push({ type: "STATE_DELTA", delta: delivered.map((n) => ({ op: "add", path: `/bus/msgs/${n}/delivered`, value: ts.timestamp! })), ...ts });
      } else stats.ignored++;
      return true;
    }
    if (rec.isSidechain === true) { // a subagent's brief: never a run boundary
      if (INTERRUPT.test(text)) stats.ignored++;
      else {
        ensureRun(rec, out);
        textMessage(rec, out, str(rec.uuid) ?? `prompt-${stats.lines}`, "user", text);
      }
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
    const call = pending.get(toolCallId);
    const content = resultText(block.content);
    const failure = classify(call, isError, content);
    const subagent = bindResult(rec, toolCallId);
    out.push({
      type: "TOOL_CALL_RESULT", messageId: `${toolCallId}:result`, toolCallId, role: "tool",
      content, ...(isError ? { isError: true as const } : {}), ...(failure ? { failure } : {}),
      ...(subagent ? { subagent } : {}), ...epochMs(rec),
    });
    pending.delete(toolCallId);
    if (isError) return;
    if (call?.write) {
      if (call.write.text !== undefined) verdictFiles.set(call.write.path, call.write.text);
      else verdictFiles.delete(call.write.path);
    }
    if (call?.edit) followEdit(call.edit);
    const panel = parsePanelReport(resultText(block.content));
    if (panel) {
      review = { ...(call?.head ? { head: call.head } : {}), ...panel };
      out.push({ type: "STATE_SNAPSHOT", snapshot: { review: structuredClone(review) }, ...epochMs(rec) });
    }
    const verdicts = call ? [...call.verdicts, ...confirmedRows(call.ledger, content)] : [];
    if (verdicts.length && review) applyVerdicts(rec, verdicts, out);
  }

  // A successful Edit of a staged verdict file: apply its replacement to the cached text, or drop the entry when
  // the replacement cannot be followed, so a later --from-file shows nothing rather than something stale.
  function followEdit({ path, old, next, all }: NonNullable<PendingCall["edit"]>) {
    const cached = verdictFiles.get(path);
    if (cached === undefined) return;
    const text = old && cached.includes(old) ? (all ? cached.split(old).join(next) : cached.replace(old, () => next)) : undefined;
    if (text !== undefined && extractVerdicts(text).length) verdictFiles.set(path, text);
    else verdictFiles.delete(path);
  }

  function applyVerdicts(rec: Rec, verdicts: VerdictUpdate[], out: AguiEvent[]) {
    const delta: JsonPatchOp[] = [];
    const head = review!.head;
    for (const v of verdicts) {
      if (v.head && head && !head.startsWith(v.head) && !v.head.startsWith(head)) continue; // another review's row
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
  // stages the VERDICT lines a later write-verdicts.sh --from-file reads, and an
  // Edit changes what it staged. A ledger row's kind decides how it is confirmed:
  // the amend rows are what the parser finds with every finding verb masked.
  function reviewEffect(name: string, input: unknown): PendingCall {
    const args = isObject(input) ? input : {};
    const command = str(args.command);
    const call: PendingCall = { name, input: args, verdicts: [], ledger: [] };
    if (name === "Bash" && command) {
      const rows = extractLedgerVerdicts(command);
      const all = commandVerdicts(command, (path) => verdictFiles.get(path));
      const amends = new Set(extractLedgerVerdicts(command.replace(/(ledger-append\.sh["']?\s+)finding\b/g, "$1-")).map((v) => v.id));
      return {
        ...call, verdicts: all.slice(0, all.length - rows.length),
        ledger: rows.map((v) => ({ ...v, amend: amends.has(v.id) })), head: extractHead(command),
      };
    }
    const path = str(args.file_path);
    const content = str(args.content);
    if (name === "Write" && path && content !== undefined) {
      return { ...call, write: { path, ...(extractVerdicts(content).length ? { text: content } : {}) } };
    }
    const old = str(args.old_string);
    const next = str(args.new_string);
    if (name === "Edit" && path && old !== undefined && next !== undefined) {
      return { ...call, edit: { path, old, next, all: args.replace_all === true } };
    }
    return call;
  }

  function mapAssistant(rec: Rec, out: AguiEvent[]): boolean {
    const message = rec.message;
    if (!isObject(message) || !Array.isArray(message.content)) return false;
    const blocks = message.content.filter(isObject) as Block[];
    if (rec.isApiErrorMessage === true) {
      const text = blocks.map((b) => str(b.text) ?? "").join("\n") || "API error";
      if (rec.isSidechain === true) { // a subagent's failure, not the run's
        ensureRun(rec, out);
        textMessage(rec, out, str(rec.uuid) ?? `error-${stats.lines}`, "assistant", text, "error");
        return true;
      }
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
        const toolCallName = BUS_SEND.test(str(block.name)!) ? "mcp__himmel-bus__send" : str(block.name)!;
        // The text the same API message streamed before this call, if any.
        const parentMessageId = messageId ? firstText.get(messageId) : undefined;
        const ts = epochMs(rec);
        const agent = agentOf(rec);
        out.push({ type: "TOOL_CALL_START", toolCallId, toolCallName, ...(parentMessageId ? { parentMessageId } : {}), agent, ...ts });
        const input = isObject(block.input) ? block.input : {};
        if (toolCallName === "Agent" || toolCallName === "Task") {
          const kind = str(input.subagent_type) ?? "general-purpose";
          spawns.set(toolCallId, {
            id: "", name: str(input.description) ?? kind, role: roleOfKind(kind), kind,
            model: str(input.model), parentToolCallId: toolCallId, prompt: str(input.prompt),
          });
        }
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
      if (rec.subtype === "turn_duration" && rec.isSidechain !== true) finishRun(rec, out, "success");
      else stats.ignored++;
    } else if (type && SILENT_TYPES.has(type)) {
      if (type === "agent-name" && str(rec.agentName)) main = { ...main, name: str(rec.agentName)!, role: roleOfName(str(rec.agentName)!) };
      stats.ignored++;
    }
    else if (type) stats.unknown++;
    else ok = false;
    if (!ok) stats.malformed++;
    else if (uuid) seen.add(uuid);
    if (sideRun) {
      sideRun = false;
      finishRun(rec, out, "success");
    }
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
