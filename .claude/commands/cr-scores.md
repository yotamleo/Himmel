---
description: Print the per-critic agreed/availability scorecard and surface drop advice
---

Run `bash scripts/cr/cr-scores.sh` (add `--window N` to narrow to the last N PRs; default 20).

Summarise the output:
1. Present the all-time and windowed per-model table (columns: total findings, agreed %, disproved %, conflict count, unaddressed count, availability %).
2. Surface any "consider dropping" lines verbatim — these fire when a model's agreed % is below `CR_SCORES_DROP_BELOW` (default 40) over at least `CR_SCORES_MIN_N` (default 10) findings.
3. If the ledger is empty, report the friendly "no critic scores recorded yet" message and stop.
