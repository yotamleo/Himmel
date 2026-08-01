import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { renderMetrics, createExporterCache, parseHostDetectorJson, runGitDivergence, readShippedGraphCommitTime } from "./flow-exporter";
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
    lanesPath: join(tmp, "empty-lanes.json"),
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
  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json") });
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
    lanesPath: join(tmp, "no-lanes.json"),
  });
  expect(body).toContain('flow_run_outcome_total{flow="unconfigured-flow",outcome="stalled"} 1');
  expect(body).toContain('flow_run_in_flight{flow="unconfigured-flow"} 0');
});

test("lane quota fanout emits real bank readings per lanes.json lane and omits sourceless lanes", async () => {
  const flowLedger = join(tmp, "flow-runs.jsonl");
  const quotaLedger = join(tmp, "quota-gauge.jsonl");
  const lanes = join(tmp, "lanes.json");
  const config = join(tmp, "observability.json");
  const claudeCache = join(tmp, "statusline-usage-cache.json");
  const sessions = join(tmp, "codex-sessions");
  writeLines(flowLedger, []);
  const futureEpoch = Math.floor(NOW / 1000) + 3600;
  writeFileSync(claudeCache, JSON.stringify({
    five_hour: { utilization: 17, resets_at: String(futureEpoch) },
    seven_day: { utilization: 56, resets_at: String(futureEpoch) },
  }));
  const day = join(sessions, "2026", "07", "13");
  mkdirSync(day, { recursive: true });
  writeFileSync(join(day, "rollout-2026-07-13T08-00-03-x.jsonl"), JSON.stringify({
    timestamp: "t", type: "event_msg",
    payload: { type: "token_count", rate_limits: { primary: { used_percent: 76, window_minutes: 10080, resets_at: futureEpoch } } },
  }) + "\n");
  writeLines(quotaLedger, [serializeQuotaGauge(quota({ lane: "glm", used_pct: 3, reset_at: new Date(NOW + 3600_000).toISOString() }))]);
  writeFileSync(lanes, JSON.stringify({ lanes: [
    { id: "sonnet", quota: { bank: "claude" } },
    { id: "claudex", quota: { bank: "codex" } },
    { id: "glm", quota: { bank: "glm" } },
    { id: "ollama-local" },
  ] }));
  writeFileSync(config, JSON.stringify({ quota_sources: { claude_cache_path: claudeCache, codex_sessions_dir: sessions } }));

  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: flowLedger, quotaLedgerPath: quotaLedger, lanesPath: lanes, platform: "linux" });
  expect(body).toContain('# HELP lane_quota_used_pct Bank quota used percent per lanes.json lane and governing window, from live local sources.');
  expect(body).toContain('lane_quota_used_pct{bank="claude",lane="sonnet",window="5h"} 17');
  expect(body).toContain('lane_quota_used_pct{bank="claude",lane="sonnet",window="weekly"} 56');
  expect(body).toContain('lane_quota_used_pct{bank="codex",lane="claudex",window="weekly"} 76');
  expect(body).toContain('lane_quota_used_pct{bank="glm",lane="glm",window="5h"} 3');
  expect(body).toContain("# lane_quota_used_pct omitted: lane ollama-local has no machine-readable quota source");
});

test("lane quota fanout fans one bank read across every lane sharing that bank", async () => {
  const flowLedger = join(tmp, "flow-runs.jsonl");
  const lanes = join(tmp, "lanes.json");
  const config = join(tmp, "observability.json");
  const claudeCache = join(tmp, "statusline-usage-cache.json");
  writeLines(flowLedger, []);
  const futureEpoch = Math.floor(NOW / 1000) + 3600;
  writeFileSync(claudeCache, JSON.stringify({
    five_hour: { utilization: 17, resets_at: String(futureEpoch) },
    seven_day: { utilization: 56, resets_at: String(futureEpoch) },
  }));
  writeFileSync(lanes, JSON.stringify({ lanes: [
    { id: "haiku", quota: { bank: "claude" } },
    { id: "sonnet", quota: { bank: "claude" } },
    { id: "opus", quota: { bank: "claude" } },
    { id: "fable", quota: { bank: "claude" } },
  ] }));
  writeFileSync(config, JSON.stringify({ quota_sources: { claude_cache_path: claudeCache, codex_sessions_dir: join(tmp, "absent-sessions") } }));
  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: flowLedger, quotaLedgerPath: join(tmp, "absent-quota.jsonl"), lanesPath: lanes, platform: "linux" });
  for (const lane of ["haiku", "sonnet", "opus", "fable"]) {
    expect(body).toContain(`lane_quota_used_pct{bank="claude",lane="${lane}",window="5h"} 17`);
    expect(body).toContain(`lane_quota_used_pct{bank="claude",lane="${lane}",window="weekly"} 56`);
  }
});

