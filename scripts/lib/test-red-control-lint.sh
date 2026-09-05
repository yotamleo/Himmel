#!/usr/bin/env bash
# scripts/lib/test-red-control-lint.sh -- unit tests for the advisory
# vacuous-mutation-control lint (HIMMEL-2544, item 2).
#
# A report-only lint is judged on two things and this suite asserts both:
# what it FLAGS, and -- far more important -- what it leaves alone. T4 is the
# load-bearing case: an inequality control that DOES compare the mutant's exit
# status is a correct control, and a lint that flagged it would be noise nobody
# runs twice. T5 is its sibling, with the exit-status check elsewhere in the
# same block rather than in the test itself.
#
# Every case also asserts the exit status is 0, hits included. A suite that only
# checked stdout would stay green while the lint started exiting 1 and somebody
# wired it up as a gate -- the one outcome its header forbids.
#
# T9 scans the repo's real scripts/ tree and REPORTS. It asserts the exit status
# but deliberately does NOT fail on hits (CR round 1 [codex-3]): failing there
# would make an advisory tool a gate via run-shell-tests.sh, so a heuristic
# false positive on some future file would turn the whole shell suite red on
# unrelated work -- exactly the outcome the always-exit-0 design exists to
# prevent. The empty-on-main hit list stays a maintained invariant checked at
# review time; T8's fixture-tree count is the deterministic assertion that
# SHOULD fail on a regression.
#
# T11-T14 are the CR round 1 regressions: two false-negative holes the panel
# found (a flat compliance window, and a bare `$?` counting as a comparison),
# each pinned by the probe that exposed it.
#
# T15-T17 are CR round 2: a backward search that stopped at a CLOSED inner
# conditional, a `[ "$?" ]` nonempty-string test mistaken for an exit-status
# comparison, and -- the important one -- a failed awk run reporting itself as
# a clean scan, which was a vacuous green inside the vacuous-green detector.
#
# T16f-g and T18 are CR round 3: a `$?` compared INSIDE the then-branch reads
# the conditional's own status (0 because the branch was taken), never the
# mutant's, and a failed ENUMERATION was the same incomplete-scan class as the
# awk hole one layer up. Round 3 also repositioned T16d/T16e -- see the fixture
# comment; they were blessing a shape that proves nothing.
#
# T19-T20 are CR round 4: a control's own DIAGNOSTIC MESSAGE ("got != want
# (rc=$rc)") satisfied the rc rule because a variable and a comparison glyph
# merely co-occurred on the line; and T9 itself read EMPTY STDOUT as proof the
# tree was clean, when a wholly failed scan produces exactly that. T20 pins the
# fix by making a failed scan and a clean tree distinguishable to T9's own
# classifier -- absence is not evidence, inside the tool built to say so.
#
# T21-T22 are CR round 5, the last substantive round. The diagnostic-message
# family came back in a third spelling (`echo "expected $rc != 0"` satisfies
# even the adjacency rule), so it was closed as a CLASS: an echo/printf line
# establishes no exit-status evidence at all. T21d is the paired negative
# control -- `[ "$rc" -eq 0 ] && echo ok` must STILL be evidence, because the
# evidence there is the test, not the echo. T22 closes the last member of the
# incomplete-scan family: an invalid scan root.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure shell over a mktemp scratch dir; NOT ported to native PowerShell -- a
# test harness needs no .ps1 twin (project convention: a documented platform
# guard suffices for a test fixture), and the lint under test is itself
# gitbash-only for the same reason. This is the T15 marker
# scripts/parity/test-ws5-invariants.sh looks for.
#
# Usage: bash scripts/lib/test-red-control-lint.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/red-control-lint.sh"

pass=0
fails=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fails=$((fails+1)); echo "  FAIL: $1"; }
eq()  {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 - got '$2' want '$3'"; fi
}
has() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *)      bad "$1 - output did not mention '$3': $2" ;;
    esac
}

