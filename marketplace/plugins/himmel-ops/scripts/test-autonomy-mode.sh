#!/usr/bin/env bash
# test-autonomy-mode.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/autonomy-mode.sh"
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 (got '$1' want '$2')"; fail=1; }; }

out=$(env -u HIMMEL_INITIATIVE -u HIMMEL_INITIATIVE_OVERNIGHT bash "$SCRIPT"); check "$out" "interactive" "unset -> interactive"
out=$(HIMMEL_INITIATIVE=1 bash "$SCRIPT"); check "$out" "autonomous" "initiative=1 -> autonomous"
out=$(HIMMEL_INITIATIVE=true bash "$SCRIPT"); check "$out" "autonomous" "initiative=true -> autonomous"
out=$(HIMMEL_INITIATIVE="pr,ticket" bash "$SCRIPT"); check "$out" "autonomous" "initiative=chain-list -> autonomous"
out=$(HIMMEL_INITIATIVE=0 bash "$SCRIPT"); check "$out" "interactive" "initiative=0 -> interactive"
out=$(HIMMEL_INITIATIVE=false bash "$SCRIPT"); check "$out" "interactive" "initiative=false -> interactive"
out=$(HIMMEL_INITIATIVE=off bash "$SCRIPT"); check "$out" "interactive" "initiative=off -> interactive"
out=$(HIMMEL_INITIATIVE=no bash "$SCRIPT"); check "$out" "interactive" "initiative=no -> interactive"
out=$(HIMMEL_INITIATIVE="" bash "$SCRIPT"); check "$out" "interactive" "initiative='' -> interactive"
out=$(env -u HIMMEL_INITIATIVE HIMMEL_INITIATIVE_OVERNIGHT=1 bash "$SCRIPT"); check "$out" "autonomous" "overnight=1 (isolated) -> autonomous"
out=$(env -u HIMMEL_INITIATIVE HIMMEL_INITIATIVE_OVERNIGHT=false bash "$SCRIPT"); check "$out" "interactive" "overnight=false -> interactive"
out=$(HIMMEL_INITIATIVE=0 HIMMEL_INITIATIVE_OVERNIGHT=1 bash "$SCRIPT"); check "$out" "autonomous" "initiative=0 overnight=1 (OR) -> autonomous"
[ "$fail" = "0" ] && echo "ALL PASS"; exit "$fail"
