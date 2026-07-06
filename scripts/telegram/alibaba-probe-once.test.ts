// scripts/telegram/alibaba-probe-once.test.ts
// HIMMEL-729 wiring chunk B — runner tests. Hermetic: NO live HTTP, NO real fs.
// runProbe's fetch / append / marker / log are all injected spies. Credentials
// in these tests are FAKE ("test-ak"/"test-sk") — never real secret material.
import { expect, test } from "bun:test";
import {
  MIN_PROBE_GAP_S, markerPath, shouldProbe, basicAuthHeader, buildPromQueryUrl,
  runProbe, parseDotenv,
} from "./alibaba-probe-once";
import type { FetchResult, ProbeOutcome } from "./alibaba-probe-once";
import type { QuotaGaugeRecord } from "./quota-gauge";
import { writeFileSync, unlinkSync } from "node:fs";

const NOW_MS = Date.parse("2026-07-04T12:00:00Z");

// Realistic Prometheus model_usage instant-query: qwen3-coder-plus total_tokens
// across two apikey_id series (sums to 600000) + qwen-plus (250000).
const REAL_PROM = JSON.stringify({
  status: "success",
  data: {
    result: [
      { metric: { model: "qwen3-coder-plus", usage_type: "total_tokens", apikey_id: "k1" }, value: [1782800000, "500000"] },
      { metric: { model: "qwen3-coder-plus", usage_type: "input_tokens", apikey_id: "k1" }, value: [1782800000, "300000"] },
      { metric: { model: "qwen3-coder-plus", usage_type: "total_tokens", apikey_id: "k2" }, value: [1782800000, "100000"] },
      { metric: { model: "qwen-plus", usage_type: "total_tokens", apikey_id: "k1" }, value: [1782800000, "250000"] },
    ],
  },
});

// Full env with the 3 Alibaba vars (FAKE creds). Tests spread overrides over it.
const BASE_ENV: Record<string, string | undefined> = {
  ALIBABA_QUOTA_PROM_URL: "https://prom.example/api/v1/query",
  ALIBABA_QUOTA_AK: "test-ak",
  ALIBABA_QUOTA_SK: "test-sk",
};

test("MIN_PROBE_GAP_S is 60", () => {
  expect(MIN_PROBE_GAP_S).toBe(60);
});

test("markerPath: default alongside the ledger; HIMMEL_ALIBABA_PROBE_MARKER override wins", () => {
  // node:path.join is platform-native (backslashes on Windows); normalize for assertion.
  const norm = (p: string): string => p.replace(/\\/g, "/");
  expect(norm(markerPath({ HOME: "/tmp/fake-home" }))).toBe("/tmp/fake-home/.himmel/alibaba-probe-lastrun");
  const override = markerPath({ HOME: "/tmp/fake-home", HIMMEL_ALIBABA_PROBE_MARKER: "/tmp/marker" });
  expect(override).toBe("/tmp/marker");   // override returned verbatim (no join)
});

test("shouldProbe: null -> true; within gap -> false; >= gap -> true", () => {
  expect(shouldProbe(null, NOW_MS)).toBe(true);
  expect(shouldProbe(NOW_MS - 5_000, NOW_MS)).toBe(false);              // 5s ago
  expect(shouldProbe(NOW_MS - (MIN_PROBE_GAP_S * 1000), NOW_MS)).toBe(true);   // exactly 60s
  expect(shouldProbe(NOW_MS - (MIN_PROBE_GAP_S * 1000 + 1), NOW_MS)).toBe(true); // >60s
  expect(shouldProbe(NOW_MS - 59_000, NOW_MS)).toBe(false);            // 59s ago
});

test("basicAuthHeader: 'Basic <base64(AK:SK)>' — decodes back to the pair (FAKE creds)", () => {
  const h = basicAuthHeader("test-ak", "test-sk");
  expect(h.startsWith("Basic ")).toBe(true);
  const b64 = h.slice("Basic ".length);
  expect(Buffer.from(b64, "base64").toString()).toBe("test-ak:test-sk");
});

