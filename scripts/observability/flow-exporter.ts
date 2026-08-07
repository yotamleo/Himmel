// HIMMEL-922 passive Prometheus exporter over local flow/quota ledgers.
// Pure reader: no ledger writes, no process control, no enforcement.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ledgerPath as flowRunLedgerPath, type FlowRunEnd, type FlowRunRow, type FlowRunStart } from "../telegram/flow-run-ledger";
import { ledgerPath as quotaGaugeLedgerPath } from "../telegram/quota-gauge";
import {
  ledgerPath as sessionRunLedgerPath,
  SESSION_END_REASONS,
  SUBAGENT_OUTCOMES,
  type SessionEndRow,
  type SessionRunRow,
  type SessionStartRow,
  type SubagentEndRow,
  type SubagentStartRow,
} from "./session-run-ledger";
import { defaultClaudeCachePath, readClaudeBank, readCodexBank, readGlmBank, readLaneQuotaTargets, type BankId, type BankResult } from "./quota-sources";

const LOOKBACK_MS = 14 * 24 * 60 * 60 * 1000;
const DEFAULT_STALL_DEADLINE_SECONDS = 6 * 60 * 60;
// HIMMEL-1052: transcript inactivity that flips an unpaired session_start from
// `running` to `dead`. Deliberately generous — an interactive session waiting
// on the operator (mid-thought, on a permission prompt, at lunch) writes
// nothing to its transcript either, and calling that dead would be worse than
// a late crash detection. Operator-tunable via
// `observability.json` -> `sessions.stale_after_seconds`.
const DEFAULT_SESSION_STALE_AFTER_SECONDS = 15 * 60;
const CACHE_TTL_MS = 60 * 1000;
const SCHEDULER_QUERY_TIMEOUT_MS = 10 * 1000;
const HOST_DETECTOR_TIMEOUT_MS = 10 * 1000;
const GIT_QUERY_TIMEOUT_MS = 10 * 1000;
const DEFAULT_PORT = 9877;

type FlowConfig = {
  name: string;
  cadence_seconds?: number;
  stall_deadline_seconds?: number;
};

export type ObservabilityConfig = {
  flows?: FlowConfig[];
  expected_tasks?: string[];
  vault_path?: string;
  host_detectors_ttl_seconds?: number;
  quota_sources?: {
    claude_cache_path?: string;
    codex_sessions_dir?: string;
    glm_ledger_path?: string;
  };
  // HIMMEL-1129: repos whose tracked graphify-out/graph.json (HIMMEL-1123)
  // should be watched for shipped-graph staleness. Absent/empty = the family
  // is omitted entirely (opt-in, no obligation on single-station adopters).
  // default_branch (default "main") is the LOCAL ref read — see
  // readShippedGraphCommitTime's doc comment for why an explicit ref matters.
  // This is operator-edited JSON, not a value this module produces itself, so
  // consumers runtime-validate it (validateGraphifyRepos) rather than trusting
  // this static type at the JSON.parse boundary.
  graphify_repos?: Array<{ corpus: string; repo_path: string; default_branch?: string }>;
  // HIMMEL-1052: session/subagent liveness tuning. Same shape discipline as
  // flows[].stall_deadline_seconds — one number, operator-edited, validated at
  // read time rather than trusted from this static type.
  sessions?: { stale_after_seconds?: number };
};

type ScheduledTaskSample = {
  task: string;
  exists: 0 | 1;
  enabled?: 0 | 1;
  next_run_timestamp?: number | null;
};

type SchedulerRunner = (tasks: string[]) => ScheduledTaskSample[] | Promise<ScheduledTaskSample[]>;

type HostTreeSample = {
  class: string;
  rss_bytes: number;
  process_count: number;
};

type HostOrphanSample = {
  class: string;
  count: number;
};

type HostDetectorResult = {
  trees: HostTreeSample[];
  orphans: HostOrphanSample[];
};

type HostDetectorRunner = () => unknown | Promise<unknown>;

// luna_git_* (HIMMEL-1199): local-refs-only divergence read for the luna vault
// clone. `unpushed` is null when the branch has no upstream configured (@{u}
// fails) — omitted, never fabricated as 0. NO fetch anywhere in this path: a
// true "behind" count needs a fetch, which would violate the exporter's
// passivity invariant, so it is intentionally not implemented.
export type GitDivergenceResult = { unpushed: number | null; uncommittedFiles: number };
export type GitRunner = (vaultPath: string) => GitDivergenceResult | Promise<GitDivergenceResult>;

type Cached<T> = {
  key: string;
  fetchedAtMs: number;
  value: T;
};

export type ExporterCache = {
  scheduler?: Cached<{ samples: ScheduledTaskSample[]; comments: string[] }>;
  hostDetectors?: Cached<HostDetectorResult>;
  luna?: Cached<{ samples: string[] }>;
  lunaGit?: Cached<GitDivergenceResult>;
  // Keyed by repo_path (a single scrape may watch several corpora/repos).
  shippedGraphAge?: Record<string, Cached<ShippedGraphAgeResult>>;
};

export type RenderMetricsOptions = {
  env?: Record<string, string | undefined>;
  nowMs?: number;
  configPath?: string;
  flowLedgerPath?: string;
  quotaLedgerPath?: string;
  sessionLedgerPath?: string;
  lanesPath?: string;
  fetchHealthStatePath?: string;
  platform?: NodeJS.Platform;
  schedulerRunner?: SchedulerRunner;
  hostDetectorRunner?: HostDetectorRunner;
  gitRunner?: GitRunner;
  graphAgeRunner?: ShippedGraphAgeRunner;
  // Total wall-clock budget for the WHOLE shipped-graph-age family across all
  // configured repos (CR round 2, codex-adv-4). Defaults to
  // DEFAULT_SHIPPED_GRAPH_AGE_BUDGET_MS; tests override with a small value so
  // a budget-exceeded path is exercisable without a real multi-second wait.
  graphAgeBudgetMs?: number;
  cache?: ExporterCache;
};

type FlowStats = {
  flow: string;
  observed: boolean;
  lastSuccessTimestamp?: number;
  outcomes: Record<"complete" | "truncated" | "error" | "stalled", number>;
  latestEndMs?: number;
  latestItemsProcessed?: number | null;
  itemsProcessedTotal: number;
  hasItemsProcessedTotal: boolean;
  inFlight: number;
};

// Exported (HIMMEL-1199) so luna-sync-alert.ts resolves the same vault_path
// the exporter does, instead of re-deriving its own config path/parse rules.
export function configPath(env: Record<string, string | undefined>): string {
  const override = env.HIMMEL_OBSERVABILITY_CONFIG;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "observability.json");
}

