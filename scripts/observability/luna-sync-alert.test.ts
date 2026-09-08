// scripts/observability/luna-sync-alert.test.ts
// HIMMEL-1199. Hermetic: no real git spawn, no real Telegram send, no real
// state file — checkLunaSync's git read and alert send are injected; readState/
// writeState are exercised against a tmp file only.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { checkLunaSync, buildAlertText, evaluateSweeperStatus, readState, writeState, statePath, sweeperStatusPath, DEFAULT_COOLDOWN_MS } from "./luna-sync-alert";
import type { GitDivergenceResult } from "./flow-exporter";

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "luna-sync-alert-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const NOW = Date.parse("2026-07-19T12:00:00Z");

function runner(result: GitDivergenceResult) {
  return async () => result;
}

// A fully-healthy status.json reading (LUNA-131 Task 8): fresh ts, fresh
// last_clean_ts, no backlog, no alarm. Used as the sweeperStatus fixture for
// the pre-existing (pre-LUNA-131) tests below so their git-only assertions
// are unaffected by the new sweeper dimension — a missing/red sweeper reading
// would otherwise fall through to the send path and change their outcomes.
function greenSweeperStatus(nowMs: number = NOW) {
  return {
    schema: 1,
    ts: new Date(nowMs).toISOString(),
    last_clean_ts: new Date(nowMs).toISOString(),
    head: "abc123",
    ahead_origin: 0,
    behind_origin: 0,
    consecutive_pull_skips: 0,
    consecutive_push_failures: 0,
    alarm_class: null,
    last_alarm_ts: null,
  };
}

test("rising edge: a dirty tree with no prior alert sends immediately and records state", async () => {
  const sent: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 9, uncommittedFiles: 2 }),
    state: { lastAlertedAt: null },
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
    sendAlert,
  });
  expect(withinCooldown.outcome).toBe("cooldown");
  expect(sent).toHaveLength(0);

  const pastCooldown = await checkLunaSync({
    vaultPath: "C:/vault", nowMs: NOW,
    gitRunner: runner({ unpushed: 3, uncommittedFiles: 0 }),
    state: { lastAlertedAt: new Date(NOW - DEFAULT_COOLDOWN_MS - 1).toISOString() },
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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
    sweeperStatus: greenSweeperStatus(),
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

test("sweeperStatusPath: default under HOME/.himmel/luna-sync; HIMMEL_LUNA_SWEEPER_STATUS override wins", () => {
  const norm = (p: string): string => p.replace(/\\/g, "/");
  expect(norm(sweeperStatusPath({ HOME: "/tmp/fake-home" }))).toBe("/tmp/fake-home/.himmel/luna-sync/status.json");
  expect(sweeperStatusPath({ HOME: "/tmp/fake-home", HIMMEL_LUNA_SWEEPER_STATUS: "/tmp/status.json" })).toBe("/tmp/status.json");
});

test("evaluateSweeperStatus: pure — RED reasons, YELLOW window, GREEN otherwise, reads no file", () => {
  // missing/unparseable status
  expect(evaluateSweeperStatus(null, NOW)).toEqual({ level: "red", reason: "sweeper-dead" });
  expect(evaluateSweeperStatus("not an object", NOW)).toEqual({ level: "red", reason: "sweeper-dead" });

  const fresh = greenSweeperStatus(NOW);
  expect(evaluateSweeperStatus(fresh, NOW)).toEqual({ level: "green", reason: null });

  // sweeper-dead: ts older than 30 min
  expect(evaluateSweeperStatus({ ...fresh, ts: new Date(NOW - 31 * 60 * 1000).toISOString() }, NOW))
    .toEqual({ level: "red", reason: "sweeper-dead" });

  // stale: last_clean_ts older than 60 min
  expect(evaluateSweeperStatus({ ...fresh, last_clean_ts: new Date(NOW - 61 * 60 * 1000).toISOString() }, NOW))
    .toEqual({ level: "red", reason: "stale" });

  // pull-backlog
  expect(evaluateSweeperStatus({ ...fresh, consecutive_pull_skips: 12 }, NOW))
    .toEqual({ level: "red", reason: "pull-backlog" });

  // push-blocked
  expect(evaluateSweeperStatus({ ...fresh, consecutive_push_failures: 6 }, NOW))
    .toEqual({ level: "red", reason: "push-blocked" });

  // alarm_class member
  expect(evaluateSweeperStatus({ ...fresh, alarm_class: "auth" }, NOW))
    .toEqual({ level: "red", reason: "auth" });
  expect(evaluateSweeperStatus({ ...fresh, alarm_class: "merge-conflict" }, NOW))
    .toEqual({ level: "green", reason: null }); // not a RED-class alarm

  // YELLOW: not red, last_alarm_ts within 24h
  expect(evaluateSweeperStatus({ ...fresh, last_alarm_ts: new Date(NOW - 2 * 60 * 60 * 1000).toISOString() }, NOW))
    .toEqual({ level: "yellow", reason: null });

  // GREEN: last_alarm_ts older than 24h
  expect(evaluateSweeperStatus({ ...fresh, last_alarm_ts: new Date(NOW - 25 * 60 * 60 * 1000).toISOString() }, NOW))
    .toEqual({ level: "green", reason: null });
});

// ── LUNA-131 Task 8 fixtures A1-A7 ──────────────────────────────────────────
// These exercise checkLunaSync's sweeper-status dimension end to end (not just
// evaluateSweeperStatus in isolation) — the swallow regression lives in
// checkLunaSync's control flow, not in the pure evaluator.

test("A1 green: fresh status.json, clean tree => clean, no alert", async () => {
  const sent: string[] = [];
  const { outcome } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 0, uncommittedFiles: 0 }),
    state: { lastAlertedAt: null },
    sweeperStatus: greenSweeperStatus(),
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("clean");
  expect(sent).toHaveLength(0);
});

