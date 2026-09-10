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
cp "$HERE/base-resolver.sh" "$fx/scripts/cr/base-resolver.sh"
cp "$HERE/review-round.sh" "$fx/scripts/cr/review-round.sh"
cp "$HERE/ledger-append.sh" "$fx/scripts/cr/ledger-append.sh"
cp "$HERE/write-verdicts.sh" "$fx/scripts/cr/write-verdicts.sh"
cp "$HERE/clear-cr-marker.sh" "$fx/scripts/cr/clear-cr-marker.sh"
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
cat >/dev/null
printf '%s\n' "$head_sha" >> "$PANEL_CALLS"
printf '%s\n' "${CR_REVIEW_ROUND:-<absent>}" >> "$PANEL_ROUNDS"
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
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" start --branch contended >"$tmp/contended-1.out" 2>"$tmp/contended-1.err") &
contended_pid1=$!
arrival_wait=0
while [ "$(find "$tmp/counter-arrivals" -type f | wc -l | tr -d ' ')" -lt 1 ] && [ "$arrival_wait" -lt 50 ]; do
    sleep 0.1
    arrival_wait=$((arrival_wait + 1))
done
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" start --branch contended >"$tmp/contended-2.out" 2>"$tmp/contended-2.err") &
contended_pid2=$!
sleep 1
independent_out="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" start --branch independent)"; independent_rc=$?
printf 'release\n' > "$tmp/counter-release"
wait "$contended_pid1"; contended_rc1=$?
wait "$contended_pid2"; contended_rc2=$?
assert_eq "$contended_rc1" "0" "first contended counter start succeeds"
assert_eq "$contended_rc2" "0" "second contended counter start succeeds"
assert_eq "$(cat "$git_dir/cr-review-rounds/contended.round")" "2" "contended starts do not lose an increment"
assert_eq "$independent_rc" "0" "different branch starts while contended branch is locked"
assert_eq "$independent_out" "1" "different branch keeps an independent counter"

write_real_marker feature "$head3"
out5="$(cd "$repo" && PANEL_MODE=suggestion-on bash "$SCRIPT" --head "$head3" --branch feature 2>"$tmp/err5")"; rc5=$?
assert_eq "$rc5" "0" "round-4 suggestion-only panel run succeeds"
assert_has "$out5" "pr-check: round 4 of 3 on feature" "capped run prints round 4"
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
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$head3" --branch feature --defer-to HIMMEL-9000 >"$tmp/defer5-first.out" 2>"$tmp/defer5-first.err"); defer5_first_rc=$?
if [ "$defer5_first_rc" -ne 0 ]; then pass "post-amendment scratch failure leaves disposition incomplete"; else fail "post-amendment scratch failure leaves disposition incomplete"; fi
assert_has "$(cat "$git_dir/cr-critic-scores.jsonl" 2>/dev/null)" '"verdict":"deferred"' "failed disposition already persisted the deferred amendment"
if [ -e "$git_dir/cr-pending/feature" ]; then pass "failed disposition leaves the marker pending"; else fail "failed disposition leaves the marker pending"; fi
cp "$tmp/write-verdicts.real" "$fx/scripts/cr/write-verdicts.sh"
chmod +x "$fx/scripts/cr/write-verdicts.sh"
defer5="$(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$head3" --branch feature --defer-to HIMMEL-9000 2>"$tmp/defer5.err")"; defer5_rc=$?
assert_eq "$defer5_rc" "0" "retry repairs a post-amendment disposition failure"
assert_has "$defer5" "clear-cr-marker CLEARED branch=feature sha=$head3" "round-4 disposition retry passes the real marker gates"
assert_has "$defer5" "clear-cr-marker: CR clean" "round-4 disposition retry uses sanctioned marker clearance"
if [ -e "$git_dir/cr-pending/feature" ]; then
    fail "round-4 disposition retry clears the marker"
else
    pass "round-4 disposition retry clears the marker"
fi
ledger="$(cat "$git_dir/cr-critic-scores.jsonl" 2>/dev/null)"
assert_has "$ledger" '"verdict":"deferred"' "round-4 suggestions record a deferred verdict"
assert_has "$ledger" '"deferred_to":"HIMMEL-9000"' "round-4 suggestions record the shared defer ticket"
assert_has "$ledger" '"reason":"Suggestion deferred after the three-round /pr-check cap."' "round-4 suggestions record a finding reason"
identity_amends="$(LEDGER="$git_dir/cr-critic-scores.jsonl" node -e 'const fs=require("fs"),e=process.env;let n=0;for(const l of fs.readFileSync(e.LEDGER,"utf8").trim().split("\n")){const o=JSON.parse(l);if(o.kind==="amend"&&o.finding_id==="stub-1"&&o.artifact==="spec"&&o.perspective==="on")n++}process.stdout.write(String(n))')"
assert_eq "$identity_amends" "1" "round-4 recovery preserves non-default artifact and perspective identity"
assert_has "$(cat "$git_dir/cr-prior-blocking/feature" 2>/dev/null)" "VERDICT [kept-1] = disproved" "round-4 recovery preserves prior-blocking verdicts"
assert_has "$(cat "$git_dir/cr-aggregate-verdicts/feature" 2>/dev/null)" "VERDICT [kept-1] = disproved" "round-4 recovery preserves aggregate verdicts"
assert_has "$(cat "$git_dir/cr-prior-blocking/feature" 2>/dev/null)" "VERDICT [stub-1] = deferred -> HIMMEL-9000" "round-4 recovery repairs prior-blocking verdict scratch"
assert_has "$(cat "$git_dir/cr-aggregate-verdicts/feature" 2>/dev/null)" "VERDICT [stub-1] = deferred -> HIMMEL-9000" "round-4 recovery repairs aggregate verdict scratch"

