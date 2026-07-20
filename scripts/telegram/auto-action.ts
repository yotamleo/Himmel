// Remote auto-action dispatch for the Telegram bridge (HIMMEL-424, auth model B2).
// The TRUSTED bridge parses a structured `/arm` command and invokes the privileged
// action DIRECTLY — the spawned `claude` agent is never in the trust path. This module
// owns the bridge-side concerns: the closed op allow-list, the per-op enable-list flag,
// the typed/non-forwarded eligibility guard, rc->message mapping, and the audit line.
// The privileged resolution + scheduler invocation live in auto-action.sh (it needs the
// real himmel shell env: .env, handover-path.sh, py-armor, schtasks).
import { join } from "node:path";
import { appendLine } from "./bus";
import type { Route } from "./router";

// Dispatch table — a thin marker keyed by op name. Its keys ARE the closed op
// allow-list (= KNOWN_OPS = the valid `TELEGRAM_AUTO_ACTIONS` tokens). v1 shipped one
// op (arm-resume); v2 (HIMMEL-1213) adds "merge-public" — the SHA-bound public-merge
// chokepoint, default OFF like every op here (enabling it is a `TELEGRAM_AUTO_ACTIONS`
// opt-in the operator sets explicitly; adding the op name to this table only makes it
// RECOGNIZABLE, never enabled). No per-op arg validators in the table (validation lives
// in auto-action.sh, which owns the privileged half + the real shell env).
export const OPS: Record<string, { script: string }> = {
  "arm-resume": { script: "arm-resume" },
  "merge-public": { script: "merge-public" },
};
export const KNOWN_OPS = new Set(Object.keys(OPS));

// Ops too privileged for the blanket enable-all aliases (=1/all/on/yes) to turn on:
// they require EXPLICIT naming (TELEGRAM_AUTO_ACTIONS=merge-public or ...,merge-public).
// HIMMEL-1213 codex CR round-2: `merge-public` is the SHA-bound PUBLIC squash-merge —
// an operator already running `=1`/`=all` for arm-resume must NOT silently inherit the
// public-merge capability. This preserves the ship-disabled / independent-opt-in intent
// even for enable-all users; arm-resume (and any future low-risk op) stays in the alias.
export const EXPLICIT_ONLY_OPS = new Set(["merge-public"]);

// parseEnabledOps — the per-op activation flag parser. Grammar mirrors HIMMEL_INITIATIVE
// (425) so users learn one convention. Fails toward inert (empty set): unset / falsy /
// pure-typo all yield no enabled ops. The enable-all aliases match ONLY on the whole
// value, so `all` as a comma-token is just an unknown token (does NOT enable every op);
// and the enable-all set EXCLUDES EXPLICIT_ONLY_OPS (privileged ops need explicit naming).
export function parseEnabledOps(raw: string | undefined, knownOps: Set<string>): Set<string> {
  const v = (raw ?? "").trim().toLowerCase();
  if (v === "" || v === "0" || v === "off" || v === "no" || v === "false") return new Set();
  if (v === "1" || v === "all" || v === "on" || v === "yes" || v === "true")
    return new Set([...knownOps].filter((op) => !EXPLICIT_ONLY_OPS.has(op)));
  const out = new Set<string>();
  for (const tok of v.split(",")) {
    const t = tok.trim();
    if (knownOps.has(t)) out.add(t);   // explicit naming enables ANY known op, incl. explicit-only
  }
  return out;
}

// The injection-test seam (pure). An auto-command executes ONLY when it is a typed
// (caption === false), non-forwarded (forwarded === false) auto route. Strict `=== false`
// so an unknown/undefined flag refuses rather than fail-open — this is THE security
// boundary. DM-only + op-enabled are checked by the caller (handleInbound).
export function isExecutableAutoCommand(route: Route, forwarded: boolean, caption: boolean): boolean {
  return route.kind === "auto" && forwarded === false && caption === false;
}

// auto-action.sh exit-code namespace (kept distinct from arm-resume's own rc space so
// "dedup/already-armed" doesn't collide with "resolution failed"):
//   0 armed · 1 bad input · 2 unknown op · 3 no handover / bad path · 4 ambiguous (>1) ·
//   5 already armed (arm-resume dedup) · 6 arm failed (arm-resume non-zero)
//
// merge-public (HIMMEL-1213) uses a SEPARATE, PASSED-THROUGH rc space: auto-action.sh
// relays merge-public-on-green.sh's own exit code verbatim after validating PR/SHA shape
// (bad shape -> 1, reusing arm-resume's "bad input" code — the two ops' rc spaces never
// co-occur within one invocation). See merge-public-on-green.sh's header for the full
// 0/1/10-19 namespace; mapMergePublicResult below covers the 5 operator-facing buckets
// (merged / not-green / head-moved / no-open-pr / error).
export type RunScriptResult = { code: number; stdout: string; stderr: string };
export type RunScriptFn = (op: string, arg: string, time: string) => Promise<RunScriptResult>;
export type AutoActionRoute = { op: string; arg: string; time: string };
export type AutoResult = { ok: boolean; rc: number; message: string; resolved?: string };

const firstLine = (s: string) => (s || "").split("\n").map((x) => x.trim()).find(Boolean) ?? "";
function parseResolved(stdout: string): string | undefined {
  const m = stdout.match(/^resolved=(.+)$/m);
  const v = m?.[1]?.trim();
  return v && v !== "-" ? v : undefined;
}

