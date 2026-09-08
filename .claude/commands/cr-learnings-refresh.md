---
description: Refresh known-findings.json evidence from the CR ledger + a CodeRabbit learnings export; lists new-class candidates
---

Lean-invoke — run after a CodeRabbit learnings export lands in Downloads, or
when `/pr-check` step 2.8 keeps printing `known-findings: round-1 hits = N` with
N > 0. No cadence: the export is a manual download and the ledger mining is
cheap enough to run on demand.

1. Refresh evidence (ledger always; the export when you have one):
   ```bash
   bash scripts/cr/known-findings.sh --refresh --learnings "<path-to-export>.csv"
   ```
   (`--refresh` alone re-mines only the ledger.) This rewrites ONLY each class's
   `evidence` block, `refreshed_at`, and (with `--learnings`) the top-level
   `learnings_export` summary; titles, globs, detectors and canonical
   texts are hand-curated and untouched.
2. Judgment layer (the session): read the "Top unmatched" list. A learning with
   ≥ 50 uses, or any class the step-2.8 hit counter keeps naming, becomes a new
   entry in `scripts/cr/known-findings.json` — pick `kind` (fix / rebuttal /
   checklist), a deterministic `detector` where one exists, and a `learning_match`
   regex so the next refresh attributes it. A learning that merely restates a
   rule a shell-lint check or `.coderabbit.yaml` instruction already enforces is
   NOT a new class — note the coverage instead.
3. `bash scripts/cr/test-known-findings.sh` must stay green; if ids changed,
   paste the output of `bash scripts/cr/known-findings.sh --list` over the class
   table in [`docs/internals/known-findings.md`](../../docs/internals/known-findings.md)
   (it prints the table; nothing edits the doc for you). Land it as a normal
   branch + PR (the JSON is versioned; it feeds every critic prompt).
