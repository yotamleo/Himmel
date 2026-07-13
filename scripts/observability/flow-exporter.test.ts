import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderMetrics, createExporterCache, parseHostDetectorJson } from "./flow-exporter";
import { serializeFlowRunEnd, serializeFlowRunStart, type FlowRunEnd, type FlowRunStart } from "../telegram/flow-run-ledger";
import { serializeQuotaGauge, type QuotaGaugeRecord } from "../telegram/quota-gauge";

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "flow-exporter-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const NOW = Date.parse("2026-07-13T12:00:00Z");

function epoch(iso: string): number {
  return Math.floor(Date.parse(iso) / 1000);
}

function flowStart(flow: string, runId: string, firedAt: string): FlowRunStart {
  return {
    v: 1,
    ev: "start",
    flow,
    run_id: runId,
    fired_at: firedAt,
    host: "test-host",
    lane: "claude",
    model: "opus",
    task_name: null,
    log_path: null,
    pid: 123,
  };
}

function flowEnd(flow: string, runId: string, endedAt: string, outcome: FlowRunEnd["outcome"], items: number | null): FlowRunEnd {
  return {
    v: 1,
    ev: "end",
    flow,
    run_id: runId,
    ended_at: endedAt,
    exit_code: outcome === "error" ? 1 : 0,
    outcome,
    items_processed: items,
    note: null,
  };
}

function quota(partial: Partial<QuotaGaugeRecord>): QuotaGaugeRecord {
  return {
    v: 1,
    ts: "2026-07-13T11:59:30Z",
    lane: "glm",
    source: "test",
    used_pct: 62,
    window: "5h",
    reset_at: null,
    tier: null,
    glm_peak: false,
    note: null,
    ...partial,
  };
}

function writeLines(path: string, lines: string[]): void {
  writeFileSync(path, lines.join("\n") + "\n");
}

function normalizeMetrics(body: string): string {
  return body.replace(/^flow_exporter_scrape_duration_seconds .+$/m, "flow_exporter_scrape_duration_seconds 0");
}

test("golden scrape folds active and rotated flow ledgers", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeFileSync(config, JSON.stringify({
    flows: [
      { name: "pipeline-harvest", cadence_seconds: 86400, stall_deadline_seconds: 7200 },
      { name: "pipeline-synthesize", cadence_seconds: 3600 },
      { name: "pipeline-silent", cadence_seconds: 60 },
    ],
  }));
  writeLines(ledger + ".1", [
    serializeFlowRunStart(flowStart("pipeline-harvest", "h1", "2026-07-12T09:00:00Z")),
    serializeFlowRunEnd(flowEnd("pipeline-harvest", "h1", "2026-07-12T10:00:00Z", "complete", 17)),
    serializeFlowRunStart(flowStart("pipeline-synthesize", "s1", "2026-07-12T11:00:00Z")),
    serializeFlowRunEnd(flowEnd("pipeline-synthesize", "s1", "2026-07-12T11:05:00Z", "truncated", null)),
  ]);
  writeLines(ledger, [
    serializeFlowRunStart(flowStart("pipeline-harvest", "h2", "2026-07-13T08:00:00Z")),
    serializeFlowRunEnd(flowEnd("pipeline-harvest", "h2", "2026-07-13T08:15:00Z", "error", 3)),
    serializeFlowRunStart(flowStart("pipeline-harvest", "h3", "2026-07-13T11:50:00Z")),
  ]);

  const body = normalizeMetrics(await renderMetrics({
    nowMs: NOW,
    configPath: config,
    flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "missing-quota.jsonl"),
    platform: "linux",
  }));

  expect(body).toBe(`# HELP flow_run_last_success_timestamp Epoch seconds of the last complete run end row in the 14d ledger window.
# TYPE flow_run_last_success_timestamp gauge
flow_run_last_success_timestamp{flow="pipeline-harvest"} ${epoch("2026-07-12T10:00:00Z")}
# HELP flow_run_outcome_total Runs by outcome in the sliding 14d ledger window; exporter restarts and window slides can reset this counter.
# TYPE flow_run_outcome_total counter
flow_run_outcome_total{flow="pipeline-harvest",outcome="complete"} 1
flow_run_outcome_total{flow="pipeline-harvest",outcome="truncated"} 0
flow_run_outcome_total{flow="pipeline-harvest",outcome="error"} 1
flow_run_outcome_total{flow="pipeline-harvest",outcome="stalled"} 0
flow_run_outcome_total{flow="pipeline-synthesize",outcome="complete"} 0
flow_run_outcome_total{flow="pipeline-synthesize",outcome="truncated"} 1
flow_run_outcome_total{flow="pipeline-synthesize",outcome="error"} 0
flow_run_outcome_total{flow="pipeline-synthesize",outcome="stalled"} 0
# HELP flow_run_items_processed Last ended run items_processed value; null is omitted.
# TYPE flow_run_items_processed gauge
flow_run_items_processed{flow="pipeline-harvest"} 3
# HELP flow_run_items_processed_total Sum of non-null items_processed values in the sliding 14d ledger window.
# TYPE flow_run_items_processed_total counter
flow_run_items_processed_total{flow="pipeline-harvest"} 20
# HELP flow_run_in_flight Unpaired start rows still within the flow stall deadline.
# TYPE flow_run_in_flight gauge
flow_run_in_flight{flow="pipeline-harvest"} 1
flow_run_in_flight{flow="pipeline-silent"} 0
flow_run_in_flight{flow="pipeline-synthesize"} 0
# agent_tree_*/orphan_* omitted: platform has no Windows process tree API
# HELP flow_exporter_scrape_duration_seconds Wall-clock duration of this exporter scrape.
# TYPE flow_exporter_scrape_duration_seconds gauge
flow_exporter_scrape_duration_seconds 0
# HELP flow_exporter_ledger_rows Parsed flow-run ledger rows inside the 14d window.
# TYPE flow_exporter_ledger_rows gauge
flow_exporter_ledger_rows 7
`);
  expect(body).not.toContain('flow_run_last_success_timestamp{flow="pipeline-silent"');
  expect(body).not.toContain('flow_run_items_processed{flow="pipeline-synthesize"');
});

