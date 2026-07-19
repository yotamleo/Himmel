// HIMMEL-922 passive Prometheus exporter over local flow/quota ledgers.
// Pure reader: no ledger writes, no process control, no enforcement.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ledgerPath as flowRunLedgerPath, type FlowRunEnd, type FlowRunRow, type FlowRunStart } from "../telegram/flow-run-ledger";
import { ledgerPath as quotaGaugeLedgerPath } from "../telegram/quota-gauge";
import { defaultClaudeCachePath, readClaudeBank, readCodexBank, readGlmBank, readLaneQuotaTargets, type BankId, type BankResult } from "./quota-sources";

const LOOKBACK_MS = 14 * 24 * 60 * 60 * 1000;
const DEFAULT_STALL_DEADLINE_SECONDS = 6 * 60 * 60;
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
};

export type RenderMetricsOptions = {
  env?: Record<string, string | undefined>;
  nowMs?: number;
  configPath?: string;
  flowLedgerPath?: string;
  quotaLedgerPath?: string;
  lanesPath?: string;
  platform?: NodeJS.Platform;
  schedulerRunner?: SchedulerRunner;
  hostDetectorRunner?: HostDetectorRunner;
  gitRunner?: GitRunner;
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

  return { lines, ledgerRows };
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
      if (req.method !== "GET" || url.pathname !== "/metrics") {
        return new Response("not found\n", { status: 404 });
      }
      try {
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
