#!/usr/bin/env bash
# Hidden acceptance test for pilot task bench-t4 (HIMMEL-4869): the frozen
# scripts/lanes/bench/fixtures/T4 whitespace cleanup, run inside lq-work/.
# Usage: accept.sh <worktree> <fixture-sha>
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../../tasks/accept-common.sh"
WT="$1"
T4="${PILOT_T4_DIR:-$HERE/../../../../../lanes/bench/fixtures/T4}"

while IFS= read -r f; do
  accept_ok "bytes-$f" cmp -s "$WT/lq-work/$f" "$T4/expected/$f"
done <"$T4/manifest.txt"
# The manifest names are plain ASCII, so ls is exact here.
# shellcheck disable=SC2012
accept_eq no-extra-files "$(sort "$T4/manifest.txt" | tr '\n' ' ')" "$(ls -A "$WT/lq-work" 2>/dev/null | sort | tr '\n' ' ')"
accept_eq fence-kept "$(sed -n '10,13p' "$T4/input/whitespace-diff-repro.md")" "$(sed -n '10,13p' "$WT/lq-work/whitespace-diff-repro.md" 2>/dev/null)"

accept_done
