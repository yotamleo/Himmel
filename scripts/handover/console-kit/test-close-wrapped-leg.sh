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
#  13. gh pr view itself fails (auth/connectivity)           -> rc 1, clean.sh NOT called
#  14. the TERM signal itself fails                          -> rc 1, no pruning attempted
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
# exact_count <label> <haystack> <exact-line> <expected-count> - a substring
# `contains` passes if the script ALSO signaled another pid or called
# clean.sh twice; this counts exact-line occurrences so an extra/duplicate
# call fails the assertion.
exact_count() { local n; n=$(grep -c -F -x -e "$3" <<< "$2"); if [ "$n" = "$4" ]; then echo "ok - $1"; else echo "FAIL - $1: expected $4 occurrence(s) of [$3], got $n"; fails=$((fails+1)); fi; }

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
if [ "${CWL_KILL_FAIL:-0}" = "1" ]; then
    exit 1
fi
exit 0
STUB
chmod +x "$KILL_STUB"

GH_STUB="$W/bin/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS_LOG"
case "$*" in
    "pr view "*)
        if [ "${CWL_PR_VIEW_FAIL:-0}" = "1" ]; then
            echo "gh-stub: pr view forced failure (auth/connectivity)" >&2
            exit 1
        fi
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
    # END_SESSION_WIKI_BIN/CLOSE_WRAPPED_LEG_PROJECTS_DIR default to a no-op
    # binary and a nonexistent dir, so cases 1-14 never exercise the
    # pre-signal capture block (HIMMEL-3629) at all - only the cases below
    # that set CWL_ESW_BIN/CWL_PROJECTS_DIR opt into it.
    CALLS_LOG="$CALLS" PATH="$W/bin:$PATH" CLAUDE_SESSIONS_PROC="$W/proc" \
        GH_BIN="$GH_STUB" KILL_BIN="$KILL_STUB" CLEAN_SH_BIN="$CLEAN_STUB" \
        CWL_PR_STATE="${CWL_PR_STATE:-MERGED}" CWL_CLEAN_MODE="${CWL_CLEAN_MODE:-ok}" \
        CWL_PR_VIEW_FAIL="${CWL_PR_VIEW_FAIL:-0}" CWL_KILL_FAIL="${CWL_KILL_FAIL:-0}" \
        END_SESSION_WIKI_BIN="${CWL_ESW_BIN:-/bin/true}" \
        CLOSE_WRAPPED_LEG_PROJECTS_DIR="${CWL_PROJECTS_DIR:-$W/no-such-projects-dir}" \
        bash "$SCRIPT" "$@"
}
reset_calls() { : > "$CALLS"; }
unset CWL_PR_STATE CWL_CLEAN_MODE CWL_PR_VIEW_FAIL CWL_KILL_FAIL

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
calls6="$(cat "$CALLS")"
exact_count "no-worktree: kill called exactly once with the matched pid" "$calls6" "kill -TERM 210" "1"
not_contains "no-worktree: clean.sh not called" "$calls6" "clean.sh"
check "no-worktree: exactly one call logged (no other pid signaled)" "$(wc -l < "$CALLS" | tr -d ' ')" "1"

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
exact_count "clean-success: kill called exactly once with the matched pid" "$calls" "kill -TERM 210" "1"
exact_count "clean-success: clean.sh called exactly once" "$calls" "clean.sh --only $WT/.claude/worktrees/demo" "1"
exact_count "clean-success: gh pr view called exactly once" "$calls" "gh pr view 42 --json state --jq .state" "1"
check "clean-success: exactly 3 calls logged (no extra kill/clean.sh)" "$(wc -l < "$CALLS" | tr -d ' ')" "3"

# --- 11. clean.sh reports in-use ------------------------------------------------
reset_calls
rc=0; out=$(CWL_PR_STATE="MERGED" CWL_CLEAN_MODE="in-use" run "$DOC" 2>&1) || rc=$?
check "clean-in-use: rc 0 (non-fatal)" "$rc" "0"
contains "clean-in-use: names it" "$out" "in use"

