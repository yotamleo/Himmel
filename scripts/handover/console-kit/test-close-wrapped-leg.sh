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
#   8. 1 match, 1 worktree, NO MERGED/READY line in the doc  -> rc 0, clean.sh
#      --only <wt> --only-allow-unmerged called anyway (HIMMEL-3747: the doc's
#      own Results bullets no longer gate the prune -- clean-garden.sh
#      resolves the branch's PR state itself)
#   9. clean.sh reports "not a prune candidate" (its own PR-state gate
#      refused, e.g. an OPEN PR)                              -> rc 0 (non-fatal)
#  10. 1 match, 1 worktree, clean.sh succeeds                 -> rc 0, kill called with the ONE matched pid, clean.sh --only <wt> --only-allow-unmerged called once
#  11. clean.sh output contains "in use"                    -> rc 0 (non-fatal)
#  12. clean.sh fails for another reason                    -> rc 1
#  13. wrap-subtree-check.sh reports WITHHELD (a non-harness child process is
#      still alive under the matched session)              -> rc 6, kill NOT
#      called, clean.sh NOT called (HIMMEL-3747 Ask 3)
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
# age_file <file> <days> - backdate a file's mtime. GNU touch takes a relative
# `-d 'N days ago'`; BSD/macOS touch does not, so fall back to BSD `date -v`
# feeding `touch -t`. Fails loudly if the file did not actually age: a decoy
# that silently stayed fresh made the scoped-search cases pass or fail for the
# wrong reason (HIMMEL-3699).
age_file() {
    touch -d "$2 days ago" "$1" 2>/dev/null \
        || touch -t "$(date -v-"$2"d +%Y%m%d%H%M 2>/dev/null)" "$1" 2>/dev/null  # gnu-ok: console kit is Linux-only; BSD fallback
    if [ -z "$(find "$1" -mtime +"$(($2 - 1))" 2>/dev/null)" ]; then
        echo "FAIL - age_file: could not backdate $1 by $2 days (test setup broken)"
        fails=$((fails+1))
    fi
}

mkdir -p "$W/proc" "$W/bin" "$W/wt" "$W/handover-root"
CALLS="$W/calls.log"

# no-leak baseline (HIMMEL-3667): record whether the real repo already had a
# handovers/ dir BEFORE any test below runs, so the end-of-suite assertion
# catches this suite CREATING one, not an unrelated pre-existing one.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
if [ -z "$REPO_ROOT" ]; then
    echo "FAIL - no-leak: repo-root discovery failed, cannot check for a leaked handovers/ dir"
    fails=$((fails+1))
fi
pre_handovers=absent
[ -n "$REPO_ROOT" ] && [ -e "$REPO_ROOT/handovers" ] && pre_handovers=present

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
# a TERMed session exits only when the case asks (the fleet cases re-use one fake pid)
if [ "$1" = "-TERM" ] && [ "${CWL_KILL_REMOVES_PROC:-0}" = "1" ]; then rm -rf "${CLAUDE_SESSIONS_PROC:?}/${!#}"; fi
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
if [ "${CWL_CLEAN_MODE:-ok}" = "in-use-once" ] && [ "$(grep -c '^clean.sh' "$CALLS_LOG")" -ge 2 ]; then
    echo "clean-garden: prune summary — 1 pruned, 0 partial, 0 skipped, 0 failed"
    exit 0
fi
if [ "${CWL_CLEAN_MODE:-ok}" = "in-use" ] || [ "${CWL_CLEAN_MODE:-ok}" = "in-use-once" ]; then
    echo "worktree is in use, skipping"
    echo "clean-garden: prune summary — 0 pruned, 0 partial, 1 skipped, 0 failed"
    exit 1
fi
if [ "${CWL_CLEAN_MODE:-ok}" = "not-candidate" ]; then
    echo "clean-garden: prune summary — 0 pruned, 0 partial, 1 skipped, 0 failed"
    echo "ERR clean-garden: --only ... was not cleanly pruned -- not a prune candidate, or the removal was partial (reason above; PR is open)"
    exit 1
fi
if [ "${CWL_CLEAN_MODE:-ok}" = "partial" ]; then
    echo "clean-garden: prune summary — 0 pruned, 1 partial, 0 skipped, 0 failed"
    echo "ERR clean-garden: --only ... was not cleanly pruned -- not a prune candidate, or the removal was partial (reason above; branch delete failed after worktree removal)"
    exit 1
