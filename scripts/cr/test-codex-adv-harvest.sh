#!/usr/bin/env bash
# scripts/cr/test-codex-adv-harvest.sh -- tests for codex-adv-harvest.sh
# (HIMMEL-2226). Bash 3.2 safe. Mirrors the assert/temp-repo/PASS-FAIL pattern
# in test-write-verdicts.sh and test-codex-adv-completion-check.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/codex-adv-harvest.sh"

fails=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 -- got '$1' want '$2'"; fails=$((fails + 1)); }; }
check_contains() {
    case "$2" in
        *"$3"*) ;;
        *) echo "FAIL: $1 -- expected output to contain '$3', got: $2"; fails=$((fails + 1)) ;;
    esac
}
check_not_contains() {
    case "$2" in
        *"$3"*) echo "FAIL: $1 -- expected output NOT to contain '$3', got: $2"; fails=$((fails + 1)) ;;
        *) ;;
    esac
}

tmp="$(mktemp -d -t codex-adv-harvest.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

# HIMMEL-2544: T7's two mutation controls (T7-R1/T7-R2 below) go through the
# RED-control contract helper (HIMMEL-2518) rather than a hand-rolled
# inequality -- it asserts the mutant RAN, PRODUCED a value, and produced the
# SPECIFIC predicted wrong value. RED_CONTROL_TMPDIR keeps the helper's stderr
# captures inside $tmp, which the EXIT trap above already cleans.
# shellcheck disable=SC2034  # read by the sourced red-control.sh
RED_CONTROL_TMPDIR="$tmp"
# shellcheck source=scripts/lib/red-control.sh
# shellcheck disable=SC1091
. "$HERE/../lib/red-control.sh"

# literal_replace_line <in> <out> <old-line> <new-line> -- copy <in> to <out>
# replacing ONE exact, whole-line literal. VERIFIED, not hoped-for: the line
# must appear exactly once in <in>, must be gone from <out>, the replacement
# must appear exactly once in <out>, and the two files must differ by exactly
# the two diff lines one substitution produces. A silently-failed mutation
# makes the control it feeds vacuous, which is the whole class HIMMEL-2518
# exists to refuse, so this returns non-zero and says which check failed
# instead of handing back a copy that merely looks mutated. (awk, not a
# python/perl heredoc: patching shell through a heredoc writes literal control
# characters and flattens line continuations.)
literal_replace_line() {
    local in="$1" out="$2" old="$3" new="$4"
    local pre post newc difflines
    pre=$(awk -v L="$old" '$0 == L { n++ } END { print n + 0 }' "$in")
    if [ "$pre" -ne 1 ]; then
        echo "literal_replace_line: expected exactly 1 occurrence of the target line in $in, found $pre" >&2
        return 1
    fi
    awk -v L="$old" -v R="$new" '$0 == L { print R; next } { print }' "$in" > "$out" || return 1
    post=$(awk -v L="$old" '$0 == L { n++ } END { print n + 0 }' "$out")
    newc=$(awk -v L="$new" '$0 == L { n++ } END { print n + 0 }' "$out")
    if [ "$post" -ne 0 ] || [ "$newc" -ne 1 ]; then
        echo "literal_replace_line: mutation did not apply cleanly (old line still present: $post, new line present: $newc)" >&2
        return 1
    fi
    difflines=$(diff "$in" "$out" | awk '/^[<>]/ { n++ } END { print n + 0 }')
    if [ "$difflines" -ne 2 ]; then
        echo "literal_replace_line: expected exactly 2 changed diff lines, got $difflines" >&2
        return 1
    fi
    return 0
}

