// scripts/telegram/glm-guard-verdict.ts — HIMMEL-2204 cross-language parity
// harness. Thin CLI over the REAL checkGlmGuards(), normalizing its {ok,
// reason} result to one coarse verdict label so a bash test can diff it
// against the bash-side reference verdict without depending on exact wording
// (test-glm-guard-parity.sh: "assert the VERDICT, not the mechanism").
// Not a runtime entry point for glm-guard.ts itself — test-only.
import { checkGlmGuards } from "./glm-guard";

const [, , cwd, cfgDir] = process.argv;
if (!cwd || !cfgDir) {
  console.error("usage: glm-guard-verdict.ts <cwd> <cfgDir>");
  process.exit(2);
}

const r = checkGlmGuards(cwd, cfgDir);
if (r.ok) {
  console.log("ALLOW");
} else {
  const reason = r.reason;
  let verdict = "DENY_OTHER";
  if (reason.includes("phi-roots") && reason.includes("not a readable file")) verdict = "DENY_UNREADABLE_PHI_ROOTS";
  else if (reason.includes("egress-denylist") && reason.includes("not a readable file")) verdict = "DENY_UNREADABLE_EGRESS_DENYLIST";
  else if (reason.includes("(.salus-profile)")) verdict = "DENY_SALUS_PROFILE";
  else if (reason.includes("(.salus)")) verdict = "DENY_SALUS";
  else if (reason.includes("PHI-marked (phi-roots)")) verdict = "DENY_PHI_ROOTS";
  else if (reason.includes("on the egress denylist")) verdict = "DENY_EGRESS_DENYLIST";
  console.log(verdict);
}
