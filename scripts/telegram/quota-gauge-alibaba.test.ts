// scripts/telegram/quota-gauge-alibaba.test.ts
// HIMMEL-729 chunk A — Alibaba Prometheus probe tests. Fixtures only, NO live
// HTTP: a realistic instant-query response, a garbled one, an empty result, a
// missing grant, and a zero grant; plus the env-ready gate and the
// never-throws probe surface.
import { expect, test } from "bun:test";
import {
  alibabaEnv,
  alibabaEnvReady,
  parseModelUsage,
  buildAlibabaRows,
  alibabaProbeAppend,
  DEFAULT_FREE_TIER_GRANT_TOKENS,
  isUnitQuotaModel,
  parseGrantsOverride,
  resolveGrants,
} from "./quota-gauge-alibaba";
import type { QuotaGaugeRecord } from "./quota-gauge";

const NOW_MS = Date.parse("2026-07-04T12:00:00Z");

// Realistic Prometheus model_usage instant-query: qwen3-coder-plus appears in
// total_tokens TWICE (across apikey_id) and also in input/output/cache series
// (which must be dropped); qwen-plus once. total_tokens per model is the SUM.
const REAL_PROM = JSON.stringify({
  status: "success",
  data: {
    result: [
      { metric: { model: "qwen3-coder-plus", usage_type: "total_tokens", workspace_id: "ws1", apikey_id: "k1" }, value: [1782800000, "500000"] },
      { metric: { model: "qwen3-coder-plus", usage_type: "input_tokens", apikey_id: "k1" }, value: [1782800000, "300000"] },
      { metric: { model: "qwen3-coder-plus", usage_type: "output_tokens", apikey_id: "k1" }, value: [1782800000, "180000"] },
      { metric: { model: "qwen3-coder-plus", usage_type: "cache_tokens", apikey_id: "k1" }, value: [1782800000, "20000"] },
      { metric: { model: "qwen-plus", usage_type: "total_tokens", apikey_id: "k1" }, value: [1782800000, "250000"] },
      { metric: { model: "qwen3-coder-plus", usage_type: "total_tokens", apikey_id: "k2" }, value: [1782800000, "100000"] },
    ],
  },
});

const GRANTS = { "qwen3-coder-plus": 1_000_000, "qwen-plus": 1_000_000 } as const;

test("parseModelUsage: keeps only total_tokens, sums per model across series", () => {
  const usage = parseModelUsage(REAL_PROM);
  expect(usage).not.toBeNull();
  expect(usage).toHaveLength(2);
  const byModel = new Map(usage!.map((u) => [u.model, u.totalTokens]));
  // 500000 + 100000 (input/output/cache dropped); qwen-plus 250000.
  expect(byModel.get("qwen3-coder-plus")).toBe(600000);
  expect(byModel.get("qwen-plus")).toBe(250000);
});

test("parseModelUsage also accepts an already-parsed object (resp.json() shape)", () => {
  const parsed = JSON.parse(REAL_PROM);
  const usage = parseModelUsage(parsed);
  expect(usage).not.toBeNull();
  expect(usage!.length).toBe(2);
});

test("buildAlibabaRows: derived used_pct, tier=model, glm_peak null, window/reset_at null", () => {
  const usage = parseModelUsage(REAL_PROM)!;
  const rows = buildAlibabaRows(usage, GRANTS, NOW_MS);
  expect(rows.length).toBe(2);
  for (const r of rows) {
    expect(r.v).toBe(1);
    expect(r.lane).toBe("alibaba");
    expect(r.source).toBe("alibaba-prometheus");
    expect(r.window).toBeNull();
    expect(r.reset_at).toBeNull();
    expect(r.glm_peak).toBeNull();
    expect(r.ts).toBe(new Date(NOW_MS).toISOString());
  }
  const coder = rows.find((r) => r.tier === "qwen3-coder-plus")!;
  const plus = rows.find((r) => r.tier === "qwen-plus")!;
  expect(coder.used_pct).toBe(60);                       // round(100*600000/1_000_000)
  expect(coder.note).toBe("consumed=600000/1000000");
  expect(plus.used_pct).toBe(25);                        // round(100*250000/1_000_000)
  expect(plus.note).toBe("consumed=250000/1000000");
});

