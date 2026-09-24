#!/usr/bin/env bash
# scripts/handover/console-kit/test-close-wrapped-leg.sh - suite for
# close-wrapped-leg.sh (HIMMEL-3572 row 7). Hermetic: a fake /proc root
# (CLAUDE_SESSIONS_PROC) with real NUL-separated <pid>/cmdline files drives
# claude_sessions() (same pattern as scripts/lanes/test-ceiling-conformance.sh),
# a PATH-stub `pgrep -x claude`, and PATH/env-var-injected `gh`/`kill`/
# `clean.sh` stubs. queue-lock.sh itself is real (acquire/release against a
# throwaway doc file) - no need to fake its locking semantics.
#
# Cases:
#   1. usage: no args / 2 args / unreadable doc          -> rc 2
#   2. held lock (a real acquire, not released)           -> rc 3
#   3. last Results marker is not WRAPPED                 -> rc 4
#   4. 0 matching live sessions                            -> rc 5, kill NOT called
#   5. 2 matching live sessions                             -> rc 5, kill NOT called
#   6. 1 match, 0 worktree paths in doc                    -> rc 0, clean.sh NOT called
#   7. 1 match, 2 worktree paths in doc                    -> rc 0, clean.sh NOT called
#   8. 1 match, 1 worktree, no MERGED/READY line             -> rc 0, clean.sh NOT called
#   9. 1 match, 1 worktree, PR state != MERGED               -> rc 0, clean.sh NOT called
#  10. 1 match, 1 worktree, PR MERGED, clean.sh succeeds      -> rc 0, kill called with the ONE matched pid, clean.sh called once
#  11. clean.sh output contains "in use"                    -> rc 0 (non-fatal)
#  12. clean.sh fails for another reason                    -> rc 1
#
# Platform guard: Linux bash 3.2+ (depends on /proc via claude-sessions.sh).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/close-wrapped-leg.sh"
QL="$HERE/../queue-lock.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/cwl-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then echo "ok - $1"; else echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); fi; }
not_contains() { if grep -q -F -e "$3" <<< "$2"; then echo "FAIL - $1: output unexpectedly contains [$3]"; fails=$((fails+1)); else echo "ok - $1"; fi; }

mkdir -p "$W/proc" "$W/bin" "$W/wt"
CALLS="$W/calls.log"

# mkcmdline <pid> <argv...> - a real NUL-separated /proc/<pid>/cmdline.
mkcmdline() {
    local pid="$1"; shift
    mkdir -p "$W/proc/$pid"
    printf '%s\0' "$@" > "$W/proc/$pid/cmdline"
}

# pgrep_x_stub <pid...> - `pgrep -x claude` stub returning these bare pids.
pgrep_x_stub() {
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016
        printf 'if [ "$1" = "-x" ]; then printf "%%s\\n" %s; exit 0; fi\n' "$*"
        printf 'exit 1\n'
    } > "$W/bin/pgrep"
    chmod +x "$W/bin/pgrep"
}
pgrep_x_stub   # default: no live sessions at all

KILL_STUB="$W/bin/kill"
cat > "$KILL_STUB" <<'STUB'
#!/usr/bin/env bash
echo "kill $*" >> "$CALLS_LOG"
exit 0
STUB
chmod +x "$KILL_STUB"

GH_STUB="$W/bin/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS_LOG"
case "$*" in
    "pr view "*)
        printf '%s' "${CWL_PR_STATE:-MERGED}"
        exit 0 ;;
esac
echo "gh-stub: unhandled args: $*" >&2
exit 1
STUB
chmod +x "$GH_STUB"

CLEAN_STUB="$W/bin/clean.sh"
cat > "$CLEAN_STUB" <<'STUB'
#!/usr/bin/env bash
echo "clean.sh $*" >> "$CALLS_LOG"
if [ "${CWL_CLEAN_MODE:-ok}" = "in-use" ]; then
    echo "worktree is in use, skipping"
    exit 1
fi
if [ "${CWL_CLEAN_MODE:-ok}" = "fail" ]; then
    echo "clean.sh: something else broke"
    exit 1
fi
echo "clean.sh: pruned"
exit 0
STUB
chmod +x "$CLEAN_STUB"

DOC="$W/HIMMEL-9-N1-demo-2026-01-01-RESUME.md"
SESSION_NAME="HIMMEL-9-N1-demo-2026-01-01"
WT="$W/wt/one"
mkdir -p "$WT/.claude/worktrees/demo"

mkdoc() { # mkdoc <last-marker-line> <extra-results-lines...>
    local marker="$1"; shift
    {
        echo "# HIMMEL-9 N1 demo leg"
        echo
        echo "## Results (newest at the bottom)"
        echo
        echo "- 09:00 LIVE - starting"
        for extra in "$@"; do echo "$extra"; done
        echo "$marker"
    } > "$DOC"
}

