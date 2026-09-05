// scripts/telegram/onboard.test.ts — HIMMEL-2176 Stage-1 PR-C Task 10.
// Run from the REPO ROOT: bun test scripts/telegram/onboard.test.ts --dots
import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { formatPidfile } from "./supervisor";
// BASH_BIN, never a bare "bash": on Windows the spawning process resolves it
// through PATH and can land on the WSL shim (HIMMEL-1279). Asserted by the
// bare-bash lint in scripts/hooks/run-hook-with-bash.test.mjs.
import { BASH_BIN } from "./run";
import {
  lockPathForToken, checkBridgeArmed, refusalMessage, STOP_COMMAND_POSIX,
  generateNonce, matchesNonce, extractIdentity, collectOffers, formatOffer,
  redactToken, safeGetUpdates, run, resolveTimeoutSec, resolvePowershellBin,
} from "./onboard";

// HIMMEL-2289: never hand a spawn the bare name `bash` — on Windows PATH
// resolves it to the System32 WSL launcher, which cannot read the Windows-form
// scriptPath these cross-checks pass it. Reuse the hook launcher's resolver,
// the one place that policy is tested (same shape as
// scripts/lanes/tests/lib/resolve-bash.mjs). Falling back to the bare name on
// a null resolution is correct off Windows, where the WSL-alias trap does not
// exist — but NOT on win32, where that fallback is the very System32 WSL
// launcher this resolution avoids (CR [codex-1]). There it stays empty and the
// two cross-checks below SKIP, the same shape they already use for a missing
// restart-bridge.sh: a host with no Git Bash cannot run these checks at all,
// and saying so beats a confusing WSL failure.
const BASH_BIN: string = createRequire(import.meta.url)("../hooks/run-hook-with-bash.js").resolveBash()
  || (process.platform === "win32" ? "" : "bash");

const NONCE = "onboard-test1234";

// --- V3 fixture: DM + group carry the nonce, a third chat does not ---

const dmUpdate = { update_id: 1, message: { chat: { id: 555, type: "private" }, from: { id: 555, username: "opuser" }, text: `hi ${NONCE}` } };
const groupUpdate = { update_id: 2, message: { chat: { id: -1009999, type: "supergroup", title: "Ops Room" }, from: { id: 777, first_name: "Ada" }, text: `${NONCE} here` } };
const unrelatedUpdate = { update_id: 3, message: { chat: { id: 42, type: "private" }, from: { id: 42, username: "stranger" }, text: "hello, no nonce here" } };

test("V3: matchesNonce is true only for updates whose text contains the nonce", () => {
  expect(matchesNonce(dmUpdate, NONCE)).toBe(true);
  expect(matchesNonce(groupUpdate, NONCE)).toBe(true);
  expect(matchesNonce(unrelatedUpdate, NONCE)).toBe(false);
});

test("V3: extractIdentity surfaces chat.id/chat.type/from.id/label for DM and group", () => {
  const dm = extractIdentity(dmUpdate)!;
  expect(dm).toEqual({ chatId: 555, chatType: "private", fromId: 555, label: "@opuser" });
  const grp = extractIdentity(groupUpdate)!;
  expect(grp).toEqual({ chatId: -1009999, chatType: "supergroup", fromId: 777, label: "Ops Room" });
});

test("V3: collectOffers offers the DM + group nonce matches, and drops the nonce-less third chat", () => {
  const { offers, consumed } = collectOffers([dmUpdate, groupUpdate, unrelatedUpdate], NONCE, false);
  expect(consumed).toBe(true);
  expect(offers).toHaveLength(2);
  expect(offers.map((o) => o.chatId).sort()).toEqual([-1009999, 555].sort());
  // never offered
  expect(offers.some((o) => o.chatId === 42)).toBe(false);
});

test("V3: formatOffer prints ids/type/label, not the raw message body", () => {
  const line = formatOffer(extractIdentity(dmUpdate)!);
  expect(line).toContain("chat.id=555");
  expect(line).toContain("chat.type=private");
  expect(line).toContain("from.id=555");
  expect(line).not.toContain(NONCE);   // the message text is not echoed back
});

// --- Nonce replay rejected ---

