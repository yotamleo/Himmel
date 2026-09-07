#!/usr/bin/env bun
// scripts/lanes/codex-bank-probe.ts — HIMMEL-1678
// BOUNDED one-shot probe of the codex account rate limits. Spawns
//   codex -s read-only -a untrusted app-server
// performs the stdio JSON-RPC handshake (initialize, initialized,
// account/rateLimits/read) and writes the TTL'd cache that
// scripts/lanes/bank-status.ts READS (bank-status never spawns this probe —
// a preflight that spawns `codex app-server` per call leaks a process every
// time its kill fails).
//
// FRAMING: requests go out newline-delimited (the MCP stdio shape); the
// inbound parser (codex-bank-probe-core.mjs) tolerates BOTH newline-delimited
// and Content-Length-framed replies, so a framed server still parses. If live
// testing ever shows codex requires framed REQUESTS, only the
// encodeJsonRpcLine() call sites change.
//
// GUARANTEED KILL (the failure this design exists to avoid): the spawned
// process is reaped on EVERY exit path — success, timeout, parse/handshake
// failure, SIGINT/SIGTERM, and as a process-'exit' backstop. On Windows the
// kill is `taskkill /T /F` (tree-kill: `codex app-server` supervises an MCP
// fleet — reaping only the direct child would orphan it, the exact leak
// scripts/codex/reap-mcp-fleet.sh exists to clean up); elsewhere SIGKILL on
// the direct child.
import { spawn, type ChildProcess } from "node:child_process";
import { killTree, SPAWN_OWN_GROUP } from "../lib/kill-tree.mjs";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { encodeJsonRpcLine, normalizeRateLimits, takeJsonRpcMessage } from "./codex-bank-probe-core.mjs";

const env = process.env;
const home = env.HOME ?? homedir();
const cachePath = env.CODEX_BANK_CACHE || join(home, ".himmel", "cache", "codex-bank.json");
const timeoutMs = positiveInt(env.CODEX_BANK_PROBE_TIMEOUT_MS) ?? 20_000;
// Test/ops hook: a space-split command (e.g. `node <stub path>`) replacing
// `codex`; the codex args are still appended. No spaces inside the command
// itself. Default is the real `codex` on PATH.
const [cmd, ...cmdPrefix] = (env.CODEX_BANK_PROBE_CMD || "codex").split(" ");
const args = [...cmdPrefix, "-s", "read-only", "-a", "untrusted", "app-server"];