run() { # run <doc> - runs the script under test with every stub wired
    CALLS_LOG="$CALLS" PATH="$W/bin:$PATH" CLAUDE_SESSIONS_PROC="$W/proc" \
        GH_BIN="$GH_STUB" KILL_BIN="$KILL_STUB" CLEAN_SH_BIN="$CLEAN_STUB" \
        CWL_PR_STATE="${CWL_PR_STATE:-MERGED}" CWL_CLEAN_MODE="${CWL_CLEAN_MODE:-ok}" \
        bash "$SCRIPT" "$@"
}
reset_calls() { : > "$CALLS"; }
unset CWL_PR_STATE CWL_CLEAN_MODE

# --- 1. usage ----------------------------------------------------------------
reset_calls
rc=0; run >/dev/null 2>&1 || rc=$?
check "usage: no args -> rc 2" "$rc" "2"
rc=0; run "$DOC" extra >/dev/null 2>&1 || rc=$?
check "usage: 2 args -> rc 2" "$rc" "2"
rc=0; run "$W/no-such-doc.md" >/dev/null 2>&1 || rc=$?
check "usage: unreadable doc -> rc 2" "$rc" "2"

# --- 2. held lock --------------------------------------------------------------
mkdoc "- 10:00 WRAPPED - done"
reset_calls
acq_out="$(bash "$QL" acquire "$DOC" "cwl-test-holder" 2>&1)"
token="$(printf '%s' "$acq_out" | sed -n "s/.*release-token: \`\([^\`]*\)\`.*/\\1/p")"
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "held-lock: rc 3" "$rc" "3"
[ -n "$token" ] && bash "$QL" release "$DOC" "$token" >/dev/null 2>&1

# --- 3. not WRAPPED ------------------------------------------------------------
mkdoc "- 10:00 LIVE - still going"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "not-wrapped: rc 4" "$rc" "4"

# --- 4. 0 matching sessions ------------------------------------------------------
mkdoc "- 10:00 WRAPPED - done"
mkcmdline 201 claude -n SOME-OTHER-SESSION work
pgrep_x_stub 201
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "zero-match: rc 5" "$rc" "5"
check "zero-match: kill never called" "$(cat "$CALLS")" ""

# --- 5. 2 matching sessions -------------------------------------------------------
mkcmdline 202 claude -n "$SESSION_NAME" work
mkcmdline 203 claude -n "$SESSION_NAME" work
pgrep_x_stub 202 203
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "two-match: rc 5" "$rc" "5"
check "two-match: kill never called" "$(cat "$CALLS")" ""

# --- from here: exactly one match --------------------------------------------
rm -rf "$W/proc"; mkdir -p "$W/proc"
mkcmdline 210 claude -n "$SESSION_NAME" work
pgrep_x_stub 210

# --- 6. 1 match, 0 worktree paths ------------------------------------------------
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "no-worktree: rc 0" "$rc" "0"
contains "no-worktree: kill still called" "$(cat "$CALLS")" "kill -TERM 210"
not_contains "no-worktree: clean.sh not called" "$(cat "$CALLS")" "clean.sh"

# --- 7. 1 match, 2 worktree paths -------------------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`" "worktree: \`$W/wt/.claude/worktrees/other\`"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "two-worktree: rc 0" "$rc" "0"
not_contains "two-worktree: clean.sh not called" "$(cat "$CALLS")" "clean.sh"

# --- 8. 1 match, 1 worktree, no MERGED/READY line -----------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "no-pr-line: rc 0" "$rc" "0"
not_contains "no-pr-line: clean.sh not called" "$(cat "$CALLS")" "clean.sh"

# --- 9. 1 match, 1 worktree, PR not merged ------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`" "- 09:30 READY 42 deadbeef GREEN"
reset_calls
rc=0; out=$(CWL_PR_STATE="OPEN" run "$DOC" 2>&1) || rc=$?
check "pr-not-merged: rc 0" "$rc" "0"
not_contains "pr-not-merged: clean.sh not called" "$(cat "$CALLS")" "clean.sh"

# --- 10. clean success path ----------------------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`" "- 09:45 MERGED #42 -> deadbeef"
reset_calls
rc=0; out=$(CWL_PR_STATE="MERGED" run "$DOC" 2>&1) || rc=$?
check "clean-success: rc 0" "$rc" "0"
calls="$(cat "$CALLS")"
contains "clean-success: kill called with the matched pid" "$calls" "kill -TERM 210"
contains "clean-success: clean.sh called once" "$calls" "clean.sh --only $WT/.claude/worktrees/demo"

# --- 11. clean.sh reports in-use ------------------------------------------------
reset_calls
rc=0; out=$(CWL_PR_STATE="MERGED" CWL_CLEAN_MODE="in-use" run "$DOC" 2>&1) || rc=$?
check "clean-in-use: rc 0 (non-fatal)" "$rc" "0"
contains "clean-in-use: names it" "$out" "in use"

# --- 12. clean.sh fails for another reason --------------------------------------
reset_calls
rc=0; out=$(CWL_PR_STATE="MERGED" CWL_CLEAN_MODE="fail" run "$DOC" 2>&1) || rc=$?
check "clean-fail: rc 1" "$rc" "1"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "ALL OK"
    exit 0
else
    echo "FAILURES: $fails"
    exit 1
fi
