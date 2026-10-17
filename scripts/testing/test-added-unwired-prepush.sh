#!/usr/bin/env bash
# Tests for the pre-push added-but-unwired step: the hook entry in
# .pre-commit-config.yaml runs check-added-unwired.sh --branch-diff, which judges the
# files the branch ADDS against its merge-base, with the ready-check item 11 message.
#
# Usage: bash scripts/testing/test-added-unwired-prepush.sh
# shellcheck disable=SC2015  # ok/no never fail, so A && ok || no is a safe if/else here
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHECK="$HERE/check-added-unwired.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/added-unwired-prepush.XXXXXX")" || exit 1
[ -d "$T" ] || exit 1
trap 'rm -rf "$T"' EXIT
unset PRE_COMMIT_TO_REF  # a pre-push run names a real-repo commit the fixture lacks
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

# The command the gate really runs: read out of the committed pre-commit config.
ENTRY=$(awk '/^ *- id: added-unwired-check$/ {f=1; next} f && /^ *- id:/ {exit} f && /entry:/ {sub(/^ *entry: */, ""); print; exit}' "$REPO/.pre-commit-config.yaml")
STAGE=$(awk '/^ *- id: added-unwired-check$/ {f=1; next} f && /^ *- id:/ {exit} f && /stages:/ {print; exit}' "$REPO/.pre-commit-config.yaml")

echo "== P config =="
[ -n "$ENTRY" ] && ok "P1 .pre-commit-config.yaml has an added-unwired-check entry" || no "P1 no added-unwired-check entry"
case "$STAGE" in *"[pre-push]"*) ok "P2 the entry runs at pre-push only" ;; *) no "P2 stage is not pre-push: $STAGE" ;; esac
case "$ENTRY" in *"check-added-unwired.sh --branch-diff") ok "P3 the entry runs the shared check in branch-diff mode" ;; *) no "P3 entry is: $ENTRY" ;; esac

# Fixture repo: main holds the runner the check reads; a branch adds a script.
R="$T/repo"
mkdir -p "$R/scripts/testing" "$R/scripts/ci" "$R/scripts/handover" "$R/scripts/tools"
cp "$CHECK" "$R/scripts/testing/check-added-unwired.sh"
: > "$R/scripts/ci/run-shell-tests.sh"
git init -q -b main "$R" || exit 1
git -C "$R" config user.email t@t || exit 1
git -C "$R" config user.name t || exit 1
git -C "$R" add -A && git -C "$R" commit -q -m "chore: base" || exit 1
git -C "$R" checkout -q -b feat/x || exit 1
printf '#!/usr/bin/env bash\n' > "$R/scripts/tools/newtool.sh"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: add newtool" || exit 1

echo "== B branch-diff behaviour =="
rc=0; out=$(cd "$R" && eval "$ENTRY" 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'added but unwired (wire it, or allowlist it in the diff):' <<<"$out" && grep -q 'UNWIRED scripts/tools/newtool.sh' <<<"$out"; } \
  && ok "B1 RED: an unwired added script fails with the item 11 message and is named" || no "B1 not caught (rc=$rc): $out"

printf 'bash scripts/tools/newtool.sh\n' > "$R/scripts/handover/caller.sh"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: reference newtool from an unwired script" || exit 1
rc=0; out=$(cd "$R" && eval "$ENTRY" 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED scripts/handover/caller.sh' <<<"$out"; } \
  && ok "B2 a referencer that is itself an unwired added script does not count" || no "B2 (rc=$rc): $out"

printf 'bash scripts/handover/caller.sh\n' > "$R/scripts/ci/run-shell-tests.sh"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: wire the caller" || exit 1
rc=0; out=$(cd "$R" && eval "$ENTRY" 2>&1) || rc=$?
[ "$rc" -eq 0 ] && ok "B3 wired in the same branch: passes" || no "B3 wired branch failed (rc=$rc): $out"

git -C "$R" checkout -q main || exit 1
rc=0; out=$(cd "$R" && eval "$ENTRY" 2>&1) || rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'adds no files' <<<"$out"; } && ok "B4 a branch adding nothing passes" || no "B4 (rc=$rc): $out"

git -C "$R" checkout -q -b feat/y main || exit 1
mkdir -p "$R/scripts/tools"
printf '#!/usr/bin/env bash\n' > "$R/scripts/tools/othertool.sh"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: add othertool" || exit 1
git -C "$R" checkout -q main || exit 1
rc=0; out=$(cd "$R" && PRE_COMMIT_TO_REF=feat/y eval "$ENTRY" 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED scripts/tools/othertool.sh' <<<"$out"; } \
  && ok "B6 the pushed tip, not the checked-out HEAD, is judged" || no "B6 (rc=$rc): $out"

git -C "$R" checkout -q -b feat/z main || exit 1
mkdir -p "$R/scripts/tools"
printf '#!/usr/bin/env bash\n' > "$R/scripts/tools/my tool.sh"
git -C "$R" add -A && git -C "$R" commit -q -m "feat: add a spaced name" || exit 1
rc=0; out=$(cd "$R" && PRE_COMMIT_TO_REF=feat/z eval "$ENTRY" 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED scripts/tools/my tool.sh' <<<"$out"; } \
  && ok "B7 a path with a space reaches the check as one argument" || no "B7 (rc=$rc): $out"
git -C "$R" checkout -q main || exit 1

R2="$T/nobase"; git init -q -b topic "$R2"; git -C "$R2" config user.email t@t; git -C "$R2" config user.name t
git -C "$R2" commit -q --allow-empty -m "chore: x"
rc=0; out=$(cd "$R2" && bash "$CHECK" --branch-diff 2>&1) || rc=$?
{ [ "$rc" -eq 0 ] && grep -q SKIPPED <<<"$out"; } && ok "B5 no base to diff against: skipped, exit 0" || no "B5 (rc=$rc): $out"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
