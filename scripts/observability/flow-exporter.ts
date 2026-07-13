// HIMMEL-922 passive Prometheus exporter over local flow/quota ledgers.
// Pure reader: no ledger writes, no process control, no enforcement.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ledgerPath as flowRunLedgerPath, type FlowRunEnd, type FlowRunRow, type FlowRunStart } from "../telegram/flow-run-ledger";
import { ledgerPath as quotaGaugeLedgerPath, quotaGaugeRead } from "../telegram/quota-gauge";

const LOOKBACK_MS = 14 * 24 * 60 * 60 * 1000;
const DEFAULT_STALL_DEADLINE_SECONDS = 6 * 60 * 60;
const CACHE_TTL_MS = 60 * 1000;
const SCHEDULER_QUERY_TIMEOUT_MS = 10 * 1000;
const DEFAULT_PORT = 9877;

type FlowConfig = {
  name: string;
  cadence_seconds?: number;
  stall_deadline_seconds?: number;
};

type ObservabilityConfig = {
  flows?: FlowConfig[];
  expected_tasks?: string[];
  vault_path?: string;
};

type ScheduledTaskSample = {
  task: string;
  exists: 0 | 1;
  enabled?: 0 | 1;
  next_run_timestamp?: number | null;
};

type SchedulerRunner = (tasks: string[]) => ScheduledTaskSample[] | Promise<ScheduledTaskSample[]>;

type Cached<T> = {
  key: string;
  fetchedAtMs: number;
  value: T;
};

export type ExporterCache = {
  scheduler?: Cached<{ samples: ScheduledTaskSample[]; comments: string[] }>;
  luna?: Cached<{ samples: string[] }>;
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

type LaneRegistry = {
  lanes?: Array<{
    id?: string;
    budget?: Record<string, unknown>;
  }>;
};

function configPath(env: Record<string, string | undefined>): string {
  const override = env.HIMMEL_OBSERVABILITY_CONFIG;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "observability.json");
}

function readConfig(path: string): ObservabilityConfig {
  if (!existsSync(path)) return {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as ObservabilityConfig;
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function readJsonFile<T>(path: string): T | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;
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

function laneBudgetLabels(lanesPath: string): Map<string, Record<string, string>> {
  const registry = readJsonFile<LaneRegistry>(lanesPath);
  const labels = new Map<string, Record<string, string>>();
  for (const lane of registry?.lanes ?? []) {
    if (!lane.id || !lane.budget || typeof lane.budget !== "object") continue;
    const budgetLabels: Record<string, string> = {};
    for (const [key, value] of Object.entries(lane.budget)) {
      if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
        budgetLabels[key] = String(value);
      }
    }
    labels.set(lane.id, budgetLabels);
  }
  return labels;
}

function quotaMetrics(path: string, lanesPath: string, nowMs: number): string[] {
  if (!existsSync(path)) return [];
  let statuses: ReturnType<typeof quotaGaugeRead>;
  try {
    statuses = quotaGaugeRead({ path, nowMs });
  } catch {
    // A malformed quota ledger must not abort the whole scrape; the family
    // is simply omitted this round (absent = dark, never fabricated).
    return [];
  }
  const budget = laneBudgetLabels(lanesPath);
  const lines: string[] = [];
  const samples = Object.values(statuses)
    .filter((s) => typeof s.row?.used_pct === "number")
    .sort((a, b) => a.lane.localeCompare(b.lane))
    .map((s) => sample("lane_quota_used_pct", { lane: s.lane, ...(budget.get(s.lane) ?? {}) }, s.row!.used_pct!));
  addFamily(lines, "lane_quota_used_pct", "Latest observed quota used percentage per lane from the passive quota gauge ledger.", "gauge", samples);
  return lines;
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

  lines.push(...lunaMetrics(cfg, nowMs, cache));
  lines.push(...quotaMetrics(quotaPath, lanesPath, nowMs));

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
