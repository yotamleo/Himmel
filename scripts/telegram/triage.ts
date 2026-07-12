import { spawn } from "bun";
import { join } from "node:path";
import { REPO_ROOT, killTree } from "./run";

export type TriageVerdict = "ignore" | "ack" | "spawn-low" | "spawn-high";
// The only model the triage seam ever injects is the spawn-low haiku override
// (HIMMEL-671). A literal type — not bare `string` — so a future verdict that
// mints a different override is a compile error at the producer, not a silent
// fall-through to the default model.
export type TriageModelOverride = "haiku";
export type TriageInvokeFn = (args: string[], prompt: string) => Promise<string>;
export type TriageDeps = { invoke?: TriageInvokeFn; timeoutMs?: number; sessionLabel?: string };

const VERDICTS = new Set<TriageVerdict>(["ignore", "ack", "spawn-low", "spawn-high"]);
const DEFAULT_TIMEOUT_MS = 20_000;

export function parseTriageVerdict(raw: string): TriageVerdict {
  const t = raw.trim();
  return VERDICTS.has(t as TriageVerdict) ? (t as TriageVerdict) : "spawn-high";
}

// TELEGRAM_TRIAGE_TIMEOUT_MS (HIMMEL-721 CR): env-tunable classifier deadline.
// Default stays 20s. NaN / non-positive falls back to the default so a malformed
// value can never disable the timeout (a missing deadline would let a hung
// hermes child wedge the ingest loop).
function resolveTimeoutMs(): number {
  const raw = Number(process.env.TELEGRAM_TRIAGE_TIMEOUT_MS);
  return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_TIMEOUT_MS;
}

function triagePrompt(text: string): string {
  return [
    "Classify this Telegram group message for whether it needs an agent spawn.",
    "Answer with exactly one token: ignore, ack, spawn-low, or spawn-high.",
    "Message:",
    text,
  ].join("\n");
}

async function defaultInvoke(args: string[], prompt: string, timeoutMs: number): Promise<string> {
  const p = spawn([...args, prompt], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  let timedOut = false;
  return await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => {
      timedOut = true;
      // killTree (HIMMEL-246): on Windows a bare p.kill() orphans the hermes
      // python grandchild — taskkill /T /F takes the whole spawn tree.
      killTree(p.pid, (s) => p.kill(s as any));
      reject(new Error("triage timeout"));
    }, timeoutMs);

    Promise.all([
      new Response(p.stdout).text(),
      new Response(p.stderr).text(),
      p.exited,
    ]).then(([stdout, stderr, code]) => {
      if (timedOut) return;
      if (code !== 0) reject(new Error(`triage exited ${code}: ${stderr.slice(-512)}`));
      else resolve(stdout);
    }).catch(reject).finally(() => { clearTimeout(timer); });
  });
}

// Cancelable timeout for the INJECTED-invoke path (tests / a fake classifier).
// Replaces a Promise.race against Bun.sleep().then(throw): when invoke won that
// race, the sleep promise later fired its throw as an UNHANDLED REJECTION. The
// setTimeout/clearTimeout-in-finally pattern (same as defaultInvoke) clears the
// timer once invoke settles, so no late throw ever fires.
function invokeWithTimeout(invokeP: Promise<string>, timeoutMs: number): Promise<string> {
  let timedOut = false;
  return new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => { timedOut = true; reject(new Error("triage timeout")); }, timeoutMs);
    invokeP.then(
      (out) => { if (!timedOut) resolve(out); },
      (err) => { if (!timedOut) reject(err); },
    ).finally(() => { clearTimeout(timer); });
  });
}

export async function classifyForSpawn(text: string, deps: TriageDeps = {}): Promise<TriageVerdict> {
  const model = process.env.TELEGRAM_TRIAGE_MODEL?.trim() || "deepseek-chat";
  const provider = process.env.TELEGRAM_TRIAGE_PROVIDER?.trim() || "deepseek";
  // Absolute path: the poller's cwd is not guaranteed to be the repo root.
  const args = ["bash", join(REPO_ROOT, "scripts", "hermes", "invoke.sh"), "--model", model, "--provider", provider];
  // deps.timeoutMs (tests) wins; otherwise the env-tunable deadline.
  const timeoutMs = deps.timeoutMs ?? resolveTimeoutMs();
  const label = deps.sessionLabel ?? "unknown-session";

  try {
    const prompt = triagePrompt(text);
    const output = deps.invoke
      ? await invokeWithTimeout(deps.invoke(args, prompt), timeoutMs)
      : await defaultInvoke(args, prompt, timeoutMs);
    return parseTriageVerdict(output);
  } catch (e) {
    // sessionLabel (HIMMEL-721 CR): correlate the fail-open to the session so a
    // dropped-to-spawn-high chatter is traceable in the log alongside the poller state.
    console.error(`[telegram-triage] fail-open for ${label}: ${e}`);
    return "spawn-high";
  }
}
