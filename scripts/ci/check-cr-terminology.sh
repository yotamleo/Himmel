#!/usr/bin/env bash
# scripts/ci/check-cr-terminology.sh — CR means code review, never a
# CodeRabbit abbreviation (HIMMEL-3561, operator ruling 2026-09-24).
#
# himmel's docs use "CR" for the pre-PR code-review gate (the CR marker, the
# CR ledger, the critic panel, /pr-check). CodeRabbit is one best-effort
# reviewer inside that gate and is always spelled out — never abbreviated CR.
# This scans tracked docs for text that defines CR AS a CodeRabbit
# abbreviation (e.g. "CR is short for CodeRabbit"), the exact confusion
# HIMMEL-3561 found and fixed at docs/adoption-trail.html.
#
# Usage:
#   check-cr-terminology.sh [scan-dir ...]   # default: docs .claude/commands README.md CLAUDE.md marketplace
#
# Exit codes:
#   0 — no CodeRabbit-meaning abbreviation of CR found
#   1 — at least one match found
set -uo pipefail

if [ "$#" -gt 0 ]; then
  scan_targets=("$@")
else
  scan_targets=(docs .claude/commands README.md CLAUDE.md marketplace)
fi

existing=()
for t in "${scan_targets[@]}"; do
  [ -e "$t" ] && existing+=("$t")
done
[ "${#existing[@]}" -eq 0 ] && exit 0

# CR defined AS an abbreviation of CodeRabbit — "CR is short for CodeRabbit",
# "CR stands for CodeRabbit", etc. CodeRabbit spelled out elsewhere in the
# same doc is fine; only the definition-of-CR-as-CodeRabbit shape is banned.
matches=$(grep -rnE '\bCR\b[^.]{0,40}(is short for|stands for|means)[^.]{0,40}CodeRabbit' \
  --include='*.md' --include='*.html' \
  "${existing[@]}" 2>/dev/null || true)

if [ -n "$matches" ]; then
  printf 'ERROR: CR means code review, not CodeRabbit (HIMMEL-3561) — CodeRabbit is always spelled out:\n'
  printf '%s\n' "$matches"
  exit 1
fi

exit 0