# HIMMEL-2503: pin the scratch path ONCE, before arming the trap that consumes
# it, and never repoint it afterwards. Every fixture below is derived from it.
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/red-control-lint-test.XXXXXX")" || {
    echo "FATAL: could not create scratch dir" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

fx="$tmpdir/fx"
mkdir -p "$fx/lib"
# The CR round 1 probe fixtures live OUTSIDE $fx on purpose, so T8's
# fixture-tree count stays the exact number it was written to assert.
probes="$tmpdir/probes"
mkdir -p "$probes"

# --- fixtures ---------------------------------------------------------------
# Seven shapes, spanning both verdicts. Nothing here touches a real path.
#
# The fixture bodies are printf ARGUMENTS, not heredocs, and that is deliberate:
# a heredoc would put bare `if ...` and `RED confirmed` lines into THIS file, and
# the lint -- a text matcher by design -- would then flag its own test suite.
# Measured: with heredoc fixtures the T9 real-tree scan reported a hit inside
# this file. Quoting each line keeps the `if` off a line start. Same reason
# scripts/lib/test-red-control.sh writes its mutants this way.
mk() { local f="$fx/$1"; shift; printf '%s\n' "$@" > "$f"; }

# shellcheck disable=SC2016  # every fixture below is SOURCE TEXT for a scratch
# script, not an expression for this shell to expand -- expanding it here is
# exactly the bug the single quotes prevent.
mk compliant.sh \
    '#!/usr/bin/env bash' \
    '# A compliant control: it drives the contract helper, so the surrounding' \
    '# inequality guard is not what proves anything.' \
    'if [ "$mode" != "skip" ]; then' \
    '    red_control_run --cwd "$wt" -- bash "$mutant"' \
    '    red_control_assert --label "T1" --observed "$got" --expect-wrong "rows=0" --correct "rows=1" >"$log" || fail=1' \
    '    grep -q "T1 RED confirmed" "$log" || fail=1' \
    'fi'

# shellcheck disable=SC2016  # ditto -- fixture source text.
mk smelly-inequality.sh \
    '#!/usr/bin/env bash' \
    '# The vacuous shape: inequality only, exit status never compared.' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'want="delegated=yes rows=1"' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "T1 RED confirmed: the mutant produced something else"' \
    'fi'

# shellcheck disable=SC2016  # ditto -- fixture source text.
mk smelly-existence.sh \
    '#!/usr/bin/env bash' \
    '# The T28 absence shape: a missing capture file proves nothing on its own.' \
    'cap="$scratch/capture.txt"' \
    'bash "$mutant" >/dev/null 2>&1' \
    'if [ ! -e "$cap" ]; then' \
    '    echo "T2 RED confirmed: the mutant never wrote the capture"' \
    'fi'

# shellcheck disable=SC2016  # ditto -- fixture source text.
mk near-miss-rc-in-test.sh \
    '#!/usr/bin/env bash' \
    '# THE false-positive control: the inequality is guarded by the mutant exit' \
    '# status, so this control is correct and the lint must stay silent on it.' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'rc=$?' \
    'if [ "$rc" -eq 0 ] && [ "$got" != "$want" ]; then' \
    '    echo "T3 RED confirmed: the mutant ran and produced the wrong value"' \
    'fi'

# shellcheck disable=SC2016  # ditto -- fixture source text.
mk near-miss-rc-in-block.sh \
    '#!/usr/bin/env bash' \
    '# The exit-status check sits elsewhere in the same block, not in the test.' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'mutant_rc=$?' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "T4 RED confirmed: the mutant produced the wrong value"' \
    '    [ "$mutant_rc" -eq 0 ] || { echo "  ... but it crashed"; fail=1; }' \
    'fi'

# shellcheck disable=SC2016  # ditto -- fixture source text.
mk comment-only.sh \
    '#!/usr/bin/env bash' \
    '# Prose about the pattern is not a control.' \
    'if [ "$got" != "$want" ]; then' \
    '    # a control here would print "RED confirmed" while proving nothing' \
    '    :' \
    'fi'

# The contract helper own path, carrying the smelly shape verbatim: it is the
# code that PRINTS the convention string, so it is compliant by construction.
# shellcheck disable=SC2016  # ditto -- fixture source text.
mk lib/red-control.sh \
    '#!/usr/bin/env bash' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "T5 RED confirmed"' \
    'fi'

# --- CR round 1 probes ------------------------------------------------------
# Four false-negative shapes the critic panel found. Each was measured NOT
# flagged (except the last, which was already correct and is pinned so the
# codex-2 fix cannot over-correct into suppressing it).
mkp() { local f="$probes/$1"; shift; printf '%s\n' "$@" > "$f"; }

# [codex-1] a separate, already-COMPLETED compliant control above a vacuous one:
# the old flat 40-line window saw red_control_run/assert and suppressed the hit.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp two-controls.sh \
    '#!/usr/bin/env bash' \
    'red_control_run --cwd "$wt" -- bash "$mutant_a"' \
    'red_control_assert --label "A" --observed "$got_a" --expect-wrong "wrong" --correct "right"' \
    '' \
    'want="correct"' \
    'got="$(bash "$mutant_b" 2>/dev/null)"' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "B RED confirmed: the mutant produced a different value"' \
    'fi'

# [codex-1] the same hole reached by a bare COMMENT naming the helper.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp comment-mention.sh \
    '#!/usr/bin/env bash' \
    '# This control should go through red_control_assert, but it does not.' \
    'want="correct"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "C RED confirmed: the mutant produced a different value"' \
    'fi'

# [codex-2] a BARE `$?` in a diagnostic echo inside the block -- not a
# comparison, so it must not buy the control an exemption.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp bare-status.sh \
    '#!/usr/bin/env bash' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "P2 RED confirmed: the mutant produced a different value (status $? for the record)"' \
    'fi'

# [codex-2] the mechanism codex-2 actually DESCRIBED -- an `rc=$?` capture
# BEFORE the `if`. That was already flagged correctly (the rc scan starts at the
# conditional, so a capture above it is out of range); pinned so the fix above
# cannot regress it into a false negative.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp rc-capture-before-if.sh \
    '#!/usr/bin/env bash' \
    'out="$(bash "$mutant" 2>/dev/null)"' \
    'rc=$?' \
    'if [ "$out" != "$want" ]; then' \
    '    echo "P1 RED confirmed: the mutant produced a different value (rc was $rc)"' \
    'fi'

# --- CR round 2 probes ------------------------------------------------------
# [codex-1] an inner conditional that has already CLOSED above the seed: the
# backward search used to stop at it and never examine the real vacuous guard.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp nested-inner-if.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'note="something"' \
    'if [ "$got" != "$want" ]; then' \
    '    if [ -n "$note" ]; then' \
    '        echo "note: $note"' \
    '    fi' \
    '    echo "R2A RED confirmed: the mutant produced a different value"' \
    'fi'

# [codex-1] the nesting walk must still match a one-LINE control ...
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp one-liner.sh \
    '#!/usr/bin/env bash' \
    'if [ "$got" != "$want" ]; then echo "R2F RED confirmed: one-line control"; fi'

# ... and must NOT invent a guard for a seed that sits after a CLOSED one.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp closed-then-seed.sh \
    '#!/usr/bin/env bash' \
    'if [ -n "$note" ]; then echo "note: $note"; fi' \
    'echo "R2G RED confirmed: this seed is inside no conditional at all"'

# [codex-2] `[ "$?" ]` is a nonempty-STRING test: $? always expands to
# something, so it is true for every exit status and compares nothing.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp bracket-status.sh \
    '#!/usr/bin/env bash' \
    'if [ "$got" != "$want" ]; then' \
    '    [ "$?" ] && echo "the status was recorded"' \
    '    echo "R2B RED confirmed: the mutant produced a different value"' \
    'fi'

# [codex-2] ... and neither does `[ -n "$?" ]`, for the same reason.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp bracket-status-n.sh \
    '#!/usr/bin/env bash' \
    'if [ "$got" != "$want" ]; then' \
    '    [ -n "$?" ] && echo "the status was recorded"' \
    '    echo "R2E RED confirmed: the mutant produced a different value"' \
    'fi'

# [codex-2] the shapes that ARE real exit-status comparisons and must keep their
# exemption -- the negative controls guarding against over-correction.
#
# CR round 3 [codex-2] REPOSITIONED both of these. They used to put the `$?`
# comparison inside the then-branch, where `$?` is the CONDITIONAL's status --
# 0 precisely because the branch was taken -- so they were asserting that a
# shape proving nothing deserved an exemption. Moved onto the conditional line,
# where `$?` still refers to the command that ran before the `if`, they are
# genuine mutant-status checks again. Deleting them would have removed the guard
# entirely; repositioning keeps it.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp status-cmp-eq.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ $? -eq 0 ] && [ "$got" != "$want" ]; then' \
    '    echo "R2C RED confirmed: the mutant ran and produced a different value"' \
    'fi'
# The `!=` spelling is the one that actually exercises the j == c rule: `-eq`
# and friends already disqualify the conditional as "not an inequality-only
# test", so this is the shape where crediting `$?` on the conditional line is
# what keeps the control unflagged.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp status-cmp-ne.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ "$?" != 0 ] || [ "$got" != "$want" ]; then' \
    '    echo "R2D RED confirmed: the mutant crashed or produced a different value"' \
    'fi'

# [codex-2, round 3] the same comparison INSIDE the block: it observes the
# conditional's own status, never the mutant's, and must not exempt anything.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp status-in-block.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ "$got" != "$want" ]; then' \
    '    [ "$?" -eq 0 ] && echo "status looked fine"' \
    '    echo "R3 RED confirmed: the mutant produced a different value"' \
    'fi'

# --- CR round 4 probes ------------------------------------------------------
# [codex-1] the rc-variable rule used to ask only that an rc-ish variable AND a
# comparison token appear on the SAME LINE. A human-readable diagnostic
# satisfies both halves -- the `!=` in the message text bought the exemption --
# so a control that never compares its mutant's status was credited by its own
# error string. Same shape as the round-1 bare-`$?` diagnostic hole, one rule
# over.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp diagnostic-message.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'rc=7' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "R4 RED confirmed: got != want (rc=$rc)"' \
    'fi'

# --- CR round 5 probes ------------------------------------------------------
# [codex-1] round 4's adjacency requirement is satisfied by quoted diagnostic
# TEXT, so the same defect came back in a third spelling. Fixed as a CLASS --
# an echo/printf line never establishes exit-status evidence -- rather than by
# tightening the regex against this wording, which would only invite a fourth.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp quoted-adjacent-message.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'rc=7' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ "$got" != "$want" ]; then' \
    '    echo "expected $rc != 0"' \
    '    echo "R5 RED confirmed: the mutant produced a different value"' \
    'fi'

# ... and the message still establishes nothing when a REAL test precedes it,
# if that test is not an exit-status comparison.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp test-then-echo-message.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'rc=7' \
    'note="something"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'if [ "$got" != "$want" ]; then' \
    '    [ -n "$note" ] && echo "expected $rc != 0"' \
    '    echo "R5B RED confirmed: the mutant produced a different value"' \
    'fi'

# NEGATIVE CONTROL for the same rule: when the segment before the `&&` IS a real
# exit-status test, the evidence is that test and the trailing echo is
# irrelevant. Dropping echo segments must not drop this.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp echo-after-real-test.sh \
    '#!/usr/bin/env bash' \
    'want="correct"' \
    'got="$(bash "$mutant" 2>/dev/null)"' \
    'mutant_rc=$?' \
    'if [ "$got" != "$want" ]; then' \
    '    [ "$mutant_rc" -eq 0 ] && echo "the mutant ran, rc $mutant_rc"' \
    '    echo "R5C RED confirmed: the mutant produced a different value"' \
    'fi'

# [codex-3] a file with TWO genuine smells, used to prove that a failed scan
# does not read as a clean one.
# shellcheck disable=SC2016  # fixture source text, not an expression.
mkp two-smells.sh \
    '#!/usr/bin/env bash' \
    'if [ "$a" != "$b" ]; then' \
    '    echo "S1 RED confirmed: first vacuous control"' \
    'fi' \
    'if [ ! -e "$cap" ]; then' \
    '    echo "S2 RED confirmed: second vacuous control"' \
    'fi'

# --- harness ----------------------------------------------------------------
lint_out=""
lint_rc=0
run_lint() {
    lint_out="$(bash "$LINT" "$@" 2>/dev/null)"
    lint_rc=$?
}
nhits() {
    if [ -z "$lint_out" ]; then echo 0; else printf '%s\n' "$lint_out" | wc -l | tr -d ' '; fi
}
# seed_line -- the line the lint OUGHT to name, read out of the fixture itself
# rather than hardcoded, so an edit to a fixture cannot silently detune a case.
seed_line() { grep -n 'RED confirmed' "$1" | head -1 | cut -d: -f1; }

echo "[test-red-control-lint] T1 a compliant control (red_control_run/assert) is not flagged"
run_lint "$fx/compliant.sh"
eq  "T1a zero hits" "$(nhits)" "0"
eq  "T1b exit status 0" "$lint_rc" "0"

echo "[test-red-control-lint] T2 the inequality-only shape is flagged, on the right line"
run_lint "$fx/smelly-inequality.sh"
eq  "T2a exactly one hit" "$(nhits)" "1"
eq  "T2b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$fx/smelly-inequality.sh:$(seed_line "$fx/smelly-inequality.sh")"
has "T2c the reason names the missing half" "$lint_out" "never compares the mutant's exit status"
has "T2d the reason names which half was asserted" "$lint_out" "only an inequality"
eq  "T2e exit status 0 even with a hit" "$lint_rc" "0"

echo "[test-red-control-lint] T3 the bare file-existence shape is flagged, on the right line"
run_lint "$fx/smelly-existence.sh"
eq  "T3a exactly one hit" "$(nhits)" "1"
eq  "T3b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$fx/smelly-existence.sh:$(seed_line "$fx/smelly-existence.sh")"
has "T3c the reason names the existence test" "$lint_out" "only a bare file-existence test"
eq  "T3d exit status 0 even with a hit" "$lint_rc" "0"

echo "[test-red-control-lint] T4 FALSE-POSITIVE CONTROL: rc compared in the test - not flagged"
run_lint "$fx/near-miss-rc-in-test.sh"
eq  "T4a zero hits" "$(nhits)" "0"
eq  "T4b exit status 0" "$lint_rc" "0"

echo "[test-red-control-lint] T5 rc compared elsewhere in the same block - not flagged"
run_lint "$fx/near-miss-rc-in-block.sh"
eq  "T5a zero hits" "$(nhits)" "0"

echo "[test-red-control-lint] T6 a comment mentioning the phrase is not a control"
run_lint "$fx/comment-only.sh"
eq  "T6a zero hits" "$(nhits)" "0"

echo "[test-red-control-lint] T7 the contract helper own file is never flagged"
run_lint "$fx/lib/red-control.sh"
eq  "T7a zero hits" "$(nhits)" "0"

echo "[test-red-control-lint] T8 a whole directory: exactly the two smelly fixtures"
run_lint "$fx"
eq  "T8a two hits across the fixture tree" "$(nhits)" "2"
eq  "T8b exit status 0" "$lint_rc" "0"
has "T8c the inequality fixture is among them" "$lint_out" "smelly-inequality.sh:"
has "T8d the existence fixture is among them" "$lint_out" "smelly-existence.sh:"

echo "[test-red-control-lint] T9 the real scripts/ tree is scanned and REPORTED, never gated"
# Run with NO arguments and from a foreign cwd, which also pins that the default
# scan root is resolved from the script own location, never from the caller PWD.
#
# CR round 1 [codex-3]: this case must NOT fail on hits. run-shell-tests.sh keys
# on a suite's exit status, so failing here would quietly make an advisory tool
# a gate -- and a heuristic text matcher false-positiving on some future file
# would then turn the whole shell suite red on unrelated work. The lint's own
# contract ("advisory only -- a report, never a gate") wins over the
# convenience of a CI-enforced invariant. Hits are printed for the reader of the
# suite log and reviewed by a human; the deterministic count assertion that
# SHOULD fail on a regression is T8's, over the fixture tree.
#
# CR round 4 [codex-2]: and it must not read EMPTY STDOUT as proof. The lint is
# deliberately silent on stdout and exits 0 when every scan FAILS, so a broken
# awk or a failed enumeration produces byte-identical output to a clean tree.
# Reporting "the invariant holds" from that is absence-of-evidence scored as
# evidence -- the same class the sibling PR-A fixes as its Finding A, here
# inside the suite of the very tool built to detect it. Stderr is captured and
# classified instead.

# t9_classify STDOUT STDERR -- the three-way verdict, factored out so the T19
# regression drives THIS logic rather than a copy of it.
#   inconclusive -- the scan itself failed; this run proves nothing either way
#   hits         -- advisory findings to read (never a suite failure)
#   clean        -- a clean-scan summary AND no hits: the only verdict allowed
#                   to claim the invariant
#   unproven     -- empty stdout with no summary at all: still not "clean"
t9_classify() {
    case "$2" in
        *"FAILED to scan"*|*"FAILED to enumerate"*|*"the result is incomplete"*)
            echo "inconclusive"; return ;;
    esac
    if [ -n "$1" ]; then echo "hits"; return; fi
    case "$2" in
        *"0 suspect controls in"*) echo "clean"; return ;;
    esac
    echo "unproven"
}