fi
if [ "${CWL_CLEAN_MODE:-ok}" = "gutted" ]; then
    echo "clean-garden: prune summary — 0 pruned, 0 partial, 0 skipped, 1 failed"
    echo "ERR clean-garden: --only ... was not cleanly pruned -- not a prune candidate, or the removal was partial (reason above; removal FAILED PARTWAY -- the tree may be GUTTED)"
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

# Stub wrap-subtree-check.sh (HIMMEL-3747 Ask 3): CLOSABLE by default so
# every pre-existing case is unaffected; CWL_SUBTREE_MODE=withheld models a
# non-harness child process still alive under the matched session.
SUBTREE_STUB="$W/bin/wrap-subtree-check.sh"
cat > "$SUBTREE_STUB" <<'STUB'
#!/usr/bin/env bash
echo "wrap-subtree-check.sh $*" >> "$CALLS_LOG"
if [ "${CWL_SUBTREE_MODE:-closable}" = "withheld" ]; then
    echo "WITHHELD: 1 process(es) still alive under claude pid $1 - TaskStop every background task and agent you spawned, then re-run"
    exit 1
fi
echo "CLOSABLE: no non-harness process under claude pid $1"
exit 0
STUB
chmod +x "$SUBTREE_STUB"

# Stub tmp-reap.sh (HIMMEL-4235): logs its argv and succeeds, so the cases
# that do not opt in can never reap anything (least of all the real /tmp).
REAP_STUB="$W/bin/tmp-reap-stub.sh"
cat > "$REAP_STUB" <<'STUB'
#!/usr/bin/env bash
echo "tmp-reap $*" >> "$CALLS_LOG.reap"
exit "${CWL_REAP_STUB_RC:-0}"
STUB
chmod +x "$REAP_STUB"

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
    #
    # HANDOVER_DIR is pinned to a scratch dir under $W - close-wrapped-leg.sh
    # calls queue-lock.sh status, which resolves handover_root(); with
    # HANDOVER_DIR unset that falls through to the Mode A inline fallback
    # <repo-root>/handovers, creating REAL handovers/.locks/ state in
    # whatever checkout this suite runs from (HIMMEL-3667).
    CALLS_LOG="$CALLS" PATH="$W/bin:$PATH" CLAUDE_SESSIONS_PROC="$W/proc" \
        HANDOVER_DIR="${CWL_HANDOVER_DIR-$W/handover-root}" \
        GH_BIN="$GH_STUB" KILL_BIN="$KILL_STUB" CLEAN_SH_BIN="$CLEAN_STUB" \
        WRAP_SUBTREE_CHECK_BIN="$SUBTREE_STUB" TMP_REAP_BIN="${CWL_REAP_BIN:-$REAP_STUB}" \
        CLOSE_WRAPPED_LEG_REAP_WAIT=0 CLOSE_WRAPPED_LEG_PRUNE_WAIT=0 \
        CWL_PR_STATE="${CWL_PR_STATE:-MERGED}" CWL_CLEAN_MODE="${CWL_CLEAN_MODE:-ok}" \
        CWL_SUBTREE_MODE="${CWL_SUBTREE_MODE:-closable}" \
        CWL_PR_VIEW_FAIL="${CWL_PR_VIEW_FAIL:-0}" CWL_KILL_FAIL="${CWL_KILL_FAIL:-0}" \
        END_SESSION_WIKI_BIN="${CWL_ESW_BIN:-/bin/true}" \
        CLOSE_WRAPPED_LEG_PROJECTS_DIR="${CWL_PROJECTS_DIR:-$W/no-such-projects-dir}" \
        bash "$SCRIPT" "$@"
}
reset_calls() { : > "$CALLS"; : > "$CALLS.reap"; }
unset CWL_PR_STATE CWL_CLEAN_MODE CWL_PR_VIEW_FAIL CWL_KILL_FAIL CWL_SUBTREE_MODE

# --- 1. usage ----------------------------------------------------------------
reset_calls
rc=0; run >/dev/null 2>&1 || rc=$?
check "usage: no args -> rc 2" "$rc" "2"
rc=0; run "$DOC" extra >/dev/null 2>&1 || rc=$?
check "usage: 2 args -> rc 2" "$rc" "2"
rc=0; run "$W/no-such-doc.md" >/dev/null 2>&1 || rc=$?
check "usage: unreadable doc -> rc 2" "$rc" "2"

