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

function readZaiKey(repoRoot: string): { key?: string; tried: string[] } {
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

export function buildGlmEnv(repoRoot: string): Record<string, string> {
  const { key, tried } = readZaiKey(repoRoot);
  if (!key) throw new Error(`glm-env: ZAI_API_KEY not set and not found in any of: ${tried.join(", ")}`);
  return {
    ANTHROPIC_BASE_URL: "https://api.z.ai/api/anthropic",
    ANTHROPIC_AUTH_TOKEN: key,
    ANTHROPIC_MODEL: "glm-5.2",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "glm-4.7",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "glm-5.2",
    ANTHROPIC_DEFAULT_OPUS_MODEL: "glm-5.2",
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
