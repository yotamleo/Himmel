import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  appendSessionRun,
  classifyAgentOutcome,
  DESCRIPTION_MAX_CHARS,
  ledgerPath,
  logSessionRunError,
  normalizeCloseEvidence,
  normalizeEndReason,
  serializeSessionRun,
  SESSION_RUN_ERROR_LOG_MAX_BYTES,
  SESSION_RUN_ROTATE_BYTES,
  SESSION_RUN_SCHEMA_VERSION,
  sessionRunErrorLogPath,
  subagentIdFor,
  truncateDescription,
} from "./session-run-ledger";
import { readTranscriptStats, recordFromPayload, recordSessionClose, utcIso } from "./session-run-hook";

let tmp: string;
beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "session-run-ledger-"));
});
afterEach(() => {
  rmSync(tmp, { recursive: true, force: true });
});

const NOW_ISO = "2026-07-13T12:00:00Z";

test("ledgerPath honours the env override, else lands beside the other himmel ledgers", () => {
  expect(ledgerPath({ HIMMEL_SESSION_RUNS_LEDGER: "/custom/session-runs.jsonl" })).toBe("/custom/session-runs.jsonl");
  expect(ledgerPath({ HIMMEL_SESSION_RUNS_LEDGER: "   ", HOME: "/home/me" })).toBe(join("/home/me", ".himmel", "session-runs.jsonl"));
});

test("serialization is a fixed field list in a fixed order (byte-stable across writers)", () => {
  expect(serializeSessionRun({
    v: 2, kind: "session", ev: "start", session_id: "s1", cwd: "C:\\repo",
    transcript_path: "C:\\t\\s1.jsonl", host: "OVERLORD8", started_at: NOW_ISO, pid: null,
    source: "startup", permission_mode: "auto",
  })).toBe('{"v":2,"kind":"session","ev":"start","session_id":"s1","cwd":"C:\\\\repo","transcript_path":"C:\\\\t\\\\s1.jsonl","host":"OVERLORD8","started_at":"2026-07-13T12:00:00Z","pid":null,"source":"startup","permission_mode":"auto"}');

  expect(serializeSessionRun({
    v: 2, kind: "session", ev: "end", session_id: "s1", ended_at: NOW_ISO, reason: "prompt_input_exit",
    permission_mode: "auto", model: "claude-fable-5", effort: "high", duration_s: 665,
    tool_calls: 18, tool_call_errors: 1,
    input_tokens: 3907, output_tokens: 15428, cache_read_tokens: 3003241, context_tokens: 109503,
  })).toBe('{"v":2,"kind":"session","ev":"end","session_id":"s1","ended_at":"2026-07-13T12:00:00Z","reason":"prompt_input_exit","permission_mode":"auto","model":"claude-fable-5","effort":"high","duration_s":665,"tool_calls":18,"tool_call_errors":1,"input_tokens":3907,"output_tokens":15428,"cache_read_tokens":3003241,"context_tokens":109503}');

  expect(serializeSessionRun({
    v: 2, kind: "session", ev: "close", session_id: "s1", closed_at: NOW_ISO, evidence: "queue_lock_release",
  })).toBe('{"v":2,"kind":"session","ev":"close","session_id":"s1","closed_at":"2026-07-13T12:00:00Z","evidence":"queue_lock_release"}');

  expect(serializeSessionRun({
    v: 2, kind: "subagent", ev: "start", subagent_id: "t1", parent_session_id: "s1",
    subagent_type: "Explore", description: null, started_at: NOW_ISO,
  })).toBe('{"v":2,"kind":"subagent","ev":"start","subagent_id":"t1","parent_session_id":"s1","subagent_type":"Explore","description":null,"started_at":"2026-07-13T12:00:00Z"}');

  expect(serializeSessionRun({
    v: 2, kind: "subagent", ev: "end", subagent_id: "t1", parent_session_id: "s1", ended_at: NOW_ISO, outcome: "error",
  })).toBe('{"v":2,"kind":"subagent","ev":"end","subagent_id":"t1","parent_session_id":"s1","ended_at":"2026-07-13T12:00:00Z","outcome":"error"}');
});