export function readConfig(path: string): ObservabilityConfig {
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as ObservabilityConfig;
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function timestampOf(row: FlowRunRow): number {
  const ts = row.ev === "start" ? row.fired_at : row.ended_at;
  const ms = Date.parse(ts);
  return Number.isFinite(ms) ? ms : NaN;
}

function deadlineSeconds(flow: string, config: ObservabilityConfig): number {
  const declared = (config.flows ?? []).find((f) => f.name === flow);
  if (declared?.stall_deadline_seconds && declared.stall_deadline_seconds > 0) {
    return declared.stall_deadline_seconds;
  }
  if (declared?.cadence_seconds && declared.cadence_seconds > 0) {
    return declared.cadence_seconds * 2;
  }
  return DEFAULT_STALL_DEADLINE_SECONDS;
}

function emptyStats(flow: string): FlowStats {
  return {
    flow,
    observed: false,
    outcomes: { complete: 0, truncated: 0, error: 0, stalled: 0 },
    itemsProcessedTotal: 0,
    hasItemsProcessedTotal: false,
    inFlight: 0,
  };
}

function parseFlowLedgerRows(path: string, nowMs: number): { rows: FlowRunRow[]; ledgerRows: number } {
  const cutoff = nowMs - LOOKBACK_MS;
  const rows: FlowRunRow[] = [];
  for (const p of [path + ".1", path]) {
    if (!existsSync(p)) continue;
    const lines = readFileSync(p, "utf8").split(/\r?\n/);
    for (const line of lines) {
      if (!line.trim()) continue;
      let row: FlowRunRow;
      try {
        row = JSON.parse(line) as FlowRunRow;
      } catch {
        continue;
      }
      if (row.v !== 1 || (row.ev !== "start" && row.ev !== "end") || typeof row.flow !== "string") continue;
      const ms = timestampOf(row);
      if (!Number.isFinite(ms) || ms < cutoff || ms > nowMs + 60_000) continue;
      rows.push(row);
    }
  }
  return { rows, ledgerRows: rows.length };
}

function foldFlowLedger(rows: FlowRunRow[], config: ObservabilityConfig, nowMs: number): Map<string, FlowStats> {
  const stats = new Map<string, FlowStats>();
  const starts = new Map<string, FlowRunStart>();
  const endedRunIds = new Set<string>();

  for (const flow of config.flows ?? []) {
    if (flow.name) stats.set(flow.name, emptyStats(flow.name));
  }

  const ensure = (flow: string): FlowStats => {
    let s = stats.get(flow);
    if (!s) {
      s = emptyStats(flow);
      stats.set(flow, s);
    }
    return s;
  };

  for (const row of rows) {
    const s = ensure(row.flow);
    s.observed = true;
    if (row.ev === "start") {
      starts.set(row.run_id, row);
      continue;
    }

    const end = row as FlowRunEnd;
    endedRunIds.add(end.run_id);
    if (end.outcome === "complete" || end.outcome === "truncated" || end.outcome === "error") {
      s.outcomes[end.outcome]++;
      const endedMs = Date.parse(end.ended_at);
      if (end.outcome === "complete" && Number.isFinite(endedMs)) {
        const epoch = Math.floor(endedMs / 1000);
        if (s.lastSuccessTimestamp === undefined || epoch > s.lastSuccessTimestamp) {
          s.lastSuccessTimestamp = epoch;
        }
      }
      if (Number.isFinite(endedMs) && (s.latestEndMs === undefined || endedMs >= s.latestEndMs)) {
        s.latestEndMs = endedMs;
        s.latestItemsProcessed = end.items_processed;
      }
      if (typeof end.items_processed === "number" && Number.isFinite(end.items_processed)) {
        s.itemsProcessedTotal += end.items_processed;
        s.hasItemsProcessedTotal = true;
      }
    }
  }

  for (const start of starts.values()) {
    if (endedRunIds.has(start.run_id)) continue;
    const s = ensure(start.flow);
    const firedMs = Date.parse(start.fired_at);
    if (!Number.isFinite(firedMs)) continue;
    const ageS = (nowMs - firedMs) / 1000;
    if (ageS > deadlineSeconds(start.flow, config)) {
      s.outcomes.stalled++;
    } else {
      s.inFlight++;
    }
  }

  return stats;
}

function escLabel(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/"/g, '\\"');
}

function sample(name: string, labels: Record<string, string>, value: number): string {
  const entries = Object.entries(labels).sort(([a], [b]) => a.localeCompare(b));
  const labelText = entries.map(([k, v]) => `${k}="${escLabel(v)}"`).join(",");
  return labelText ? `${name}{${labelText}} ${formatNumber(value)}` : `${name} ${formatNumber(value)}`;
}

function formatNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(6).replace(/0+$/, "").replace(/\.$/, "");
}

function addFamily(lines: string[], name: string, help: string, type: "gauge" | "counter", samples: string[]): void {
  if (samples.length === 0) return;
  lines.push(`# HELP ${name} ${help}`);
  lines.push(`# TYPE ${name} ${type}`);
  lines.push(...samples);
}

function buildFlowMetrics(path: string, config: ObservabilityConfig, nowMs: number): { lines: string[]; ledgerRows: number } {
  const { rows, ledgerRows } = parseFlowLedgerRows(path, nowMs);
  const stats = [...foldFlowLedger(rows, config, nowMs).values()].sort((a, b) => a.flow.localeCompare(b.flow));
  const lines: string[] = [];

  addFamily(lines, "flow_run_last_success_timestamp", "Epoch seconds of the last complete run end row in the 14d ledger window.", "gauge",
    stats.flatMap((s) => s.lastSuccessTimestamp === undefined ? [] : [sample("flow_run_last_success_timestamp", { flow: s.flow }, s.lastSuccessTimestamp)]));

  const outcomes: Array<"complete" | "truncated" | "error" | "stalled"> = ["complete", "truncated", "error", "stalled"];
  addFamily(lines, "flow_run_outcome_total", "Runs by outcome in the sliding 14d ledger window; exporter restarts and window slides can reset this counter.", "counter",
    stats.flatMap((s) => s.observed ? outcomes.map((outcome) => sample("flow_run_outcome_total", { flow: s.flow, outcome }, s.outcomes[outcome])) : []));

  addFamily(lines, "flow_run_items_processed", "Last ended run items_processed value; null is omitted.", "gauge",
    stats.flatMap((s) => typeof s.latestItemsProcessed === "number" ? [sample("flow_run_items_processed", { flow: s.flow }, s.latestItemsProcessed)] : []));

  addFamily(lines, "flow_run_items_processed_total", "Sum of non-null items_processed values in the sliding 14d ledger window.", "counter",
    stats.flatMap((s) => s.hasItemsProcessedTotal ? [sample("flow_run_items_processed_total", { flow: s.flow }, s.itemsProcessedTotal)] : []));

  addFamily(lines, "flow_run_in_flight", "Unpaired start rows still within the flow stall deadline.", "gauge",
    stats.map((s) => sample("flow_run_in_flight", { flow: s.flow }, s.inFlight)));

  // HIMMEL-924: the declared cadence_seconds, verbatim from observability.json,
  // for the last-success-age alert rule's "2x cadence period (per-flow from
  // config)" threshold (design §5). Omitted for flows with no declared
  // cadence_seconds — an alert rule joining on this series never fires for
  // them, matching the "dark tile, not a fabricated healthy/unhealthy state"
  // rule for uninstrumented flows (design §1.3).
  addFamily(lines, "flow_cadence_seconds", "Declared cadence_seconds from observability.json, verbatim.", "gauge",
    [...(config.flows ?? [])]
      .filter((f) => f.name && f.cadence_seconds && f.cadence_seconds > 0)
      .sort((a, b) => a.name.localeCompare(b.name))
      .map((f) => sample("flow_cadence_seconds", { flow: f.name }, f.cadence_seconds!)));

  return { lines, ledgerRows };
}

// ===========================================================================
// HIMMEL-1052 — live session + subagent tracking
// ===========================================================================
// Sibling of the flow fold above, NOT a replacement: flows are the five
// pipeline-cadence legs, this is the operator's interactive/foreground Claude
// Code sessions and the Task-tool subagents fanned out inside them. Same
// passive-reader charter — this half only reads `session-runs.jsonl` (written
// by scripts/observability/session-run-hook.ts from existing hook
// chokepoints) plus the transcript files' mtimes.
//
// LIVENESS IS THE LOAD-BEARING DECISION, and it is why this cannot reuse
// foldFlowLedger unmodified. A flow has a known cadence, so an unpaired start
// past `cadence*2` is stalled. An interactive session has no cadence and can
// legitimately sit idle for a long time waiting on the operator. Wall-clock
// age alone therefore cannot tell "thinking" from "died three hours ago".
// The transcript file can: it advances exactly while, and only while, the
// session is doing something — independent of whether any hook fired cleanly
// at exit. So an unpaired `session_start` is `running` while its transcript
// mtime is fresh and `dead` once it goes stale, and a session with a matching
// `session_end` row is `ended`, tagged by reason.

export type SessionStatus = "running" | "dead" | "ended";

// The per-session detail view. This is served as JSON (GET /sessions.json),
// NOT as Prometheus labels: `session_id` is unique per occurrence and
// unbounded over time, and putting it in a label set is the textbook
// cardinality explosion. Metrics below stay aggregated; detail lives here.
export type SessionView = {
  session_id: string;
  cwd: string | null;
  host: string;
  started_at: string;
  status: SessionStatus;
  end_reason: string | null;
  age_seconds: number;
  // Seconds since the transcript last advanced. null = the transcript path is
  // absent or unreadable, which is reported as unknown, never as 0.
  last_activity_seconds: number | null;
  subagents_started: number;
  subagents_active: number;
};

const SESSION_LABEL_MAX_CHARS = 64;

// Label values here originate in hook payloads (a hostname, an Agent tool's
// `subagent_type`) rather than a fixed in-repo enum, so they are sanitized
// before rendering: control characters — carriage return in particular, which
// escLabel does NOT escape — would inject a new exposition line, and an
// unbounded string would bloat every series name it appears in.
function sanitizeLabelValue(raw: unknown, fallback = "unknown"): string {
  if (typeof raw !== "string") return fallback;
  const cleaned = raw.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  if (!cleaned) return fallback;
  return cleaned.length > SESSION_LABEL_MAX_CHARS ? cleaned.slice(0, SESSION_LABEL_MAX_CHARS) : cleaned;
}