# --- 2. held lock --------------------------------------------------------------
# HANDOVER_DIR pinned to the same scratch root run() uses below, so this
# direct acquire and the script-under-test's own `queue-lock.sh status`
# (invoked via run()) resolve the SAME lock root.
mkdoc "- 10:00 WRAPPED - done"
reset_calls
acq_out="$(HANDOVER_DIR="$W/handover-root" bash "$QL" acquire "$DOC" "cwl-test-holder" 2>&1)"
token="$(printf '%s' "$acq_out" | sed -n "s/.*release-token: \`\([^\`]*\)\`.*/\\1/p")"
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "held-lock: rc 3" "$rc" "3"
[ -n "$token" ] && HANDOVER_DIR="$W/handover-root" bash "$QL" release "$DOC" "$token" >/dev/null 2>&1

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
check "no-worktree: exactly two calls logged (subtree check + kill, no other pid signaled)" "$(wc -l < "$CALLS" | tr -d ' ')" "2"

# HIMMEL-3748: removing the successful-close manifest update must fail this.
fleet_manifest="$W/fleet.json"
bash "$HERE/fleet-manifest.sh" add "$fleet_manifest" "$DOC" "$W/HIMMEL-9-N2-other.md"
rc=0; out=$(run --fleet "$fleet_manifest" "$DOC" 2>&1) || rc=$?
check 'fleet: successful no-worktree close returns zero' 0 "$rc"
check 'fleet: close removes only its own doc' "$W/HIMMEL-9-N2-other.md" "$(jq -r '.legs[].doc' "$fleet_manifest")"
bash "$HERE/fleet-manifest.sh" add "$fleet_manifest" "$DOC"
fleet_before="$(cat "$fleet_manifest")"
mkdoc '- 10:00 LIVE - not wrapped'
rc=0; out=$(run --fleet "$fleet_manifest" "$DOC" 2>&1) || rc=$?
check 'fleet: refused close preserves status' 4 "$rc"
check 'fleet: refused close keeps manifest unchanged' "$fleet_before" "$(cat "$fleet_manifest")"
mkdoc '- 10:00 WRAPPED - done'
rc=0; out=$(CWL_KILL_FAIL=1 run --fleet "$fleet_manifest" "$DOC" 2>&1) || rc=$?
check 'fleet: failed signal preserves status' 1 "$rc"
check 'fleet: failed signal keeps manifest unchanged' "$fleet_before" "$(cat "$fleet_manifest")"

# Each successful prune exit must retire its doc; a failed prune must not.
for fleet_mode in ok not-candidate in-use fail; do
    bash "$HERE/fleet-manifest.sh" add "$fleet_manifest" "$DOC"
    mkdoc '- 10:00 WRAPPED - done' "worktree: \`$WT/.claude/worktrees/demo\`"
    rc=0; out=$(CWL_CLEAN_MODE="$fleet_mode" run --fleet "$fleet_manifest" "$DOC" 2>&1) || rc=$?
    fleet_present="$(jq --arg d "$DOC" 'any(.legs[]; .doc == $d)' "$fleet_manifest")"
    if [ "$fleet_mode" = fail ]; then
        check 'fleet: failed prune status' 1 "$rc"
        check 'fleet: failed prune keeps doc' true "$fleet_present"
    else
        check "fleet: $fleet_mode prune success" 0 "$rc"
        check "fleet: $fleet_mode prune retires doc" false "$fleet_present"
    fi
done
printf '%s\n' 'invalid manifest' > "$fleet_manifest"
mkdoc '- 10:00 WRAPPED - done'
rc=0; out=$(run --fleet "$fleet_manifest" "$DOC" 2>&1) || rc=$?
check 'fleet: update failure returns nonzero after close' 1 "$rc"
contains 'fleet: update failure reports session already closed' "$out" 'session closed but fleet manifest update failed'
check 'fleet: invalid manifest never overwritten' 'invalid manifest' "$(cat "$fleet_manifest")"
rc=0; run --fleet >/dev/null 2>&1 || rc=$?
check 'fleet: missing flag value refuses' 2 "$rc"

# --- 7. 1 match, 2 worktree paths -------------------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`" "worktree: \`$W/wt/.claude/worktrees/other\`"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "two-worktree: rc 0" "$rc" "0"
not_contains "two-worktree: clean.sh not called" "$(cat "$CALLS")" "clean.sh"

# --- 8. 1 match, 1 worktree, NO MERGED/READY line in the doc (HIMMEL-3747:
# the doc's own bullets no longer gate the prune) -------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "no-pr-line: rc 0" "$rc" "0"
calls8="$(cat "$CALLS")"
exact_count "no-pr-line: clean.sh --only <wt> --only-allow-unmerged called anyway" "$calls8" "clean.sh --only $WT/.claude/worktrees/demo --only-allow-unmerged" "1"

# --- 9. clean.sh reports "not a prune candidate" (its own PR-state gate
# refused the target, e.g. an OPEN PR) -------------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="not-candidate" run "$DOC" 2>&1) || rc=$?
check "not-candidate: rc 0 (non-fatal)" "$rc" "0"
contains "not-candidate: names the skip" "$out" "not pruned"

# --- 9b. clean.sh's error text ALSO contains "not a prune candidate" when the
# true cause was PARTIAL (branch-delete-after-worktree-removal failure) --
# codex-2 (HIMMEL-3747 CR round 1): the substring match can't tell this apart
# from case 9's benign skip, so it must NOT be treated as non-fatal. ------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="partial" run "$DOC" 2>&1) || rc=$?
check "partial: rc 1 (fatal -- a partial removal is not a benign skip)" "$rc" "1"

# --- 9c. same, but the true cause was FAILED (a possibly GUTTED worktree) ------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="gutted" run "$DOC" 2>&1) || rc=$?
check "gutted: rc 1 (fatal -- a failed/gutted removal is not a benign skip)" "$rc" "1"

# --- 10. clean success path ----------------------------------------------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="ok" run "$DOC" 2>&1) || rc=$?
check "clean-success: rc 0" "$rc" "0"
calls="$(cat "$CALLS")"
exact_count "clean-success: kill called exactly once with the matched pid" "$calls" "kill -TERM 210" "1"
exact_count "clean-success: clean.sh called exactly once with --only-allow-unmerged" "$calls" "clean.sh --only $WT/.claude/worktrees/demo --only-allow-unmerged" "1"
check "clean-success: exactly 3 calls logged (subtree check + kill + clean.sh, no extras)" "$(wc -l < "$CALLS" | tr -d ' ')" "3"

# --- 11. clean.sh reports in-use ------------------------------------------------
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="in-use" run "$DOC" 2>&1) || rc=$?
check "clean-in-use: rc 0 (non-fatal)" "$rc" "0"
contains "clean-in-use: names it" "$out" "in use"
exact_count "clean-in-use: retried a bounded 3 times after the first pass (4 calls)" "$(cat "$CALLS")" "clean.sh --only $WT/.claude/worktrees/demo --only-allow-unmerged" "4"

# --- 11b. in use at first, free on the retry (HIMMEL-4334) ----------------------
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="in-use-once" run "$DOC" 2>&1) || rc=$?
check "clean-in-use-once: rc 0" "$rc" "0"
exact_count "clean-in-use-once: pruned on the second call, no more retries" "$(cat "$CALLS")" "clean.sh --only $WT/.claude/worktrees/demo --only-allow-unmerged" "2"
contains "clean-in-use-once: final output is the successful prune" "$out" "1 pruned"

# --- 12. clean.sh fails for another reason --------------------------------------
reset_calls
rc=0; out=$(CWL_CLEAN_MODE="fail" run "$DOC" 2>&1) || rc=$?
check "clean-fail: rc 1" "$rc" "1"

# --- 13. wrap-subtree-check.sh reports WITHHELD (HIMMEL-3747 Ask 3) -------------
mkdoc "- 10:00 WRAPPED - done" "worktree: \`$WT/.claude/worktrees/demo\`"
reset_calls
rc=0; out=$(CWL_SUBTREE_MODE="withheld" run "$DOC" 2>&1) || rc=$?
check "subtree-withheld: rc 6" "$rc" "6"
calls13="$(cat "$CALLS")"
exact_count "subtree-withheld: wrap-subtree-check.sh called exactly once with the matched pid" "$calls13" "wrap-subtree-check.sh 210" "1"
not_contains "subtree-withheld: kill never called" "$calls13" "kill -TERM"
not_contains "subtree-withheld: clean.sh never called" "$calls13" "clean.sh"
contains "subtree-withheld: names the refusal" "$out" "did not report CLOSABLE"

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

# --- 17b: HIMMEL-3747 Ask 4 -- WRAPPED not leading the FINAL timestamped
# bullet is still accepted (a leg that reports the lock release before the
# marker word).
mkdoc "- 10:15 Released lock \`tok-123\`, appended WRAPPED, ending turn"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "wrapped-anywhere: rc 0 (accepted as WRAPPED)" "$rc" "0"

# --- 17c: HIMMEL-3747 Ask 4 control -- WRAPPED mentioned in an EARLIER
# bullet does not retroactively count once a later, non-WRAPPED bullet is the
# final timestamped one.
mkdoc "- 10:20 LIVE - still going, resumed after the earlier wrap discussion" "- 10:00 WRAPPED - done"
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "wrapped-earlier-only: rc 4 (last bullet is LIVE, not WRAPPED)" "$rc" "4"

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
age_file "$STALE_TRANSCRIPT" 10
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
    age_file "$stale" 30
done
ESW_SB4="$W/esw-sb4"
mkdir -p "$ESW_SB4/vault" "$ESW_SB4/proj" "$ESW_SB4/home"
FRESH4="$PROJDIR4/sess-fresh.jsonl"
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$ESW_SB4/proj\",\"timestamp\":\"2026-06-17T00:00:00Z\"}"
    printf '%s\n' "{\"timestamp\":\"2026-06-17T00:00:00Z\",\"cwd\":\"$ESW_SB4/proj\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\"}]}}"
    yes '{"padding":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' 2>/dev/null | head -c 1000000 || true
} > "$FRESH4"
# the `|| true` above only absorbs `yes`'s SIGPIPE; assert the fixtures were
# genuinely generated, else this case passes without exercising scale (HIMMEL-3740).
fixture_ok=yes
[ "$(wc -c < "$FRESH4")" -ge 1000000 ] || fixture_ok=no
for stale in "$PROJDIR4"/stale-*.jsonl; do
    [ -s "$stale" ] || fixture_ok=no
done
check "timing-guard: padded fresh transcript (>=1MB) and stale decoys generated" "$fixture_ok" "yes"
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
age_file "$OLD_TRANSCRIPT" 10
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
age_file "$OLD_TRANSCRIPT6" 10
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
age_file "$OLD_TRANSCRIPT7" 10
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

# --- 25: leg cost ledger (HIMMEL-4217) ---------------------------------------
# A wrapped leg's transcript is metered by leg-burn.sh --raw and ONE JSONL row
# lands in <handover root>/.ledger/leg-cost.jsonl before the TERM. A meter or
# ledger failure only WARNs - the close still succeeds.
LC_PROJ="$W/lc-projects"
mkdir -p "$LC_PROJ"
LC_T="$LC_PROJ/sess-lc1.jsonl"
asst() { # asst <id> <input> <cache-read> <cache-create> <out>
    printf '{"type":"assistant","message":{"id":"%s","model":"claude-sonnet-5-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s}}}\n' "$1" "$2" "$3" "$4" "$5"
}
{
    printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$W\",\"timestamp\":\"2026-10-03T00:00:00Z\"}"
    asst m1 10 1000 2000 100
    asst m2 20 3000 0 200
    asst m2 20 3000 0 200
    printf '%s\n' '{"type":"system","subtype":"compact_boundary"}'
    asst m3 5 4000 500 50
} > "$LC_T"
LC_LEDGER="$W/handover-root/.ledger/leg-cost.jsonl"
rm -f "$LC_LEDGER"
mkdoc "- 10:00 WRAPPED - done" "- 09:50 READY - PR 4321 abc GREEN"
{ printf -- '---\nclass: impl\nprofile: leg-impl\n---\n'; cat "$DOC"; } > "$DOC.fm" && mv "$DOC.fm" "$DOC"
reset_calls
rc=0; out=$(CWL_PROJECTS_DIR="$LC_PROJ" run "$DOC" 2>&1) || rc=$?
check "ledger: rc 0" "$rc" "0"
check "ledger: exactly one row" "$(grep -c . "$LC_LEDGER" 2>/dev/null)" "1"
lc_row() { jq -r ".$1" "$LC_LEDGER" 2>/dev/null | head -1; }
check "ledger: calls deduped by message id" "$(lc_row calls)" "3"
check "ledger: input" "$(lc_row input)" "35"
check "ledger: cache_read" "$(lc_row cache_read)" "8000"
check "ledger: cache_create" "$(lc_row cache_create)" "2500"
check "ledger: out" "$(lc_row out)" "350"
check "ledger: cost_eq is exact (35 + 8000*0.1 + 2500*1.25 + 350*5)" "$(lc_row cost_eq)" "5710"
check "ledger: compactions" "$(lc_row compactions)" "1"
check "ledger: model from the transcript" "$(lc_row model)" "claude-sonnet-5-5"
check "ledger: leg label" "$(lc_row leg)" "N1"
check "ledger: ticket key" "$(lc_row ticket)" "HIMMEL-9"
check "ledger: class from front matter" "$(lc_row class)" "impl"
check "ledger: profile from front matter" "$(lc_row profile)" "leg-impl"
check "ledger: PR from the READY bullet" "$(lc_row pr)" "4321"
check "ledger: date is today" "$(lc_row date)" "$(date +%F)"
# a retried close (same transcript) never writes a second row
mkdoc "- 10:00 WRAPPED - done"
rc=0; out=$(CWL_PROJECTS_DIR="$LC_PROJ" run "$DOC" 2>&1) || rc=$?
check "ledger: retried close still one row" "$(grep -c . "$LC_LEDGER")" "1"
# class from the doc name; no front matter
DOC_SHEP="$W/HIMMEL-9-N1-demo-cloud-shepherd-2026-01-01-RESUME.md"
SESSION_SAVE="$SESSION_NAME"; DOC_SAVE="$DOC"
SESSION_NAME="HIMMEL-9-N1-demo-cloud-shepherd-2026-01-01"; DOC="$DOC_SHEP"
mkcmdline 210 claude -n "$SESSION_NAME" work
sed "s/$SESSION_SAVE/$SESSION_NAME/" "$LC_T" > "$LC_PROJ/sess-lc2.jsonl"; rm -f "$LC_T"
mkdoc "- 10:00 WRAPPED - done"
rc=0; out=$(CWL_PROJECTS_DIR="$LC_PROJ" run "$DOC" 2>&1) || rc=$?
check "ledger-class: rc 0" "$rc" "0"
check "ledger-class: shepherd derived from the doc name" "$(jq -r .class "$LC_LEDGER" | tail -1)" "shepherd"
check "ledger-class: profile unknown without front matter" "$(jq -r .profile "$LC_LEDGER" | tail -1)" "unknown"
# a broken meter still closes, with a WARN and no row
LC_BAD="$W/bin/leg-burn-broken.sh"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$LC_BAD"; chmod +x "$LC_BAD"
rm -f "$LC_LEDGER"; reset_calls
rc=0; out=$(LEG_BURN_BIN="$LC_BAD" CWL_PROJECTS_DIR="$LC_PROJ" run "$DOC" 2>&1) || rc=$?
check "ledger-fail: close still rc 0 when leg-burn fails" "$rc" "0"
contains "ledger-fail: WARNs" "$out" "WARN"
exact_count "ledger-fail: TERM still sent" "$(cat "$CALLS")" "kill -TERM 210" "1"
check "ledger-fail: no row written" "$([ -e "$LC_LEDGER" ] && { wc -l < "$LC_LEDGER" | tr -d ' '; } || echo 0)" "0"
# an unwritable ledger location also only WARNs
reset_calls
rc=0; out=$(LEG_COST_LEDGER="/proc/no-such-dir/x.jsonl" CWL_PROJECTS_DIR="$LC_PROJ" run "$DOC" 2>&1) || rc=$?
check "ledger-unwritable: close still rc 0" "$rc" "0"
contains "ledger-unwritable: WARNs" "$out" "WARN"
SESSION_NAME="$SESSION_SAVE"; DOC="$DOC_SAVE"

# --- 26: ledger root follows the DOC, not the cwd (HIMMEL-4231) ---------------
# HANDOVER_DIR unset and cwd a repo with its own handovers/ stub (a console
# running from the himmel checkout): the row must land under the handover root
# that holds the leg doc, never in the cwd repo's stub.
LR_STATE="$W/lr-state"; LR_STUB="$W/lr-stub"
mkdir -p "$LR_STATE/handovers/u/himmel" "$LR_STUB/handovers"
git -C "$LR_STUB" init -q 2>/dev/null || { echo "FAIL: case 26 setup: git init in $LR_STUB"; exit 1; }
printf '{"repos":{"state":{"path":"%s","user":"u"}}}\n' "$LR_STATE" > "$W/lr-registry.json"
LR_STEM="HIMMEL-9-N7-rootcase-2026-01-01"
DOC_SAVE="$DOC"; SESSION_SAVE="$SESSION_NAME"
DOC="$LR_STATE/handovers/u/himmel/$LR_STEM.md"; SESSION_NAME="$LR_STEM"
mkcmdline 211 claude -n "$SESSION_NAME" work
pgrep_x_stub 211
printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$W\",\"timestamp\":\"2026-10-03T00:00:00Z\"}" > "$LC_PROJ/sess-lr1.jsonl"
asst m1 10 1000 2000 100 >> "$LC_PROJ/sess-lr1.jsonl"
mkdoc "- 10:00 WRAPPED - done"
reset_calls
rc=0; out=$(cd "$LR_STUB" && CWL_HANDOVER_DIR="" HANDOVER_REGISTRY="$W/lr-registry.json" CWL_PROJECTS_DIR="$LC_PROJ" run "$DOC" 2>&1) || rc=$?
check "ledger-root: rc 0" "$rc" "0"
check "ledger-root: row lands under the doc's handover root" "$(grep -c sess-lr1 "$LR_STATE/handovers/.ledger/leg-cost.jsonl" 2>/dev/null)" "1"
check "ledger-root: nothing in the cwd repo's stub" "$([ -e "$LR_STUB/handovers/.ledger" ] && echo present || echo absent)" "absent"
pgrep_x_stub 210
SESSION_NAME="$SESSION_SAVE"; DOC="$DOC_SAVE"

# --- 27: the wrapped leg's own /tmp scratch is archived (HIMMEL-4235) --------
# A judge dir of THIS leg's PR (leg N1, READY PR 2 -> j2*) and the leg's session scratch dir are
# archived then reaped after the TERM; the label-named j1a (another PR's judge), another
# session's dir and a root fixture in the same tree are untouched. Real
# tmp-reap.sh against a scratch root: the real /tmp is never reached.
RP_ROOT="$W/reap-tmp"; RP_ARCH="$W/reap-arch"; RP_CL="$RP_ROOT/claude-$(id -u)"
RP_SID=55555555-5555-5555-5555-555555555555; RP_OTHER=66666666-6666-6666-6666-666666666666
mkdir -p "$RP_CL/j2a" "$RP_CL/j2b" "$RP_CL/j1a" "$RP_CL/-proj/$RP_SID" "$RP_CL/-proj/$RP_OTHER" "$RP_ROOT/mog-run.old" "$W/reap-proc/1" "$W/reap-sessions"
ln -s / "$W/reap-proc/1/cwd"
for d in "$RP_CL/j2a" "$RP_CL/j1a" "$RP_CL/-proj/$RP_SID" "$RP_CL/-proj/$RP_OTHER"; do printf '{"a":1}\n' > "$d/corpus-x.jsonl"; done
touch -t 200001010000 "$RP_CL/j2a" "$RP_CL/j2b"   # an idle judge (over the 6 h floor)
touch -t 200001010000 "$RP_ROOT/mog-run.old"
RP_PROJ="$W/reap-projects/p"; mkdir -p "$RP_PROJ"
printf '%s\n' "{\"customTitle\":\"$SESSION_NAME\",\"cwd\":\"$W\"}" > "$RP_PROJ/$RP_SID.jsonl"
rm -rf "$W/proc"; mkdir -p "$W/proc"
mkcmdline 210 claude -n "$SESSION_NAME" work
pgrep_x_stub 210
mkdoc "- 10:00 WRAPPED - done" "- 09:50 READY - PR 2 abc GREEN"
reset_calls
rc=0; out=$(CWL_KILL_REMOVES_PROC=1 TMP_REAP_TMP_ROOT="$RP_ROOT" TMP_REAP_ARCHIVE_ROOT="$RP_ARCH" TMP_REAP_SESSIONS_DIR="$W/reap-sessions" TMP_REAP_PROC="$W/reap-proc" \
    CWL_REAP_BIN="$HERE/../../tmp-reap.sh" CWL_PROJECTS_DIR="$W/reap-projects" run "$DOC" 2>&1) || rc=$?
check "reap: rc 0" "$rc" "0"
check "reap: this leg's judge dir reaped" "$([ -e "$RP_CL/j2a" ] && echo present || echo absent)" "absent"
check "reap: this leg's empty judge dir reaped" "$([ -e "$RP_CL/j2b" ] && echo present || echo absent)" "absent"
check "reap: this leg's session scratch reaped" "$([ -e "$RP_CL/-proj/$RP_SID" ] && echo present || echo absent)" "absent"
check "reap: judge corpus archived first" "$(find "$RP_ARCH" -name corpus-x.jsonl 2>/dev/null | grep -c 'j2a')" "1"
check "reap: another leg's judge dir untouched" "$([ -e "$RP_CL/j1a/corpus-x.jsonl" ] && echo present || echo absent)" "present"
check "reap: another session's dir untouched" "$([ -e "$RP_CL/-proj/$RP_OTHER/corpus-x.jsonl" ] && echo present || echo absent)" "present"
check "reap: no fleet-wide fixture sweep" "$([ -e "$RP_ROOT/mog-run.old" ] && echo present || echo absent)" "present"

# --- 28: a reap failure never fails the wrap; a failed dry-run never applies --
mkdoc "- 10:00 WRAPPED - done" "- 09:50 READY - PR 7 abc GREEN"
rm -rf "$W/proc"; mkdir -p "$W/proc"; mkcmdline 210 claude -n "$SESSION_NAME" work; pgrep_x_stub 210
reset_calls
rc=0; out=$(CWL_KILL_REMOVES_PROC=1 CWL_REAP_STUB_RC=1 run "$DOC" 2>&1) || rc=$?
check "reap-fail: close still rc 0" "$rc" "0"
contains "reap-fail: WARNs" "$out" "WARN"
exact_count "reap-fail: kill still called once" "$(cat "$CALLS")" "kill -TERM 210" "1"
not_contains "reap-fail: no apply after a failed dry-run" "$(cat "$CALLS.reap")" "--apply"
rm -rf "$W/proc"; mkdir -p "$W/proc"; mkcmdline 210 claude -n "$SESSION_NAME" work
reset_calls
rc=0; out=$(CWL_KILL_REMOVES_PROC=1 run "$DOC" 2>&1) || rc=$?
contains "reap-ok: dry-run is scoped to the leg's PR number (never the leg label)" "$(cat "$CALLS.reap")" "tmp-reap --judge 7"
contains "reap-ok: apply follows a clean dry-run" "$(cat "$CALLS.reap")" "--apply"
# a leg with no PR in its doc reaps no judge dir: session half only, never a guess
mkdoc "- 10:00 WRAPPED - done"
rm -rf "$W/proc"; mkdir -p "$W/proc"; mkcmdline 210 claude -n "$SESSION_NAME" work
reset_calls
rc=0; out=$(CWL_KILL_REMOVES_PROC=1 run "$DOC" 2>&1) || rc=$?
not_contains "reap-nopr: no judge scope without a PR" "$(cat "$CALLS.reap")" "--judge"
contains "reap-nopr: says why" "$out" "no PR"

# --- 29: a session that outlives the TERM keeps its scratch (never reaped live) -
mkdoc "- 10:00 WRAPPED - done" "- 09:50 READY - PR 7 abc GREEN"
rm -rf "$W/proc"; mkdir -p "$W/proc"
mkcmdline 210 claude -n "$SESSION_NAME" work
pgrep_x_stub 210
reset_calls
rc=0; out=$(run "$DOC" 2>&1) || rc=$?
check "reap-alive: close still rc 0" "$rc" "0"
contains "reap-alive: says it skipped" "$out" "still running"
check "reap-alive: tmp-reap never called" "$(wc -c < "$CALLS.reap" | tr -d ' ')" "0"

# --- 24: no handovers/ leaked into the real repo (HIMMEL-3667) ----------------
post_handovers=absent
[ -n "$REPO_ROOT" ] && [ -e "$REPO_ROOT/handovers" ] && post_handovers=present
check "no-leak: this suite left no handovers/ dir behind in the repo root" "$post_handovers" "$pre_handovers"

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "ALL OK"
    exit 0
else
    echo "FAILURES: $fails"
    exit 1
fi
