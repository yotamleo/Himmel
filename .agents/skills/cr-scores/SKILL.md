---
name: cr-scores
description: Print the per-critic agreed/availability scorecard and surface drop advice. Use when the user asks for CR critic scores or runs /cr-scores.
---

# cr-scores

When the user asks for the critic scorecard, run:

    bash scripts/cr/cr-scores.sh [--window N]

`--window N` narrows to the last N PRs (default 20). Summarise the all-time +
windowed per-model table (total findings, agreed %, disproved %, conflict count,
unaddressed count, availability %) and surface any "consider dropping" lines
verbatim. If the ledger is empty, report "no critic scores recorded yet" and stop.
See `.claude/commands/cr-scores.md`.
