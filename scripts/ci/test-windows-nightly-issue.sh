#!/usr/bin/env bash
# Smoke test for scripts/ci/windows-nightly-issue.sh (HIMMEL-3125). Uses
# DRY_RUN=1 so no gh, no auth, no network — asserts the issue-state decisions
# per bun-suites (windows-latest) outcome from the emitted DRY: gh command
# lines. Modeled on scripts/ci/test-fork-drift-issue.sh.
#
# Platform guard (gitbash-only): tests a script invoked from the
# windows-latest leg itself -- pure bash; no .ps1 twin needed.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (HIMMEL-1430: this file runs under `set -o pipefail`, where a
# pipe into `grep -q` can report a successful match as failed via SIGPIPE).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/windows-nightly-issue.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

has()   { if grepq "$2" "$1"; then ok "$3"; else bad "$3; out: $2"; fi; }
hasnt() { if grepq "$2" "$1"; then bad "$3; out: $2"; else ok "$3"; fi; }

RUN_URL="https://github.com/yotamleo/Himmel/actions/runs/0"

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# 2. Bad args -> usage exit 2.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "no args -> exit 2"; else bad "no args exit=$rc (expected 2)"; fi

# 3. Red (rc=1), no existing issue -> create (never edit/close).
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
has 'DRY: gh issue create' "$out" "red/no-issue -> creates"
has 'DRY: gh label create' "$out" "red ensures marker label exists"
hasnt 'gh issue edit' "$out" "red/no-issue does not edit"
hasnt 'gh issue close' "$out" "red never closes"

# 4. Red, existing issue #7 -> edit + comment, never create.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="7" bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"
has 'DRY: gh issue edit 7' "$out" "red/existing -> edits #7 (refresh in place)"
has 'DRY: gh issue comment 7' "$out" "red/existing -> adds still-red comment"
hasnt 'gh issue create' "$out" "red/existing never creates a duplicate"

# 5. Green (rc=0), existing issue #7 -> comment + close.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="7" bash "$SCRIPT" 0 "$RUN_URL" 2>&1)"
has 'DRY: gh issue close 7' "$out" "green/existing -> closes #7"
hasnt 'gh issue create' "$out" "green never creates"

# 6. Green, no existing issue -> nothing.
out="$(DRY_RUN=1 DRY_RUN_OPEN_ISSUE="" bash "$SCRIPT" 0 "$RUN_URL" 2>&1)"
hasnt 'DRY: gh issue ' "$out" "green/no-issue -> no gh issue mutation"

# 7. Lookup failure (gh issue list errored) must NOT be treated as "no issue".
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 1 "$RUN_URL" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "red + lookup-failure -> exit 1 (bail)"; else bad "red + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue create' "$out" "red + lookup-failure never creates (no duplicate)"
out="$(DRY_RUN=1 DRY_RUN_LOOKUP_FAIL=1 bash "$SCRIPT" 0 "$RUN_URL" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then ok "green + lookup-failure -> exit 1 (propagate)"; else bad "green + lookup-failure exit=$rc (expected 1)"; fi
hasnt 'DRY: gh issue close' "$out" "green + lookup-failure never closes blindly"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
