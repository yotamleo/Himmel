---
name: guardrail-sim
description: Flag/rewrite predictable himmel guardrail collisions in planned bash commands. Use for /guardrail-sim.
---

# guardrail-sim

When the user wants to pre-flight planned bash commands, feed them on stdin:

    printf '%s\n' "cmd1" "cmd2" | bash scripts/guardrails/preflight-sim.sh

Report each flagged command, the predicted collision, and the suggested rewrite.
