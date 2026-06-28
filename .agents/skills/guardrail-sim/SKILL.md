---
name: guardrail-sim
description: Pre-flight guardrail simulator — flags/rewrites predictable himmel guardrail collisions in planned bash commands before they stall a run. Use when the user asks to simulate guardrails or run /guardrail-sim.
---

# guardrail-sim

When the user wants to pre-flight planned bash commands, feed them on stdin:

    printf '%s\n' "cmd1" "cmd2" | bash scripts/guardrails/preflight-sim.sh

Report each flagged command, the predicted collision, and the suggested rewrite.