# build_harvest_anchor <dir> -- assemble a throwaway "fake himmel" tree holding
# everything codex-adv-harvest.sh resolves off its own SCRIPT_DIR/HIMMEL_ROOT,
# so a MUTATED copy dropped at <dir>/scripts/cr/codex-adv-harvest.sh has a
# genuine HIMMEL_ROOT and runs to COMPLETION. A mutant that dies early proves
# nothing (contract point (a)) -- that is exactly how T7 in
# test-pr-check-context.sh was found vacuous in PR #2135. The dir is mktemp
# scratch only: a mutant NEVER lives in the real tree (HIMMEL-2503).
build_harvest_anchor() {
    local d="$1"
    mkdir -p "$d/scripts/cr" "$d/scripts/guardrails" "$d/scripts/lib" || return 1
    cp "$HERE/ledger-append.sh" "$d/scripts/cr/ledger-append.sh" || return 1
    cp "$HERE/codex-adv-completion-check.sh" "$d/scripts/cr/codex-adv-completion-check.sh" || return 1
    # Only reachable on the HIMMEL-1420 retry path, which T7's fixture never
    # takes -- copied (with the lib it sources) so the anchor is not silently
    # incomplete for a future case that does take it.
    cp "$HERE/run-codex-adversarial.sh" "$d/scripts/cr/run-codex-adversarial.sh" || return 1
    cp "$HERE/../guardrails/lib.sh" "$d/scripts/guardrails/lib.sh" || return 1
    cp "$HERE/../lib/load-dotenv.sh" "$d/scripts/lib/load-dotenv.sh" || return 1
    cp "$HERE/../lib/proc-tree.sh" "$d/scripts/lib/proc-tree.sh" || return 1
    cp "$HERE/../lib/render-lease.sh" "$d/scripts/lib/render-lease.sh" || return 1
    return 0
}

# ledger_head <ledger-file> -- the `head` field of the ledger's first row, or
# the literal token "none" when there is no row. A literal token, never an
# empty string: an empty observed value is a RED-control FAILURE by contract
# (point (b)), so "no row" must be a value the control can assert on.
ledger_head() {
    [ -s "$1" ] || { printf 'none\n'; return 0; }
    L="$1" node -e 'console.log(require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse)[0].head)'
}

# ledger_rows <ledger-file> -- row count, whitespace-free.
ledger_rows() { wc -l < "$1" | tr -d ' '; }

# Isolate $HOME: the HIMMEL-1420 retry path globs
# $HOME/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs
# to re-resolve the companion. Test 5 below deliberately drives that retry
# path (rc=0, empty stdout), and it must NEVER launch a real
# run-codex-adversarial.sh (no quota spend, no network) regardless of whether
# codex happens to be installed on the machine running this suite. Pointing
# HOME at an empty fixture dir guarantees the glob matches nothing, so the
# script takes its own "companion path could not be re-resolved" branch and
# stops there -- the retry path is structurally exercised, never a real
# invocation.
fakehome="$tmp/fakehome"
mkdir -p "$fakehome"

repo="$tmp/repo"
mkdir -p "$repo"
(
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git commit -q --allow-empty -m init
)
git_dir="$repo/.git"
out_dir="$git_dir/codex-adv-out"

# run_harvest <branch> -- checks out <branch> in the fixture repo and runs the
# script there with an isolated HOME, capturing stdout/stderr/rc under $tmp.
# CR_PROFILE must be exported by the caller before calling this.
run_harvest() {
    local branch="$1"
    (
        cd "$repo" || exit 1
        git checkout -q -B "$branch" >/dev/null 2>&1
        HOME="$fakehome" bash "$SCRIPT"
    ) >"$tmp/out" 2>"$tmp/err"
    echo $? >"$tmp/rc"
}

# -- T1: CR_PROFILE=none -> harvests nothing, no codex-adv-status: line. ----
export CR_PROFILE=none
run_harvest "t1-none"
check "$(cat "$tmp/rc")" "0" "T1 rc"
check "$(cat "$tmp/out")" "" "T1 stdout empty"
check_not_contains "T1 no codex-adv-status" "$(cat "$tmp/err")" "codex-adv-status:"
unset CR_PROFILE