t9_out="$(cd "$tmpdir" && bash "$LINT" 2>"$tmpdir/t9.err")"
t9_rc=$?
t9_err="$(cat "$tmpdir/t9.err")"
t9_state="$(t9_classify "$t9_out" "$t9_err")"
case "$t9_state" in
    clean)
        ok "T9a the empty-on-main invariant HOLDS - a clean-scan summary and zero hits" ;;
    hits)
        ok "T9a the real scripts/ tree was scanned; the hits below are ADVISORY, not a failure"
        echo "  --- red-control-lint advisory hits on the real scripts/ tree (review these) ---"
        printf '%s\n' "$t9_out" | sed 's/^/  /'
        echo "  --- end advisory hits; they do not fail this suite by design ---" ;;
    inconclusive)
        ok "T9a INCONCLUSIVE - the scan itself failed, so this run proves NOTHING about the invariant"
        printf '%s\n' "$t9_err" | sed 's/^/  /' ;;
    *)
        ok "T9a INCONCLUSIVE - empty stdout with no scan summary at all; absence is not evidence"
        printf '%s\n' "$t9_err" | sed 's/^/  /' ;;
esac
eq  "T9b exit status 0" "$t9_rc" "0"

echo "[test-red-control-lint] T10 --help prints usage and exits 0"
run_lint --help
eq  "T10a exit status 0" "$lint_rc" "0"
has "T10b prints the usage line" "$lint_out" "Usage: bash scripts/lib/red-control-lint.sh"

