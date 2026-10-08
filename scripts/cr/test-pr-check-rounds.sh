#!/usr/bin/env bash
# Focused acceptance tests for the branch-scoped /pr-check round cap
# (HIMMEL-2780). Bash 3.2-safe; no network or paid critic calls.
# Platform guard: requires POSIX Bash 3.2+; on Windows, run under Git Bash.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
assert_has() {
    case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2'; got: $1)" ;; esac
}
assert_lacks() {
    case "$1" in *"$2"*) fail "$3 (unexpected '$2'; got: $1)" ;; *) pass "$3" ;; esac
}
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi
}

fx="$tmp/fx"
mkdir -p "$fx/scripts/cr" "$fx/scripts/guardrails" "$fx/scripts/lib"
cp "$HERE/panel-first-pass.sh" "$fx/scripts/cr/panel-first-pass.sh"
cp "$HERE/anchor-handoff.sh" "$fx/scripts/cr/anchor-handoff.sh"
cp "$HERE/base-resolver.sh" "$fx/scripts/cr/base-resolver.sh"
cp "$HERE/review-round.sh" "$fx/scripts/cr/review-round.sh"
cp "$HERE/ledger-append.sh" "$fx/scripts/cr/ledger-append.sh"
cp "$HERE/write-verdicts.sh" "$fx/scripts/cr/write-verdicts.sh"
cp "$HERE/clear-cr-marker.sh" "$fx/scripts/cr/clear-cr-marker.sh"
# HIMMEL-3914: every chokepoint fails closed without its seam-guard lib.
cp "$HERE/../lib/chokepoint-seam-guard.sh" "$fx/scripts/lib/chokepoint-seam-guard.sh"
cp "$HERE/../guardrails/lib.sh" "$fx/scripts/guardrails/lib.sh"
cp "$HERE/../lib/load-dotenv.sh" "$fx/scripts/lib/load-dotenv.sh"
cp "$HERE/../lib/shared-branch-lock.sh" "$fx/scripts/lib/shared-branch-lock.sh"
chmod +x "$fx/scripts/cr/panel-first-pass.sh" "$fx/scripts/cr/ledger-append.sh" "$fx/scripts/cr/clear-cr-marker.sh"
SCRIPT="$fx/scripts/cr/panel-first-pass.sh"

PANEL_CALLS="$tmp/panel-calls"
PANEL_ROUNDS="$tmp/panel-rounds"
CLEAR_CALLS="$tmp/clear-calls"
export PANEL_CALLS PANEL_ROUNDS CLEAR_CALLS
cat > "$fx/scripts/cr/critic-panel.sh" <<'STUB'
#!/usr/bin/env bash
head_sha=""
branch=""
while [ $# -gt 0 ]; do
    case "$1" in
        --head) head_sha="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "${PANEL_DIFF_LAST:-}" ]; then cat > "$PANEL_DIFF_LAST"; else cat >/dev/null; fi
printf '%s\n' "$head_sha" >> "$PANEL_CALLS"
printf '%s\n' "${CR_REVIEW_ROUND:-<absent>}" >> "$PANEL_ROUNDS"
[ "${PANEL_MODE:-clean}" = "fail" ] && exit 1
ledger="$(git rev-parse --git-common-dir)/cr-critic-scores.jsonl"
CR_LEDGER="$ledger" bash "$(dirname "$0")/ledger-append.sh" avail \
    --branch "$branch" --head "$head_sha" --model stub --status ok || exit $?
case "${PANEL_MODE:-clean}" in
    suggestion-on)
        CR_LEDGER="$ledger" bash "$(dirname "$0")/ledger-append.sh" finding \
            --branch "$branch" --head "$head_sha" --model stub --id stub-1 \
            --severity sug --file f.txt --line 2 --verdict "" \
            --artifact spec --perspective on || exit $?
        printf '# Critic Panel Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (1 found)\n- [stub-1]: inspect the specification [f.txt:2]\n'
        ;;
    suggestion)
        CR_LEDGER="$ledger" bash "$(dirname "$0")/ledger-append.sh" finding \
            --branch "$branch" --head "$head_sha" --model stub --id stub-1 \
            --severity sug --file f.txt --line 2 --verdict "" || exit $?
        printf '# Critic Panel Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (1 found)\n- [stub-1]: tidy the fixture [f.txt:2]\n'
        ;;
    important)
        CR_LEDGER="$ledger" bash "$(dirname "$0")/ledger-append.sh" finding \
            --branch "$branch" --head "$head_sha" --model stub --id stub-1 \
            --severity imp --file f.txt --line 2 --verdict "" || exit $?
        printf '# Critic Panel Review\n\n## Critical Issues (0 found)\n\n## Important Issues (1 found)\n- [stub-1]: important fixture defect [f.txt:2]\n\n## Suggestions (0 found)\n'
        ;;
    critical)
        CR_LEDGER="$ledger" bash "$(dirname "$0")/ledger-append.sh" finding \
            --branch "$branch" --head "$head_sha" --model stub --id stub-1 \
            --severity crit --file f.txt --line 2 --verdict "" || exit $?
        printf '# Critic Panel Review\n\n## Critical Issues (1 found)\n- [stub-1]: critical fixture defect [f.txt:2]\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
        ;;
    *)
        printf '# Critic Panel Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
        ;;
esac
STUB
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    [ "$arg" = "--head" ] && exit 0
done
printf 'unexpected gh invocation\n' >&2
exit 1
STUB
chmod +x "$tmp/bin/gh" "$fx/scripts/cr/critic-panel.sh"
PATH="$tmp/bin:$PATH"
export PATH

install_clear_stub() {
    cat > "$fx/scripts/cr/clear-cr-marker.sh" <<'STUB'
#!/usr/bin/env bash
branch="$1"
printf '%s\n' "$branch" >> "$CLEAR_CALLS"
rm -f "$(git rev-parse --git-common-dir)/cr-pending/$branch"
printf 'clear-cr-marker: CR clean — marker cleared for %s.\n' "$branch"
STUB
    chmod +x "$fx/scripts/cr/clear-cr-marker.sh"
}

write_real_marker() {
    marker_branch="$1"
    marker_sha="$2"
    marker_base="$(git -C "$repo" rev-parse refs/remotes/origin/main)"
    mkdir -p "$git_dir/cr-pending/$(dirname "$marker_branch")"
    printf '2026-09-07T20:00:00Z | %s | full | origin | refs/heads/%s | %s | %s\n' \
        "$marker_sha" "$marker_branch" "$tmp/origin.git" "$marker_base" \
        > "$git_dir/cr-pending/$marker_branch"
}

repo="$tmp/repo"
mkdir -p "$repo"
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    printf 'base\n' > f.txt
    git add f.txt
    git commit -q -m base
    git init -q --bare "$tmp/origin.git"
    git remote add origin "$tmp/origin.git"
    git push -q -u origin main
    git checkout -q -b feature
    printf 'feature-1\n' >> f.txt
    git commit -q -am feature-1
    git push -q -u origin feature
) || { printf 'FAIL - fixture setup\n' >&2; exit 1; }

head1="$(git -C "$repo" rev-parse feature)"
out1="$(cd "$repo" && bash "$SCRIPT" --head "$head1" --branch feature 2>"$tmp/err1")"; rc1=$?
assert_eq "$rc1" "0" "round 1 run succeeds"
assert_has "$out1" "pr-check: round 1 of 3 on feature" "first run prints round 1"

printf 'feature-2\n' >> "$repo/f.txt"
git -C "$repo" commit -q -am feature-2
head2="$(git -C "$repo" rev-parse feature)"
out2="$(cd "$repo" && bash "$SCRIPT" --head "$head2" --branch feature 2>"$tmp/err2")"; rc2=$?
assert_eq "$rc2" "0" "changed-head run succeeds"
assert_has "$out2" "pr-check: round 2 of 3 on feature" "head change retains the branch counter"

git -C "$repo" checkout -q main
printf 'main-forward\n' > "$repo/main.txt"
git -C "$repo" add main.txt
git -C "$repo" commit -q -m main-forward
git -C "$repo" checkout -q feature
git -C "$repo" merge -q --no-edit main
head3="$(git -C "$repo" rev-parse feature)"
git -C "$repo" push -q origin feature
out3="$(cd "$repo" && bash "$SCRIPT" --head "$head3" --branch feature 2>"$tmp/err3")"; rc3=$?
assert_eq "$rc3" "0" "merge-forward run succeeds"
assert_has "$out3" "pr-check: round 3 of 3 on feature" "merge-forward retains the branch counter"
assert_eq "$(cat "$PANEL_ROUNDS")" "$(printf '1\n2\n3')" "panel receives each persisted branch review round"

git -C "$repo" checkout -q -b other main
printf 'other\n' > "$repo/other.txt"
git -C "$repo" add other.txt
git -C "$repo" commit -q -m other
other_head="$(git -C "$repo" rev-parse other)"
out4="$(cd "$repo" && bash "$SCRIPT" --head "$other_head" --branch other 2>"$tmp/err4")"; rc4=$?
assert_eq "$rc4" "0" "new-branch run succeeds"
assert_has "$out4" "pr-check: round 1 of 3 on other" "different branch starts at round 1"

git -C "$repo" checkout -q feature
git_dir="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"

# Concurrent starts on one branch must serialize the read/increment/write. The
# cat shim snapshots the old value before waiting, so an unlocked implementation
# deterministically makes both workers increment the same 0. A branch-scoped
# lock lets only the first worker reach that snapshot until the release opens.
real_cat="$(command -v cat)"
mkdir -p "$git_dir/cr-review-rounds" "$tmp/counter-arrivals"
printf '0\n' > "$git_dir/cr-review-rounds/contended.round"
rm -f "$tmp/counter-release"
export CR_COUNTER_REAL_CAT="$real_cat"
export CR_COUNTER_ARRIVALS="$tmp/counter-arrivals"
export CR_COUNTER_RELEASE="$tmp/counter-release"
cat > "$tmp/bin/cat" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    */cr-review-rounds/contended.round)
        value="$("$CR_COUNTER_REAL_CAT" "$1")" || exit $?
        : > "$CR_COUNTER_ARRIVALS/$$"
        while [ ! -e "$CR_COUNTER_RELEASE" ]; do sleep 0.1; done
        printf '%s\n' "$value"
        ;;
    *) exec "$CR_COUNTER_REAL_CAT" "$@" ;;
esac
STUB
chmod +x "$tmp/bin/cat"
# review-round only writes the branch checked out in cwd (HIMMEL-3495), so each
# branch runs from its own linked worktree; the state dir is the shared one.
git -C "$repo" worktree add -q -b contended "$tmp/wt-contended" main
git -C "$repo" worktree add -q -b independent "$tmp/wt-independent" main
(cd "$tmp/wt-contended" && bash "$fx/scripts/cr/review-round.sh" start --branch contended >"$tmp/contended-1.out" 2>"$tmp/contended-1.err") &
contended_pid1=$!
arrival_wait=0
while [ "$(find "$tmp/counter-arrivals" -type f | wc -l | tr -d ' ')" -lt 1 ] && [ "$arrival_wait" -lt 50 ]; do
    sleep 0.1
    arrival_wait=$((arrival_wait + 1))
done
(cd "$tmp/wt-contended" && bash "$fx/scripts/cr/review-round.sh" start --branch contended >"$tmp/contended-2.out" 2>"$tmp/contended-2.err") &
contended_pid2=$!
sleep 1
independent_out="$(cd "$tmp/wt-independent" && bash "$fx/scripts/cr/review-round.sh" start --branch independent)"; independent_rc=$?
printf 'release\n' > "$tmp/counter-release"
wait "$contended_pid1"; contended_rc1=$?
wait "$contended_pid2"; contended_rc2=$?
assert_eq "$contended_rc1" "0" "first contended counter start succeeds"
assert_eq "$contended_rc2" "0" "second contended counter start succeeds"
assert_eq "$(cat "$git_dir/cr-review-rounds/contended.round")" "2" "contended starts do not lose an increment"
assert_eq "$independent_rc" "0" "different branch starts while contended branch is locked"
assert_eq "$independent_out" "1" "different branch keeps an independent counter"

# HIMMEL-3495: review-round writes shared per-branch state, so every verb
# refuses a --branch other than the one checked out in cwd, and a detached
# HEAD. Run from the feature checkout against the `other` branch's state.
other_round_before="$(cat "$git_dir/cr-review-rounds/other.round")"
for verb_args in "start" "defer --head $other_head --defer-to HIMMEL-9000" "promote --head $other_head"; do
    # shellcheck disable=SC2086 # verb_args splits into the verb and its flags on purpose
    foreign_out="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" $verb_args --branch other 2>&1)"; foreign_rc=$?
    assert_eq "$foreign_rc" "2" "review-round ${verb_args%% *} refuses a branch not checked out in cwd"
    assert_has "$foreign_out" "not the branch checked out" "review-round ${verb_args%% *} foreign-branch refusal names the reason"
