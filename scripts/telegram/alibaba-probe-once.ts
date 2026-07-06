// scripts/telegram/alibaba-probe-once.ts
// HIMMEL-729 wiring chunk B — the deferred LIVE touchpoint for the Alibaba
// quota-gauge probe (companion to the PURE quota-gauge-alibaba.ts module shipped
// in PR #950/#951). Invoke-only and PIGGYBACKED on a qwen* dispatch from
// scripts/hermes/invoke.sh: NO always-on surface (no hook, no daemon, no cron,
// no poll loop). The probe runs at most ONCE per invocation and self-throttles.
//
// Flow: read ALIBABA_QUOTA_{AK,SK,PROM_URL} (process.env -> repo .env ->
// main-checkout .env); SKIP SILENTLY (rc 0) when any is missing. A freshness
// marker enforces a MIN 60s gap between probes (stale-skip is rc 0). Query the
// Prometheus instant endpoint (HTTP Basic base64(AK:SK), `query=model_usage`);
// on HTTP 429 record a backoff and skip (no in-line retry); on success feed
// parseModelUsage + resolveGrants + buildAlibabaRows and append every row to the
// quota-gauge ledger. NEVER prints secret values; the credential pair lives only
// in the Authorization header passed to the fetch.
//
// All I/O (fetch, marker read/write, append) is injected into runProbe so the
// core is unit-testable with NO network and NO real fs. The thin main() wires
// the real fetch + fs + appendQuotaGauge and is the only thing that runs live.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  alibabaEnv, alibabaEnvReady, parseModelUsage, resolveGrants, buildAlibabaRows,
} from "./quota-gauge-alibaba";
import { appendQuotaGauge, ledgerPath } from "./quota-gauge";
import type { QuotaGaugeRecord } from "./quota-gauge";

export const MIN_PROBE_GAP_S = 60;

// Freshness-marker path: alongside the ledger (<HOME>/.himmel/alibaba-probe-
// lastrun), overridable via HIMMEL_ALIBABA_PROBE_MARKER for tests. Reads HOME
// from the injectable env (via ledgerPath) so it never touches the real home in
// a hermetic test.
export function markerPath(env: Record<string, string | undefined> = process.env): string {
  const override = env.HIMMEL_ALIBABA_PROBE_MARKER;
  if (override && override.trim()) return override;
  return join(dirname(ledgerPath(env)), "alibaba-probe-lastrun");
}

// True iff enough time has elapsed since the last probe attempt. `lastProbeMs`
// null (no prior attempt) -> always probe. Pure.
export function shouldProbe(lastProbeMs: number | null, nowMs: number, gapS: number = MIN_PROBE_GAP_S): boolean {
  if (lastProbeMs === null) return true;
  return nowMs - lastProbeMs >= gapS * 1000;
}

// HTTP Basic header for the Prometheus endpoint. base64(AK:SK). NEVER logged.
export function basicAuthHeader(accessKey: string, accessSecret: string): string {
  return "Basic " + Buffer.from(`${accessKey}:${accessSecret}`).toString("base64");
}

// Build the instant-query URL from the configured Prometheus URL. The
// operator-stored ALIBABA_QUOTA_PROM_URL is the workspace BASE URL; the
// instant-query endpoint lives at <base>/api/v1/query (verified live
// 2026-07-06 with the scoped key: base + "?query=" -> HTTP 404, base +
// "/api/v1/query?query=" -> HTTP 200 status=success). Accept either form:
// append the path segment only when it is not already present. Pure.
export function buildPromQueryUrl(promUrl: string): string {
  const trimmed = promUrl.trim();
  const qIdx = trimmed.indexOf("?");
  let path = (qIdx === -1 ? trimmed : trimmed.slice(0, qIdx)).replace(/\/+$/, "");
  const params = qIdx === -1 ? "" : trimmed.slice(qIdx + 1);
  if (!/\/api\/v1\/query$/.test(path)) path = `${path}/api/v1/query`;
  return params ? `${path}?${params}&query=model_usage` : `${path}?query=model_usage`;
}

// One fetch outcome. `ok` carries the raw body (string or parsed object —
// parseModelUsage accepts both); `rate_limited` is HTTP 429; `error` is any
// other failure (network, non-2xx, throw). The injected fetch maps errors to
// this shape so runProbe never sees a throw from the transport.
export type FetchResult =
  | { status: "ok"; body: unknown }
  | { status: "rate_limited" }
  | { status: "error"; message: string };

export type ProbeOutcome = "appended" | "skip-noenv" | "skip-fresh" | "skip-429" | "skip-error";

