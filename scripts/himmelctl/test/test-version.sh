#!/usr/bin/env bash
# test-version.sh — himmel carries a version, and himmelctl reports it.
#
# WHY (HIMMEL-1599): himmel had NO version of its own. The `template-version`
# gate versions the luna TEMPLATE, not the harness, so every measurement we
# take — gate false-positive rates, dispatch-completion rates, suite timings —
# was unattributable: "this run was slower" with nothing to attribute it to.
# A version is the cheapest thing that makes a measurement comparable.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"

[ -f "$root/VERSION" ] || { echo "FAIL - no VERSION file at $root/VERSION"; exit 1; }

# tr strips CR too: the file is read on Windows checkouts where a CRLF would
# otherwise sneak into the semver comparison and fail for a cosmetic reason.
v=$(tr -d ' \n\r' < "$root/VERSION")
printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "FAIL - VERSION is not semver: [$v]"; exit 1; }

# Pin the root the CLI derives: repoRoot() gives HIMMELCTL_REPO_ROOT precedence,
# so an inherited value would have --version read a DIFFERENT checkout's VERSION
# than the "$root/VERSION" this test just compared against.
# -F: the semver's dots are regex wildcards under a plain grep, so a coincidental
# near-miss ("0X1Y0") would satisfy the assertion.
out=$(HIMMELCTL_REPO_ROOT="$root" node "$root/scripts/himmelctl/bin.js" --version 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  || { echo "FAIL - himmelctl --version exited $rc (it must never throw; got: $out)"; exit 1; }
printf '%s' "$out" | grep -Fq "$v" \
  || { echo "FAIL - himmelctl --version does not report $v (got: $out)"; exit 1; }

# --version must not cannibalise --help: both are pre-parseArgs special cases,
# and an over-broad match would swallow the other.
help_out=$(HIMMELCTL_REPO_ROOT="$root" node "$root/scripts/himmelctl/bin.js" --help 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  || { echo "FAIL - himmelctl --help exits $rc (got: $help_out)"; exit 1; }
printf '%s' "$help_out" | grep -q 'usage' \
  || { echo "FAIL - --help no longer prints usage"; exit 1; }

echo "ok - VERSION is semver ($v), himmelctl reports it, --help still works"