done
assert_eq "$(cat "$git_dir/cr-review-rounds/other.round")" "$other_round_before" "a refused foreign start leaves the other branch's round untouched"
git -C "$repo" worktree add -q --detach "$tmp/wt-detached" feature
detached_out="$(cd "$tmp/wt-detached" && bash "$fx/scripts/cr/review-round.sh" start --branch feature 2>&1)"; detached_rc=$?
assert_eq "$detached_rc" "2" "review-round refuses a detached HEAD"
assert_has "$detached_out" "not the branch checked out" "detached-HEAD refusal names the reason"
panel_foreign_out="$(cd "$repo" && bash "$SCRIPT" --head "$other_head" --branch other 2>&1)"; panel_foreign_rc=$?
assert_eq "$panel_foreign_rc" "2" "panel-first-pass refuses a --branch not checked out in cwd"
assert_has "$panel_foreign_out" "not the branch checked out" "panel-first-pass foreign-branch refusal names the reason"
assert_eq "$(cat "$git_dir/cr-review-rounds/other.round")" "$other_round_before" "a refused panel run leaves the other branch's round untouched"

# HIMMEL-4600: a 4th FULL round is refused. Re-reviewing the round-3 head is
# a full round of code three rounds already saw, so it never runs the panel.
before_full4_calls="$(wc -l < "$PANEL_CALLS" | tr -d ' ')"
full4_out="$(cd "$repo" && bash "$SCRIPT" --head "$head3" --branch feature 2>&1)"; full4_rc=$?
assert_eq "$full4_rc" "8" "a 4th full round at the round-3 head is refused"
assert_has "$full4_out" "4th full round is refused" "4th-full-round refusal names the reason"
assert_eq "$(cat "$git_dir/cr-review-rounds/feature.round")" "3" "a refused 4th full round leaves the counter at 3"
assert_eq "$(wc -l < "$PANEL_CALLS" | tr -d ' ')" "$before_full4_calls" "a refused 4th full round never runs the panel"

# Merge-forward: a head that differs from the round-3 head only by a merge of
# origin/main gets the ONE delta round, scoped to round-3 head..new head.
git -C "$repo" checkout -q main
printf 'main-forward-2\n' > "$repo/main2.txt"
# HIMMEL-4995: main also adds a line above the branch's hunk, so the branch's
# own diff shifts (a changed context line) and this merge is not a free
# clean-merge - it keeps the one delta round, as before.
printf 'top\nbase\n' > "$repo/f.txt"
git -C "$repo" add main2.txt f.txt
git -C "$repo" commit -q -m main-forward-2
git -C "$repo" push -q origin main
git -C "$repo" checkout -q feature
git -C "$repo" merge -q --no-edit main
head4="$(git -C "$repo" rev-parse feature)"
git -C "$repo" push -q origin feature
write_real_marker feature "$head4"
out5="$(cd "$repo" && PANEL_MODE=suggestion-on PANEL_DIFF_LAST="$tmp/delta-diff" bash "$SCRIPT" --head "$head4" --branch feature 2>"$tmp/err5")"; rc5=$?
assert_eq "$rc5" "0" "merge-forward delta round runs"
assert_has "$out5" "pr-check: delta round 4 on feature (from $head3)" "merge-forward head gets the one delta round"
assert_has "$(cat "$tmp/delta-diff")" "main-forward-2" "delta round reviews the round-3 head..new head diff"
assert_lacks "$(cat "$tmp/delta-diff")" "+feature-1" "delta round does not re-review the already-reviewed branch diff"
assert_lacks "$(cat "$CLEAR_CALLS" 2>/dev/null)" "feature" "first pass never clears before later reviewers finish"
printf '%s\n' 'VERDICT [kept-1] = disproved' | (cd "$repo" && bash "$fx/scripts/cr/write-verdicts.sh" prior-blocking --branch feature)
printf '%s\n' 'VERDICT [kept-1] = disproved' | (cd "$repo" && bash "$fx/scripts/cr/write-verdicts.sh" aggregate --branch feature)
cp "$fx/scripts/cr/write-verdicts.sh" "$tmp/write-verdicts.real"
cat > "$fx/scripts/cr/write-verdicts.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'injected verdict scratch failure\n' >&2
exit 9
STUB
chmod +x "$fx/scripts/cr/write-verdicts.sh"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$head4" --branch feature --defer-to HIMMEL-9000 >"$tmp/defer5-first.out" 2>"$tmp/defer5-first.err"); defer5_first_rc=$?
if [ "$defer5_first_rc" -ne 0 ]; then pass "post-amendment scratch failure leaves disposition incomplete"; else fail "post-amendment scratch failure leaves disposition incomplete"; fi
assert_has "$(cat "$git_dir/cr-critic-scores.jsonl" 2>/dev/null)" '"verdict":"deferred"' "failed disposition already persisted the deferred amendment"
if [ -e "$git_dir/cr-pending/feature" ]; then pass "failed disposition leaves the marker pending"; else fail "failed disposition leaves the marker pending"; fi
cp "$tmp/write-verdicts.real" "$fx/scripts/cr/write-verdicts.sh"
chmod +x "$fx/scripts/cr/write-verdicts.sh"
defer5="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$head4" --branch feature --defer-to HIMMEL-9000 2>"$tmp/defer5.err")"; defer5_rc=$?
assert_eq "$defer5_rc" "0" "retry repairs a post-amendment disposition failure"
assert_has "$defer5" "clear-cr-marker CLEARED branch=feature sha=$head4" "delta-round disposition retry passes the real marker gates"
assert_has "$defer5" "clear-cr-marker: CR clean" "delta-round disposition retry uses sanctioned marker clearance"
if [ -e "$git_dir/cr-pending/feature" ]; then
    fail "delta-round disposition retry clears the marker"
else
    pass "delta-round disposition retry clears the marker"
fi
ledger="$(cat "$git_dir/cr-critic-scores.jsonl" 2>/dev/null)"
assert_has "$ledger" '"verdict":"deferred"' "delta-round suggestions record a deferred verdict"
assert_has "$ledger" '"deferred_to":"HIMMEL-9000"' "delta-round suggestions record the shared defer ticket"
assert_has "$ledger" '"reason":"Finding deferred in the one delta round after the three-round /pr-check cap."' "delta-round suggestions record a finding reason"
identity_amends="$(LEDGER="$git_dir/cr-critic-scores.jsonl" node -e 'const fs=require("fs"),e=process.env;let n=0;for(const l of fs.readFileSync(e.LEDGER,"utf8").trim().split("\n")){const o=JSON.parse(l);if(o.kind==="amend"&&o.finding_id==="stub-1"&&o.artifact==="spec"&&o.perspective==="on")n++}process.stdout.write(String(n))')"
assert_eq "$identity_amends" "1" "delta-round recovery preserves non-default artifact and perspective identity"
assert_has "$(cat "$git_dir/cr-prior-blocking/feature" 2>/dev/null)" "VERDICT [kept-1] = disproved" "delta-round recovery preserves prior-blocking verdicts"
assert_has "$(cat "$git_dir/cr-aggregate-verdicts/feature" 2>/dev/null)" "VERDICT [kept-1] = disproved" "delta-round recovery preserves aggregate verdicts"
assert_has "$(cat "$git_dir/cr-prior-blocking/feature" 2>/dev/null)" "VERDICT [stub-1] = deferred -> HIMMEL-9000" "delta-round recovery repairs prior-blocking verdict scratch"
assert_has "$(cat "$git_dir/cr-aggregate-verdicts/feature" 2>/dev/null)" "VERDICT [stub-1] = deferred -> HIMMEL-9000" "delta-round recovery repairs aggregate verdict scratch"

# A second delta round after the delta round is refused.
printf 'feature-5\n' >> "$repo/f.txt"
git -C "$repo" commit -q -am feature-5
head5="$(git -C "$repo" rev-parse feature)"
before_delta2_calls="$(wc -l < "$PANEL_CALLS" | tr -d ' ')"
delta2_out="$(cd "$repo" && bash "$SCRIPT" --head "$head5" --branch feature 2>&1)"; delta2_rc=$?
assert_eq "$delta2_rc" "8" "a second delta round is refused"
assert_has "$delta2_out" "delta round was already used" "second-delta refusal names the reason"
assert_eq "$(wc -l < "$PANEL_CALLS" | tr -d ' ')" "$before_delta2_calls" "a refused second delta round never runs the panel"
assert_eq "$(cat "$git_dir/cr-review-rounds/feature.round")" "4" "a refused second delta round leaves the counter at 4"

# three_rounds <branch> <round-3 panel mode>: a fresh branch off main with
# three full rounds at one head (cap_r3_head); fix_commit adds the commit
# that answers a round-3 finding (cap_fix_head).
three_rounds() {
    git -C "$repo" checkout -q -b "$1" main
    printf '%s\n' "$1" > "$repo/$1.txt"
    git -C "$repo" add "$1.txt"
    # HIMMEL-4697: an optional third argument bumps the branch's plugin.json.
    [ -z "${3:-}" ] || write_plugin "$1" "$3"
    git -C "$repo" commit -q -m "$1"
    cap_r3_head="$(git -C "$repo" rev-parse "$1")"
    for n in 1 2; do
        (cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$cap_r3_head" --branch "$1" >/dev/null 2>"$tmp/$1-$n.err") || fail "$1 fixture setup round $n"
    done
    (cd "$repo" && PANEL_MODE="$2" bash "$SCRIPT" --head "$cap_r3_head" --branch "$1" >/dev/null 2>"$tmp/$1-3.err") || fail "$1 fixture setup round 3"
}
fix_commit() {
    printf 'fix\n' >> "$repo/$1.txt"
    git -C "$repo" commit -q -am "fix $1"
    cap_fix_head="$(git -C "$repo" rev-parse "$1")"
}

# The HIMMEL-4600 RED: three rounds, round 3 raised a finding, the leg fixed
# it at a new head. clear-cr-marker refuses that head (no critic reviewed it)
# until the one delta round runs; then it clears through the real gate.
three_rounds fixpath suggestion
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch fixpath --head "$cap_r3_head" --id stub-1 --set verdict=fixed \
    --reason 'round-3 finding answered by the fix commit' >/dev/null 2>"$tmp/fixpath-amend.err" \
    || fail "fixpath round-3 finding disposition"
printf '%s\n' "SWEEP [stub-1@$cap_r3_head] class=stub :: single-site search=git grep -n stub" \
    | (cd "$repo" && bash "$fx/scripts/cr/write-verdicts.sh" sweep --branch fixpath) >/dev/null 2>"$tmp/fixpath-sweep.err" \
    || fail "fixpath round-3 sweep record"
fix_commit fixpath
git -C "$repo" push -q -u origin fixpath
write_real_marker fixpath "$cap_fix_head"
(cd "$repo" && bash "$fx/scripts/cr/clear-cr-marker.sh" fixpath >"$tmp/fixpath-clear1.out" 2>&1); fixpath_clear1_rc=$?
if [ "$fixpath_clear1_rc" -ne 0 ]; then pass "a fix after round 3 cannot clear before the delta round"; else fail "a fix after round 3 cannot clear before the delta round"; fi
if [ -e "$git_dir/cr-pending/fixpath" ]; then pass "the unreviewed fix head keeps its marker"; else fail "the unreviewed fix head keeps its marker"; fi
fixpath_out="$(cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$cap_fix_head" --branch fixpath 2>"$tmp/fixpath-delta.err")"; fixpath_rc=$?
assert_eq "$fixpath_rc" "0" "a fix to a round-3 finding gets the one delta round"
assert_has "$fixpath_out" "pr-check: delta round 4 on fixpath (from $cap_r3_head)" "fix delta round names its scope"
(cd "$repo" && bash "$fx/scripts/cr/clear-cr-marker.sh" fixpath >"$tmp/fixpath-clear2.out" 2>&1); fixpath_clear2_rc=$?
assert_eq "$fixpath_clear2_rc" "0" "the fix head clears after the one delta round"
if [ -e "$git_dir/cr-pending/fixpath" ]; then fail "the delta round's rows clear the marker"; else pass "the delta round's rows clear the marker"; fi

# A new commit after a CLEAN round 3 is new work, not a fix: no delta round.
three_rounds newwork clean
fix_commit newwork
newwork_out="$(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch newwork 2>&1)"; newwork_rc=$?
assert_eq "$newwork_rc" "8" "new work after a clean round 3 gets no delta round"
assert_has "$newwork_out" "neither answers a round-3 finding nor only merges" "no-trigger refusal names the reason"
assert_eq "$(cat "$git_dir/cr-review-rounds/newwork.round")" "3" "a refused delta leaves the counter at 3"

# A round-3 finding disproved needs no fix, so a commit after it is new work.
three_rounds disproved suggestion
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch disproved --head "$cap_r3_head" --id stub-1 --set verdict=disproved \
    --reason 'round-3 finding disproved' >/dev/null 2>"$tmp/disproved-amend.err" \
    || fail "disproved round-3 finding disposition"
fix_commit disproved
disproved_out="$(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch disproved 2>&1)"; disproved_rc=$?
assert_eq "$disproved_rc" "8" "a disproved round-3 finding authorizes no delta round"
assert_has "$disproved_out" "neither answers a round-3 finding nor only merges" "disproved refusal names the reason"

# J1943 P1: a round-3 finding already deferred needs no fix either.
three_rounds deferredr3 suggestion
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch deferredr3 --head "$cap_r3_head" --id stub-1 --set verdict=deferred --set deferred_to=HIMMEL-9 \
    --set fu_class=polish --set 'reason=deferred at round 3' --reason 'deferred by /pr-check step 4.5' >/dev/null 2>"$tmp/deferredr3-amend.err" \
    || fail "deferred round-3 finding disposition"
