import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  appendSessionRun,
  classifyAgentOutcome,
  DESCRIPTION_MAX_CHARS,
  ledgerPath,
  normalizeEndReason,
  serializeSessionRun,
  SESSION_RUN_ROTATE_BYTES,
  subagentIdFor,
  truncateDescription,
} from "./session-run-ledger";
import { recordFromPayload, utcIso } from "./session-run-hook";

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
    v: 1, kind: "session", ev: "start", session_id: "s1", cwd: "C:\\repo",
    transcript_path: "C:\\t\\s1.jsonl", host: "OVERLORD8", started_at: NOW_ISO, pid: null,
  })).toBe('{"v":1,"kind":"session","ev":"start","session_id":"s1","cwd":"C:\\\\repo","transcript_path":"C:\\\\t\\\\s1.jsonl","host":"OVERLORD8","started_at":"2026-07-13T12:00:00Z","pid":null}');

  expect(serializeSessionRun({
    v: 1, kind: "session", ev: "end", session_id: "s1", ended_at: NOW_ISO, reason: "prompt_input_exit",
  })).toBe('{"v":1,"kind":"session","ev":"end","session_id":"s1","ended_at":"2026-07-13T12:00:00Z","reason":"prompt_input_exit"}');

  expect(serializeSessionRun({
    v: 1, kind: "subagent", ev: "start", subagent_id: "t1", parent_session_id: "s1",
    subagent_type: "Explore", description: null, started_at: NOW_ISO,
  })).toBe('{"v":1,"kind":"subagent","ev":"start","subagent_id":"t1","parent_session_id":"s1","subagent_type":"Explore","description":null,"started_at":"2026-07-13T12:00:00Z"}');

  expect(serializeSessionRun({
    v: 1, kind: "subagent", ev: "end", subagent_id: "t1", parent_session_id: "s1", ended_at: NOW_ISO, outcome: "error",
  })).toBe('{"v":1,"kind":"subagent","ev":"end","subagent_id":"t1","parent_session_id":"s1","ended_at":"2026-07-13T12:00:00Z","outcome":"error"}');
});

test("a description containing a newline stays ONE ledger line", () => {
  const line = serializeSessionRun({
    v: 1, kind: "subagent", ev: "start", subagent_id: "t1", parent_session_id: "s1",
    subagent_type: "Explore", description: "first\nsecond", started_at: NOW_ISO,
  });
  expect(line.includes("\n")).toBe(false);
  expect(JSON.parse(line).description).toBe("first\nsecond");
});

test("appendSessionRun creates the ledger dir and appends one line per row", () => {
  const path = join(tmp, "nested", "session-runs.jsonl");
  appendSessionRun({ v: 1, kind: "session", ev: "start", session_id: "s1", cwd: null, transcript_path: null, host: null, started_at: NOW_ISO, pid: null }, path);
  appendSessionRun({ v: 1, kind: "session", ev: "end", session_id: "s1", ended_at: NOW_ISO, reason: "clear" }, path);
  const lines = readFileSync(path, "utf8").trim().split("\n");
  expect(lines.length).toBe(2);
  expect(JSON.parse(lines[1]).reason).toBe("clear");
});

test("appendSessionRun rotates at the 10MB mark, same scheme as the flow-run ledger", () => {
  const path = join(tmp, "session-runs.jsonl");
  writeFileSync(path, "x".repeat(SESSION_RUN_ROTATE_BYTES));
  appendSessionRun({ v: 1, kind: "session", ev: "start", session_id: "s1", cwd: null, transcript_path: null, host: null, started_at: NOW_ISO, pid: null }, path);
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

test("SessionStart payload becomes a session start row", () => {
  const row = recordFromPayload("session-start", {
    session_id: "a1b2",
    cwd: "C:\\repo",
    transcript_path: "C:\\t\\a1b2.jsonl",
    reason: "ignored-here",
  }, NOW_ISO, "OVERLORD8");
  expect(row).toEqual({
    v: 1, kind: "session", ev: "start", session_id: "a1b2", cwd: "C:\\repo",
    transcript_path: "C:\\t\\a1b2.jsonl", host: "OVERLORD8", started_at: NOW_ISO, pid: null,
  });
});

test("SessionEnd payload becomes a session end row with a normalized reason", () => {
  expect(recordFromPayload("session-end", { session_id: "a1b2", reason: "clear" }, NOW_ISO, "OVERLORD8"))
    .toEqual({ v: 1, kind: "session", ev: "end", session_id: "a1b2", ended_at: NOW_ISO, reason: "clear" });
  expect(recordFromPayload("session-end", { session_id: "a1b2" }, NOW_ISO, null))
    .toEqual({ v: 1, kind: "session", ev: "end", session_id: "a1b2", ended_at: NOW_ISO, reason: "other" });
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
    v: 1, kind: "subagent", ev: "start", subagent_id: "toolu_01", parent_session_id: "a1b2",
    subagent_type: "Explore", description: "find the flow-exporter tests", started_at: NOW_ISO,
  });
  expect(post).toEqual({
    v: 1, kind: "subagent", ev: "end", subagent_id: "toolu_01", parent_session_id: "a1b2",
    ended_at: "2026-07-13T12:05:00Z", outcome: "success",
  });
});

test("the pair still correlates when the payload carries no native tool_use_id", () => {
  const toolInput = { subagent_type: "Explore", description: "find the tests" };
  const pre = recordFromPayload("subagent-start", { session_id: "a1b2", tool_input: toolInput }, NOW_ISO, null);
  const post = recordFromPayload("subagent-end", { session_id: "a1b2", tool_input: toolInput, tool_response: "ok" }, NOW_ISO, null);
  expect((pre as { subagent_id: string }).subagent_id).toBe((post as { subagent_id: string }).subagent_id);
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