echo "[test-red-control-lint] T11 [codex-1] a completed compliant control above does not suppress a vacuous one"
run_lint "$probes/two-controls.sh"
eq  "T11a exactly one hit" "$(nhits)" "1"
eq  "T11b the hit names the second control's RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/two-controls.sh:$(seed_line "$probes/two-controls.sh")"

echo "[test-red-control-lint] T12 [codex-1] a comment naming the helper does not suppress a vacuous control"
run_lint "$probes/comment-mention.sh"
eq  "T12a exactly one hit" "$(nhits)" "1"
eq  "T12b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/comment-mention.sh:$(seed_line "$probes/comment-mention.sh")"

echo "[test-red-control-lint] T13 [codex-2] a bare \$? in a diagnostic echo is not an exit-status comparison"
run_lint "$probes/bare-status.sh"
eq  "T13a exactly one hit" "$(nhits)" "1"
eq  "T13b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/bare-status.sh:$(seed_line "$probes/bare-status.sh")"

echo "[test-red-control-lint] T14 [codex-2] an rc=\$? capture BEFORE the if is still flagged (never compared)"
run_lint "$probes/rc-capture-before-if.sh"
eq  "T14a exactly one hit" "$(nhits)" "1"
eq  "T14b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/rc-capture-before-if.sh:$(seed_line "$probes/rc-capture-before-if.sh")"
eq  "T14c exit status 0" "$lint_rc" "0"

