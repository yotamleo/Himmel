#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture files are built with single-quoted
# printf on purpose -- every `$var`/`$(...)` below is literal text the
# fixture must contain, never an expansion in THIS shell.
# scripts/lib/test-unchecked-mktemp.sh -- suite for the unchecked_mktemp_scan
# predicate (scripts/lib/unchecked-mktemp.sh) and its gate
# (scripts/hooks/check-unchecked-mktemp.sh), HIMMEL-2709.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# The predicate's contract is deliberately simple -- see
# scripts/lib/unchecked-mktemp.sh's header for the full rule list and why it
# does not classify guard QUALITY. T21 below is the regression lock for the
# specific failure that simplification fixed: the predicate must never flag
# its own gate or suite file (a `|| {` multiline block used to false-positive
# there, HIMMEL-2709 codex-1).
#
# Three sections: (1) direct predicate cases, positive and negative, against
# scratch files; (2) the gate exercised end-to-end against a throwaway
# fixture git repo, one case per documented behaviour; (3) one RED control
# (scripts/lib/red-control.sh) proving the staged-vs-working-tree distinction
# in the gate is actually exercised, not just asserted.
#
# Usage: bash scripts/lib/test-unchecked-mktemp.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$LIB_DIR/../hooks" && pwd)"
GATE="$HOOKS_DIR/check-unchecked-mktemp.sh"

# shellcheck source=scripts/lib/unchecked-mktemp.sh
# shellcheck disable=SC1091
. "$LIB_DIR/unchecked-mktemp.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$LIB_DIR/fixture-tempdir.sh"
# shellcheck source=scripts/lib/red-control.sh
# shellcheck disable=SC1091
. "$LIB_DIR/red-control.sh"

TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-unchecked-mktemp.XXXXXX")" || {
    echo "FAIL: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$TMPDIR_ROOT"' EXIT
# shellcheck disable=SC2034  # read by the sourced red-control.sh; the repo's
# shell-lint runs shellcheck WITHOUT -x, so it cannot follow the source above.
RED_CONTROL_TMPDIR="$TMPDIR_ROOT"

_pass=0
_fail=0

assert_rc() {
    local test_name="$1" expected_rc="$2" actual_rc="$3"
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        echo "PASS: $test_name (rc=$actual_rc)"
        _pass=$((_pass + 1))
    else
        echo "FAIL: $test_name -- expected rc=$expected_rc got rc=$actual_rc"
        _fail=$((_fail + 1))
    fi
}

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS: $test_name"
        _pass=$((_pass + 1))
    else
        echo "FAIL: $test_name -- expected [$expected] got [$actual]"
        _fail=$((_fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# Section 1: unchecked_mktemp_scan direct cases.
# ---------------------------------------------------------------------------

# T0 -- the predicate library passes `bash -n`. Its awk program is one
# single-quoted shell string, so an apostrophe in an awk COMMENT closes the
# quote and turns the rest into shell syntax -- the salvaged WIP shipped
# exactly that (a possessive "'s" in two comments, HIMMEL-2709 port) and every
# scan then silently returned nothing. `bash -n` checks SHELL syntax only; it
# says nothing about the awk program itself, which T0b checks by running it.
rc=0
bash -n "$LIB_DIR/unchecked-mktemp.sh" >/dev/null 2>&1 || rc=$?
assert_rc "T0 predicate library passes bash -n" 0 "$rc"

# T0b -- the awk program parses and runs: a scan of an empty file exits 0
# with no stderr (an awk syntax error exits 2 and prints to stderr).
t0b_dir=$(fixture_mktemp_dir) || { echo "FAIL: T0b setup: fixture_mktemp_dir failed -- aborting suite" >&2; exit 1; }
: > "$t0b_dir/empty.sh"
rc=0
t0b_err="$(unchecked_mktemp_scan "$t0b_dir/empty.sh" 2>&1 >/dev/null)" || rc=$?
assert_rc "T0b predicate awk program runs (empty file)" 0 "$rc"
assert_eq "T0b predicate awk program prints no error" "" "$t0b_err"

scan_lines() {
    unchecked_mktemp_scan "$1" | wc -l | tr -d ' '
}

# T1 -- bare unguarded assignment -> OFFENDING.
f="$TMPDIR_ROOT/t1.sh"
printf 'A=$(mktemp -d)\n' > "$f"
assert_eq "T1 bare unguarded assignment -> offending" "1" "$(scan_lines "$f")"

# T2 -- same-line || guard -> ok.
f="$TMPDIR_ROOT/t2.sh"
printf 'B=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T2 same-line || guard -> ok" "0" "$(scan_lines "$f")"

# T3 -- next-line bare [ -n ] test, nothing else on the line -> ok. The
# simplified contract does not judge guard QUALITY -- any test construct
# referencing the variable within the window counts, chained or not.
f="$TMPDIR_ROOT/t3.sh"
printf 'C="$(mktemp -d)"\n[ -n "$C" ]\n' > "$f"
assert_eq "T3 next-line bare [ -n ] test -> ok" "0" "$(scan_lines "$f")"

# T3b -- next-line [ -n ] test chained with || -> ok (consequential).
f="$TMPDIR_ROOT/t3b.sh"
printf 'C="$(mktemp -d)"\n[ -n "$C" ] || exit 1\n' > "$f"
assert_eq "T3b next-line [ -n ] || exit guard -> ok" "0" "$(scan_lines "$f")"

# T3c -- next-line test as an if-condition -> ok (consequential).
f="$TMPDIR_ROOT/t3c.sh"
printf 'C="$(mktemp -d)"\nif [ -z "$C" ]; then exit 1; fi\n' > "$f"
assert_eq "T3c next-line if [ -z ] condition guard -> ok" "0" "$(scan_lines "$f")"

# T4 -- next-line ${VAR:?...} guard -> ok.
f="$TMPDIR_ROOT/t4.sh"
printf 'D="$(mktemp -d)"\n: "${D:?missing}"\n' > "$f"
assert_eq "T4 next-line \${D:?} guard -> ok" "0" "$(scan_lines "$f")"

# T5 -- documented escape comment -> ok.
f="$TMPDIR_ROOT/t5.sh"
printf 'E=$(mktemp -d)  # mktemp-unchecked-ok: x\n' > "$f"
assert_eq "T5 mktemp-unchecked-ok escape -> ok" "0" "$(scan_lines "$f")"

# T6 -- local-prefixed unguarded assignment -> OFFENDING.
f="$TMPDIR_ROOT/t6.sh"
printf 'local F=$(mktemp)\n' > "$f"
assert_eq "T6 local-prefixed unguarded -> offending" "1" "$(scan_lines "$f")"

# T7 -- `if ! G=$(mktemp -d); then` is not an assignment statement -> ok.
f="$TMPDIR_ROOT/t7.sh"
printf 'if ! G=$(mktemp -d); then\n    exit 1\nfi\n' > "$f"
assert_eq "T7 if-guarded condition -> ok (not an assignment statement)" "0" "$(scan_lines "$f")"

# T8 -- a `trap` cleanup is NOT a guard -> OFFENDING.
f="$TMPDIR_ROOT/t8.sh"
printf 'H="$(mktemp -d)"; trap '"'"'rmdir "$H"'"'"' EXIT\n' > "$f"
assert_eq "T8 trap cleanup is not a guard -> offending" "1" "$(scan_lines "$f")"

# T9 -- blank lines do not consume the 3-line guard window -> ok.
f="$TMPDIR_ROOT/t9.sh"
printf 'I="$(mktemp -d)"\n\n[[ -d "$I" ]] || exit 1\n' > "$f"
assert_eq "T9 blank line does not consume guard window -> ok" "0" "$(scan_lines "$f")"

# T10 -- export-prefixed unguarded assignment -> OFFENDING.
f="$TMPDIR_ROOT/t10.sh"
printf 'export J="$(mktemp -d)"\n' > "$f"
assert_eq "T10 export-prefixed unguarded -> offending" "1" "$(scan_lines "$f")"

# T11 -- explicit template argument, still unguarded -> OFFENDING.
f="$TMPDIR_ROOT/t11.sh"
printf 'K=$(mktemp "${TMPDIR:-/tmp}/x.XXXXXX")\n' > "$f"
assert_eq "T11 explicit template, unguarded -> offending" "1" "$(scan_lines "$f")"

# T13 -- same-line || whose RHS does not terminate -> ok. ACCEPTED DOCUMENTED
# FALSE NEGATIVE: a `||` that does not actually terminate/divert still counts
# as a guard under the simplified contract (rule a is "any `||`", no
# judgement on the RHS) -- do not "fix" this by re-adding an RHS check; see
# scripts/lib/unchecked-mktemp.sh's header for why that road was tried twice
# and produced a self-blocking false positive both times.
f="$TMPDIR_ROOT/t13.sh"
printf 'T=$(mktemp -d) || echo failed\n' > "$f"
assert_eq "T13 || echo failed -> ok (accepted false negative)" "0" "$(scan_lines "$f")"

# T14 -- same-line || return 1 -> ok.
f="$TMPDIR_ROOT/t14.sh"
printf 'T=$(mktemp -d) || return 1\n' > "$f"
assert_eq "T14 || return 1 -> ok" "0" "$(scan_lines "$f")"

# T15 -- same-line || fail "..." -> ok.
f="$TMPDIR_ROOT/t15.sh"
printf 'T=$(mktemp -d) || fail "mktemp failed"\n' > "$f"
assert_eq "T15 || fail \"...\" -> ok" "0" "$(scan_lines "$f")"

# T16 -- single-line || { ...; exit N; } block -> ok.
f="$TMPDIR_ROOT/t16.sh"
printf 'T=$(mktemp -d) || { echo failed; exit 1; }\n' > "$f"
assert_eq "T16 || { echo failed; exit 1; } -> ok" "0" "$(scan_lines "$f")"

# T16b -- MULTILINE || { ...; exit N; } block (codex-1): the assignment line
# itself carries a `||` and nothing more -- the block body is on later lines
# entirely. This is the exact house form that self-blocked this gate's own
# files under the old terminating-verb-plus-block-scan rules; rule (a) (any
# `||` on the line) fixes it for free, with no multiline parsing needed.
f="$TMPDIR_ROOT/t16b.sh"
printf 'scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")" || {\n    echo "FAIL" >&2\n    exit 1\n}\n' > "$f"
assert_eq "T16b multiline || { ... } block (codex-1) -> ok" "0" "$(scan_lines "$f")"

# T17 -- local-prefixed assignment with || exit 1 -> OFFENDING regardless
# (finding 2b): `local`'s own exit status, not mktemp's, is what || sees.
f="$TMPDIR_ROOT/t17.sh"
printf 'local T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T17 local T=\$(mktemp -d) || exit 1 -> offending (declaration masks status)" "1" "$(scan_lines "$f")"

# T18 -- export-prefixed assignment with || exit 1 -> OFFENDING regardless
# (finding 2b), same reasoning as T17.
f="$TMPDIR_ROOT/t18.sh"
printf 'export T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T18 export T=\$(mktemp -d) || exit 1 -> offending (declaration masks status)" "1" "$(scan_lines "$f")"

# T18b/c -- same reasoning as T17/T18, declare and typeset prefixes.
f="$TMPDIR_ROOT/t18b.sh"
printf 'declare T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T18b declare T=\$(mktemp -d) || exit 1 -> offending (declaration masks status)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t18c.sh"
printf 'typeset T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T18c typeset T=\$(mktemp -d) || exit 1 -> offending (declaration masks status)" "1" "$(scan_lines "$f")"

# T18d -- readonly prefix, same reasoning.
f="$TMPDIR_ROOT/t18d.sh"
printf 'readonly T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T18d readonly T=\$(mktemp -d) || exit 1 -> offending (declaration masks status)" "1" "$(scan_lines "$f")"

# T20 -- next-line ${T?msg} (NO colon) is NOT sufficient (codex-4): a failed
# mktemp leaves T set-but-EMPTY, and `${T?msg}` only aborts on UNSET, so it
# never fires on the failure this gate exists to catch. Only the colon form
# `${T:?msg}` (T4, above) counts.
f="$TMPDIR_ROOT/t20.sh"
printf 'T="$(mktemp -d)"\n: "${T?msg}"\n' > "$f"
assert_eq "T20 next-line \${T?msg} (no colon) -> offending (codex-4)" "1" "$(scan_lines "$f")"

# T22/T23/T23dq/T24 -- a shell FIXTURE written inline as a QUOTED heredoc is
# scanned as fixture DATA, never as code (finding 1), while an UNQUOTED
# heredoc genuinely executes and must still be scanned -- a real unguarded
# capture AFTER a quoted heredoc's terminator on the same file is also still
# flagged, proving the skip stops at the terminator rather than swallowing
# the rest of the file. `lt`/`sq`/`dq` hold the `<`, `'` and `"` characters so
# this suite's OWN source line never contains a literal `<<`/quote sequence
# that the predicate's heredoc scan could mistake for a real opener when it
# later self-scans this file (T21, below).
lt='<'
sq="'"
dq='"'

# T22 -- unquoted `<<EOF` genuinely expands and executes, so a capture inside
# it is NOT skipped (round-4 finding 1): both captures are flagged.
f="$TMPDIR_ROOT/t22.sh"
printf 'cat > f.sh %s%sEOF\nT=$(mktemp -d)\nEOF\nU=$(mktemp -d)\n' "$lt" "$lt" > "$f"
assert_eq "T22 unquoted <<EOF executes -> both captures flagged (finding 1)" "2" "$(scan_lines "$f")"
assert_eq "T22 unquoted <<EOF: both lines flagged" "$(printf '2\n4')" "$(unchecked_mktemp_scan "$f" | cut -f1)"

# T23 -- single-quoted `<<'EOF'` -- quoted, so the body is real fixture data.
f="$TMPDIR_ROOT/t23.sh"
printf 'cat > f.sh %s%s%sEOF%s\nT=$(mktemp -d)\nEOF\nU=$(mktemp -d)\n' "$lt" "$lt" "$sq" "$sq" > "$f"
assert_eq "T23 <<'EOF' heredoc body ignored -> only 1 flagged" "1" "$(scan_lines "$f")"
assert_eq "T23 <<'EOF': flagged line is the one AFTER the terminator" "4" "$(unchecked_mktemp_scan "$f" | cut -f1)"

# T23dq -- double-quoted `<<"EOF"` -- also quoted, same as T23.
f="$TMPDIR_ROOT/t23dq.sh"
printf 'cat > f.sh %s%s%sEOF%s\nT=$(mktemp -d)\nEOF\nU=$(mktemp -d)\n' "$lt" "$lt" "$dq" "$dq" > "$f"
assert_eq "T23dq double-quoted heredoc body ignored -> only 1 flagged" "1" "$(scan_lines "$f")"
assert_eq "T23dq double-quoted: flagged line is the one AFTER the terminator" "4" "$(unchecked_mktemp_scan "$f" | cut -f1)"

# T24 -- dash form `<<-'EOF'`, quoted, body and terminator both tab-indented.
f="$TMPDIR_ROOT/t24.sh"
printf 'cat > f.sh %s%s-%sEOF%s\n\tT=$(mktemp -d)\n\tEOF\nU=$(mktemp -d)\n' "$lt" "$lt" "$sq" "$sq" > "$f"
assert_eq "T24 <<-'EOF' quoted dash heredoc body ignored -> only 1 flagged" "1" "$(scan_lines "$f")"
assert_eq "T24 <<-'EOF': flagged line is the one AFTER the terminator" "4" "$(unchecked_mktemp_scan "$f" | cut -f1)"

# T24b -- dash form `<<-EOF`, UNQUOTED: still executes, so still scanned --
# the dash only controls tab-stripping, not quoting (round-4 finding 1).
f="$TMPDIR_ROOT/t24b.sh"
printf 'cat > f.sh %s%s-EOF\n\tT=$(mktemp -d)\n\tEOF\nU=$(mktemp -d)\n' "$lt" "$lt" > "$f"
assert_eq "T24b unquoted <<-EOF executes -> both captures flagged (finding 1)" "2" "$(scan_lines "$f")"

# T22c -- a QUOTED heredoc opener with NO matching terminator ANYWHERE in the
# file is not a real heredoc: nothing is skipped, and a real unguarded
# capture after it is still flagged (round-4 finding 1, closing the fail-open
# hole where ordinary logging like `echo "<<'EOF'"` could hide every later
# capture).
f="$TMPDIR_ROOT/t22c.sh"
printf 'echo %s%s%s%sEOF%s%s\nV=$(mktemp -d)\n' "$dq" "$lt" "$lt" "$sq" "$sq" "$dq" > "$f"
assert_eq "T22c quoted heredoc opener with no terminator -> capture still flagged (finding 1)" "1" "$(scan_lines "$f")"

# T25/T25b -- a same-line guard AFTER the capture, separated by `;`, counts
# exactly like a next-line one (finding 4): both the `${VAR:?}` form and the
# test-construct form.
f="$TMPDIR_ROOT/t25.sh"
printf 'T=$(mktemp -d); : "${T:?x}"\n' > "$f"
assert_eq "T25 same-line \${T:?x} after ; -> ok (finding 4)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t25b.sh"
printf 'T=$(mktemp -d); [ -n "$T" ]\n' > "$f"
assert_eq "T25b same-line [ -n ] test after ; -> ok (finding 4)" "0" "$(scan_lines "$f")"

# T26/T26b -- a declaration-prefixed line's same-line VALUE guard (rule (c)'s
# test construct, rule (d)'s `${VAR:?...}`) DOES guard it (round-4 finding
# 2): unlike a `||`, these read the variable's actual value, not the
# declaration builtin's masked exit status. T17/T18* below (same-line `||`)
# must stay offending -- that regression is a different rule (a) and is not
# touched by this fix.
f="$TMPDIR_ROOT/t26.sh"
printf 'local T=$(mktemp -d); : "${T:?x}"\n' > "$f"
assert_eq "T26 local + same-line \${T:?x} -> ok (finding 2)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t26b.sh"
printf 'local T=$(mktemp -d); [ -n "$T" ]\n' > "$f"
assert_eq "T26b local + same-line [ -n ] test -> ok (finding 2)" "0" "$(scan_lines "$f")"

# T27 -- an option on a declaration builtin other than declare (`local -r`,
# `typeset -r`) must not hide the capture from the scan: it masks mktemp's
# status exactly like the bare builtin does.
f="$TMPDIR_ROOT/t27.sh"
printf 'local -r T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T27 local -r capture + same-line || -> flagged (declaration masks status)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t27b.sh"
printf 'typeset -r T=$(mktemp -d)\n' > "$f"
assert_eq "T27b typeset -r capture, unguarded -> flagged" "1" "$(scan_lines "$f")"

# T28/T28b -- a commented-out guard line is not a guard (HIMMEL-3428 N333
# item 1, ticket finding 1): the window scan must ignore comment-only lines
# rather than treating their text as a real test construct.
f="$TMPDIR_ROOT/t28.sh"
printf 'T=$(mktemp -d)\n# [ -d "$T" ] || exit 1\n' > "$f"
assert_eq "T28 next-line comment-only guard ignored -> offending (N333 item 1)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t28b.sh"
printf 'T=$(mktemp -d)\n# validate with [ -n "$T" ]\n' > "$f"
assert_eq "T28b next-line comment-only guard (alt wording) ignored -> offending (N333 item 1)" "1" "$(scan_lines "$f")"

# T28c -- control: a REAL (uncommented) guard on the next line is still
# accepted -- the comment-ignoring fix must not eat genuine guards.
f="$TMPDIR_ROOT/t28c.sh"
printf 'T=$(mktemp -d)\n[ -d "$T" ] || exit 1\n' > "$f"
assert_eq "T28c control: real next-line guard still accepted (N333 item 1)" "0" "$(scan_lines "$f")"

# T29/T29b/T29c -- a split declaration -- `local T; T=$(mktemp -d)` -- is
# scanned at all (HIMMEL-3428 N333 item 2, ticket finding 2): the old
# anchored assignment regex never matched this shape, so an unguarded
# split-declared capture was invisible to the scan.
f="$TMPDIR_ROOT/t29.sh"
printf 'local T; T=$(mktemp -d)\n' > "$f"
assert_eq "T29 split declaration local T; T=\$(mktemp -d), unguarded -> offending (N333 item 2)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t29b.sh"
printf 'readonly T; T=$(mktemp -d)\n' > "$f"
assert_eq "T29b split declaration readonly T; T=\$(mktemp -d), unguarded -> offending (N333 item 2)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t29c.sh"
printf 'declare T; T=$(mktemp -d)\n' > "$f"
assert_eq "T29c split declaration declare T; T=\$(mktemp -d), unguarded -> offending (N333 item 2)" "1" "$(scan_lines "$f")"

# T29d -- control: a split declaration's bare assignment statement is a
# plain assignment (no decl builtin on ITS OWN statement), so a same-line
# `||` guards it correctly, unmasked -- the fix must not over-flag this.
f="$TMPDIR_ROOT/t29d.sh"
printf 'local T; T=$(mktemp -d) || exit 1\n' > "$f"
assert_eq "T29d control: split declaration local T with guarded capture -> ok (N333 item 2)" "0" "$(scan_lines "$f")"

# T30/T30b -- a command name that merely starts with "mktemp" is not mktemp
# (HIMMEL-3428 N333 item 3, ticket round-7/8 codex-2): `mktemp_metadata` /
# `mktemp_wrapper` must not be scanned as a mktemp capture.
f="$TMPDIR_ROOT/t30.sh"
printf 'T=$(mktemp_metadata)\n' > "$f"
assert_eq "T30 mktemp_metadata is not mktemp -> ok (N333 item 3)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t30b.sh"
printf 'T=$(mktemp_wrapper -d)\n' > "$f"
assert_eq "T30b mktemp_wrapper is not mktemp -> ok (N333 item 3)" "0" "$(scan_lines "$f")"

# T30c/T30d -- control: real mktemp is still matched, unguarded -> offending
# -- the boundary tightening must not exclude the genuine command, templated
# or bare.
f="$TMPDIR_ROOT/t30c.sh"
printf 'T=$(mktemp -d)\n' > "$f"
assert_eq "T30c control: real mktemp -d still matched -> offending (N333 item 3)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t30d.sh"
printf 'T=$(mktemp)\n' > "$f"
assert_eq "T30d control: bare mktemp() still matched -> offending (N333 item 3)" "1" "$(scan_lines "$f")"

# T30e/T30f -- codex-1 (round 1 /pr-check finding on this same branch): a
# non-identifier boundary is not enough -- "-" and "." are non-identifier
# characters that are still valid, common command-name characters, so
# `mktemp-wrapper` / `mktemp.sh` are distinct commands the boundary must
# also exclude.
f="$TMPDIR_ROOT/t30e.sh"
printf 'T=$(mktemp-wrapper -d)\n' > "$f"
assert_eq "T30e mktemp-wrapper is not mktemp -> ok (N333 item 3, codex-1)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t30f.sh"
printf 'T=$(mktemp.sh -d)\n' > "$f"
assert_eq "T30f mktemp.sh is not mktemp -> ok (N333 item 3, codex-1)" "0" "$(scan_lines "$f")"

# T31/T31b/T31c/T31d -- HIMMEL-3428 slice 2 item 1: a mere MENTION of the var
# inside a `[ ]`/`[[ ]]`/`test` construct (the var appears embedded in a
# larger string being compared, not as the thing actually being tested) must
# not satisfy rule (c) -- this was the test-resolve-node.sh:73 regression the
# console's adversarial review on #1107 found. Only an actual test of the
# var itself (bare truthiness, -n/-d/-z, etc.) counts.
f="$TMPDIR_ROOT/t31.sh"
printf 'tmp="$(mktemp -d)"\nout="$(foo)"\nif [ "$out" = "$tmp/bin/node.exe" ]; then true; fi\n' > "$f"
assert_eq "T31 rule (c) mention-only (\$tmp embedded in a compared string) does not guard -> offending (HIMMEL-3428 item 1)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t31b.sh"
printf 'tmp="$(mktemp -d)"\n[ -d "$tmp" ] || exit 1\n' > "$f"
assert_eq "T31b control: real [ -d \"\$tmp\" ] test of the var still guards -> ok (HIMMEL-3428 item 1)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t31c.sh"
printf 'T=$(mktemp -d)\n[ "$T" ] || exit 1\n' > "$f"
assert_eq "T31c control: bare [ \"\$T\" ] truthiness test still guards -> ok (HIMMEL-3428 item 1)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t31d.sh"
printf 'tmp="$(mktemp -d)"\nout="$(resolve)"\nif [ "$rc" -eq 0 ] && { [ "$out" = "$tmp/bin/node.exe" ] || [ "$out" = "$tmp/bin/node" ]; }; then true; fi\n' > "$f"
assert_eq "T31d regression lock: test-resolve-node.sh:73 shape -> offending (HIMMEL-3428 item 1)" "1" "$(scan_lines "$f")"

# codex-1 (/pr-check round 1 on this branch): the item-1 fix only covered the
# unbraced spelling ($tmp); a BRACED mere-mention (${tmp} embedded in a
# compared string, not actually tested) slipped past the same rule (c)
# window because the optional \}? let the engine skip the literal `}` and
# match it as the boundary character instead.
f="$TMPDIR_ROOT/t31e.sh"
printf 'tmp="$(mktemp -d)"\nout="$(foo)"\nif [ "$out" = "${tmp}/bin/node" ]; then true; fi\n' > "$f"
assert_eq "T31e rule (c) braced mention-only (\${tmp} embedded in a compared string) does not guard -> offending (codex-1)" "1" "$(scan_lines "$f")"

# Regression lock for the codex-1 fix itself: requiring an exact `${VAR}`
# close must not break the common set-u-safe `${VAR:-}` spelling of a real
# emptiness test (scripts/handover/reconcile-workers.sh:338's shape) -- the
# closing brace still has to be real, but a modifier between the var name
# and it (`:-`, `:=`, ...) must still be accepted.
f="$TMPDIR_ROOT/t31f.sh"
printf 'a=$(mktemp 2>/dev/null) && b=$(mktemp 2>/dev/null)\nif [ -z "${a:-}" ] || [ -z "${b:-}" ]; then exit 1; fi\n' > "$f"
assert_eq "T31f control: \${VAR:-} inside [ -z ] still guards (codex-1 widen)" "0" "$(scan_lines "$f")"

# T32/T32b/T32c/T32d/T32e -- HIMMEL-3428 slice 2 item 2: a trailing ` #...`
# comment must be stripped before rules (a)/(c)/(d) run, so a commented-out
# guard (same-line or next-line) does not count as real -- while `#` inside
# quotes, `${#x}` and `$#` are left alone.
f="$TMPDIR_ROOT/t32.sh"
printf 'T=$(mktemp) # || exit 1\n' > "$f"
assert_eq "T32 same-line trailing-comment fake || guard -> offending (HIMMEL-3428 item 2)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t32b.sh"
printf 'T=$(mktemp)\n# ${T:?}\n' > "$f"
assert_eq "T32b next-line commented \${T:?} guard -> offending (HIMMEL-3428 item 2)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t32c.sh"
printf 'T=$(mktemp)\n# [ -d "$T" ]\n' > "$f"
assert_eq "T32c next-line commented [ -d ] guard (bare) -> offending (HIMMEL-3428 item 2)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t32d.sh"
printf 'T=$(mktemp -d)\n[ -n "$T" ] # len=${#T}\n' > "$f"
assert_eq "T32d control: \${#T} length op in a trailing comment does not break guard recognition -> ok (HIMMEL-3428 item 2)" "0" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t32e.sh"
printf 'T=$(mktemp -d "#tag") || exit 1\n' > "$f"
assert_eq "T32e control: quoted # in the capture line args does not break || recognition -> ok (HIMMEL-3428 item 2)" "0" "$(scan_lines "$f")"

# codex-2 (/pr-check round 1 on this branch): an UNQUOTED `#` glued to a
# preceding character (no separating whitespace), e.g. inside a mktemp
# template argument, is ordinary text, not a comment start -- stripping it
# must not eat a real trailing `|| exit 1` guard that follows it.
f="$TMPDIR_ROOT/t32f.sh"
printf 'T=$(mktemp /tmp/name#XXXXXX) || exit 1\n' > "$f"
assert_eq "T32f control: unquoted # glued to a template arg (no space) does not break || recognition -> ok (codex-2)" "0" "$(scan_lines "$f")"

# T33/T33b/T33c/T33d/T33e/T33f -- HIMMEL-3428 slice 2 item 3: the command-name
# boundary must also catch `<`/`>` redirects, a bare quote with no preceding
# whitespace, a line-continuing backslash, and a CRLF line ending (stripped
# at ingestion so it never hides a match or a guard).
f="$TMPDIR_ROOT/t33.sh"
printf 'T=$(mktemp</dev/null)\n' > "$f"
assert_eq "T33 mktemp</dev/null boundary -> offending (HIMMEL-3428 item 3)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t33b.sh"
printf 'T=$(mktemp>"$f2")\n' > "$f"
assert_eq "T33b mktemp>redirect boundary -> offending (HIMMEL-3428 item 3)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t33c.sh"
printf 'T=$(mktemp%s-d%s)\n' "$sq" "$sq" > "$f"
assert_eq "T33c mktemp$sq-d$sq quote boundary -> offending (HIMMEL-3428 item 3)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t33d.sh"
printf 'T=$(mktemp \\\n-d)\n' > "$f"
assert_eq "T33d backslash-newline continuation boundary -> offending (HIMMEL-3428 item 3)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t33e.sh"
printf 'T=$(mktemp -d)\r\n' > "$f"
assert_eq "T33e CRLF-terminated capture line -> offending (HIMMEL-3428 item 3)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t33f.sh"
printf 'T=$(mktemp -d)\r\n[ -n "$T" ] || exit 1\r\n' > "$f"
assert_eq "T33f control: CRLF-terminated guard line still recognized -> ok (HIMMEL-3428 item 3)" "0" "$(scan_lines "$f")"

# T34/T34b/T34c/T34d/T34e -- HIMMEL-3428 slice 2 item 4: multi-var and
# chained declarations are recognised as declaration prefixes, not just a
# single split `local T; T=$(mktemp)`.
f="$TMPDIR_ROOT/t34.sh"
printf 'local T U\nT=$(mktemp)\n' > "$f"
assert_eq "T34 multi-var local T U; T=\$(mktemp) -> offending (HIMMEL-3428 item 4)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t34b.sh"
printf 'local T\nlocal U\nT=$(mktemp)\n' > "$f"
assert_eq "T34b chained local T; local U; T=\$(mktemp) -> offending (HIMMEL-3428 item 4)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t34c.sh"
printf 'local -- T\nT=$(mktemp)\n' > "$f"
assert_eq "T34c local -- T; T=\$(mktemp) -> offending (HIMMEL-3428 item 4)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t34d.sh"
printf 'local T && T=$(mktemp)\n' > "$f"
assert_eq "T34d local T && T=\$(mktemp) -> offending (HIMMEL-3428 item 4)" "1" "$(scan_lines "$f")"

f="$TMPDIR_ROOT/t34e.sh"
printf 'local T U\nT=$(mktemp) || exit 1\n' > "$f"
assert_eq "T34e control: guarded multi-var declaration -> ok (HIMMEL-3428 item 4)" "0" "$(scan_lines "$f")"

# T21 -- self-check: the predicate must NOT flag its own repo files. Locks
# the codex-1 self-blocking regression closed for good -- if this ever comes
# back it fails loudly here instead of silently refusing every commit that
# touches either file.
self_check_offenders="$( { unchecked_mktemp_scan "$GATE"; unchecked_mktemp_scan "$LIB_DIR/test-unchecked-mktemp.sh"; } )"
assert_eq "T21 self-check: gate + suite scan clean" "" "$self_check_offenders"

# T12 -- nonexistent path -> scan itself fails (rc=1), not a crash.
rc=0
unchecked_mktemp_scan "$TMPDIR_ROOT/does-not-exist.sh" >/dev/null 2>&1 || rc=$?
assert_rc "T12 nonexistent path -> scan fails" 1 "$rc"

# ---------------------------------------------------------------------------
# Section 2: the gate, end-to-end, against a throwaway fixture git repo.
# ---------------------------------------------------------------------------

setup_repo() {
    R=$(fixture_mktemp_dir) || return 1
    git -C "$R" init -q
    git -C "$R" config user.email t@t
    git -C "$R" config user.name t
    git -C "$R" commit -q --allow-empty -m init
}

run_gate() {
    ( cd "$R" && bash "$GATE" >/dev/null 2>&1 )
}

# G1 -- a guarded mktemp added -> gate exits 0.
setup_repo || { echo "FAIL: G1 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d) || exit 1\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G1 guarded mktemp added -> gate ok" 0 "$?"

# G2 -- an UNGUARDED mktemp added -> gate exits 1 and names the file:line.
setup_repo || { echo "FAIL: G2 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
g2_out="$(cd "$R" && bash "$GATE" 2>&1)"
g2_rc=$?
assert_rc "G2 unguarded mktemp added -> gate refuses" 1 "$g2_rc"
g2_named="$(printf '%s' "$g2_out" | grep -Fc 'scripts.sh:2:' || true)"
assert_eq "G2 names the exact file:line" "1" "$g2_named"

# G3 -- a file with a PRE-EXISTING unguarded mktemp, staged change is an
# unrelated added line -> gate exits 0 (added-lines-only invariant; the
# invariant that makes this gate landable in a repo with existing debt).
setup_repo || { echo "FAIL: G3 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
git -C "$R" commit -q -m "pre-existing unguarded (fixture debt)"
printf 'echo "unrelated"\n' >> "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G3 pre-existing unguarded, unrelated added line -> gate ok" 0 "$?"

# G4 -- UNCHECKED_MKTEMP_OK=1 bypasses an otherwise-refused fixture.
setup_repo || { echo "FAIL: G4 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
( cd "$R" && UNCHECKED_MKTEMP_OK=1 bash "$GATE" >/dev/null 2>&1 )
assert_rc "G4 UNCHECKED_MKTEMP_OK=1 bypasses" 0 "$?"

# G5 -- a path under a testdata/ component is skipped even when unguarded.
setup_repo || { echo "FAIL: G5 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
mkdir -p "$R/scripts/cr/testdata"
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts/cr/testdata/bad.sh"
git -C "$R" add scripts/cr/testdata/bad.sh
run_gate
assert_rc "G5 testdata/ path skipped -> gate ok" 0 "$?"

# G6 -- fail-closed: a corrupt staged index refuses rather than reading as
# clean. `git diff --cached` genuinely errors against a corrupt GIT_INDEX_FILE
# (verified: a nonexistent index path is NOT enough -- git treats that as a
# legitimately empty index -- so the fixture must be a file that exists and
# fails to parse).
setup_repo || { echo "FAIL: G6 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
head -c 64 /dev/urandom > "$TMPDIR_ROOT/g6-garbage.idx" 2>/dev/null || {
    echo "FAIL: G6 setup: could not build a garbage index fixture" >&2
    _fail=$((_fail + 1))
}
g6_rc=0
( cd "$R" && GIT_INDEX_FILE="$TMPDIR_ROOT/g6-garbage.idx" bash "$GATE" >/dev/null 2>&1 ) || g6_rc=$?
assert_rc "G6 corrupt staged index -> fail-closed" 1 "$g6_rc"

# G7 -- a staged RENAME whose new content adds an unguarded capture is
# refused (finding 3): --diff-filter used to be AM only, which silently
# skipped renames end to end.
setup_repo || { echo "FAIL: G7 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\necho "one"\necho "two"\necho "three"\necho "four"\necho "five"\n' > "$R/old.sh"
git -C "$R" add old.sh
git -C "$R" commit -q -m "add old.sh"
git -C "$R" mv old.sh new.sh
printf 'T=$(mktemp -d)\necho "$T"\n' >> "$R/new.sh"
git -C "$R" add new.sh
g7_out="$(cd "$R" && bash "$GATE" 2>&1)"
g7_rc=$?
assert_rc "G7 renamed file, added unguarded capture -> gate refuses" 1 "$g7_rc"
g7_named="$(printf '%s' "$g7_out" | grep -Fc 'new.sh:7:' || true)"
assert_eq "G7 names the exact new-path:line" "1" "$g7_named"

# G8 -- a staged path containing a space and a non-ASCII character is scanned
# (finding 4): git quotes such names by default, and a line-oriented reader
# (`grep -E '\.sh$'` over `--name-only` without -z) silently drops them.
setup_repo || { echo "FAIL: G8 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
weird_path='scripts/wéird file.sh'
mkdir -p "$R/scripts"
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/$weird_path"
git -C "$R" add -- "$weird_path"
g8_out="$(cd "$R" && bash "$GATE" 2>&1)"
g8_rc=$?
assert_rc "G8 non-ASCII + space filename -> gate refuses" 1 "$g8_rc"
g8_named="$(printf '%s' "$g8_out" | grep -Fc "$weird_path:2:" || true)"
assert_eq "G8 names the exact file:line" "1" "$g8_named"

# G9 -- a staged RENAME whose CONTENT IS UNCHANGED (pure rename) still carries
# a PRE-EXISTING unguarded capture -- the added-lines-only contract must
# treat this as zero added lines, not "the whole file is new" (round-4
# finding 3): a per-file diff pathspec covering only the rename DESTINATION
# cannot pair with its delete-side source, so git shows the entire renamed
# file as ADDED and its pre-existing debt then blocks an unrelated rename.
setup_repo || { echo "FAIL: G9 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/pre.sh"
git -C "$R" add pre.sh
git -C "$R" commit -q -m "add pre.sh with pre-existing unguarded capture"
git -C "$R" mv pre.sh post.sh
run_gate
assert_rc "G9 pure rename, pre-existing unguarded capture, no content change -> gate ok" 0 "$?"

# G10 -- fail-closed: when the added-line lookup itself errors (grep exit 2,
# not 1), the gate must refuse rather than read the offending line as
# "not added" and pass. A PATH shim makes only the `grep -Fxq` lookup fail.
setup_repo || { echo "FAIL: G10 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
real_grep=$(command -v grep)
shim_dir="$R/.shim"
mkdir -p "$shim_dir"
printf '#!/usr/bin/env bash\n[ "$1" = "-Fxq" ] && exit 2\nexec %s "$@"\n' "$real_grep" > "$shim_dir/grep"
chmod +x "$shim_dir/grep"
( cd "$R" && PATH="$shim_dir:$PATH" bash "$GATE" >/dev/null 2>&1 )
assert_rc "G10 added-line lookup error -> fail-closed" 1 "$?"

# G11 -- color.ui=always must not blind the hunk parse: ANSI-prefixed `@@`
# headers would yield zero added lines and let an unguarded capture through.
setup_repo || { echo "FAIL: G11 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
git -C "$R" config color.ui always
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G11 color.ui=always, unguarded capture added -> gate refuses" 1 "$?"

# G12 -- an external diff driver must not replace the -U0 hunks: with
# diff.external (config) or GIT_EXTERNAL_DIFF (env) set to a program that
# prints nothing, the gate saw zero added lines and passed (fail-open).
setup_repo || { echo "FAIL: G12 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
git -C "$R" config diff.external /bin/true
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G12 diff.external=/bin/true, unguarded capture added -> gate refuses" 1 "$?"

setup_repo || { echo "FAIL: G12b setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
( cd "$R" && GIT_EXTERNAL_DIFF=/bin/true bash "$GATE" >/dev/null 2>&1 )
assert_rc "G12b GIT_EXTERNAL_DIFF=/bin/true, unguarded capture added -> gate refuses" 1 "$?"

# G13 -- a binary attribute or a textconv driver must not hide the hunks:
# `-diff` yields "Binary files differ" and a textconv to /bin/true yields an
# empty diff, both zero added lines (fail-open).
setup_repo || { echo "FAIL: G13 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '*.sh -diff\n' > "$R/.gitattributes"
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G13 .gitattributes -diff, unguarded capture added -> gate refuses" 1 "$?"

setup_repo || { echo "FAIL: G13b setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '*.sh diff=blind\n' > "$R/.gitattributes"
git -C "$R" config diff.blind.textconv /bin/true
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G13b textconv=/bin/true, unguarded capture added -> gate refuses" 1 "$?"

# G14 -- a typechange (symlink -> regular file, status T) is a staged *.sh
# with new content; --diff-filter=AMR skipped it entirely (fail-open).
setup_repo || { echo "FAIL: G14 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf 'x\n' > "$R/target.txt"
ln -s target.txt "$R/scripts.sh"
git -C "$R" add target.txt scripts.sh
git -C "$R" commit -q -m link
rm "$R/scripts.sh"
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G14 symlink -> regular typechange, unguarded capture added -> gate refuses" 1 "$?"

# G15 -- GIT_DIFF_OPTS=-u3 must not widen the -U0 hunks: context lines
# would be read as added. A pre-existing unguarded capture next to an
# unrelated added line stays unflagged, and an added one is still refused.
setup_repo || { echo "FAIL: G15 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
git -C "$R" commit -q -n -m pre
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\necho more\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
( cd "$R" && GIT_DIFF_OPTS=-u3 bash "$GATE" >/dev/null 2>&1 )
assert_rc "G15 GIT_DIFF_OPTS=-u3, pre-existing capture, unrelated added line -> gate ok" 0 "$?"

setup_repo || { echo "FAIL: G15b setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
( cd "$R" && GIT_DIFF_OPTS=-u3 bash "$GATE" >/dev/null 2>&1 )
assert_rc "G15b GIT_DIFF_OPTS=-u3, unguarded capture added -> gate refuses" 1 "$?"

# G16 -- the zero-hunk fail-closed must not refuse the three staged changes
# that legitimately have no hunk: an empty new file, a mode-only change and a
# pure (100%) rename.
setup_repo || { echo "FAIL: G16 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
: > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G16 empty new *.sh (no hunk) -> gate ok" 0 "$?"

setup_repo || { echo "FAIL: G16b setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
git -C "$R" commit -q -n -m pre
chmod +x "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G16b mode-only change (no hunk) -> gate ok" 0 "$?"

setup_repo || { echo "FAIL: G16c setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
git -C "$R" commit -q -n -m pre
git -C "$R" mv scripts.sh renamed.sh
run_gate
assert_rc "G16c pure rename (no hunk) -> gate ok" 0 "$?"

# G17 -- the zero-hunk check must read the whole diff: a `printf | grep -q`
# under pipefail SIGPIPEs its producer on a diff larger than a pipe buffer,
# reads a hunk-bearing diff as hunk-less and falsely refuses a clean file.
setup_repo || { echo "FAIL: G17 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
awk 'BEGIN { print "#!/usr/bin/env bash"; for (i = 0; i < 4000; i++) printf "echo line-%06d-padding-padding-padding-padding\n", i }' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G17 large clean diff (> pipe buffer) -> gate ok" 0 "$?"

# G18 -- diff.interHunkContext must not fuse -U0 hunks: fused, the
# unchanged lines between two edits read as added, so a pre-existing
# unguarded capture sitting between them blocked an unrelated commit.
setup_repo || { echo "FAIL: G18 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\necho a\nT=$(mktemp -d)\necho b\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
git -C "$R" commit -q -n -m pre
git -C "$R" config diff.interHunkContext 5
printf '#!/usr/bin/env bash\necho A\nT=$(mktemp -d)\necho B\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
run_gate
assert_rc "G18 diff.interHunkContext=5, pre-existing capture between edits -> gate ok" 0 "$?"

# G19 -- a staged filename carrying pathspec magic must be diffed as a
# literal path: `-- ':(exclude):*.sh'` would diff every OTHER staged
# *.sh instead, so the unguarded capture on its line 10 was never read.
setup_repo || { echo "FAIL: G19 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\necho 2\necho 3\necho 4\necho 5\necho 6\necho 7\necho 8\necho 9\nT=$(mktemp -d)\n' > "$R/:(exclude):*.sh"
printf 'echo b\n' > "$R/b.sh"
git --literal-pathspecs -C "$R" add -- ':(exclude):*.sh' b.sh
run_gate
assert_rc "G19 pathspec-magic filename with an unguarded capture -> gate refuses" 1 "$?"

# G19b -- a glob-named file must not pick up a sibling it matches:
# `-- 'a*.sh'` also diffs ab.sh, whose added line 2 was then read against
# the pre-existing unguarded capture on line 2 of a*.sh.
setup_repo || { echo "FAIL: G19b setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho 3\necho 4\n' > "$R/a*.sh"
git --literal-pathspecs -C "$R" add -- 'a*.sh'
git -C "$R" commit -q -n -m pre
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho 3\necho FOUR\n' > "$R/a*.sh"
printf '#!/usr/bin/env bash\necho b\n' > "$R/ab.sh"
git --literal-pathspecs -C "$R" add -- 'a*.sh' ab.sh
run_gate
assert_rc "G19b glob-named file, sibling it matches staged -> gate ok" 0 "$?"

# G20 -- diff.renameLimit must not unpair inexact renames: unpaired, each
# renamed file reads as wholly ADDED, so its pre-existing unguarded
# capture blocked an unrelated rename.
setup_repo || { echo "FAIL: G20 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
for f in x y; do
    printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho 3\necho 4\necho 5\necho 6\necho 7\necho 8\necho %s\n' "$f" > "$R/$f.sh"
done
git -C "$R" add x.sh y.sh
git -C "$R" commit -q -n -m pre
git -C "$R" config diff.renameLimit 1
for f in x y; do
    git -C "$R" mv "$f.sh" "${f}2.sh"
    printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho 3\necho 4\necho 5\necho 6\necho 7\necho 8\necho %s-renamed\n' "$f" > "$R/${f}2.sh"
done
git -C "$R" add x2.sh y2.sh
run_gate
assert_rc "G20 diff.renameLimit=1, two inexact renames of pre-existing debt -> gate ok" 0 "$?"

# G21 -- a failed write to the scratch name list must refuse the commit:
# unchecked, a read-only diff-names.nul dropped every staged name, nothing
# was scanned, and the unguarded capture passed. A PATH-shimmed mktemp
# plants that read-only file in the scratch dir the gate creates.
if [ "$(id -u)" = 0 ]; then
    echo "SKIP: G21 needs a non-root user (root ignores a read-only file)"
else
    setup_repo || { echo "FAIL: G21 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
    real_mktemp=$(command -v mktemp) || { echo "FAIL: G21 setup: no mktemp -- aborting suite" >&2; exit 1; }
    shim_dir="$R/.shim"
    mkdir "$shim_dir"
    printf '#!/usr/bin/env bash\nd=$("%s" "$@") || exit 1\nif [ "$1" = -d ]; then : > "$d/diff-names.nul" && chmod 444 "$d/diff-names.nul"; fi\nprintf "%%s\\n" "$d"\n' "$real_mktemp" > "$shim_dir/mktemp"
    chmod +x "$shim_dir/mktemp"
    printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"
    git -C "$R" add scripts.sh
    g21_out="$(cd "$R" && PATH="$shim_dir:$PATH" bash "$GATE" 2>&1)"
    g21_rc=$?
    assert_rc "G21 read-only scratch name list -> gate refuses" 1 "$g21_rc"
    case "$g21_out" in
        *"cannot write the staged-name list"*) _pass=$((_pass + 1)) ;;
        *) echo "FAIL: G21 refusal must name the name-list write failure -- got: $g21_out"; _fail=$((_fail + 1)) ;;
    esac
fi

# ---------------------------------------------------------------------------
# Section 3: RED control (scripts/lib/red-control.sh).
#
# Mutation: swap the gate's staged-blob read (`git show ":$sh_path"`) for a
# working-tree read (`cat "$sh_path"`). Fixture: a file is STAGED with a
# guarded mktemp on line 2 (real gate: no violation, rc=0); the WORKING TREE
# copy of that same file is then edited, unstaged, to make line 2 unguarded.
# `git diff --cached` (unaffected by the working-tree edit) still reports
# line 2 as added, so the real gate reads the staged (guarded) blob and
# passes, while the mutant reads the working tree (now unguarded) and must
# refuse, naming exactly line 2 -- a specific, predictable wrong value, not
# merely "a different rc".
# ---------------------------------------------------------------------------

setup_repo || { echo "FAIL: R1 setup: setup_repo failed -- aborting suite" >&2; exit 1; }
printf '#!/usr/bin/env bash\nT=$(mktemp -d) || exit 1\necho "$T"\n' > "$R/scripts.sh"
git -C "$R" add scripts.sh
# Working-tree-only edit AFTER staging: the index keeps the guarded content.
printf '#!/usr/bin/env bash\nT=$(mktemp -d)\necho "$T"\n' > "$R/scripts.sh"

real_out="$(cd "$R" && bash "$GATE" 2>&1)"
real_rc=$?
real_named=$(printf '%s' "$real_out" | grep -Fc 'scripts.sh:2:' || true)
correct_value="rc=$real_rc flagged=$([ "$real_named" -gt 0 ] && echo yes || echo no)"

mkdir -p "$R/scripts/hooks" "$R/scripts/lib"
cp "$LIB_DIR/unchecked-mktemp.sh" "$R/scripts/lib/unchecked-mktemp.sh"
mutant="$R/scripts/hooks/check-unchecked-mktemp.mutant.sh"
sed 's#git show ":$sh_path"#cat "$sh_path"#' "$GATE" > "$mutant"
chmod +x "$mutant"

red_control_run --cwd "$R" -- sh -c 'bash "'"$mutant"'" 2>&1'
mutant_out="$RED_CONTROL_OUT"
mutant_named=$(printf '%s' "$mutant_out" | grep -Fc 'scripts.sh:2:' || true)
observed="rc=$RED_CONTROL_RC flagged=$([ "$mutant_named" -gt 0 ] && echo yes || echo no)"
red_control_assert \
    --label "R1 staged-vs-working-tree" \
    --observed "$observed" \
    --expect-wrong "rc=1 flagged=yes" \
    --expect-rc 1 \
    --correct "$correct_value" \
    --note "mutant reads the WORKING TREE instead of the staged blob and flags the working-tree-only unguarded line" \
    && _pass=$((_pass + 1)) || _fail=$((_fail + 1))

echo "-- $_pass passed, $_fail failed --"
[ "$_fail" -eq 0 ]
