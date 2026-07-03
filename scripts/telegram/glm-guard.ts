// scripts/telegram/glm-guard.ts
// PHI/egress guard for env-only GLM spawns (spec D2). An env-injection spawn
// bypasses the launcher's wrapper guards, so the SAME semantics are
// re-implemented here against the SAME config files.
// KEEP IN SYNC with scripts/claude-glm{,.ps1} path_under_any / guard block and
// scripts/claude-routed{,.ps1}. Fail-closed: unreadable guard config refuses.
// No --force override on this path (unattended lane; force stays interactive).
// NOTE (spec D2): dormant-by-construction in v1 (cwd is a spawn-created himmel
// worktree); ships for the vault follow-up + investigation blocker (b).
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";

type GuardResult = { ok: true } | { ok: false; reason: string };

function pathUnderAny(target: string, listFile: string): "hit" | "miss" | "unreadable" {
  if (!existsSync(listFile)) return "miss";
  let lines: string[];
  try {
    if (!statSync(listFile).isFile()) return "unreadable";
    lines = readFileSync(listFile, "utf8").split("\n");
  } catch { return "unreadable"; }
  const t = resolve(target) + sep;
  for (let root of lines) {
    root = root.replace(/\r$/, "").replace(/[\\/]+$/, "");
    if (!root) continue; // blank / CR-only line must not become a match-all root
    const r = resolve(root) + sep;
    if (t === r || t.startsWith(r)) return "hit";
  }
  return "miss";
}

export function checkGlmGuards(cwd: string, cfgDir: string = join(homedir(), ".config", "claude-glm")): GuardResult {
  if (existsSync(join(cwd, ".salus")))
    return { ok: false, reason: `glm-guard: REFUSED — ${cwd} is PHI-marked (.salus). No override exists.` };
  for (const [file, label] of [["phi-roots", "PHI-marked (phi-roots)"], ["egress-denylist", "on the egress denylist"]] as const) {
    const rc = pathUnderAny(cwd, join(cfgDir, file));
    if (rc === "unreadable")
      return { ok: false, reason: `glm-guard: guard config ${join(cfgDir, file)} exists but is not a readable file — failing closed.` };
    if (rc === "hit")
      return { ok: false, reason: `glm-guard: REFUSED — ${cwd} is ${label}. No override on the unattended GLM path.` };
  }
  return { ok: true };
}