test("a v2 end row with no derivable stats still lands, as nulls — never a guess", () => {
  expect(serializeSessionRun({
    v: 2, kind: "session", ev: "end", session_id: "s1", ended_at: NOW_ISO, reason: "other",
  })).toBe('{"v":2,"kind":"session","ev":"end","session_id":"s1","ended_at":"2026-07-13T12:00:00Z","reason":"other","permission_mode":null,"model":null,"effort":null,"duration_s":null,"tool_calls":null,"tool_call_errors":null,"input_tokens":null,"output_tokens":null,"cache_read_tokens":null,"context_tokens":null}');
});

test("a description containing a newline stays ONE ledger line", () => {
  const line = serializeSessionRun({
    v: 2, kind: "subagent", ev: "start", subagent_id: "t1", parent_session_id: "s1",
    subagent_type: "Explore", description: "first\nsecond", started_at: NOW_ISO,
  });
  expect(line.includes("\n")).toBe(false);
  expect(JSON.parse(line).description).toBe("first\nsecond");
});

test("appendSessionRun creates the ledger dir and appends one line per row", () => {
  const path = join(tmp, "nested", "session-runs.jsonl");
  appendSessionRun({ v: 2, kind: "session", ev: "start", session_id: "s1", cwd: null, transcript_path: null, host: null, started_at: NOW_ISO, pid: null }, path);
  appendSessionRun({ v: 2, kind: "session", ev: "end", session_id: "s1", ended_at: NOW_ISO, reason: "clear" }, path);
  const lines = readFileSync(path, "utf8").trim().split("\n");
  expect(lines.length).toBe(2);
  expect(JSON.parse(lines[1]).reason).toBe("clear");
});

test("appendSessionRun rotates at the 10MB mark, same scheme as the flow-run ledger", () => {
  const path = join(tmp, "session-runs.jsonl");
  writeFileSync(path, "x".repeat(SESSION_RUN_ROTATE_BYTES));
  appendSessionRun({ v: 2, kind: "session", ev: "start", session_id: "s1", cwd: null, transcript_path: null, host: null, started_at: NOW_ISO, pid: null }, path);
  expect(readFileSync(path + ".1", "utf8").length).toBe(SESSION_RUN_ROTATE_BYTES);
  expect(readFileSync(path, "utf8").trim().split("\n").length).toBe(1);
});

test("session end reasons are normalized into a closed enum (no unbounded label)", () => {
  expect(normalizeEndReason("prompt_input_exit")).toBe("prompt_input_exit");
  expect(normalizeEndReason(" logout ")).toBe("logout");
  expect(normalizeEndReason("something-new")).toBe("other");
  expect(normalizeEndReason(undefined)).toBe("other");
  expect(normalizeEndReason(42)).toBe("other");
});

test("close evidence is normalized into a closed enum (no unbounded label)", () => {
  expect(normalizeCloseEvidence("queue_lock_release")).toBe("queue_lock_release");
  expect(normalizeCloseEvidence(" close_sentinel ")).toBe("close_sentinel");
  expect(normalizeCloseEvidence("something-new")).toBe("other");
  expect(normalizeCloseEvidence(undefined)).toBe("other");
  expect(normalizeCloseEvidence(42)).toBe("other");
});

test("agent outcome classification never guesses success from an unreadable response", () => {
  expect(classifyAgentOutcome({ content: "done" })).toBe("success");
  expect(classifyAgentOutcome("done")).toBe("success");
  expect(classifyAgentOutcome({ is_error: true })).toBe("error");
  expect(classifyAgentOutcome({ isError: true })).toBe("error");
  expect(classifyAgentOutcome({ error: "boom" })).toBe("error");
  expect(classifyAgentOutcome(undefined)).toBe("unknown");
  expect(classifyAgentOutcome(null)).toBe("unknown");
  expect(classifyAgentOutcome("   ")).toBe("unknown");
});

test("subagent_id uses the native tool_use_id when present, and pairs deterministically without it", () => {
  const input = { subagent_type: "Explore", description: "find the tests" };
  expect(subagentIdFor("s1", input, "toolu_abc123")).toBe("toolu_abc123");
  expect(subagentIdFor("s1", input, "  ")).toBe(subagentIdFor("s1", input));
  // The fallback must pair a PRE with its POST, so it hashes only what both
  // events carry unchanged — never a timestamp POST cannot re-derive.
  expect(subagentIdFor("s1", input)).toBe(subagentIdFor("s1", { ...input }));
  expect(subagentIdFor("s1", input)).not.toBe(subagentIdFor("s2", input));
  expect(subagentIdFor("s1", input).length).toBe(12);
});