# -- T2: no pid file (nothing was launched) -> harvests nothing, no
#    codex-adv-status: line. ------------------------------------------------
export CR_PROFILE=free
run_harvest "t2-nopid"
check "$(cat "$tmp/rc")" "0" "T2 rc"
check "$(cat "$tmp/out")" "" "T2 stdout empty"
check_not_contains "T2 no codex-adv-status" "$(cat "$tmp/err")" "codex-adv-status:"
unset CR_PROFILE

# -- T3: rc file contains a non-zero rc -> "codex adversarial pass failed
#    (rc=...)" on stderr, codex-adv-status: unavailable. -------------------
branch="t3-rcfail"
export CR_PROFILE=free
mkdir -p "$out_dir"
codex_out="$out_dir/$branch"
printf '99999\n' >"${codex_out}.pid"
printf '1\n' >"${codex_out}.rc"
printf '0\n' >"${codex_out}.pid.cleanup-rc"
run_harvest "$branch"
check "$(cat "$tmp/rc")" "0" "T3 script rc"
check_contains "T3 fail message" "$(cat "$tmp/err")" "codex adversarial pass failed (rc=1"
check_contains "T3 status unavailable" "$(cat "$tmp/err")" "codex-adv-status: unavailable"
unset CR_PROFILE

# -- T4: rc=0 with stdout the completion check accepts -> findings reach
#    stdout, codex-adv-status: ok. ------------------------------------------
branch="t4-ok"
export CR_PROFILE=free
codex_out="$out_dir/$branch"
printf '99999\n' >"${codex_out}.pid"
printf '0\n' >"${codex_out}.rc"
printf '0\n' >"${codex_out}.pid.cleanup-rc"
cat >"$codex_out" <<'EOF'
# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Found a SQL injection risk in the query builder.

Findings:
- [high] SQL injection in query builder (src/db.js:42)
  Untrusted input concatenated directly into the query string.
EOF
: >"${codex_out}.err"
run_harvest "$branch"
check "$(cat "$tmp/rc")" "0" "T4 script rc"
check_contains "T4 findings on stdout" "$(cat "$tmp/out")" "SQL injection in query builder"
check_contains "T4 status ok" "$(cat "$tmp/err")" "codex-adv-status: ok"
unset CR_PROFILE

# -- T5: rc=0 with EMPTY stdout (HIMMEL-1420 silent-death shape) -> does NOT
#    report ok (no companion resolvable under fakehome, so the bounded retry
#    stops at "companion path could not be re-resolved" -- never a real
#    run-codex-adversarial.sh invocation). ----------------------------------
branch="t5-empty"
export CR_PROFILE=free
codex_out="$out_dir/$branch"
printf '99999\n' >"${codex_out}.pid"
printf '0\n' >"${codex_out}.rc"
printf '0\n' >"${codex_out}.pid.cleanup-rc"
: >"$codex_out"
: >"${codex_out}.err"
run_harvest "$branch"
check "$(cat "$tmp/rc")" "0" "T5 script rc"
check "$(cat "$tmp/out")" "" "T5 stdout empty (no findings leaked)"
check_not_contains "T5 never reports ok" "$(cat "$tmp/err")" "codex-adv-status: ok"
check_contains "T5 silent-death message" "$(cat "$tmp/err")" "silent death suspected"
check_contains "T5 retry never reached a real invocation" "$(cat "$tmp/err")" "retry skipped"
unset CR_PROFILE

# -- T6: cleanup unverified (cleanup-rc file holds a non-zero value) ->
#    sidecar files are PRESERVED, not deleted (fail-closed direction). -----
branch="t6-cleanup"
export CR_PROFILE=free
codex_out="$out_dir/$branch"
pid_file="${codex_out}.pid"
identity_file="${pid_file}.identity"
rc_file="${codex_out}.rc"
cleanup_rc_file="${pid_file}.cleanup-rc"
printf '99999\n' >"$pid_file"
printf 'fake-identity\n' >"$identity_file"
printf '0\n' >"$rc_file"
printf '1\n' >"$cleanup_rc_file"  # non-zero, not 3 -> cleanup unverified
cat >"$codex_out" <<'EOF'
# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: approve