function positiveInt(v: string | undefined): number | null {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

// HIMMEL-1835/1956: this was a private third copy of the tree-stop helper,
// carrying the same three holes -- POSIX signalled only the direct child
// (orphaning the app-server's MCP fleet), it returned early once the child had
// exited (the case where reaping descendants matters MOST), and it discarded
// taskkill's rc so a failed tree stop looked identical to a successful one.
// All three are handled in the shared helper now. The exited flag is still
// passed because on WINDOWS a recycled pid is not ours to aim a tree stop at;
// POSIX reaps the group either way.
// Reaping runs from the finally, from the SIGINT/SIGTERM handlers, AND from
// the process-'exit' backstop -- and a signal handler calls process.exit, so
// two of them ALWAYS fire (CodeRabbit, PR #1751). The second run is not a
// harmless repeat: by then the first has emptied the group, so the pid is
// released and a POSIX group signal could land on a RECYCLED pgid -- the exact
// boundary kill-tree.mjs documents. The flag is set BEFORE the stop, so a
// signal arriving mid-reap cannot re-enter either.
let reapedTree = false;
function reapProbeTree(child: ChildProcess): void {
  if (reapedTree) return;
  reapedTree = true;
  const exited = child.exitCode !== null || child.signalCode !== null;
  const r = killTree(child.pid, (sig) => { try { child.kill(sig); } catch { /* already gone */ } }, { exited });
  // Nothing here awaits the descendants, so an unreported failure would stay
  // invisible until reap-mcp-fleet.sh found the leak days later.
  if (!r.ok) process.stderr.write(`codex-bank-probe: WARNING - could not reap the app-server tree (pid ${child.pid}): ${r.detail}\n`);
}

async function main(): Promise<void> {
  // SPAWN_OWN_GROUP (HIMMEL-1956): `codex app-server` supervises an MCP fleet,
  // and the group has to exist at spawn time for the reap below to reach it.
  const child = spawn(cmd, args, { ...SPAWN_OWN_GROUP, stdio: ["pipe", "pipe", "ignore"], windowsHide: true });
  // stdin EPIPE (child died first) must not crash the probe — the exit
  // watcher below is the signal that matters.
  child.stdin!.on("error", () => {});

  for (const sig of ["SIGINT", "SIGTERM"] as const) {
    process.on(sig, () => {
      reapProbeTree(child);
      process.exit(sig === "SIGINT" ? 130 : 143);
    });
  }
  // Backstop for any exotic exit path that bypasses the finally below.
  process.on("exit", () => reapProbeTree(child));

  let buffer = Buffer.alloc(0);
  const responders = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  child.stdout!.on("data", (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const taken = takeJsonRpcMessage(buffer);
      if (!taken) break;
      buffer = taken.rest;
      let message: unknown;
      try { message = JSON.parse(taken.text); } catch { continue; }
      if (!message || typeof message !== "object" || !("id" in message)) continue; // notifications/logs: ignored
      const id = (message as { id?: unknown }).id;
      if (typeof id !== "number") continue;
      const waiter = responders.get(id);
      if (!waiter) continue;
      responders.delete(id);
      if ("error" in message) waiter.reject(new Error(`JSON-RPC error: ${JSON.stringify((message as { error?: unknown }).error)}`));
      else waiter.resolve((message as { result?: unknown }).result);
    }
  });

  // Each of these rejects at most once while awaited; the .catch marks the
  // promise handled so a LATE rejection (child exiting after success, the
  // deadline firing after the finally) cannot become an unhandledRejection.
  const childFailed = (async () => {
    try {
      await new Promise<never>((_, reject) => child.on("error", reject));
    } catch (error) {
      throw new Error(`failed to spawn '${cmd}': ${(error as Error).message}`);
    }
  })();
  const childExited = new Promise<never>((_, reject) => {
    child.on("exit", (code, signal) => reject(new Error(`app-server exited before answering (code=${code} signal=${signal})`)));
  });
  let cancelDeadline = (): void => {};
  const deadline = new Promise<never>((_, reject) => {
    const timer = setTimeout(() => reject(new Error(`probe timed out after ${timeoutMs}ms (no usable account/rateLimits/read response)`)), timeoutMs);
    cancelDeadline = () => clearTimeout(timer);
  });
  childFailed.catch(() => {});
  childExited.catch(() => {});
  deadline.catch(() => {});

  function request(id: number, method: string, params: unknown): Promise<unknown> {
    let settle!: { resolve: (v: unknown) => void; reject: (e: Error) => void };
    const promise = new Promise<unknown>((resolve, reject) => { settle = { resolve, reject }; });
    responders.set(id, settle);
    child.stdin!.write(encodeJsonRpcLine({ jsonrpc: "2.0", id, method, params }));
    return promise;
  }

  try {
    await Promise.race([
      request(1, "initialize", { clientInfo: { name: "himmel-codex-bank-probe", version: "1" } }),
      deadline,
      childFailed,
      childExited,
    ]);
    // Standard handshake-completion notification; servers that do not expect
    // it ignore notifications (no response is awaited).
    child.stdin!.write(encodeJsonRpcLine({ jsonrpc: "2.0", method: "initialized" }));
    const result = await Promise.race([
      request(2, "account/rateLimits/read", {}),
      deadline,
      childFailed,
      childExited,
    ]);
    const { limits, planType } = normalizeRateLimits(result);
    if (limits.length === 0) throw new Error("account/rateLimits/read carried no usable limit objects");
    const payload = { limits, planType, capturedAt: new Date().toISOString() };
    mkdirSync(dirname(cachePath), { recursive: true });
    const tmp = `${cachePath}.tmp-${process.pid}`;
    writeFileSync(tmp, `${JSON.stringify(payload, null, 2)}\n`);
    renameSync(tmp, cachePath);
    const rendered = limits
      .map((l) => `${l.limitId} ${l.usedPercent}% (window ${l.windowDurationMins}m, resets ${l.resetsAt === null ? "unknown" : new Date(l.resetsAt * 1000).toISOString()})`)
      .join("; ");
    process.stdout.write(`codex bank: plan=${planType ?? "unknown"} — ${rendered}\n`);
  } finally {
    cancelDeadline(); // else the timer holds the event loop open past success
    reapProbeTree(child); // success path included: the server would otherwise linger
    child.stdin!.end();
  }
}

try {
  await main();
} catch (error) {
  process.stderr.write(`codex-bank-probe: ${(error as Error).message}\n`);
  process.exit(1);
}
