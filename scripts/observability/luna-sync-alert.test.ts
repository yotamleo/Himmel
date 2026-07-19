// scripts/observability/luna-sync-alert.test.ts
// HIMMEL-1199. Hermetic: no real git spawn, no real Telegram send, no real
// state file — checkLunaSync's git read and alert send are injected; readState/
// writeState are exercised against a tmp file only.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checkLunaSync, buildAlertText, readState, writeState, statePath, DEFAULT_COOLDOWN_MS } from "./luna-sync-alert";
import type { GitDivergenceResult } from "./flow-exporter";

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "luna-sync-alert-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const NOW = Date.parse("2026-07-19T12:00:00Z");

function runner(result: GitDivergenceResult) {
  return async () => result;
}

test("rising edge: a dirty tree with no prior alert sends immediately and records state", async () => {
  const sent: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 9, uncommittedFiles: 2 }),
    state: { lastAlertedAt: null },
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent).toHaveLength(1);
  expect(sent[0]).toContain("9 unpushed commits");
  expect(sent[0]).toContain("2 uncommitted files");
  expect(state.lastAlertedAt).toBe(new Date(NOW).toISOString());
});

test("clean tree does not alert and resets any prior alert state", async () => {
  const sent: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 0, uncommittedFiles: 0 }),
    state: { lastAlertedAt: new Date(NOW - 1000).toISOString() },
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("clean");
  expect(sent).toHaveLength(0);
  expect(state.lastAlertedAt).toBeNull();
});

test("no upstream (null unpushed) is out of scope, does not alert, and PRESERVES prior alert state (does not reset the cooldown)", async () => {
  // HIMMEL-1199 CR fix: null means "no upstream configured" (not a genuinely-
  // clean 0-unpushed tree), so an in-progress alert window must survive — only
  // a real clean reading resets it. Reproduces the silent-failure mode where a
  // transient/ambiguous git read would wipe the rising-edge state.
  const sent: string[] = [];
  const prior = { lastAlertedAt: new Date(NOW - 1000).toISOString() };
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: null, uncommittedFiles: 0 }),
    state: prior,
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("clean");
  expect(sent).toHaveLength(0);
  expect(state.lastAlertedAt).toBe(prior.lastAlertedAt);
});

test("cooldown suppresses a repeat alert within the window, then re-alerts once it elapses", async () => {
  const sent: string[] = [];
  const sendAlert = async (text: string) => { sent.push(text); return true; };

  const withinCooldown = await checkLunaSync({
    vaultPath: "C:/vault", nowMs: NOW,
    gitRunner: runner({ unpushed: 3, uncommittedFiles: 0 }),
    state: { lastAlertedAt: new Date(NOW - 1000).toISOString() },
    sendAlert,
  });
  expect(withinCooldown.outcome).toBe("cooldown");
  expect(sent).toHaveLength(0);

  const pastCooldown = await checkLunaSync({
    vaultPath: "C:/vault", nowMs: NOW,
    gitRunner: runner({ unpushed: 3, uncommittedFiles: 0 }),
    state: { lastAlertedAt: new Date(NOW - DEFAULT_COOLDOWN_MS - 1).toISOString() },
    sendAlert,
  });
  expect(pastCooldown.outcome).toBe("sent");
  expect(sent).toHaveLength(1);
});

test("no vault_path skips silently without invoking the git runner", async () => {
  let called = false;
  const { outcome } = await checkLunaSync({
    vaultPath: undefined,
    nowMs: NOW,
    gitRunner: async () => { called = true; return { unpushed: 5, uncommittedFiles: 0 }; },
    state: { lastAlertedAt: null },
    sendAlert: async () => true,
    log: () => {},
  });
  expect(outcome).toBe("skip-no-vault");
  expect(called).toBe(false);
});

test("a git runner error/timeout skips without throwing and never alerts", async () => {
  const sent: string[] = [];
  const logs: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: async () => { throw new Error("git status timed out"); },
    state: { lastAlertedAt: null },
    sendAlert: async (text) => { sent.push(text); return true; },
    log: (m) => logs.push(m),
  });
  expect(outcome).toBe("skip-error");
  expect(sent).toHaveLength(0);
  expect(state.lastAlertedAt).toBeNull();
  expect(logs[0]).toContain("git status timed out");
});