test("buildPromQueryUrl: appends ?query=model_usage; uses & when a query string is present", () => {
  expect(buildPromQueryUrl("https://prom.example/api/v1/query")).toBe("https://prom.example/api/v1/query?query=model_usage");
  expect(buildPromQueryUrl("https://prom.example/api/v1/query?timeout=30s")).toBe("https://prom.example/api/v1/query?timeout=30s&query=model_usage");
});

test("buildPromQueryUrl: appends /api/v1/query to a workspace BASE url (the stored ALIBABA_QUOTA_PROM_URL form; live-verified 2026-07-06)", () => {
  expect(buildPromQueryUrl("https://prom.example/workspaces/ws-123")).toBe("https://prom.example/workspaces/ws-123/api/v1/query?query=model_usage");
  expect(buildPromQueryUrl("https://prom.example/workspaces/ws-123/")).toBe("https://prom.example/workspaces/ws-123/api/v1/query?query=model_usage");
  expect(buildPromQueryUrl("https://prom.example/workspaces/ws-123?timeout=30s")).toBe("https://prom.example/workspaces/ws-123/api/v1/query?timeout=30s&query=model_usage");
});

test("parseDotenv: reads KEY=VAL; strips one surrounding quote pair; skips blanks/comments", () => {
  // parseDotenv reads a real file path; write a tiny fixture to a temp file.
  const tmp = `${import.meta.dir}/.alibaba-probe-fixture.env`;
  writeFileSync(tmp, [
    '# comment',
    'export ALIBABA_QUOTA_AK="real-ak"',
    "ALIBABA_QUOTA_SK='real-sk'",
    "ALIBABA_QUOTA_PROM_URL=https://prom.example/api",
    "BLANK=",
    "NOTHING_HERE",
  ].join("\n"));
  try {
    const out = parseDotenv(tmp);
    expect(out.ALIBABA_QUOTA_AK).toBe("real-ak");
    expect(out.ALIBABA_QUOTA_SK).toBe("real-sk");
    expect(out.ALIBABA_QUOTA_PROM_URL).toBe("https://prom.example/api");
    expect(out.BLANK).toBeUndefined();          // blank value dropped
    expect(out.NOTHING_HERE).toBeUndefined();   // no `=` -> not a var line
  } finally { unlinkSync(tmp); }
});

// ── runProbe (all side effects injected) ─────────────────────────────────────
test("runProbe skip-noenv: any missing var -> skip-noenv, silent, no fetch/append/marker", async () => {
  let fetched = 0, appended = 0, committed = 0, logged = 0;
  const outcome = await runProbe({
    env: { ...BASE_ENV, ALIBABA_QUOTA_SK: undefined },   // SK missing
    nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => { fetched++; return { status: "ok", body: REAL_PROM }; },
    append: () => { appended++; },
    commitMarker: () => { committed++; },
    log: () => { logged++; },
  });
  expect(outcome).toBe("skip-noenv");
  expect([fetched, appended, committed, logged]).toEqual([0, 0, 0, 0]);
});

test("runProbe skip-fresh: within the gap -> skip-fresh, silent, no fetch/append/marker", async () => {
  let fetched = 0, appended = 0, committed = 0, logged = 0;
  const outcome = await runProbe({
    env: BASE_ENV,
    nowMs: NOW_MS, markerMs: NOW_MS - 5_000,   // 5s ago — too fresh
    fetchJson: async () => { fetched++; return { status: "ok", body: REAL_PROM }; },
    append: () => { appended++; },
    commitMarker: () => { committed++; },
    log: () => { logged++; },
  });
  expect(outcome).toBe("skip-fresh");
  expect([fetched, appended, committed, logged]).toEqual([0, 0, 0, 0]);
});

test("runProbe skip-429: HTTP 429 -> backoff; marker committed; NO append; one stderr line", async () => {
  let fetched = 0, appended = 0, committed = 0, logged = 0;
  const outcome = await runProbe({
    env: BASE_ENV, nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => { fetched++; return { status: "rate_limited" }; },
    append: () => { appended++; },
    commitMarker: () => { committed++; },
    log: () => { logged++; },
  });
  expect(outcome).toBe("skip-429");
  expect([fetched, committed, logged]).toEqual([1, 1, 1]);
  expect(appended).toBe(0);
});

