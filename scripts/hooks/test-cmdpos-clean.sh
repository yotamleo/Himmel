#!/usr/bin/env bash
# test-cmdpos-clean.sh — lib-cmdpos-clean.sh's marker block is guard-pr-check-literal.sh's
# command-position predicate byte for byte. guard-pr-check-literal.sh stays
# self-contained, so its copy is the canonical one: every function or variable
# assignment the block defines must equal the same-named definition there, in
# the same order. A drift in either file fails here.
#
# Usage: bash scripts/hooks/test-cmdpos-clean.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/lib-cmdpos-clean.sh"
GUARD="$HERE/guard-pr-check-literal.sh"
BEGIN_RE='^# >>> BEGIN cmdpos '
END_RE='^# <<< END cmdpos <<<$'
FAILED=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# block FILE — the lines between the markers of FILE.
block() {
    awk -v b="$BEGIN_RE" -v e="$END_RE" '$0 ~ e {p = 0} p {print} $0 ~ b {p = 1}' "$1"
}

# names — the function and variable names the helper's block defines, in order.
names() {
    block "$HELPER" | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)(\(\) \{|=).*/\1/p'
}

# extract FILE NAME... — each named definition of FILE verbatim: a function from
# `NAME() {` to the first `}` line (a one-line function whole), an assignment
# until its single quotes balance.
extract() {
    local f=$1 n
    shift
    for n in "$@"; do
        awk -v n="$n" '
            !on && index($0, n "() {") == 1 { on = 1; print; if ($0 ~ /; }$/) on = 0; next }
            !on && index($0, n "=") == 1 { print; if (gsub(/\047/, "\047") % 2 == 1) aon = 1; next }
            aon { print; if (gsub(/\047/, "\047") % 2 == 1) aon = 0; next }
            on { print; if ($0 == "}") on = 0 }
        ' "$f"
    done
}

# in_sync GUARD — the helper's block equals GUARD's definitions of its names.
in_sync() {
    local list
    list=$(names)
    [ -n "$list" ] || return 1
    # shellcheck disable=SC2086 # one name per word
    [ "$(block "$HELPER"; echo x)" = "$(extract "$1" $list; echo x)" ]
}

if [ "$(grep -cE "$BEGIN_RE" "$HELPER")" = 1 ] && [ "$(grep -cE "$END_RE" "$HELPER")" = 1 ]; then
    pass "helper carries exactly one BEGIN/END marker pair"
else
    fail "helper lacks exactly one BEGIN/END marker pair"
fi

if names | grep -x cmdpos_clean >/dev/null; then
    pass "block defines cmdpos_clean"
else
    fail "block does not define cmdpos_clean"
fi

if in_sync "$GUARD"; then
    pass "block is byte-identical to guard-pr-check-literal.sh's definitions"
else
    fail "block drifted from guard-pr-check-literal.sh's definitions"
fi

# RED control: one changed byte inside a guard function is drift.
tmp=$(mktemp "${TMPDIR:-/tmp}/cmdpos-guard.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
awk '/^cmdpos_clean\(\) \{/ {on = 1} on && !done && /return 1/ {sub(/return 1/, "return 0"); done = 1} {print}' "$GUARD" >"$tmp"
if cmp -s "$GUARD" "$tmp"; then
    fail "control: the mutation did not change the guard copy"
elif in_sync "$tmp"; then
    fail "control: a changed cmdpos_clean byte is not reported as drift"
else
    pass "control: a changed cmdpos_clean byte is reported as drift"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK test-cmdpos-clean: all cases passed"
    exit 0
fi
echo "ERR test-cmdpos-clean: $FAILED case(s) failed" >&2
exit 1