echo "[test-red-control-lint] T15 [codex-1] the ENCLOSING conditional is found across a closed inner block"
run_lint "$probes/nested-inner-if.sh"
eq  "T15a exactly one hit" "$(nhits)" "1"
eq  "T15b the hit names the RED-confirmed line, not the inner guard" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/nested-inner-if.sh:$(seed_line "$probes/nested-inner-if.sh")"
run_lint "$probes/one-liner.sh"
eq  "T15c a one-line if/then/fi control is still matched" "$(nhits)" "1"
run_lint "$probes/closed-then-seed.sh"
eq  "T15d a seed after a CLOSED one-liner is in no conditional - not flagged" "$(nhits)" "0"

echo "[test-red-control-lint] T16 [codex-2] a non-comparing \$? test buys no exemption"
run_lint "$probes/bracket-status.sh"
eq  "T16a [ \"\$?\" ] does not exempt the control" "$(nhits)" "1"
eq  "T16b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/bracket-status.sh:$(seed_line "$probes/bracket-status.sh")"
run_lint "$probes/bracket-status-n.sh"
eq  "T16c [ -n \"\$?\" ] does not exempt the control either" "$(nhits)" "1"
run_lint "$probes/status-cmp-eq.sh"
eq  "T16d NEGATIVE CONTROL: a status comparison ON the conditional line leaves it unflagged" \
    "$(nhits)" "0"
