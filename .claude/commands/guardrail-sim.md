---
description: Pre-flight guardrail simulator — feed planned Bash commands on stdin and it flags/rewrites the predictable himmel guardrail collisions (compound→single, WSL-bash→Git Bash, destructive-git, on-main-write) + a curated learnings file, before they stall a run (HIMMEL-475).
---

Pre-flight guardrail simulator (HIMMEL-475, C1 of the autonomy-resilience epic).
Before running a planned batch of Bash commands, pipe them through the simulator
to catch the predictable guardrail collisions that would otherwise stall an
autonomous run (a denial, a permission hang, a destructive op). Static analysis
only — it never executes a command and relaxes **no** rail (advisory / rewrite).

Lean-invoke by design (HIMMEL-177): a static pre-check run on demand, NOT an
always-on hook (it cannot watch other sessions, so the learnings file is grown by
a deliberate append, not observation).

Built-in rules:
- **[wsl-bash]** — bare `bash ...` on Windows hits the WSL `System32` stub
  (can't read `C:/`, exit 127); rewritten to the explicit Git Bash path.
- **[compound]** — `&& || | ; $() backtick $var` makes the native permission
  matcher bail (HIMMEL-203) and hang in auto/headless; split into literal singles.
- **[destructive-git]** — `git reset --hard` / `git checkout --` discard work.
- **[on-main-write]** — a redirect into an in-repo path is block-edit-on-main
  territory; send report output to a temp dir.

Steps:

1. Pipe the planned commands (one per line) through the simulator:

   ```bash
   printf '%s\n' "cmd1" "cmd2" | bash scripts/guardrails/preflight-sim.sh
   ```

2. Read the per-command verdicts. Apply any `-> rewrite`, split flagged compounds
   into single commands, and reconsider destructive/on-main ops. Exit code is `0`
   when nothing is predicted, `1` when at least one collision is flagged.

3. When you hit a NEW recurring block during a run, append a `PATTERN|||VERDICT|||MESSAGE`
   line to `scripts/guardrails/preflight-learnings.txt` — the simulator reads it on
   the next invocation. (`VERDICT` = `FLAG` or `REFUSE`.)
