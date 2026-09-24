#!/usr/bin/env bash
# Tests for scripts/hooks/lib/shell-tokenize.sh (HIMMEL-3546) and the drift
# check that keeps its two inlined copies honest.
#
# The lib is NOT sourced by the hooks at runtime: its BEGIN…END block is
# copied byte-for-byte into block-edit-live-settings.sh and
# guard-pr-check-literal.sh (hook-integrity pins launched hooks, not the libs
# they source). This suite fails when either copy drifts from the canonical
# file, and proves that check can fail (RED control on a mutated copy).
#
# Usage:
#   bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-shell-tokenize.sh
#       run the suite; add --sync to rewrite both inlined copies from the lib
#
# Exit codes:
#   0 - all cases passed (or --sync rewrote both copies)
#   1 - at least one case failed
# shellcheck disable=SC2016 # the unit cases feed literal command text
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/shell-tokenize.sh"
HOOKS=("$HERE/block-edit-live-settings.sh" "$HERE/guard-pr-check-literal.sh")
BEGIN_LINE='# >>> BEGIN shell-tokenize (HIMMEL-3546; canonical: scripts/hooks/lib/shell-tokenize.sh) >>>'
END_LINE='# <<< END shell-tokenize <<<'

# block FILE — the marker block of FILE, markers included.
block() {
    awk -v b="$BEGIN_LINE" -v e="$END_LINE" '$0 == b {p = 1} p {print} $0 == e {p = 0}' "$1"
}

# markers_ok FILE — exactly one BEGIN and one END line, BEGIN first.
markers_ok() {
    awk -v b="$BEGIN_LINE" -v e="$END_LINE" '
        $0 == b {nb++; if (ne) bad = 1}
        $0 == e {ne++}
        END {exit !(nb == 1 && ne == 1 && !bad)}' "$1"
}

# in_sync FILE — FILE's marker block is byte-identical to the lib's.
in_sync() {
    markers_ok "$1" && [ "$(block "$1"; echo x)" = "$(block "$LIB"; echo x)" ]
}

# sync_into FILE — replace FILE's marker block with the lib's.
sync_into() {
    local tmp blk
    markers_ok "$1" || { echo "sync: $1 lacks exactly one BEGIN/END pair" >&2; return 1; }
    blk=$(mktemp) && tmp=$(mktemp) || return 1
    block "$LIB" > "$blk"
    awk -v b="$BEGIN_LINE" -v e="$END_LINE" -v f="$blk" '
        $0 == b {while ((getline l < f) > 0) print l; skip = 1; next}
        $0 == e {skip = 0; next}
        !skip {print}' "$1" > "$tmp" && cat "$tmp" > "$1"
    rm -f "$tmp" "$blk"
}

if [ "${1:-}" = --sync ]; then
    for h in "${HOOKS[@]}"; do sync_into "$h" || exit 1; done
    echo "synced shell-tokenize into: ${HOOKS[*]##*/}"
    exit 0
fi

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 - expected [$3], got [$2]"; fi; }

# ---- drift: both inlined copies equal the canonical block
if [ -n "$(block "$LIB")" ]; then pass "lib carries a marker block"; else fail "lib carries a marker block"; fi
for h in "${HOOKS[@]}"; do
    if in_sync "$h"; then pass "${h##*/} inlined block matches the lib"
    else fail "${h##*/} inlined block differs from the lib (edit the lib, then run --sync)"; fi
done
# Neither hook sources the lib at runtime.
for h in "${HOOKS[@]}"; do
    if grep -nE '^[^#]*(\.|source)[[:space:]].*shell-tokenize' "$h" >/dev/null; then
        fail "${h##*/} sources shell-tokenize at runtime"
    else pass "${h##*/} does not source shell-tokenize"; fi
done

# ---- RED control: a one-line change in an inlined copy is caught, and
# --sync's rewrite repairs it.
SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
awk -v b="$BEGIN_LINE" '{print} $0 == b {print "# drift"}' "${HOOKS[1]}" > "$SCRATCH/hook.sh"
if in_sync "$SCRATCH/hook.sh"; then fail "control: a mutated copy is reported in sync"
else pass "control: a mutated copy is reported as drift"; fi
sync_into "$SCRATCH/hook.sh"
if in_sync "$SCRATCH/hook.sh" && cmp -s "$SCRATCH/hook.sh" "${HOOKS[1]}"; then
    pass "control: sync restores the mutated copy byte-for-byte"
else fail "control: sync did not restore the mutated copy"; fi
awk -v b="$BEGIN_LINE" '$0 != b {print}' "${HOOKS[1]}" > "$SCRATCH/nobegin.sh"
if in_sync "$SCRATCH/nobegin.sh"; then fail "control: a copy with no BEGIN marker is reported in sync"
else pass "control: a copy with no BEGIN marker is reported as drift"; fi