fix_commit deferredr3
(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch deferredr3 >/dev/null 2>&1); deferredr3_rc=$?
assert_eq "$deferredr3_rc" "8" "a deferred round-3 finding authorizes no delta round"

# J1943 P2: a finding the leg itself wrote (model claude) is not a critic finding.
three_rounds forgedr3 clean
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch forgedr3 --head "$cap_r3_head" --model claude --id forged-1 --severity sug --file f.txt --line 1 \
    --verdict agreed >/dev/null 2>"$tmp/forgedr3-finding.err" || fail "forged round-3 finding setup"
fix_commit forgedr3
(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch forgedr3 >/dev/null 2>&1); forgedr3_rc=$?
assert_eq "$forgedr3_rc" "8" "a claude-model round-3 finding authorizes no delta round"

# J1943 P3: a finding once disproved stays disproved for the trigger.
three_rounds flipr3 suggestion
for v in disproved agreed; do
    CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
        --branch flipr3 --head "$cap_r3_head" --id stub-1 --set verdict="$v" \
        --reason "flip to $v" >/dev/null 2>"$tmp/flipr3-amend.err" || fail "flipr3 amend $v"
done
fix_commit flipr3
(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch flipr3 >/dev/null 2>&1); flipr3_rc=$?
assert_eq "$flipr3_rc" "8" "a disproved-then-agreed round-3 finding authorizes no delta round"

# J1943 P4: an unreviewed commit plus a leg-written avail row cannot move the
# delta scope past itself; a merge-forward on top is still refused.
three_rounds evilavail clean
printf 'EVIL\n' >> "$repo/evilavail.txt"
git -C "$repo" commit -q -am EVIL
evil_sha="$(git -C "$repo" rev-parse evilavail)"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" avail \
    --branch evilavail --head "$evil_sha" --model claude --status ok >/dev/null 2>"$tmp/evilavail.err" || fail "evilavail avail setup"
git -C "$repo" checkout -q main
printf 'main-p4\n' > "$repo/main-p4.txt"
git -C "$repo" add main-p4.txt
git -C "$repo" commit -q -m main-p4
git -C "$repo" push -q origin main
git -C "$repo" checkout -q evilavail
git -C "$repo" merge -q --no-edit main
(cd "$repo" && bash "$SCRIPT" --head "$(git -C "$repo" rev-parse evilavail)" --branch evilavail >/dev/null 2>&1); evilavail_rc=$?
assert_eq "$evilavail_rc" "8" "a leg-written avail row at an unreviewed commit cannot scope a merge-forward delta"

# J1943 P4b: the same with a leg-written claude finding at the unreviewed commit.
three_rounds evilfind clean
printf 'EVIL\n' >> "$repo/evilfind.txt"
git -C "$repo" commit -q -am EVIL
evil_sha="$(git -C "$repo" rev-parse evilfind)"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" avail \
    --branch evilfind --head "$evil_sha" --model claude --status ok >/dev/null 2>"$tmp/evilfind.err" || fail "evilfind avail setup"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch evilfind --head "$evil_sha" --model claude --id forged-2 --severity sug --file f.txt --line 1 \
    --verdict agreed >/dev/null 2>"$tmp/evilfind-finding.err" || fail "evilfind finding setup"
fix_commit evilfind
(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch evilfind >/dev/null 2>&1); evilfind_rc=$?
assert_eq "$evilfind_rc" "8" "a leg-written avail and finding at an unreviewed commit authorize no delta round"

# A merge of main that also carries its own edit is new work, not a merge-forward.
three_rounds evilmerge clean
git -C "$repo" checkout -q main
printf 'main-forward-evil\n' > "$repo/main-evil.txt"
git -C "$repo" add main-evil.txt
git -C "$repo" commit -q -m main-forward-evil
git -C "$repo" push -q origin main
git -C "$repo" checkout -q evilmerge
git -C "$repo" merge -q --no-commit main
printf 'smuggled\n' >> "$repo/evilmerge.txt"
git -C "$repo" add evilmerge.txt
git -C "$repo" commit -q --no-edit
evil_head="$(git -C "$repo" rev-parse evilmerge)"
evil_out="$(cd "$repo" && bash "$SCRIPT" --head "$evil_head" --branch evilmerge 2>&1)"; evil_rc=$?
assert_eq "$evil_rc" "8" "a merge that adds its own edit gets no merge-forward delta round"
assert_has "$evil_out" "neither answers a round-3 finding nor only merges" "evil-merge refusal names the reason"
assert_eq "$(cat "$git_dir/cr-review-rounds/evilmerge.round")" "3" "a refused evil merge leaves the counter at 3"

# HIMMEL-4697: plugin-version-bump-required makes a plugin PR bump its
# plugin.json version inside the merge of main, so that merge never equals a
# clean merge tree. Only a version-only resolution above both parents passes.
write_plugin() {
    mkdir -p "$repo/marketplace/plugins/$1/.claude-plugin"
    printf '{\n  "name": "%s",\n  "version": "%s",\n  "description": "%s"\n}\n' \
        "$1" "$2" "${3:-fixture}" > "$repo/marketplace/plugins/$1/.claude-plugin/plugin.json"
    git -C "$repo" add "marketplace/plugins/$1/.claude-plugin/plugin.json"
}
# plugin_case <branch> <main version> <branch version> [main-bumps [file]]:
# plugin.json at 0.1.0 on main, three rounds on a branch at <branch version>,
# then main moves (a plugin file, the version when main-bumps is set, and its
# own copy of <file> when given) and the branch merges it with --no-commit,
# leaving the resolution to the caller.
plugin_case() {
    git -C "$repo" checkout -q main
    write_plugin "$1" 0.1.0
    git -C "$repo" commit -q -m "$1 plugin base"
    git -C "$repo" push -q origin main
    three_rounds "$1" clean "$3"
    git -C "$repo" checkout -q main
    printf 'skill\n' > "$repo/marketplace/plugins/$1/SKILL.md"
    git -C "$repo" add "marketplace/plugins/$1/SKILL.md"
    [ -z "${4:-}" ] || write_plugin "$1" "$2"
    if [ -n "${5:-}" ]; then
        printf 'main copy\n' > "$repo/$5"
        git -C "$repo" add "$5"
    fi
    git -C "$repo" commit -q -m "$1 main moves"
    git -C "$repo" push -q origin main
    git -C "$repo" checkout -q "$1"
    git -C "$repo" merge -q --no-commit main >/dev/null 2>&1 || true
}
plugin_merge_commit() {
    git -C "$repo" commit -q --no-edit
    plugin_head="$(git -C "$repo" rev-parse HEAD)"
}

# (1a) Both sides bumped (a conflict), resolved to a version above both: accepted.
plugin_case pvconflict 0.1.1 0.1.2 main-bumps
write_plugin pvconflict 0.1.3
plugin_merge_commit
pv1_out="$(cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$plugin_head" --branch pvconflict 2>&1)"; pv1_rc=$?
assert_eq "$pv1_rc" "0" "a version-only conflict resolution above both parents gets the merge-forward delta round"
assert_has "$pv1_out" "pr-check: delta round 4 on pvconflict (from $cap_r3_head)" "version-only conflict resolution is the delta round"
assert_has "$(cat "$git_dir/cr-review-rounds/pvconflict.delta" 2>/dev/null)" "merge-forward" "version-only conflict resolution records the merge-forward trigger"

# (1b) A clean merge whose merge commit bumps the version above both: accepted.
plugin_case pvclean 0.1.0 0.1.2
write_plugin pvclean 0.1.10
plugin_merge_commit
pv2_out="$(cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$plugin_head" --branch pvclean 2>&1)"; pv2_rc=$?
assert_eq "$pv2_rc" "0" "a clean merge plus a version-only bump gets the merge-forward delta round"
assert_has "$pv2_out" "pr-check: delta round 4 on pvclean (from $cap_r3_head)" "clean merge plus bump is the delta round"
assert_has "$(cat "$git_dir/cr-review-rounds/pvclean.delta" 2>/dev/null)" "merge-forward" "clean merge plus bump records the merge-forward trigger"

# (2) The version bump plus one other byte in plugin.json: refused.
plugin_case pvextra 0.1.1 0.1.2 main-bumps
write_plugin pvextra 0.1.3 fixturE
plugin_merge_commit
pv3_out="$(cd "$repo" && bash "$SCRIPT" --head "$plugin_head" --branch pvextra 2>&1)"; pv3_rc=$?
assert_eq "$pv3_rc" "8" "a version bump plus another plugin.json byte gets no merge-forward delta round"
assert_has "$pv3_out" "neither answers a round-3 finding nor only merges" "version-plus-byte refusal keeps today's message"

# (2b) The version bump plus a byte in another file: refused.
plugin_case pvother 0.1.1 0.1.2 main-bumps
write_plugin pvother 0.1.3
printf 'smuggled\n' >> "$repo/pvother.txt"
git -C "$repo" add pvother.txt
plugin_merge_commit
(cd "$repo" && bash "$SCRIPT" --head "$plugin_head" --branch pvother >/dev/null 2>&1); pv4_rc=$?
assert_eq "$pv4_rc" "8" "a version bump plus an edit to another file gets no merge-forward delta round"

# (3) A resolved version equal to, or below, either parent: refused.
plugin_case pvequal 0.1.1 0.1.2 main-bumps
write_plugin pvequal 0.1.2
plugin_merge_commit
(cd "$repo" && bash "$SCRIPT" --head "$plugin_head" --branch pvequal >/dev/null 2>&1); pv5_rc=$?
assert_eq "$pv5_rc" "8" "a resolved version equal to a parent's gets no merge-forward delta round"
plugin_case pvlower 0.1.5 0.1.2 main-bumps
write_plugin pvlower 0.1.4
plugin_merge_commit
(cd "$repo" && bash "$SCRIPT" --head "$plugin_head" --branch pvlower >/dev/null 2>&1); pv6_rc=$?
assert_eq "$pv6_rc" "8" "a resolved version below main's gets no merge-forward delta round"
assert_eq "$(cat "$git_dir/cr-review-rounds/pvlower.round")" "3" "a refused version resolution leaves the counter at 3"

# (4) A conflict outside plugin.json, even with a valid version bump: refused.
# main also adds the branch's own pvoutside.txt, so the merge conflicts there.
plugin_case pvoutside 0.1.1 0.1.2 main-bumps pvoutside.txt
printf 'pvoutside\n' > "$repo/pvoutside.txt"
git -C "$repo" add pvoutside.txt
write_plugin pvoutside 0.1.3
plugin_merge_commit
pv7_out="$(cd "$repo" && bash "$SCRIPT" --head "$plugin_head" --branch pvoutside 2>&1)"; pv7_rc=$?
assert_eq "$pv7_rc" "8" "a conflict outside plugin.json gets no merge-forward delta round"
assert_has "$pv7_out" "neither answers a round-3 finding nor only merges" "outside-conflict refusal keeps today's message"

# HIMMEL-4616: a delta round whose panel produced no rows is still pending, so
# the SAME <from> <to> pair may start again without a second counter bump; once
# a critic reviewed the head, or for any other pair, the one delta round is used.
three_rounds pendingdelta suggestion
fix_commit pendingdelta
pd_r3="$cap_r3_head"
pd_head="$cap_fix_head"
pd1_out="$(cd "$repo" && PANEL_MODE=fail bash "$SCRIPT" --head "$pd_head" --branch pendingdelta 2>"$tmp/pd1.err")"; pd1_rc=$?
assert_eq "$pd1_rc" "0" "a failed delta-round panel run fails open"
assert_has "$pd1_out" "pr-check: delta round 4 on pendingdelta (from $pd_r3)" "the failed run was the delta round"
pd2_out="$(cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$pd_head" --branch pendingdelta 2>"$tmp/pd2.err")"; pd2_rc=$?
assert_eq "$pd2_rc" "0" "a failed delta-round panel run does not consume the delta round"
assert_has "$pd2_out" "pr-check: delta round 4 on pendingdelta (from $pd_r3)" "the same pair reruns as the delta round"
assert_eq "$(cat "$git_dir/cr-review-rounds/pendingdelta.round")" "4" "a reused delta round leaves the counter at 4"
pd3_out="$(cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$pd_head" --branch pendingdelta 2>&1)"; pd3_rc=$?
assert_eq "$pd3_rc" "8" "a delta round the panel reviewed is used up"
assert_has "$pd3_out" "delta round was already used" "used-up delta refusal names the reason"
three_rounds pendingother suggestion
fix_commit pendingother
(cd "$repo" && PANEL_MODE=fail bash "$SCRIPT" --head "$cap_fix_head" --branch pendingother >/dev/null 2>&1) || fail "pendingother failed delta setup"
printf 'more\n' >> "$repo/pendingother.txt"
git -C "$repo" commit -q -am "more pendingother"
pdo_out="$(cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$(git -C "$repo" rev-parse pendingother)" --branch pendingother 2>&1)"; pdo_rc=$?
assert_eq "$pdo_rc" "8" "a pending delta round is never reused for a different head"
assert_has "$pdo_out" "delta round was already used" "different-pair refusal names the reason"

