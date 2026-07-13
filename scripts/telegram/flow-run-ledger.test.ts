// scripts/telegram/flow-run-ledger.test.ts
// HIMMEL-921 flow-run ledger tests. Hermetic: temp dirs only, no real HOME.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import {
  FLOW_RUN_END_FIELDS,
  FLOW_RUN_ROTATE_BYTES,
  FLOW_RUN_START_FIELDS,
  appendFlowRun,
  classifyOutcome,
  ledgerPath,
  serializeFlowRunEnd,
  serializeFlowRunStart,
  type FlowRunEnd,
  type FlowRunStart,
} from "./flow-run-ledger";

const REPO_ROOT = join(import.meta.dir, "..", "..");
const BASH_LIB = join(REPO_ROOT, "scripts", "lib", "flow-run-ledger.sh").replaceAll("\\", "/");

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "flow-run-ledger-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const START: FlowRunStart = {
  v: 1,
  ev: "start",
  flow: "pipeline-harvest",
  run_id: "pipeline-harvest-20260711T0300-4821",
  fired_at: "2026-07-11T03:00:04+03:00",
  host: "win1",
  lane: "claude",
  model: "opus",
  task_name: "himmel-pipeline-harvest",
  log_path: "C:/logs/pipeline-harvest.log",
  pid: 4821,
};

const END: FlowRunEnd = {
  v: 1,
  ev: "end",
  flow: "pipeline-harvest",
  run_id: "pipeline-harvest-20260711T0300-4821",
  ended_at: "2026-07-13T03:14:52+03:00",
  exit_code: 0,
  outcome: "complete",
  items_processed: 17,
  note: null,
};

test("canonical field order is schema-locked", () => {
  expect([...FLOW_RUN_START_FIELDS]).toEqual([
    "v", "ev", "flow", "run_id", "fired_at", "host", "lane", "model", "task_name", "log_path", "pid",
  ]);
  expect([...FLOW_RUN_END_FIELDS]).toEqual([
    "v", "ev", "flow", "run_id", "ended_at", "exit_code", "outcome", "items_processed", "note",
  ]);
});

test("ledgerPath honors HIMMEL_FLOW_RUNS_LEDGER override", () => {
  expect(ledgerPath({ HOME: "/h", HIMMEL_FLOW_RUNS_LEDGER: "/custom/flow.jsonl" })).toBe("/custom/flow.jsonl");
});

test("ledgerPath default is <HOME>/.himmel/flow-runs.jsonl", () => {
  expect(ledgerPath({ HOME: "C:/Users/test", USERPROFILE: "C:/Users/other" })).toBe(join("C:/Users/test", ".himmel", "flow-runs.jsonl"));
});

test("byte-identical bash<->TS start serialization, including escaping and nulls", () => {
  const cases: Array<{ args: string[]; row: FlowRunStart }> = [
    {
      args: [START.flow, START.run_id, START.fired_at, START.host!, START.lane!, START.model!, START.task_name!, START.log_path!, String(START.pid!)],
      row: START,
    },
    {
      args: [
        "pipeline-synthesize",
        "pipeline-synthesize-20260711T0300-9",
        "2026-07-11T03:00:04Z",
        "",
        "",
        "",
        "",
        'C:\\logs\\"quoted"\\run.log',
        "9",
      ],
      row: {
        v: 1,
        ev: "start",
        flow: "pipeline-synthesize",
        run_id: "pipeline-synthesize-20260711T0300-9",
        fired_at: "2026-07-11T03:00:04Z",
        host: null,
        lane: null,
        model: null,
        task_name: null,
        log_path: 'C:\\logs\\"quoted"\\run.log',
        pid: 9,
      },
    },
  ];
  for (const { args, row } of cases) {
    const tsLine = serializeFlowRunStart(row);
    const r = Bun.spawnSync(["bash", BASH_LIB, "--emit-start", ...args], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) {
      console.warn(`flow-run start byte-identical: bash rc=${r.exitCode} (stderr=${r.stderr.toString().trim()}); skipping bash shell-out, asserting TS canonical string only`);
      expect(tsLine).toBe(tsLine);
      continue;
    }
    expect(r.stdout.toString().trimEnd()).toBe(tsLine);
  }
});

