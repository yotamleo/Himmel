---
name: pr-check
description: Panel-only CR gate for Codex — runs the shell critic panel over the branch diff and clears the CR marker only when the panel is clean. Use when the user asks to run /pr-check or clear the CR gate under Codex.
---

# pr-check (Codex panel-only subset)

This is the Codex subset of himmel's `/pr-check`: the cross-model **shell critic
panel** plus CR-marker handling. It does NOT dispatch the Claude
`pr-review-toolkit` reviewer agents, and there is NO per-finding verdict /
adjudication step. (Codex native `/review` integration is a post-HIMMEL-527
follow-up.)

## 1. Locate the marker

    branch=$(git branch --show-current)
    gitdir=$(git rev-parse --git-common-dir)
    marker="$gitdir/cr-pending/$branch"

If `$marker` is absent, report `no pending CR for $branch — nothing to do` and stop.

## 2. Lane check (HIMMEL-303)

    lane=$(awk -F' [|] ' '{print $3; exit}' "$marker" 2>/dev/null)

If `lane = docs-audit`: the code-critic panel is the wrong charter — **retain**
the marker and tell the operator to run the Claude `/pr-check` for docs lanes.
Stop. Only `lane = full` or empty proceeds.

## 3. Run the panel over the diff

    db=$(. scripts/guardrails/lib.sh 2>/dev/null && default_branch || echo main)
    # HIMMEL-558: load CR_PROFILE from the primary checkout's .env and export it.
    # Do NOT hand-compute a tier: critic-panel.sh resolves tiers from CR_PROFILE
    # itself (authoritative), so the paid critic can't be scoped out by hand.
    . scripts/lib/load-dotenv.sh; load_dotenv CR_PROFILE || true
    export CR_PROFILE
    diff_rc=0; diff_out=$(git diff "$db...HEAD") || diff_rc=$?
    if [ "$diff_rc" -ne 0 ] || [ -z "$diff_out" ]; then
        echo "diff unavailable/empty — marker retained"; exit 0
    fi
    panel_rc=0
    panel_out=$(printf '%s\n' "$diff_out" | bash scripts/cr/critic-panel.sh) || panel_rc=$?

`CR_PROFILE` (loaded from `.env`) is authoritative — the panel derives its tiers
from it; unset ⇒ the free fast panel.

## 4. Gate decision

- If `panel_rc != 0` (the panel header reports `0/N critics responded` →
  unavailable): **retain** the marker, report `panel unavailable — marker
  retained`, and point the operator at the `SKIP_CR=1` emergency bypass. Stop.
- Else parse the panel stdout. The header line is
  `# Critic Panel Review (M/N critics responded)` and the count lines are
  `## Critical Issues (C found)` / `## Important Issues (I found)`.
  - If `C = 0` AND `I = 0`: **clear** the marker — `rm -f "$marker"` — and report
    `CR clean — marker cleared (M/N critics responded)`, reading `M/N` from the
    header line. A clean clear only requires ≥1 critic to have responded; surface
    `M/N` so the operator sees coverage.
  - Otherwise: **retain** the marker and report the Critical/Important findings
    verbatim for the operator to fix and re-run.