function sessionStaleAfterSeconds(config: ObservabilityConfig): number {
  const declared = config.sessions?.stale_after_seconds;
  return typeof declared === "number" && Number.isFinite(declared) && declared > 0
    ? declared
    : DEFAULT_SESSION_STALE_AFTER_SECONDS;
}

function sessionRowTimestampMs(row: SessionRunRow): number {
  const ts = row.ev === "start"
    ? (row as SessionStartRow | SubagentStartRow).started_at
    : (row as SessionEndRow | SubagentEndRow).ended_at;
  const ms = typeof ts === "string" ? Date.parse(ts) : NaN;
  return Number.isFinite(ms) ? ms : NaN;
}

function isSessionRunRow(raw: unknown): raw is SessionRunRow {
  if (!raw || typeof raw !== "object") return false;
  const r = raw as Record<string, unknown>;
  if (r.v !== 1) return false;
  if (r.kind !== "session" && r.kind !== "subagent") return false;
  if (r.ev !== "start" && r.ev !== "end") return false;
  if (r.kind === "session") return typeof r.session_id === "string" && r.session_id.length > 0;
  return typeof r.subagent_id === "string" && r.subagent_id.length > 0
    && typeof r.parent_session_id === "string" && r.parent_session_id.length > 0;
}

export function parseSessionLedgerRows(path: string, nowMs: number): { rows: SessionRunRow[]; ledgerRows: number } {
  const cutoff = nowMs - LOOKBACK_MS;
  const rows: SessionRunRow[] = [];
  for (const p of [path + ".1", path]) {
    if (!existsSync(p)) continue;
    let text: string;
    try {
      text = readFileSync(p, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) continue;
      let parsed: unknown;
      try {
        parsed = JSON.parse(line);
      } catch {
        continue;
      }
      if (!isSessionRunRow(parsed)) continue;
      const ms = sessionRowTimestampMs(parsed);
      if (!Number.isFinite(ms) || ms < cutoff || ms > nowMs + 60_000) continue;
      rows.push(parsed);
    }
  }
  return { rows, ledgerRows: rows.length };
}

// Seconds since the transcript last advanced, or null when it cannot be read.
// Clamped at 0: a clock skew that puts the mtime slightly in the future must
// read as "just now", not as a negative age.
function transcriptIdleSeconds(path: string | null, nowMs: number): number | null {
  if (!path) return null;
  try {
    const mtimeMs = statSync(path).mtimeMs;
    if (!Number.isFinite(mtimeMs)) return null;
    return Math.max(0, (nowMs - mtimeMs) / 1000);
  } catch {
    return null;
  }
}

type SessionFold = {
  sessions: SessionView[];
  endRows: SessionEndRow[];
  subagentStarts: SubagentStartRow[];
  subagentEndIds: Set<string>;
  subagentEnds: SubagentEndRow[];
};

export function foldSessionLedger(rows: SessionRunRow[], nowMs: number, staleAfterSeconds: number): SessionFold {
  const starts = new Map<string, SessionStartRow>();
  const ends = new Map<string, SessionEndRow>();
  const subagentStarts = new Map<string, SubagentStartRow>();
  const subagentEnds = new Map<string, SubagentEndRow>();

  for (const row of rows) {
    if (row.kind === "session") {
      if (row.ev === "start") starts.set(row.session_id, row);
      else ends.set(row.session_id, row);
      continue;
    }
    if (row.ev === "start") subagentStarts.set(row.subagent_id, row);
    else subagentEnds.set(row.subagent_id, row);
  }

  const statuses = new Map<string, SessionStatus>();
  const views: SessionView[] = [];
  for (const start of starts.values()) {
    const end = ends.get(start.session_id);
    const idle = transcriptIdleSeconds(start.transcript_path, nowMs);
    const startedMs = Date.parse(start.started_at);
    const ageSeconds = Number.isFinite(startedMs) ? Math.max(0, (nowMs - startedMs) / 1000) : 0;
    // A transcript we cannot read is NOT evidence of life: fall back to the
    // session's own age against the same threshold, so a session whose
    // transcript never appeared (or was cleaned up) ages into `dead` instead
    // of being counted as running forever.
    const activitySeconds = idle ?? ageSeconds;
    const status: SessionStatus = end ? "ended" : activitySeconds <= staleAfterSeconds ? "running" : "dead";
    statuses.set(start.session_id, status);
    views.push({
      session_id: start.session_id,
      cwd: start.cwd,
      host: sanitizeLabelValue(start.host),
      started_at: start.started_at,
      status,
      end_reason: end ? sanitizeLabelValue(end.reason, "other") : null,
      age_seconds: ageSeconds,
      last_activity_seconds: idle,
      subagents_started: 0,
      subagents_active: 0,
    });
  }

  const viewById = new Map(views.map((v) => [v.session_id, v]));
  for (const sub of subagentStarts.values()) {
    const view = viewById.get(sub.parent_session_id);
    if (!view) continue;
    view.subagents_started++;
    // A subagent counts as ACTIVE only while its parent session is running.
    // Deliberate narrowing of the design draft's plain "start row with no end
    // row": a subagent whose parent crashed can never emit its end row, so an
    // unqualified reading would leave phantom subagents pinned live for the
    // whole 14d window — the exact false-positive this ticket exists to kill.
    if (!subagentEnds.has(sub.subagent_id) && statuses.get(sub.parent_session_id) === "running") {
      view.subagents_active++;
    }
  }

  views.sort((a, b) => (b.started_at.localeCompare(a.started_at)) || a.session_id.localeCompare(b.session_id));
  return {
    sessions: views,
    endRows: [...ends.values()],
    subagentStarts: [...subagentStarts.values()],
    subagentEndIds: new Set(subagentEnds.keys()),
    subagentEnds: [...subagentEnds.values()],
  };
}

function buildSessionMetrics(path: string, config: ObservabilityConfig, nowMs: number): { lines: string[]; ledgerRows: number } {
  const { rows, ledgerRows } = parseSessionLedgerRows(path, nowMs);
  const staleAfterSeconds = sessionStaleAfterSeconds(config);
  const fold = foldSessionLedger(rows, nowMs, staleAfterSeconds);
  const lines: string[] = [];

  // Per host: a zeroed entry for every host observed in the window, so the
  // gauges stay present (and a dead-session alert stays evaluable) once the
  // last live session on that host goes away.
  const byHost = new Map<string, { active: number; dead: number }>();
  for (const view of fold.sessions) {
    const bucket = byHost.get(view.host) ?? { active: 0, dead: 0 };
    if (view.status === "running") bucket.active++;
    if (view.status === "dead") bucket.dead++;
    byHost.set(view.host, bucket);
  }
  const hosts = [...byHost.keys()].sort((a, b) => a.localeCompare(b));

  addFamily(lines, "session_active_total", "Claude Code sessions with an unpaired start row whose transcript is still advancing (HIMMEL-1052).", "gauge",
    hosts.map((host) => sample("session_active_total", { host }, byHost.get(host)!.active)));
  addFamily(lines, "session_dead_total", "Sessions with an unpaired start row whose transcript went stale — crashed, killed, or wedged. SessionEnd never fires for these, so a purely start/end-paired ledger cannot see them.", "gauge",
    hosts.map((host) => sample("session_dead_total", { host }, byHost.get(host)!.dead)));

  const reasonCounts = new Map<string, number>();
  for (const reason of SESSION_END_REASONS) reasonCounts.set(reason, 0);
  for (const end of fold.endRows) {
    const reason = sanitizeLabelValue(end.reason, "other");
    // Closed enum: the writer already normalizes, but a hand-edited or
    // foreign row must not open an unbounded label.
    const key = reasonCounts.has(reason) ? reason : "other";
    reasonCounts.set(key, (reasonCounts.get(key) ?? 0) + 1);
  }
  addFamily(lines, "session_end_outcome_total", "Graceful session_end rows by reason in the sliding 14d ledger window; window slides read as counter resets, same caveat as flow_run_outcome_total.", "counter",
    fold.endRows.length > 0 ? SESSION_END_REASONS.map((reason) => sample("session_end_outcome_total", { reason }, reasonCounts.get(reason) ?? 0)) : []);

  // (host, subagent_type) pairs: host is resolved through the PARENT session's
  // start row — the subagent rows deliberately carry no host of their own
  // rather than duplicating a field that can be joined.
  const viewBySession = new Map(fold.sessions.map((v) => [v.session_id, v]));
  const typeBySubagent = new Map(fold.subagentStarts.map((s) => [s.subagent_id, sanitizeLabelValue(s.subagent_type)]));
  const activeByPair = new Map<string, number>();
  for (const sub of fold.subagentStarts) {
    const parent = viewBySession.get(sub.parent_session_id);
    const host = parent?.host ?? "unknown";
    const subagentType = typeBySubagent.get(sub.subagent_id) ?? "unknown";
    const key = `${host}\u0000${subagentType}`;
    const current = activeByPair.get(key) ?? 0;
    const active = !fold.subagentEndIds.has(sub.subagent_id) && parent?.status === "running";
    activeByPair.set(key, current + (active ? 1 : 0));
  }
  addFamily(lines, "subagent_active_total", "Task-tool subagents with an unpaired start row under a still-running parent session (HIMMEL-1052).", "gauge",
    [...activeByPair.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, count]) => {
        const [host, subagent_type] = key.split("\u0000");
        return sample("subagent_active_total", { host, subagent_type }, count);
      }));

  const outcomeByType = new Map<string, Map<string, number>>();
  for (const end of fold.subagentEnds) {
    const subagentType = typeBySubagent.get(end.subagent_id) ?? "unknown";
    const outcome = sanitizeLabelValue(end.outcome, "unknown");
    const key = (SUBAGENT_OUTCOMES as readonly string[]).includes(outcome) ? outcome : "unknown";
    let byOutcome = outcomeByType.get(subagentType);
    if (!byOutcome) {
      byOutcome = new Map(SUBAGENT_OUTCOMES.map((o) => [o as string, 0]));
      outcomeByType.set(subagentType, byOutcome);
    }
    byOutcome.set(key, (byOutcome.get(key) ?? 0) + 1);
  }
  addFamily(lines, "subagent_outcome_total", "Subagent end rows by coarse outcome in the sliding 14d ledger window. `unknown` means the tool response could not be classified, never an assumed success.", "counter",
    [...outcomeByType.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .flatMap(([subagent_type, byOutcome]) => SUBAGENT_OUTCOMES.map((outcome) => sample("subagent_outcome_total", { subagent_type, outcome }, byOutcome.get(outcome) ?? 0))));

  return { lines, ledgerRows };
}

