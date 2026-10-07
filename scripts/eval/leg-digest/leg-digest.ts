// leg-digest.ts — one leg session's failures as class keys (HIMMEL-4670 P1). Read-only, zero model calls.
//
//   bun scripts/eval/leg-digest/leg-digest.ts (--transcript <journal.jsonl> | --session <uuid>)
//       [--denials-ledger <classifier-denials.jsonl>] [--max-bytes N]
//
// The journal and its subagent transcripts are merged in the order the AG-UI page uses (journal-merge.ts),
// mapped by the same mapper (journal-mapper.ts), and each failure event gets a class key <failure>/<sub>
// whose <sub> comes only from closed vocabularies (spec section 2.2), never from journal text. Denied
// events of the main agent are joined by tool_call_id to `trajectory.py score --denials`, which owns the
// recovered / identical-retry rule. One digest JSON on stdout; nothing is written. Exit 2 on a usage error.
// --max-bytes is the size cap (default 200 MB); over it the digest is inconclusive.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { createJournalMapper, MAPPER_SCHEMA, SUITE } from "../../config-ui/agui/journal-mapper.ts";
import { mergeJournalFiles, sessionFiles } from "../../config-ui/agui/journal-merge.ts";
import { resolveJournal } from "../../config-ui/agui/sse.ts";
import type { AgentInfo, AguiEvent } from "../../config-ui/agui/events.ts";

const { spawnSync } = Bun;
const DIGEST_SCHEMA = 1;
const REPO = resolve(import.meta.dir, "../../..");
const TRAJECTORY = join(REPO, "scripts/eval/lane-quality/trajectory.py");
const MAX_BYTES = 200 * 1024 * 1024;
const MAX_IDS = 5;
const LEDGER_SLACK_MS = 10_000; // a ledger row joins a classifier refusal logged within this of its result

// Closed vocabularies. Anything outside them is "other".
const TOOLS = new Set(["Bash", "Edit", "Write", "Read", "Grep", "Glob", "NotebookEdit", "WebFetch", "WebSearch",
  "Agent", "Task", "TaskStop", "SendMessage", "Skill", "ToolSearch", "ListAgents", "Artifact"]);
const RUN_ERRORS = new Set(["overloaded", "rate_limit", "max_tokens", "server_error", "authentication_failed",
  "billing_error", "invalid_request"]);
const KINDS = new Set(["general-purpose", "Explore", "Plan", "claude", "console-judge", "statusline-setup",
  "claude-code-guide", "gemini-subagent", "pr-review-toolkit-himmel:code-reviewer"]);
const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const CLASSIFIER_CATEGORIES = new Set(["Out-of-Place Publication", "Merge Without Review",
  "Session Transcript Tampering", "Security Weaken"].map(slug));
const MODEL = /^(claude|gpt|gemini|glm|codex|o\d)[a-z0-9.\-[\]]{0,60}$/i;