# HIMMEL-4634: round-3 findings are keyed by id + artifact + perspective, so
# settling one finding does not hide another that shares its id.
three_rounds keyedr3 clean
for ap in "diff off" "spec on"; do
    # shellcheck disable=SC2086 # ap splits into the artifact and the perspective on purpose
    set -- $ap
    CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" finding \
        --branch keyedr3 --head "$cap_r3_head" --model stub --id stub-1 --severity sug --file f.txt --line 1 \
        --verdict "" --artifact "$1" --perspective "$2" >/dev/null 2>"$tmp/keyedr3-finding.err" || fail "keyedr3 finding $ap"
done
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch keyedr3 --head "$cap_r3_head" --id stub-1 --artifact spec --perspective on --set verdict=disproved \
    --reason 'settle only the spec finding' >/dev/null 2>"$tmp/keyedr3-amend.err" || fail "keyedr3 amend"
fix_commit keyedr3
(cd "$repo" && bash "$SCRIPT" --head "$cap_fix_head" --branch keyedr3 >/dev/null 2>&1); keyedr3_rc=$?
assert_eq "$keyedr3_rc" "0" "settling one finding does not hide another with the same id"

# HIMMEL-4635: in the delta round an Important counts as classified only when
# fu_class is exactly hardening.
three_rounds polishimp suggestion
fix_commit polishimp
polishimp_head="$cap_fix_head"
printf 'pending\n' > "$git_dir/cr-pending/polishimp"
(cd "$repo" && PANEL_MODE=important bash "$SCRIPT" --head "$polishimp_head" --branch polishimp >/dev/null 2>"$tmp/err-polish") || fail "polish delta producer run"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch polishimp --head "$polishimp_head" --id stub-1 --set fu_class=polish \
    --reason 'adjudicated polish' >/dev/null 2>"$tmp/polish-amend.err" || fail "polish amend"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$polishimp_head" --branch polishimp --defer-to HIMMEL-9005 >"$tmp/defer-polish.out" 2>"$tmp/defer-polish.err"); defer_polish_rc=$?
assert_eq "$defer_polish_rc" "4" "a delta-round Important classed polish is refused"
assert_has "$(cat "$tmp/defer-polish.err")" "explicit fu_class amend" "polish Important refusal names the remedy"
if [ -e "$git_dir/cr-pending/polishimp" ]; then pass "polish Important leaves the marker pending"; else fail "polish Important leaves the marker pending"; fi

# HIMMEL-4618: the delta Important deferral clears the new head through the
# REAL clear-cr-marker.sh, not the stub installed below.
three_rounds important suggestion
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch important --head "$cap_r3_head" --id stub-1 --set verdict=fixed \
    --reason 'round-3 finding answered by the fix commit' >/dev/null 2>"$tmp/important-r3.err" || fail "important round-3 disposition"
printf '%s\n' "SWEEP [stub-1@$cap_r3_head] class=stub :: single-site search=git grep -n stub" \
    | (cd "$repo" && bash "$fx/scripts/cr/write-verdicts.sh" sweep --branch important) >/dev/null 2>"$tmp/important-sweep.err" \
    || fail "important round-3 sweep record"
fix_commit important
important_head="$cap_fix_head"
git -C "$repo" push -q -u origin important
write_real_marker important "$important_head"
out6="$(cd "$repo" && PANEL_MODE=important bash "$SCRIPT" --head "$important_head" --branch important 2>"$tmp/err6")"; rc6=$?
assert_eq "$rc6" "0" "delta-round Important producer run completes for adjudication"
assert_has "$out6" "pr-check: delta round 4 on important" "Important run is the delta round"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$important_head" --branch important --defer-to HIMMEL-9001 >/dev/null 2>"$tmp/defer6u.err"); defer6u_rc=$?
assert_eq "$defer6u_rc" "4" "a delta-round Important without an fu_class amend is refused"
assert_has "$(cat "$tmp/defer6u.err")" "explicit fu_class amend" "unclassified Important refusal names the remedy"
if [ -e "$git_dir/cr-pending/important" ]; then pass "an unclassified Important leaves the marker pending"; else fail "an unclassified Important leaves the marker pending"; fi
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch important --head "$important_head" --id stub-1 --set fu_class=hardening \
    --reason 'classified hardening by the adjudicator' >/dev/null 2>"$tmp/important-class.err" || fail "important fu_class amend"
defer6="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$important_head" --branch important --defer-to HIMMEL-9001 2>"$tmp/defer6.err")"; defer6_rc=$?
assert_eq "$defer6_rc" "0" "delta-round Important finding is deferred"
assert_has "$defer6" "clear-cr-marker CLEARED branch=important sha=$important_head" "deferred delta-round Important finding clears the new head through the real gate"
if [ -e "$git_dir/cr-pending/important" ]; then fail "the real gate clears the delta-round Important marker"; else pass "the real gate clears the delta-round Important marker"; fi
assert_has "$(cat "$git_dir/cr-critic-scores.jsonl")" '"fu_class":"hardening"' "delta-deferred Important findings are classed hardening"

# Later controls only need to observe whether clearance was attempted; the
# successful paths above deliberately used the real gate.
install_clear_stub

# A Critical finding still blocks the delta round.
three_rounds critical suggestion
fix_commit critical
critical_head="$cap_fix_head"
printf 'pending\n' > "$git_dir/cr-pending/critical"
(cd "$repo" && PANEL_MODE=critical bash "$SCRIPT" --head "$critical_head" --branch critical >/dev/null 2>"$tmp/err-crit") || fail "critical delta producer run"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$critical_head" --branch critical --defer-to HIMMEL-9003 >"$tmp/defer-crit.out" 2>"$tmp/defer-crit.err"); defer_crit_rc=$?
assert_eq "$defer_crit_rc" "4" "delta-round Critical finding blocks disposition"
assert_has "$(cat "$tmp/defer-crit.err")" "remain blocking in the delta round" "Critical disposition explains the block"
assert_lacks "$(cat "$CLEAR_CALLS" 2>/dev/null)" "critical" "Critical finding never invokes marker clearance"
if [ -e "$git_dir/cr-pending/critical" ]; then pass "Critical finding leaves the marker pending"; else fail "Critical finding leaves the marker pending"; fi

# An Important finding the adjudicator classes escape still blocks it.
three_rounds escape suggestion
fix_commit escape
escape_head="$cap_fix_head"
printf 'pending\n' > "$git_dir/cr-pending/escape"
(cd "$repo" && PANEL_MODE=important bash "$SCRIPT" --head "$escape_head" --branch escape >/dev/null 2>"$tmp/err-esc") || fail "escape delta producer run"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch escape --head "$escape_head" --id stub-1 --set fu_class=escape \
    --reason 'adjudicated escape-class' >/dev/null 2>"$tmp/escape-amend.err" || fail "escape amend"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$escape_head" --branch escape --defer-to HIMMEL-9004 >"$tmp/defer-esc.out" 2>"$tmp/defer-esc.err"); defer_esc_rc=$?
assert_eq "$defer_esc_rc" "4" "delta-round escape-class finding blocks disposition"
assert_lacks "$(cat "$CLEAR_CALLS" 2>/dev/null)" "escape" "escape-class finding never invokes marker clearance"

# Missing ticket stops after the producer writes findings, prints the exact Jira
# command, and can be resumed against those rows without another panel call.
three_rounds capped suggestion
fix_commit capped
capped_head="$cap_fix_head"
printf 'pending\n' > "$git_dir/cr-pending/capped"
before_missing_calls="$(wc -l < "$PANEL_CALLS" | tr -d ' ')"
out7="$(cd "$repo" && PANEL_MODE=suggestion bash "$SCRIPT" --head "$capped_head" --branch capped 2>"$tmp/err7")"; rc7=$?
assert_eq "$rc7" "0" "delta-round missing-ticket producer run completes"
assert_has "$out7" "pr-check: delta round 4 on capped" "missing-ticket run still reports its round"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$capped_head" --branch capped >"$tmp/defer7.out" 2>"$tmp/defer7.err"); defer7_rc=$?
if [ "$defer7_rc" -ne 0 ]; then pass "delta-round suggestions fail disposition without a defer ticket"; else fail "delta-round suggestions fail disposition without a defer ticket"; fi
expected_jira="node '$fx/scripts/jira/dist/index.js' create --type Task --title 'Track deferred /pr-check round 4+ suggestions' --desc 'Track suggestion/nit-only findings deferred after the three-round review cap.'"
assert_has "$(cat "$tmp/defer7.err")" "$expected_jira" "missing ticket prints the exact non-executed Jira command"
after_missing_calls="$(wc -l < "$PANEL_CALLS" | tr -d ' ')"
assert_eq "$after_missing_calls" "$((before_missing_calls + 1))" "missing-ticket flow invokes the panel exactly once"
if [ -e "$git_dir/cr-pending/capped" ]; then pass "missing ticket leaves the marker pending"; else fail "missing ticket leaves the marker pending"; fi

recover_out="$(cd "$repo" && CR_DEFER_TO=HIMMEL-9002 bash "$fx/scripts/cr/review-round.sh" defer --head "$capped_head" --branch capped 2>"$tmp/recover.err")"; recover_rc=$?
assert_eq "$recover_rc" "0" "environment ticket resumes deferred disposition"
assert_has "$recover_out" "clear-cr-marker: CR clean" "recovery clears through the sanctioned script"
recover_calls="$(wc -l < "$PANEL_CALLS" | tr -d ' ')"
assert_eq "$recover_calls" "$after_missing_calls" "recovery dispositions recorded results without rerunning the panel"
ledger="$(cat "$git_dir/cr-critic-scores.jsonl" 2>/dev/null)"
assert_has "$ledger" '"deferred_to":"HIMMEL-9002"' "recovery records the environment-supplied ticket"
assert_has "$ledger" '"fu_class":"polish"' "cap-deferred Suggestions are classed polish (HIMMEL-4034)"
if [ -e "$git_dir/cr-pending/capped" ]; then fail "recovery clears the marker"; else pass "recovery clears the marker"; fi

calls="$(cat "$PANEL_CALLS" 2>/dev/null)"
expected_prefix="$(printf '%s\n%s\n%s\n%s' "$head1" "$head2" "$head3" "$other_head")"
assert_has "$calls" "$expected_prefix" "early rounds run the actual captured heads"

# review-round.sh promote (HIMMEL-2911): agreed findings absent at a clean
# round head become terminal `fixed` amends, idempotently.
promote_ledger="$git_dir/cr-critic-scores.jsonl"
git -C "$repo" checkout -q -b promote main
printf 'promote-a\n' > "$repo/promote.txt"
git -C "$repo" add promote.txt
git -C "$repo" commit -q -m promote-a
promote_head_a="$(git -C "$repo" rev-parse promote)"
printf 'promote-b\n' >> "$repo/promote.txt"
git -C "$repo" commit -q -am promote-b
promote_head_b="$(git -C "$repo" rev-parse promote)"

# (a) agreed, not re-raised at the clean head -> promoted to fixed.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-a \
    --severity sug --file promote.txt --line 1 --verdict "" \
    --text "tidy up the promote fixture alpha"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-a \
    --set verdict=agreed --reason "leg agrees with alpha"

# (b) agreed, re-raised (same fingerprint reappears) at the clean head -> still-open.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-b \
    --severity sug --file promote.txt --line 2 --verdict "" \
    --text "tidy up the promote fixture beta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-b \
    --set verdict=agreed --reason "leg agrees with beta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_b" --model stub --id find-b2 \
    --severity sug --file promote.txt --line 2 --verdict "" \
    --text "tidy up the promote fixture beta"

# (c) already terminal (fixed) -> untouched.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-c \
    --severity sug --file promote.txt --line 3 --verdict "" \
    --text "tidy up the promote fixture gamma"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-c \
    --set verdict=fixed --reason "already fixed by hand"

# (d) deferred -> untouched, deferred_to intact.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-d \
    --severity sug --file promote.txt --line 4 --verdict "" \
    --text "tidy up the promote fixture delta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-d \
    --set verdict=deferred --set deferred_to=HIMMEL-9010 --set fu_class=hardening --reason "deferred by hand"

# (h) agreed at an earlier head, its fingerprint reappears at the clean head
# but that reappearance is deferred, not resolved (codex-1, HIMMEL-2911 CR
# round 3) -> still-open: deferred means the issue is still real.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-h \
    --severity sug --file promote.txt --line 7 --verdict "" \
    --text "tidy up the promote fixture theta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-h \
    --set verdict=agreed --reason "leg agrees with theta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_b" --model stub --id find-h2 \
    --severity sug --file promote.txt --line 7 --verdict "" \
    --text "tidy up the promote fixture theta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_b" --id find-h2 \
    --set verdict=deferred --set deferred_to=HIMMEL-9011 --reason "tracked, out of scope"