# --- 12. clean.sh fails for another reason --------------------------------------
reset_calls
rc=0; out=$(CWL_PR_STATE="MERGED" CWL_CLEAN_MODE="fail" run "$DOC" 2>&1) || rc=$?
check "clean-fail: rc 1" "$rc" "1"

# --- 13. gh pr view itself fails -------------------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`" "- 09:45 MERGED #42 -> deadbeef"
reset_calls
rc=0; out=$(CWL_PR_VIEW_FAIL="1" run "$DOC" 2>&1) || rc=$?
check "pr-view-fail: rc 1" "$rc" "1"
not_contains "pr-view-fail: clean.sh not called" "$(cat "$CALLS")" "clean.sh"
contains "pr-view-fail: names the reason" "$out" "gh pr view"

# --- 14. the TERM signal itself fails ---------------------------------------------
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0; out=$(CWL_KILL_FAIL="1" run "$DOC" 2>&1) || rc=$?
check "kill-fail: rc 1" "$rc" "1"
not_contains "kill-fail: clean.sh not called" "$(cat "$CALLS")" "clean.sh"
not_contains "kill-fail: never claims it sent TERM" "$out" "sent TERM"

# --- 15: pre-signal session-note capture (HIMMEL-3629 direction 2) -----------
# Before signalling, the script must resolve the ONE matching leg's transcript
# (via a customTitle grep over CLOSE_WRAPPED_LEG_PROJECTS_DIR, like leg-burn.sh's
# session lookup) and feed it to the REAL end-session-wiki.sh hook, which then
# writes a session note into a scratch vault - all before the TERM in case 10
# ever fires. This exercises the real hook end-to-end, never a stub, so the
# assertion is the artifact (a note file), not a logged call.
REAL_ESW="$HERE/../../hooks/end-session-wiki.sh"
[ -r "$REAL_ESW" ] || { echo "FAIL - pre-signal-capture: real hook not found at $REAL_ESW"; fails=$((fails+1)); }

ESW_SB="$W/esw-sb"
mkdir -p "$ESW_SB/vault" "$ESW_SB/proj" "$ESW_SB/home"
PROJDIR="$W/esw-projects"
mkdir -p "$PROJDIR"
TRANSCRIPT="$PROJDIR/sess-abc123.jsonl"
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB/proj\",\"timestamp\":\"2026-06-17T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2026-06-17T00:00:00Z\",\"cwd\":\"$ESW_SB/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\\nline two\"}]}}"
} > "$TRANSCRIPT"

mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0
out=$(HOME="$ESW_SB/home" LUNA_VAULT_PATH="$ESW_SB/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$PROJDIR" \
    run "$DOC" 2>&1) || rc=$?