run_lint "$probes/status-cmp-ne.sh"
eq  "T16e NEGATIVE CONTROL: [ \"\$?\" != 0 ] on the conditional line still exempts it" \
    "$(nhits)" "0"
run_lint "$probes/status-in-block.sh"
eq  "T16f [codex-2 r3] the SAME comparison inside the block exempts nothing" "$(nhits)" "1"
eq  "T16g the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/status-in-block.sh:$(seed_line "$probes/status-in-block.sh")"

echo "[test-red-control-lint] T17 [codex-3] a FAILED scan is reported, never read as a clean one"
# The vacuous green inside the vacuous-green detector: awk's exit status and
# stderr used to be discarded, so a broken awk produced a summary byte-identical
# to a genuinely clean scan. Driven exactly as the panel probe drove it -- a
# failing awk stub first on PATH, against a file with two real smells.
stubbin="$tmpdir/stubbin"
mkdir -p "$stubbin"
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "awk: simulated failure (fatal): cannot open source file" >&2' \
    'exit 2' > "$stubbin/awk"
chmod 755 "$stubbin/awk"
run_lint "$probes/two-smells.sh"
eq  "T17a with a working awk the file yields its two hits" "$(nhits)" "2"
stub_out="$(PATH="$stubbin:$PATH" bash "$LINT" "$probes/two-smells.sh" 2>"$tmpdir/stub.err")"
stub_rc=$?
stub_err="$(cat "$tmpdir/stub.err")"
eq  "T17b the exit status is STILL 0 - the contract is unchanged" "$stub_rc" "0"
eq  "T17c no hits are claimed from the failed scan" \
    "$(if [ -z "$stub_out" ]; then echo 0; else printf '%s\n' "$stub_out" | wc -l | tr -d ' '; fi)" "0"