const HOOK_PREFIX = /^(?:PreToolUse|PermissionRequest):\w+ hook error: /;
const CLASSIFIER = /denied by the Claude Code auto mode classifier/;
const BRACKET = /Reason: \[([^\]\n]{1,80})\]/;
const TEST_NAME = /[\w./-]*?((?:test-[\w.-]+\.sh)|(?:[\w.-]+\.test\.ts))\b/g;
const SCRIPT_NAME = /[\w./-]*?([\w.+-]+\.sh)\b/g;
const GREP_CMD = /(?:^|[\s;&|(])(?:grep|egrep|fgrep|rg|ugrep)\s/;
// The last stage of a pipeline whose exit status can be a grep's: the grep itself or a filter that passes it through.
const PASS_THROUGH = /^\s*(?:(?:grep|egrep|fgrep|rg|ugrep|head|tail|sort|uniq|cat)\b)/;

// HIMMEL-4793: the pipeline stages of the last command in `cmd`. Commands split on `;`, `&&`, `||` and newline,
// stages on `|`, never inside single quotes, double quotes or after a backslash, so a grep pattern like 'a|b' stays
// whole. ponytail: no `$(...)`, backticks or heredocs, a split inside one still reads as a stage boundary; revisit
// if the board shows a misclassified row.
const lastStages = (cmd: string): string[] => {
  let stages: string[] = [], last: string[] = [""], cur = "", quote = "", ws = true; // ws: the last char was unescaped whitespace or a boundary
  const endStage = () => { stages.push(cur); cur = ""; ws = true; };
  const endCommand = () => { endStage(); if (stages.some((s) => s.trim())) last = stages; stages = []; };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    const wordStart = ws;
    ws = false;
    if (quote) {
      if (c === "\\" && quote === '"') { cur += c + (cmd[++i] ?? ""); continue; }
      if (c === quote) quote = "";
      cur += c;
    } else if (c === "\\" && cmd[i + 1] === "\n") { i++; ws = wordStart; } // a line continuation joins the lines and is not a word boundary
    else if (c === "\\") cur += c + (cmd[++i] ?? "");
    else if (c === "#" && wordStart) { while (i + 1 < cmd.length && cmd[i + 1] !== "\n") i++; }
    else if (c === "'" || c === '"') { quote = c; cur += c; }
    else if (c === ";" || c === "\n") endCommand();
    else if (c === "&" && cmd[i + 1] === "&") { endCommand(); i++; }
    else if (c === "|" && cmd[i + 1] === "|") { endCommand(); i++; }
    else if (c === "|") endStage();
    else { cur += c; ws = /\s/.test(c); }
  }
  endCommand();
  return last;
};

// HIMMEL-4785: a Bash error is sub-classed by this table, first match wins. `out` tests the result text, `cmd` the
// command; `sub` is a fixed name, so no journal text reaches a class key. "usage" takes its script from SCRIPT_NAME
// and only when the basename is a tracked scripts file; an unmatched error stays error/Bash.
const BASH_ERRORS: { sub: string; out: RegExp; cmd?: RegExp }[] = [
  { sub: "zsh-nomatch", out: /\bzsh:\d+: no matches found\b/ },
  { sub: "cr-gate-exit-14", out: /^Exit code 14\b/, cmd: /clear-cr-marker\.sh/ },
  { sub: "usage", out: /\busage:|expected <base>\.\.<head>|\bunknown (?:option|argument)\b|\bcannot set\b|\bunsupported\b/i },
  { sub: "no-such-file", out: /no such file or directory/i },
];
// A grep that matched nothing exits 1 with no output: the compound's answer, not a failure (the HIMMEL-4755 audit's
// largest error/Bash bucket).
const NO_MATCH = /^Exit code 1\s*$/;
// guard-leg-context-handoff words its refusal "leg context checkpoint|hand-off (mode ...)" or "refusing
// auto-compaction", never "<hook>:", so the hook-name lookup in deniedSub cannot find it.
const CONTEXT_GUARD = /\bleg context (?:checkpoint|hand-off) \(mode |\brefusing auto-compaction: no CHECKPOINT/;

type Agent = { id: string; role: string; kind: string | null; model: string | null };
type Row = {
  session: string; agent: Agent; class: string; failure: string; count: number;
  identical_retry: number | null; recovered: boolean | null;
  first_ts: number | null; last_ts: number | null; tool_call_ids: string[]; final_red?: boolean;
};
const allIds = new WeakMap<Row, string[]>(); // every tool_call_id of a row, for the trajectory join; output keeps MAX_IDS
type Denial = { tool_call_id: string; recovered: boolean; identical: number };
type LedgerRow = { ts: number; tag: string; tool: string; used: boolean };

function usage(msg: string): never {
  console.error(`leg-digest: ${msg}`);
  process.exit(2);
}

function args(argv: string[]) {
  const o: { transcript?: string; session?: string; ledger: string; maxBytes: number } = {
    ledger: join(homedir(), ".himmel/state/classifier-denials.jsonl"), maxBytes: MAX_BYTES,
  };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i + 1];
    if (v === undefined) usage(`${argv[i]} needs a value`);
    if (argv[i] === "--transcript") o.transcript = v;
    else if (argv[i] === "--session") o.session = v;
    else if (argv[i] === "--denials-ledger") o.ledger = v;
    else if (argv[i] === "--max-bytes" && /^\d+$/.test(v)) o.maxBytes = Number(v);
    else usage(`unknown argument ${argv[i]}`);
    i++;
  }
  if (!o.transcript && !o.session) usage("--transcript or --session is required");
  return o;
}

