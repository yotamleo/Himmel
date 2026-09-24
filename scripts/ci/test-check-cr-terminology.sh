#!/usr/bin/env bash
# Smoke test for scripts/ci/check-cr-terminology.sh (HIMMEL-3561).
#
# Usage: bash scripts/ci/test-check-cr-terminology.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-cr-terminology.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h3561.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# Case A: a doc that defines CR as short for CodeRabbit -> exit 1
echo "== Case A: CR defined as CodeRabbit =="
printf 'and CR is short for CodeRabbit, an automated review app.\n' > "$tmp/bad.md"
bash "$GUARD" "$tmp/bad.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "bad.md -> exit 1"; else fail "bad.md -> expected 1 got $rc"; fi

# Case B: CodeRabbit spelled out, CR used for code review -> exit 0
echo "== Case B: CR means code review, CodeRabbit spelled out =="
printf 'the CR marker records that a review is owed; CodeRabbit is one best-effort reviewer.\n' > "$tmp/good.md"
bash "$GUARD" "$tmp/good.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "good.md -> exit 0"; else fail "good.md -> expected 0 got $rc"; fi

# Case C: no scan target exists -> exit 0 (nothing to check)
echo "== Case C: scan dir absent =="
bash "$GUARD" "$tmp/does-not-exist" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "absent dir -> exit 0"; else fail "absent dir -> expected 0 got $rc"; fi

# Case D: the real repo docs pass post-fix.
echo "== Case D: real repo docs clean =="
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
( cd "$REPO_ROOT" && bash scripts/ci/check-cr-terminology.sh ) >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then pass "repo docs -> exit 0"; else fail "repo docs -> expected 0 got $rc"; fi

echo
if [ "$failures" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$failures FAILURE(S)"
  exit 1
fi