# (i) agreed on a DIVERGENT commit that is not an ancestor of the clean head
# (codex-2, HIMMEL-2911 CR round 3) -> still-open even with no fingerprint
# match: --head never reviewed past that commit, so its absence proves nothing.
git -C "$repo" checkout -q -b promote-divergent main
printf 'divergent\n' > "$repo/divergent.txt"
git -C "$repo" add divergent.txt
git -C "$repo" commit -q -m divergent
promote_head_divergent="$(git -C "$repo" rev-parse promote-divergent)"
git -C "$repo" checkout -q promote
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_divergent" --model stub --id find-i \
    --severity sug --file divergent.txt --line 1 --verdict "" \
    --text "tidy up the promote fixture iota"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_divergent" --id find-i \
    --set verdict=agreed --reason "leg agrees with iota"

# (f) agreed AT the clean head itself (codex-1, HIMMEL-2911 CR round 1) ->
# still-open: no later commit could have fixed a finding raised THIS round.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_b" --model stub --id find-f \
    --severity sug --file promote.txt --line 5 --verdict "" \
    --text "tidy up the promote fixture zeta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_b" --id find-f \
    --set verdict=agreed --reason "leg agrees with zeta"

# (g) agreed at an earlier head, its fingerprint reappears at the clean head
# but that reappearance is already disproved (codex-2, HIMMEL-2911 CR round
# 1) -> promoted: a DISPOSITIONED occurrence is not a live re-raise.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-g \
    --severity sug --file promote.txt --line 6 --verdict "" \
    --text "tidy up the promote fixture eta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-g \
    --set verdict=agreed --reason "leg agrees with eta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_b" --model stub --id find-g2 \
    --severity sug --file promote.txt --line 6 --verdict "" \
    --text "tidy up the promote fixture eta"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_b" --id find-g2 \
    --set verdict=disproved --reason "not reproducible at this head"

# (m) no amend at all, no verdict on the finding row (the exact #617 shape:
# HIMMEL-2917) -> still-open, tagged unadjudicated: nobody dispositioned it,
# so the round is not certified clean over it either.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-m \
    --severity sug --file promote.txt --line 9 --verdict "" \
    --text "tidy up the promote fixture mu"

promote_out1="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" promote --branch promote --head "$promote_head_b")"; promote_rc1=$?
assert_eq "$promote_rc1" "3" "promote exits 3 while a re-raised finding is still open"
assert_has "$promote_out1" "promoted find-a@" "promote (a) not-re-raised agreed finding is promoted"
assert_has "$promote_out1" "still-open find-b@" "promote (b) re-raised agreed finding stays open"
assert_has "$promote_out1" "skip-terminal find-c@" "promote (c) already-fixed row is skipped"
assert_has "$promote_out1" "skip-terminal find-d@" "promote (d) deferred row is skipped"
assert_has "$promote_out1" "still-open find-f@" "promote (f) same-head agreed finding is never auto-fixed"
assert_has "$promote_out1" "promoted find-g@" "promote (g) an earlier agreed finding promotes when its head-H reappearance is already disproved"
assert_has "$promote_out1" "still-open find-h@" "promote (h) a deferred head-H reappearance keeps the earlier agreed finding still-open"
assert_has "$promote_out1" "still-open find-i@" "promote (i) a finding on a non-ancestor commit is never promoted"
assert_has "$promote_out1" "$(printf 'still-open find-m@%s (unadjudicated)' "$(printf '%s' "$promote_head_a" | cut -c1-8)")" "promote (m) an unadjudicated finding (no verdict, no amend) is still-open, tagged (unadjudicated), not silently skipped"
promote_ledger_content="$(cat "$promote_ledger" 2>/dev/null)"
assert_has "$promote_ledger_content" '"finding_id":"find-a"' "promoted amend targets find-a"
assert_has "$promote_ledger_content" '"verdict":"fixed"' "promote writes a fixed verdict"
assert_has "$promote_ledger_content" 'Promoted from agreed: no re-raise at clean round head' "promote amend carries the promotion reason"
assert_has "$promote_ledger_content" '"deferred_to":"HIMMEL-9010"' "promote (d) leaves deferred_to intact"
find_a_amends="$(LEDGER="$promote_ledger" node -e 'const fs=require("fs"),e=process.env;let n=0;for(const l of fs.readFileSync(e.LEDGER,"utf8").trim().split("\n")){const o=JSON.parse(l);if(o.kind==="amend"&&o.finding_id==="find-a"&&o.set&&o.set.verdict==="fixed")n++}process.stdout.write(String(n))')"
assert_eq "$find_a_amends" "1" "promote (a) writes exactly one fixed amend"

# (e) second run is idempotent: no new amend, same decisions.
promote_out2="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" promote --branch promote --head "$promote_head_b")"; promote_rc2=$?
assert_eq "$promote_rc2" "3" "second promote run still reports the unresolved re-raise"
assert_lacks "$promote_out2" "promoted find-a@" "second promote run does not re-promote find-a"
assert_has "$promote_out2" "skip-terminal find-a@" "second promote run reports find-a as already terminal"
find_a_amends_2="$(LEDGER="$promote_ledger" node -e 'const fs=require("fs"),e=process.env;let n=0;for(const l of fs.readFileSync(e.LEDGER,"utf8").trim().split("\n")){const o=JSON.parse(l);if(o.kind==="amend"&&o.finding_id==="find-a"&&o.set&&o.set.verdict==="fixed")n++}process.stdout.write(String(n))')"
assert_eq "$find_a_amends_2" "1" "second promote run writes zero new amends for find-a"
assert_has "$promote_out2" "still-open find-m@" "second promote run still reports find-m as unadjudicated"
find_m_amends="$(LEDGER="$promote_ledger" node -e 'const fs=require("fs"),e=process.env;let n=0;for(const l of fs.readFileSync(e.LEDGER,"utf8").trim().split("\n")){const o=JSON.parse(l);if(o.kind==="amend"&&o.finding_id==="find-m")n++}process.stdout.write(String(n))')"
assert_eq "$find_m_amends" "0" "an unadjudicated (empty-verdict) row is never written to"

# CR_LEDGER pin (codex-1, HIMMEL-2911 CR round 4): an ambient CR_LEDGER in the
# caller's environment must not redirect the amend write to a different file
# than the one promote just read and evaluated.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch promote --head "$promote_head_a" --model stub --id find-j \
    --severity sug --file promote.txt --line 8 --verdict "" \
    --text "tidy up the promote fixture kappa"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch promote --head "$promote_head_a" --id find-j \
    --set verdict=agreed --reason "leg agrees with kappa"
bogus_ledger="$tmp/bogus-ledger-shouldnt-be-used.jsonl"
promote_out_env="$(cd "$repo" && CR_LEDGER="$bogus_ledger" bash "$fx/scripts/cr/review-round.sh" promote --branch promote --head "$promote_head_b")"
assert_has "$promote_out_env" "promoted find-j@" "an ambient CR_LEDGER does not stop promote reading the real ledger"
if [ -e "$bogus_ledger" ]; then fail "ambient CR_LEDGER redirected the amend write"; else pass "ambient CR_LEDGER never gets a write"; fi
assert_has "$(cat "$promote_ledger" 2>/dev/null)" '"finding_id":"find-j"' "find-j's fixed amend lands in the real ledger promote evaluated"

# HIMMEL-3461: review-round.sh's own amendsByKey gains the branch dimension,
# mirroring ledger-append.sh / clear-cr-marker.sh / handover-bridge.sh
# (HIMMEL-2405). Two branches can legitimately share a head (HIMMEL-1175), so
# an amend recorded while judging one branch must never leak into another
# branch's promote decision.
git -C "$repo" branch branchkey-b "$promote_head_a"

# (n) cross-branch: an amend recorded for branch "promote" at promote_head_a
# must NOT apply to a same-id finding on branch "branchkey-b" at the same
# head, even though the two branches share both the head and the finding id.
# ledger-append.sh itself now refuses to WRITE a mismatched --branch amend
# (HIMMEL-3467), so this exercises review-round.sh's READ side directly by
# injecting the raw ledger row a pre-HIMMEL-3467 writer (or a foreign branch's
# own legitimate amend that later collided) could have produced.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch branchkey-b --head "$promote_head_a" --model stub --id find-n \
    --severity sug --file promote.txt --line 10 --verdict "" \
    --text "tidy up the promote fixture nu"
printf '{"kind":"amend","ts":"2020-01-01T00:00:00Z","branch":"promote","target_head":"%s","finding_id":"find-n","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"leg agrees with nu on the OTHER branch"}\n' "$promote_head_a" >> "$promote_ledger"

# (o) same-branch positive control: an amend recorded for branch
# "branchkey-b" at promote_head_a DOES apply while judging branchkey-b.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch branchkey-b --head "$promote_head_a" --model stub --id find-o \
    --severity sug --file promote.txt --line 11 --verdict "" \
    --text "tidy up the promote fixture xi"
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" amend \
    --branch branchkey-b --head "$promote_head_a" --id find-o \
    --set verdict=agreed --reason "leg agrees with xi on its own branch"

# (p) legacy back-compat: an amend row with NO branch field at all (written
# before branches were stamped, HIMMEL-2405) still applies to ANY branch.
CR_LEDGER="$promote_ledger" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch branchkey-b --head "$promote_head_a" --model stub --id find-p \
    --severity sug --file promote.txt --line 12 --verdict "" \
    --text "tidy up the promote fixture pi"
printf '{"kind":"amend","ts":"2020-01-01T00:00:00Z","target_head":"%s","finding_id":"find-p","artifact":"diff","perspective":"off","set":{"verdict":"agreed"},"reason":"legacy branchless amend"}\n' "$promote_head_a" >> "$promote_ledger"

git -C "$repo" checkout -q branchkey-b
branchkey_out="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" promote --branch branchkey-b --head "$promote_head_b")"
git -C "$repo" checkout -q promote
assert_has "$branchkey_out" "$(printf 'still-open find-n@%s (unadjudicated)' "$(printf '%s' "$promote_head_a" | cut -c1-8)")" "HIMMEL-3461 (n) a different branch's amend does not merge into this branch's finding"
assert_has "$branchkey_out" "promoted find-o@" "HIMMEL-3461 (o) a same-branch amend still merges (positive control)"
assert_has "$branchkey_out" "promoted find-p@" "HIMMEL-3461 (p) a legacy branchless amend still applies (back-compat)"

# Negative control: a malformed ledger row refuses automatic promotion and writes nothing.
promote_lines_before="$(wc -l < "$promote_ledger" | tr -d ' ')"
printf 'not-json-at-all\n' >> "$promote_ledger"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" promote --branch promote --head "$promote_head_b" >/dev/null 2>"$tmp/promote3.err"); promote_rc3=$?
promote_lines_after="$(wc -l < "$promote_ledger" | tr -d ' ')"
assert_eq "$promote_rc3" "1" "a malformed ledger row makes promote exit 1"
assert_has "$(cat "$tmp/promote3.err")" "malformed CR ledger row" "malformed-ledger refusal names the reason"
assert_eq "$promote_lines_after" "$((promote_lines_before + 1))" "malformed-ledger run appends nothing beyond the injected garbage line"

# HIMMEL-4700: a judge NO-GO on the last reviewed head, as the console-kit
# verdict writer records it, buys exactly one delta round. The records are
# written by the real writer from the fixture anchor, so the scope the writer
# and review-round.sh resolve must agree.
mkdir -p "$fx/scripts/handover/console-kit"
cp "$HERE/../handover/console-kit/write-verdict.sh" "$fx/scripts/handover/console-kit/write-verdict.sh"
for lib in go-gate.sh handover-path.sh user-slug.sh forge.sh forge-github.sh forge-bitbucket.sh; do
    cp "$HERE/../lib/$lib" "$fx/scripts/lib/$lib"
done
git -C "$fx" -c init.defaultBranch=main init -q
vroot="$tmp/hroot"
mkdir -p "$vroot"
HANDOVER_DIR="$vroot" USER_SLUG=tuser
export HANDOVER_DIR USER_SLUG
vscope="$vroot/tuser/fx/verdicts"
# The writer takes evidence only from /tmp/claude-<uid>/ (HIMMEL-4714).
jscratch="/tmp/claude-$(id -u)"
[ -d "$jscratch" ] || mkdir -m 700 "$jscratch" || fail "cannot create $jscratch"
jev="$(mktemp -d "$jscratch/pr-check-rounds.XXXXXX")" || { fail "mktemp -d in $jscratch"; exit 1; }
trap 'rm -rf "$tmp" "$jev"' EXIT
printf 'class: option-parsing\n\nthe fix does not hold\n' > "$jev/judge-evidence.md"
judge() {
    env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_RELAY CLAUDE_CODE_SESSION_ID=judge-sess-4700 \
        bash "$fx/scripts/handover/console-kit/write-verdict.sh" "$1" "$2" "$3" \
        --pr 1 --evidence-file "$jev/judge-evidence.md" >/dev/null 2>"$tmp/judge-$1.err" || fail "judge writes $1 $2"
}
start_round() {
    (cd "$repo" && PANEL_MODE="${2:-clean}" bash "$SCRIPT" --head "$1" --branch "$3" 2>&1)
}