has "T17d stderr names the file that failed to scan" "$stub_err" "FAILED to scan"
has "T17e stderr carries awk's own error" "$stub_err" "simulated failure"
has "T17f the summary says the result is incomplete" "$stub_err" "the result is incomplete"
# The load-bearing one: the failed run must NOT be able to print the clean-scan
# summary. Before the fix the two runs were byte-identical on stderr.
case "$stub_err" in
    *"0 suspect controls in"*)
        bad "T17g a failed scan still printed the clean-scan summary line: $stub_err" ;;
    *)  ok "T17g a failed scan cannot print the clean-scan summary line" ;;
esac

echo "[test-red-control-lint] T18 [codex-1] a FAILED enumeration is reported, never read as a clean scan"
# Round 2's awk hole one layer up: find's exit status used to be discarded, so a
# traversal failure produced a clean-looking scan over a PARTIAL file list.
# Driven with a find stub on PATH exactly as T17 drives the awk stub -- and the
# stub emits ONE real path before failing, so the run has genuine hits AND a
# reported failure at the same time, which is the shape that actually occurs.
stubfind="$tmpdir/stubfind"
mkdir -p "$stubfind"
# shellcheck disable=SC2016  # stub SOURCE TEXT -- $STUB_FIND_EMIT is read by
# the stub when it runs, not by this shell when it writes it.
printf '%s\n' '#!/usr/bin/env bash' \
    '[ -n "${STUB_FIND_EMIT:-}" ] && echo "$STUB_FIND_EMIT"' \
    'echo "find: simulated traversal failure: Permission denied" >&2' \
    'exit 1' > "$stubfind/find"
chmod 755 "$stubfind/find"
fstub_out="$(STUB_FIND_EMIT="$probes/two-smells.sh" PATH="$stubfind:$PATH" bash "$LINT" "$probes" 2>"$tmpdir/fstub.err")"
fstub_rc=$?
fstub_err="$(cat "$tmpdir/fstub.err")"
eq  "T18a the exit status is STILL 0 - the contract is unchanged" "$fstub_rc" "0"
eq  "T18b the partial list is still scanned, so its two hits are reported" \
    "$(if [ -z "$fstub_out" ]; then echo 0; else printf '%s\n' "$fstub_out" | wc -l | tr -d ' '; fi)" "2"
has "T18c stderr names the root that failed to enumerate" "$fstub_err" "FAILED to enumerate"
has "T18d stderr carries find's own error" "$fstub_err" "simulated traversal failure"
has "T18e stderr says the file list is PARTIAL" "$fstub_err" "the file list is PARTIAL"
has "T18f the summary says the result is incomplete" "$fstub_err" "the result is incomplete"
case "$fstub_err" in
    *"0 suspect controls in"*)
        bad "T18g a failed enumeration still printed the clean-scan summary line: $fstub_err" ;;
    *)  ok "T18g a failed enumeration cannot print the clean-scan summary line" ;;