Nothing of concern in this diff.

No material findings.
EOF
: >"${codex_out}.err"
run_harvest "$branch"
check "$(cat "$tmp/rc")" "0" "T6 script rc"
check_contains "T6 cleanup unverified message" "$(cat "$tmp/err")" "cleanup unverified"
[ -f "$pid_file" ] || { echo "FAIL: T6 pid_file was deleted (should be preserved)"; fails=$((fails + 1)); }
[ -f "$identity_file" ] || { echo "FAIL: T6 identity_file was deleted (should be preserved)"; fails=$((fails + 1)); }
[ -f "$rc_file" ] || { echo "FAIL: T6 rc_file was deleted (should be preserved)"; fails=$((fails + 1)); }
[ -f "$cleanup_rc_file" ] || { echo "FAIL: T6 cleanup_rc_file was deleted (should be preserved)"; fails=$((fails + 1)); }
unset CR_PROFILE

# -- T7 (HIMMEL-2321 CR round 4, HIMMEL-1175 head-drift class): with
#    codex-adv-kickoff.sh now persisting the launched head to a `.head`
#    sidecar (same "${codex_out}.SUFFIX" convention as .pid/.rc/.err), the
#    self-write reads it back and stamps the ledger with the commit the pass
#    ACTUALLY reviewed - not whatever HEAD happens to be at harvest time.
#
#    RED-FIRST, the case that motivated this: the pass is "launched" at
#    commit A (the pid/rc/output sidecar files exist, as if a companion run
#    completed, AND kickoff wrote .head=A), then a CONCURRENT commit B lands
#    on the branch before harvest runs. The ledger row must carry A, not B.
#    Two mutants make those assertions non-vacuous, and both are BUILT AND RUN
#    below as T7-R1 / T7-R2 under the RED-control contract
#    (scripts/lib/red-control.sh, HIMMEL-2518). (1) T7-R1, the code as
#    committed before this round, never reads .head at all and writes NO row;
#    (2) T7-R2, a naive `git rev-parse HEAD` variant (the original round 1/2
#    bug), stamps commit B - the commit the pass never saw.
#
#    HIMMEL-2544: this comment used to claim both mutants were "shown red
#    below (see the CR round 4 report for the actual red output)" while this
#    file built no mutant at all -- the RED evidence lived only in a review
#    report, was not reproducible by running the suite, and would have rotted
#    silently the moment the code moved. The controls below replace that
#    claim with something the suite itself re-proves on every run.
branch="t7-headdrift"
export CR_PROFILE=free
(cd "$repo" && git checkout -q -B "$branch" >/dev/null 2>&1 && git commit -q --allow-empty -m "commit A - what the simulated pass reviewed")
COMMIT_A="$(cd "$repo" && git rev-parse "$branch")"
codex_out="$out_dir/$branch"
printf '99999\n' >"${codex_out}.pid"
printf '0\n' >"${codex_out}.rc"
printf '0\n' >"${codex_out}.pid.cleanup-rc"
# The sidecar codex-adv-kickoff.sh now writes at launch time (HIMMEL-2321/
# HIMMEL-1175 CR round 4) - simulated directly here, same as the pid/rc
# sidecars above simulate a completed companion run without actually
# launching kickoff.sh.
printf '%s\n' "$COMMIT_A" >"${codex_out}.head"
cat >"$codex_out" <<'EOF'
# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

One issue found.