test("runProbe skip-error: transport error / non-2xx -> skip-error; marker committed; one stderr line", async () => {
  // (a) explicit error result (non-2xx mapped by the transport)
  let appended = 0, committed = 0, logged = 0;
  let o1 = await runProbe({
    env: BASE_ENV, nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => ({ status: "error", message: "HTTP 502" }),
    append: () => { appended++; },
    commitMarker: () => { committed++; },
    log: () => { logged++; },
  });
  expect(o1).toBe("skip-error");
  // (b) thrown fetch -> same skip-error path
  let o2 = await runProbe({
    env: BASE_ENV, nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => { throw new Error("ENETUNREACH"); },
    append: () => { appended++; },
    commitMarker: () => { committed++; },
    log: () => { logged++; },
  });
  expect(o2).toBe("skip-error");
  expect([appended, committed, logged]).toEqual([0, 2, 2]);   // marker+log each attempt; never appended
});

test("runProbe appended (ok): default grants applied -> derived used_pct; marker committed; no stderr", async () => {
  const rows: QuotaGaugeRecord[] = [];
  let committed = 0, logged = 0;
  const outcome = await runProbe({
    env: BASE_ENV, nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => ({ status: "ok", body: REAL_PROM }),
    append: (r) => rows.push(r),
    commitMarker: () => { committed++; },
    log: () => { logged++; },
  });
  expect(outcome).toBe("appended");
  expect(committed).toBe(1);
  expect(logged).toBe(0);                          // success is silent
  expect(rows.length).toBe(2);                     // qwen3-coder-plus + qwen-plus
  const coder = rows.find((r) => r.tier === "qwen3-coder-plus")!;
  expect(coder.used_pct).toBe(60);                 // round(100*600000/1_000_000) via free-tier default
  expect(coder.source).toBe("alibaba-prometheus");
});

test("runProbe appended (ok): ALIBABA_QUOTA_GRANTS override flows through resolveGrants", async () => {
  const rows: QuotaGaugeRecord[] = [];
  const outcome = await runProbe({
    env: { ...BASE_ENV, ALIBABA_QUOTA_GRANTS: '{"qwen-plus": 500000}' }, // qwen-plus overridden to 500k
    nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => ({ status: "ok", body: REAL_PROM }),
    append: (r) => rows.push(r),
  });
  expect(outcome).toBe("appended");
  const plus = rows.find((r) => r.tier === "qwen-plus")!;
  expect(plus.used_pct).toBe(50);                  // round(100*250000/500000) — override beat the 1M default
  const coder = rows.find((r) => r.tier === "qwen3-coder-plus")!;
  expect(coder.used_pct).toBe(60);                 // default still applies to the non-overridden model
});

test("runProbe appended (ok, garbled body): ONE invisible row + one stderr line", async () => {
  const rows: QuotaGaugeRecord[] = [];
  let logged = 0;
  const outcome = await runProbe({
    env: BASE_ENV, nowMs: NOW_MS, markerMs: null,
    fetchJson: async () => ({ status: "ok", body: "not json{" }),
    append: (r) => rows.push(r),
    log: () => { logged++; },
  });
  expect(outcome).toBe("appended");
  expect(rows.length).toBe(1);
  expect(rows[0].source).toBe("invisible");
  expect(rows[0].used_pct).toBeNull();
  expect(logged).toBe(1);
});

test("runProbe: exhausted-but-distinct outcomes (compile-time coverage of the union)", () => {
  // Belt-and-braces: the four skip outcomes + appended are the whole ProbeOutcome
  // union; this pins the spelling the runner's callers/observers depend on.
  const all: ProbeOutcome[] = ["appended", "skip-noenv", "skip-fresh", "skip-429", "skip-error"];
  expect(new Set(all).size).toBe(all.length);
});

// FetchResult union pin (guards against a silent shape drift in the transport).
test("FetchResult shapes are spellable", () => {
  const a: FetchResult = { status: "ok", body: "{}" };
  const b: FetchResult = { status: "rate_limited" };
  const c: FetchResult = { status: "error", message: "x" };
  expect([a.status, b.status, c.status]).toEqual(["ok", "rate_limited", "error"]);
});