# RED: a judge NO-GO on the round-3 head enables the delta round for its fix.
three_rounds judgenogo clean
jn_r3="$cap_r3_head"
fix_commit judgenogo
jn_fix="$cap_fix_head"
jn_out="$(start_round "$jn_fix" clean judgenogo)"; jn_rc=$?
assert_eq "$jn_rc" "8" "without a judge record, a fix after a clean round 3 gets no delta round"
judge jn-1 NO-GO "$jn_r3"
jn_out="$(start_round "$jn_fix" clean judgenogo)"; jn_rc=$?
assert_eq "$jn_rc" "0" "a judge NO-GO on the last reviewed head enables the delta round"
assert_has "$jn_out" "pr-check: delta round 4 on judgenogo (from $jn_r3)" "the judge-triggered round is a delta from the last reviewed head"
assert_has "$(cat "$git_dir/cr-review-rounds/judgenogo.delta")" "verdict:jn-1" "the delta state names the judge record"
# Each record buys one round: the reviewed delta head needs its own NO-GO.
printf 'second fix\n' >> "$repo/judgenogo.txt"
git -C "$repo" commit -q -am "judgenogo second fix"
jn_fix2="$(git -C "$repo" rev-parse judgenogo)"
jn2_out="$(start_round "$jn_fix2" clean judgenogo)"; jn2_rc=$?
assert_eq "$jn2_rc" "8" "a judge record for an earlier head buys no second delta round"
assert_has "$jn2_out" "delta round was already used" "second-delta refusal still names the used delta"
printf 'class: cwd-indirection\n\na different finding\n' > "$jev/judge-evidence.md"
judge jn-2 NO-GO "$jn_fix"
jn3_out="$(start_round "$jn_fix2" clean judgenogo)"; jn3_rc=$?
assert_eq "$jn3_rc" "0" "a fresh judge NO-GO on the reviewed delta head buys one more delta round"
assert_has "$jn3_out" "pr-check: delta round 5 on judgenogo (from $jn_fix)" "the next judge round is scoped from the delta head"

# HIMMEL-4885: real writer records on two reviewed heads must not buy
# repeated rounds for the same class. Without the class stop this reaches 5.
three_rounds classrepeat clean
cr_first="$cap_r3_head"
fix_commit classrepeat
cr_second="$cap_fix_head"
printf 'class: option-parsing\n\nfirst option-parsing finding\n' > "$jev/judge-evidence.md"
judge class-repeat NO-GO "$cr_first"
cr_out="$(start_round "$cr_second" clean classrepeat)"; cr_rc=$?
assert_eq "$cr_rc" "0" "first class delta is allowed"
printf 'another fix\n' >> "$repo/classrepeat.txt"
git -C "$repo" commit -q -am "classrepeat another fix"
cr_third="$(git -C "$repo" rev-parse classrepeat)"
printf 'class: option-parsing\n\nsecond option-parsing finding\n' > "$jev/judge-evidence.md"
judge class-repeat-next NO-GO "$cr_second"
cr_out="$(start_round "$cr_third" clean classrepeat)"; cr_rc=$?
assert_eq "$cr_rc" "8" "class-repeat-across-heads-refused"
assert_has "$cr_out" "option-parsing" "class repeat refusal names the class"
assert_has "$cr_out" "layer-decision:" "class repeat refusal names the way out"
# Keep the first head's history on this branch, but use a different class
# for other positive controls so unrelated fixture qids cannot stop them.
for class_case in different-class-allowed layer-decision-unlocks other-repeat-refused class-set-overlap-refused legacy-classless-nogo-never-matches finding-trigger-history-retained second-candidate-repeat-refused candidate-class-history-retained; do
    cc_panel=clean
    [ "$class_case" != finding-trigger-history-retained ] || cc_panel=suggestion
    three_rounds "$class_case" "$cc_panel"
    cc_first="$cap_r3_head"
    fix_commit "$class_case"
    cc_second="$cap_fix_head"
    cc_first_class=option-parsing
    cc_next_class=option-parsing
    cc_want=8
    cc_layer=""
    case "$class_case" in
        different-class-allowed) cc_next_class=cwd-indirection; cc_want=0 ;;
        layer-decision-unlocks) cc_layer='layer-decision: os same-uid file access belongs at the OS layer'; cc_want=0 ;;
        other-repeat-refused) cc_first_class=other; cc_next_class=other ;;
        class-set-overlap-refused) cc_first_class='shell-parsing, option-parsing'; cc_next_class='reader-allowlist, shell-parsing' ;;
        legacy-classless-nogo-never-matches) cc_want=0 ;;
    esac
    printf 'class: %s\n\nfirst finding\n' "$cc_first_class" > "$jev/judge-evidence.md"
    judge "$class_case-first" NO-GO "$cc_first"
    if [ "$class_case" = candidate-class-history-retained ]; then
        printf 'class: cwd-indirection\n\nfirst candidate\n' > "$jev/judge-evidence.md"
        judge "a-$class_case-first" NO-GO "$cc_first"
    fi
    if [ "$class_case" = legacy-classless-nogo-never-matches ]; then
        # Model a record written before class: existed, retaining its stamp.
        sed -i.bak '/^class:/d' "$vscope/$class_case-first/judge.md"
        rm -f "$vscope/$class_case-first/judge.md.bak"
    fi
    cc_out="$(start_round "$cc_second" clean "$class_case")"; cc_rc=$?
    assert_eq "$cc_rc" "0" "$class_case first round setup"
    printf 'next fix\n' >> "$repo/$class_case.txt"
    git -C "$repo" commit -q -am "$class_case next fix"
    cc_third="$(git -C "$repo" rev-parse "$class_case")"
    printf 'class: %s\n%s\n\nnext finding\n' "$cc_next_class" "$cc_layer" > "$jev/judge-evidence.md"
    judge "$class_case-next" NO-GO "$cc_second"
    if [ "$class_case" = second-candidate-repeat-refused ]; then
        printf 'class: cwd-indirection\n\nanother current candidate\n' > "$jev/judge-evidence.md"
        judge "a-$class_case-next" NO-GO "$cc_second"
    fi
    cc_out="$(start_round "$cc_third" clean "$class_case")"; cc_rc=$?
    assert_eq "$cc_rc" "$cc_want" "$class_case"
    if [ "$cc_want" = 8 ]; then
        assert_eq "$(cat "$git_dir/cr-review-rounds/$class_case.round")" "4" "$class_case leaves counter unchanged"
        assert_has "$cc_out" "layer-decision:" "$class_case names decision remedy"
    fi
done
# A consumed qid cannot buy another round, but later NO-GOs in that
# same-PR qid must still veto a fresh, different-class judge trigger.
for consumed_case in consumed-qid-repeat-refused consumed-qid-layer-unlocks; do
    three_rounds "$consumed_case" clean
    cq_first="$cap_r3_head"
    fix_commit "$consumed_case"
    cq_second="$cap_fix_head"
    printf 'class: option-parsing\n\nfirst finding\n' > "$jev/judge-evidence.md"
    judge "$consumed_case" NO-GO "$cq_first"
    cq_out="$(start_round "$cq_second" clean "$consumed_case")"; cq_rc=$?
    assert_eq "$cq_rc" "0" "$consumed_case first round setup"
    printf 'next fix\n' >> "$repo/$consumed_case.txt"
    git -C "$repo" commit -q -am "$consumed_case next fix"
    cq_third="$(git -C "$repo" rev-parse "$consumed_case")"
    cq_layer=""
    cq_want=8
    if [ "$consumed_case" = consumed-qid-layer-unlocks ]; then
        cq_layer='layer-decision: os same-uid access belongs at the OS layer'
        cq_want=0
    fi
    printf 'class: option-parsing\n%s\n\nrepeated finding\n' "$cq_layer" > "$jev/judge-evidence.md"
    judge "$consumed_case" NO-GO "$cq_second"
    if [ "$cq_want" = 8 ]; then
        cq_out="$(start_round "$cq_third" clean "$consumed_case")"; cq_rc=$?
        assert_eq "$cq_rc" "8" "consumed-only qid cannot spend again"
        assert_has "$cq_out" "layer-decision:" "consumed-only repeat still names class remedy"
    fi
    printf 'class: cwd-indirection\n\nfresh different-class trigger\n' > "$jev/judge-evidence.md"
    judge "$consumed_case-next" NO-GO "$cq_second"
    cq_out="$(start_round "$cq_third" clean "$consumed_case")"; cq_rc=$?
    assert_eq "$cq_rc" "$cq_want" "$consumed_case"
    if [ "$cq_want" = 8 ]; then
        assert_eq "$(cat "$git_dir/cr-review-rounds/$consumed_case.round")" "4" "$consumed_case leaves counter unchanged"
        assert_has "$cq_out" "layer-decision:" "$consumed_case names class remedy"
    fi
done
# HIMMEL-4945: a git error (exit 128: the earlier head is missing from this
# clone) is not proof the earlier NO-GO is off this PR. The record must keep
# its class veto; only a clean exit 1 drops it.
three_rounds ancestry-error-keeps-record clean
ae_first="$cap_r3_head"
fix_commit ancestry-error-keeps-record
ae_second="$cap_fix_head"
printf 'class: cwd-indirection\n\nfirst finding\n' > "$jev/judge-evidence.md"
judge ancestry-error-first NO-GO "$ae_first"
ae_out="$(start_round "$ae_second" clean ancestry-error-keeps-record)"; ae_rc=$?
assert_eq "$ae_rc" "0" "ancestry-error first round setup"
printf 'next fix\n' >> "$repo/ancestry-error-keeps-record.txt"
git -C "$repo" commit -q -am "ancestry-error next fix"
ae_third="$(git -C "$repo" rev-parse ancestry-error-keeps-record)"
ae_missing="$(printf 'b%.0s' $(seq 1 40))"
printf 'class: option-parsing\n\nearlier head absent from this clone\n' > "$jev/judge-evidence.md"
judge ancestry-error-candidate NO-GO "$ae_missing"
printf 'class: option-parsing\n\ncurrent repeat\n' > "$jev/judge-evidence.md"
judge ancestry-error-candidate NO-GO "$ae_second"
ae_out="$(start_round "$ae_third" clean ancestry-error-keeps-record)"; ae_rc=$?
assert_eq "$ae_rc" "8" "a git error on the ancestry check keeps the earlier NO-GO"
assert_has "$ae_out" "ancestry check could not run" "git-error line is stable and names the check"
assert_has "$ae_out" "option-parsing" "git-error refusal names the retained class"

three_rounds same-head-not-a-repeat clean
sh_first="$cap_r3_head"
fix_commit same-head-not-a-repeat
printf 'class: option-parsing\n\nsame head findings\n' > "$jev/judge-evidence.md"
judge same-head-one NO-GO "$sh_first"
judge same-head-two NO-GO "$sh_first"
sh_out="$(start_round "$cap_fix_head" clean same-head-not-a-repeat)"; sh_rc=$?
assert_eq "$sh_rc" "0" "same-head-not-a-repeat"
assert_has "$sh_out" "delta round 4" "same-head NO-GOs buy the first delta only"
printf 'class: option-parsing\n\nthe fix does not hold\n' > "$jev/judge-evidence.md"

# The same record never buys a second round, even while its round is pending.
three_rounds judgeonce clean
jo_r3="$cap_r3_head"
fix_commit judgeonce
judge jo-1 NO-GO "$jo_r3"
(start_round "$cap_fix_head" fail judgeonce >/dev/null) || fail "judgeonce pending delta setup"
printf 'another\n' >> "$repo/judgeonce.txt"
git -C "$repo" commit -q -am "judgeonce another"
jo_out="$(start_round "$(git -C "$repo" rev-parse judgeonce)" clean judgeonce)"; jo_rc=$?
assert_eq "$jo_rc" "8" "a second delta round on the same judge record is refused"
assert_has "$jo_out" "delta round was already used" "same-record refusal names the used delta"
assert_eq "$(cat "$git_dir/cr-review-rounds/judgeonce.round")" "4" "the refused second delta leaves the counter at 4"

# A delta round that fails to record does not spend the judge record.
three_rounds judgekeep clean
jk_r3="$cap_r3_head"
fix_commit judgekeep
judge jk-1 NO-GO "$jk_r3"
# A read-only directory at the .delta path fails only the delta write.
mkdir "$git_dir/cr-review-rounds/judgekeep.delta"
chmod a-w "$git_dir/cr-review-rounds/judgekeep.delta"
jk_out="$(start_round "$cap_fix_head" clean judgekeep)"; jk_rc=$?
chmod u+w "$git_dir/cr-review-rounds/judgekeep.delta"
rm -rf "$git_dir/cr-review-rounds/judgekeep.delta"
assert_eq "$jk_rc" "5" "an unwritable delta state fails the judge-triggered round"
jk_out="$(start_round "$cap_fix_head" clean judgekeep)"; jk_rc=$?
assert_eq "$jk_rc" "0" "the judge record survives a failed delta write and buys the round on retry"
assert_has "$jk_out" "pr-check: delta round 4 on judgekeep (from $jk_r3)" "the retried judge round is the delta round"

