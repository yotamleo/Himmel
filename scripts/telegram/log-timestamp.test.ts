import { expect, test } from "bun:test";
import { installTimestampedLogging } from "./log-timestamp";

const ISO_PREFIX = /^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\]$/;

test("installTimestampedLogging prepends an ISO-8601 timestamp arg to log + error, preserving the original args", () => {
  const logCalls: unknown[][] = [];
  const errorCalls: unknown[][] = [];
  // A fake target, not the real console — this must not touch global state
  // (other test files share the process and would leak the wrap otherwise).
  const target = {
    log: (...args: unknown[]) => { logCalls.push(args); },
    error: (...args: unknown[]) => { errorCalls.push(args); },
  };
  installTimestampedLogging(target as unknown as Console);
  target.log("[poller] hello", 42);
  target.error("[poller] boom");

  expect(logCalls).toHaveLength(1);
  expect(String(logCalls[0][0])).toMatch(ISO_PREFIX);
  expect(logCalls[0].slice(1)).toEqual(["[poller] hello", 42]);

  expect(errorCalls).toHaveLength(1);
  expect(String(errorCalls[0][0])).toMatch(ISO_PREFIX);
  expect(errorCalls[0].slice(1)).toEqual(["[poller] boom"]);
});

test("installTimestampedLogging does not touch the real global console (opt-in target only)", () => {
  const originalLog = console.log;
  const originalError = console.error;
  const target = { log: () => {}, error: () => {} };
  installTimestampedLogging(target as unknown as Console);
  expect(console.log).toBe(originalLog);
  expect(console.error).toBe(originalError);
});