// GET /sessions.json — the per-session table panel's data path (the design
// draft's Open Question 3, answered as "an endpoint on the existing exporter"
// rather than a second script + datasource, so there is one reader and one
// liveness rule). Still a pure read: same ledger, same fold, no writes.
export function renderSessionsJson(options: RenderMetricsOptions = {}): string {
  const env = options.env ?? process.env;
  const nowMs = options.nowMs ?? Date.now();
  const cfg = readConfig(options.configPath ?? configPath(env));
  const staleAfterSeconds = sessionStaleAfterSeconds(cfg);
  const path = options.sessionLedgerPath ?? sessionRunLedgerPath(env);
  const { rows, ledgerRows } = parseSessionLedgerRows(path, nowMs);
  const fold = foldSessionLedger(rows, nowMs, staleAfterSeconds);
  return JSON.stringify({
    v: 1,
    generated_at: new Date(nowMs).toISOString(),
    stale_after_seconds: staleAfterSeconds,
    ledger_rows: ledgerRows,
    sessions: fold.sessions,
  });
}

const FETCH_HEALTH_STATUSES = [
  "ok",
  "auth-or-cookie-expired",
  "blocked-or-rate-limited",
  "transport-fail",
] as const;

type FetchHealthStatus = typeof FETCH_HEALTH_STATUSES[number];

function defaultFetchHealthStatePath(env: Record<string, string | undefined>): string {
  const override = env.HIMMEL_FETCH_HEALTH_STATE;
  if (override && override.trim()) return override;
  return join(env.USERPROFILE ?? env.HOME ?? homedir(), ".himmel", "fetch-health.json");
}

function fetchHealthMetrics(path: string): { lines: string[]; comments: string[] } {
  if (!existsSync(path)) return { lines: [], comments: [] };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object") throw new Error("state is not an object");
    const sources = (parsed as Record<string, unknown>).sources;
    if (!sources || typeof sources !== "object" || Array.isArray(sources)) {
      throw new Error("sources is not an object");
    }

    const statusSamples: string[] = [];
    const successSamples: string[] = [];
    for (const [source, value] of Object.entries(sources).sort(([a], [b]) => a.localeCompare(b))) {
      if (!source || /[\r\n]/.test(source) || !value || typeof value !== "object" || Array.isArray(value)) continue;
      const row = value as Record<string, unknown>;
      const status = row.status;
      if (typeof status !== "string" || !FETCH_HEALTH_STATUSES.includes(status as FetchHealthStatus)) continue;
      for (const candidate of FETCH_HEALTH_STATUSES) {
        statusSamples.push(sample("clip_fetch_source_status", { source, status: candidate }, candidate === status ? 1 : 0));
      }
      const lastSuccess = row.last_success_timestamp;
      if (typeof lastSuccess === "number" && Number.isFinite(lastSuccess) && lastSuccess >= 0) {
        successSamples.push(sample("clip_fetch_source_last_success_timestamp", { source }, lastSuccess));
      }
    }

    const lines: string[] = [];
    addFamily(lines, "clip_fetch_source_status", "One-hot daily fetch-health classification for each live Luna clip source.", "gauge", statusSamples);
    addFamily(lines, "clip_fetch_source_last_success_timestamp", "Epoch seconds of the last successful known-good fetch probe per Luna clip source.", "gauge", successSamples);
    return { lines, comments: [] };
  } catch (e) {
    const message = e instanceof Error && e.message ? e.message : "state parse failed";
    return { lines: [], comments: [`# clip_fetch_source_* omitted: ${message.replace(/\s+/g, " ").trim()}`] };
  }
}

function normalizeTaskSamples(raw: unknown): ScheduledTaskSample[] {
  const arr = Array.isArray(raw) ? raw : raw ? [raw] : [];
  const samples: ScheduledTaskSample[] = [];
  for (const item of arr) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    const task = typeof row.task === "string" ? row.task : typeof row.Task === "string" ? row.Task : null;
    if (!task) continue;
    const exists = row.exists ?? row.Exists;
    const enabled = row.enabled ?? row.Enabled;
    const next = row.next_run_timestamp ?? row.NextRunTimestamp;
    samples.push({
      task,
      exists: exists === 1 || exists === true ? 1 : 0,
      enabled: enabled === 1 || enabled === true ? 1 : 0,
      next_run_timestamp: typeof next === "number" && Number.isFinite(next) ? next : null,
    });
  }
  return samples;
}