// Core probe. Every side effect is injected:
//   - markerMs    : last probe-attempt time (read by the caller), or null.
//   - fetchJson   : the Prometheus fetch (transport-mapped to FetchResult).
//   - append      : ledger append (one QuotaGaugeRecord).
//   - commitMarker: write the attempt time (called once a real fetch is about to
//                   happen, so a 429 / error also throttles for the gap).
//   - log         : stderr sink (default console.error); silent on noenv/fresh.
// Returns the outcome; never throws. The caller exits 0 regardless (best-effort).
export async function runProbe(opts: {
  env: Record<string, string | undefined>;
  nowMs: number;
  markerMs: number | null;
  gapS?: number;
  fetchJson: (url: string, authHeader: string) => Promise<FetchResult>;
  append: (row: QuotaGaugeRecord) => void;
  commitMarker?: () => void;
  log?: (msg: string) => void;
}): Promise<ProbeOutcome> {
  const aenv = alibabaEnv(opts.env);
  if (!alibabaEnvReady(aenv)) return "skip-noenv";          // silent — unconfigured
  if (!shouldProbe(opts.markerMs, opts.nowMs, opts.gapS)) return "skip-fresh"; // silent — throttled
  const log = opts.log ?? ((m: string) => console.error(m));
  opts.commitMarker?.();                                     // mark the attempt (throttle holds even on 429/error)

  let res: FetchResult;
  try {
    res = await opts.fetchJson(buildPromQueryUrl(aenv.promUrl!), basicAuthHeader(aenv.accessKey!, aenv.accessSecret!));
  } catch (e) {
    res = { status: "error", message: e instanceof Error ? e.message : String(e) };
  }

  if (res.status === "rate_limited") {
    log("alibaba-probe-once: HTTP 429 from Prometheus — backing off (skipping this probe)");
    return "skip-429";
  }
  if (res.status === "error") {
    log(`alibaba-probe-once: probe failed (${res.message}) — skipping`);
    return "skip-error";
  }

  const usage = parseModelUsage(res.body);
  if (usage === null) log("alibaba-probe-once: prometheus response unreadable or no total_tokens series — recording an invisible alibaba row");
  const grants = resolveGrants(usage, opts.env);
  for (const row of buildAlibabaRows(usage, grants, opts.nowMs)) opts.append(row);
  return "appended";
}

// ── .env cascade (parity with glm-env.ts:readZaiKey + mainCheckoutRoot) ───────
// process.env wins; then the worktree/repo .env; then the main-checkout .env
// (a worktree's .env is gitignored/absent — the real one lives in the main
// checkout, resolved via `git rev-parse --git-common-dir`). NOT imported from
// glm-env.ts to keep this runner self-contained and avoid its spawn-glm deps.
export function parseDotenv(envFile: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!existsSync(envFile)) return out;
  for (const raw of readFileSync(envFile, "utf8").split(/\r?\n/)) {
    const m = raw.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (v) out[m[1]] = v;
  }
  return out;
}

export function mainCheckoutRoot(repoRoot: string): string | undefined {
  try {
    const r = Bun.spawnSync(["git", "-C", repoRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) return undefined;
    const commonDir = r.stdout.toString().trim();
    if (!commonDir) return undefined;
    const parent = dirname(commonDir);
    return resolve(parent) !== resolve(repoRoot) ? parent : undefined;
  } catch { return undefined; }
}

export function loadAlibabaEnv(repoRoot: string): Record<string, string | undefined> {
  const merged: Record<string, string | undefined> = {};
  const mainRoot = mainCheckoutRoot(repoRoot);
  if (mainRoot) Object.assign(merged, parseDotenv(join(mainRoot, ".env")));   // lowest precedence
  Object.assign(merged, parseDotenv(join(repoRoot, ".env")));
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined) merged[k] = v; // process.env wins
  return merged;
}

// ── real I/O (main-only; never exercised by tests) ────────────────────────────
function readMarkerMs(path: string): number | null {
  if (!existsSync(path)) return null;
  const raw = readFileSync(path, "utf8").trim();
  if (!raw) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function writeMarkerMs(path: string, nowMs: number): void {
  const dir = dirname(path);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, String(nowMs), "utf8");
}

async function realFetchJson(url: string, authHeader: string): Promise<FetchResult> {
  try {
    const resp = await fetch(url, { headers: { Authorization: authHeader } });
    if (resp.status === 429) return { status: "rate_limited" };
    if (!resp.ok) return { status: "error", message: `HTTP ${resp.status}` };
    return { status: "ok", body: await resp.text() };
  } catch (e) {
    return { status: "error", message: e instanceof Error ? e.message : String(e) };
  }
}

const REPO_ROOT = fileURLToPath(new URL("../..", import.meta.url));

async function main(): Promise<void> {
  const env = loadAlibabaEnv(REPO_ROOT);
  const nowMs = Date.now();
  const mPath = markerPath(env);
  await runProbe({
    env,
    nowMs,
    markerMs: readMarkerMs(mPath),
    fetchJson: realFetchJson,
    append: (row) => appendQuotaGauge(row, ledgerPath(env)),
    commitMarker: () => writeMarkerMs(mPath, nowMs),
  });
  // rc 0 always — best-effort piggyback; never fails the dispatch.
}

if (import.meta.main) {
  main().catch((e) => { console.error(`alibaba-probe-once: fatal: ${e instanceof Error ? e.message : String(e)}`); });
}