# Later controls only need to observe whether clearance was attempted; the
# successful round-4 path above deliberately used the real gate.
install_clear_stub

# A round-4 Important finding remains blocking and never reaches marker clearance.
git -C "$repo" checkout -q -b important main
printf 'important\n' > "$repo/important.txt"
git -C "$repo" add important.txt
git -C "$repo" commit -q -m important
important_head="$(git -C "$repo" rev-parse important)"
for n in 1 2 3; do
    (cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$important_head" --branch important >/dev/null 2>"$tmp/important-$n.err") || fail "important fixture setup round $n"
done
printf 'pending\n' > "$git_dir/cr-pending/important"
out6="$(cd "$repo" && PANEL_MODE=important bash "$SCRIPT" --head "$important_head" --branch important 2>"$tmp/err6")"; rc6=$?
assert_eq "$rc6" "0" "round-4 Important producer run completes for adjudication"
assert_has "$out6" "pr-check: round 4 of 3 on important" "Important run prints round 4"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$important_head" --branch important --defer-to HIMMEL-9001 >"$tmp/defer6.out" 2>"$tmp/defer6.err"); defer6_rc=$?
if [ "$defer6_rc" -ne 0 ]; then pass "round-4 Important finding blocks disposition"; else fail "round-4 Important finding blocks disposition"; fi
assert_has "$(cat "$tmp/defer6.err")" "Critical or Important finding(s) remain blocking" "Important disposition explains the block"
assert_lacks "$(cat "$CLEAR_CALLS" 2>/dev/null)" "important" "Important finding never invokes marker clearance"
if [ -e "$git_dir/cr-pending/important" ]; then
    pass "Important finding leaves the marker pending"
else
    fail "Important finding leaves the marker pending"
fi

# Missing ticket stops after the producer writes findings, prints the exact Jira
# command, and can be resumed against those rows without another panel call.
git -C "$repo" checkout -q -b capped main
printf 'capped\n' > "$repo/capped.txt"
git -C "$repo" add capped.txt
git -C "$repo" commit -q -m capped
capped_head="$(git -C "$repo" rev-parse capped)"
for n in 1 2 3; do
    (cd "$repo" && PANEL_MODE=clean bash "$SCRIPT" --head "$capped_head" --branch capped >/dev/null 2>"$tmp/capped-$n.err") || fail "missing-ticket fixture setup round $n"
done
printf 'pending\n' > "$git_dir/cr-pending/capped"
before_missing_calls="$(wc -l < "$PANEL_CALLS" | tr -d ' ')"
out7="$(cd "$repo" && PANEL_MODE=suggestion bash "$SCRIPT" --head "$capped_head" --branch capped 2>"$tmp/err7")"; rc7=$?
assert_eq "$rc7" "0" "round-4 missing-ticket producer run completes"
assert_has "$out7" "pr-check: round 4 of 3 on capped" "missing-ticket run still reports its round"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" defer --head "$capped_head" --branch capped >"$tmp/defer7.out" 2>"$tmp/defer7.err"); defer7_rc=$?
if [ "$defer7_rc" -ne 0 ]; then pass "round-4 suggestions fail disposition without a defer ticket"; else fail "round-4 suggestions fail disposition without a defer ticket"; fi
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
    --set verdict=deferred --set deferred_to=HIMMEL-9010 --reason "deferred by hand"

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

# Negative control: a malformed ledger row refuses automatic promotion and writes nothing.
promote_lines_before="$(wc -l < "$promote_ledger" | tr -d ' ')"
printf 'not-json-at-all\n' >> "$promote_ledger"
(cd "$repo" && bash "$fx/scripts/cr/review-round.sh" promote --branch promote --head "$promote_head_b" >/dev/null 2>"$tmp/promote3.err"); promote_rc3=$?
promote_lines_after="$(wc -l < "$promote_ledger" | tr -d ' ')"
assert_eq "$promote_rc3" "1" "a malformed ledger row makes promote exit 1"
assert_has "$(cat "$tmp/promote3.err")" "malformed CR ledger row" "malformed-ledger refusal names the reason"
assert_eq "$promote_lines_after" "$((promote_lines_before + 1))" "malformed-ledger run appends nothing beyond the injected garbage line"

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-pr-check-rounds (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-pr-check-rounds\n'