function powershellArrayLiteral(values: string[]): string {
  return JSON.stringify(values).replace(/'/g, "''");
}

async function runWindowsScheduledTasks(tasks: string[]): Promise<ScheduledTaskSample[]> {
  if (tasks.length === 0) return [];
  const namesJson = powershellArrayLiteral(tasks);
  const script = `
$ErrorActionPreference = 'SilentlyContinue'
$names = ConvertFrom-Json '${namesJson}'
# UTC-kind epoch anchor: [datetime]'...Z' parses as LOCAL kind, and DateTime
# subtraction ignores Kind, which would skew next_run by the UTC offset.
$epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
$out = foreach ($name in $names) {
  $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($null -eq $task) {
    [pscustomobject]@{ task = $name; exists = 0; enabled = 0; next_run_timestamp = $null }
    continue
  }
  $enabled = 0
  if ($task.State -ne 'Disabled') { $enabled = 1 }
  $nextEpoch = $null
  $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
  if ($null -ne $info -and $null -ne $info.NextRunTime -and $info.NextRunTime -gt $epoch) {
    $nextEpoch = [int64](($info.NextRunTime.ToUniversalTime() - $epoch).TotalSeconds)
  }
  [pscustomobject]@{ task = $name; exists = 1; enabled = $enabled; next_run_timestamp = $nextEpoch }
}
$out | ConvertTo-Json -Compress
`.trim();
  // Async spawn with a hard timeout: a hung PowerShell must fail this family
  // closed (omitted), never freeze the scrape server the way a sync spawn
  // on the request path would.
  const proc = Bun.spawn(["powershell", "-NoProfile", "-Command", script], { stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => {
    try { proc.kill(); } catch { /* already gone */ }
  }, SCHEDULER_QUERY_TIMEOUT_MS);
  try {
    const exitCode = await proc.exited;
    clearTimeout(timer);
    if (exitCode !== 0) return [];
    const out = await new Response(proc.stdout).text();
    return normalizeTaskSamples(JSON.parse(out));
  } catch {
    clearTimeout(timer);
    return [];
  }
}

async function scheduledTaskMetrics(
  config: ObservabilityConfig,
  opts: Required<Pick<RenderMetricsOptions, "platform" | "nowMs" | "cache">> & { schedulerRunner?: SchedulerRunner },
): Promise<{ lines: string[]; comments: string[] }> {
  const tasks = [...(config.expected_tasks ?? [])].filter(Boolean).sort();
  if (tasks.length === 0) return { lines: [], comments: [] };
  if (opts.platform !== "win32") {
    return { lines: [], comments: ["# scheduled_task_* omitted: platform has no Windows Scheduled Tasks API"] };
  }

  const key = tasks.join("\0");
  if (opts.cache.scheduler && opts.cache.scheduler.key === key && opts.nowMs - opts.cache.scheduler.fetchedAtMs < CACHE_TTL_MS) {
    return buildScheduledTaskLines(opts.cache.scheduler.value.samples, opts.cache.scheduler.value.comments);
  }

  const runner = opts.schedulerRunner ?? runWindowsScheduledTasks;
  let samples: ScheduledTaskSample[] = [];
  const comments: string[] = [];
  try {
    samples = normalizeTaskSamples(await runner(tasks));
    const byTask = new Map(samples.map((s) => [s.task, s]));
    samples = tasks.map((task) => byTask.get(task) ?? { task, exists: 0, enabled: 0, next_run_timestamp: null });
  } catch {
    comments.push("# scheduled_task_* omitted: scheduled-task query failed");
  }
  opts.cache.scheduler = { key, fetchedAtMs: opts.nowMs, value: { samples, comments } };
  return buildScheduledTaskLines(samples, comments);
}

function buildScheduledTaskLines(samples: ScheduledTaskSample[], comments: string[]): { lines: string[]; comments: string[] } {
  const ordered = [...samples].sort((a, b) => a.task.localeCompare(b.task));
  const lines: string[] = [];
  addFamily(lines, "scheduled_task_exists", "Whether an expected Windows scheduled task exists.", "gauge",
    ordered.map((s) => sample("scheduled_task_exists", { task: s.task }, s.exists)));
  addFamily(lines, "scheduled_task_enabled", "Whether an expected Windows scheduled task is enabled.", "gauge",
    ordered.map((s) => sample("scheduled_task_enabled", { task: s.task }, s.enabled ?? 0)));
  addFamily(lines, "scheduled_task_next_run_timestamp", "Next run time as epoch seconds from a Date object, never a locale-rendered string.", "gauge",
    ordered.flatMap((s) => s.exists && typeof s.next_run_timestamp === "number" ? [sample("scheduled_task_next_run_timestamp", { task: s.task }, s.next_run_timestamp)] : []));
  return { lines, comments };
}

function hostDetectorTtlMs(config: ObservabilityConfig): number {
  const seconds = config.host_detectors_ttl_seconds;
  return typeof seconds === "number" && Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : CACHE_TTL_MS;
}

function asNonNegativeNumber(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : 0;
}

export function parseHostDetectorJson(raw: unknown): HostDetectorResult {
  const parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
  if (!parsed || typeof parsed !== "object") {
    throw new Error("host-detectors output is not an object");
  }
  const row = parsed as Record<string, unknown>;
  const treesRaw = Array.isArray(row.trees) ? row.trees : [];
  const orphansRaw = Array.isArray(row.orphans) ? row.orphans : [];
  return {
    trees: treesRaw.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const tree = item as Record<string, unknown>;
      if (typeof tree.class !== "string" || !tree.class) return [];
      return [{
        class: tree.class,
        rss_bytes: asNonNegativeNumber(tree.rss_bytes),
        process_count: asNonNegativeNumber(tree.process_count),
      }];
    }),
    orphans: orphansRaw.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const orphan = item as Record<string, unknown>;
      if (typeof orphan.class !== "string" || !orphan.class) return [];
      return [{
        class: orphan.class,
        count: asNonNegativeNumber(orphan.count),
      }];
    }),
  };
}

