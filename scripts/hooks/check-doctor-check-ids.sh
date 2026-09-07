#!/usr/bin/env bash
# scripts/hooks/check-doctor-check-ids.sh -- Guard A (HIMMEL-2664).
#
# Pins the check_cNN() namespace in scripts/himmel-doctor.sh. Two branches
# that each add a check_cNN() with a different next-free-ID guess still
# collide when one rebases onto the other -- C32 collided twice in one
# afternoon (2026-09-06): PR #2195 and HIMMEL-2653 both independently picked
# check_c32(), and renumbering to C33 would have collided again with an
# unmerged branch that had already taken it.
#
# Git catches a textual conflict, but not:
#   1. two additions far enough apart in the file to merge textually clean --
#      bash then silently shadows the earlier definition, which stops
#      running and emits nothing.
#   2. a hand-resolved "keep both sides" conflict resolution that leaves two
#      function bodies for one ID and only one call-list entry -- the same
#      silent shadowing, arrived at by hand instead of by git.
#   3. a defined check dropped from the call list during a resolution --
#      equally silent.
# So this checks the POST-RESOLUTION artifact (the staged file), not the
# diff that produced it -- a clean auto-merge is not evidence of correctness
# here (see scripts/hooks/CLAUDE.md's merge-hazard note, extended by this
# same change to name this namespace).
#
# Invariants over scripts/himmel-doctor.sh's STAGED content:
#   1. every check_cNN(...)() is defined exactly once per numeric ID
#   2. every defined function NAME is invoked exactly once, by that exact
#      name, in the flat call list at the tail of the file. The C1 call is
#      conditional (`if ...; then fix_c1_guardrail; else check_c1_guardrail;
#      fi`) but its single literal occurrence of check_c1_guardrail already
#      counts as one call under a plain text scan -- no special-casing
#      needed. Matched by exact NAME, not just numeric ID: a call to
#      check_c3_bar when only check_c3_foo is defined shares an ID but is a
#      real bug (a call-list typo/stale rename that crashes the doctor at
#      runtime) -- comparing IDs alone would wave that through.
#   3. a defined-but-never-called function and a called-but-never-defined
#      function both fail. Comment lines in the call-list section are
#      excluded from the scan, so a comment mentioning a check can never
#      create a false duplicate call or satisfy a commented-out one.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + grep/sed/comm text processing; no .ps1 twin needed.
#
# Fail-closed. A silently-shadowed check is exactly the invisible failure
# this gate exists to catch, so an infrastructure error here (an unreadable
# staged blob, a missing "# --- run" anchor) refuses the commit rather than
# waving it through. Single-run bypass: DOCTOR_CHECK_IDS_OK=1.
#
# Exit codes: 0 = clean, 1 = collision, drift, or a read/structure failure.
set -uo pipefail

if [ "${DOCTOR_CHECK_IDS_OK:-0}" = 1 ]; then
    echo "check-doctor-check-ids: DOCTOR_CHECK_IDS_OK=1 -- skipping (bypass used)" >&2
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/lib/git-show-safe.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/git-show-safe.sh"

# Repo root is resolved from the CWD's git context (not SCRIPT_DIR) so this
# gate can be exercised in place against a throwaway fixture repo -- same
# pattern as check-doc-guard.sh (see its test's Step 0 comment).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    echo "FAIL: check-doctor-check-ids: not inside a git repository" >&2
    exit 1
fi
cd "$REPO_ROOT" || { echo "FAIL: check-doctor-check-ids: cannot cd to repo root $REPO_ROOT" >&2; exit 1; }