check "pre-signal-capture: rc 0 (still closes)" "$rc" "0"
exact_count "pre-signal-capture: kill still called exactly once (capture never blocks the signal)" "$(cat "$CALLS")" "kill -TERM 210" "1"
note_count=$(find "$ESW_SB/vault/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check "pre-signal-capture: exactly one session note written before signalling" "$note_count" "1"

# --- 16: ambiguous transcript match (0 candidates) skips the capture, never
# guesses, and still closes normally (HIMMEL-3629 direction 2's "never guess").
ESW_SB2="$W/esw-sb2"
mkdir -p "$ESW_SB2/vault" "$ESW_SB2/proj" "$ESW_SB2/home"
EMPTY_PROJDIR="$W/esw-projects-empty"
mkdir -p "$EMPTY_PROJDIR"
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0
out=$(HOME="$ESW_SB2/home" LUNA_VAULT_PATH="$ESW_SB2/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB2/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$EMPTY_PROJDIR" \
    run "$DOC" 2>&1) || rc=$?
check "no-transcript-match: rc 0 (still closes)" "$rc" "0"
contains "no-transcript-match: says it cannot resolve unambiguously" "$out" "cannot resolve unambiguously"
exact_count "no-transcript-match: kill still called exactly once" "$(cat "$CALLS")" "kill -TERM 210" "1"

# --- 17: HIMMEL-3635 -- a colon-suffixed `WRAPPED:` marker bullet (tick.sh's
# leg_tail_status already accepts this shape; close-wrapped-leg's own
# marker-bullet check must accept it too, via the shared parser).
mkdoc "- 10:00 WRAPPED: done"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "wrapped-colon: rc 0 (accepted as WRAPPED)" "$rc" "0"

# --- 18: HIMMEL-3638 console add-on -- a live session named exactly the
# FULL doc stem (-RESUME and date intact), as the console launches legs this
# shift, must match as this leg's one live session.
rm -rf "$W/proc"; mkdir -p "$W/proc"
FULL_STEM="$(basename "$DOC" .md)"
mkcmdline 220 claude -n "$FULL_STEM" work
pgrep_x_stub 220
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "full-stem-session: rc 0 (matched)" "$rc" "0"
exact_count "full-stem-session: kill called exactly once with the matched pid" "$(cat "$CALLS")" "kill -TERM 220" "1"
# restore the undated-session fixture other cases below assume
rm -rf "$W/proc"; mkdir -p "$W/proc"
mkcmdline 210 claude -n "$SESSION_NAME" work
pgrep_x_stub 210

# --- 19: HIMMEL-3638 -- the pre-signal capture must not read a STALE
# transcript that happens to share a customTitle-bearing decoy line but is
# from a prior day (mtime-scoped: only today's files are searched). A stale
# decoy alongside the real, fresh transcript must still resolve to exactly
# the fresh one, not refuse as ambiguous.
ESW_SB3="$W/esw-sb3"
mkdir -p "$ESW_SB3/vault" "$ESW_SB3/proj" "$ESW_SB3/home"
PROJDIR3="$W/esw-projects3"
mkdir -p "$PROJDIR3"
STALE_TRANSCRIPT="$PROJDIR3/sess-stale.jsonl"
printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB3/proj\",\"timestamp\":\"2020-01-01T00:00:00Z\"}" > "$STALE_TRANSCRIPT"
touch -d '10 days ago' "$STALE_TRANSCRIPT" 2>/dev/null || touch -t "$(date -d '10 days ago' +%Y%m%d0000 2>/dev/null)" "$STALE_TRANSCRIPT" 2>/dev/null || true  # gnu-ok: console kit is Linux-only
FRESH_TRANSCRIPT="$PROJDIR3/sess-fresh.jsonl"
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB3/proj\",\"timestamp\":\"2026-06-17T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2026-06-17T00:00:00Z\",\"cwd\":\"$ESW_SB3/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\\nline two\"}]}}"
} > "$FRESH_TRANSCRIPT"
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0
out=$(HOME="$ESW_SB3/home" LUNA_VAULT_PATH="$ESW_SB3/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB3/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$PROJDIR3" \
    run "$DOC" 2>&1) || rc=$?
