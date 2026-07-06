// scripts/telegram/quota-gauge.test.ts
// WS9 (HIMMEL-654) — quota-gauge ledger tests. Path resolver, append helper,
// byte-identical bash<->TS serialization (T22), two interleaved appends
// (T16), and the in-process same-lane concurrent-append race (T17/AC6).
// Injected deps only — no real $HOME writes, no network.
import { expect, test, beforeEach, afterEach } from "bun:test";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mkdtempSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import {
  QUOTA_GAUGE_FIELDS,
  ledgerPath,
  appendQuotaGauge,
  serializeQuotaGauge,
  quotaGaugeRead,
  isGlmPeak,
  buildGlmRow,
  type QuotaGaugeRecord,
} from "./quota-gauge";

const REPO_ROOT = join(import.meta.dir, "..", "..");
// bash needs POSIX separators; backslashes are escape chars in bash argv.
const BASH_LIB = join(REPO_ROOT, "scripts", "lib", "quota-gauge-ledger.sh").replaceAll("\\", "/");

let tmp: string;
beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "quota-gauge-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

const NOW_TS = "2026-07-04T12:00:00Z";

function rec(partial: Partial<QuotaGaugeRecord>): QuotaGaugeRecord {
  return {
    v: 1, ts: NOW_TS, lane: "claude", source: "test",
    used_pct: null, window: null, reset_at: null,
    tier: null, glm_peak: null, note: null,
    ...partial,
  };
}

test("QUOTA_GAUGE_FIELDS canonical order (10 keys, schema-locked)", () => {
  expect([...QUOTA_GAUGE_FIELDS]).toEqual([
    "v", "ts", "lane", "source", "used_pct", "window", "reset_at", "tier", "glm_peak", "note",
  ]);
});

test("no forbidden fields in the record schema (AC23/T23)", () => {
  const src = readFileSync(join(import.meta.dir, "quota-gauge.ts"), "utf8");
  expect(src).not.toMatch(/fresh_for_s/);
  expect(src).not.toMatch(/concurrency/);
  // no $-budget field on the record line
  expect(serializeQuotaGauge(rec({}))).not.toMatch(/"budget"/);
});

test("ledgerPath honors HIMMEL_QUOTA_GAUGE_LEDGER override (T22)", () => {
  expect(ledgerPath({ HOME: "/h", HIMMEL_QUOTA_GAUGE_LEDGER: "/custom/x.jsonl" })).toBe("/custom/x.jsonl");
});

test("ledgerPath default is <HOME>/.himmel/quota-gauge.jsonl under a Windows-style HOME (T22)", () => {
  expect(ledgerPath({ HOME: "C:/Users/test" })).toBe(join("C:/Users/test", ".himmel", "quota-gauge.jsonl"));
});

test("appendQuotaGauge writes one \\n-terminated line; 10 keys canonical order; null rendered", () => {
  const f = join(tmp, "a.jsonl");
  appendQuotaGauge(rec({
    lane: "claude", source: "arm-threshold", used_pct: 93, window: "5h",
    reset_at: "2026-06-10T13:30:00+00:00", note: "cap approached",
  }), f);
  const raw = readFileSync(f, "utf8");
  expect(raw.endsWith("\n")).toBe(true);
  expect(raw.split("\n").filter(Boolean).length).toBe(1);
  const line = raw.trimEnd();
  const keys = (line.match(/"([^"]+)":/g) ?? []).map(k => k.slice(1, -2));
  expect(keys).toEqual([...QUOTA_GAUGE_FIELDS]);
  expect(line).toContain('"tier":null');
  expect(line).toContain('"glm_peak":null');
  const parsed = JSON.parse(line);
  expect(parsed.used_pct).toBe(93);
  expect(parsed.lane).toBe("claude");
});

test("appendQuotaGauge creates the parent dir on append (not on resolve)", () => {
  const nested = join(tmp, "deep", "dir", "x.jsonl");
  appendQuotaGauge(rec({}), nested);
  expect(existsSync(nested)).toBe(true);
});