Findings:
- [critical] the script's rc is unchecked (src/db.js:42)
EOF
: >"${codex_out}.err"
# Commit B lands on the branch AFTER the simulated pass "launched" but
# BEFORE harvest runs - the drift window this fix closes.
(cd "$repo" && git commit -q --allow-empty -m "commit B - lands during the async wait, the pass never saw this")
COMMIT_B="$(cd "$repo" && git rev-parse "$branch")"
LEDGER7="$tmp/ledger7.jsonl"; : >"$LEDGER7"
export CR_LEDGER="$LEDGER7"
# run_harvest does its own `git checkout -q -B "$branch"`, which on an
# EXISTING branch is a no-op checkout (stays on commit B) - it does not
# create a fresh branch off the current HEAD, so commit B set up above
# survives into the harvest run.
run_harvest "$branch"
check "$(cat "$tmp/rc")" "0" "T7 script rc"
check_contains "T7 status ok" "$(cat "$tmp/err")" "codex-adv-status: ok"
check_contains "T7 stdout unchanged (findings still surfaced for manual adjudication)" "$(cat "$tmp/out")" "the script's rc is unchecked"
check \
    "$(wc -l < "$LEDGER7" | tr -d ' ')" \
    "1" "T7 exactly one ledger row written (the launched-head record made it recoverable)"
check \
    "$(L="$LEDGER7" node -e 'console.log(require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse)[0].head)')" \
    "$COMMIT_A" "T7 row is stamped with the LAUNCHED head (commit A), not the drifted one"
check \
    "$([ "$(L="$LEDGER7" node -e 'console.log(require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse)[0].head)')" = "$COMMIT_B" ] && echo yes || echo no)" \
    "no" "T7 row is NOT stamped with the drifted head (commit B)"
unset CR_LEDGER
unset CR_PROFILE

# -- T7-R1 / T7-R2: the two RED controls T7's comment names. ADDITIVE and run
#    AFTER T7's own assertions, so the unmutated evidence is established
#    first. Each one resets the sidecars T7's verified-clean harvest deleted,
#    points CR_LEDGER at a FRESH empty ledger, and runs the mutant with the
#    same isolated HOME run_harvest uses. codex-adv-harvest.sh always exits 0
#    (it is a harvest/report step, never a gate), so --expect-rc 0; the
#    mutant's stdout is the findings text, non-empty in both cases, and the
#    value asserted on is the LEDGER the self-write produced.
reset_t7_fixture() {
    printf '99999\n' >"${codex_out}.pid"
    printf '0\n' >"${codex_out}.rc"
    printf '0\n' >"${codex_out}.pid.cleanup-rc"
    printf '%s\n' "$COMMIT_A" >"${codex_out}.head"
    : >"${codex_out}.err"
}
anchor7="$tmp/fake-himmel-t7-red"
mutant7="$anchor7/scripts/cr/codex-adv-harvest.sh"
if ! build_harvest_anchor "$anchor7"; then
    echo "FAIL: T7 RED -- could not assemble the fake-himmel anchor at $anchor7"
    fails=$((fails + 1))
