// scripts/telegram/quota-gauge-alibaba.ts
// HIMMEL-729 chunk A — Alibaba Model Studio lane probe for the quota-gauge.
// Alibaba (qwen models, free per-model quotas) exposes per-model CONSUMED
// tokens — NOT free-remaining — via a private Prometheus HTTP API: metric
// `model_usage`, labels workspace_id/model/user_id/apikey_id/usage_type
// (usage_type ∈ total_tokens/input_tokens/output_tokens/cache_tokens), auth
// HTTP Basic base64(AccessKey:AccessKeySecret). Free-remaining is exposed
// NOWHERE, so it is DERIVED: used_pct = round(100 * consumed / grant), where
// the per-model grant is operator-configured. Never fabricated: a missing
// env/grant/response collapses to explicit invisible/null semantics
// (HIMMEL-275), matching the codex probe's style (quota-gauge-codex.ts).
//
// Mirrors quota-gauge-codex.ts: a best-effort PIGGYBACK probe — a rare
// piggyback on an Alibaba dispatch, 1h freshness like codex. Pure parse +
// row-build are fixture-tested here; the thin append is wired at a consumer
// touchpoint later (same deferred pattern the codex probe header documents —
// no such touchpoint on main yet). This module ships PURE: NO live HTTP in
// tests, NO new poll, NO always-on anything.
import type { QuotaGaugeRecord } from "./quota-gauge";

// Injectable env record (mirrors ledgerPath's `env` param). The caller reads
// process.env into this shape via alibabaEnv(); tests inject directly.
export type AlibabaEnv = { promUrl?: string; accessKey?: string; accessSecret?: string };

// Per-model operator-configured free-token grant. Keyed by model name. A model
// absent from this record (or with a non-positive grant) has an unknowable
// used_pct — consumed is still recorded, never fabricated into a percentage.
export type AlibabaGrants = Record<string, number>;

// One model's consumed-total-token reading (the total_tokens usage_type only).
export type ModelUsage = { model: string; totalTokens: number };

// Read the three Alibaba env vars out of an injectable env record (default
// process.env), mirroring ledgerPath's injectability.
export function alibabaEnv(env: Record<string, string | undefined> = process.env): AlibabaEnv {
  return {
    promUrl: env.ALIBABA_QUOTA_PROM_URL,
    accessKey: env.ALIBABA_QUOTA_AK,
    accessSecret: env.ALIBABA_QUOTA_SK,
  };
}

// ── HIMMEL-729 wiring chunk A: free-tier grants resolution ───────────────────
// Every TOKEN-quota model on the account carries exactly this free-tier grant.
// Source: operator-verified from the live Model Studio console, 2026-07-06,
// cross-checked with https://www.alibabacloud.com/help/en/model-studio/new-free-quota
// — ~89 token models (~70M total pool): qwen* families PLUS glm-5.1/glm-5.2,
// deepseek-v3.2/v4-*, kimi-k2.7-code, qwq/qvq. Most grants expire 2026-10-03;
// qwen-plus and qwen-turbo expire 2026-08-04. Quota is SHARED between the account
// and its RAM users; Singapore region; Stop-on-Exhaust is enabled (hard stop, no
// overage). Applied ONLY as a default to a reported token model with no operator
// override — never to wan* (unit-quota video models). Never fabricated: a grant
// figure is emitted only for a model that is either defaulted or overridden.
export const DEFAULT_FREE_TIER_GRANT_TOKENS = 1_000_000;

// wan* (e.g. wan2.2-t2v) are UNIT-quota video models: their grant is measured in
// calls (~50), not tokens, so the token default never applies. used_pct for one
// stays null unless an operator override supplies a token figure for it.
export function isUnitQuotaModel(model: string): boolean {
  return /^wan/i.test(model);
}

