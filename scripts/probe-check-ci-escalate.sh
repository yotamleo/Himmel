#!/usr/bin/env bash
# probe-check-ci-escalate.sh — the escalation-only fast lane over
# scripts/test-check-ci.sh (HIMMEL-1964).
#
# WHY THIS EXISTS. test-check-ci.sh runs ~110 cases and takes ~51 minutes on
# Git-Bash (every case spawns dozens of stub processes), so nobody iterates on
# the escalation path against it. This SPLICES that suite instead of forking
# it: the real gh stub, the real run/assert helpers and the real ledger
# fixtures are extracted verbatim from the suite file, and only the --escalate
# cases are appended. There is no second copy of any fixture to drift, and a
# case edited in the suite is the case this runs.
#
# NOT a replacement for the suite — it proves nothing about the ~90 cases it
# skips. The full suite is still what CI runs.
#
# The name deliberately does NOT start with `test-`: run-shell-tests.sh
# discovers `**/test-*.sh`, and a discovered probe would re-run these cases a
# second time in every full pass.
#
# Usage: bash scripts/probe-check-ci-escalate.sh [case-number ...]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$SCRIPT_DIR/test-check-ci.sh"
[ -r "$SUITE" ] || { echo "FATAL: cannot read $SUITE" >&2; exit 1; }

# Every case whose verdict can turn on _cr_body_escalate: the A2 escalation
# block, the B2 (HIMMEL-1698) block, and the HIMMEL-1964 claim/retry block.
CASES=${*:-"44 45 46 47 48 49 50 51 52 77 78 79 80 81 82 83 84 85 86 90 91 92 93"}

WORK=$(mktemp -d) || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
SPLICED="$WORK/spliced.sh"

{
    # 1. Setup prefix: everything above the suite's first case (the gh stub,
    #    the run/assert helpers, the per-case overrides).
    awk '/^echo "test-check-ci\.sh"$/ { exit } { print }' "$SUITE"
    # The prefix derives SCRIPT from its OWN location; the splice runs out of a
    # temp dir, where that resolves to a check-ci.sh that does not exist and
    # every case fails rc 127. Re-point it at the real script under test.
    printf 'SCRIPT_DIR=%q\nSCRIPT=%q\n' "$SCRIPT_DIR" "$SCRIPT_DIR/check-ci.sh"
    # 2. The exact-head ledger fixture repos, which the suite builds mid-file
    #    (the escalate cases run inside them). From the first fixture line to
    #    the line before the first case that uses one.
    awk '/^EMPTY_LEDGER_REPO=/ { p=1 } p && /^run_in_repo /  { exit } p { print }' "$SUITE"
    echo 'echo "probe-check-ci-escalate.sh (spliced from test-check-ci.sh)"'
} > "$SPLICED"

# 3. The wanted case blocks, verbatim. A block runs from its `# <n> — ` header
#    to the blank line that follows its assertions; the seen-a-run guard keeps
#    a blank line inside a long comment header from ending the block early.
for c in $CASES; do
    if ! grep -q -- "^# $c — " "$SUITE"; then
        echo "FATAL: case $c not found in $SUITE (renumbered?)" >&2
        exit 1
    fi
    awk -v want="$c" '
        $0 ~ "^# " want " — " { p=1 }
        p && /^(run|run_in_repo) / { seen=1 }
        p && seen && /^[[:space:]]*$/ { p=0; seen=0; print ""; next }
        p { print }
    ' "$SUITE" >> "$SPLICED"
done

cat >> "$SPLICED" <<'FOOTER'
echo
echo "ran $COUNT cases; PASS=$PASS FAIL=$FAIL"
[ "$COUNT" -gt 0 ] || { echo "SPLICE ERROR: no case ran"; exit 1; }
[ "$FAIL" -eq 0 ] || exit 1
FOOTER

bash "$SPLICED"