test("lane quota fanout emits one omit comment per lane when a shared bank has no live reading", async () => {
  const flowLedger = join(tmp, "flow-runs.jsonl");
  const lanes = join(tmp, "lanes.json");
  const config = join(tmp, "observability.json");
  writeLines(flowLedger, []);
  writeFileSync(lanes, JSON.stringify({ lanes: [
    { id: "haiku", quota: { bank: "claude" } },
    { id: "sonnet", quota: { bank: "claude" } },
  ] }));
  writeFileSync(config, JSON.stringify({ quota_sources: { claude_cache_path: join(tmp, "absent-cache.json"), codex_sessions_dir: join(tmp, "absent-sessions") } }));
  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: flowLedger, quotaLedgerPath: join(tmp, "absent-quota.jsonl"), lanesPath: lanes, platform: "linux" });
  expect(body).toContain("# lane_quota_used_pct omitted: lane haiku (bank claude): statusline cache not found");
  expect(body).toContain("# lane_quota_used_pct omitted: lane sonnet (bank claude): statusline cache not found");
  expect(body).not.toContain('lane_quota_used_pct{');
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

  // platform/gitRunner pinned (HIMMEL-1199): this test only cares about the
  // synchronous luna backlog walk — without these, vault_path being set also
  // triggers a REAL host-detector powershell spawn and a REAL git spawn,
  // which is slow/environment-dependent and unrelated to what's asserted here.
  const body = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "linux", gitRunner: async () => ({ unpushed: null, uncommittedFiles: 0 }) });
  expect(body).toContain('luna_inbox_backlog{stage="unprocessed"} 2');
  expect(body).toContain('luna_inbox_backlog{stage="unharvested"} 1');
  expect(body).toContain("luna_done_graduations_month 1");
});

test("luna git divergence renders unpushed commits and uncommitted files from an injected runner", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  const vault = join(tmp, "vault");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ vault_path: vault }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    platform: "linux",
    gitRunner: async () => ({ unpushed: 9, uncommittedFiles: 2 }),
  });
  expect(body).toContain('# HELP luna_git_unpushed_commits');
  expect(body).toContain("luna_git_unpushed_commits 9");
  expect(body).toContain("luna_git_uncommitted_files 2");
});

test("luna git divergence omits only the unpushed sample when the branch has no upstream", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  const vault = join(tmp, "vault");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ vault_path: vault }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    platform: "linux",
    gitRunner: async () => ({ unpushed: null, uncommittedFiles: 0 }),
  });
  expect(body).not.toContain("luna_git_unpushed_commits ");
  expect(body).toContain("luna_git_uncommitted_files 0");
});

test("luna git divergence family is omitted, fail-soft, when the git runner errors or times out", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  const vault = join(tmp, "vault");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ vault_path: vault }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    platform: "linux",
    gitRunner: async () => { throw new Error("git status timed out"); },
  });
  expect(body).toContain("# luna_git_* omitted: git status timed out");
  expect(body).not.toContain("luna_git_unpushed_commits");
  expect(body).not.toContain("luna_git_uncommitted_files");
});

test("luna git divergence is omitted with no vault_path configured, without invoking the runner", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  writeLines(ledger, []);
  let called = false;

  const body = await renderMetrics({
    nowMs: NOW, configPath: join(tmp, "missing-observability.json"), flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    gitRunner: async () => { called = true; return { unpushed: 0, uncommittedFiles: 0 }; },
  });
  expect(called).toBe(false);
  expect(body).not.toContain("luna_git_");
});

// Shipped-graph age (HIMMEL-1129, option 3). config.graphify_repos is opt-in
// (undefined/empty -> family fully omitted, no obligation on single-station
// adopters); graphAgeRunner is injected so the render-level wiring is
// exercised without a real git spawn.