async function runWindowsHostDetectors(): Promise<HostDetectorResult> {
  const scriptPath = join(import.meta.dir, "host-detectors.ps1");
  const proc = Bun.spawn(["powershell", "-NoProfile", "-File", scriptPath], { stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => {
    try { proc.kill(); } catch { /* already gone */ }
  }, HOST_DETECTOR_TIMEOUT_MS);
  try {
    // Drain both pipes CONCURRENTLY with exit: awaiting exited first can
    // deadlock if the child fills a pipe buffer before exiting (codex-5).
    const [exitCode, out, err] = await Promise.all([
      proc.exited,
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    clearTimeout(timer);
    if (exitCode !== 0) {
      throw new Error(err.trim() || `host-detectors exited ${exitCode}`);
    }
    return parseHostDetectorJson(out);
  } catch (e) {
    clearTimeout(timer);
    throw e;
  }
}

function hostDetectorOmitComment(reason: string): string {
  return `# agent_tree_*/orphan_* omitted: ${reason.replace(/\s+/g, " ").trim() || "host-detectors query failed"}`;
}

async function hostDetectorMetrics(
  config: ObservabilityConfig,
  opts: Required<Pick<RenderMetricsOptions, "platform" | "nowMs" | "cache">> & { hostDetectorRunner?: HostDetectorRunner },
): Promise<{ lines: string[]; comments: string[] }> {
  if (opts.platform !== "win32") {
    return { lines: [], comments: [hostDetectorOmitComment("platform has no Windows process tree API")] };
  }

  const key = "host-detectors";
  const ttlMs = hostDetectorTtlMs(config);
  if (opts.cache.hostDetectors && opts.cache.hostDetectors.key === key && opts.nowMs - opts.cache.hostDetectors.fetchedAtMs < ttlMs) {
    return buildHostDetectorLines(opts.cache.hostDetectors.value);
  }

  const runner = opts.hostDetectorRunner ?? runWindowsHostDetectors;
  try {
    const result = parseHostDetectorJson(await runner());
    opts.cache.hostDetectors = { key, fetchedAtMs: opts.nowMs, value: result };
    return buildHostDetectorLines(result);
  } catch (e) {
    delete opts.cache.hostDetectors;
    const message = e instanceof Error && e.message ? e.message : "host-detectors query failed";
    return { lines: [], comments: [hostDetectorOmitComment(message)] };
  }
}

function buildHostDetectorLines(result: HostDetectorResult): { lines: string[]; comments: string[] } {
  const trees = [...result.trees].sort((a, b) => a.class.localeCompare(b.class));
  const orphans = [...result.orphans].sort((a, b) => a.class.localeCompare(b.class));
  const lines: string[] = [];
  addFamily(lines, "agent_tree_rss_bytes", "Working-set bytes summed by agent process tree class.", "gauge",
    trees.map((s) => sample("agent_tree_rss_bytes", { class: s.class }, s.rss_bytes)));
  addFamily(lines, "agent_tree_process_count", "Process count summed by agent process tree class.", "gauge",
    trees.map((s) => sample("agent_tree_process_count", { class: s.class }, s.process_count)));
  addFamily(lines, "orphan_process_count", "Report-only orphan-shaped process count by detector class.", "gauge",
    orphans.map((s) => sample("orphan_process_count", { class: s.class }, s.count)));
  return { lines, comments: [] };
}

function frontmatter(text: string): string {
  if (!text.startsWith("---")) return "";
  const end = text.indexOf("\n---", 3);
  if (end < 0) return "";
  return text.slice(3, end);
}

function lunaMetrics(config: ObservabilityConfig, nowMs: number, cache: ExporterCache): string[] {
  const vault = config.vault_path;
  if (!vault) return [];
  const key = vault;
  if (cache.luna && cache.luna.key === key && nowMs - cache.luna.fetchedAtMs < CACHE_TTL_MS) {
    return cache.luna.value.samples;
  }

  const samples: string[] = [];
  const clippings = join(vault, "Clippings");
  if (!existsSync(clippings)) {
    cache.luna = { key, fetchedAtMs: nowMs, value: { samples } };
    return samples;
  }

  let unprocessed = 0;
  let unharvested = 0;
  for (const name of readdirSync(clippings)) {
    // Per-entry guard: a file vanishing between readdir and stat/read (live
    // vault) must skip that entry, not abort the whole scrape.
    try {
      const path = join(clippings, name);
      if (!name.endsWith(".md") || !statSync(path).isFile()) continue;
      const fm = frontmatter(readFileSync(path, "utf8"));
      if (!/^processed:\s*true\s*$/m.test(fm)) unprocessed++;
      if (!/^harvested_at:\s*.+$/m.test(fm)) unharvested++;
    } catch {
      continue;
    }
  }

  addFamily(samples, "luna_inbox_backlog", "Luna clipping inbox backlog by processing stage.", "gauge", [
    sample("luna_inbox_backlog", { stage: "unprocessed" }, unprocessed),
    sample("luna_inbox_backlog", { stage: "unharvested" }, unharvested),
  ]);

  const month = new Date(nowMs).toISOString().slice(0, 7);
  const doneDir = join(clippings, "_done", month);
  if (existsSync(doneDir)) {
    // Same fail-soft contract as the inbox walk: entries (or the whole dir)
    // vanishing mid-scrape skip silently; the family is omitted, never a 500.
    try {
      let count = 0;
      for (const name of readdirSync(doneDir)) {
        try {
          if (name.endsWith(".md") && statSync(join(doneDir, name)).isFile()) count++;
        } catch {
          continue;
        }
      }
      addFamily(samples, "luna_done_graduations_month", "Count of Luna clippings graduated into the current YYYY-MM done folder.", "gauge", [
        sample("luna_done_graduations_month", {}, count),
      ]);
    } catch {
      // done dir vanished mid-scrape: omit family, do not abort.
    }
  }

  cache.luna = { key, fetchedAtMs: nowMs, value: { samples } };
  return samples;
}

export type GitCommandResult = { exitCode: number; stdout: string; stderr: string };
export type GitCommandRunner = (args: string[], cwd: string, timeoutMs: number) => Promise<GitCommandResult>;

async function runGitCommand(args: string[], cwd: string, timeoutMs: number): Promise<GitCommandResult> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => {
    try { proc.kill(); } catch { /* already gone */ }
  }, timeoutMs);
  try {
    const [exitCode, out, err] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    clearTimeout(timer);
    return { exitCode, stdout: out, stderr: err };
  } catch (e) {
    clearTimeout(timer);
    throw e;
  }
}

// Local-refs-only divergence read (HIMMEL-1199) — the exact signal for the
// incident this ticket detects (an auto-sync push silently blocked, commits
// piling up unpushed). NO `git fetch` anywhere here: that is the passivity
// invariant this exporter is built on. `git status --porcelain` proves the
// vault is a readable repo; if it fails (missing repo, timeout, spawn error)
// the whole family is omitted by the caller. `@{u}..HEAD` separately fails
// ONLY when the branch has no upstream configured — that omits just the
// unpushed sample, since the uncommitted-files reading is still valid. Every
// OTHER rev-list failure (timeout, spawn error, non-numeric output, any other
// nonzero exit) is ambiguous and must PROPAGATE so the caller omits the whole
// family — never fold a transient failure into a false "clean" (unpushed:null)
// reading, which is the exact silent-failure mode this ticket exists to kill.
// The git command runner is injected (default: real spawn) so the branch
// discrimination is unit-testable without a live git.
export async function runGitDivergence(vaultPath: string, run: GitCommandRunner = runGitCommand): Promise<GitDivergenceResult> {
  const status = await run(["status", "--porcelain"], vaultPath, GIT_QUERY_TIMEOUT_MS);
  if (status.exitCode !== 0) throw new Error(`git status exited ${status.exitCode}`);
  const uncommittedFiles = status.stdout.split(/\r?\n/).filter((l) => l.trim().length > 0).length;

  const rev = await run(["rev-list", "--count", "@{u}..HEAD"], vaultPath, GIT_QUERY_TIMEOUT_MS);
  let unpushed: number | null;
  if (rev.exitCode === 0 && /^\d+$/.test(rev.stdout.trim())) {
    unpushed = Number(rev.stdout.trim());
  } else if (/no upstream configured/i.test(rev.stderr)) {
    // Genuine "branch has no upstream" — nothing to compare. Omit only the
    // unpushed sample; the uncommitted-files reading above is still valid.
    unpushed = null;
  } else {
    // Timeout / spawn error / non-numeric output / any other nonzero exit —
    // cause unknown. Propagate so the whole family is omitted, not "clean".
    const detail = (rev.stderr.trim() || rev.stdout.trim() || "no output").slice(0, 200);
    throw new Error(`git rev-list @{u}..HEAD exited ${rev.exitCode}: ${detail}`);
  }

  return { unpushed, uncommittedFiles };
}

function lunaGitOmitComment(reason: string): string {
  return `# luna_git_* omitted: ${reason.replace(/\s+/g, " ").trim() || "git query failed"}`;
}

function buildLunaGitLines(result: GitDivergenceResult): string[] {
  const lines: string[] = [];
  addFamily(lines, "luna_git_unpushed_commits", "Commits on HEAD not yet pushed to @{u} (git rev-list --count @{u}..HEAD; no fetch). Omitted when the vault has no upstream configured — a true 'behind' count would need a fetch and is intentionally not implemented (passivity invariant).", "gauge",
    result.unpushed !== null ? [sample("luna_git_unpushed_commits", {}, result.unpushed)] : []);
  addFamily(lines, "luna_git_uncommitted_files", "Line count of `git status --porcelain` in the luna vault clone.", "gauge",
    [sample("luna_git_uncommitted_files", {}, result.uncommittedFiles)]);
  return lines;
}

async function lunaGitMetrics(
  config: ObservabilityConfig,
  opts: Required<Pick<RenderMetricsOptions, "nowMs" | "cache">> & { gitRunner?: GitRunner },
): Promise<{ lines: string[]; comments: string[] }> {
  const vault = config.vault_path;
  if (!vault) return { lines: [], comments: [] };

  const key = vault;
  if (opts.cache.lunaGit && opts.cache.lunaGit.key === key && opts.nowMs - opts.cache.lunaGit.fetchedAtMs < CACHE_TTL_MS) {
    return { lines: buildLunaGitLines(opts.cache.lunaGit.value), comments: [] };
  }

  const runner = opts.gitRunner ?? runGitDivergence;
  try {
    const result = await runner(vault);
    opts.cache.lunaGit = { key, fetchedAtMs: opts.nowMs, value: result };
    return { lines: buildLunaGitLines(result), comments: [] };
  } catch (e) {
    delete opts.cache.lunaGit;
    const message = e instanceof Error && e.message ? e.message : "git query failed";
    return { lines: [], comments: [lunaGitOmitComment(message)] };
  }
}

// HIMMEL-1129 (option 3): shipped-graph age observability. HIMMEL-1123
// tracks graphify-out/graph.json + GRAPH_REPORT.md so stations that can't
// afford a re-extract (win2) pull the graph instead — but a pulled checkout's
// FILE MTIME is checkout time, not content age, so check-graph-freshness.sh's
// mtime read is meaningless on a shipped/pulled copy (it always reads FRESH).
// The real age of what was SHIPPED is the git commit time of the last commit
// that touched graphify-out/graph.json — that's what these two series expose.
//
// Deliberately NOT named graphify_graph_age_seconds{corpus} (the name
// HIMMEL-1124 proposes for a LOCAL graph's mtime-based age, still unimplemented
// at time of writing — verified: HIMMEL-1124 is "To Do", no commits exist
// under that key anywhere in history). Reusing that exact name here would
// collide two different measurements (git-commit-time vs. mtime) under one
// series; graphify_shipped_graph_age_seconds keeps 1124's naming convention
// and PromQL shape (per-corpus gauge, HELP/TYPE lines) while staying
// unambiguous about what it measures.
export type ShippedGraphAgeResult = { epochSeconds: number } | null;
export type ShippedGraphAgeRunner = (repoPath: string, ref: string) => Promise<ShippedGraphAgeResult>;

const SHIPPED_GRAPH_PATH = "graphify-out/graph.json";
const DEFAULT_SHIPPED_GRAPH_REF = "main";

// Exported for unit tests (mirrors runGitDivergence's raw-command-runner seam):
// null = the path has no commit history in this repo (never tracked there);
// a thrown error = ambiguous (timeout, spawn error, non-numeric output) and
// must PROPAGATE so the caller omits the whole family rather than reading it
// as "no history" (same discipline as HIMMEL-1199's runGitDivergence).
//
// `ref` MUST be explicit (CR round 1, codex-adv-1): `git log -1 -- <path>`
// with no starting ref reads whatever branch is CURRENTLY CHECKED OUT in
// repoPath, not the protected default. A checkout sitting on a feature or
// publish branch would then report a fresh unmerged graph while `main`
// itself stayed stale — silently defeating the whole alert. `ref` is a
// LOCAL branch name (default "main", per config.graphify_repos[].default_branch)
// — this function does no `git fetch` (same passivity invariant as
// lunaGitMetrics/runGitDivergence), so it reads whatever that local ref
// happens to point at and CAN LAG the remote if nothing else keeps it
// updated on the exporter's host.
export async function readShippedGraphCommitTime(repoPath: string, ref: string = DEFAULT_SHIPPED_GRAPH_REF, run: GitCommandRunner = runGitCommand): Promise<ShippedGraphAgeResult> {
  const res = await run(["log", "-1", "--format=%ct", ref, "--", SHIPPED_GRAPH_PATH], repoPath, GIT_QUERY_TIMEOUT_MS);
  if (res.exitCode !== 0) {
    const detail = (res.stderr.trim() || res.stdout.trim() || "no output").slice(0, 200);
    throw new Error(`git log -1 ${ref} -- ${SHIPPED_GRAPH_PATH} exited ${res.exitCode}: ${detail}`);
  }
  const out = res.stdout.trim();
  if (!out) return null;
  const epochSeconds = Number(out);
  if (!Number.isFinite(epochSeconds)) {
    throw new Error(`git log produced a non-numeric commit time: ${out.slice(0, 80)}`);
  }
  return { epochSeconds };
}

function shippedGraphAgeOmitComment(corpus: string, reason: string): string {
  return `# graphify_shipped_graph_age_seconds omitted (corpus=${corpus}): ${reason.replace(/\s+/g, " ").trim() || "shipped-graph query failed"}`;
}

type GraphifyRepoEntry = { corpus: string; repo_path: string; default_branch?: string };

// CR round 1 (codex-adv-5): config.graphify_repos is OPERATOR-EDITED JSON, not
// a value this module produces itself — a malformed entry (wrong shape, an
// object instead of an array, a non-string corpus) must never crash the whole
// /metrics scrape (Prometheus would see a hard 500 across EVERY family, not
// just this one). Invalid entries are skipped with a comment; valid siblings
// still render. Duplicate `corpus` values are also rejected (second-and-later
// occurrence skipped) — two samples of the same gauge under an identical
// label set is a malformed exposition, not "last write wins".
function validateGraphifyRepos(raw: unknown): { valid: GraphifyRepoEntry[]; comments: string[] } {
  if (raw === undefined) return { valid: [], comments: [] };
  if (!Array.isArray(raw)) {
    return { valid: [], comments: ["# graphify_shipped_graph_age_seconds omitted: config.graphify_repos is not an array"] };
  }
  const comments: string[] = [];
  const seenCorpus = new Set<string>();
  const valid: GraphifyRepoEntry[] = [];
  raw.forEach((entry, i) => {
    if (!entry || typeof entry !== "object") {
      comments.push(`# graphify_shipped_graph_age_seconds omitted: graphify_repos[${i}] is not an object`);
      return;
    }
    const e = entry as Record<string, unknown>;
    const corpus = typeof e.corpus === "string" ? e.corpus.trim() : "";
    const repo_path = typeof e.repo_path === "string" ? e.repo_path.trim() : "";
    const default_branch = typeof e.default_branch === "string" && e.default_branch.trim() ? e.default_branch.trim() : undefined;
    if (!corpus || !repo_path) {
      comments.push(`# graphify_shipped_graph_age_seconds omitted: graphify_repos[${i}] needs non-empty string corpus + repo_path`);
      return;
    }
    // CR r2 (codex-adv): narrowed from "newline, double-quote, or backslash"
    // to line breaks only. The label path is already safe for quotes and
    // backslashes -- escLabel escapes backslash, newline, and double-quote,
    // and sample() applies it to every label value, so such a corpus renders
    // as a valid escaped label. The DANGER is the OMIT-COMMENT paths (this
    // duplicate skip and shippedGraphAgeOmitComment below), which interpolate
    // corpus RAW: a line break there injects a whole new exposition line.
    // (carriage return included -- codex-2; escLabel does not escape \r
    // either.) Rejecting quotes/backslashes was over-broad and made a valid
    // config silently lose both graph-age series (and its stale-graph alert).
    if (/[\r\n]/.test(corpus)) {
      comments.push(`# graphify_shipped_graph_age_seconds omitted: graphify_repos[${i}] corpus contains a line break (newline or carriage return) that would inject a new Prometheus exposition line in a comment`);
      return;
    }
    if (seenCorpus.has(corpus)) {
      comments.push(`# graphify_shipped_graph_age_seconds omitted: graphify_repos[${i}] duplicate corpus="${corpus}" (first occurrence wins)`);
      return;
    }
    seenCorpus.add(corpus);
    valid.push({ corpus, repo_path, default_branch });
  });
  return { valid, comments };
}

// CR round 2 default (codex-adv-4): with N repos queried SEQUENTIALLY, each up
// to GIT_QUERY_TIMEOUT_MS (10s) on a hung/degraded git spawn, the worst case
// was N*10s -- large enough on its own to blow past a typical Prometheus
// scrape_timeout and lose EVERY family in the response, not just this one.
// Queries below run CONCURRENTLY (bounding the worst case near a single
// query's own timeout regardless of N) AND are individually raced against
// this shared, shrinking budget, so a scrape returns well inside a normal
// external timeout even if some individual git spawn is still hung — the
// slow repo is reported via an omit comment (retried on the NEXT scrape,
// picked up fresh once its own query completes), never left to block the
// whole /metrics response.
const DEFAULT_SHIPPED_GRAPH_AGE_BUDGET_MS = 8000;

const BUDGET_EXCEEDED = Symbol("shipped-graph-age budget exceeded");

async function raceBudget<T>(promise: Promise<T>, budgetMs: number): Promise<T | typeof BUDGET_EXCEEDED> {
  if (budgetMs <= 0) return BUDGET_EXCEEDED;
  // CR: capture the budget timer and clear it once the race settles. Without
  // this, a WON race (the promise resolves first) leaves the setTimeout
  // pending for up to budgetMs, keeping the Node event loop alive after the
  // scrape is otherwise done.
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<typeof BUDGET_EXCEEDED>((resolve) => {
        timer = setTimeout(() => resolve(BUDGET_EXCEEDED), budgetMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function shippedGraphAgeMetrics(
  config: ObservabilityConfig,
  opts: Required<Pick<RenderMetricsOptions, "nowMs" | "cache">> & { graphAgeRunner?: ShippedGraphAgeRunner; budgetMs?: number },
): Promise<{ lines: string[]; comments: string[] }> {
  const { valid: repos, comments: validationComments } = validateGraphifyRepos(config.graphify_repos);
  if (repos.length === 0) return { lines: [], comments: validationComments };

  const runner = opts.graphAgeRunner ?? readShippedGraphCommitTime;
  const cacheMap = opts.cache.shippedGraphAge ?? (opts.cache.shippedGraphAge = {});
  const budgetMs = opts.budgetMs ?? DEFAULT_SHIPPED_GRAPH_AGE_BUDGET_MS;
  const started = performance.now();

  // Per-repo isolation: each entry's own try/catch means one failing/slow
  // repo can never reject (or stall resolving) the shared Promise.all below.
  const perRepo = await Promise.all(repos.map(async (entry) => {
    const { corpus, repo_path, default_branch } = entry;
    const ref = default_branch ?? DEFAULT_SHIPPED_GRAPH_REF;
    // Composite key (CR round 2, codex-2/codex-adv-3): repo_path ALONE
    // aliased two config entries watching different branches of the SAME
    // repo onto one cache slot -- the second entry silently inherited the
    // first's ref/result, and a default_branch EDIT in config was masked
    // until the (up to 60s) TTL happened to expire on its own.
    const cacheKey = `${repo_path}\0${ref}`;
    const cached = cacheMap[cacheKey];
    if (cached && opts.nowMs - cached.fetchedAtMs < CACHE_TTL_MS) {
      return { corpus, ref, ok: true as const, result: cached.value };
    }
    const remainingMs = Math.max(0, budgetMs - (performance.now() - started));
    try {
      const outcome = await raceBudget(runner(repo_path, ref), remainingMs);
      if (outcome === BUDGET_EXCEEDED) {
        return { corpus, ref, ok: false as const, message: `exceeded the ${budgetMs}ms shipped-graph query budget` };
      }
      cacheMap[cacheKey] = { key: cacheKey, fetchedAtMs: opts.nowMs, value: outcome };
      return { corpus, ref, ok: true as const, result: outcome };
    } catch (e) {
      delete cacheMap[cacheKey];
      const message = e instanceof Error && e.message ? e.message : "shipped-graph query failed";
      return { corpus, ref, ok: false as const, message };
    }
  }));

  const ageSamples: string[] = [];
  const tsSamples: string[] = [];
  const comments: string[] = [...validationComments];

  for (const entry of perRepo) {
    if (!entry.ok) {
      comments.push(shippedGraphAgeOmitComment(entry.corpus, entry.message));
      continue;
    }
    if (entry.result === null) {
      comments.push(shippedGraphAgeOmitComment(entry.corpus, `${SHIPPED_GRAPH_PATH} has no commit history on ${entry.ref} in this repo (never tracked, or wrong default_branch)`));
      continue;
    }
    const ageSeconds = Math.max(0, opts.nowMs / 1000 - entry.result.epochSeconds);
    ageSamples.push(sample("graphify_shipped_graph_age_seconds", { corpus: entry.corpus }, ageSeconds));
    tsSamples.push(sample("graphify_shipped_graph_commit_timestamp", { corpus: entry.corpus }, entry.result.epochSeconds));
  }

  const lines: string[] = [];
  addFamily(lines, "graphify_shipped_graph_age_seconds",
    "Seconds since the last commit touching the tracked graphify-out/graph.json (HIMMEL-1129) — the SHIPPED graph's real age, from git commit time, NOT file mtime (a pulled checkout's mtime is checkout time, always reading FRESH regardless of content age).",
    "gauge", ageSamples);
  addFamily(lines, "graphify_shipped_graph_commit_timestamp",
    "Epoch seconds of the last commit touching the tracked graphify-out/graph.json.",
    "gauge", tsSamples);
  return { lines, comments };
}

// HIMMEL-1000: real per-lane bank gauges. Each lanes.json lane that declares
// quota.bank fans out one series per live window of that bank; lanes without
// a machine-readable source (or whose bank has no live reading) emit an
// explicit omit comment: absent = dark, never fabricated.
function quotaMetrics(
  cfg: ObservabilityConfig,
  env: Record<string, string | undefined>,
  quotaLedgerPath: string,
  lanesPath: string,
  platform: NodeJS.Platform,
  nowMs: number,
): { lines: string[]; comments: string[] } {
  const targets = readLaneQuotaTargets(lanesPath);
  const comments: string[] = targets.without.map(
    (lane) => `# lane_quota_used_pct omitted: lane ${lane} has no machine-readable quota source`,
  );
  const home = env.HOME ?? homedir();
  const src = cfg.quota_sources ?? {};
  const readers: Record<BankId, () => BankResult> = {
    claude: () => readClaudeBank(src.claude_cache_path ?? defaultClaudeCachePath(env, platform), nowMs),
    codex: () => readCodexBank(src.codex_sessions_dir ?? join(home, ".codex", "sessions"), nowMs),
    glm: () => readGlmBank(src.glm_ledger_path ?? quotaLedgerPath, nowMs),
  };
  const banks = new Map<BankId, BankResult>();
  const samples: string[] = [];
  for (const { lane, bank } of targets.withBank) {
    let result = banks.get(bank);
    if (!result) {
      result = readers[bank]();
      banks.set(bank, result);
    }
    if (result.readings.length === 0) {
      comments.push(`# lane_quota_used_pct omitted: lane ${lane} (bank ${bank}): ${result.omitReason ?? "no live reading"}`);
      continue;
    }
    for (const reading of result.readings) {
      samples.push(sample("lane_quota_used_pct", { lane, bank, window: reading.window }, reading.usedPct));
    }
  }
  const lines: string[] = [];
  addFamily(lines, "lane_quota_used_pct", "Bank quota used percent per lanes.json lane and governing window, from live local sources.", "gauge", samples);
  return { lines, comments };
}

function defaultLanesPath(): string {
  return join(import.meta.dir, "..", "lanes", "lanes.json");
}

export function createExporterCache(): ExporterCache {
  return {};
}

export async function renderMetrics(options: RenderMetricsOptions = {}): Promise<string> {
  const started = performance.now();
  const env = options.env ?? process.env;
  const nowMs = options.nowMs ?? Date.now();
  const cache = options.cache ?? createExporterCache();
  const cfg = readConfig(options.configPath ?? configPath(env));
  const flowPath = options.flowLedgerPath ?? flowRunLedgerPath(env);
  const quotaPath = options.quotaLedgerPath ?? quotaGaugeLedgerPath(env);
  const lanesPath = options.lanesPath ?? defaultLanesPath();

  const lines: string[] = [];
  const flow = buildFlowMetrics(flowPath, cfg, nowMs);
  lines.push(...flow.lines);

  const sessionPath = options.sessionLedgerPath ?? sessionRunLedgerPath(env);
  const sessions = buildSessionMetrics(sessionPath, cfg, nowMs);
  lines.push(...sessions.lines);

  const fetchHealth = fetchHealthMetrics(options.fetchHealthStatePath ?? defaultFetchHealthStatePath(env));
  lines.push(...fetchHealth.comments);
  lines.push(...fetchHealth.lines);

  const scheduled = await scheduledTaskMetrics(cfg, {
    platform: options.platform ?? process.platform,
    nowMs,
    cache,
    schedulerRunner: options.schedulerRunner,
  });
  lines.push(...scheduled.comments);
  lines.push(...scheduled.lines);

  const host = await hostDetectorMetrics(cfg, {
    platform: options.platform ?? process.platform,
    nowMs,
    cache,
    hostDetectorRunner: options.hostDetectorRunner,
  });
  lines.push(...host.comments);
  lines.push(...host.lines);

  lines.push(...lunaMetrics(cfg, nowMs, cache));
  const lunaGit = await lunaGitMetrics(cfg, { nowMs, cache, gitRunner: options.gitRunner });
  lines.push(...lunaGit.comments);
  lines.push(...lunaGit.lines);

  const shippedGraph = await shippedGraphAgeMetrics(cfg, { nowMs, cache, graphAgeRunner: options.graphAgeRunner, budgetMs: options.graphAgeBudgetMs });
  lines.push(...shippedGraph.comments);
  lines.push(...shippedGraph.lines);

  const quota = quotaMetrics(cfg, env, quotaPath, lanesPath, options.platform ?? process.platform, nowMs);
  lines.push(...quota.comments);
  lines.push(...quota.lines);

  const durationS = (performance.now() - started) / 1000;
  addFamily(lines, "flow_exporter_scrape_duration_seconds", "Wall-clock duration of this exporter scrape.", "gauge", [
    sample("flow_exporter_scrape_duration_seconds", {}, durationS),
  ]);
  addFamily(lines, "flow_exporter_ledger_rows", "Parsed flow-run ledger rows inside the 14d window.", "gauge", [
    sample("flow_exporter_ledger_rows", {}, flow.ledgerRows),
  ]);
  addFamily(lines, "session_runs_ledger_rows", "Parsed session-run ledger rows inside the 14d window; exporter self-health parity with flow_exporter_ledger_rows.", "gauge", [
    sample("session_runs_ledger_rows", {}, sessions.ledgerRows),
  ]);

  return lines.join("\n") + "\n";
}

export function startFlowExporter(options: RenderMetricsOptions = {}): { stop: () => void; port: number } {
  const env = options.env ?? process.env;
  const portRaw = env.HIMMEL_FLOW_EXPORTER_PORT;
  const port = portRaw && /^\d+$/.test(portRaw) ? Number(portRaw) : DEFAULT_PORT;
  const cache = options.cache ?? createExporterCache();
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port,
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method !== "GET" || (url.pathname !== "/metrics" && url.pathname !== "/sessions.json")) {
        return new Response("not found\n", { status: 404 });
      }
      try {
        // HIMMEL-1052: the per-session table panel's data path. Same passive
        // read, same fold, just a shape Prometheus labels cannot carry
        // (session_id is unbounded cardinality). Still no writes anywhere.
        if (url.pathname === "/sessions.json") {
          return new Response(renderSessionsJson({ ...options, env }) + "\n", {
            headers: { "content-type": "application/json; charset=utf-8" },
          });
        }
        const body = await renderMetrics({ ...options, env, cache });
        return new Response(body, {
          headers: { "content-type": "text/plain; version=0.0.4; charset=utf-8" },
        });
      } catch {
        // Fail visible: a render error is a controlled 500, and Prometheus
        // surfaces it as a failed scrape rather than a hung request.
        return new Response("metrics render failed\n", { status: 500 });
      }
    },
  });
  return { stop: () => server.stop(true), port: server.port };
}

if (import.meta.main) {
  const server = startFlowExporter();
  console.log(`flow-exporter listening on 127.0.0.1:${server.port}`);
}