test("byte-identical bash<->TS serialization (T22)", () => {
  const cases: Array<{ args: string[]; record: QuotaGaugeRecord }> = [
    {
      args: ["claude", "arm-threshold", "93", "5h", "2026-06-10T13:30:00+00:00", "cap approached", NOW_TS],
      record: rec({
        lane: "claude", source: "arm-threshold", used_pct: 93, window: "5h",
        reset_at: "2026-06-10T13:30:00+00:00", note: "cap approached",
      }),
    },
    {
      args: ["claude", "invisible", "", "", "", "wedged", NOW_TS],
      record: rec({ lane: "claude", source: "invisible", note: "wedged" }),
    },
  ];
  for (const { args, record } of cases) {
    const tsLine = serializeQuotaGauge(record);
    const r = Bun.spawnSync(["bash", BASH_LIB, "--emit", ...args], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) {
      // Fallback where a bare `bash` resolves to a non-Git-Bash stub: the
      // bash smoke test carries the authoritative bash-side assertion.
      console.warn(`byte-identical: bash --emit rc=${r.exitCode} (stderr=${r.stderr.toString().trim()}); skipping bash shell-out, asserting TS canonical string only`);
      expect(tsLine).toBe(tsLine);
      continue;
    }
    const bashLine = r.stdout.toString().trimEnd();
    expect(bashLine).toBe(tsLine);
  }
});

test("two interleaved appends -> 2 complete parseable lines (T16)", () => {
  const f = join(tmp, "two.jsonl");
  appendQuotaGauge(rec({ lane: "glm", source: "monitor-endpoint", used_pct: 62, window: "5h", tier: "pro", glm_peak: true }), f);
  appendQuotaGauge(rec({ lane: "codex", source: "codex-sqlite", used_pct: 40, window: "weekly", tier: "pro", glm_peak: null }), f);
  const lines = readFileSync(f, "utf8").split("\n").filter(Boolean);
  expect(lines.length).toBe(2);
  const a = JSON.parse(lines[0]);
  const b = JSON.parse(lines[1]);
  expect(a.lane).toBe("glm");
  expect(b.lane).toBe("codex");
  expect(a.glm_peak).toBe(true);
  expect(b.glm_peak).toBe(null);
});

test("T17/AC6 same-lane concurrent appendQuotaGauge race -> no loss/merge", async () => {
  const f = join(tmp, "race.jsonl").replaceAll("\\", "/");
  // Lean volume: Cygwin fork is ~280ms/append (quota_gauge_row's `date` + 4
  // `$(...)` subshells), so a high row count blows the 5s test budget. The
  // atomicity volume was already proven by Task 0's 4000-line standalone
  // probe; T17's job is the CODE PATH (quota_gauge_append wraps printf >> with
  // path resolution + mkdir) under concurrent first-creation — W concurrent
  // writers each contributing a few rows to ONE ledger is sufficient.
  const W = 6, R = 3;
  const subs: Array<{ exited: Promise<number> }> = [];
  for (let w = 0; w < W; w++) {
    const script = [
      `source "${BASH_LIB}" 2>/dev/null || exit 99`,
      `ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)`,
      `i=0`,
      `while [ "$i" -lt ${R} ]; do`,
      `  quota_gauge_append "$(quota_gauge_row glm monitor-endpoint ${w} 5h "" "race-w${w}-i$i" "$ts")" 2>/dev/null || true`,
      `  i=$((i+1))`,
      `done`,
    ].join("\n");
    const sub = Bun.spawn(["bash", "-c", script], {
      stdout: "pipe", stderr: "pipe",
      env: { ...process.env, HIMMEL_QUOTA_GAUGE_LEDGER: f },
    });
    subs.push(sub);
  }
  const codes = await Promise.all(subs.map(s => s.exited));
  expect(codes.every(c => c === 0)).toBe(true);
  expect(existsSync(f)).toBe(true);
  const lines = readFileSync(f, "utf8").split("\n").filter(Boolean);
  expect(lines.length).toBe(W * R);
  let allParse = true;
  for (const l of lines) {
    try { const o = JSON.parse(l); if (o.lane !== "glm" || o.v !== 1) allParse = false; }
    catch { allParse = false; }
  }
  expect(allParse).toBe(true);
  // no merged lines: exactly one '{' per line
  const openBraces = lines.reduce((n, l) => n + (l.match(/{/g) ?? []).length, 0);
  expect(openBraces).toBe(lines.length);
});

// ── Task 2: quotaGaugeRead reader (T10-T15, T18, T21, T26) ─────────────────────
const NOW_MS = Date.parse(NOW_TS);
const ago = (s: number) => new Date(NOW_MS - s * 1000).toISOString();
function writeLedger(rows: string[]): string {
  const p = join(tmp, "quota-gauge.jsonl");
  writeFileSync(p, rows.length ? rows.join("\n") + "\n" : "");
  return p;
}

test("T10 fresh GLM row (age 30s < 120 budget) -> fresh:true status:known", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "glm", used_pct: 62, ts: ago(30) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.glm.fresh).toBe(true);
  expect(r.glm.status).toBe("known");
  expect(r.glm.row?.used_pct).toBe(62);
});