const lines = (path: string) => { try { return readFileSync(path, "utf8").split("\n"); } catch { return []; } };

// The two vocabulary lookups return null when they fail, so the digest is partial rather than all "other".
function hookNames(): Set<string> | null {
  try { return new Set(readdirSync(join(REPO, "scripts/hooks")).filter((n) => n.endsWith(".sh")).map((n) => n.slice(0, -3))); }
  catch { return null; }
}

// spawnSync throws when the binary is not on PATH, so each spawn sits inside the try.
function trackedNames(): { tests: Set<string>; scripts: Set<string> } | null {
  try {
    const r = spawnSync(["git", "-C", REPO, "ls-files", "-z"]);
    if (!r.success) return null;
    const names = r.stdout.toString().split("\0").map((p) => basename(p));
    return {
      tests: new Set(names.filter((n) => /^test-[\w.-]+\.sh$|\.test\.ts$/.test(n))),
      scripts: new Set(names.filter((n) => /^[\w.+-]+\.sh$/.test(n))),
    };
  } catch { return null; }
}

// null when trajectory.py did not run or did not print JSON.
function trajectory(journal: string): Record<string, unknown> | null {
  try {
    const r = spawnSync(["python3", TRAJECTORY, "score", journal, "--denials"]);
    return r.success ? JSON.parse(r.stdout.toString()) : null;
  } catch { return null; }
}

function ledgerRows(path: string, session: string): LedgerRow[] {
  const out: LedgerRow[] = [];
  for (const l of lines(path)) {
    let r: Record<string, unknown>;
    try { r = JSON.parse(l); } catch { continue; }
    const ts = Date.parse(String(r?.ts ?? ""));
    if (r?.session_id === session && Number.isFinite(ts)) out.push({ ts, tag: String(r.reason_tag ?? ""), tool: String(r.tool ?? ""), used: false });
  }
  return out;
}

const agentOf = (a: AgentInfo | undefined): Agent => ({
  id: a?.id ?? "main",
  role: a?.role ?? "agent",
  kind: a?.kind === undefined ? null : KINDS.has(a.kind) ? a.kind : "other",
  model: a?.model && MODEL.test(a.model) ? a.model : null,
});

function inconclusive(session: string, reason: string) {
  return { digest_v: DIGEST_SCHEMA, mapper_v: MAPPER_SCHEMA, trajectory_v: null, session, status: "inconclusive",
    reason, model: null, metrics: {}, agents: [], failures: [], stats: {} };
}

