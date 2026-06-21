#!/usr/bin/env bash
# Smoke test for scripts/ci/check-no-secrets.sh.
#
# Creates hermetic sandboxes (mktemp -d), exercises each case, asserts rc.
# The guard accepts an optional positional scan dir; tests pass the sandbox dir.
#
# Usage: bash scripts/ci/test-check-no-secrets.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-no-secrets.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# Case A: clean dir — no secret interpolation → guard exits 0
echo "== Case A: clean workflow =="
dir_a=$(mktemp -d)
cat > "$dir_a/clean.yml" <<'YAML'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
bash "$GUARD" "$dir_a"
rc=$?
if [ "$rc" -eq 0 ]; then pass "clean.yml -> exit 0"; else fail "clean.yml -> expected 0 got $rc"; fi
rm -rf "$dir_a"

# Case B: workflow containing a secrets interpolation → guard exits 1
#         and names the offending file
echo "== Case B: leaking workflow =="
dir_b=$(mktemp -d)
# We write the interpolation as two concatenated pieces so THIS test file
# itself does not contain a literal secrets-interpolation pattern.
# shellcheck disable=SC2016  # single-quotes intentional: prevent ${{ expansion
piece1='${{ '
piece2='secrets.FOO }}'
printf 'name: Release\non: [push]\njobs:\n  deploy:\n    runs-on: ubuntu-latest\n    env:\n      TOKEN: %s%s\n' \
  "$piece1" "$piece2" > "$dir_b/leak.yml"
out=$(bash "$GUARD" "$dir_b" 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then pass "leak.yml -> exit 1"; else fail "leak.yml -> expected 1 got $rc"; fi
if printf '%s' "$out" | grep -qF "leak.yml"; then
  pass "leak.yml -> filename reported"
else
  fail "leak.yml -> expected filename in output, got: $out"
fi
rm -rf "$dir_b"

# Case C: file mentions the word "secrets" in a comment but NOT as
#         ${{ secrets.* }} interpolation → guard exits 0 (no false positive)
echo "== Case C: comment-only mention of secrets =="
dir_c=$(mktemp -d)
cat > "$dir_c/comment.yml" <<'YAML'
name: Docs
# This job does NOT use any secrets.
# See docs/secrets-policy.md for the secrets rotation schedule.
on: [push]
jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML
bash "$GUARD" "$dir_c"
rc=$?
if [ "$rc" -eq 0 ]; then pass "comment-only secrets -> exit 0 (no FP)"; else fail "comment-only secrets -> expected 0 got $rc"; fi
rm -rf "$dir_c"

# Final tally
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $failures case(s) failed"
  exit 1
fi