test("descriptions are bounded so a dispatch brief cannot bloat the ledger", () => {
  expect(truncateDescription("  find the tests  ")).toBe("find the tests");
  expect(truncateDescription("")).toBeNull();
  expect(truncateDescription(undefined)).toBeNull();
  expect(truncateDescription("x".repeat(500))!.length).toBe(DESCRIPTION_MAX_CHARS);
});

test("SessionStart payload becomes a v2 session start row carrying source + permission_mode", () => {
  const row = recordFromPayload("session-start", {
    session_id: "a1b2",
    cwd: "C:\\repo",
    transcript_path: "C:\\t\\a1b2.jsonl",
    source: "resume",
    permission_mode: "auto",
    reason: "ignored-here",
  }, NOW_ISO, "OVERLORD8");
  expect(row).toEqual({
    v: 2, kind: "session", ev: "start", session_id: "a1b2", cwd: "C:\\repo",
    transcript_path: "C:\\t\\a1b2.jsonl", host: "OVERLORD8", started_at: NOW_ISO, pid: null,
    source: "resume", permission_mode: "auto",
  });
});

test("SessionEnd payload becomes a session end row with a normalized reason", () => {
  const NULL_STATS = {
    permission_mode: null, model: null, effort: null, duration_s: null,
    tool_calls: null, tool_call_errors: null,
    input_tokens: null, output_tokens: null, cache_read_tokens: null, context_tokens: null,
  };
  expect(recordFromPayload("session-end", { session_id: "a1b2", reason: "clear" }, NOW_ISO, "OVERLORD8"))
    .toEqual({ v: 2, kind: "session", ev: "end", session_id: "a1b2", ended_at: NOW_ISO, reason: "clear", ...NULL_STATS });
  expect(recordFromPayload("session-end", { session_id: "a1b2" }, NOW_ISO, null))
    .toEqual({ v: 2, kind: "session", ev: "end", session_id: "a1b2", ended_at: NOW_ISO, reason: "other", ...NULL_STATS });
});

test("SessionEnd folds the transcript stats in, and prefers a payload field over a derived one", () => {
  const stats = {
    model: "claude-opus-4-8", effort: null, duration_s: 12465,
    tool_calls: 221, tool_call_errors: 8,
    input_tokens: 133351, output_tokens: 1350371, cache_read_tokens: 182136802, context_tokens: 700697,
  };
  expect(recordFromPayload("session-end", { session_id: "a1b2", reason: "logout", permission_mode: "auto" }, NOW_ISO, null, stats))
    .toMatchObject({ v: 2, model: "claude-opus-4-8", effort: null, duration_s: 12465, tool_calls: 221, tool_call_errors: 8, context_tokens: 700697, permission_mode: "auto" });
  // A payload that DOES carry the model wins over the transcript-derived one.
  expect(recordFromPayload("session-end", { session_id: "a1b2", model: "claude-fable-5", effort: "high" }, NOW_ISO, null, stats))
    .toMatchObject({ model: "claude-fable-5", effort: "high" });
});

test("subagent rows carry the same schema version (one ledger, one v)", () => {
  const row = recordFromPayload("subagent-start", {
    session_id: "a1b2", tool_use_id: "toolu_01", tool_input: { subagent_type: "Explore" },
  }, NOW_ISO, null);
  expect((row as { v: number }).v).toBe(SESSION_RUN_SCHEMA_VERSION);
});

test("the Agent PreToolUse/PostToolUse pair produces two rows sharing one subagent_id", () => {
  const toolInput = { subagent_type: "Explore", description: "find the flow-exporter tests" };
  const pre = recordFromPayload("subagent-start", {
    session_id: "a1b2", tool_name: "Agent", tool_use_id: "toolu_01", tool_input: toolInput,
  }, NOW_ISO, "OVERLORD8");
  const post = recordFromPayload("subagent-end", {
    session_id: "a1b2", tool_name: "Agent", tool_use_id: "toolu_01", tool_input: toolInput,
    tool_response: { content: "found them" },
  }, "2026-07-13T12:05:00Z", "OVERLORD8");

  expect(pre).toEqual({
    v: 2, kind: "subagent", ev: "start", subagent_id: "toolu_01", parent_session_id: "a1b2",
    subagent_type: "Explore", description: "find the flow-exporter tests", started_at: NOW_ISO,
  });
  expect(post).toEqual({
    v: 2, kind: "subagent", ev: "end", subagent_id: "toolu_01", parent_session_id: "a1b2",
    ended_at: "2026-07-13T12:05:00Z", outcome: "success",
  });
});