test("shipped-graph age is omitted entirely with no graphify_repos configured, without invoking the runner", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  writeLines(ledger, []);
  let called = false;

  const body = await renderMetrics({
    nowMs: NOW, configPath: join(tmp, "missing-observability.json"), flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async () => { called = true; return { epochSeconds: 0 }; },
  });
  expect(called).toBe(false);
  expect(body).not.toContain("graphify_shipped_graph_");
});

test("shipped-graph age renders age + commit timestamp per corpus from an injected runner", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ graphify_repos: [{ corpus: "himmel", repo_path: "C:/himmel" }] }));
  const commitEpoch = Math.floor(NOW / 1000) - 3600; // 1h old

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async () => ({ epochSeconds: commitEpoch }),
  });
  expect(body).toContain('# HELP graphify_shipped_graph_age_seconds');
  expect(body).toContain(`graphify_shipped_graph_age_seconds{corpus="himmel"} 3600`);
  expect(body).toContain(`graphify_shipped_graph_commit_timestamp{corpus="himmel"} ${commitEpoch}`);
});

test("shipped-graph age omits one corpus (never tracked there) while still rendering another", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "himmel", repo_path: "C:/himmel" },
      { corpus: "luna", repo_path: "C:/luna" },
    ],
  }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async (repoPath) => (repoPath === "C:/luna" ? null : { epochSeconds: Math.floor(NOW / 1000) }),
  });
  expect(body).toContain('graphify_shipped_graph_age_seconds{corpus="himmel"}');
  expect(body).not.toContain('corpus="luna"');
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted (corpus=luna): graphify-out/graph.json has no commit history on main in this repo (never tracked, or wrong default_branch)");
});

test("shipped-graph age passes each entry's default_branch through to the runner (falls back to main when absent)", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "himmel", repo_path: "C:/himmel", default_branch: "release/9.9" },
      { corpus: "luna", repo_path: "C:/luna" },
    ],
  }));
  const seenRefs: Record<string, string> = {};

  await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async (repoPath, ref) => { seenRefs[repoPath] = ref; return { epochSeconds: Math.floor(NOW / 1000) }; },
  });
  expect(seenRefs["C:/himmel"]).toBe("release/9.9");
  expect(seenRefs["C:/luna"]).toBe("main");
});

// CR round 2 (codex-2/codex-adv-3): the shipped-graph cache used to be keyed
// by repo_path ALONE, so two config entries watching different branches of
// the SAME repo aliased onto one cache slot -- the second entry silently
// inherited the first's result. The composite key (repo_path + ref) fixes
// this; these two tests exercise it directly.

test("shipped-graph age keys the cache by repo_path+ref: two corpora on the same repo, different branches, render independently", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "himmel-main", repo_path: "C:/himmel", default_branch: "main" },
      { corpus: "himmel-release", repo_path: "C:/himmel", default_branch: "release/9.9" },
    ],
  }));
  const calls: Array<{ repoPath: string; ref: string }> = [];
  const epochByRef: Record<string, number> = {
    main: Math.floor(NOW / 1000) - 100,
    "release/9.9": Math.floor(NOW / 1000) - 9999,
  };

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async (repoPath, ref) => { calls.push({ repoPath, ref }); return { epochSeconds: epochByRef[ref] }; },
  });
  // Both entries queried the runner -- neither was skipped as a cache "hit"
  // aliased from the other's slot.
  expect(calls.length).toBe(2);
  expect(body).toContain(`graphify_shipped_graph_age_seconds{corpus="himmel-main"} 100`);
  expect(body).toContain(`graphify_shipped_graph_age_seconds{corpus="himmel-release"} 9999`);
});

test("shipped-graph age cache: a repeat scrape with the SAME repo_path+ref reuses the cache (still just one runner call each)", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "himmel-main", repo_path: "C:/himmel", default_branch: "main" },
      { corpus: "himmel-release", repo_path: "C:/himmel", default_branch: "release/9.9" },
    ],
  }));
  let calls = 0;
  const cache = createExporterCache();
  const runner = async () => { calls++; return { epochSeconds: Math.floor(NOW / 1000) }; };

  await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), cache, graphAgeRunner: runner });
  await renderMetrics({ nowMs: NOW + 1000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), cache, graphAgeRunner: runner });
  expect(calls).toBe(2); // one per (repo_path, ref) pair, not one per scrape
});