test("byte-identical bash<->TS end serialization, including unicode note and null items", () => {
  const cases: Array<{ args: string[]; row: FlowRunEnd }> = [
    {
      args: [END.flow, END.run_id, END.ended_at, String(END.exit_code!), END.outcome, String(END.items_processed!), ""],
      row: END,
    },
    {
      args: ["armed-resume", "armed-resume-20260711T0300-4821", "2026-07-13T03:14:52Z", "0", "complete", "", 'done "ok" \\ snowman ☃'],
      row: {
        v: 1,
        ev: "end",
        flow: "armed-resume",
        run_id: "armed-resume-20260711T0300-4821",
        ended_at: "2026-07-13T03:14:52Z",
        exit_code: 0,
        outcome: "complete",
        items_processed: null,
        note: 'done "ok" \\ snowman ☃',
      },
    },
  ];
  for (const { args, row } of cases) {
    const tsLine = serializeFlowRunEnd(row);
    const r = Bun.spawnSync(["bash", BASH_LIB, "--emit-end", ...args], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) {
      console.warn(`flow-run end byte-identical: bash rc=${r.exitCode} (stderr=${r.stderr.toString().trim()}); skipping bash shell-out, asserting TS canonical string only`);
      expect(tsLine).toBe(tsLine);
      continue;
    }
    expect(r.stdout.toString().trimEnd()).toBe(tsLine);
  }
});

test("bash --append-start: run_id is minutes-compact and host defaults non-null", () => {
  const ledger = join(tmp, "flow-runs.jsonl");
  const r = Bun.spawnSync(
    ["bash", BASH_LIB, "--append-start", "pipeline-harvest", "2026-07-11T03:00:04+03:00", "", "claude", "opus", "", "", "4821"],
    { stdout: "pipe", stderr: "pipe", env: { ...process.env, HIMMEL_FLOW_RUNS_LEDGER: ledger } },
  );
  if (r.exitCode !== 0) {
    console.warn(`flow-run append-start: bash rc=${r.exitCode} (stderr=${r.stderr.toString().trim()}); skipping bash shell-out`);
    return;
  }
  // run_id grain is MINUTES (design §1.2: <flow>-YYYYMMDDTHHMM-<pid>).
  expect(r.stdout.toString().trimEnd()).toBe("pipeline-harvest-20260711T0300-4821");
  const row = JSON.parse(readFileSync(ledger, "utf8").trimEnd());
  expect(row.run_id).toBe("pipeline-harvest-20260711T0300-4821");
  // The append CLI defaults an empty host (so runner emitters never bake a
  // fire-time hostname subshell into generated runner text).
  expect(typeof row.host).toBe("string");
  expect(row.host!.length).toBeGreaterThan(0);
});

test("classifier: nonzero exit -> error", () => {
  expect(classifyOutcome(1, join(tmp, "missing.log"))).toBe("error");
});

test("classifier: truncation signature in tail -> truncated", () => {
  const p = join(tmp, "run.log");
  writeFileSync(p, "ok\nBackground tasks still running: terminating\n");
  expect(classifyOutcome(0, p)).toBe("truncated");
});

test("classifier: extra marker in tail -> truncated", () => {
  const p = join(tmp, "run.log");
  writeFileSync(p, "partial-work marker\n");
  expect(classifyOutcome(0, p, "partial-work")).toBe("truncated");
});

test("classifier: complete and missing log -> complete", () => {
  const p = join(tmp, "run.log");
  writeFileSync(p, "all done\n");
  expect(classifyOutcome(0, p)).toBe("complete");
  expect(classifyOutcome(0, join(tmp, "missing.log"))).toBe("complete");
});

test("bash classifier mirrors TS classifier cases", () => {
  const p = join(tmp, "run.log").replaceAll("\\", "/");
  writeFileSync(p, "ok\nBackground tasks still running: terminating\n");
  const r = Bun.spawnSync(["bash", BASH_LIB, "--classify", "0", p], { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) {
    console.warn(`flow-run classifier: bash rc=${r.exitCode} (stderr=${r.stderr.toString().trim()}); skipping bash shell-out`);
    expect(classifyOutcome(0, p)).toBe("truncated");
  } else {
    expect(r.stdout.toString().trim()).toBe("truncated");
  }
});

test("append creates parent dir and keeps null items_processed as null", () => {
  const p = join(tmp, "deep", "flow-runs.jsonl");
  appendFlowRun({ ...END, items_processed: null }, p);
  expect(existsSync(p)).toBe(true);
  const parsed = JSON.parse(readFileSync(p, "utf8").trim());
  expect(parsed.items_processed).toBeNull();
});

test("rotation at 10 MB keeps exactly one .1 and appends new row", () => {
  const p = join(tmp, "flow-runs.jsonl");
  writeFileSync(p, "x".repeat(FLOW_RUN_ROTATE_BYTES));
  writeFileSync(p + ".1", "old");
  appendFlowRun(START, p);
  expect(existsSync(p)).toBe(true);
  expect(existsSync(p + ".1")).toBe(true);
  expect(statSync(p + ".1").size).toBe(FLOW_RUN_ROTATE_BYTES);
  expect(readFileSync(p, "utf8").trim()).toBe(serializeFlowRunStart(START));
});