// rc -> operator message for merge-public. `pr`/`sha` here are route.arg/route.time
// (the Route variant reuses arm-resume's field names — see router.ts's MERGEPUB
// comment). Unlisted codes (1 bad-input, 10 wrong-repo, 11 tool-missing, 13
// pr-query-failed, 14 base-mismatch, 17 audit-unwritable, 18 merge-failed, 19
// CLAUDECODE self-refusal) all fall into the generic "error" bucket below.
function mapMergePublicResult(pr: string, sha: string, code: number, stdout: string, stderr: string): AutoResult {
  const detail = firstLine(stderr) || firstLine(stdout);
  switch (code) {
    case 0:  return { ok: true, rc: 0, message: `✅ merged PR #${pr} @ ${sha}` };
    case 12: return { ok: false, rc: 12, message: `⚠️ PR #${pr} is not open — nothing to merge` };
    case 15: return { ok: false, rc: 15, message: `⚠️ head moved — PR #${pr}'s head no longer matches ${sha}; request a fresh ready report` };
    case 16: return { ok: false, rc: 16, message: `⚠️ PR #${pr} isn't green yet (CI/CR gate not passed) — try again once it's clean` };
    default: return { ok: false, rc: code, message: `⚠️ couldn't merge PR #${pr}: ${detail || `exit ${code}`}` };
  }
}

// Re-assert the op against KNOWN_OPS (defense-in-depth vs the router parse layer), spawn
// auto-action.sh (the injected runScript spawns it argv-array in prod), then map its rc
// to an operator-facing message. arm-resume's resolved handover basename is parsed from
// stdout; merge-public has no analogous "resolved" concept.
export async function dispatchAutoAction(deps: { runScript: RunScriptFn }, route: AutoActionRoute): Promise<AutoResult> {
  if (!KNOWN_OPS.has(route.op)) return { ok: false, rc: 2, message: `⚠️ unknown op: ${route.op}` };
  const { code, stdout, stderr } = await deps.runScript(route.op, route.arg, route.time);
  if (route.op === "merge-public") return mapMergePublicResult(route.arg, route.time, code, stdout, stderr);
  const resolved = parseResolved(stdout);
  switch (code) {
    case 0:  return { ok: true, rc: 0, resolved, message: `✅ armed: ${resolved ?? route.arg} (${route.time})` };
    case 3:  return { ok: false, rc: 3, message: `⚠️ no resume handover for ${route.arg}` };
    case 4:  return { ok: false, rc: 4, message: `⚠️ ambiguous: ${firstLine(stderr)} — re-send /arm <full-path>` };
    case 5:  return { ok: false, rc: 5, message: `ℹ️ already armed for that handover — use the terminal to --force/replace` };
    default: return { ok: false, rc: code, message: `⚠️ couldn't arm ${route.arg}: ${firstLine(stderr) || `exit ${code}`}` };
  }
}

// --- Audit (one append-only line per attempt, executed OR refused) ---
// The `result=` label is computed by poller.ts's `auditResult(op, rc)`, which is
// OP-AWARE (HIMMEL-1213 codex-adv): merge-public relays merge-public-on-green.sh's
// OWN rc space, so rc=0 -> "merged" (never arm-resume's "armed") and 12/15/16 ->
// "no-open-pr"/"head-moved"/"not-green", keeping result-keyed forensic queries
// correct. The labels below are the closed union both ops draw from.
export type AuditResult = "armed" | "already-armed" | "ambiguous" | "refused-forwarded" | "no-match" | "error"
  | "merged" | "not-green" | "head-moved" | "no-open-pr";
export type AuditFields = {
  chat_id: number; user: number; forwarded: boolean; op: string;
  arg: string; resolved?: string; time: string; rc: number; result: string;
};

// Strip control chars (newlines/tabs/etc.) so a crafted arg can't forge a second audit
// line. Filters by code point (< 0x20 -> space) to avoid a control-char regex literal,
// then collapses whitespace.
function sanitize(s: string): string {
  return Array.from(s ?? "", (c) => ((c.codePointAt(0) ?? 0) < 0x20 ? " " : c))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
}

export function formatAuditLine(f: AuditFields, now: string): string {
  return [
    now,
    `chat=${f.chat_id}`,
    `user=${f.user}`,
    `fwd=${f.forwarded ? 1 : 0}`,
    `op=${sanitize(f.op)}`,
    `arg=${sanitize(f.arg)}`,
    `resolved=${sanitize(f.resolved ?? "-") || "-"}`,
    `time=${sanitize(f.time)}`,
    `rc=${f.rc}`,
    `result=${sanitize(f.result)}`,
  ].join(" ");
}

// Best-effort: an audit-write failure is logged, never thrown (it must not block the
// reply or wedge the poller) — consistent with the bridge's other best-effort sinks.
export function appendAuditLine(
  root: string,
  deps: { write?: (file: string, line: string) => Promise<void>; now?: () => string } = {},
) {
  const write = deps.write ?? appendLine;
  const now = deps.now ?? (() => new Date().toISOString());
  return async (f: AuditFields): Promise<void> => {
    try { await write(join(root, "auto-action-audit.log"), formatAuditLine(f, now())); }
    catch (e) { console.error(`[auto-action] audit write failed: ${e}`); }
  };
}