test("stall inference separates expired unpaired starts from in-flight starts", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeFileSync(config, JSON.stringify({ flows: [{ name: "short-flow", cadence_seconds: 100 }] }));
  writeLines(ledger, [
    serializeFlowRunStart(flowStart("short-flow", "old", "2026-07-13T11:55:00Z")),
    serializeFlowRunStart(flowStart("short-flow", "new", "2026-07-13T11:58:20Z")),
  ]);
  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none") });
  expect(body).toContain('flow_run_outcome_total{flow="short-flow",outcome="stalled"} 1');
  expect(body).toContain('flow_run_in_flight{flow="short-flow"} 1');
});

test("active ledger without config uses default six-hour stall deadline", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  writeLines(ledger, [
    serializeFlowRunStart(flowStart("unconfigured-flow", "old", "2026-07-13T04:59:00Z")),
  ]);
  const body = await renderMetrics({
    nowMs: NOW,
    configPath: join(tmp, "missing-observability.json"),
    flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"),
  });
  expect(body).toContain('flow_run_outcome_total{flow="unconfigured-flow",outcome="stalled"} 1');
  expect(body).toContain('flow_run_in_flight{flow="unconfigured-flow"} 0');
});

test("quota gauge ledger is re-exported through quotaGaugeRead", async () => {
  const flowLedger = join(tmp, "flow-runs.jsonl");
  const quotaLedger = join(tmp, "quota-gauge.jsonl");
  const lanes = join(tmp, "lanes.json");
  writeLines(flowLedger, []);
  writeLines(quotaLedger, [serializeQuotaGauge(quota({ lane: "glm", used_pct: 62 }))]);
  writeFileSync(lanes, JSON.stringify({ lanes: [{ id: "glm", budget: { posture: "conserve" } }] }));
  const body = await renderMetrics({ nowMs: NOW, flowLedgerPath: flowLedger, quotaLedgerPath: quotaLedger, lanesPath: lanes });
  expect(body).toContain('# HELP lane_quota_used_pct Latest observed quota used percentage per lane from the passive quota gauge ledger.');
  expect(body).toContain('lane_quota_used_pct{lane="glm",posture="conserve"} 62');
});

test("luna backlog counts inbox stages and monthly graduations, read-only", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  const vault = join(tmp, "vault");
  const clippings = join(vault, "Clippings");
  const month = new Date(NOW).toISOString().slice(0, 7);
  const done = join(clippings, "_done", month);
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ vault_path: vault }));
  mkdirSync(done, { recursive: true });
  writeFileSync(join(clippings, "a.md"), "---\nprocessed: true\nharvested_at: 2026-07-01\n---\nbody\n");
  writeFileSync(join(clippings, "b.md"), "---\nharvested_at: 2026-07-02\n---\nbody\n");
  writeFileSync(join(clippings, "c.md"), "---\ntitle: raw\n---\nbody\n");
  writeFileSync(join(done, "old.md"), "graduated\n");

  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none") });
  expect(body).toContain('luna_inbox_backlog{stage="unprocessed"} 2');
  expect(body).toContain('luna_inbox_backlog{stage="unharvested"} 1');
  expect(body).toContain("luna_done_graduations_month 1");
});