# Forged, unsigned or malformed records are refused.
judge_refused() {  # <branch> <label>: the fix head after a clean round 3 stays refused
    _jr_out="$(start_round "$cap_fix_head" clean "$1")"; _jr_rc=$?
    assert_eq "$_jr_rc" "8" "$2"
    assert_eq "$(cat "$git_dir/cr-review-rounds/$1.round")" "3" "$2 (counter stays at 3)"
}
three_rounds jhand clean
fix_commit jhand
mkdir -p "$vscope/jhand-1"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
printf '# VERDICT jhand-1 - judge\n\n## Verdict\n\n**NO-GO** for head `%s`.\n' "$cap_r3_head" > "$vscope/jhand-1/judge.md"
judge_refused jhand "a hand-written record without the writer's stamp is refused"
three_rounds jbadline clean
fix_commit jbadline
judge jbad-1 NO-GO "$cap_r3_head"
sed -i.bak 's/^\*\*NO-GO\*\* for head/**NO-GO** at head/' "$vscope/jbad-1/judge.md"
rm -f "$vscope/jbad-1/judge.md.bak"
judge_refused jbadline "a record whose verdict line does not parse is refused"
three_rounds jqid clean
fix_commit jqid
judge jqid-1 NO-GO "$cap_r3_head"
mkdir -p "$vscope/jqid-2"
mv "$vscope/jqid-1/judge.md" "$vscope/jqid-2/judge.md"
judge_refused jqid "a record moved under another qid is refused"
three_rounds jgo clean
fix_commit jgo
judge jgo-1 GO "$cap_r3_head"
judge_refused jgo "a judge GO is no delta trigger"
three_rounds jother clean
fix_commit jother
judge jother-1 NO-GO "$cap_fix_head"
judge_refused jother "a NO-GO for another head is no delta trigger"
three_rounds jscope clean
fix_commit jscope
judge jscope-1 NO-GO "$cap_r3_head"
mkdir -p "$vroot/tuser/elsewhere/verdicts"
mv "$vscope/jscope-1" "$vroot/tuser/elsewhere/verdicts/jscope-1"
judge_refused jscope "a record in another repo's verdict scope is refused"
three_rounds jlink clean
fix_commit jlink
judge jlink-1 NO-GO "$cap_r3_head"
mv "$vscope/jlink-1" "$tmp/jlink-real"
ln -s "$tmp/jlink-real" "$vscope/jlink-1"
judge_refused jlink "a symlinked verdict directory is refused"
# HIMMEL-4720: a record with the writer's layout but a bad stamp is refused.
three_rounds jstamp clean
fix_commit jstamp
judge jstamp-1 NO-GO "$cap_r3_head"
sed -i.bak 's/^writer-session: .*/writer-session: forged session!/' "$vscope/jstamp-1/judge.md"
rm -f "$vscope/jstamp-1/judge.md.bak"
judge_refused jstamp "a laid-out record with a malformed writer-session stamp is refused"
three_rounds jwhen clean
fix_commit jwhen
judge jwhen-1 NO-GO "$cap_r3_head"
sed -i.bak 's/^written-at: .*/written-at: yesterday/' "$vscope/jwhen-1/judge.md"
rm -f "$vscope/jwhen-1/judge.md.bak"
judge_refused jwhen "a laid-out record with a malformed written-at stamp is refused"

# HIMMEL-4720: one record buys one round even when .head never moved. The
# counter write fails after the delta and verdict writes landed, so the
# .verdicts line is the only thing refusing a second round from that head,
# even when a fresh, unconsumed record exists for it.
real_mv="$(command -v mv)"
mkdir -p "$tmp/mvshim"
cat > "$tmp/mvshim/mv" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in */jonly.round) exit 1 ;; esac; done
exec "$real_mv" "\$@"
SHIM
chmod +x "$tmp/mvshim/mv"
three_rounds jonly clean
jy_r3="$cap_r3_head"
fix_commit jonly
judge jy-1 NO-GO "$jy_r3"
jy_rc=0; PATH="$tmp/mvshim:$PATH" start_round "$cap_fix_head" clean jonly >/dev/null || jy_rc=$?
assert_eq "$jy_rc" "5" "a failed counter write fails the judge-triggered round"
assert_has "$(cat "$git_dir/cr-review-rounds/jonly.verdicts" 2>/dev/null)" " jy-1/" "the judge record was consumed before the counter write"
assert_eq "$(cat "$git_dir/cr-review-rounds/jonly.head" 2>/dev/null)" "$jy_r3" "the failed round leaves the last reviewed head in place"
# A fresh record for the same head: only the per-head .verdicts line refuses it.
judge jy-2 NO-GO "$jy_r3"
printf 'another\n' >> "$repo/jonly.txt"
git -C "$repo" commit -q -am "jonly another"
jy_rc=0; start_round "$(git -C "$repo" rev-parse jonly)" clean jonly >/dev/null || jy_rc=$?
assert_eq "$jy_rc" "8" "the consumed record alone refuses a second round from the same head"
assert_eq "$(cat "$git_dir/cr-review-rounds/jonly.round")" "3" "the refused round leaves the counter at 3"

# HIMMEL-4720: a record is consumed by qid across branches, so two branches
# with the same last reviewed head cannot each spend the same NO-GO.
three_rounds jbr1 clean
jbr_r3="$cap_r3_head"
git -C "$repo" checkout -q -b jbr2 "$jbr_r3"
for n in 1 2 3; do
    (start_round "$jbr_r3" clean jbr2 >/dev/null) || fail "jbr2 fixture setup round $n"
done
# The ledger dedups avail on (head,model), so the stub's jbr1 row hides jbr2's:
# give jbr2 its own critic row at the shared head.
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" avail \
    --branch jbr2 --head "$jbr_r3" --model stub-jbr2 --status ok >/dev/null 2>"$tmp/jbr2-avail.err" || fail "jbr2 avail setup"
judge jbr-1 NO-GO "$jbr_r3"
git -C "$repo" checkout -q jbr1
fix_commit jbr1
jbr_rc=0; start_round "$cap_fix_head" clean jbr1 >/dev/null || jbr_rc=$?
assert_eq "$jbr_rc" "0" "the judge NO-GO buys the delta round on the first branch"
git -C "$repo" checkout -q jbr2
printf 'fix2\n' >> "$repo/jbr1.txt"
git -C "$repo" commit -q -am "fix jbr2"
cap_fix_head="$(git -C "$repo" rev-parse jbr2)"
jbr_rc=0; start_round "$cap_fix_head" clean jbr2 >/dev/null || jbr_rc=$?
assert_eq "$jbr_rc" "8" "the same judge record buys no round on a second branch with the same reviewed head"
assert_eq "$(cat "$git_dir/cr-review-rounds/jbr2.round")" "3" "the refused second-branch round leaves its counter at 3"

# HIMMEL-4738: a consumed-qid scan that fails refuses the record rather than
# reading as "not consumed". chmod is ignored by root, so a grep shim fails
# the cross-branch scan and a directory stands in for the per-head file.
real_grep="$(command -v grep)"
mkdir -p "$tmp/grepshim"
cat > "$tmp/grepshim/grep" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--include=*.verdicts" ] && exit 2; done
exec "$real_grep" "\$@"
SHIM
chmod +x "$tmp/grepshim/grep"
three_rounds jscan clean
fix_commit jscan
judge jscan-1 NO-GO "$cap_r3_head"
js_rc=0; js_out="$(PATH="$tmp/grepshim:$PATH" start_round "$cap_fix_head" clean jscan)" || js_rc=$?
assert_eq "$js_rc" "8" "a failed cross-branch consumed-qid scan refuses the judge record"
assert_has "$js_out" "cannot scan" "the failed cross-branch scan is named"
assert_eq "$(cat "$git_dir/cr-review-rounds/jscan.round")" "3" "the refused scan-failure round leaves the counter at 3"
three_rounds jhscan clean
fix_commit jhscan
judge jhscan-1 NO-GO "$cap_r3_head"
mkdir "$git_dir/cr-review-rounds/jhscan.verdicts"
jh_rc=0; jh_out="$(start_round "$cap_fix_head" clean jhscan)" || jh_rc=$?
rm -rf "$git_dir/cr-review-rounds/jhscan.verdicts"
assert_eq "$jh_rc" "8" "an unreadable per-head .verdicts refuses the judge record"
assert_has "$jh_out" "cannot read" "the unreadable per-head .verdicts is named"
assert_eq "$(cat "$git_dir/cr-review-rounds/jhscan.round")" "3" "the refused per-head scan-failure round leaves the counter at 3"

# HIMMEL-4952: a judge-signed record admits ONE post-cap delta round for a
# test- or lint-only delta. The record is a GO written by the real writer for
# the delta's NEW head, carrying `delta-scope:` and `delta-from:` evidence lines.
scope_commit() {
    # scope_commit <branch> <path> : commit a change to <path>, set scope_head
    mkdir -p "$(dirname "$repo/$2")"
    printf '%s\n' "$2" >> "$repo/$2"
    git -C "$repo" add "$2"
    git -C "$repo" commit -q -m "scope change $2"
    scope_head="$(git -C "$repo" rev-parse "$1")"
}
scope_judge() {
    # scope_judge <qid> <head> <scope> <from>
    printf 'delta-scope: %s\ndelta-from: %s\n\nthe delta changes no production path\n' "$3" "$4" > "$jev/judge-evidence.md"
    judge "$1" GO "$2"
}

# RED: without a record a clean test-only commit after the cap gets no round.
three_rounds scopeok clean
sc_r3="$cap_r3_head"
scope_commit scopeok tests/test-scope.sh
sc_head="$scope_head"
sc_out="$(start_round "$sc_head" clean scopeok)"; sc_rc=$?
assert_eq "$sc_rc" "8" "a test-only delta with no judge record gets no round after the cap"
scope_judge sc-1 "$sc_head" test-only "$sc_r3"
sc_out="$(start_round "$sc_head" clean scopeok)"; sc_rc=$?
assert_eq "$sc_rc" "0" "a judge-signed test-only delta is admitted after the cap"
assert_has "$sc_out" "pr-check: delta round 4 on scopeok (from $sc_r3)" "the scope round is a delta from the last reviewed head"
assert_has "$(cat "$git_dir/cr-review-rounds/scopeok.delta")" "scope:sc-1" "the delta state names the scope record"
# Second use: the record is spent, and a further test-only commit needs its own.
scope_commit scopeok tests/test-scope-two.sh
sc_head2="$scope_head"
sc_out="$(start_round "$sc_head2" clean scopeok)"; sc_rc=$?
assert_eq "$sc_rc" "8" "a spent scope record buys no second round"
assert_has "$sc_out" "delta round was already used" "the second-use refusal names the used delta"

# A delta that touches production code is refused even with a test-only record.
three_rounds scopeprod clean
sp_r3="$cap_r3_head"
scope_commit scopeprod scopeprod.txt
sp_head="$scope_head"
scope_judge sp-1 "$sp_head" test-only "$sp_r3"
sp_out="$(start_round "$sp_head" clean scopeprod)"; sp_rc=$?
assert_eq "$sp_rc" "8" "a test-only record cannot admit a delta that changes a non-test path"
assert_has "$sp_out" "non-test" "the refusal names the non-test path"

# A record for another head is refused.
three_rounds scopehead clean
sh_r3="$cap_r3_head"
scope_commit scopehead tests/test-scope-a.sh
sh_a="$scope_head"
scope_commit scopehead tests/test-scope-b.sh
sh_b="$scope_head"
scope_judge sh-1 "$sh_a" test-only "$sh_r3"
sh_out="$(start_round "$sh_b" clean scopehead)"; sh_rc=$?
assert_eq "$sh_rc" "8" "a scope record for another head is refused"

# A record whose delta-from is not the last reviewed head is refused.
three_rounds scopefrom clean
scope_commit scopefrom tests/test-scope-f.sh
sf_head="$scope_head"
scope_judge sf-1 "$sf_head" test-only "$sf_head"
sf_rc=0; start_round "$sf_head" clean scopefrom >/dev/null || sf_rc=$?
assert_eq "$sf_rc" "8" "a scope record naming another delta-from is refused"

# A hand-written file (not the writer's format) is refused.
three_rounds scopeforge clean
sg_r3="$cap_r3_head"
scope_commit scopeforge tests/test-scope-g.sh
sg_head="$scope_head"
mkdir -p "$vscope/sg-1"
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
printf '# VERDICT sg-1 - judge\n\n**GO** for head `%s`.\n\ndelta-scope: test-only\ndelta-from: %s\n' "$sg_head" "$sg_r3" > "$vscope/sg-1/judge.md"
sg_rc=0; start_round "$sg_head" clean scopeforge >/dev/null || sg_rc=$?
assert_eq "$sg_rc" "8" "a hand-written scope record is refused"
rm -rf "$vscope/sg-1"

# An unknown scope word is refused.
three_rounds scopeword clean
sw_r3="$cap_r3_head"
scope_commit scopeword tests/test-scope-w.sh
sw_head="$scope_head"
scope_judge sw-1 "$sw_head" anything "$sw_r3"
sw_rc=0; start_round "$sw_head" clean scopeword >/dev/null || sw_rc=$?
assert_eq "$sw_rc" "8" "a scope record with an unknown delta-scope is refused"

# Moving a production file into tests/ is a rename git reports as its
# destination only; the scope check must still see the production path leave.
three_rounds scoperen clean
sn_r3="$cap_r3_head"
mkdir -p "$repo/tests"
git -C "$repo" mv scoperen.txt tests/test-scoperen.sh
git -C "$repo" commit -q -m "move scoperen into tests"
sn_head="$(git -C "$repo" rev-parse scoperen)"
scope_judge sn-1 "$sn_head" test-only "$sn_r3"
sn_out="$(start_round "$sn_head" clean scoperen)"; sn_rc=$?
assert_eq "$sn_rc" "8" "a rename of a production file into tests/ is not a test-only delta"
assert_has "$sn_out" "non-test" "the rename refusal names the removed production path"