test("the pair still correlates when the payload carries no native tool_use_id", () => {
  const toolInput = { subagent_type: "Explore", description: "find the tests" };
  const pre = recordFromPayload("subagent-start", { session_id: "a1b2", tool_input: toolInput }, NOW_ISO, null);
  const post = recordFromPayload("subagent-end", { session_id: "a1b2", tool_input: toolInput, tool_response: "ok" }, NOW_ISO, null);
  expect((pre as { subagent_id: string }).subagent_id).toBe((post as { subagent_id: string }).subagent_id);
});

test("HIMMEL-2294: recordSessionClose reads the session id from env and the evidence from argv", () => {
  const row = recordSessionClose(
    { CLAUDE_CODE_SESSION_ID: "a1b2" },
    ["bun", "session-run-hook.ts", "session-close", "--evidence", "queue_lock_release"],
    NOW_ISO,
  );
  expect(row).toEqual({
    v: 2, kind: "session", ev: "close", session_id: "a1b2", closed_at: NOW_ISO, evidence: "queue_lock_release",
  });
});

test("recordSessionClose normalizes an unrecognized/missing evidence token to \"other\", never throws", () => {
  expect(recordSessionClose({ CLAUDE_CODE_SESSION_ID: "a1b2" }, [], NOW_ISO)).toMatchObject({ evidence: "other" });
  expect(recordSessionClose({ CLAUDE_CODE_SESSION_ID: "a1b2" }, ["--evidence", "bogus"], NOW_ISO)).toMatchObject({ evidence: "other" });
});

test("recordSessionClose produces no row when CLAUDE_CODE_SESSION_ID is absent or blank — never a fabricated one", () => {
  expect(recordSessionClose({}, ["--evidence", "queue_lock_release"], NOW_ISO)).toBeNull();
  expect(recordSessionClose({ CLAUDE_CODE_SESSION_ID: "   " }, ["--evidence", "queue_lock_release"], NOW_ISO)).toBeNull();
});

test("a payload without a session id produces no row at all (never a fabricated one)", () => {
  expect(recordFromPayload("session-start", {}, NOW_ISO, "host")).toBeNull();
  expect(recordFromPayload("subagent-end", { tool_response: "ok" }, NOW_ISO, "host")).toBeNull();
});

test("a malformed tool_input degrades to nulls rather than throwing", () => {
  const row = recordFromPayload("subagent-start", { session_id: "a1b2", tool_input: "not-an-object" }, NOW_ISO, null);
  expect(row).toMatchObject({ kind: "subagent", ev: "start", subagent_type: null, description: null });
});

test("utcIso emits the same second-resolution UTC shape the other ledgers use", () => {
  expect(utcIso(Date.parse("2026-07-13T12:00:00Z"))).toBe("2026-07-13T12:00:00Z");
});


// ---------------------------------------------------------------------------
// HIMMEL-2022: the outage, the enrichment pass, and the failure log.
// ---------------------------------------------------------------------------

const TRANSCRIPT_LINES = [
  { type: "user", timestamp: "2026-08-22T03:59:00.000Z", message: { role: "user", content: "go" } },
  {
    type: "assistant", timestamp: "2026-08-22T03:59:25.000Z", effort: "high",
    message: {
      model: "claude-fable-5",
      content: [{ type: "tool_use", id: "t1", name: "Bash" }, { type: "tool_use", id: "t2", name: "Read" }],
      usage: { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 1000, cache_creation_input_tokens: 5 },
    },
  },
  {
    type: "user", timestamp: "2026-08-22T03:59:30.000Z",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", is_error: true }, { type: "tool_result", tool_use_id: "t2" }] },
  },
  {
    type: "assistant", timestamp: "2026-08-22T04:10:30.000Z", effort: "high",
    message: {
      model: "claude-fable-5",
      content: [{ type: "text", text: "done" }],
      usage: { input_tokens: 7, output_tokens: 30, cache_read_input_tokens: 2000, cache_creation_input_tokens: 3 },
    },
  },
];

