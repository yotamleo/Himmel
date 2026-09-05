#!/usr/bin/env bash
# Run the guardrail matrix invariant suites (HIMMEL-1522).
#
# Both suites existed as standalone scripts that only ran when somebody
# remembered to type them. The egress matrix decides whether a corpus may leave
# the machine and the voice policy decides what a spoken request may do — an
# unenforced guard is exactly the one that regresses quietly, so they are wired
# into pre-commit AND the public-mirror CI.
#
# Pre-commit matters more than CI here: Actions is OFF on the private repo by
# design, so a private PR going green is not evidence either suite ran.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root"

if ! command -v node >/dev/null 2>&1; then
  echo "check-guardrail-matrices: node not found — cannot verify guardrail invariants" >&2
  exit 1
fi

status=0
for suite in \
  scripts/guardrails/test-egress-matrix.mjs \
  scripts/guardrails/test-voice-policy.mjs
do
  if [ ! -f "$suite" ]; then
    echo "check-guardrail-matrices: missing $suite" >&2
    status=1
    continue
  fi
  if ! out=$(node "$suite" 2>&1); then
    echo "check-guardrail-matrices: FAILED $suite" >&2
    echo "$out" >&2
    status=1
  else
    echo "  ok  $suite"
  fi
done

exit "$status"
