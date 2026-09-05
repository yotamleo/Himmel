import { spawn } from "bun";
import { join } from "node:path";
import { BASH_BIN, REPO_ROOT, killTree } from "./run";
import { SPAWN_OWN_GROUP } from "../lib/kill-tree.mjs";

export type TriageVerdict = "ignore" | "ack" | "spawn-low" | "spawn-high";
// The only model the triage seam ever injects is the spawn-low haiku override
// (HIMMEL-671). A literal type — not bare `string` — so a future verdict that
// mints a different override is a compile error at the producer, not a silent
// fall-through to the default model.
export type TriageModelOverride = "haiku";
// The models the RUN path can be pinned to. Wider than TriageModelOverride on
// purpose: triage still only ever emits "haiku", but the operator's explicit
// `model:` tag (LUNA-101) can name any of these. Keeping the two types distinct
// preserves the compile-time guarantee above at the triage producer while
// letting the run path carry an operator choice.
export type ModelOverride = "haiku" | "sonnet" | "opus";
export type TriageInvokeFn = (args: string[], prompt: string) => Promise<string>;
// fromOperator (HIMMEL-1296 CR codex-adv-1): the sender's ROLE, which selects
// the prompt framing. Defaults false — the conservative side: an unwired caller
// gets the shared-group framing, never the operator one.
export type TriageDeps = { invoke?: TriageInvokeFn; timeoutMs?: number; sessionLabel?: string; fromOperator?: boolean };

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

// HIMMEL-1296. Two things were wrong with the bare-message prompt.
//
// 1. It never said what the group IS, so a terse follow-up (`try again..`,
//    `Status?`) was indistinguishable from idle chatter.
// 2. `ack` LIES about its effect. To a classifier the token reads "send an
//    acknowledgement"; at the poller it means the same as `ignore` — silently
//    discarded, nobody ever sees it. So the model picked the label whose name
//    matched its intent and unknowingly chose the drop.
//
// Naming each verdict's consequence is what actually moves messages out of the
// drop set. Measured against the three texts the incident lost, via the live
// classifier (deepseek-v4-flash):
//
//   prompt                     try again..   …upgrraded whispper?   why didn't we got an answer
//   bare (before)              ignore        ignore                 ack
//   + channel framing only     ack           ack                    ack        ← still dropped
//   + verdict EFFECTS (this)   spawn-low     spawn-low              spawn-low  ← answered
//
// and genuine chatter (`lol nice`, `haha 😂`, `ok`) still classifies `ack`, so
// the HIMMEL-721 spam gate keeps its teeth.
//
// Deliberately stateless — no conversation history: the poller's triage gate
// runs BEFORE the enqueue precisely so it needs no session I/O.
function triagePrompt(text: string, fromOperator: boolean): string {
  return [
    "Classify this Telegram group message for whether it needs an agent spawn.",
    // ROLE-SPLIT (CR codex-adv-1). The framing was originally sent to EVERY
    // sender, which told the classifier "most traffic is the operator" even for
    // an ordinary member of a shared group — a bare group allowlist admits every
    // member. Measured chatter still classified `ack` under it, so no promotion
    // was observed, but asserting something false about the sender to widen a
    // spam gate is the wrong shape regardless: HIMMEL-721 exists to filter
    // exactly those members. The operator framing now goes only where it is true.
    ...(fromOperator
      ? ["This message is from the human operator the agent works for: it is an",
         "instruction or a question addressed to the agent, and a terse or",
         "context-free follow-up is still a request."]
      // Deliberately says "not from the operator" rather than "from another
      // member": anonymous CHANNEL posts also land here (ingest falls their
      // `from` back to sender_chat, a channel id that is never in allowFrom), and
      // a broadcast post is not a group member. Their handling is unchanged from
      // before this ticket — no exemption existed for anyone — so this is
      // accuracy, not a behaviour change. Recognising an operator posting under a
      // channel identity would need a trusted-channel policy; not in scope here.
      : ["This message is a shared-group post and is NOT from the operator.",
         "Most such traffic is ordinary chatter that needs no agent at all."]),
    // Role-NEUTRAL, and the half that actually did the work: the verdict labels
    // lie about their effect to anyone who has not been told otherwise.
    "The verdict decides what HAPPENS to the message:",
    "- ignore: silently discarded, nobody ever sees it. Group noise only.",
    "- ack: ALSO silently discarded — no acknowledgement is sent. Use it only for",
    "  messages that need no response at all.",
    "- spawn-low: answered by a small cheap model. Use for anything addressed to",
    "  the agent that is simple, terse, or a follow-up.",
    "- spawn-high: answered by the full model. Use for real work or hard questions.",
    "Answer with exactly one token: ignore, ack, spawn-low, or spawn-high.",
    "Message:",
    text,
  ].join("\n");
}

async function defaultInvoke(args: string[], prompt: string, timeoutMs: number): Promise<string> {
  // SPAWN_OWN_GROUP (HIMMEL-1956): the timeout path below calls killTree,
  // whose POSIX half signals the group -- the hermes python grandchild this
  // comment already worries about on Windows survives on POSIX without it.
  const p = spawn([...args, prompt], { ...SPAWN_OWN_GROUP, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
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
  // deepseek-v4-flash defaults to thinking mode; the Hermes invoke chokepoint
  // does not expose a thinking toggle, so this bulk classifier accepts that
  // behavior delta from legacy deepseek-chat.
  const model = process.env.TELEGRAM_TRIAGE_MODEL?.trim() || "deepseek-v4-flash";
  const provider = process.env.TELEGRAM_TRIAGE_PROVIDER?.trim() || "deepseek";
  // Absolute path: the poller's cwd is not guaranteed to be the repo root.
  // BASH_BIN, not a bare "bash" (HIMMEL-1279): under the poller's PATH a bare
  // "bash" hit the WSL System32 stub, which exits 127 on any C: path — so the
  // classifier fail-opened to spawn-high on 100% of messages, invisibly.
  const args = [BASH_BIN, join(REPO_ROOT, "scripts", "hermes", "invoke.sh"), "--model", model, "--provider", provider];
  // deps.timeoutMs (tests) wins; otherwise the env-tunable deadline.
  const timeoutMs = deps.timeoutMs ?? resolveTimeoutMs();
  const label = deps.sessionLabel ?? "unknown-session";

  try {
    const prompt = triagePrompt(text, deps.fromOperator === true);
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