function writeTranscript(): string {
  const path = join(tmp, "transcript.jsonl");
  writeFileSync(path, TRANSCRIPT_LINES.map((l) => JSON.stringify(l)).join("\n") + "\n", "utf8");
  return path;
}

test("readTranscriptStats derives model, effort, tool counts, token sums and end-of-session context", () => {
  const stats = readTranscriptStats(writeTranscript())!;
  expect(stats.model).toBe("claude-fable-5");
  expect(stats.effort).toBe("high");
  expect(stats.tool_calls).toBe(2);
  expect(stats.tool_call_errors).toBe(1);
  // Summed across turns...
  expect(stats.input_tokens).toBe(107);
  expect(stats.output_tokens).toBe(50);
  expect(stats.cache_read_tokens).toBe(3000);
  // ...but context is the LAST turn only: 7 + 2000 + 3.
  expect(stats.context_tokens).toBe(2010);
  // First to last record this pass parses (03:59:25 -> 04:10:30).
  expect(stats.duration_s).toBe(665);
});

test("readTranscriptStats returns null rather than throwing on a transcript it cannot use", () => {
  expect(readTranscriptStats(null)).toBeNull();
  expect(readTranscriptStats(join(tmp, "does-not-exist.jsonl"))).toBeNull();
});

test("a corrupt transcript line is skipped, not fatal — the rest of the pass still counts", () => {
  const path = join(tmp, "corrupt.jsonl");
  writeFileSync(path, '{"type":"assistant" TRUNCATED\n' + JSON.stringify(TRANSCRIPT_LINES[1]) + "\n", "utf8");
  const stats = readTranscriptStats(path)!;
  expect(stats.tool_calls).toBe(2);
  expect(stats.model).toBe("claude-fable-5");
});

test("sessionRunErrorLogPath sits beside the ledger, and honours its own override", () => {
  expect(sessionRunErrorLogPath({ HIMMEL_SESSION_RUNS_LEDGER: "/x/session-runs.jsonl" }))
    .toBe("/x/session-runs.errors.log");
  expect(sessionRunErrorLogPath({ HIMMEL_SESSION_RUNS_ERROR_LOG: "/x/other.log" })).toBe("/x/other.log");
});

test("logSessionRunError writes ONE bounded line, creates its dir, and caps the file", () => {
  const path = join(tmp, "nested", "session-runs.errors.log");
  logSessionRunError("session-end", new Error("boom\nsecond line"), path);
  const lines = readFileSync(path, "utf8").trim().split("\n");
  expect(lines.length).toBe(1);
  expect(lines[0]).toContain("session-end");
  expect(lines[0]).toContain("Error: boom second line");
  expect(existsSync(dirname(path))).toBe(true);

  writeFileSync(path, "x".repeat(SESSION_RUN_ERROR_LOG_MAX_BYTES));
  logSessionRunError("session-end", new Error("dropped"), path);
  expect(readFileSync(path, "utf8").includes("dropped")).toBe(false);
});

test("logSessionRunError cannot itself throw (it is the last line of the fail-open contract)", () => {
  expect(() => logSessionRunError("session-end", new Error("x"), tmp)).not.toThrow();
});

// THE REGRESSION TEST. The outage was invisible to every unit test above:
// recordFromPayload was correct the whole time, and the ENTRYPOINT was what
// silently wrote nothing (a floating `main().catch().finally()` around
// `await Bun.stdin.text()`, which Bun 1.4.0 exits out from under). Only a real
// subprocess with real piped stdin can catch that class of bug.
async function runHook(event: string, payload: unknown, ledger: string): Promise<number> {
  const proc = Bun.spawn({
    cmd: [process.execPath, join(import.meta.dir, "session-run-hook.ts"), event],
    stdin: new TextEncoder().encode(JSON.stringify(payload)),
    stdout: "ignore",
    stderr: "ignore",
    env: { ...process.env, HIMMEL_SESSION_RUNS_LEDGER: ledger },
  });
  return await proc.exited;
}