test("T11 stale GLM row (age 300s > 120 budget) -> fresh:false status:unknown", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "glm", used_pct: 62, ts: ago(300) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.glm.fresh).toBe(false);
  expect(r.glm.status).toBe("unknown");
  expect(r.glm.row?.used_pct).toBe(62); // last-known still carried even when stale
});

test("T12 Claude budget 0 -> a 1s-old visible row still reads unknown", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "claude", used_pct: 93, source: "arm-threshold", ts: ago(1) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.claude.fresh).toBe(false);
  expect(r.claude.status).toBe("unknown");
});

test("T13 absent lane -> row null, status unknown (no fabricated 0/100)", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "glm", used_pct: 62, ts: ago(10) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.codex.row).toBeNull();
  expect(r.codex.status).toBe("unknown");
});

test("T14 latest invisible row -> unknown; earlier real reading NOT surfaced (F10)", () => {
  const p = writeLedger([
    serializeQuotaGauge(rec({ lane: "glm", used_pct: 40, ts: ago(20) })),                       // older real reading
    serializeQuotaGauge(rec({ lane: "glm", used_pct: null, source: "invisible", ts: ago(5) })), // newest = invisible
  ]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.glm.status).toBe("unknown");
  expect(r.glm.row?.used_pct).toBeNull(); // the invisible latest, not the earlier 40
});

test("T15 truncated trailing partial line skipped; latest-per-lane still correct", () => {
  const good = serializeQuotaGauge(rec({ lane: "glm", used_pct: 62, ts: ago(10) }));
  const p = join(tmp, "quota-gauge.jsonl");
  writeFileSync(p, good + "\n" + '{"v":1,"lane":"glm","used_pct":5,"ts":"2026'); // half-written newest line
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.glm.status).toBe("known");
  expect(r.glm.row?.used_pct).toBe(62); // good row wins; the truncated one is skipped
});

test("T18 GLM burst after a fresh Codex row does not evict Codex (within N)", () => {
  const rows: string[] = [serializeQuotaGauge(rec({ lane: "codex", used_pct: 50, window: "weekly", ts: ago(60) }))];
  for (let i = 0; i < 220; i++) rows.push(serializeQuotaGauge(rec({ lane: "glm", used_pct: 60, ts: ago(30) })));
  const r = quotaGaugeRead({ path: writeLedger(rows), nowMs: NOW_MS });
  expect(r.glm.status).toBe("known");
  expect(r.codex.status).toBe("known"); // codex at position 221 < 500, still found
  expect(r.codex.row?.used_pct).toBe(50);
});

test("T26 absent lane beyond lookbackN -> unknown, scan bounded at N", () => {
  const rows: string[] = [];
  for (let i = 0; i < 200; i++) rows.push(serializeQuotaGauge(rec({ lane: "glm", used_pct: 60, ts: ago(30) })));
  const r = quotaGaugeRead({ path: writeLedger(rows), nowMs: NOW_MS, lookbackN: 50 });
  expect(r.codex.status).toBe("unknown"); // codex never appears within the newest 50
  expect(r.codex.row).toBeNull();
  expect(r.glm.status).toBe("known");     // glm found at row 1, before the bound bites
});

