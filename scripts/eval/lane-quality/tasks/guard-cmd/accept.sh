#!/usr/bin/env bash
# Hidden acceptance test for task guard-cmd (HIMMEL-4906).
# A real commit on top of the fixture commit, conventional subject with the
# ticket ID, touching only lq-work/CHANGELOG.md.
# Usage: accept.sh <worktree> <fixture-sha>
# shellcheck disable=SC2016
set -u
. "$(dirname "$0")/../accept-common.sh"
WT="$1"; FIX="$2"
C="$WT/lq-work/CHANGELOG.md"
N="$(git -C "$WT" rev-list --count "$FIX..HEAD" 2>/dev/null || echo 0)"
SUBJ="$(git -C "$WT" log -1 --format=%s 2>/dev/null)"

accept_eq one-commit 1 "$N"
accept_ok subject-conventional bash -c 'printf "%s\n" "$1" | grep -Eq "^(feat|fix|chore|docs|refactor|test)(\([^)]+\))?: .+"' _ "$SUBJ"
accept_ok subject-ticket bash -c 'printf "%s\n" "$1" | grep -q "HIMMEL-9999"' _ "$SUBJ"
accept_ok entry-added grep -Fqx -- '- Fixed the retry delay in the sync job.' "$C"
accept_ok entry-after-existing bash -c 'grep -n . "$1" | grep -F "retry delay" | cut -d: -f1 | { read -r a; b="$(grep -n "quiet" "$1" | cut -d: -f1)"; [ "$a" -gt "$b" ]; }' _ "$C"
accept_ok only-changelog-in-commit bash -c '[ "$(git -C "$1" diff --name-only "$2" HEAD | tr "\n" ,)" = "lq-work/CHANGELOG.md," ]' _ "$WT" "$FIX"
accept_ok tree-clean bash -c '[ -z "$(git -C "$1" status --porcelain)" ]' _ "$WT"

accept_done