# A second, conflicting delta-from line in the evidence is refused.
three_rounds scopedup clean
sd_r3="$cap_r3_head"
scope_commit scopedup tests/test-scope-d.sh
sd_head="$scope_head"
printf 'delta-scope: test-only\ndelta-from: %s\ndelta-from: %s\n\nno production path\n' "$sd_r3" "$sd_head" > "$jev/judge-evidence.md"
judge sd-1 GO "$sd_head"
start_round "$sd_head" clean scopedup >/dev/null; sd_rc=$?
assert_eq "$sd_rc" "8" "a scope record with two delta-from lines is refused"

# A test path with a non-ASCII name is still a test path (git would quote it).
three_rounds scopeuni clean
su_r3="$cap_r3_head"
scope_commit scopeuni "tests/test-caf$(printf '\303\251').sh"
su_head="$scope_head"
scope_judge su-1 "$su_head" test-only "$su_r3"
start_round "$su_head" clean scopeuni >/dev/null; su_rc=$?
assert_eq "$su_rc" "0" "a test-only delta with a non-ASCII test path is admitted"

# A filename pattern must not match across a directory: a production file under
# a test-named directory is not a test file.
three_rounds scopedir clean
sdr_r3="$cap_r3_head"
scope_commit scopedir src/module.test.js/production.js
sdr_head="$scope_head"
scope_judge sdr-1 "$sdr_head" test-only "$sdr_r3"
sdr_out="$(start_round "$sdr_head" clean scopedir)"; sdr_rc=$?
assert_eq "$sdr_rc" "8" "a production file under a .test.js directory is not a test-only delta"
assert_has "$sdr_out" "non-test" "the directory-pattern refusal names the non-test path"

# lint-only: the judge's record alone admits it (no path rule can tell lint
# from behaviour).
three_rounds scopelint clean
sl_r3="$cap_r3_head"
scope_commit scopelint scopelint.txt
sl_head="$scope_head"
scope_judge sl-1 "$sl_head" lint-only "$sl_r3"
sl_rc=0; start_round "$sl_head" clean scopelint >/dev/null || sl_rc=$?
assert_eq "$sl_rc" "0" "a judge-signed lint-only delta is admitted after the cap"
assert_has "$(cat "$git_dir/cr-review-rounds/scopelint.delta")" "scope:sl-1" "the lint-only delta state names the scope record"

# The existing fix trigger is unchanged and still records itself as fix.
assert_has "$(cat "$git_dir/cr-review-rounds/fixpath.delta")" " fix" "the fix trigger still records fix"
assert_has "$(cat "$git_dir/cr-review-rounds/feature.delta")" " merge-forward" "the merge-forward trigger still records merge-forward"

# HIMMEL-4995: a CLEAN merge of main past the cap is admitted without spending
# the one delta round; a merge that changes the PR's own diff or resolves a
# conflict is not, unless a judge-signed merge-resolution record binds it.
main_commit() {
    # main_commit <file> <content>: commit <file> on main, push, return to the branch
    mm_back="$(git -C "$repo" branch --show-current)"
    git -C "$repo" checkout -q main
    printf '%s\n' "$2" > "$repo/$1"
    git -C "$repo" add "$1"
    git -C "$repo" commit -q -m "main $1"
    git -C "$repo" push -q origin main
    git -C "$repo" checkout -q "$mm_back"
}

# Clean merge: admitted, repeatable, and the delta round stays unspent.
three_rounds cmok clean
cm_r3="$cap_r3_head"
main_commit cm-main-1.txt one
git -C "$repo" merge -q --no-edit main
cm_head="$(git -C "$repo" rev-parse cmok)"
cm_out="$(start_round "$cm_head" clean cmok)"; cm_rc=$?
assert_eq "$cm_rc" "0" "a clean merge of main after the cap is admitted"
assert_has "$cm_out" "pr-check: delta round 4 on cmok (from $cm_r3)" "the clean merge is scoped from the last reviewed head"
if [ -e "$git_dir/cr-review-rounds/cmok.delta" ]; then fail "a clean merge leaves the delta round unspent"; else pass "a clean merge leaves the delta round unspent"; fi
main_commit cm-main-2.txt two
git -C "$repo" merge -q --no-edit main
cm_head2="$(git -C "$repo" rev-parse cmok)"
cm_out="$(start_round "$cm_head2" clean cmok)"; cm_rc=$?
assert_eq "$cm_rc" "0" "a second clean merge is admitted too"

# The one delta round is still there for a real fix after the clean merges.
printf 'fix\n' >> "$repo/cmok.txt"
git -C "$repo" commit -q -am "fix cmok"
cm_fix="$(git -C "$repo" rev-parse cmok)"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch cmok --head "$cm_head2" --model stub --id stub-cm --severity sug --file f.txt --line 1 \
    --verdict agreed >/dev/null 2>"$tmp/cmok-finding.err" || fail "cmok finding setup"
cm_out="$(start_round "$cm_fix" clean cmok)"; cm_rc=$?
assert_eq "$cm_rc" "0" "the unspent delta round still buys a fix after clean merges"
assert_has "$(cat "$git_dir/cr-review-rounds/cmok.delta" 2>/dev/null)" " fix" "that fix records the fix trigger"

# Delta already spent: a clean merge is still admitted, one that changes the
# PR's own diff is not (main lands the same f.txt line the PR appended).
three_rounds cmused suggestion
printf 'fix\n' >> "$repo/cmused.txt"
printf 'extra\n' >> "$repo/f.txt"
git -C "$repo" commit -q -am "fix cmused"
cap_fix_head="$(git -C "$repo" rev-parse cmused)"
start_round "$cap_fix_head" clean cmused >/dev/null || fail "cmused delta setup"
main_commit cm-used-1.txt one
git -C "$repo" merge -q --no-edit main
cu_head="$(git -C "$repo" rev-parse cmused)"
cu_rc=0; start_round "$cu_head" clean cmused >/dev/null || cu_rc=$?
assert_eq "$cu_rc" "0" "a clean merge is admitted after the delta round was spent"
main_commit f.txt "$(git -C "$repo" show main:f.txt; echo extra)"
git -C "$repo" merge -q --no-edit main
cu_head2="$(git -C "$repo" rev-parse cmused)"
cu_rc=0; start_round "$cu_head2" clean cmused >/dev/null || cu_rc=$?
assert_eq "$cu_rc" "8" "a merge that changes the PR's own diff is not admitted after the delta was spent"

# Conflict merge: refused without a record, admitted with a bound one.
three_rounds cmconf clean
cc_r3="$cap_r3_head"
main_commit cmconf.txt "from main"
git -C "$repo" merge -q --no-commit main >/dev/null 2>&1 || true
printf 'resolved\n' > "$repo/cmconf.txt"
git -C "$repo" add cmconf.txt
git -C "$repo" commit -q --no-edit
cc_head="$(git -C "$repo" rev-parse cmconf)"
cc_out="$(start_round "$cc_head" clean cmconf)"; cc_rc=$?
assert_eq "$cc_rc" "8" "a conflict-resolving merge gets no round without a record"
scope_judge cc-1 "$cc_head" merge-resolution "$cc_r3"
cc_out="$(start_round "$cc_head" clean cmconf)"; cc_rc=$?
assert_eq "$cc_rc" "0" "a judge-signed merge-resolution record admits the conflict merge"
assert_has "$(cat "$git_dir/cr-review-rounds/cmconf.delta")" "scope:cc-1" "the delta state names the merge-resolution record"

# A merge-resolution record for another head, or another delta-from, is refused.
three_rounds cmhead clean
ch_r3="$cap_r3_head"
main_commit cmhead.txt "from main"
git -C "$repo" merge -q --no-commit main >/dev/null 2>&1 || true
printf 'resolved\n' > "$repo/cmhead.txt"
git -C "$repo" add cmhead.txt
git -C "$repo" commit -q --no-edit
ch_head="$(git -C "$repo" rev-parse cmhead)"
scope_judge ch-1 "$ch_r3" merge-resolution "$ch_r3"
ch_rc=0; start_round "$ch_head" clean cmhead >/dev/null || ch_rc=$?
assert_eq "$ch_rc" "8" "a merge-resolution record for another head is refused"
scope_judge ch-2 "$ch_head" merge-resolution "$ch_head"
ch_rc=0; start_round "$ch_head" clean cmhead >/dev/null || ch_rc=$?
assert_eq "$ch_rc" "8" "a merge-resolution record naming another delta-from is refused"

# A merge-resolution record cannot admit a delta that is not a merge of main.
three_rounds cmplain clean
cp_r3="$cap_r3_head"
scope_commit cmplain cmplain-extra.txt
cp_head="$scope_head"
scope_judge cp-1 "$cp_head" merge-resolution "$cp_r3"
cp_rc=0; start_round "$cp_head" clean cmplain >/dev/null || cp_rc=$?
assert_eq "$cp_rc" "8" "a merge-resolution record cannot admit a delta that is not a merge of main"

# A merge whose parents are both the PR's own commits (no parent on main) is not
# a merge of main, so a merge-resolution record cannot admit it either.
git -C "$repo" checkout -q -b cmoff main
printf 'a\n' > "$repo/cmoff.txt"
git -C "$repo" add cmoff.txt
git -C "$repo" commit -q -m "cmoff a"
co_a="$(git -C "$repo" rev-parse cmoff)"
printf 'b\n' >> "$repo/cmoff.txt"
git -C "$repo" commit -q -am "cmoff b"
co_b="$(git -C "$repo" rev-parse cmoff)"
for n in 1 2 3; do
    (cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$co_b" --branch cmoff >/dev/null 2>"$tmp/cmoff-$n.err") || fail "cmoff fixture setup round $n"
done
printf 'edited\n' >> "$repo/cmoff.txt"
git -C "$repo" add cmoff.txt
co_tree="$(git -C "$repo" write-tree)"
co_m="$(git -C "$repo" commit-tree "$co_tree" -p "$co_b" -p "$co_a" -m "cmoff internal merge")"
git -C "$repo" reset -q --hard "$co_m"
scope_judge co-1 "$co_m" merge-resolution "$co_b"
co_rc=0; start_round "$co_m" clean cmoff >/dev/null || co_rc=$?
assert_eq "$co_rc" "8" "a merge-resolution record cannot admit a merge with no parent on main"

# HIMMEL-4638 T1: an inherited delta_reuse never skips the counter bump on a
# round before the cap (delta_reuse was only initialised inside delta_check).
git -C "$repo" checkout -q -b t1init main
(cd "$repo" && delta_reuse=1 bash "$fx/scripts/cr/review-round.sh" start --branch t1init >/dev/null 2>&1); t1_rc=$?
assert_eq "$t1_rc" "0" "an exported delta_reuse does not break a round-1 start"
assert_eq "$(cat "$git_dir/cr-review-rounds/t1init.round")" "1" "an exported delta_reuse does not skip the round-1 counter bump"

# HIMMEL-4638 T2: a pending delta pair is reusable only while no critic finding
# row exists at its head, even if the avail row never landed.
three_rounds t2row suggestion
fix_commit t2row
(start_round "$cap_fix_head" fail t2row >/dev/null) || fail "t2row pending delta setup"
CR_LEDGER="$git_dir/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch t2row --head "$cap_fix_head" --model stub --id stub-t2 \
    --severity sug --file f.txt --line 2 --verdict "" >/dev/null 2>"$tmp/t2row-finding.err" || fail "t2row finding row setup"
t2_out="$(start_round "$cap_fix_head" clean t2row)"; t2_rc=$?
assert_eq "$t2_rc" "8" "a critic finding row at the pending head makes the delta round used"
assert_has "$t2_out" "delta round was already used" "finding-row refusal names the used delta"

# HIMMEL-4638 T3: a second start on a pending pair whose first start's caller
# is still alive is refused; once that caller is gone the pair restarts.
three_rounds t3conc suggestion
fix_commit t3conc
(start_round "$cap_fix_head" fail t3conc >/dev/null) || fail "t3conc pending delta setup"
t3_claim="$(grep -Ec '^[0-9]+$' "$git_dir/cr-review-rounds/t3conc.delta.run" 2>/dev/null)"
assert_eq "$t3_claim" "1" "a real delta start records its caller pid"
sleep 60 &
t3_pid=$!
printf '%s\n' "$t3_pid" > "$git_dir/cr-review-rounds/t3conc.delta.run"
t3_out="$(start_round "$cap_fix_head" clean t3conc)"; t3_rc=$?
assert_eq "$t3_rc" "8" "a concurrent start on a pending delta round is refused"
assert_has "$t3_out" "already running" "concurrent-start refusal names the running round"
kill "$t3_pid" 2>/dev/null; wait "$t3_pid" 2>/dev/null
t3b_out="$(start_round "$cap_fix_head" clean t3conc)"; t3b_rc=$?
assert_eq "$t3b_rc" "0" "a pending delta round restarts once the earlier start's caller is gone"
assert_has "$t3b_out" "delta round 4 on t3conc" "the restarted pair is still the delta round"

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-pr-check-rounds (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-pr-check-rounds\n'