esac

echo "[test-red-control-lint] T19 [codex-1 r4] a diagnostic MESSAGE is not a status comparison"
run_lint "$probes/diagnostic-message.sh"
eq  "T19a exactly one hit" "$(nhits)" "1"
eq  "T19b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/diagnostic-message.sh:$(seed_line "$probes/diagnostic-message.sh")"

echo "[test-red-control-lint] T20 [codex-2 r4] T9's own logic calls a FAILED scan inconclusive, never clean"
# The same failing-awk stub T17 uses, driven through the SAME default-root
# invocation T9 makes -- so this exercises T9's classifier, not a copy of it.
t20_out="$(cd "$tmpdir" && PATH="$stubbin:$PATH" bash "$LINT" 2>"$tmpdir/t20.err")"
t20_rc=$?
t20_err="$(cat "$tmpdir/t20.err")"
eq  "T20a stdout is empty, byte-identical to a genuinely clean tree" \
    "$(if [ -z "$t20_out" ]; then echo 0; else printf '%s\n' "$t20_out" | wc -l | tr -d ' '; fi)" "0"
eq  "T20b the exit status is 0, also identical to a clean tree" "$t20_rc" "0"
eq  "T20c yet the classifier calls it INCONCLUSIVE, not clean" \
    "$(t9_classify "$t20_out" "$t20_err")" "inconclusive"
# Deterministic unit checks on the classifier itself -- no dependence on what
# the real tree happens to contain, so these can never gate on the environment.
eq  "T20d a clean-scan summary with no hits is the only input classed clean" \
    "$(t9_classify "" "red-control-lint: 0 suspect controls in 916 files scanned")" "clean"
eq  "T20e empty stdout with NO summary is unproven, never clean" \
    "$(t9_classify "" "")" "unproven"
eq  "T20f a failure report outranks everything else on stderr" \
    "$(t9_classify "" "red-control-lint: FAILED to enumerate /x (find exited 1) - the file list is PARTIAL")" \
    "inconclusive"

echo "[test-red-control-lint] T21 [codex-1 r5] an echo/printf line never establishes exit-status evidence"
run_lint "$probes/quoted-adjacent-message.sh"
eq  "T21a a comparison inside a diagnostic message does not exempt the control" "$(nhits)" "1"
eq  "T21b the hit names the RED-confirmed line" \
    "$(printf '%s' "$lint_out" | cut -d' ' -f1)" \
    "$probes/quoted-adjacent-message.sh:$(seed_line "$probes/quoted-adjacent-message.sh")"
run_lint "$probes/test-then-echo-message.sh"
eq  "T21c a real test that is NOT an rc comparison, plus a message, is still flagged" "$(nhits)" "1"
run_lint "$probes/echo-after-real-test.sh"
eq  "T21d NEGATIVE CONTROL: a real rc test followed by && echo IS still evidence" "$(nhits)" "0"

echo "[test-red-control-lint] T22 [codex-2 r5] an invalid scan root is a FAILED scan, not a clean one"
badroot_out="$(bash "$LINT" "$tmpdir/no-such-root" 2>"$tmpdir/badroot.err")"
badroot_rc=$?
badroot_err="$(cat "$tmpdir/badroot.err")"
eq  "T22a the exit status is still 0" "$badroot_rc" "0"
eq  "T22b stdout is empty, byte-identical to a clean scan" \
    "$(if [ -z "$badroot_out" ]; then echo 0; else printf '%s\n' "$badroot_out" | wc -l | tr -d ' '; fi)" "0"
has "T22c stderr names the root that could not be scanned" "$badroot_err" "FAILED to scan"
has "T22d the summary says the result is incomplete" "$badroot_err" "the result is incomplete"
case "$badroot_err" in
    *"0 suspect controls in"*)
        bad "T22e an invalid root still printed the clean-scan summary line: $badroot_err" ;;
    *)  ok "T22e an invalid root cannot print the clean-scan summary line" ;;
esac
eq  "T22f T9's own classifier calls it inconclusive, not clean" \
    "$(t9_classify "$badroot_out" "$badroot_err")" "inconclusive"

echo
echo "[test-red-control-lint] $pass passed, $fails failed"
[ "$fails" -eq 0 ] || exit 1
