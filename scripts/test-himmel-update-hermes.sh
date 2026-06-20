#!/usr/bin/env bash
# Smoke test for update_hermes() in himmel-update.sh (HIMMEL-426). Sources the
# script via its HIMMEL_UPDATE_LIB seam so the function runs in isolation with
# HERMES_HOME fixtures — no network, no repo mutation.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
HIMMEL_UPDATE_LIB=1 . "$HERE/himmel-update.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

check() {  # <description> <expected-substring> <actual-output>
  if printf '%s' "$3" | grep -Eq "$2"; then
    echo "ok: $1"
  else
    echo "FAIL: $1"; echo "  expected /$2/ in:"; printf '%s\n' "$3" | sed 's/^/    /'
    fail=1
  fi
}

# HERMES_HOME is the install ROOT; the git checkout is its hermes-agent/ subdir.

# Case 1: install root with no hermes-agent checkout → "not installed" skip.
out=$(HERMES_HOME="$tmp/nope" update_hermes check 2>&1)
check "absent hermes skips" "skip: hermes not installed as a git checkout" "$out"

# Case 2: hermes-agent/ checkout with a foreign remote → "not a … checkout" skip
# (returns before any fetch/pull, so this stays offline).
git init -q "$tmp/other/hermes-agent"
git -C "$tmp/other/hermes-agent" remote add origin https://github.com/x/y.git
out=$(HERMES_HOME="$tmp/other" update_hermes apply 2>&1)
check "foreign checkout skips" "is not a NousResearch/hermes-agent checkout" "$out"

# Case 3: NousResearch hermes-agent/ checkout, check mode, fetch unreachable →
# graceful handling (offline / current / update-available), never crash/push.
git init -q "$tmp/install/hermes-agent"
git -C "$tmp/install/hermes-agent" remote add origin https://github.com/NousResearch/hermes-agent.git
out=$(HERMES_HOME="$tmp/install" update_hermes check 2>&1)
check "nous checkout check handled" "could not reach origin|hermes is current|update available" "$out"

# Case 4: HERMES_HOME pointing STRAIGHT at the checkout (…/.git present) is
# tolerated — same NousResearch handling.
git init -q "$tmp/direct"
git -C "$tmp/direct" remote add origin https://github.com/NousResearch/hermes-agent.git
out=$(HERMES_HOME="$tmp/direct" update_hermes check 2>&1)
check "direct checkout tolerated" "could not reach origin|hermes is current|update available" "$out"

if [ "$fail" -eq 0 ]; then
  echo "PASS: himmel-update hermes smoke test"
else
  echo "FAILED"; exit 1
fi