# ---- unit cases for the tokenizer itself (command text is literal)
# shellcheck source=lib/shell-tokenize.sh
. "$LIB"
# tok CMD — tokenize in THIS shell (a $(…) would lose ST_*); R is the rc.
tok() { if st_tokenize "$1"; then R=0; else R=1; fi; }

tok "echo 'a|b' \"c;d\""; check "quoted | and ; stay inside their words" "$R:$ST_NSEG:$ST_N:${ST_W[1]}:${ST_Q[1]}:${ST_W[2]}" "0:1:3:a|b:1:c;d"
tok 'cat x 2>&1 | grep y'; check "2>&1 is a redirect, not a separator" "$R:$ST_NSEG:${ST_SEP[0]}:${ST_W[2]}:${ST_RO[2]}" "0:2:|:1:2>&"
tok 'a && b; c'; check "&& and ; split segments" "$R:$ST_NSEG:${ST_SEP[0]}:${ST_SEP[1]}" "0:3:&&:;"
tok $'a\nb'; check "a newline splits segments" "$R:$ST_NSEG:${ST_SEP[0]}" "0:2:nl"
tok 'x=$(tar -xf a)'; check "\$(…) sets SUBST" "$R:$ST_SUBST" "0:1"
tok 'echo "a $(b) c"'; check "\$(…) inside double quotes sets SUBST" "$R:$ST_SUBST" "0:1"
tok 'echo `b`'; check "a backtick sets SUBST" "$R:$ST_SUBST" "0:1"
tok "echo '\$(b)'"; check "a single-quoted \$(…) is inert" "$R:$ST_SUBST:${ST_X[1]}" "0:0:0"
tok 'echo "$X"'; check "a double-quoted \$X is live" "$R:${ST_X[1]}" "0:1"
tok 'ls *.sh'; check "an unquoted glob sets G" "$R:${ST_G[1]}" "0:1"
tok "ls '*.sh'"; check "a quoted glob does not" "$R:${ST_G[1]}" "0:0"
tok 'ls ~/x'; check "a tilde is not a glob" "$R:${ST_G[1]}" "0:0"
tok 'FOO=bar cmd'; check "NAME=value is assignment-shaped" "$R:${ST_A[0]}:${ST_A[1]}" "0:1:0"
tok "'FOO=bar' cmd"; check "a quoted NAME=value is not" "$R:${ST_A[0]}" "0:0"
tok "echo \$'a'"; check "\$'…' sets ANSIC" "$R:$ST_ANSIC" "0:1"
tok 'echo a # c; d'; check "a comment sets COMMENT and ends the command" "$R:$ST_COMMENT:$ST_NSEG:$ST_N" "0:1:1:2"
tok $'cat <<EOF\nbody $(x)\nEOF\necho after'; check "an unquoted heredoc body with \$(…) sets SUBST" "$R:$ST_HEREDOC:$ST_SUBST" "0:1:1"
tok $'cat <<\'EOF\'\nbody $(x)\nEOF'; check "a quoted heredoc body is inert" "$R:$ST_HEREDOC:$ST_SUBST" "0:1:0"
tok 'case x in a) ;; esac'; check "case…esac is not modelled" "$R" "1"
tok "echo 'a"; check "an unterminated quote is not modelled" "$R" "1"
tok 'echo >'; check "a redirect with no target is not modelled" "$R" "1"

sed_inert() { if st_sed_inert "$1"; then echo inert; else echo not; fi; }
check "sed s///g is inert" "$(sed_inert 's/a/b/g')" inert
check "sed p is inert" "$(sed_inert 'p')" inert
check "sed s with | delimiter is inert" "$(sed_inert 's|a|b|')" inert
check "sed w flag is not inert" "$(sed_inert 's/a/b/w /tmp/x')" not
check "sed e flag is not inert" "$(sed_inert 's/.*/x/e')" not
check "sed e command is not inert" "$(sed_inert '1e touch x')" not
check "a second sed command is not inert" "$(sed_inert 's/a/b/;w x')" not
check "an unescaped / in the replacement is not inert" "$(sed_inert 's/x/y a/b z/')" not

sed_args() { st_tokenize "$1" >/dev/null; if st_sed_args 0 "$2"; then echo "ok[$ST_SED_SCRIPTS]"; else echo no; fi; }
check "sed -n script file: script is word 2" "$(sed_args "sed -n 's/a/b/' f" 0)" "ok[ 2]"
check "sed -e script: script is word 2" "$(sed_args "sed -e 's/a/b/' f" 0)" "ok[ 2]"
check "sed -i refused when in-place is not allowed" "$(sed_args "sed -i 's/a/b/' f" 0)" no
check "sed -i accepted when in-place is allowed" "$(sed_args "sed -i 's/a/b/' f" 1)" "ok[ 2]"
check "sed -f is refused" "$(sed_args 'sed -f s.sed f' 0)" no
check "a glob-built sed script is refused" "$(sed_args 'sed s/a/*/ f' 0)" no

echo
if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED shell-tokenize case(s) failed"
    exit 1
fi
echo "all shell-tokenize cases passed"
