#!/usr/bin/env bash
# Smoke test for scripts/ci/fork-drift-issue.sh (HIMMEL-1046). Uses DRY_RUN=1
# so no gh, no auth, no network — asserts the issue-state decisions per guard
# exit code from the emitted DRY: gh command lines.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/fork-drift-issue.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

REP="$(mktemp)"; printf 'graphify: BEHIND (v0.9.16)\n' >"$REP"

# has/hasnt: assert a substring is present / absent in captured output.
has()   { if printf '%s' "$2" | grep -q "$1"; then ok "$3"; else bad "$3; out: $2"; fi; }
hasnt() { if printf '%s' "$2" | grep -q "$1"; then bad "$3; out: $2"; else ok "$3"; fi; }

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. Bad args -> usage exit 2.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exit=$rc (expected 2)"; fi
bash "$SCRIPT" 2 /no/such/file >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "missing report file -> exit 2"; else bad "missing report exit=$rc (expected 2)"; fi

# 3. rc=2, no existing issue -> create (never edit/close).
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 2 "$REP" 2>&1)"
has 'DRY: gh issue create' "$out" "rc2/no-issue -> creates"
has 'DRY: gh label create' "$out" "rc2 ensures marker label exists"
hasnt 'gh issue edit' "$out" "rc2/no-issue does not edit"
hasnt 'gh issue close' "$out" "rc2 never closes"

# 4. rc=2, existing issue #42 -> edit + comment, never create.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 2 "$REP" 2>&1)"
has 'DRY: gh issue edit 42' "$out" "rc2/existing -> edits #42 (refresh in place)"
has 'DRY: gh issue comment 42' "$out" "rc2/existing -> adds still-drifting comment"
hasnt 'gh issue create' "$out" "rc2/existing never creates a duplicate"

# 5. rc=0, existing issue #42 -> comment + close.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 0 "$REP" 2>&1)"
has 'DRY: gh issue close 42' "$out" "rc0/existing -> closes #42"
hasnt 'gh issue create' "$out" "rc0 never creates"

# 6. rc=0, no existing issue -> nothing.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 0 "$REP" 2>&1)"
hasnt 'DRY: gh issue ' "$out" "rc0/no-issue -> no gh issue mutation"

# 7. rc=3 (incomplete, documented) -> leave state unchanged, exit 0.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 3 "$REP" 2>&1)"; rc=$?
hasnt 'DRY: gh issue ' "$out" "rc3 -> issue state unchanged (proved nothing)"
if [ "$rc" -eq 0 ]; then ok "rc3 -> exit 0 (benign incomplete)"; else bad "rc3 exit=$rc (expected 0)"; fi

# 7b. Any OTHER guard exit (crash/127/usage) is NOT the 0/2/3 contract -> fail
#     (red), never a silent-green no-op that hides a broken guard.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="42" bash "$SCRIPT" 127 "$REP" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc127 (unexpected) -> exit 1 (broken guard is visible)"; else bad "rc127 exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue ' "$out" "rc127 -> no issue mutation"

# 8. Lookup failure (gh issue list errored) must NOT be treated as "no issue".
#    rc=2 + failed lookup -> bail (exit 1), never create a duplicate.
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 2 "$REP" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc2 + lookup-failure -> exit 1 (bail)"; else bad "rc2 + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue create' "$out" "rc2 + lookup-failure never creates (no duplicate)"
#    rc=0 + failed lookup -> propagate (exit 1) for consistency, never close blindly.
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 0 "$REP" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "rc0 + lookup-failure -> exit 1 (propagate)"; else bad "rc0 + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue close' "$out" "rc0 + lookup-failure never closes blindly"

rm -f "$REP"
echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
