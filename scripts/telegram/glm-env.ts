// scripts/telegram/glm-env.ts
// GLM lane env builder (HIMMEL-654 offload spike, spec: state repo
// specs/design/glm-worker-spawn.md D1).
// KEEP IN SYNC with the launcher family: scripts/claude-glm{,.ps1} (env block
// + .env quote-strip semantics) and scripts/claude-routed{,.ps1}.
// CLAUDE_CONFIG_DIR is deliberately NOT set: workers share ~/.claude so himmel
// hooks load; the settings-conflict preflight below replaces trust in
// process-env-vs-settings precedence (the launcher strips instead of trusting).
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

export const GLM_MODEL_ALIAS = "opus"; // maps via ANTHROPIC_DEFAULT_OPUS_MODEL

function parseZaiKeyFromEnv(envFile: string): string | undefined {
  if (!existsSync(envFile)) return undefined;
  for (const raw of readFileSync(envFile, "utf8").split(/\r?\n/)) {
    const m = raw.match(/^\s*(?:export\s+)?ZAI_API_KEY\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[1].trim();
    // one matching surrounding quote pair stripped — parity with claude-glm:26-29
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    return v || undefined;
  }
  return undefined;
}

// When the CLI runs from a git WORKTREE, repoRoot is the worktree root whose .env
// is gitignored / absent — the real .env lives in the MAIN checkout. git-common-dir
// resolves to <main>/.git; its parent is the main checkout root. Non-git dir / git
// failure → undefined (no fallback). Returns undefined when it equals repoRoot.
function mainCheckoutRoot(repoRoot: string): string | undefined {
  try {
    const r = Bun.spawnSync(["git", "-C", repoRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) return undefined;
    const commonDir = r.stdout.toString().trim();
    if (!commonDir) return undefined;
    const parent = dirname(commonDir);
    return resolve(parent) !== resolve(repoRoot) ? parent : undefined;
  } catch { return undefined; }
}

export function readZaiKey(repoRoot: string): { key?: string; tried: string[] } {
  if (process.env.ZAI_API_KEY?.trim()) return { key: process.env.ZAI_API_KEY.trim(), tried: [] };
  const tried: string[] = [];
  const primary = join(repoRoot, ".env");
  tried.push(primary);
  const k1 = parseZaiKeyFromEnv(primary);
  if (k1) return { key: k1, tried };
  const mainRoot = mainCheckoutRoot(repoRoot);
  if (mainRoot) {
    const fallback = join(mainRoot, ".env");
    tried.push(fallback);
    const k2 = parseZaiKeyFromEnv(fallback);
    if (k2) return { key: k2, tried };
  }
  return { tried };
}

export function buildGlmEnv(repoRoot: string, context?: "big" | "small"): Record<string, string> {
  const { key, tried } = readZaiKey(repoRoot);
  if (!key) throw new Error(`glm-env: ZAI_API_KEY not set and not found in any of: ${tried.join(", ")}`);
  // Context presets (HIMMEL-718): spawn-glm --context big|small sets GLM_CONTEXT,
  // which the runSession env path reads (an explicit `context` arg beats the env, so
  // direct callers + tests are deterministic). big = the [1m] 1M-context variant + a
  // 1M auto-compact window; small = glm-5.2 + 200k. CLAUDE_CODE_AUTO_COMPACT_WINDOW
  // stops Claude Code auto-compacting at ~200k — the documented "prompt too long"
  // deaths on this lane. HAIKU stays glm-4.7 (1M is main-only). Mirrors the
  // claude-glm{,.ps1} GLM_MODEL/GLM_CONTEXT_WINDOW knobs (those are the raw
  // operator-facing knobs on the interactive launchers; this is the orchestrator preset).
  const presets = { big: { model: "glm-5.2[1m]", window: "1000000" }, small: { model: "glm-5.2", window: "200000" } } as const;
  const ctx = context ?? (process.env.GLM_CONTEXT === "small" ? "small" : "big");
  const { model, window } = presets[ctx];
  return {
    ANTHROPIC_BASE_URL: "https://api.z.ai/api/anthropic",
    ANTHROPIC_AUTH_TOKEN: key,
    ANTHROPIC_MODEL: model,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "glm-4.7",
    ANTHROPIC_DEFAULT_SONNET_MODEL: model,
    ANTHROPIC_DEFAULT_OPUS_MODEL: model,
    CLAUDE_CODE_AUTO_COMPACT_WINDOW: window,
    // Worker context diet (HIMMEL-654): force-disable the env-gated
    // session-shaping injections. Two prompt-too-long deaths showed every
    // injected block costs context the GLM lane cannot spare, and none is
    // meaningful to an unattended worker. These keys merge over process.env in
    // glmChildEnv (run.ts), and the injector hooks read process-env-first, so a
    // falsy value here beats an operator-exported gate (the three that also
    // read a repo .env via load_dotenv keep it — non-clobber — so the falsy
    // value survives; check-update-available reads process env directly with no
    // .env fallback). A DELETED key would NOT work — load_dotenv refills unset
    // vars. PreToolUse guard hooks are unaffected — none of them read these
    // session-shaping keys (they have their own bypass vars, out of scope
    // here). The settings preflight (findSettingsConflicts) intentionally does
    // NOT flag a settings `env.HIMMEL_*` key — its charter is ANTHROPIC_* keys
    // that would fight the z.ai endpoint; a settings-level diet override is a
    // deliberate accepted gap (the operator opted in by editing settings).
    // Interactive claude-glm{,.ps1} launchers deliberately NOT mirrored: an
    // operator at the keyboard may want these injections; workers never do.
    HIMMEL_INITIATIVE: "0",
    HIMMEL_INITIATIVE_OVERNIGHT: "0",
    HIMMEL_OVERNIGHT: "0",
    HIMMEL_WHERE_ARE_WE: "0",
    HIMMEL_DOC_FRESHNESS: "0",
    UPDATE_CHECK_DISABLE: "1",
  };
}

// Structured conflict (spec D1/D4): the KIND — not a formatted string — is what
// planSpawn keys its warning-vs-refusal decision on, so the fail-closed choice
// isn't a stringly `.endsWith(": model")` cross-file coupling. Message
// formatting lives at the print/refusal-reason site via formatConflict.
export type SettingsConflict = { file: string; kind: "model" | "env" | "unparseable"; key?: string };

// Preflight (spec D1/D4): refuse to spawn when any merged settings layer could
// fight the GLM env block. Missing file = fine; unparseable = conflict (closed).
export function findSettingsConflicts(files: string[]): SettingsConflict[] {
  const out: SettingsConflict[] = [];
  for (const f of files) {
    if (!existsSync(f)) continue;
    let j: any;
    try { j = JSON.parse(readFileSync(f, "utf8")); } catch { out.push({ file: f, kind: "unparseable" }); continue; }
    if (j && typeof j === "object") {
      if ("model" in j) out.push({ file: f, kind: "model" });
      for (const k of Object.keys(j.env ?? {})) if (k.startsWith("ANTHROPIC_")) out.push({ file: f, kind: "env", key: k });
    }
  }
  return out;
}

// Human-readable rendering of a conflict — the `${file}: ${key}` strings the
// print (warnings) and refusal-reason sites emit.
export function formatConflict(c: SettingsConflict): string {
  return c.kind === "env" ? `${c.file}: env.${c.key}` : `${c.file}: ${c.kind}`;
}

// ── GLM cap guard (HIMMEL-654): monitor-endpoint client ─────────────────────
// Reverse-engineered endpoint (3 independent community tools; schema verified
// live in Task 0c — tests/fixtures/glm-cap/monitor-0c.json). percentage = USED.
// Contract: null on ANY failure (blank key, network, non-200, schema drift) —
// never a throw; callers print the "usage invisible" line on null (HIMMEL-275:
// invisible usage must be visible-invisible, not silently absent).
export type GlmUsage = { percentage: number; nextResetTime: number; level?: string };
const MONITOR_URL = "https://api.z.ai/api/monitor/usage/quota/limit";
const FIVE_H_MS = 5 * 3600_000;

// 5h-window selection rule (spec (b) 1.1): among limits[] entries with a
// FUTURE nextResetTime, the one <=5h out is the 5-hour window; none = drift.
export function pickFiveHourLimit(json: unknown, nowMs: number): GlmUsage | null {
  const data = (json as any)?.data;
  const limits = Array.isArray(data?.limits) ? data.limits : [];
  let best: GlmUsage | null = null;
  for (const l of limits) {
    const pct = Number(l?.percentage), reset = Number(l?.nextResetTime);
    if (!Number.isFinite(pct) || !Number.isFinite(reset)) continue;
    if (reset > nowMs && reset <= nowMs + FIVE_H_MS && (best === null || reset < best.nextResetTime)) {
      // smallest future reset among <=5h candidates (0c ambiguity guard): a
      // shorter sub-window entry must not shadow the true window by array
      // order, and the nearest reset is the conservative arm slot.
      best = { percentage: pct, nextResetTime: reset, ...(typeof data?.level === "string" ? { level: data.level } : {}) };
    }
  }
  return best;
}

export async function fetchGlmUsage(key: string | undefined, fetchImpl: typeof fetch = fetch, nowMs: number = Date.now()): Promise<GlmUsage | null> {
  if (!key?.trim()) return null;
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 5000);
    let r: Response;
    try { r = await fetchImpl(MONITOR_URL, { headers: { Authorization: `Bearer ${key}` }, signal: ctl.signal }); }
    finally { clearTimeout(t); }
    if (!r.ok) return null;
    return pickFiveHourLimit(await r.json(), nowMs);
    // broad catch is INTENTIONAL (null-on-any-failure contract): the external
    // failures (fetch/abort/json) are the target; pickFiveHourLimit is
    // asserted-total in tests, so a throw from it reaching here would be a
    // regression those tests catch — not a silent class we accept.
  } catch { return null; }
}
