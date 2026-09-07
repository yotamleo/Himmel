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
cp "$HERE/base-resolver.sh" "$fx/scripts/cr/base-resolver.sh"
cp "$HERE/review-round.sh" "$fx/scripts/cr/review-round.sh"
cp "$HERE/../guardrails/lib.sh" "$fx/scripts/guardrails/lib.sh"
cp "$HERE/../lib/load-dotenv.sh" "$fx/scripts/lib/load-dotenv.sh"
cp "$HERE/../lib/shared-branch-lock.sh" "$fx/scripts/lib/shared-branch-lock.sh"
chmod +x "$fx/scripts/cr/panel-first-pass.sh"

CALL_LOG="$tmp/panel-calls.log"
export CALL_LOG
# ARGS_LOG records the stub's argv so a test can assert WHICH base literal the
# panel actually received (HIMMEL-1984 capture-once, HIMMEL-2598 T12).
ARGS_LOG="$tmp/panel-args.log"
export ARGS_LOG
cat > "$fx/scripts/cr/critic-panel.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'called\n' >> "$CALL_LOG"
printf '%s\n' "$*" >> "$ARGS_LOG"
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

# =============================================================================
# T10 (HIMMEL-2598, the ticket's primary acceptance): a SECOND fixture with a
# bare upstream + repo2 whose LOCAL main has been rewound one commit behind
# origin/main -- exactly the "unpulled primary checkout" state that made
# panel-first-pass.sh review other people's already-merged commits as if they
# were this branch's own (cost a paid critic call + a misattributed finding
# on HIMMEL-2528 round 5). The diff base must resolve refs/remotes/origin/main,
# never the stale local ref.
up="$tmp/upstream.git"
mkdir -p "$up"
git init -q --bare "$up"
repo2="$tmp/repo2"
mkdir -p "$repo2"
(
    fixture_enter_git_init_dir "$repo2" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo A > f.txt
    git add f.txt
    git commit -q -m A
    echo B >> f.txt
    git commit -q -am B
    git remote add origin "$up"
    git push -q origin main
    git remote set-head origin -a >/dev/null 2>&1 || true
    git checkout -q -b feature
    echo C >> f.txt
    git commit -q -am C
    stale_main="$(git rev-parse main~1)"
    git update-ref refs/heads/main "$stale_main"                 # local main -> A
    git update-ref refs/remotes/origin/main "$stale_main"       # cached origin/main -> A; upstream stays at B
) || { echo "FAIL: T10 fixture setup failed" >&2; exit 1; }

r2_local_main="$(git -C "$repo2" rev-parse refs/heads/main)"
r2_stale_origin_main="$(git -C "$repo2" rev-parse refs/remotes/origin/main)"
r2_upstream_main="$(git --git-dir="$up" rev-parse refs/heads/main)"
r2_feature="$(git -C "$repo2" rev-parse feature)"

# The row proves a real fetch, not merely remote-ref preference: BOTH cached
# refs start stale, while the bare upstream already carries the newer base.
if [ "$r2_local_main" = "$r2_stale_origin_main" ] && [ "$r2_stale_origin_main" != "$r2_upstream_main" ]; then
    ok "T10 fixture starts stale: local/main and cached origin/main are $r2_local_main; upstream main is $r2_upstream_main"
else
    bad "T10 fixture is VACUOUS: expected both cached refs stale behind upstream"
fi

rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/err"
out="$( (cd "$repo2" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$r2_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T10 exits 0"; else bad "T10 exit (got $rc)"; fi
r2_fetched_origin_main="$(git -C "$repo2" rev-parse refs/remotes/origin/main)"
assert_has "$out" "captured diff base: main ($r2_upstream_main)" "T10 fetches and captures current origin/main, not stale cached refs"
assert_lacks "$out" "main ($r2_local_main)" "T10 diff base does NOT carry stale local/cached main"
if [ "$r2_fetched_origin_main" = "$r2_upstream_main" ]; then
    ok "T10 fetch refreshed refs/remotes/origin/main"
else
    bad "T10 fetch did not refresh origin/main (got $r2_fetched_origin_main, want $r2_upstream_main)"
fi

# T12: CONTROL, HIMMEL-1984 capture-once. Reads $ARGS_LOG from the T10 run
# above -- checked here, BEFORE T11 below invokes the panel again and would
# append a second line to it, so "exactly one --base-sha handoff" stays a
# clean read of T10's run alone. The panel must receive the SAME base literal
# stdout printed -- never re-derive it live in a later step -- so the two
# review lanes (stdout ledger + panel argv) can never re-resolve it minutes
# apart and disagree.
if [ -f "$ARGS_LOG" ]; then
    args="$(cat "$ARGS_LOG")"
    assert_has "$args" "--base-sha $r2_upstream_main" "T12 panel received the fetched origin base sha"
    assert_lacks "$args" "--base-sha $r2_local_main" "T12 panel did NOT receive the stale local/cached base sha"
    _base_sha_count="$(grep -o -- '--base-sha' "$ARGS_LOG" | wc -l | tr -d ' ')"
    if [ "$_base_sha_count" = "1" ]; then
        ok "T12 exactly one --base-sha handoff (capture-once holds)"
    else
        bad "T12 expected exactly one --base-sha handoff, got $_base_sha_count"
    fi