async function main() {
  const o = args(process.argv.slice(2));
  let journal = o.transcript && resolve(o.transcript);
  if (!journal) {
    const r = await resolveJournal(homedir(), o.session!);
    if (!("path" in r)) return inconclusive(o.session!, `journal ${r.status}`);
    journal = r.path;
  }
  const session = basename(journal, ".jsonl");
  if (o.session && o.session !== session) usage("--session does not name the --transcript");
  let size: number;
  try { size = statSync(journal).size; } catch { return inconclusive(session, "no-journal"); }
  const { paths, capped } = await sessionFiles(journal);
  for (const p of paths.slice(1)) { try { size += statSync(p).size; } catch { /* gone: the merge skips it */ } }
  if (size > o.maxBytes) return inconclusive(session, "too-big");

  const mapper = createJournalMapper({ threadId: session });
  const events: AguiEvent[] = [];
  const merged = await mergeJournalFiles(paths);
  for (const l of merged.lines) events.push(...mapper.pushLine(l));
  events.push(...mapper.flush());

  const trajOut = trajectory(journal);
  const traj = trajOut ?? {};
  const denials = new Map<string, Denial>(((traj.denials as Denial[]) ?? []).map((d) => [d.tool_call_id, d]));
  const hookList = hookNames();
  const names = trackedNames();
  const lookupsFailed = [...(hookList ? [] : ["hooks"]), ...(names ? [] : ["tracked-tests"])];
  const hooks = hookList ?? new Set<string>();
  const tests = names?.tests ?? new Set<string>();
  const scripts = names?.scripts ?? new Set<string>();
  const ledger = ledgerRows(o.ledger, session);

  const agents = new Map<string, Agent>();
  const callAgent = new Map<string, Agent>();
  const callName = new Map<string, string>();
  const callArgs = new Map<string, string>();
  const rows = new Map<string, Row>();
  const suiteLast = new Map<string, { row: Row; red: boolean }>();
  const mapperDenied = new Set<string>();
  const m = { tool_calls: 0, subagents: 0, turns: 0, fail_denied: 0, fail_suite: 0, fail_blocked: 0, fail_error: 0,
    run_errors: 0, interrupts: 0, ok_no_match: 0 };
  let mainModel: string | null = null;

  const seen = (a: Agent) => {
    const prev = agents.get(a.id);
    agents.set(a.id, { ...a, kind: a.kind ?? prev?.kind ?? null, model: a.model ?? prev?.model ?? null });
    if (a.id === "main" && a.model) mainModel = a.model;
    return agents.get(a.id)!;
  };
  const add = (agent: Agent, cls: string, failure: string, id: string | undefined, ts: number | undefined): Row => {
    const key = `${agent.id}\0${cls}`;
    let r = rows.get(key);
    if (!r) {
      r = { session, agent, class: cls, failure, count: 0, identical_retry: null, recovered: null,
        first_ts: ts ?? null, last_ts: ts ?? null, tool_call_ids: [] };
      rows.set(key, r);
    }
    r.agent = agents.get(agent.id) ?? agent;
    r.count++;
    if (ts !== undefined) { r.first_ts ??= ts; r.last_ts = ts; }
    if (id && r.tool_call_ids.length < MAX_IDS) r.tool_call_ids.push(id);
    if (id) { const all = allIds.get(r) ?? []; all.push(id); allIds.set(r, all); }
    return r;
  };
  const command = (id: string): string => {
    try { const v = JSON.parse(callArgs.get(id) ?? "").command; return typeof v === "string" ? v : ""; } catch { return ""; }
  };
  const suiteSub = (cmd: string): string => {
    for (const hit of cmd.matchAll(TEST_NAME)) if (tests.has(basename(hit[1]))) return basename(hit[1]);
    return "other";
  };
  // The suite a command runs, for final_red only (never output): its first test name, else the command itself, so
  // two untracked suites that share the suite/other row are still told apart.
  const suiteKey = (agent: Agent, cmd: string): string => {
    const hit = cmd.matchAll(TEST_NAME).next().value;
    return `${agent.id}\0${hit ? basename(hit[1]) : cmd}`;
  };
  // null: not a failure (a grep that matched nothing). Else "" or ":<sub>", appended to error/Bash.
  const bashErrorSub = (cmd: string, text: string): string | null => {
    // Only the last stage of the last command can be the grep whose exit 1 this is: in `grep x f; false` or
    // `grep x f | false` the failure is `false`'s. ponytail: `false && grep x f` still reads as a no-match (the
    // grep never ran), a sequence cannot be told from `ls && grep x f` without running it; revisit if the board shows it.
    const stages = lastStages(cmd);
    if (NO_MATCH.test(text) && GREP_CMD.test(stages.join(" ")) && PASS_THROUGH.test(stages[stages.length - 1])) return null;
    for (const e of BASH_ERRORS) {
      if (!e.out.test(text) || (e.cmd && !e.cmd.test(cmd))) continue;
      if (e.sub !== "usage") return `:${e.sub}`;
      // The script the usage error is about: the only tracked one in the command, else the one its output names.
      const named = [...new Set([...cmd.matchAll(SCRIPT_NAME)].map((h) => h[1]).filter((s) => scripts.has(s)))];
      const hit = named.length === 1 ? named : named.filter((s) => text.includes(s));
      if (hit.length === 1) return `:usage:${hit[0].replace(/\.sh$/, "")}`;
    }
    return "";
  };
  const deniedSub = (text: string, ts: number | undefined, tool: string): string => {
    if (CLASSIFIER.test(text)) {
      let cat: string | undefined;
      if (ts !== undefined) {
        const row = ledger.filter((r) => !r.used && r.tool === tool && Math.abs(r.ts - ts) <= LEDGER_SLACK_MS)
          .sort((a, b) => Math.abs(a.ts - ts) - Math.abs(b.ts - ts))[0];
        if (row) { row.used = true; if (CLASSIFIER_CATEGORIES.has(slug(row.tag))) cat = slug(row.tag); }
      }
      // spec deviation (console ruling, HIMMEL-4670): the ledger's reason_tag is mostly "unknown", so fall back to the
      // journal's bracketed category, kept only when it is on the same fixed list.
      if (!cat) { const b = BRACKET.exec(text)?.[1]; if (b && CLASSIFIER_CATEGORIES.has(slug(b))) cat = slug(b); }
      return `classifier:${cat ?? "other"}`;
    }
    if (CONTEXT_GUARD.test(text.slice(0, 2000))) return "guard-leg-context-handoff";
    const pre = HOOK_PREFIX.exec(text);
    if (!pre) return "permission-prompt";
    let rest = text.slice(pre[0].length);
    if (rest.startsWith("[")) { const i = rest.indexOf("]: "); rest = i >= 0 ? rest.slice(i + 3) : ""; }
    const name = /^[^\w]*([a-z0-9][a-z0-9-]*):/.exec(rest)?.[1];
    return name && hooks.has(name) ? name : "other";
  };

  for (const e of events) {
    switch (e.type) {
      case "RUN_STARTED": m.turns++; break;
      case "RUN_FINISHED": if (e.outcome?.type === "cancelled") m.interrupts++; break;
      case "RUN_ERROR": {
        m.run_errors++;
        add(seen(agentOf(undefined)), `run_error/${e.code && RUN_ERRORS.has(e.code) ? e.code : "other"}`, "run_error", undefined, e.timestamp);
        break;
      }
      case "TEXT_MESSAGE_START": {
        const a = seen(agentOf(e.agent));
        if (e.failure === "blocked") { m.fail_blocked++; add(a, "blocked/-", "blocked", undefined, e.timestamp); }
        else if (e.failure === "error") { m.run_errors++; add(a, "run_error/other", "run_error", undefined, e.timestamp); }
        break;
      }
      case "TOOL_CALL_START": {
        m.tool_calls++;
        const a = seen(agentOf(e.agent));
        callAgent.set(e.toolCallId, a);
        callName.set(e.toolCallId, e.toolCallName);
        break;
      }
      case "TOOL_CALL_ARGS": callArgs.set(e.toolCallId, (callArgs.get(e.toolCallId) ?? "") + e.delta); break;
      case "TOOL_CALL_RESULT": {
        if (e.subagent) seen(agentOf(e.subagent));
        const a = callAgent.get(e.toolCallId) ?? seen(agentOf(undefined));
        const cmd = command(e.toolCallId);
        if (!e.failure) {
          if (SUITE.test(cmd)) { const s = suiteLast.get(suiteKey(a, cmd)); if (s) s.red = false; }
          break;
        }
        if (e.failure === "denied") {
          m.fail_denied++;
          if (a.id === "main") mapperDenied.add(e.toolCallId);
          add(a, `denied/${deniedSub(e.content, e.timestamp, callName.get(e.toolCallId) ?? "")}`, "denied", e.toolCallId, e.timestamp);
        } else if (e.failure === "suite") {
          m.fail_suite++;
          const sub = suiteSub(cmd);
          suiteLast.set(suiteKey(a, cmd), { row: add(a, `suite/${sub}`, "suite", e.toolCallId, e.timestamp), red: true });
        } else if (e.failure === "blocked") {
          m.fail_blocked++;
          add(a, "blocked/-", "blocked", e.toolCallId, e.timestamp);
        } else {
          const tool = callName.get(e.toolCallId) ?? "";
          const sub = tool === "Bash" ? bashErrorSub(cmd, e.content) : "";
          if (sub === null) { m.ok_no_match++; break; }
          m.fail_error++;
          add(a, `error/${tool.startsWith("mcp__") ? "mcp" : TOOLS.has(tool) ? tool : "other"}${sub}`, "error", e.toolCallId, e.timestamp);
        }
        break;
      }
    }
  }
  m.subagents = [...agents.keys()].filter((id) => id !== "main").length;
  for (const { row } of suiteLast.values()) row.final_red = false;
  for (const { row, red } of suiteLast.values()) if (red) row.final_red = true;

  // The trajectory join: main-agent denied rows take recovered / identical from trajectory.py by tool_call_id.
  for (const r of rows.values()) {
    if (r.failure !== "denied" || r.agent.id !== "main") continue;
    const ds = (allIds.get(r) ?? []).map((id) => denials.get(id)).filter((d): d is Denial => !!d);
    if (ds.length === 0) continue;
    r.identical_retry = ds.reduce((n, d) => n + d.identical, 0);
    r.recovered = ds.every((d) => d.recovered);
  }
  const main = agents.get("main") ?? seen(agentOf(undefined));
  const bool = (v: unknown) => (v === true ? 1 : v === false ? 0 : null);
  const failures = [...rows.values()];
  const trajRow = (cls: string, count: number) => failures.push({ session, agent: main, class: cls, failure: "traj", count,
    identical_retry: null, recovered: null, first_ts: null, last_ts: null, tool_call_ids: [] });
  if (traj.red_before_green === false) trajRow("traj/red-before-green", 1);
  if (traj.verify_before_claim === false) trajRow("traj/claim-unverified", 1);
  const idr = typeof traj.identical_denied_retries === "number" ? traj.identical_denied_retries : 0;
  if (idr >= 1) trajRow("traj/identical-retry", idr);

  const divergence = [
    ...[...mapperDenied].filter((id) => !denials.has(id)).map((id) => ({ tool_call_id: id, only: "mapper" })),
    ...[...denials.keys()].filter((id) => !mapperDenied.has(id)).map((id) => ({ tool_call_id: id, only: "trajectory" })),
  ];
  const stats = { ...mapper.stats, files: paths.length, files_skipped: merged.skipped, subagent_cap_hit: capped,
    trajectory_failed: trajOut === null, lookups_failed: lookupsFailed, denial_divergence: divergence };
  return {
    digest_v: DIGEST_SCHEMA, mapper_v: MAPPER_SCHEMA, trajectory_v: traj.trajectory_v ?? null, session,
    status: mapper.stats.malformed > 0 || capped || merged.skipped > 0 || trajOut === null || lookupsFailed.length > 0
      ? "partial" : "ok",
    model: mainModel,
    metrics: { ...m, red_before_green: bool(traj.red_before_green), denial_recovery: traj.denial_recovery ?? null,
      identical_denied_retries: traj.identical_denied_retries ?? null, verify_before_claim: bool(traj.verify_before_claim) },
    agents: [...agents.values()], failures, stats,
  };
}

console.log(JSON.stringify(await main()));