check "mtime-scoped-capture: rc 0 (still closes)" "$rc" "0"
note_count19=$(find "$ESW_SB3/vault/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check "mtime-scoped-capture: exactly one note written (stale decoy excluded, not ambiguous)" "$note_count19" "1"

# --- 20: HIMMEL-3638 timing guard -- a projects dir with many STALE, large
# decoy transcripts (simulating scale) plus one fresh, large transcript whose
# customTitle match sits within the head window and is followed by megabytes
# of padding. The fix must not open every byte of every file: this is a
# best-effort wall-clock bound (sandbox timing is inherently noisy), backed
# by the real proof -- correctness despite the decoys (exactly one note).
PROJDIR4="$W/esw-projects4"
mkdir -p "$PROJDIR4"
for i in $(seq 1 10); do
    stale="$PROJDIR4/stale-$i.jsonl"
    yes '{"customTitle":"not-this-leg","timestamp":"2020-01-01T00:00:00Z"}' 2>/dev/null | head -c 300000 > "$stale" || true
    touch -d '30 days ago' "$stale" 2>/dev/null || touch -t "$(date -d '30 days ago' +%Y%m%d0000 2>/dev/null)" "$stale" 2>/dev/null || true  # gnu-ok: console kit is Linux-only
done
ESW_SB4="$W/esw-sb4"
mkdir -p "$ESW_SB4/vault" "$ESW_SB4/proj" "$ESW_SB4/home"
FRESH4="$PROJDIR4/sess-fresh.jsonl"
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB4/proj\",\"timestamp\":\"2026-06-17T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2026-06-17T00:00:00Z\",\"cwd\":\"$ESW_SB4/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\"}]}}"
    yes '{"padding":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' 2>/dev/null | head -c 1000000 || true
} > "$FRESH4"
mkdoc "- 10:00 WRAPPED - done"
reset_calls
start_ts=$(date +%s)
rc=0
out=$(HOME="$ESW_SB4/home" LUNA_VAULT_PATH="$ESW_SB4/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB4/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$PROJDIR4" \
    run "$DOC" 2>&1) || rc=$?
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))
check "timing-guard: rc 0" "$rc" "0"
note_count20=$(find "$ESW_SB4/vault/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check "timing-guard: exactly one note written despite large/stale decoys" "$note_count20" "1"
if [ "$elapsed" -le 15 ]; then
    echo "ok - timing-guard: close completed in ${elapsed}s (<=15s best-effort bound)"
else
    echo "FAIL - timing-guard: close took ${elapsed}s (>15s) - mtime/head-window scoping may have regressed"
    fails=$((fails+1))
fi

# --- 21: HIMMEL-3638/F3 -- the ONLY matching transcript is older than the
# mtime window (e.g. the console closes a leg more than a day after it
# WRAPPED). The mtime-scoped search alone matches 0 files; the fix must fall
# back to an all-time search rather than skipping the pre-signal capture.
ESW_SB5="$W/esw-sb5"
mkdir -p "$ESW_SB5/vault" "$ESW_SB5/proj" "$ESW_SB5/home"
PROJDIR5="$W/esw-projects5"
mkdir -p "$PROJDIR5"
OLD_TRANSCRIPT="$PROJDIR5/sess-old.jsonl"
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB5/proj\",\"timestamp\":\"2020-01-01T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2020-01-01T00:00:00Z\",\"cwd\":\"$ESW_SB5/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\\nline two\"}]}}"
} > "$OLD_TRANSCRIPT"
touch -d '10 days ago' "$OLD_TRANSCRIPT" 2>/dev/null || touch -t "$(date -d '10 days ago' +%Y%m%d0000 2>/dev/null)" "$OLD_TRANSCRIPT" 2>/dev/null || true  # gnu-ok: console kit is Linux-only
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0
out=$(HOME="$ESW_SB5/home" LUNA_VAULT_PATH="$ESW_SB5/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB5/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$PROJDIR5" CLOSE_WRAPPED_LEG_MTIME_DAYS=1 \
    run "$DOC" 2>&1) || rc=$?