// CR round 2 (codex-adv-4): sequential per-repo awaits meant N degraded repos
// = up to N * GIT_QUERY_TIMEOUT_MS before the family (and the WHOLE /metrics
// response) returned. Concurrency + a shared budget bound the family's total
// wall time near a single budget window regardless of N, with slow repos
// individually omitted (not blocking the fast ones or the overall response).

test("shipped-graph age runs per-repo queries CONCURRENTLY: total wall time stays near one slow call, not the sum of several", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  const DELAY_MS = 150;
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "a", repo_path: "C:/a" },
      { corpus: "b", repo_path: "C:/b" },
      { corpus: "c", repo_path: "C:/c" },
    ],
  }));

  // platform/gitRunner pinned (same reason as HIMMEL-1199's luna-git tests):
  // without these, this timing-sensitive test also triggers a REAL
  // host-detector powershell spawn + a real git spawn, polluting elapsedMs.
  const start = performance.now();
  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    platform: "linux", gitRunner: async () => ({ unpushed: null, uncommittedFiles: 0 }),
    graphAgeRunner: async () => { await new Promise((r) => setTimeout(r, DELAY_MS)); return { epochSeconds: Math.floor(NOW / 1000) }; },
  });
  const elapsedMs = performance.now() - start;

  // Sequential would take >= 3 * DELAY_MS (450ms); concurrent stays close to
  // one DELAY_MS window. A generous ceiling (well under the sequential sum)
  // keeps this from being flaky under CI/host scheduling jitter.
  expect(elapsedMs).toBeLessThan(DELAY_MS * 2.5);
  expect(body).toContain('graphify_shipped_graph_age_seconds{corpus="a"}');
  expect(body).toContain('graphify_shipped_graph_age_seconds{corpus="b"}');
  expect(body).toContain('graphify_shipped_graph_age_seconds{corpus="c"}');
});

test("shipped-graph age: a query exceeding the total budget is omitted with a budget-specific comment, without blocking a faster sibling", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "fast", repo_path: "C:/fast" },
      { corpus: "hung", repo_path: "C:/hung" },
    ],
  }));

  const start = performance.now();
  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    platform: "linux", gitRunner: async () => ({ unpushed: null, uncommittedFiles: 0 }),
    graphAgeBudgetMs: 40,
    graphAgeRunner: async (repoPath) => {
      if (repoPath === "C:/hung") {
        // Never resolves within the test lifetime -- simulates a truly hung
        // git spawn. The budget race must return without waiting on this.
        return new Promise(() => {});
      }
      return { epochSeconds: Math.floor(NOW / 1000) };
    },
  });
  const elapsedMs = performance.now() - start;

  expect(elapsedMs).toBeLessThan(2000); // returned promptly, did not hang the scrape
  expect(body).toContain('graphify_shipped_graph_age_seconds{corpus="fast"}');
  expect(body).not.toContain('corpus="hung"');
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted (corpus=hung): exceeded the 40ms shipped-graph query budget");
});

// Malformed graphify_repos config (CR round 1, codex-adv-5): this is
// operator-edited JSON, never trusted at the JSON.parse boundary — a bad
// shape must degrade to an omit comment, never a thrown exception (a crash
// here would 500 the WHOLE /metrics scrape, not just this one family).

test("shipped-graph age omits with a comment (not a crash) when graphify_repos is not an array", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ graphify_repos: { corpus: "himmel", repo_path: "C:/himmel" } }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async () => ({ epochSeconds: Math.floor(NOW / 1000) }),
  });
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted: config.graphify_repos is not an array");
  expect(body).not.toContain("graphify_shipped_graph_age_seconds{");
});