test("missing grant (model absent) -> used_pct null, note flags unknowable", () => {
  const usage = parseModelUsage(REAL_PROM)!;
  // qwen3-coder-plus has NO grant; qwen-plus does.
  const rows = buildAlibabaRows(usage, { "qwen-plus": 1_000_000 }, NOW_MS);
  const coder = rows.find((r) => r.tier === "qwen3-coder-plus")!;
  expect(coder.used_pct).toBeNull();
  expect(coder.note).toBe("consumed=600000 (no grant configured - used_pct unknowable)");
  const plus = rows.find((r) => r.tier === "qwen-plus")!;
  expect(plus.used_pct).toBe(25);
  expect(plus.note).toBe("consumed=250000/1000000");
});

test("zero grant -> used_pct null (no divide-by-zero), consumed still recorded", () => {
  const usage = [{ model: "qwen3-coder-plus", totalTokens: 600000 }];
  const rows = buildAlibabaRows(usage, { "qwen3-coder-plus": 0 }, NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].used_pct).toBeNull();
  expect(rows[0].note).toBe("consumed=600000 (no grant configured - used_pct unknowable)");
});

test("empty result array -> parseModelUsage null -> ONE invisible row (no fabrication)", () => {
  const empty = JSON.stringify({ status: "success", data: { result: [] } });
  expect(parseModelUsage(empty)).toBeNull();
  const rows = buildAlibabaRows(parseModelUsage(empty), GRANTS, NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].source).toBe("invisible");
  expect(rows[0].used_pct).toBeNull();
  expect(rows[0].tier).toBeNull();
  expect(rows[0].note).toBe("alibaba prometheus unreadable");
});

test("garbled / non-success / wrong-shape -> parseModelUsage null", () => {
  expect(parseModelUsage("not json{")).toBeNull();                       // unparseable string
  expect(parseModelUsage("")).toBeNull();                                // empty body
  expect(parseModelUsage(JSON.stringify({ status: "error", error: "bad_query" }))).toBeNull();
  expect(parseModelUsage(JSON.stringify({ status: "success" }))).toBeNull();                 // no data
  expect(parseModelUsage(JSON.stringify({ status: "success", data: {} }))).toBeNull();       // no result
  expect(parseModelUsage(JSON.stringify({ status: "success", data: { result: "nope" } }))).toBeNull(); // non-array
  expect(parseModelUsage(42)).toBeNull();                                // primitive
  // total_tokens label absent entirely -> no usable series -> null
  const noTotal = JSON.stringify({ status: "success", data: { result: [
    { metric: { model: "x", usage_type: "input_tokens" }, value: [1, "5"] },
  ] } });
  expect(parseModelUsage(noTotal)).toBeNull();
  // value[1] non-numeric -> that series dropped; if it is the only one -> null
  const badVal = JSON.stringify({ status: "success", data: { result: [
    { metric: { model: "x", usage_type: "total_tokens" }, value: [1, "not-a-number"] },
  ] } });
  expect(parseModelUsage(badVal)).toBeNull();
});

test("alibabaEnvReady: true only with a non-empty url AND both AK+SK", () => {
  expect(alibabaEnvReady({ promUrl: "https://prom.example/api", accessKey: "ak", accessSecret: "sk" })).toBe(true);
  expect(alibabaEnvReady({ promUrl: "   ", accessKey: "ak", accessSecret: "sk" })).toBe(false); // blank url
  expect(alibabaEnvReady({ promUrl: "https://prom.example/api", accessKey: "ak" })).toBe(false); // missing SK
  expect(alibabaEnvReady({ promUrl: "https://prom.example/api", accessSecret: "sk" })).toBe(false); // missing AK
  expect(alibabaEnvReady({})).toBe(false);
});