else
    # T7-R1: the pre-round-4 code, which never reads the .head sidecar. The
    # minimal faithful mutation is a launched-head record path that cannot
    # exist, which reproduces that behaviour exactly: warn-and-skip, no row.
    # shellcheck disable=SC2016  # literal match against codex-adv-harvest.sh's
    # own source text (unexpanded $vars) -- not a shell expansion.
    if literal_replace_line "$SCRIPT" "$mutant7" \
        '    _cxl_head_file="${codex_out}.head"' \
        '    _cxl_head_file="${codex_out}.head-suffix-that-cannot-exist"'; then
        reset_t7_fixture
        LEDGER7R1="$tmp/ledger7-r1.jsonl"; : >"$LEDGER7R1"
        export CR_PROFILE=free
        export CR_LEDGER="$LEDGER7R1"
        red_control_run --cwd "$repo" --env HOME="$fakehome" -- bash "$mutant7"
        red_control_assert --label "T7-R1" --expect-rc 0 \
            --observed     "rows=$(ledger_rows "$LEDGER7R1") head=$(ledger_head "$LEDGER7R1")" \
            --expect-wrong "rows=0 head=none" \
            --correct      "rows=1 head=$COMMIT_A" \
            --note "without the launched-head record the self-write is skipped entirely, so T7's 'exactly one ledger row' assertion is load-bearing" \
            || fails=$((fails + 1))
        unset CR_LEDGER
        unset CR_PROFILE
    else
        echo "FAIL: T7-R1 -- could not build the never-reads-.head mutant"
        fails=$((fails + 1))
    fi

    # T7-R2: the original round 1/2 bug -- resolve the head at HARVEST time
    # instead of reading what kickoff recorded at LAUNCH time.
    # shellcheck disable=SC2016  # literal match against codex-adv-harvest.sh's
    # own source text (unexpanded $vars) -- not a shell expansion.
    if literal_replace_line "$SCRIPT" "$mutant7" \
        '    _cxl_head="$(cat "$_cxl_head_file" 2>/dev/null)" || _cxl_head=""' \
        '    _cxl_head="$(git rev-parse HEAD 2>/dev/null)" || _cxl_head=""'; then
        reset_t7_fixture
        LEDGER7R2="$tmp/ledger7-r2.jsonl"; : >"$LEDGER7R2"
        export CR_PROFILE=free
        export CR_LEDGER="$LEDGER7R2"
        red_control_run --cwd "$repo" --env HOME="$fakehome" -- bash "$mutant7"
        red_control_assert --label "T7-R2" --expect-rc 0 \
            --observed     "rows=$(ledger_rows "$LEDGER7R2") head=$(ledger_head "$LEDGER7R2")" \
            --expect-wrong "rows=1 head=$COMMIT_B" \
            --correct      "rows=1 head=$COMMIT_A" \
            --note "the round 1/2 bug stamps the commit the pass never saw; T7's head==COMMIT_A assertion is what catches it" \
            || fails=$((fails + 1))
        unset CR_LEDGER
        unset CR_PROFILE
    else
        echo "FAIL: T7-R2 -- could not build the naive rev-parse-HEAD mutant"
        fails=$((fails + 1))
    fi
fi

# -- T8 (HIMMEL-2321 CR round 3/4, the genuinely-unrecoverable case): when
#    kickoff could not resolve or record a head (or its record predates this
#    fix / is missing for any other reason), the self-write must still
#    warn-and-skip, never guess - this refusal is the exception now, not the
#    permanent state, but it must still hold.
branch="t8-nohead"
export CR_PROFILE=free
codex_out="$out_dir/$branch"
printf '99999\n' >"${codex_out}.pid"
printf '0\n' >"${codex_out}.rc"
printf '0\n' >"${codex_out}.pid.cleanup-rc"
cat >"$codex_out" <<'EOF'
# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

One issue found.

Findings:
- [high] a finding with no recoverable head (src/z.js:1)
EOF
: >"${codex_out}.err"
LEDGER8="$tmp/ledger8.jsonl"; : >"$LEDGER8"
export CR_LEDGER="$LEDGER8"
run_harvest "$branch"
check "$(cat "$tmp/rc")" "0" "T8 script rc"
check_contains "T8 stdout unchanged" "$(cat "$tmp/out")" "a finding with no recoverable head"
check_contains "T8 warns that the launched head cannot be proven" "$(cat "$tmp/err")" "no launched-head record"
check "$(wc -l < "$LEDGER8" | tr -d ' ')" "0" "T8 NO ledger row written (no .head sidecar to trust)"
unset CR_LEDGER
unset CR_PROFILE

if [ "$fails" -eq 0 ]; then
    echo "PASS test-codex-adv-harvest"
else
    echo "$fails FAILED"
    exit 1
fi
