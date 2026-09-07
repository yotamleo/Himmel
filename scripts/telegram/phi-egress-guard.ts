// scripts/telegram/phi-egress-guard.ts
// PHI/egress guard for env-injected worker spawns (spec D2). An env-injection
// spawn bypasses the launcher's wrapper guards, so the SAME semantics are
// re-implemented here against the SAME config files.
//
// Named for the invariant it enforces, not the lane that first needed it
// (HIMMEL-2622): this was `glm-guard.ts` until the GLM/Zhipu lane was dropped
// (operator ruling 2026-08-19; `zai-glm` de-listed from the egress matrix
// 2026-08-29, HIMMEL-2224). The predicate is a property of the target
// DIRECTORY — is it PHI-marked or egress-denied — so it outlives any one lane.
//
// KEEP IN SYNC with scripts/claude-glm{,.ps1} path_under_any / guard block and
// scripts/claude-routed{,.ps1}. Fail-closed: unreadable guard config refuses.
// No --force override on this path (unattended lane; force stays interactive).
//
// The `cfgDir` default below is a DEPLOYED on-disk path shared with
// scripts/claude-glm, and scripts/guardrails/egress-matrix.json defines the
// `salus` corpus in exactly those path terms. It is deliberately NOT renamed
// with this module: changing it would stop reading operators' existing lists —
// a fail-OPEN regression on a PHI fence — and put the code out of step with
// the authoritative matrix. Rename the module, never the config contract.
//
// NOTE (spec D2): dormant-by-construction in v1 (cwd is a spawn-created himmel
// worktree); ships for the vault follow-up + investigation blocker (b).
// HIMMEL-2626: spawn-claudex.ts deliberately does NOT call this module — it
// calls scripts/claude-codex's own `--guard-check <dir>` check-only entry
// instead, so the launcher stays the single owner of that lane's PHI/egress
// verdict (two recognisers over the same directory could reach different
// answers; one owner means they can't). This module remains the
// env-injected-spawn path's implementation (spawn-glm.ts) and the TypeScript
// side of scripts/telegram/test-phi-egress-guard-parity.sh's cross-lane check.
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

export function checkPhiEgressGuards(cwd: string, cfgDir: string = join(homedir(), ".config", "claude-glm")): GuardResult {
  // .salus / .salus-profile root marker (#850, HIMMEL-2173): existsSync fails
  // OPEN (returns false on a stat error like EACCES/EIO), which would let an
  // unreadable marker slip through as "not PHI". statSync distinguishes a real
  // ENOENT (absent) from any other stat error, failing CLOSED — matching the
  // pathUnderAny list checks' posture below. .salus-profile (template
  // machinery dropped by the salus profile installer) is accepted too — a
  // defense for deployments that predate the installer shipping the real
  // .salus guard marker alongside it.
  for (const marker of [".salus", ".salus-profile"]) {
    try {
      statSync(join(cwd, marker));
      return { ok: false, reason: `phi-egress-guard: REFUSED — ${cwd} is PHI-marked (${marker}). No override exists.` };
    } catch (e) {
      const code = (e as NodeJS.ErrnoException | undefined)?.code;
      if (code !== "ENOENT")
        return { ok: false, reason: `phi-egress-guard: ${marker} at ${cwd} is not a readable stat target (stat code ${code ?? "?"}) — failing closed.` };
    }
  }
  for (const [file, label] of [["phi-roots", "PHI-marked (phi-roots)"], ["egress-denylist", "on the egress denylist"]] as const) {
    const rc = pathUnderAny(cwd, join(cfgDir, file));
    if (rc === "unreadable")
      return { ok: false, reason: `phi-egress-guard: guard config ${join(cfgDir, file)} exists but is not a readable file — failing closed.` };
    if (rc === "hit")
      return { ok: false, reason: `phi-egress-guard: REFUSED — ${cwd} is ${label}. No override on the unattended spawn path.` };
  }
  return { ok: true };
}
