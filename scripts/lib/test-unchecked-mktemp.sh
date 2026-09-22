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

# T0 -- the predicate library parses. Its awk program is one single-quoted
# shell string, so an apostrophe in an awk COMMENT closes the quote and turns
# the rest into shell syntax -- the salvaged WIP shipped exactly that (a
# possessive "'s" in two comments, HIMMEL-2709 port) and every scan then
# silently returned nothing.
rc=0
bash -n "$LIB_DIR/unchecked-mktemp.sh" >/dev/null 2>&1 || rc=$?
assert_rc "T0 predicate library parses (bash -n)" 0 "$rc"

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