TARGET="scripts/himmel-doctor.sh"
content="$(git_show_safe "" "$TARGET")" || {
    echo "FAIL: check-doctor-check-ids: cannot read staged $TARGET" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Definitions: every line that opens a check_cNN...() function.
# ---------------------------------------------------------------------------
def_names="$(printf '%s\n' "$content" | grep -oE '^check_c[0-9]+[A-Za-z0-9_]*\(\)' | sed -E 's/\(\)$//')"

if [ -z "$def_names" ]; then
    echo "FAIL: check-doctor-check-ids: no check_cNN() definitions found in $TARGET -- structure changed underneath this gate?" >&2
    exit 1
fi

def_ids="$(printf '%s\n' "$def_names" | sed -E 's/^check_c([0-9]+).*/\1/')"

# ---------------------------------------------------------------------------
# Calls: the flat call list after the "# --- run" marker, scanned for
# check_cNN...() tokens. Scoped to that section so a check_cNN mention
# inside an earlier function BODY (a log message, a comment) is never
# mistaken for a call.
# ---------------------------------------------------------------------------
run_marker_line="$(printf '%s\n' "$content" | grep -n '^# --- run' | head -1 | cut -d: -f1)"
if [ -z "$run_marker_line" ]; then
    echo "FAIL: check-doctor-check-ids: no '# --- run' marker found in $TARGET -- cannot locate the call list" >&2
    exit 1
fi
run_section="$(printf '%s\n' "$content" | tail -n "+$run_marker_line")"

# Comment lines excluded before the call scan (a comment mentioning a check
# must never create a false duplicate, and a commented-out call must never
# satisfy the invariant).
run_section_nocomment="$(printf '%s\n' "$run_section" | grep -vE '^[[:space:]]*#')"

call_names="$(printf '%s\n' "$run_section_nocomment" | grep -oE 'check_c[0-9]+[A-Za-z0-9_]*')"
if [ -z "$call_names" ]; then
    echo "FAIL: check-doctor-check-ids: no check_cNN calls found after the '# --- run' marker in $TARGET" >&2
    exit 1
fi

fail=0

# Invariant 1: every defined ID appears exactly once as a definition.
dup_def_ids="$(printf '%s\n' "$def_ids" | sort | uniq -d)"
if [ -n "$dup_def_ids" ]; then
    fail=1
    echo "FAIL: check-doctor-check-ids: duplicate check ID definition(s) in $TARGET:" >&2
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        names="$(printf '%s\n' "$def_names" | grep -E "^check_c${id}([^0-9]|$)")"
        echo "  C${id}: defined more than once --" >&2
        printf '%s\n' "$names" | sed 's/^/    /' >&2
    done <<EOF
$dup_def_ids
EOF
fi

# Invariant 2a: every defined NAME is called exactly once (by exact name,
# not just ID -- see the header note).
dup_call_names="$(printf '%s\n' "$call_names" | sort | uniq -d)"
if [ -n "$dup_call_names" ]; then
    fail=1
    echo "FAIL: check-doctor-check-ids: function(s) called more than once in $TARGET's call list:" >&2
    printf '%s\n' "$dup_call_names" | sed 's/^/  /' >&2
fi

# Invariant 2b: defined-but-never-called (by exact name).
never_called="$(comm -23 <(printf '%s\n' "$def_names" | sort -u) <(printf '%s\n' "$call_names" | sort -u))"
if [ -n "$never_called" ]; then
    fail=1
    echo "FAIL: check-doctor-check-ids: function(s) defined but never called in $TARGET:" >&2
    printf '%s\n' "$never_called" | sed 's/^/  /' >&2
fi

# Invariant 2c: called-but-never-defined (by exact name) -- catches a
# call-list entry whose ID matches a defined function but whose name does
# not (e.g. check_c3_bar called, only check_c3_foo defined): that call
# crashes himmel-doctor.sh at runtime ("command not found"), which an
# ID-only comparison would wave through as "ID 3 satisfied".
never_defined="$(comm -13 <(printf '%s\n' "$def_names" | sort -u) <(printf '%s\n' "$call_names" | sort -u))"
if [ -n "$never_defined" ]; then
    fail=1
    echo "FAIL: check-doctor-check-ids: function(s) called but never defined in $TARGET:" >&2
    printf '%s\n' "$never_defined" | sed 's/^/  /' >&2
fi

if [ "$fail" -ne 0 ]; then
    echo "Fix: give each check_cNN() a unique numeric ID and make sure it is invoked exactly once in the call list at the tail of $TARGET." >&2
    echo "Bypass (single run, leaves the collision unfixed): DOCTOR_CHECK_IDS_OK=1 git commit ..." >&2
    exit 1
fi

echo "OK: check-doctor-check-ids: $(printf '%s\n' "$def_ids" | sort -u | wc -l | tr -d ' ') check IDs, each defined once and called once."
exit 0
