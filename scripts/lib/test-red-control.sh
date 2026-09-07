#!/usr/bin/env bash
# scripts/lib/test-red-control.sh -- unit tests for the RED-control contract
# helper (HIMMEL-2518).
#
# The helper's whole job is to REFUSE evidence that a control is entitled to
# treat as proof, so the cases that matter are the negative ones: one per
# contract failure mode (crashed / empty / wrong-mutation / genuinely-not-red,
# plus the caller-error `broken` mode), each driven by a purpose-built mutant
# that reproduces exactly that mode. A positive control proves a genuine mutant
# still passes -- without it a helper that failed everything would score 100%.
#
# T14 below is the load-bearing one: it runs the SAME five broken mutants
# through the naive `[ "$observed" != "$correct" ]` shape this helper replaces,
# and pins that FOUR of the five are ACCEPTED by it -- every one whose value is
# empty or merely different. That is the defect class HIMMEL-2518 exists for,
# asserted rather than asserted-about.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure shell over a scratch dir; NOT ported to native PowerShell -- a test
# harness needs no .ps1 twin (project convention: a documented platform guard
# suffices for a test fixture), and the library under test is itself
# gitbash-only for the same reason. This is the T15 marker
# scripts/parity/test-ws5-invariants.sh looks for.
#
# Usage: bash scripts/lib/test-red-control.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pass=0
fails=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fails=$((fails+1)); echo "  FAIL: $1"; }
eq()  {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 - got '$2' want '$3'"; fi
}
# has -- the message must NAME its mode. Point 4 of the contract is a promise
# to the next reader, so it is asserted like any other behaviour.
has() {
    case "$2" in
        *"$3"*) ok "$1" ;;
        *)      bad "$1 - message did not mention '$3': $2" ;;
    esac
}

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/red-control-test.XXXXXX")" || {
    echo "FATAL: could not create scratch dir" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

# Keep the library's stderr captures inside this suite's own scratch dir, so
# the EXIT trap above cleans them and nothing lands in /tmp. This is the
# documented RED_CONTROL_TMPDIR contract, exercised by using it.
RED_CONTROL_TMPDIR="$tmpdir"
export RED_CONTROL_TMPDIR

# shellcheck source=scripts/lib/red-control.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/red-control.sh"

# --- fixtures ---------------------------------------------------------------
# A "script under test" that prints value=correct, and five mutants of it, one
# per outcome a real mutation can have. Nothing here touches a real path: these
# are the mktemp scratch copies HIMMEL-2503 requires.
mut="$tmpdir/mutants"
mkdir -p "$mut"
mk() { printf '%s\n' '#!/usr/bin/env bash' "$2" > "$mut/$1"; }
mk real.sh    'printf "value=%s\n" "correct"'
mk good.sh    'printf "value=%s\n" "wrong"'
mk other.sh   'printf "value=%s\n" "elsewise"'
mk inert.sh   'printf "value=%s\n" "correct"'
mk silent.sh  'exit 0'
mk noise.sh   'printf "unrelated=%s\n" "noise"'
# shellcheck disable=SC2016  # these two are fixture SOURCE TEXT written into
# a scratch script, not expressions for this shell to expand -- expanding them
# here is exactly the bug the single quotes prevent.
mk env.sh     'printf "value=%s\n" "${PROBE:-unset}"'
# shellcheck disable=SC2016  # ditto -- fixture source text, not an expression.
mk cwd.sh     'printf "value=%s\n" "$(basename "$PWD")"'
printf '%s\n' '#!/usr/bin/env bash' \
    'echo "boom: anchor not found" >&2' 'exit 2'                 > "$mut/crash.sh"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "value=%s\n" "wrong"' 'exit 3'                      > "$mut/wrong_rc3.sh"

val() { printf '%s\n' "${1-}" | sed -n 's/^value=//p'; }

# run_case <mutant> -- run a mutant and leave the assert to the caller. Every
# case goes through red_control_run, which is the only way an exit status is
# recorded, so no case can accidentally skip contract point (a).
run_case() { red_control_run -- bash "$mut/$1"; }

# assert_msg -- call red_control_assert IN THIS SHELL (not a command
# substitution) and capture its output to a file. A subshell would inherit the
# sourced functions but discard the RED_CONTROL_RAN consumption the helper
# performs, and T8 below depends on that consumption being real.
msgfile="$tmpdir/assert.out"
assert_msg() {
    red_control_assert "$@" >"$msgfile" 2>&1
    arc=$?
    amsg="$(cat "$msgfile")"
    return 0
}

echo "[test-red-control] T1 positive control: a genuine mutant passes"
run_case good.sh
assert_msg --label "T1" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct" --note "the mutation flipped the value"
eq  "T1 a genuine mutant returns PASS" "$arc" "$RED_CONTROL_RC_PASS"
has "T1 prints the RED-confirmed line" "$amsg" "RED confirmed"
has "T1 names the observed wrong value" "$amsg" "wrong"

echo "[test-red-control] T2 crashed: a mutant that dies before the mutated line"
run_case crash.sh
eq  "T2 red_control_run recorded the mutant's exit status" "$RED_CONTROL_RC" "2"
assert_msg --label "T2" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T2 returns the crashed status" "$arc" "$RED_CONTROL_RC_CRASHED"
has "T2 names the crashed mode" "$amsg" "crashed"
has "T2 reports the mutant's actual exit status" "$amsg" "exited 2"
has "T2 surfaces the mutant's stderr" "$amsg" "anchor not found"

echo "[test-red-control] T3 empty: a mutant that exits 0 producing nothing"
run_case silent.sh
assert_msg --label "T3" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T3 returns the empty status" "$arc" "$RED_CONTROL_RC_EMPTY"
has "T3 names the empty mode" "$amsg" "empty"

echo "[test-red-control] T4 empty: output present, but the extraction yields ''"
run_case noise.sh
assert_msg --label "T4" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T4 returns the empty status" "$arc" "$RED_CONTROL_RC_EMPTY"
has "T4 blames the extraction, not the mutation" "$amsg" "extracted from it is empty"

echo "[test-red-control] T5 wrong-mutation: a value that is neither predicted nor correct"
run_case other.sh
assert_msg --label "T5" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T5 returns the wrong-mutation status" "$arc" "$RED_CONTROL_RC_WRONG_MUTATION"
has "T5 names the wrong-mutation mode" "$amsg" "wrong-mutation"
has "T5 reports what it saw instead" "$amsg" "elsewise"

echo "[test-red-control] T6 genuinely-not-red: the mutant reproduces the correct value"
run_case inert.sh
assert_msg --label "T6" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T6 returns the not-red status" "$arc" "$RED_CONTROL_RC_NOT_RED"
has "T6 names the genuinely-not-red mode" "$amsg" "genuinely-not-red"
has "T6 says the protected assertion is vacuous" "$amsg" "vacuous"

echo "[test-red-control] T7 broken: assert with no preceding run"
RED_CONTROL_RAN=0
assert_msg --label "T7" --observed "wrong" --expect-wrong "wrong" --correct "correct"
eq  "T7 returns the broken status" "$arc" "$RED_CONTROL_RC_BROKEN"
has "T7 names the broken mode" "$amsg" "broken"
has "T7 says nothing ran" "$amsg" "without a preceding red_control_run"

echo "[test-red-control] T8 broken: a second assert re-reading a consumed run"
run_case good.sh
assert_msg --label "T8a" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T8a the first assert passes" "$arc" "$RED_CONTROL_RC_PASS"
assert_msg --label "T8b" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T8b the second assert is broken, not a silent re-pass" "$arc" "$RED_CONTROL_RC_BROKEN"

echo "[test-red-control] T9 broken: caller-side misuse is refused, not guessed at"
run_case good.sh
assert_msg --label "T9a" --observed "wrong" --expect-wrong ""
eq  "T9a an empty --expect-wrong is refused" "$arc" "$RED_CONTROL_RC_BROKEN"
has "T9a explains why the empty string cannot be the predicted value" "$amsg" "crashed mutant produces"
run_case good.sh
assert_msg --label "T9b" --observed "wrong" --expect-wrong "same" --correct "same"
eq  "T9b --correct identical to --expect-wrong is refused" "$arc" "$RED_CONTROL_RC_BROKEN"
run_case good.sh
assert_msg --label "T9c" --expect-wrong "wrong" --correct "correct"
eq  "T9c a missing --observed is refused" "$arc" "$RED_CONTROL_RC_BROKEN"
run_case good.sh
assert_msg --label "T9d" --observed "wrong" --nonsense "x"
eq  "T9d an unknown option is refused" "$arc" "$RED_CONTROL_RC_BROKEN"

echo "[test-red-control] T10 --expect-rc: a mutant whose fixture legitimately exits nonzero"
run_case wrong_rc3.sh
assert_msg --label "T10a" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T10a rc 3 is crashed when 0 was expected" "$arc" "$RED_CONTROL_RC_CRASHED"
run_case wrong_rc3.sh
assert_msg --label "T10b" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct" --expect-rc 3
eq  "T10b rc 3 passes when the fixture declares it" "$arc" "$RED_CONTROL_RC_PASS"

echo "[test-red-control] T11 --correct is optional (weaker, but still a contract)"
run_case inert.sh
assert_msg --label "T11" --observed "$(val "$RED_CONTROL_OUT")" --expect-wrong "wrong"
eq  "T11 without --correct an inert mutant is wrong-mutation, never a pass" \
    "$arc" "$RED_CONTROL_RC_WRONG_MUTATION"

echo "[test-red-control] T12 red_control_run honours --cwd and --env"
mkdir -p "$tmpdir/probe-dir"
pwd_before="$PWD"
red_control_run --cwd "$tmpdir/probe-dir" -- bash "$mut/cwd.sh"
eq  "T12a --cwd runs the mutant in the named directory" "$(val "$RED_CONTROL_OUT")" "probe-dir"
eq  "T12b --cwd did not move the suite's own cwd" "$PWD" "$pwd_before"
red_control_run --env PROBE=seen -- bash "$mut/env.sh"
eq  "T12c --env reaches the mutant" "$(val "$RED_CONTROL_OUT")" "seen"
red_control_run -- bash "$mut/env.sh"
eq  "T12d without --env the variable is not leaked in" "$(val "$RED_CONTROL_OUT")" "unset"

echo "[test-red-control] T13 red_control_run refuses its own misuse"
red_control_run --cwd "$tmpdir" 2>/dev/null
eq  "T13a a run with no command is refused" "$?" "$RED_CONTROL_RC_BROKEN"
red_control_run --bogus x -- true 2>/dev/null
eq  "T13b an unknown run option is refused" "$?" "$RED_CONTROL_RC_BROKEN"

echo "[test-red-control] T14 the naive '!=' shape accepts 4 of the 5 broken mutants"
# The defect class itself, pinned. `naive` is the control shape this library
# replaces: it compares the observed value against the CORRECT one and calls
# any difference red. Run the same fixtures through both and count.
naive() { [ "${1-}" != "correct" ]; }
naive_accepted=0
contract_accepted=0
for m in crash.sh silent.sh noise.sh other.sh inert.sh; do
    run_case "$m"
    naive "$(val "$RED_CONTROL_OUT")" && naive_accepted=$((naive_accepted+1))
    assert_msg --label "T14/$m" --observed "$(val "$RED_CONTROL_OUT")" \
        --expect-wrong "wrong" --correct "correct"
    [ "$arc" -eq "$RED_CONTROL_RC_PASS" ] && contract_accepted=$((contract_accepted+1))
done
eq  "T14a the naive shape accepts every broken mutant except the inert one" \
    "$naive_accepted" "4"
eq  "T14b the contract accepts none of them" "$contract_accepted" "0"

echo "[test-red-control] T15 a run that FAILS SETUP invalidates the previous run"
# CR round 1 [codex-1]: red_control_run used to leave RED_CONTROL_RAN=1 from an
# earlier run when it returned early, so a caller that does not check its exit
# status would assert against the PREVIOUS mutant's stdout and pass on stale
# evidence -- the exact class this library refuses. T29 in
# scripts/cr/test-pr-check-context.sh makes it reachable: it deliberately
# leaves its first run unconsumed.
run_case good.sh
red_control_run --stderr "$tmpdir/no-such-dir/stderr" -- bash "$mut/good.sh" 2>/dev/null
eq  "T15a a run whose stderr capture cannot be written returns broken" \
    "$?" "$RED_CONTROL_RC_BROKEN"
assert_msg --label "T15b" --observed "wrong" --expect-wrong "wrong" --correct "correct"
eq  "T15b the failed setup invalidated the earlier run, so the assert is broken" \
    "$arc" "$RED_CONTROL_RC_BROKEN"

echo "[test-red-control] T16 a value-taking option with no value RETURNS, never hangs"
# CR round 1 [codex-2]: `shift 2` with one argument left FAILS and leaves "$@"
# untouched, so the `while [ $# -gt 0 ]` loop spins on the same token forever.
# Bounded with `timeout` on purpose: a regression here hangs the suite, and an
# unbounded assertion could not distinguish "returned broken" from "still
# running". rc 124 is timeout's own kill signal. The library is sourced INSIDE
# the timed shell -- a bare `bash -c` inherits no functions.
# shellcheck disable=SC2016  # \$1 is the INNER shell's positional, passed after the script name -- expanding it here is the bug.
timeout 5 bash -c '. "$1"; red_control_run --cwd' _ "$SCRIPT_DIR/red-control.sh" >/dev/null 2>&1
eq  "T16a red_control_run --cwd with no value returns broken (124 would mean it hung)" \
    "$?" "$RED_CONTROL_RC_BROKEN"
# shellcheck disable=SC2016  # ditto -- inner positional, not ours.
timeout 5 bash -c '. "$1"; red_control_assert --label' _ "$SCRIPT_DIR/red-control.sh" >/dev/null 2>&1
eq  "T16b red_control_assert --label with no value returns broken" \
    "$?" "$RED_CONTROL_RC_BROKEN"

echo "[test-red-control] T17 even the unknown-option path consumes the run"
# CR round 1 [codex-3]: the unknown-option arm returned BEFORE the run was
# consumed, so a caller error could hand its run to the NEXT assert -- which
# contradicted this library's own documented "consume on every path" claim.
run_case good.sh
assert_msg --label "T17a" --observed "wrong" --nonsense "x"
eq  "T17a the unknown option is refused" "$arc" "$RED_CONTROL_RC_BROKEN"
assert_msg --label "T17b" --observed "$(val "$RED_CONTROL_OUT")" \
    --expect-wrong "wrong" --correct "correct"
eq  "T17b the refused call still consumed the run, so the next assert is broken" \
    "$arc" "$RED_CONTROL_RC_BROKEN"

echo
echo "[test-red-control] $pass passed, $fails failed"
[ "$fails" -eq 0 ] || exit 1
