---
description: Mine the CR ledger for disproved classes per critic and draft citation-backed tuning proposals (.coderabbit.yaml / critics.json) — proposals only, never auto-applied
---

1. Run the mechanical miner and the scorecard:
   ```bash
   bash scripts/cr/cr-tune.sh
   bash scripts/cr/cr-scores.sh
   ```
2. Judgment layer (the session): map each disproved cluster / calibration flag / re-litigation signal to a named concept class (e.g. "test-fixture over-verification", "CR-round re-litigation", "docs-mirror noise"). Evidence bar: a proposal needs ≥3 supporting disproved rows from ONE cluster OR an operator-confirmed known-limitation pattern; anything thinner is listed under "weak signals — do not tune yet".
3. Draft proposals — each citing its ledger rows (`ts head finding_id file:line`):
   - `.coderabbit.yaml`: `reviews.path_instructions` additions/edits (path_instructions outrank CodeRabbit "learnings", so the yaml is the durable channel).
   - `scripts/cr/critics.json`: per-critic prompt/routing adjustments; confirm or contradict `cr-scores.sh` drop advice.
4. Write the proposals to `<handover-root>/cr-tune/proposals-YYYY-MM-DD.md` — resolve the root via `scripts/lib/handover-path.sh` using `handover_root_ensure` (NOT plain `handover_root`, which never mkdirs), then `mkdir -p "<root>/cr-tune"` before writing, and `test -f` the resulting file before surfacing the path. NEVER edit `.coderabbit.yaml` or `critics.json` in the same run — config changes are operator-approved PRs that cite the proposal file.
5. Re-run note: the miner is read-only and idempotent; re-running after new /pr-check rounds refreshes the clusters.
