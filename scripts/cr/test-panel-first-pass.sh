#!/usr/bin/env bash
# scripts/cr/test-panel-first-pass.sh -- smoke test for panel-first-pass.sh
# (HIMMEL-2226). Bash 3.2 safe.
#
# Hermetic: builds a throwaway git repo under mktemp plus a throwaway
# "scripts" tree that mirrors the real scripts/cr, scripts/guardrails,
# scripts/lib layout -- a COPY of panel-first-pass.sh under test, REAL
# (unmodified) copies of guardrails/lib.sh and lib/load-dotenv.sh (this
# suite does not re-test default_branch/load_dotenv), and a STUBBED
# critic-panel.sh so no run ever reaches the real one, which spends the
# operator's paid OpenAI bank. The stub is a PATH-side fixture, not a
# test-only env seam added to panel-first-pass.sh itself: the script under
# test always resolves critic-panel.sh from its own HIMMEL_ROOT, so pointing
# HIMMEL_ROOT at the fixture tree is enough to intercept the call.
#
# No network: the panel is stubbed and the real `rtk` binary (if installed
# on this operator's machine) is excluded from PATH below, so the rc=1
# fail-open case never nondeterministically takes the rtk-retry branch.
# No writes outside the fixture: asserted at the end by checking the script's
# own mktemp scratch files (cr-panel-avail.*) never survive in the shared
# system temp dir. (A whole-repo `git status --porcelain` diff was tried
# first and dropped: this worktree has other HIMMEL-2226 workers committing
# unrelated scripts/cr/* files concurrently, so that diff is contaminated by
# noise that has nothing to do with this script.)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# assert_has <haystack> <needle> <label>
assert_has() {
    case "$1" in
        *"$2"*) ok "$3" ;;
        *) bad "$3 (missing '$2'; got: $1)" ;;
    esac
}
# assert_lacks <haystack> <needle> <label>
assert_lacks() {
    case "$1" in
        *"$2"*) bad "$3 (unexpectedly contains '$2'; got: $1)" ;;
        *) ok "$3" ;;
    esac
}

# _list_panel_avail_tmp -- portable (Git Bash / BSD / GNU) replacement for
# `find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cr-panel-avail.*'`: -maxdepth is
# GNU-only. A subshell-scoped nullglob keeps the glob from leaking the
# literal pattern when nothing matches, without touching the caller's shopts.
_list_panel_avail_tmp() {
    (
        shopt -s nullglob
        for f in "${TMPDIR:-/tmp}"/cr-panel-avail.*; do
            printf '%s\n' "$f"
        done
    ) | sort
}

# --- keep the suite hermetic: drop a real rtk off PATH if present -----------
_rtk_bin="$(command -v rtk 2>/dev/null || true)"
if [ -n "$_rtk_bin" ]; then
    _rtk_dir="$(dirname "$_rtk_bin")"
    _newpath=""
    _old_ifs="$IFS"; IFS=':'
    for _p in $PATH; do
        if [ "$_p" != "$_rtk_dir" ]; then
            _newpath="${_newpath:+$_newpath:}$_p"
        fi
    done
    IFS="$_old_ifs"
    PATH="$_newpath"; export PATH
fi

# --- fixture "scripts" tree --------------------------------------------------
fx="$tmp/fx"
mkdir -p "$fx/scripts/cr" "$fx/scripts/guardrails" "$fx/scripts/lib"
cp "$HERE/panel-first-pass.sh" "$fx/scripts/cr/panel-first-pass.sh"
cp "$HERE/../guardrails/lib.sh" "$fx/scripts/guardrails/lib.sh"
cp "$HERE/../lib/load-dotenv.sh" "$fx/scripts/lib/load-dotenv.sh"
chmod +x "$fx/scripts/cr/panel-first-pass.sh"

CALL_LOG="$tmp/panel-calls.log"
export CALL_LOG
cat > "$fx/scripts/cr/critic-panel.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'called\n' >> "$CALL_LOG"
cat >/dev/null
[ -n "${FAKE_OUT:-}" ] && printf '%s\n' "$FAKE_OUT"
[ -n "${FAKE_ERR:-}" ] && printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_RC:-0}"
STUBEOF
chmod +x "$fx/scripts/cr/critic-panel.sh"
SCRIPT="$fx/scripts/cr/panel-first-pass.sh"

# --- fixture git repo: main + a real-diff branch + a no-diff branch --------
repo="$tmp/repo"
mkdir -p "$repo"
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m init
    git checkout -q -b feature
    echo change >> f.txt
    git commit -q -am change
    git checkout -q -b feature-empty main
) || { echo "FAIL: fixture repo setup failed" >&2; exit 1; }

main_sha="$(git -C "$repo" rev-parse main)"
feature_sha="$(git -C "$repo" rev-parse feature)"
empty_sha="$(git -C "$repo" rev-parse feature-empty)"

# Snapshot the shared system temp dir's cr-panel-avail.* files BEFORE running
# anything -- other processes on this machine (including concurrent HIMMEL-2226
# workers running the real critic-panel.sh) may already have some sitting
# there, so "no leaked scratch files" must be a pre/post DIFF, not a bare
# absence check.
_pre_tmp="$(_list_panel_avail_tmp)"