test("nonce replay: once consumed, a second batch carrying the same nonce is NOT re-offered", () => {
  const first = collectOffers([dmUpdate], NONCE, false);
  expect(first.consumed).toBe(true);
  expect(first.offers).toHaveLength(1);
  // simulate a second poll batch, same nonce text arriving again, with consumed=true carried forward
  const second = collectOffers([dmUpdate], NONCE, first.consumed);
  expect(second.offers).toHaveLength(0);
  expect(second.consumed).toBe(true);
});

// --- lockPathForToken derivation ---

function withEnv(vars: Record<string, string | undefined>, fn: () => void): void {
  const prev: Record<string, string | undefined> = {};
  for (const k of Object.keys(vars)) prev[k] = process.env[k];
  for (const [k, v] of Object.entries(vars)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  try { fn(); }
  finally { for (const [k, v] of Object.entries(prev)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } }
}

test("lockPathForToken: derives <dir>/bridge-<sha256(token)[:16]>.lock under BRIDGE_LOCK_DIR", () => {
  withEnv({ BRIDGE_LOCK_DIR: "C:/fake/lockdir", BRIDGE_ROOT: undefined }, () => {
    const p = lockPathForToken("SECRET_TOKEN_ABC");
    // sha256("SECRET_TOKEN_ABC") first 16 hex chars, computed independently below
    expect(p.replace(/\\/g, "/")).toBe("C:/fake/lockdir/bridge-" + require("node:crypto").createHash("sha256").update("SECRET_TOKEN_ABC", "utf8").digest("hex").slice(0, 16) + ".lock");
  });
});

test("lockPathForToken: falls back to BRIDGE_ROOT when BRIDGE_LOCK_DIR is unset", () => {
  withEnv({ BRIDGE_LOCK_DIR: undefined, BRIDGE_ROOT: "C:/fake/bridgeroot" }, () => {
    const p = lockPathForToken("TOK").replace(/\\/g, "/");
    expect(p.startsWith("C:/fake/bridgeroot/bridge-")).toBe(true);
    expect(p.endsWith(".lock")).toBe(true);
  });
});

// CR fix (HIMMEL-2176): `${VAR:-default}` (the shell contract restart-bridge.sh
// derives its lock path from) falls back on unset OR empty; a naive `??` only
// catches unset. A set-but-empty BRIDGE_LOCK_DIR/BRIDGE_ROOT must resolve to
// the SAME path the shell would, or the two single-consumer guards can
// disagree about which lock they're both supposed to hold.
test("lockPathForToken: empty-string BRIDGE_LOCK_DIR is treated as unset (falls through to BRIDGE_ROOT)", () => {
  withEnv({ BRIDGE_LOCK_DIR: "", BRIDGE_ROOT: "C:/fake/bridgeroot" }, () => {
    const p = lockPathForToken("TOK2").replace(/\\/g, "/");
    expect(p.startsWith("C:/fake/bridgeroot/bridge-")).toBe(true);
  });
});

test("lockPathForToken: empty-string BRIDGE_LOCK_DIR and BRIDGE_ROOT both fall through to the $HOME default", () => {
  withEnv({ BRIDGE_LOCK_DIR: "", BRIDGE_ROOT: "" }, () => {
    const p = lockPathForToken("TOK3").replace(/\\/g, "/");
    const expectedRoot = join(require("node:os").homedir(), ".claude", "handover", "bridge").replace(/\\/g, "/");
    expect(p.startsWith(expectedRoot + "/bridge-")).toBe(true);
  });
});

// --- V4: single-consumer refusal ---

test("V4: checkBridgeArmed refuses when the supervisor pidfile names a live pid", () => {
  const reason = checkBridgeArmed({
    pidfileRec: () => ({ supervisor: 111, poller: 222 }),
    isAlive: (pid) => pid === 111,
    bridgeProcessRunning: () => false,
    lockPath: "C:/nope/none.lock",
    fileExists: () => false,
  });
  expect(reason).not.toBeNull();
  expect(reason).toContain("supervisor.pid");
});

test("V4: checkBridgeArmed refuses on a detected bridge process even without a pidfile", () => {
  const reason = checkBridgeArmed({
    pidfileRec: () => null,
    isAlive: () => false,
    bridgeProcessRunning: () => true,
    lockPath: "C:/nope/none.lock",
    fileExists: () => false,
  });
  expect(reason).toContain("poller.ts / supervisor.ts");
});

test("V4: checkBridgeArmed refuses on a held launcher lockfile", () => {
  const reason = checkBridgeArmed({
    pidfileRec: () => null,
    isAlive: () => false,
    bridgeProcessRunning: () => false,
    lockPath: "C:/fake/bridge-abc.lock",
    fileExists: (p) => p === "C:/fake/bridge-abc.lock",
  });
  expect(reason).toContain("lock");
});

test("V4: checkBridgeArmed returns null (safe to start) when nothing is armed", () => {
  const reason = checkBridgeArmed({
    pidfileRec: () => null,
    isAlive: () => false,
    bridgeProcessRunning: () => false,
    lockPath: "C:/nope/none.lock",
    fileExists: () => false,
  });
  expect(reason).toBeNull();
});

test("V4: refusalMessage names the stop command", () => {
  const msg = refusalMessage("the bridge supervisor is running");
  expect(msg).toContain(STOP_COMMAND_POSIX);
  expect(msg).toContain("restart-bridge.sh stop");
  expect(msg).toContain("supervisor.ts --kill");   // the real Windows stop lever (-Kill on restart-bridge.ps1 relaunches, it doesn't stop)
});

test("V4 end-to-end: run() refuses with a real live pid in a sandboxed BRIDGE_ROOT supervisor.pid, exits non-zero, names the stop command", async () => {
  const root = mkdtempSync(join(tmpdir(), "onboard-armed-"));
  const prevRoot = process.env.BRIDGE_ROOT;
  process.env.BRIDGE_ROOT = root;
  try {
    // process.pid (this test process) is genuinely alive — a truthful "live pid"
    // fixture without touching any real bridge.
    writeFileSync(join(root, "supervisor.pid"), formatPidfile({ supervisor: process.pid, poller: null }), "utf8");
    const errors: string[] = [];
    const logs: string[] = [];
    const rc = await run({
      argv: [],
      loadToken: async () => "FAKE_TOKEN_FOR_ARMED_TEST",
      bridgeProcessRunning: () => false,
      fileExists: () => false,
      log: (s) => logs.push(s),
      error: (s) => errors.push(s),
    });
    expect(rc).not.toBe(0);
    expect(errors.join("\n")).toContain("restart-bridge.sh stop");
    expect(logs).toHaveLength(0);   // refused before ever printing a nonce
  } finally {
    if (prevRoot === undefined) delete process.env.BRIDGE_ROOT; else process.env.BRIDGE_ROOT = prevRoot;
    rmSync(root, { recursive: true, force: true });
  }
});

// --- resolveTimeoutSec: garbage ONBOARD_TIMEOUT_SEC must not silently
// disable the deadline (same shape as supervisor.ts's resolveMaxFails) ---

test("resolveTimeoutSec: blank/undefined falls back to the default, no warning", () => {
  const warnings: string[] = [];
  const warn = (s: string) => warnings.push(s);
  expect(resolveTimeoutSec(undefined, warn)).toBe(300);
  expect(resolveTimeoutSec("", warn)).toBe(300);
  expect(resolveTimeoutSec("   ", warn)).toBe(300);
  expect(warnings).toHaveLength(0);
});

test("resolveTimeoutSec: non-numeric garbage falls back to the default AND warns loudly", () => {
  const warnings: string[] = [];
  expect(resolveTimeoutSec("abc", (s) => warnings.push(s))).toBe(300);
  expect(warnings).toHaveLength(1);
  expect(warnings[0]).toContain("abc");
  expect(warnings[0]).toContain("300");
});

test("resolveTimeoutSec: non-positive values (-5, 0) fall back to the default and warn", () => {
  for (const bad of ["-5", "0"]) {
    const warnings: string[] = [];
    expect(resolveTimeoutSec(bad, (s) => warnings.push(s))).toBe(300);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain(bad);
  }
});

test("resolveTimeoutSec: a valid positive value wins, no warning", () => {
  const warnings: string[] = [];
  expect(resolveTimeoutSec("7", (s) => warnings.push(s))).toBe(7);
  expect(warnings).toHaveLength(0);
});

test("run(): a garbage ONBOARD_TIMEOUT_SEC does not disable the poll loop (regression: NaN deadline made the loop never run)", async () => {
  const root = mkdtempSync(join(tmpdir(), "onboard-badtimeout-"));
  const prevRoot = process.env.BRIDGE_ROOT;
  const prevEnvVar = process.env.ONBOARD_TIMEOUT_SEC;
  process.env.BRIDGE_ROOT = root;
  process.env.ONBOARD_TIMEOUT_SEC = "not-a-number";
  try {
    let getUpdatesCalls = 0;
    const rc = await run({
      argv: [],
      loadToken: async () => "FAKE_TOKEN_BADTIMEOUT",
      bridgeProcessRunning: () => false,
      fileExists: () => false,
      // A real fetch is never reached: getUpdates is only invoked once the
      // loop body runs at all, which is exactly what a NaN deadline used to
      // prevent. One call proves the loop executed instead of skipping.
      fetchFn: (async () => { getUpdatesCalls++; return new Response(JSON.stringify({ ok: true, result: [] })); }) as unknown as typeof fetch,
      // Advances 100s per call: call #1 sets the deadline (n=100000,
      // deadline=400000); call #2 (while-check) passes (200000<400000) so the
      // loop body runs exactly once (proving it runs AT ALL — the NaN-deadline
      // bug made it never enter); call #3 (remainingSec) and call #4 (the next
      // while-check, n=400000) then exceed the deadline, so the test
      // terminates after exactly one getUpdates call.
      now: (() => { let n = 0; return () => (n += 100_000); })(),
      log: () => {},
      error: () => {},
    });
    expect(rc).toBe(0);
    expect(getUpdatesCalls).toBeGreaterThan(0);   // the loop body actually ran
  } finally {
    if (prevRoot === undefined) delete process.env.BRIDGE_ROOT; else process.env.BRIDGE_ROOT = prevRoot;
    if (prevEnvVar === undefined) delete process.env.ONBOARD_TIMEOUT_SEC; else process.env.ONBOARD_TIMEOUT_SEC = prevEnvVar;
    rmSync(root, { recursive: true, force: true });
  }
});

// --- Timeout: clean exit, no crash, no hang ---

test("timeout: a very short override exits cleanly with a try-again message (no crash, no hang)", async () => {
  const root = mkdtempSync(join(tmpdir(), "onboard-timeout-"));
  const prevRoot = process.env.BRIDGE_ROOT;
  process.env.BRIDGE_ROOT = root;   // empty dir → no pidfile → not armed
  try {
    // A monotonically-jumping fake clock: each read advances far past any
    // reasonable deadline, so the loop's `while (now() < deadline)` resolves
    // instantly and deterministically without any real waiting.
    let t = 0;
    const now = () => (t += 10_000);
    const logs: string[] = [];
    const rc = await run({
      argv: ["--timeout", "1"],
      loadToken: async () => "FAKE_TOKEN_FOR_TIMEOUT_TEST",
      bridgeProcessRunning: () => false,
      fileExists: () => false,
      now,
      log: (s) => logs.push(s),
      error: () => {},
    });
    expect(rc).toBe(0);   // clean exit, not a crash
    expect(logs.some((l) => /timed out|try again/i.test(l))).toBe(true);
  } finally {
    if (prevRoot === undefined) delete process.env.BRIDGE_ROOT; else process.env.BRIDGE_ROOT = prevRoot;
    rmSync(root, { recursive: true, force: true });
  }
});

// --- Token never leaks ---

test("redactToken strips every occurrence of the token", () => {
  const token = "123456:ABC-DEF_secret";
  const text = `GET https://api.telegram.org/bot${token}/getUpdates failed twice (bot${token} again)`;
  const out = redactToken(text, token);
  expect(out).not.toContain(token);
  expect(out).toContain("[REDACTED]");
});

test("token never leaks: a failing fetch (URL embeds the token, per the predecessor-PR defect) renders a redacted error, never the raw token", async () => {
  const token = "999888:LEAK_ME_NOT";
  const failingFetch = (async (url: string) => {
    // Models the real defect: the thrown error's message embeds the request URL,
    // which embeds the token (telegram-api.ts's API() builds .../bot<token>/...).
    throw new Error(`fetch failed for ${url}`);
  }) as unknown as typeof fetch;
  const { updates, error } = await safeGetUpdates(token, 0, 1, failingFetch);
  expect(updates).toEqual([]);
  expect(error).not.toBeNull();
  expect(error).not.toContain(token);
});

test("token never leaks across a full armed-refusal run (error output scanned for the token)", async () => {
  const root = mkdtempSync(join(tmpdir(), "onboard-leak-"));
  const prevRoot = process.env.BRIDGE_ROOT;
  process.env.BRIDGE_ROOT = root;
  try {
    writeFileSync(join(root, "supervisor.pid"), formatPidfile({ supervisor: process.pid, poller: null }), "utf8");
    const token = "777666:DO_NOT_LEAK";
    const errors: string[] = [];
    await run({
      argv: [],
      loadToken: async () => token,
      bridgeProcessRunning: () => false,
      fileExists: () => false,
      error: (s) => errors.push(s),
      log: () => {},
    });
    expect(errors.join("\n")).not.toContain(token);
  } finally {
    if (prevRoot === undefined) delete process.env.BRIDGE_ROOT; else process.env.BRIDGE_ROOT = prevRoot;
    rmSync(root, { recursive: true, force: true });
  }
});

// --- --help works without a token ---

test("--help prints usage and exits 0 WITHOUT ever calling loadToken", async () => {
  let tokenCalled = false;
  const logs: string[] = [];
  const rc = await run({
    argv: ["--help"],
    loadToken: async () => { tokenCalled = true; return "SHOULD_NOT_BE_NEEDED"; },
    log: (s) => logs.push(s),
    error: () => {},
  });
  expect(rc).toBe(0);
  expect(tokenCalled).toBe(false);
  expect(logs.join("\n")).toContain("usage:");
});

// --- Lock-path cross-check against the sibling's restart-bridge.sh ---
// This depends on a SIBLING agent's file (scripts/telegram/restart-bridge.sh,
// HIMMEL-2176 Task 9). If it hasn't landed yet, SKIP loudly (never a silent or
// fake pass) — the parent re-runs this suite once it does.

test("lock-path cross-check: restart-bridge.sh --print-lock-path agrees with lockPathForToken()", () => {
  const scriptPath = join(import.meta.dir, "restart-bridge.sh");
  if (!existsSync(scriptPath)) {
    console.warn("[onboard.test] SKIP lock-path cross-check: scripts/telegram/restart-bridge.sh does not exist yet (sibling HIMMEL-2176 Task 9 not landed) — re-run this suite once it lands.");
    return;
  }
  if (!BASH_BIN) {
    console.warn("[onboard.test] SKIP lock-path cross-check: no usable Git Bash on this Windows host (a bare `bash` here is the System32 WSL launcher, which cannot read the Windows-form scriptPath) — install Git for Windows to run this check.");
    return;
  }
  const lockDir = mkdtempSync(join(tmpdir(), "onboard-lockdir-"));
  const token = "CROSSCHECK_TOKEN_ABC123";
  try {
    const proc = Bun.spawnSync([BASH_BIN, scriptPath, "--print-lock-path"], {
      env: { ...process.env, TELEGRAM_BOT_TOKEN: token, BRIDGE_LOCK_DIR: lockDir },
      stdout: "pipe", stderr: "pipe",
    });
    const printed = proc.stdout.toString().trim();
    withEnv({ BRIDGE_LOCK_DIR: lockDir, BRIDGE_ROOT: undefined }, () => {
      // restart-bridge.sh is bash (POSIX forward slashes even under git-bash on
      // Windows); node:path's join() on win32 emits backslashes. Same path,
      // different separator convention — normalize both sides for comparison
      // (matches the other lockPathForToken tests above).
      expect(printed.replace(/\\/g, "/")).toBe(lockPathForToken(token).replace(/\\/g, "/"));
    });
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
});

test("lock-path cross-check: an empty BRIDGE_LOCK_DIR agrees with the shell's ${VAR:-default} fallback (restart-bridge.sh)", () => {
  const scriptPath = join(import.meta.dir, "restart-bridge.sh");
  if (!existsSync(scriptPath)) {
    console.warn("[onboard.test] SKIP empty-value lock-path cross-check: scripts/telegram/restart-bridge.sh does not exist yet (sibling HIMMEL-2176 Task 9 not landed) — re-run this suite once it lands.");
    return;
  }
  if (!BASH_BIN) {
    console.warn("[onboard.test] SKIP empty-value lock-path cross-check: no usable Git Bash on this Windows host (see the sibling cross-check above).");
    return;
  }
  const bridgeRootDir = mkdtempSync(join(tmpdir(), "onboard-lockdir-empty-"));
  const token = "CROSSCHECK_EMPTY_TOKEN";
  try {
    const proc = Bun.spawnSync([BASH_BIN, scriptPath, "--print-lock-path"], {
      env: { ...process.env, TELEGRAM_BOT_TOKEN: token, BRIDGE_LOCK_DIR: "", BRIDGE_ROOT: bridgeRootDir },
      stdout: "pipe", stderr: "pipe",
    });
    const printed = proc.stdout.toString().trim();
    withEnv({ BRIDGE_LOCK_DIR: "", BRIDGE_ROOT: bridgeRootDir }, () => {
      expect(printed.replace(/\\/g, "/")).toBe(lockPathForToken(token).replace(/\\/g, "/"));
    });
  } finally {
    rmSync(bridgeRootDir, { recursive: true, force: true });
  }
});

// --- PowerShell resolution (CR fix, HIMMEL-2176): the win32 armed-check must
// prefer pwsh over powershell, same order as
// scripts/himmelctl/lib/helpers.js's resolvePowershell() (HIMMEL-2126) — a
// host with ONLY pwsh installed must not silently fail-open the check. ---

test("resolvePowershellBin: prefers pwsh when only pwsh resolves on PATH", () => {
  expect(resolvePowershellBin((bin) => bin === "pwsh")).toBe("pwsh");
});

test("resolvePowershellBin: falls back to powershell when pwsh does not resolve", () => {
  expect(resolvePowershellBin(() => false)).toBe("powershell");
});

// --- Error backoff (CR fix, HIMMEL-2176): a persistently failing getUpdates
// must not spin the loop at max rate for the whole timeout window. ---

test("run(): a persistently erroring getUpdates backs off instead of spinning, and still exits cleanly at the deadline", async () => {
  const root = mkdtempSync(join(tmpdir(), "onboard-errbackoff-"));
  const prevRoot = process.env.BRIDGE_ROOT;
  process.env.BRIDGE_ROOT = root;   // empty dir → no pidfile → not armed
  try {
    let t = 0;
    // `sleep` advances the simulated clock by exactly the backoff duration
    // instead of actually waiting — this is what makes "bounded attempts in
    // a fixed window" observable without a real multi-second test: without a
    // backoff sleep, `now()` never advances and the loop would spin forever
    // (the test would time out instead of passing).
    const now = () => t;
    const sleep = async (ms: number) => { t += ms; };
    let getUpdatesCalls = 0;
    const rc = await run({
      argv: ["--timeout", "10"],   // 10s simulated window
      loadToken: async () => "FAKE_TOKEN_FOR_BACKOFF_TEST",
      bridgeProcessRunning: () => false,
      fileExists: () => false,
      fetchFn: (async () => { getUpdatesCalls++; throw new Error("boom: transport failure"); }) as unknown as typeof fetch,
      now,
      sleep,
      log: () => {},
      error: () => {},
    });
    expect(rc).toBe(0);   // clean exit at the deadline, not a crash/hang
    expect(getUpdatesCalls).toBeGreaterThan(0);
    // 10s window / a multi-second backoff bounds this to a handful of
    // attempts — nowhere near "one per tick" (which would spin unboundedly).
    expect(getUpdatesCalls).toBeLessThan(20);
  } finally {
    if (prevRoot === undefined) delete process.env.BRIDGE_ROOT; else process.env.BRIDGE_ROOT = prevRoot;
    rmSync(root, { recursive: true, force: true });
  }
});