test("A2 yellow: last_alarm_ts 2h ago, otherwise clean => NOT sent (yellow never wakes the operator alone)", async () => {
  const sent: string[] = [];
  const { outcome } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 0, uncommittedFiles: 0 }),
    state: { lastAlertedAt: null },
    sweeperStatus: { ...greenSweeperStatus(), last_alarm_ts: new Date(NOW - 2 * 60 * 60 * 1000).toISOString() },
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).not.toBe("sent");
  expect(sent).toHaveLength(0);
});

test("A3 red x5: one fixture per RED reason on an otherwise-clean tree => sent, reason in text", async () => {
  const fresh = greenSweeperStatus(NOW);
  const cases: Array<{ name: string; status: unknown; wantReason: string }> = [
    { name: "sweeper-dead", status: null, wantReason: "sweeper-dead" },
    { name: "stale", status: { ...fresh, last_clean_ts: new Date(NOW - 61 * 60 * 1000).toISOString() }, wantReason: "stale" },
    { name: "pull-backlog", status: { ...fresh, consecutive_pull_skips: 12 }, wantReason: "pull-backlog" },
    { name: "push-blocked", status: { ...fresh, consecutive_push_failures: 6 }, wantReason: "push-blocked" },
    { name: "alarm_class member", status: { ...fresh, alarm_class: "auth" }, wantReason: "auth" },
  ];

  for (const c of cases) {
    const sent: string[] = [];
    const { outcome } = await checkLunaSync({
      vaultPath: "C:/vault",
      nowMs: NOW,
      gitRunner: runner({ unpushed: 0, uncommittedFiles: 0 }),
      state: { lastAlertedAt: null },
      sweeperStatus: c.status,
      sendAlert: async (text) => { sent.push(text); return true; },
    });
    expect(outcome).toBe("sent");
    expect(sent).toHaveLength(1);
    expect(sent[0]).toContain(`sweeper: ${c.wantReason}`);
  }
});

test("A4 (the swallow regression): unpushed=0, uncommitted=0 (genuinely-clean L111) + RED sweeper => sent, no git clause", async () => {
  // This is the exact case the pre-fold design swallowed: a sweeper RED
  // arriving on a git-clean vault was returned as "clean" by the L111 early
  // return before checkLunaSync ever looked at the sweeper.
  const sent: string[] = [];
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 0, uncommittedFiles: 0 }),
    state: { lastAlertedAt: null },
    sweeperStatus: { ...greenSweeperStatus(), last_clean_ts: new Date(NOW - 61 * 60 * 1000).toISOString() }, // stale
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent).toHaveLength(1);
  expect(sent[0]).not.toContain("unpushed");
  expect(sent[0]).not.toContain("uncommitted");
  expect(sent[0]).toContain("sweeper: stale");
  expect(state.lastAlertedAt).toBe(new Date(NOW).toISOString());
});

test("A5 (reset-branch pair, no-upstream side): L100 no-upstream branch PRESERVES lastAlertedAt regardless of sweeper level", async () => {
  const prior = { lastAlertedAt: new Date(NOW - 1000).toISOString() };
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: null, uncommittedFiles: 0 }), // L100: no upstream, nothing uncommitted
    state: prior,
    sweeperStatus: greenSweeperStatus(), // not red
    sendAlert: async () => true,
  });
  expect(outcome).toBe("clean");
  expect(state.lastAlertedAt).toBe(prior.lastAlertedAt);
});

test("A6 (reset-branch pair, genuinely-clean side): L111 genuinely-clean branch with a GREEN sweeper RESETS lastAlertedAt", async () => {
  const prior = { lastAlertedAt: new Date(NOW - 1000).toISOString() };
  const { outcome, state } = await checkLunaSync({
    vaultPath: "C:/vault",
    nowMs: NOW,
    gitRunner: runner({ unpushed: 0, uncommittedFiles: 0 }), // L111: genuinely clean
    state: prior,
    sweeperStatus: greenSweeperStatus(), // GREEN
    sendAlert: async () => true,
  });
  expect(outcome).toBe("clean");
  expect(state.lastAlertedAt).toBeNull();
});

test("A7: skip-no-vault + RED sweeper => sent, with '(vault path unset)' in the text", async () => {
  const sent: string[] = [];
  const { outcome } = await checkLunaSync({
    vaultPath: undefined,
    nowMs: NOW,
    gitRunner: async () => { throw new Error("must not be called — vaultPath is falsy"); },
    state: { lastAlertedAt: null },
    sweeperStatus: null, // missing status => RED sweeper-dead
    sendAlert: async (text) => { sent.push(text); return true; },
  });
  expect(outcome).toBe("sent");
  expect(sent).toHaveLength(1);
  expect(sent[0]).toContain("(vault path unset)");
  expect(sent[0]).toContain("sweeper: sweeper-dead");
});