# =============================================================================
# T1: missing --head -> exit 2, no panel call.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && bash "$SCRIPT" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 2 ]; then ok "T1 missing --head exits 2"; else bad "T1 missing --head exit (got $rc)"; fi
assert_has "$err" "--head is required" "T1 diagnostic on stderr"
if [ -f "$CALL_LOG" ]; then bad "T1 panel invoked on a usage error"; else ok "T1 panel never invoked"; fi

# T2: missing --branch -> exit 2, no panel call.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && bash "$SCRIPT" --head "$feature_sha") 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 2 ]; then ok "T2 missing --branch exits 2"; else bad "T2 missing --branch exit (got $rc)"; fi
assert_has "$err" "--branch is required" "T2 diagnostic on stderr"
if [ -f "$CALL_LOG" ]; then bad "T2 panel invoked on a usage error"; else ok "T2 panel never invoked"; fi

# T3: CR_PROFILE=none -> skip, exit 0, no panel call.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && CR_PROFILE=none bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "T3 CR_PROFILE=none exits 0"; else bad "T3 CR_PROFILE=none exit (got $rc)"; fi
assert_has "$out" "claude-only review (CR_PROFILE=none)" "T3 skip note on stdout"
assert_has "$out" "captured diff base: main ($main_sha)" "T3 captured-base line"
if [ -f "$CALL_LOG" ]; then bad "T3 panel invoked despite CR_PROFILE=none"; else ok "T3 panel never invoked"; fi

# T4: empty diff -> skip, exit 0, no panel call (feature-empty == main).
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && bash "$SCRIPT" --head "$empty_sha" --branch feature-empty) 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "T4 empty diff exits 0"; else bad "T4 empty diff exit (got $rc)"; fi
assert_has "$out" "empty diff - critic panel skipped" "T4 skip note on stdout"
assert_has "$out" "captured diff base: main ($main_sha)" "T4 captured-base line"
if [ -f "$CALL_LOG" ]; then bad "T4 panel invoked on an empty diff"; else ok "T4 panel never invoked"; fi
# The elapsed tell is scoped to an INVOKED panel: a skip path legitimately
# returns instantly and must not be labelled as a suspicious empty round.
err="$(cat "$tmp/err")"
assert_lacks "$err" "panel-elapsed:" "T4 no elapsed tell on a skip path (panel never invoked)"

# T5: stubbed panel exit 7 -> ABORT, propagates as exit 7, no fallback.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=7 FAKE_OUT='SENTINEL-EXIT7-FINDINGS' \
    FAKE_ERR='panel-availability: codex unavailable (rc=7)' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 7 ]; then ok "T5 panel exit 7 propagates as exit 7"; else bad "T5 panel exit 7 (got $rc)"; fi
assert_has "$err" "critic-panel.sh exit 7" "T5 ABORT text on stderr"
assert_has "$err" "Re-run /pr-check from step 1." "T5 ABORT re-run instruction"
assert_lacks "$out" "SENTINEL-EXIT7-FINDINGS" "T5 no findings fallback on stdout"
if [ -f "$CALL_LOG" ] && [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = "1" ]; then
    ok "T5 panel called exactly once (no rtk-retry on exit 7)"
else
    bad "T5 unexpected panel call count"
fi

# T6: stubbed panel exit 1 -> fail-open, loud message, empty findings.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=1 FAKE_OUT='PHANTOM-FINDING-MUST-NOT-SURVIVE' \
    FAKE_ERR='panel-availability: codex unavailable (rc=1)' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T6 panel exit 1 degrades to exit 0"; else bad "T6 panel exit 1 exit (got $rc)"; fi
assert_has "$err" "critic panel unavailable (all critics failed) - claude-only review" "T6 fail-open message on stderr"
assert_has "$err" "panel-availability: codex unavailable (rc=1)" "T6 availability line surfaced on stderr"
assert_lacks "$out" "PHANTOM-FINDING-MUST-NOT-SURVIVE" "T6 findings reset to empty on fail-open"
# HIMMEL-2542 elapsed tell: the panel WAS invoked and came back with nothing,
# which is exactly when a reader needs to see how long that took.
assert_has "$err" "panel-elapsed:" "T6 elapsed tell printed for an invoked panel with an empty findings block"
if [ -f "$CALL_LOG" ] && [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = "1" ]; then
    ok "T6 panel called exactly once (rtk excluded from PATH)"
else
    bad "T6 unexpected panel call count"
fi

# T7: stubbed panel exit 0 -> findings on stdout, availability on stderr,
# streams never merged; captured diff base line present.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 critical bug here' \
    FAKE_ERR='panel-availability: codex ok' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T7 panel exit 0 exits 0"; else bad "T7 panel exit 0 exit (got $rc)"; fi