test("shipped-graph age skips an entry missing corpus/repo_path while still rendering a valid sibling", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "", repo_path: "C:/himmel" },
      { repo_path: "C:/no-corpus" },
      "not-even-an-object",
      { corpus: "luna", repo_path: "C:/luna" },
    ],
  }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async () => ({ epochSeconds: Math.floor(NOW / 1000) }),
  });
  expect(body).toContain('graphify_shipped_graph_age_seconds{corpus="luna"}');
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted: graphify_repos[0] needs non-empty string corpus + repo_path");
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted: graphify_repos[1] needs non-empty string corpus + repo_path");
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted: graphify_repos[2] is not an object");
});

test("shipped-graph age skips a duplicate corpus label (second occurrence) rather than emitting two samples", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({
    graphify_repos: [
      { corpus: "himmel", repo_path: "C:/himmel-a" },
      { corpus: "himmel", repo_path: "C:/himmel-b" },
    ],
  }));
  let calls = 0;

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async () => { calls++; return { epochSeconds: Math.floor(NOW / 1000) }; },
  });
  expect(calls).toBe(1);
  const matches = body.match(/graphify_shipped_graph_age_seconds\{corpus="himmel"\}/g) ?? [];
  expect(matches.length).toBe(1);
  expect(body).toContain('# graphify_shipped_graph_age_seconds omitted: graphify_repos[1] duplicate corpus="himmel" (first occurrence wins)');
});

test("shipped-graph age family is omitted, fail-soft, when the runner errors or times out", async () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const config = join(tmp, "observability.json");
  writeLines(ledger, []);
  writeFileSync(config, JSON.stringify({ graphify_repos: [{ corpus: "himmel", repo_path: "C:/himmel" }] }));

  const body = await renderMetrics({
    nowMs: NOW, configPath: config, flowLedgerPath: ledger,
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
    graphAgeRunner: async () => { throw new Error("git log timed out"); },
  });
  expect(body).toContain("# graphify_shipped_graph_age_seconds omitted (corpus=himmel): git log timed out");
  expect(body).not.toContain('graphify_shipped_graph_age_seconds{corpus="himmel"}');
  expect(body).not.toContain('graphify_shipped_graph_commit_timestamp{corpus="himmel"}');
});

// readShippedGraphCommitTime branch discrimination (mirrors runGitDivergence's
// discipline below): a genuinely untracked path returns null; ANY git failure
// (nonzero exit, non-numeric output) must PROPAGATE so the caller omits the
// family rather than reading a failure as "never tracked".

test("readShippedGraphCommitTime: happy path returns the last commit's epoch seconds", async () => {
  const result = await readShippedGraphCommitTime("C:/himmel", "main", gitCmd({
    log: { exitCode: 0, stdout: "1752400000\n" },
  }));
  expect(result).toEqual({ epochSeconds: 1752400000 });
});

test("readShippedGraphCommitTime: empty output (path never committed here) returns null", async () => {
  const result = await readShippedGraphCommitTime("C:/himmel", "main", gitCmd({
    log: { exitCode: 0, stdout: "" },
  }));
  expect(result).toBeNull();
});

test("readShippedGraphCommitTime: nonzero git exit propagates (not read as null-clean)", async () => {
  await expect(readShippedGraphCommitTime("C:/himmel", "main", gitCmd({
    log: { exitCode: 128, stderr: "fatal: not a git repository\n" },
  }))).rejects.toThrow();
});

test("readShippedGraphCommitTime: non-numeric output propagates (ambiguous, not null-clean)", async () => {
  await expect(readShippedGraphCommitTime("C:/himmel", "main", gitCmd({
    log: { exitCode: 0, stdout: "not-a-number\n" },
  }))).rejects.toThrow();
});

test("readShippedGraphCommitTime: passes the given ref explicitly (CR round 1, codex-adv-1) rather than reading the current checkout", async () => {
  let seenArgs: string[] = [];
  const run = async (args: string[]) => { seenArgs = args; return { exitCode: 0, stdout: "1700000000\n", stderr: "" }; };
  await readShippedGraphCommitTime("C:/himmel", "release/9.9", run);
  expect(seenArgs).toContain("release/9.9");
  // the ref must precede the `--` path separator (a revision, not a pathspec).
  expect(seenArgs.indexOf("release/9.9")).toBeLessThan(seenArgs.indexOf("--"));
});