test("the hook ENTRYPOINT actually consumes piped stdin and appends a row", async () => {
  const ledger = join(tmp, "entrypoint", "session-runs.jsonl");
  const transcript = writeTranscript();

  expect(await runHook("session-start", {
    hook_event_name: "SessionStart", session_id: "e2e-1", cwd: "C:\\repo",
    transcript_path: transcript, source: "startup", permission_mode: "auto",
  }, ledger)).toBe(0);

  expect(await runHook("session-end", {
    hook_event_name: "SessionEnd", session_id: "e2e-1",
    transcript_path: transcript, permission_mode: "auto", reason: "clear",
  }, ledger)).toBe(0);

  const lines = readFileSync(ledger, "utf8").trim().split("\n").map((l) => JSON.parse(l));
  expect(lines.length).toBe(2);
  expect(lines[0]).toMatchObject({ v: 2, kind: "session", ev: "start", session_id: "e2e-1", source: "startup", permission_mode: "auto" });
  expect(lines[1]).toMatchObject({
    v: 2, kind: "session", ev: "end", session_id: "e2e-1", reason: "clear",
    model: "claude-fable-5", effort: "high", tool_calls: 2, tool_call_errors: 1, context_tokens: 2010,
  });
});

test("the entrypoint stays fail-open on garbage stdin — exit 0, no row, one error line", async () => {
  const ledger = join(tmp, "garbage", "session-runs.jsonl");
  const proc = Bun.spawn({
    cmd: [process.execPath, join(import.meta.dir, "session-run-hook.ts"), "session-start"],
    stdin: new TextEncoder().encode("not json at all"),
    stdout: "ignore",
    stderr: "ignore",
    env: { ...process.env, HIMMEL_SESSION_RUNS_LEDGER: ledger },
  });
  expect(await proc.exited).toBe(0);
  expect(existsSync(ledger)).toBe(false);
  expect(readFileSync(join(tmp, "garbage", "session-runs.errors.log"), "utf8")).toContain("session-start");
});

// HIMMEL-2294: session-close is invoked directly (not from a piped hook
// payload), so its entrypoint test spawns with NO stdin at all and passes
// the session id via env instead.
async function runSessionClose(env: Record<string, string | undefined>, argv: string[], ledger: string): Promise<number> {
  // Delete-not-just-override: an undefined value in `env` must actually
  // REMOVE the key from the child's environment (e.g. a real
  // CLAUDE_CODE_SESSION_ID this test process happens to be running under)
  // rather than leak the parent's value through.
  const fullEnv: Record<string, string | undefined> = { ...process.env, ...env, HIMMEL_SESSION_RUNS_LEDGER: ledger };
  for (const key of Object.keys(fullEnv)) {
    if (fullEnv[key] === undefined) delete fullEnv[key];
  }
  const proc = Bun.spawn({
    cmd: [process.execPath, join(import.meta.dir, "session-run-hook.ts"), "session-close", ...argv],
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
    env: fullEnv as Record<string, string>,
  });
  return await proc.exited;
}

test("the session-close entrypoint appends a close row from env + argv, no stdin needed", async () => {
  const ledger = join(tmp, "close-entrypoint", "session-runs.jsonl");
  expect(await runSessionClose(
    { CLAUDE_CODE_SESSION_ID: "e2e-close-1" },
    ["--evidence", "queue_lock_release"],
    ledger,
  )).toBe(0);
  const row = JSON.parse(readFileSync(ledger, "utf8").trim());
  expect(row).toMatchObject({ v: 2, kind: "session", ev: "close", session_id: "e2e-close-1", evidence: "queue_lock_release" });
});

test("the session-close entrypoint writes nothing and still exits 0 when CLAUDE_CODE_SESSION_ID is unset", async () => {
  const ledger = join(tmp, "close-noop", "session-runs.jsonl");
  expect(await runSessionClose({ CLAUDE_CODE_SESSION_ID: undefined }, ["--evidence", "queue_lock_release"], ledger)).toBe(0);
  expect(existsSync(ledger)).toBe(false);
});

test("an unreadable transcript costs the enriched fields, not the row", async () => {
  const ledger = join(tmp, "degraded", "session-runs.jsonl");
  // A directory is not a transcript: readFileSync throws EISDIR.
  expect(await runHook("session-end", { session_id: "e2e-2", transcript_path: tmp, reason: "logout" }, ledger)).toBe(0);
  const row = JSON.parse(readFileSync(ledger, "utf8").trim());
  expect(row).toMatchObject({ v: 2, kind: "session", ev: "end", session_id: "e2e-2", reason: "logout", model: null, tool_calls: null });
  expect(readFileSync(join(tmp, "degraded", "session-runs.errors.log"), "utf8")).toContain("session-end");
});
