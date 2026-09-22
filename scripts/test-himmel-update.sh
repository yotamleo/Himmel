#!/usr/bin/env bash
# test-himmel-update.sh — the one non-hermetic case for scripts/himmel-update.sh
# (HIMMEL-426), split by HIMMEL-3450 out of what used to be a single monolith.
#
# Every OTHER case that used to live here is hermetic and now runs in CI as
# scripts/test-himmel-update-check.sh (not on SKIP_LIST). This file keeps only
# the sub-case that genuinely cannot run hermetically: `claude plugin
# marketplace update himmel` only succeeds against THIS STATION's real
# marketplace registration, so it needs the real $HOME rather than a
# throwaway sandbox — there is no local-fixture substitute for a real
# marketplace registry. That is why this file, alone, stays on SKIP_LIST.
#
# himmel-update.sh resolves its own repo root via BASH_SOURCE/.. and cd's there,
# so we test it by COPYING it into a throwaway mock clone and running it from
# inside that clone — same technique as test-himmel-update-check.sh, sharing
# its channel-fixture helpers via scripts/lib/himmel-update-fixtures.sh.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# HIMMEL-2902: scope the profile lookup to this suite's own tmp dir and clear
# any inherited channel so a station's real install profile (e.g. channel:
# stable) cannot steer this --only marketplace scenario.
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HIMMELCTL_CACHE_DIR"
unset HIMMEL_UPDATE_CHANNEL

# HIMMEL-3101: this suite still pins a throwaway CLAUDE_CONFIG_DIR/HERMES_HOME
# floor for setup (make_repo_channel, --plugins-check) so nothing but the one
# marketplace assertion below ever touches real host state — that assertion
# deliberately overrides HOME back to the real one (below) because it is the
# one case that needs it.
REAL_HOME="$HOME"
export USERPROFILE=''
export HOME="$TMP/suite-home"
export CLAUDE_CONFIG_DIR="$TMP/suite-no-claude-config"
export HERMES_HOME="$TMP/suite-no-hermes"
mkdir -p "$HOME/.claude"

# shellcheck source=lib/himmel-update-fixtures.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/himmel-update-fixtures.sh"

# ─── Test 19 (residual, HIMMEL-2705 codex-1, round 4) — the one sub-case of ──
# this scenario that needs the real station HOME/marketplace registration.
# The rest of Test 19 (--plugins-check and --only pull) is hermetic and runs
# in test-himmel-update-check.sh instead.
echo "Test 19 (residual): malformed profile channel does not abort an unrelated --only marketplace item"
make_repo_channel
PROFILE_DIR="$TMP/th19-profile"
mkdir -p "$PROFILE_DIR"
printf '{"channel":false}\n' > "$PROFILE_DIR/install-profile.json"
rc=0
# Pre-existing, out-of-scope gap (not HIMMEL-3101's): `claude plugin
# marketplace update himmel` only succeeds against this station's real
# marketplace registration, so this one case needs the real HOME rather than
# the suite-level throwaway — `--only marketplace` never reaches
# rewire_statusline/update_hermes, so this does not reopen the leak the
# suite-level sandbox above exists to close.
env -u CLAUDE_CONFIG_DIR HIMMELCTL_CACHE_DIR="$PROFILE_DIR" HOME="$REAL_HOME" bash "$CHECKOUT_DIR/scripts/himmel-update.sh" --only marketplace >/dev/null 2>&1 || rc=$?
assert_eq "malformed channel: --only marketplace (unrelated item) still exits 0" "0" "$rc"

echo
# shellcheck disable=SC2154 # pass/fail assigned by the sourced fixtures lib
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