test("scheduled-task scrape is platform-gated and TTL-cached", async () => {
  const config = join(tmp, "observability.json");
  const ledger = join(tmp, "flow-runs.jsonl");
  writeFileSync(config, JSON.stringify({ expected_tasks: ["himmel-pipeline-harvest", "himmel-pipeline-synthesize"] }));
  writeLines(ledger, []);
  const cache = createExporterCache();
  let calls = 0;
  const runner = () => {
    calls++;
    return [
      { task: "himmel-pipeline-harvest", exists: 1 as const, enabled: 1 as const, next_run_timestamp: 1783915200 },
      { task: "himmel-pipeline-synthesize", exists: 0 as const, enabled: 0 as const, next_run_timestamp: null },
    ];
  };
  const first = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), platform: "win32", schedulerRunner: runner, cache });
  const second = await renderMetrics({ nowMs: NOW + 1000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), platform: "win32", schedulerRunner: runner, cache });
  expect(calls).toBe(1);
  expect(first).toContain('scheduled_task_exists{task="himmel-pipeline-harvest"} 1');
  expect(first).toContain('scheduled_task_enabled{task="himmel-pipeline-harvest"} 1');
  expect(first).toContain('scheduled_task_next_run_timestamp{task="himmel-pipeline-harvest"} 1783915200');
  expect(second).toContain('scheduled_task_exists{task="himmel-pipeline-synthesize"} 0');

  const linux = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), platform: "linux", cache: createExporterCache() });
  expect(linux).toContain("# scheduled_task_* omitted: platform has no Windows Scheduled Tasks API");
  expect(linux).not.toContain("scheduled_task_exists");
});

test("host detector JSON parser normalizes detector output", () => {
  const parsed = parseHostDetectorJson(JSON.stringify({
    trees: [
      { class: "claude", rss_bytes: 1234, process_count: 2 },
      { class: "", rss_bytes: 999, process_count: 1 },
      { class: "other", rss_bytes: -1, process_count: Number.NaN },
    ],
    orphans: [
      { class: "codex-fleet", count: 3 },
      { class: "ignored" },
    ],
  }));
  expect(parsed.trees).toEqual([
    { class: "claude", rss_bytes: 1234, process_count: 2 },
    { class: "other", rss_bytes: 0, process_count: 0 },
  ]);
  expect(parsed.orphans).toEqual([
    { class: "codex-fleet", count: 3 },
    { class: "ignored", count: 0 },
  ]);
});

test("host detector metrics render from fixture data", async () => {
  const config = join(tmp, "observability.json");
  const ledger = join(tmp, "flow-runs.jsonl");
  writeFileSync(config, JSON.stringify({ host_detectors_ttl_seconds: 30 }));
  writeLines(ledger, []);

  const body = await renderMetrics({
    nowMs: NOW,
    configPath: config,
    flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"),
    platform: "win32",
    hostDetectorRunner: () => JSON.stringify({
      trees: [
        { class: "claude", rss_bytes: 2048, process_count: 2 },
        { class: "other", rss_bytes: 512, process_count: 1 },
      ],
      orphans: [
        { class: "codex-fleet", count: 1 },
      ],
    }),
  });

  expect(body).toContain('# HELP agent_tree_rss_bytes Working-set bytes summed by agent process tree class.');
  expect(body).toContain('agent_tree_rss_bytes{class="claude"} 2048');
  expect(body).toContain('agent_tree_process_count{class="other"} 1');
  expect(body).toContain('orphan_process_count{class="codex-fleet"} 1');
});

test("host detector scrape is platform-gated and fail-soft on runner errors", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  writeLines(ledger, []);
  const base = { nowMs: NOW, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none") };

  const linux = await renderMetrics({ ...base, platform: "linux", hostDetectorRunner: () => { throw new Error("should not run"); } });
  expect(linux).toContain("# agent_tree_*/orphan_* omitted: platform has no Windows process tree API");
  expect(linux).not.toContain("agent_tree_rss_bytes");

  const failed = await renderMetrics({
    ...base,
    platform: "win32",
    hostDetectorRunner: () => { throw new Error("powershell failed"); },
  });
  expect(failed).toContain("# agent_tree_*/orphan_* omitted: powershell failed");
  expect(failed).not.toContain("orphan_process_count");
});

test("host detector scrape uses TTL cache and drops cache on refresh failure", async () => {
  const config = join(tmp, "observability.json");
  const ledger = join(tmp, "flow-runs.jsonl");
  writeFileSync(config, JSON.stringify({ host_detectors_ttl_seconds: 2 }));
  writeLines(ledger, []);
  const cache = createExporterCache();
  let calls = 0;
  const runner = () => {
    calls++;
    if (calls === 2) throw new Error("expired refresh failed");
    return {
      trees: [{ class: "claude", rss_bytes: 1000, process_count: 1 }],
      orphans: [{ class: "codex-fleet", count: 0 }],
    };
  };

  const first = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), platform: "win32", hostDetectorRunner: runner, cache });
  const second = await renderMetrics({ nowMs: NOW + 1000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), platform: "win32", hostDetectorRunner: runner, cache });
  const third = await renderMetrics({ nowMs: NOW + 3000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), platform: "win32", hostDetectorRunner: runner, cache });

  expect(calls).toBe(2);
  expect(first).toContain('agent_tree_rss_bytes{class="claude"} 1000');
  expect(second).toContain('agent_tree_process_count{class="claude"} 1');
  expect(third).toContain("# agent_tree_*/orphan_* omitted: expired refresh failed");
  expect(third).not.toContain("agent_tree_rss_bytes");
});
