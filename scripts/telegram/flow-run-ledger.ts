// scripts/telegram/flow-run-ledger.ts
// HIMMEL-921 flow-run lifecycle ledger. TypeScript twin of
// scripts/lib/flow-run-ledger.sh; serializers are byte-identical by contract.
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir, tmpdir } from "node:os";

export type FlowRunOutcome = "complete" | "truncated" | "error" | "parked";
export type FlowRunLane = string | null;

export const FLOW_RUN_ROTATE_BYTES = 10 * 1024 * 1024;
export const FLOW_RUN_TRUNCATION_SIGNATURES: RegExp[] = [
  /Background tasks still running.*terminating/,
];

export const FLOW_RUN_START_FIELDS = [
  "v", "ev", "flow", "run_id", "fired_at", "host", "lane", "model", "task_name", "log_path", "pid",
] as const;

export const FLOW_RUN_END_FIELDS = [
  "v", "ev", "flow", "run_id", "ended_at", "exit_code", "outcome", "items_processed", "note",
] as const;

export type FlowRunStart = {
  v: 1;
  ev: "start";
  flow: string;
  run_id: string;
  fired_at: string;
  host: string | null;
  lane: FlowRunLane;
  model: string | null;
  task_name: string | null;
  log_path: string | null;
  pid: number | null;
};

export type FlowRunEnd = {
  v: 1;
  ev: "end";
  flow: string;
  run_id: string;
  ended_at: string;
  exit_code: number | null;
  outcome: FlowRunOutcome;
  items_processed: number | null;
  note: string | null;
};

export type FlowRunRow = FlowRunStart | FlowRunEnd;

export function ledgerPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_FLOW_RUNS_LEDGER;
  if (override && override.trim()) return override;
  const home = env.HOME ?? homedir();
  return join(home, ".himmel", "flow-runs.jsonl");
}

function jsonStr(s: string): string {
  return '"' + s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t") + '"';
}

function jsonVal(v: number | string | null | undefined): string {
  if (v === null || v === undefined) return "null";
  if (typeof v === "number") return String(v);
  return jsonStr(v);
}

export function serializeFlowRunStart(row: FlowRunStart): string {
  const vals = [
    jsonVal(row.v),
    jsonStr(row.ev),
    jsonStr(row.flow),
    jsonStr(row.run_id),
    jsonStr(row.fired_at),
    jsonVal(row.host),
    jsonVal(row.lane),
    jsonVal(row.model),
    jsonVal(row.task_name),
    jsonVal(row.log_path),
    jsonVal(row.pid),
  ];
  const pairs = FLOW_RUN_START_FIELDS.map((k, i) => `"${k}":${vals[i]}`);
  return "{" + pairs.join(",") + "}";
}

export function serializeFlowRunEnd(row: FlowRunEnd): string {
  const vals = [
    jsonVal(row.v),
    jsonStr(row.ev),
    jsonStr(row.flow),
    jsonStr(row.run_id),
    jsonStr(row.ended_at),
    jsonVal(row.exit_code),
    jsonStr(row.outcome),
    jsonVal(row.items_processed),
    jsonVal(row.note),
  ];
  const pairs = FLOW_RUN_END_FIELDS.map((k, i) => `"${k}":${vals[i]}`);
  return "{" + pairs.join(",") + "}";
}

export function serializeFlowRun(row: FlowRunRow): string {
  return row.ev === "start" ? serializeFlowRunStart(row) : serializeFlowRunEnd(row);
}

function lastLines(text: string, n: number): string {
  const lines = text.split(/\r?\n/);
  return lines.slice(Math.max(0, lines.length - n)).join("\n");
}

// requiredMarker (HIMMEL-1716): a zero exit whose log tail lacks the bare
// completion marker line is a parked/blocked leg, not a complete one (mirrors
// flow_run_classify in scripts/lib/flow-run-ledger.sh). A missing log is no marker.
export function classifyOutcome(exitCode: number, logPath?: string | null, extraMarkerRegex?: string, requiredMarker?: string): FlowRunOutcome {
  if (exitCode !== 0) return "error";
  if (!logPath || !existsSync(logPath)) return requiredMarker ? "parked" : "complete";
  const tail = lastLines(readFileSync(logPath, "utf8"), 50);
  if (FLOW_RUN_TRUNCATION_SIGNATURES.some((re) => re.test(tail))) return "truncated";
  if (extraMarkerRegex) {
    try {
      if (new RegExp(extraMarkerRegex).test(tail)) return "truncated";
    } catch {
      // invalid extra regex: ignore it, but the required-marker check below
      // still applies (coderabbit #1762 -- mirrors the bash classifier).
    }
  }
  if (requiredMarker && !tail.split(/\r?\n/).some((l) => l === requiredMarker)) return "parked";
  return "complete";
}

export function appendFlowRun(row: FlowRunRow, path?: string): void {
  let p = path ?? ledgerPath();
  // HIMMEL-2241 (mirrors the bash twin's flow_run_append guard): a missed test
  // redirect must fail LOUD, never silently pollute production telemetry.
  // run-shell-tests.sh exports HIMMEL_SUITE_LOCK_HELD for the whole suite run
  // and children inherit it, so a write reaching here with the marker set and
  // NO explicit path or env override is a fixture that fell back to
  // ~/.himmel/flow-runs.jsonl. Quarantine it in the suite's own temp root.
  if (path === undefined && process.env.HIMMEL_SUITE_LOCK_HELD && !process.env.HIMMEL_FLOW_RUNS_LEDGER) {
    // TMPDIR first, so this lands in the same per-suite temp root the bash
    // twin uses; os.tmpdir() rather than the twin's "/tmp" literal for the
    // fallback, because a native Windows node process has no /tmp.
    p = join(process.env.TMPDIR || tmpdir(), "flow-runs-unredirected.jsonl");
    console.error(
      `[flow-run-ledger] HIMMEL-2241 WARN: shell suite running (HIMMEL_SUITE_LOCK_HELD set) with no HIMMEL_FLOW_RUNS_LEDGER override; row quarantined in ${p} instead of the production ledger. Export HIMMEL_FLOW_RUNS_LEDGER to a scratch path in the fixture that spawned this wrapper.`,
    );
  }
  const dir = dirname(p);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  if (existsSync(p) && statSync(p).size >= FLOW_RUN_ROTATE_BYTES) {
    try {
      rmSync(p + ".1", { force: true });
      renameSync(p, p + ".1");
    } catch {
      // best-effort rotation, mirroring the bash twin's `mv -f ... || true`:
      // a concurrent writer may have already rotated the file away.
    }
  }
  appendFileSync(p, serializeFlowRun(row) + "\n", "utf8");
}