// runGitDivergence branch discrimination (HIMMEL-1199 CR fix). A genuine
// "no upstream configured" omits ONLY the unpushed sample (unpushed: null);
// ANY other rev-list failure — timeout, spawn error, non-"no upstream" nonzero
// exit, non-numeric output — must PROPAGATE so the caller omits the WHOLE
// family, never fold into a false "clean" (unpushed: null) reading. The git
// command runner is injected so the branching is exercised without real git.
type GitCmdResult = { exitCode: number; stdout?: string; stderr?: string };
function gitCmd(responses: Record<string, GitCmdResult>) {
  return async (args: string[]) => {
    const r = responses[args[0]];
    if (!r) throw new Error(`unexpected git ${args.join(" ")}`);
    return { exitCode: r.exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  };
}

test("runGitDivergence: happy path reports the unpushed count and uncommitted file count", async () => {
  const result = await runGitDivergence("C:/vault", gitCmd({
    status: { exitCode: 0, stdout: " M a.md\n M b.md\n" },
    "rev-list": { exitCode: 0, stdout: "9\n" },
  }));
  expect(result).toEqual({ unpushed: 9, uncommittedFiles: 2 });
});

test("runGitDivergence: genuine 'no upstream configured' omits ONLY the unpushed sample (null)", async () => {
  const result = await runGitDivergence("C:/vault", gitCmd({
    status: { exitCode: 0, stdout: "" },
    "rev-list": { exitCode: 128, stderr: "fatal: no upstream configured for branch 'main'\n" },
  }));
  expect(result).toEqual({ unpushed: null, uncommittedFiles: 0 });
});

test("runGitDivergence: a rev-list nonzero exit that is NOT no-upstream propagates (family omitted, not null-clean)", async () => {
  await expect(runGitDivergence("C:/vault", gitCmd({
    status: { exitCode: 0, stdout: "" },
    "rev-list": { exitCode: 128, stderr: "fatal: bad revision '@{u}..HEAD'\n" },
  }))).rejects.toThrow();
});

test("runGitDivergence: a thrown rev-list (spawn error / timeout) propagates rather than reading clean", async () => {
  const run = async (args: string[]) => {
    if (args[0] === "status") return { exitCode: 0, stdout: "", stderr: "" };
    throw new Error("spawn git ENOENT");
  };
  await expect(runGitDivergence("C:/vault", run)).rejects.toThrow(/ENOENT/);
});

test("runGitDivergence: exit 0 but non-numeric rev-list output propagates (ambiguous, not null-clean)", async () => {
  await expect(runGitDivergence("C:/vault", gitCmd({
    status: { exitCode: 0, stdout: "" },
    "rev-list": { exitCode: 0, stdout: "not-a-number\n" },
  }))).rejects.toThrow();
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
  const first = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "win32", schedulerRunner: runner, cache });
  const second = await renderMetrics({ nowMs: NOW + 1000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "win32", schedulerRunner: runner, cache });
  expect(calls).toBe(1);
  expect(first).toContain('scheduled_task_exists{task="himmel-pipeline-harvest"} 1');
  expect(first).toContain('scheduled_task_enabled{task="himmel-pipeline-harvest"} 1');
  expect(first).toContain('scheduled_task_next_run_timestamp{task="himmel-pipeline-harvest"} 1783915200');
  expect(second).toContain('scheduled_task_exists{task="himmel-pipeline-synthesize"} 0');

  const linux = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "linux", cache: createExporterCache() });
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
    quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"),
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
  const base = { nowMs: NOW, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json") };

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

  const first = await renderMetrics({ nowMs: NOW, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "win32", hostDetectorRunner: runner, cache });
  const second = await renderMetrics({ nowMs: NOW + 1000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "win32", hostDetectorRunner: runner, cache });
  const third = await renderMetrics({ nowMs: NOW + 3000, configPath: config, flowLedgerPath: ledger, quotaLedgerPath: join(tmp, "none"), lanesPath: join(tmp, "no-lanes.json"), platform: "win32", hostDetectorRunner: runner, cache });

  expect(calls).toBe(2);
  expect(first).toContain('agent_tree_rss_bytes{class="claude"} 1000');
  expect(second).toContain('agent_tree_process_count{class="claude"} 1');
  expect(third).toContain("# agent_tree_*/orphan_* omitted: expired refresh failed");
  expect(third).not.toContain("agent_tree_rss_bytes");
});