assert_has "$out" "[codex-1] f.txt:1 critical bug here" "T7 findings on stdout"
assert_has "$err" "panel-availability: codex ok" "T7 availability on stderr"
assert_lacks "$out" "panel-availability: codex ok" "T7 availability NOT leaked onto stdout"
assert_lacks "$err" "[codex-1] f.txt:1 critical bug here" "T7 findings NOT leaked onto stderr"
assert_has "$out" "captured diff base: main ($main_sha)" "T7 captured-base line"
assert_lacks "$err" "panel-elapsed:" "T7 no elapsed tell when the panel returned findings"

# =============================================================================
# T8 (HIMMEL-2542): a --head that names NO commit in this repo is an input-pin
# failure, not a critic outage. Pre-fix this exited 0 with "critic panel
# unavailable - claude-only review (git diff failed rc=128)" in under a second,
# so a caller that trusted rc=0 recorded a claude-only round and cleared the
# marker having reviewed nothing. It must ABORT at exit 7, name the ARGUMENT,
# and never invoke the panel.
BOGUS_SHA="0000000000000000000000000000000000000000"   # well-formed, resolves to nothing
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=0 FAKE_OUT='MUST-NOT-REVIEW' \
    bash "$SCRIPT" --head "$BOGUS_SHA" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 7 ]; then ok "T8 unresolvable --head exits 7"; else bad "T8 unresolvable --head exit (got $rc, want 7)"; fi
assert_has "$err" "--head $BOGUS_SHA does not resolve to a commit in this repo" "T8 ABORT names the argument, not the panel"
assert_lacks "$err" "critic panel unavailable" "T8 must NOT report a critic outage for a caller error"
assert_lacks "$out" "MUST-NOT-REVIEW" "T8 no findings from a run that never reviewed"
if [ -f "$CALL_LOG" ]; then bad "T8 panel invoked on an unresolvable pin"; else ok "T8 panel never invoked"; fi

# T9: NEGATIVE CONTROL for T8 (HIMMEL-2518 control contract). A mutant with the
# T8 guard deleted must RUN, PRODUCE a value, and produce the SPECIFIC wrong
# value the ticket reported - rc=0 plus the "critic panel unavailable" line.
# A mutant that merely "differs" (e.g. crashed on a syntax error) proves
# nothing, so each of those three properties is asserted with its own message.
# The mutant lives INSIDE the fixture tree: panel-first-pass.sh resolves
# critic-panel.sh from its own SCRIPT_DIR/../.., so a mutant written anywhere
# else would resolve HIMMEL_ROOT outside the fixture and could reach the REAL,
# paid critic panel.
mutant="$fx/scripts/cr/panel-first-pass.mutant.sh"
awk '
    index($0, "git rev-parse --verify --quiet") && index($0, "HEAD_SHA") { drop = 1 }
    drop && $0 == "fi" { drop = 0; next }
    !drop { print }
' "$SCRIPT" > "$mutant"
if cmp -s "$SCRIPT" "$mutant"; then
    bad "T9 control is VACUOUS: the guard-deleting mutation matched nothing, so the mutant is the fixed script"
else
    ok "T9 mutation applied (guard block removed)"
    if grep -q 'does not resolve to a commit in this repo' "$mutant"; then
        bad "T9 control is VACUOUS: the mutant still carries the guard's ABORT message"
    else
        ok "T9 mutant no longer carries the guard"
    fi
    rm -f "$CALL_LOG" "$tmp/err"
    out="$( (cd "$repo" && bash "$mutant" --head "$BOGUS_SHA" --branch feature) 2>"$tmp/err" )"; rc=$?
    err="$(cat "$tmp/err")"
    # (a) it RAN and produced a value: the captured-base line is printed after
    # arg parsing and before the diff, so its presence means execution reached
    # the code the guard was removed from.
    assert_has "$out" "captured diff base: main ($main_sha)" "T9 control RAN (produced the captured-base line)"
    # (b) the SPECIFIC wrong value, not merely "different from 7".
    if [ "$rc" -eq 0 ]; then ok "T9 control reproduces the exact defect (exit 0 on an unresolvable pin)"; else bad "T9 control did not reproduce the defect: exit $rc, want the pre-fix 0"; fi
    assert_has "$err" "critic panel unavailable" "T9 control reproduces the misleading outage message"
fi

# --- no writes outside the mktemp fixture -----------------------------------
# panel-first-pass.sh's only persistent writes are mktemp -t cr-panel-avail.*
# scratch files, always rm -f'd before it returns. Any NEW one since the
# pre-run snapshot would mean this suite's own runs leaked a file into the
# shared system temp dir (pre-existing ones from other processes are not
# this suite's concern).
_post_tmp="$(_list_panel_avail_tmp)"
_new_tmp="$(comm -13 <(printf '%s\n' "$_pre_tmp") <(printf '%s\n' "$_post_tmp") 2>/dev/null || true)"
if [ -z "$_new_tmp" ]; then
    ok "no NEW leaked cr-panel-avail scratch files outside the fixture"
else
    bad "leaked scratch files outside the fixture: $_new_tmp"
fi

if [ "$fail" -eq 0 ]; then echo "PASS test-panel-first-pass"; else echo "FAILURES in test-panel-first-pass"; exit 1; fi