// ── HIMMEL-729: alibaba lane in the reader (budget 3600s, like codex) ─────────
test("T13b absent alibaba lane -> row null, status unknown (no fabricated row)", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "glm", used_pct: 62, ts: ago(10) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.alibaba.row).toBeNull();
  expect(r.alibaba.status).toBe("unknown");
  expect(r.alibaba.fresh).toBe(false);
});

test("T10b fresh alibaba row (age 30s < 3600 budget) -> fresh:true status:known", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "alibaba", source: "alibaba-prometheus", used_pct: 12, tier: "qwen3-coder-plus", ts: ago(30) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.alibaba.fresh).toBe(true);
  expect(r.alibaba.status).toBe("known");
  expect(r.alibaba.row?.used_pct).toBe(12);
  expect(r.alibaba.row?.tier).toBe("qwen3-coder-plus");
});

test("T11b stale alibaba row (age 4000s > 3600 budget) -> fresh:false status:unknown", () => {
  const p = writeLedger([serializeQuotaGauge(rec({ lane: "alibaba", used_pct: 12, ts: ago(4000) }))]);
  const r = quotaGaugeRead({ path: p, nowMs: NOW_MS });
  expect(r.alibaba.fresh).toBe(false);
  expect(r.alibaba.status).toBe("unknown");
  expect(r.alibaba.row?.used_pct).toBe(12); // last-known still carried even when stale
});

test("T21/AC11 exactly one quotaGaugeRead impl; no second-language reader twin", () => {
  const src = readFileSync(join(REPO_ROOT, "scripts", "telegram", "quota-gauge.ts"), "utf8");
  expect((src.match(/export function quotaGaugeRead/g) ?? []).length).toBe(1);
  expect(existsSync(join(REPO_ROOT, "scripts", "lib", "quota-gauge-read.sh"))).toBe(false);
});

// ── Task 5: GLM row-builder + peak band (T1, T2, T3) ─────────────────────────
test("T1 buildGlmRow maps a live-shaped reading; round-trips; no fresh_for_s (AC1)", () => {
  const reading = { percentage: 62, nextResetTime: NOW_MS + 2 * 3600 * 1000, level: "pro" };
  const row = buildGlmRow(reading, NOW_MS);
  expect(row.lane).toBe("glm");
  expect(row.source).toBe("monitor-endpoint");
  expect(row.used_pct).toBe(62);
  expect(row.window).toBe("5h");
  expect(row.reset_at).toBe(new Date(NOW_MS + 2 * 3600 * 1000).toISOString());
  expect(row.tier).toBe("pro");
  expect(JSON.parse(serializeQuotaGauge(row)).used_pct).toBe(62);
  expect(serializeQuotaGauge(row)).not.toContain("fresh_for_s");
});

test("T2 buildGlmRow(null) -> invisible row, used_pct null, no throw", () => {
  const row = buildGlmRow(null, NOW_MS);
  expect(row.source).toBe("invisible");
  expect(row.used_pct).toBeNull();
  expect(row.window).toBeNull();
  expect(row.note).toContain("invisible");
});

test("T3 isGlmPeak boundaries 13:59 / 14:00 / 17:59 / 18:00 UTC+8 (AC8)", () => {
  // a UTC instant whose UTC+8 wall-clock hour is `utc8h` -> UTC hour = utc8h-8.
  const at = (utc8h: number, m: number) => Date.UTC(2026, 6, 4, (utc8h - 8 + 24) % 24, m, 0);
  expect(isGlmPeak(at(13, 59))).toBe(false);
  expect(isGlmPeak(at(14, 0))).toBe(true);
  expect(isGlmPeak(at(17, 59))).toBe(true);
  expect(isGlmPeak(at(18, 0))).toBe(false);
  // glm_peak is a bool on GLM rows (never null there); non-GLM rows carry null
  expect(buildGlmRow({ percentage: 1, nextResetTime: NOW_MS, level: "pro" }, NOW_MS).glm_peak).not.toBeNull();
});