else
    bad "T12 ARGS_LOG missing from the T10 run"
fi

# T11: CONTROL, no remote -> resolves the LOCAL branch. Reuses the EXISTING
# $repo fixture (it has no origin remote). T3/T4/T7 already exercise this
# line incidentally; this row names it explicitly as HIMMEL-2598's documented
# fallback control (no origin/$db to prefer, so $db itself must still work).
# Runs AFTER the T12 read above so its panel invocation can't add a second
# line to $ARGS_LOG before T12 counts it.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
assert_has "$out" "captured diff base: main ($main_sha)" "T11 no-remote control resolves the local branch"

# T13: RED CONTROL by REVERTING THE REAL FIX (never a stub), following T9's
# mutant contract exactly. The mutant lives INSIDE the fixture tree ($fx/...)
# so it can never resolve HIMMEL_ROOT outside the fixture and reach the real,
# paid critic panel.
mutant2="$fx/scripts/cr/panel-first-pass.mutant2.sh"
# shellcheck disable=SC2016  # single-quoted sed programs match literal shell syntax in $SCRIPT
sed -e 's|! cr_fetch_base "$review_root" "$db"|! true|' \
    -e 's|^base_ref=.*|base_ref="$db"|' "$SCRIPT" > "$mutant2"
if cmp -s "$SCRIPT" "$mutant2"; then
    bad "T13 control is VACUOUS: the mutation matched nothing, so the mutant is the fixed script"
else
    ok "T13 mutation applied (fetch + origin-first resolution bypassed)"
    # shellcheck disable=SC2016  # literal source needle, not shell expansion
    if grep -q 'base_ref="$(cr_resolve_base_ref' "$mutant2"; then
        bad "T13 control is VACUOUS: the mutant still calls the origin-first resolver"
    else
        ok "T13 mutant now resolves the bare local \$db"
    fi
    chmod +x "$mutant2"
    rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/err"
    out="$( (cd "$repo2" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
        bash "$mutant2" --head "$r2_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "T13 control RAN to completion (exit 0)"; else bad "T13 control did not run to completion: exit $rc"; fi
    assert_has "$out" "captured diff base: main ($r2_local_main)" "T13 control reproduces the SPECIFIC wrong value (stale local main)"
    assert_lacks "$out" "main ($r2_upstream_main)" "T13 control does not carry the correct fetched origin sha"
fi

# T14 (codex-2 CR round 2, HIMMEL-2780/2787): a repo whose refs/heads carries
# a branch literally named "origin/main" that SHADOWS refs/remotes/origin/main
# in git's ambiguous-ref precedence (refs/heads/<name> is checked before
# refs/remotes/<name>). cr_resolve_base_ref must return the fully-qualified
# refs/remotes/origin/main, not the short "origin/main" that a bare
# `git rev-parse` would resolve to the shadowing branch instead.
repo3="$tmp/repo3"
mkdir -p "$repo3"
(
    fixture_enter_git_init_dir "$repo3" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo A > f.txt
    git add f.txt
    git commit -q -m A
    up3="$tmp/upstream3.git"
    git init -q --bare "$up3"
    git remote add origin "$up3"
    git push -q origin main
    # Shadow branch: refs/heads/origin/main, pointing at a DIFFERENT commit
    # than the real refs/remotes/origin/main.
    echo SHADOW > shadow.txt
    git add shadow.txt
    git commit -q -m shadow
    git update-ref refs/heads/origin/main HEAD
    git checkout -q main
) || { echo "FAIL: T14 fixture setup failed" >&2; exit 1; }
r3_tracking_main="$(git -C "$repo3" rev-parse refs/remotes/origin/main)"
r3_shadow_main="$(git -C "$repo3" rev-parse refs/heads/origin/main)"
if [ "$r3_tracking_main" = "$r3_shadow_main" ]; then
    bad "T14 fixture is VACUOUS: shadow branch and tracking ref point at the same commit"
else
    ok "T14 fixture has a real shadow: refs/heads/origin/main ($r3_shadow_main) != refs/remotes/origin/main ($r3_tracking_main)"
fi
r3_resolved="$( (
    . "$HERE/base-resolver.sh"
    cr_resolve_base_ref "$repo3" main
) )"
assert_has "$r3_resolved" "refs/remotes/origin/main" "T14 cr_resolve_base_ref returns the fully-qualified tracking ref"
r3_rev="$(git -C "$repo3" rev-parse --verify --quiet "$r3_resolved^{commit}" 2>/dev/null)" || r3_rev=""
if [ "$r3_rev" = "$r3_tracking_main" ]; then
    ok "T14 resolved ref rev-parses to the tracking commit, not the shadow branch"
else
    bad "T14 resolved ref rev-parsed to $r3_rev, want the tracking commit $r3_tracking_main (got shadow $r3_shadow_main?)"
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