test("alibabaEnv maps the three env vars (injectable record)", () => {
  expect(alibabaEnv({
    ALIBABA_QUOTA_PROM_URL: "https://prom.example/api",
    ALIBABA_QUOTA_AK: "ak",
    ALIBABA_QUOTA_SK: "sk",
  })).toEqual({ promUrl: "https://prom.example/api", accessKey: "ak", accessSecret: "sk" });
  expect(alibabaEnv({})).toEqual({ promUrl: undefined, accessKey: undefined, accessSecret: undefined });
  expect(alibabaEnv({ ALIBABA_QUOTA_AK: "ak" }).accessKey).toBe("ak");
});

test("alibabaProbeAppend: found -> rows, no stderr; throw/garbled -> ONE invisible row + ONE stderr; never rejects", async () => {
  const rows: QuotaGaugeRecord[] = [];
  let stderrCount = 0;
  const origErr = console.error;
  console.error = () => { stderrCount++; };
  try {
    await alibabaProbeAppend(() => Promise.resolve(REAL_PROM), GRANTS, NOW_MS, (r) => rows.push(r)); // 2 rows
    await alibabaProbeAppend(() => Promise.reject(new Error("ENETUNREACH")), GRANTS, NOW_MS, (r) => rows.push(r)); // throw -> invisible
    await alibabaProbeAppend(() => Promise.resolve("not json{"), GRANTS, NOW_MS, (r) => rows.push(r)); // garbled -> invisible
    await alibabaProbeAppend(() => Promise.resolve(JSON.stringify({ status: "success", data: { result: [] } })), GRANTS, NOW_MS, (r) => rows.push(r)); // empty -> invisible
  } finally { console.error = origErr; }
  // 2 (found) + 1 (throw) + 1 (garbled) + 1 (empty) = 5
  expect(rows.length).toBe(5);
  expect(rows[0].source).toBe("alibaba-prometheus");
  expect(rows[0].used_pct).toBe(60);
  expect(rows[1].source).toBe("alibaba-prometheus");
  expect(rows[2].source).toBe("invisible"); // throw
  expect(rows[3].source).toBe("invisible"); // garbled
  expect(rows[4].source).toBe("invisible"); // empty result
  // stderr fires exactly once per unreadable probe (throw, garbled, empty) — never on found.
  expect(stderrCount).toBe(3);
});

test("latent empty usage[] -> ONE invisible row, never a silent zero-row append", () => {
  const rows = buildAlibabaRows([], GRANTS, NOW_MS);
  expect(rows.length).toBe(1);
  expect(rows[0].source).toBe("invisible");
  expect(rows[0].used_pct).toBeNull();
});

// ── HIMMEL-729 wiring chunk A: free-tier grants resolution ───────────────────
test("DEFAULT_FREE_TIER_GRANT_TOKENS is the documented 1,000,000", () => {
  expect(DEFAULT_FREE_TIER_GRANT_TOKENS).toBe(1_000_000);
});

test("isUnitQuotaModel: wan* only (case-insensitive); qwen/glm/deepseek are not", () => {
  expect(isUnitQuotaModel("wan2.2-t2v")).toBe(true);
  expect(isUnitQuotaModel("WAN2.2-i2v")).toBe(true);
  expect(isUnitQuotaModel("qwen-plus")).toBe(false);
  expect(isUnitQuotaModel("qwen3-coder-plus")).toBe(false);
  expect(isUnitQuotaModel("glm-5.2")).toBe(false);
  expect(isUnitQuotaModel("deepseek-v3.2")).toBe(false);
  expect(isUnitQuotaModel("kimi-k2.7-code")).toBe(false);
});

test("parseGrantsOverride: absent/blank -> {} (defaults apply later)", () => {
  expect(parseGrantsOverride({})).toEqual({});
  expect(parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: "   " })).toEqual({});
});