check "mtime-window-fallback: rc 0 (still closes)" "$rc" "0"
note_count21=$(find "$ESW_SB5/vault/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check "mtime-window-fallback: exactly one note written (0 matches under the mtime window, found via all-time fallback)" "$note_count21" "1"

# --- 22: codex-3 -- the mtime-scoped search is NON-empty (an unrelated, recent
# decoy transcript exists) but contains 0 MATCHES for this leg; the actual
# target transcript is older than the window. An empty-scan_files check alone
# never retries here (scan_files has the decoy in it), so this must fall back
# on 0 MATCHES, not 0 files.
ESW_SB6="$W/esw-sb6"
mkdir -p "$ESW_SB6/vault" "$ESW_SB6/proj" "$ESW_SB6/home"
PROJDIR6="$W/esw-projects6"
mkdir -p "$PROJDIR6"
DECOY_TRANSCRIPT="$PROJDIR6/sess-decoy.jsonl"
printf '%s\n' "{\"customTitle\":\"not-this-leg\",\"timestamp\":\"2026-06-17T00:00:00Z\"}" > "$DECOY_TRANSCRIPT"
OLD_TRANSCRIPT6="$PROJDIR6/sess-old.jsonl"
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB6/proj\",\"timestamp\":\"2020-01-01T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2020-01-01T00:00:00Z\",\"cwd\":\"$ESW_SB6/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\\nline two\"}]}}"
} > "$OLD_TRANSCRIPT6"
touch -d '10 days ago' "$OLD_TRANSCRIPT6" 2>/dev/null || touch -t "$(date -d '10 days ago' +%Y%m%d0000 2>/dev/null)" "$OLD_TRANSCRIPT6" 2>/dev/null || true  # gnu-ok: console kit is Linux-only
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0
out=$(HOME="$ESW_SB6/home" LUNA_VAULT_PATH="$ESW_SB6/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB6/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$PROJDIR6" CLOSE_WRAPPED_LEG_MTIME_DAYS=1 \
    run "$DOC" 2>&1) || rc=$?
check "mtime-scoped-decoy-fallback: rc 0 (still closes)" "$rc" "0"
note_count22=$(find "$ESW_SB6/vault/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check "mtime-scoped-decoy-fallback: exactly one note written (an unrelated recent decoy must not suppress the all-time retry)" "$note_count22" "1"

# --- 23: codex-2 (round 4) -- the all-time FALLBACK pass must not apply the
# same per-file head-window truncation as the scoped pass. The transcript is
# outside the mtime window (forces the fallback) AND its customTitle line
# sits past a small test-configured head window, so a fallback that still
# truncates at that window can never find it either.
ESW_SB7="$W/esw-sb7"
mkdir -p "$ESW_SB7/vault" "$ESW_SB7/proj" "$ESW_SB7/home"
PROJDIR7="$W/esw-projects7"
mkdir -p "$PROJDIR7"
OLD_TRANSCRIPT7="$PROJDIR7/sess-old.jsonl"
{
    printf '%s\n' "{\"filler\":1}"
    printf '%s\n' "{\"filler\":2}"
    printf '%s\n' "{\"filler\":3}"
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB7/proj\",\"timestamp\":\"2020-01-01T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2020-01-01T00:00:00Z\",\"cwd\":\"$ESW_SB7/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\\nline two\"}]}}"
} > "$OLD_TRANSCRIPT7"
touch -d '10 days ago' "$OLD_TRANSCRIPT7" 2>/dev/null || touch -t "$(date -d '10 days ago' +%Y%m%d0000 2>/dev/null)" "$OLD_TRANSCRIPT7" 2>/dev/null || true  # gnu-ok: console kit is Linux-only
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0
out=$(HOME="$ESW_SB7/home" LUNA_VAULT_PATH="$ESW_SB7/vault" OBSIDIAN_API_KEY="" \
    CLAUDE_PROJECT_DIR="$ESW_SB7/proj" OSTYPE="linux-gnu" OS="" \
    CWL_ESW_BIN="$REAL_ESW" CWL_PROJECTS_DIR="$PROJDIR7" CLOSE_WRAPPED_LEG_MTIME_DAYS=1 \
    CLOSE_WRAPPED_LEG_CUSTOMTITLE_HEAD=2 \
    run "$DOC" 2>&1) || rc=$?
check "fallback-head-window: rc 0 (still closes)" "$rc" "0"
note_count23=$(find "$ESW_SB7/vault/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
check "fallback-head-window: exactly one note written (customTitle past the head window is still found by the unbounded all-time fallback)" "$note_count23" "1"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "ALL OK"
    exit 0
else
    echo "FAILURES: $fails"
    exit 1
fi
