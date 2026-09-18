#!/usr/bin/env bash
# scripts/handover/test-arm-resume-wrapper-coverage.sh — drift guard
# (HIMMEL-3132): asserts every section test-arm-resume.sh --list reports is
# selected by at least one of its two per-PR/nightly --only dispatcher
# wrappers (test-arm-resume-fast.sh, test-arm-resume-1879.sh).
#
# test-arm-resume.sh itself stays SKIP_LISTed (its own runtime exceeds the
# 600s per-suite cap), so a section added there and forgotten in BOTH
# wrappers would never run in CI again, silently — the exact failure class
# that let PR #787 / HIMMEL-3118 case (h) ship unwatched. This suite is the
# structural check that closes that gap for every FUTURE section, not just
# the ones known today.
#
# Matching mirrors test-arm-resume.sh's own _sec_selected: --only compares
# EXACT strings against a section's aliases (test-arm-resume.sh:_sec_selected,
# HIMMEL-1637), and both wrappers pass the --list-reported label itself (never
# a shorter alias) — so a plain exact-string membership test against the
# quoted --only arguments in each wrapper's source is equivalent to what the
# suite would actually accept.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

all_sections=$(bash test-arm-resume.sh --list) || {
    echo "ERR wrapper-coverage: test-arm-resume.sh --list failed" >&2
    exit 1
}

covered=$(sed -n 's/.*--only "\([^"]*\)".*/\1/p' test-arm-resume-fast.sh test-arm-resume-1879.sh)

fail=0
pass=0
while IFS= read -r section; do
    [ -n "$section" ] || continue
    if grep -qxF "$section" <<< "$covered"; then
        pass=$((pass + 1))
    else
        echo "FAIL wrapper-coverage: section '$section' is in test-arm-resume.sh --list but is not selected by either test-arm-resume-fast.sh or test-arm-resume-1879.sh" >&2
        fail=$((fail + 1))
    fi
done <<EOF
$all_sections
EOF

echo "wrapper-coverage: $pass covered, $fail missing"
[ "$fail" -eq 0 ]