test("parseGrantsOverride: valid object -> map; non-positive/non-finite values dropped", () => {
  expect(parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: '{"qwen-plus": 500000}' })).toEqual({ "qwen-plus": 500000 });
  const mixed = parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: '{"a": 100, "b": 0, "c": -5, "d": "x", "e": 200}' });
  expect(mixed).toEqual({ a: 100, e: 200 });   // b/c non-positive, d non-numeric -> dropped
});

test("parseGrantsOverride: malformed JSON -> warn to stderr + {} (fall back to defaults)", () => {
  let stderrCount = 0;
  const origErr = console.error;
  console.error = () => { stderrCount++; };
  try {
    expect(parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: "not json{" })).toEqual({});
    expect(parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: "[1,2,3]" })).toEqual({});      // non-object body
    expect(parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: '"a string"' })).toEqual({});   // non-object body
    expect(parseGrantsOverride({ ALIBABA_QUOTA_GRANTS: "42" })).toEqual({});            // non-object body
  } finally { console.error = origErr; }
  expect(stderrCount).toBe(4);   // one warning per malformed/non-object parse
});

test("resolveGrants: missing ALIBABA_QUOTA_GRANTS -> blanket 1M default on every reported token model", () => {
  const usage = parseModelUsage(REAL_PROM)!;   // qwen3-coder-plus + qwen-plus
  const grants = resolveGrants(usage, {});
  expect(grants).toEqual({ "qwen3-coder-plus": 1_000_000, "qwen-plus": 1_000_000 });
});

test("resolveGrants: override REPLACES the default per model key (others still default)", () => {
  const usage = parseModelUsage(REAL_PROM)!;
  const grants = resolveGrants(usage, { ALIBABA_QUOTA_GRANTS: '{"qwen-plus": 500000}' });
  expect(grants).toEqual({ "qwen-plus": 500000, "qwen3-coder-plus": 1_000_000 });
});

test("resolveGrants: wan* model gets NO token default (used_pct stays null downstream)", () => {
  const usage = [{ model: "wan2.2-t2v", totalTokens: 30 }, { model: "qwen-plus", totalTokens: 250000 }];
  const grants = resolveGrants(usage, {});
  expect(grants).toEqual({ "qwen-plus": 1_000_000 });   // wan2.2-t2v absent — never fabricated
  const rows = buildAlibabaRows(usage, grants, NOW_MS);
  const wan = rows.find((r) => r.tier === "wan2.2-t2v")!;
  expect(wan.used_pct).toBeNull();
  expect(wan.note).toBe("consumed=30 (no grant configured - used_pct unknowable)");
});

test("resolveGrants: an override ON a wan* model applies (operator supplies the token figure)", () => {
  const usage = [{ model: "wan2.2-t2v", totalTokens: 100000 }];
  const grants = resolveGrants(usage, { ALIBABA_QUOTA_GRANTS: '{"wan2.2-t2v": 1000000}' });
  expect(grants).toEqual({ "wan2.2-t2v": 1_000_000 });
  const rows = buildAlibabaRows(usage, grants, NOW_MS);
  expect(rows[0].used_pct).toBe(10);
});

test("resolveGrants: usage null (probe unreadable) -> only overrides knowable, no blind default", () => {
  const grants = resolveGrants(null, { ALIBABA_QUOTA_GRANTS: '{"qwen-plus": 500000}' });
  expect(grants).toEqual({ "qwen-plus": 500000 });   // no fabricated defaults without a reported model
});

test("resolveGrants + buildAlibabaRows: default makes a previously-unknowable model derivable", () => {
  // Same input as the shipped "missing grant -> null" test, but grants now resolved
  // with the free-tier default: qwen3-coder-plus is NO LONGER unknowable.
  const usage = parseModelUsage(REAL_PROM)!;
  const grants = resolveGrants(usage, {});   // defaults only
  const rows = buildAlibabaRows(usage, grants, NOW_MS);
  const coder = rows.find((r) => r.tier === "qwen3-coder-plus")!;
  expect(coder.used_pct).toBe(60);                       // round(100*600000/1_000_000)
  expect(coder.note).toBe("consumed=600000/1000000");
});