// Read the operator override `ALIBABA_QUOTA_GRANTS` (JSON `{"<model>": <tokens>}`).
// Malformed JSON (or a non-object body) -> ONE stderr warning + empty map (fall
// back to defaults). Absent/blank -> empty map. A non-positive / non-finite
// value for a key is dropped. Returns the override map ONLY; the per-model
// default is applied in resolveGrants. Injectable env (alibabaEnv-style).
export function parseGrantsOverride(env: Record<string, string | undefined> = process.env): AlibabaGrants {
  const raw = env.ALIBABA_QUOTA_GRANTS;
  if (!raw || !raw.trim()) return {};
  let obj: unknown;
  try { obj = JSON.parse(raw); } catch {
    console.error("quota-gauge-alibaba: ALIBABA_QUOTA_GRANTS is not valid JSON — ignoring override, using defaults");
    return {};
  }
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) {
    console.error("quota-gauge-alibaba: ALIBABA_QUOTA_GRANTS is not a JSON object — ignoring override, using defaults");
    return {};
  }
  const out: AlibabaGrants = {};
  for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
    const n = Number(v);
    if (Number.isFinite(n) && n > 0) out[k] = n;   // override REPLACES the default per model key
  }
  return out;
}

// Resolve the per-model grant map for the models the probe actually reported. An
// operator override REPLACES the default for that model key; otherwise every
// non-wan* token model gets DEFAULT_FREE_TIER_GRANT_TOKENS; wan* models get no
// entry (used_pct stays null unless overridden). `usage` null (probe unreadable)
// -> only overrides are knowable, so the default is NOT applied blindly. Pure +
// injectable; the runner calls this AFTER parseModelUsage so the default lands on
// reported models only, and buildAlibabaRows (unchanged) receives a fully
// resolved map — keeping its never-fabricate rule intact for any model neither
// defaulted nor overridden.
export function resolveGrants(usage: ModelUsage[] | null, env: Record<string, string | undefined> = process.env): AlibabaGrants {
  const grants: AlibabaGrants = { ...parseGrantsOverride(env) };
  if (usage === null) return grants;
  for (const { model } of usage) {
    if (model in grants) continue;          // override wins (already a positive finite number)
    if (isUnitQuotaModel(model)) continue;  // wan*: unit-quota, no token default
    grants[model] = DEFAULT_FREE_TIER_GRANT_TOKENS;
  }
  return grants;
}

// Parse a Prometheus HTTP API instant-query response into per-model consumed
// totals. Accepts either a raw JSON string (parsed here) or an already-parsed
// object (so the deferred wiring may use resp.text() OR resp.json()). Keeps
// ONLY usage_type="total_tokens" series; sums per model when a model appears
// in multiple series (e.g. across apikey_id). Returns null on a non-success
// status, missing data.result, a non-array result, an empty/no-usable-series
// result, or a garbled/unparseable input — never a fabricated number.
export function parseModelUsage(json: unknown): ModelUsage[] | null {
  let obj: unknown = json;
  if (typeof obj === "string") {
    if (obj.trim() === "") return null;
    try { obj = JSON.parse(obj); } catch { return null; }
  }
  if (typeof obj !== "object" || obj === null) return null;
  const o = obj as { status?: unknown; data?: unknown };
  if (o.status !== "success") return null;
  if (typeof o.data !== "object" || o.data === null) return null;
  const result = (o.data as { result?: unknown }).result;
  if (!Array.isArray(result)) return null;

  const byModel = new Map<string, number>();
  let anyUsable = false;
  for (const item of result) {
    if (typeof item !== "object" || item === null) continue;
    const entry = item as { metric?: unknown; value?: unknown };
    if (typeof entry.metric !== "object" || entry.metric === null) continue;
    const metric = entry.metric as { model?: unknown; usage_type?: unknown };
    if (metric.usage_type !== "total_tokens") continue;       // keep ONLY total_tokens
    if (typeof metric.model !== "string" || metric.model === "") continue;
    if (!Array.isArray(entry.value) || entry.value.length < 2) continue;
    const raw = entry.value[1];
    if (typeof raw !== "string" && typeof raw !== "number") continue;  // value[1] is a number-string
    const n = Number(raw);
    if (!Number.isFinite(n)) continue;
    anyUsable = true;
    byModel.set(metric.model, (byModel.get(metric.model) ?? 0) + n);   // sum per model if duplicated
  }
  if (!anyUsable) return null;
  const out: ModelUsage[] = [];
  for (const [model, totalTokens] of byModel) out.push({ model, totalTokens });
  return out;
}