test("uncommitted files with zero unpushed commits still alerts (HIMMEL-1199 CR: codex-1)", async () => {
  // The metric and alert text both cover uncommitted files, so the trigger must
  // too — a dirty-but-fully-pushed tree (e.g. auto-commit blocked) is the same
  // blocked-git-op silent failure and must not read as clean.
  const sent: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 0, uncommittedFiles: 4 }),
    state: { lastAlertedAt: null },
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent).toHaveLength(1);
  expect(sent[0]).toContain("4 uncommitted files");
  expect(sent[0]).not.toContain("unpushed");
  expect(state.lastAlertedAt).toBe(new Date(NOW).toISOString());
});

test("uncommitted files with no upstream (null unpushed) still alerts — null must not mask uncommitted", async () => {
  const sent: string[] = [];
  const { outcome } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: null, uncommittedFiles: 2 }),
    state: { lastAlertedAt: null },
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent[0]).toContain("2 uncommitted files");
});

test("an undelivered alert (no chat_id / Telegram drop) leaves state unchanged and does NOT enter cooldown (HIMMEL-1199 CR: codex-adv + coderabbit)", async () => {
  // sendAlert resolves false when nothing was actually delivered. Advancing
  // lastAlertedAt then would suppress retries for the whole cooldown window with
  // the operator never notified — the exact silent failure this checker fights.
  const logs: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 5, uncommittedFiles: 0 }),
    state: { lastAlertedAt: null },
    sendAlert: async () => false,
    log: (m) => logs.push(m),
  });
  expect(outcome).toBe("undelivered");
  expect(state.lastAlertedAt).toBeNull();
  expect(logs[0]).toContain("not delivered");

  // A prior alert window is preserved (not wiped) on an undelivered retry.
  const prior = { lastAlertedAt: new Date(NOW - DEFAULT_COOLDOWN_MS - 1).toISOString() };
  const retry = await checkLunaSync({
    vaultPath: "C:/vault", nowMs: NOW,
    gitRunner: runner({ unpushed: 5, uncommittedFiles: 0 }),
    state: prior,
    sendAlert: async () => false,
  });
  expect(retry.outcome).toBe("undelivered");
  expect(retry.state.lastAlertedAt).toBe(prior.lastAlertedAt);
});

test("buildAlertText: singular commit/file wording; zero unpushed omits the commit clause", () => {
  expect(buildAlertText(1, 0, "C:/vault")).toContain("1 unpushed commit ");
  expect(buildAlertText(1, 1, "C:/vault")).toContain("1 uncommitted file in");
  const uncommittedOnly = buildAlertText(0, 3, "C:/vault");
  expect(uncommittedOnly).toContain("3 uncommitted files in");
  expect(uncommittedOnly).not.toContain("unpushed");
});

test("statePath: default under HOME/.himmel; HIMMEL_LUNA_SYNC_ALERT_STATE override wins", () => {
  const norm = (p: string): string => p.replace(/\\/g, "/");
  expect(norm(statePath({ HOME: "/tmp/fake-home" }))).toBe("/tmp/fake-home/.himmel/luna-sync-alert-state.json");
  expect(statePath({ HOME: "/tmp/fake-home", HIMMEL_LUNA_SYNC_ALERT_STATE: "/tmp/state.json" })).toBe("/tmp/state.json");
});

test("readState/writeState round-trip through a real tmp file; missing/corrupt file reads as null", () => {
  const p = join(tmp, "state.json");
  expect(readState(p)).toEqual({ lastAlertedAt: null });

  writeState(p, { lastAlertedAt: "2026-07-19T12:00:00.000Z" });
  expect(readState(p)).toEqual({ lastAlertedAt: "2026-07-19T12:00:00.000Z" });

  writeState(p, { lastAlertedAt: null });
  expect(readState(p)).toEqual({ lastAlertedAt: null });
});