// Map parsed usage + operator grants to canonical rows — one per model.
// `usage` null -> exactly ONE invisible-source row with null fields
// (visible-not-silent, HIMMEL-275), never a fabricated number. used_pct is
// DERIVED: round(100*consumed/grant) when the grant is a finite positive
// number, else null (the consumed figure is still recorded in `note`).
// glm_peak is null on every alibaba row (the peak band is a GLM-only
// concept). window/reset_at are null — Prometheus exposes a cumulative
// consumed counter, no rolling window or reset instant. tier carries the
// model name (the closest analogue to a "tier" for a per-model quota).
export function buildAlibabaRows(usage: ModelUsage[] | null, grants: AlibabaGrants, nowMs: number): QuotaGaugeRecord[] {
  const ts = new Date(nowMs).toISOString();
  if (usage === null) {
    return [{ v: 1, ts, lane: "alibaba", source: "invisible", used_pct: null, window: null, reset_at: null, tier: null, glm_peak: null, note: "alibaba prometheus unreadable" }];
  }
  const rows: QuotaGaugeRecord[] = [];
  for (const { model, totalTokens } of usage) {
    const grant = grants[model];
    const grantKnown = typeof grant === "number" && Number.isFinite(grant) && grant > 0;
    const usedPct = grantKnown ? Math.round((100 * totalTokens) / grant) : null;
    const note = grantKnown
      ? `consumed=${totalTokens}/${grant}`
      : `consumed=${totalTokens} (no grant configured - used_pct unknowable)`;
    rows.push({
      v: 1, ts, lane: "alibaba", source: "alibaba-prometheus",
      used_pct: usedPct, window: null, reset_at: null,
      tier: model, glm_peak: null, note,
    });
  }
  // Guard a representable-but-empty usage (parseModelUsage funnels it to null
  // today, but if an empty ModelUsage[] is ever constructed elsewhere it must
  // collapse to the honest invisible row, not a silent zero-row append
  // (visible-not-silent, HIMMEL-275 / CR type-design).
  if (rows.length === 0) {
    return [{ v: 1, ts, lane: "alibaba", source: "invisible", used_pct: null, window: null, reset_at: null, tier: null, glm_peak: null, note: "alibaba prometheus unreadable" }];
  }
  return rows;
}

// The caller decides whether to probe at all: only when a Prometheus URL and a
// complete HTTP-Basic key pair (AK + SK) are configured. Exported so the
// (deferred) wiring touchpoint can gate the fetch without inspecting env shape.
export function alibabaEnvReady(env: AlibabaEnv): boolean {
  return Boolean(env.promUrl && env.promUrl.trim() && env.accessKey && env.accessSecret);
}

// Best-effort probe: fetch the Prometheus response (throw/empty/garbled -> ONE
// invisible row + ONE stderr line, never a throw), build the rows, append every
// one. fetchBlob returns a Promise (live HTTP is the caller's concern); all
// other I/O is injected so this is unit-testable with no network. The returned
// promise never rejects — a failed fetch resolves to a single invisible row.
export async function alibabaProbeAppend(
  fetchBlob: () => Promise<unknown>,
  grants: AlibabaGrants,
  nowMs: number,
  append: (row: QuotaGaugeRecord) => void,
): Promise<void> {
  let json: unknown = null;
  try { json = await fetchBlob(); } catch { json = null; }
  const usage = json === null || json === undefined ? null : parseModelUsage(json);
  if (usage === null) console.error("quota-gauge-alibaba: prometheus response unreadable or no total_tokens series — recording an invisible alibaba row");
  for (const row of buildAlibabaRows(usage, grants, nowMs)) append(row);
}
