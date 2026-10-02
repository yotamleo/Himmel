#!/usr/bin/env bash
# test-profile-settings.sh -- HIMMEL-4033: profile-settings.sh names the generated
# settings file by a hash of the resolved JSON, so two checkouts whose
# plugin-profiles.json differ cannot rewrite a file an armed relaunch already
# points at. Scratch HOME/dir only; never touches ~/.himmel/launch-profiles.
# Usage: bash scripts/lanes/test-profile-settings.sh   (bash 3.2-safe)
# shellcheck disable=SC2015  # ok() cannot fail; A && ok || bad is the intended guard
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PS="$HERE/profile-settings.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/profile-settings.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_PROFILE_SETTINGS_DIR="$TMP/profiles"
FAILED=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# Registry B differs from the shipped one in what `user` resolves to.
python3 - "$HERE/plugin-profiles.json" "$TMP/registry-b.json" <<'E'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["user"]["drop"] = ["pr-review-toolkit-himmel@himmel"]
json.dump(d, open(sys.argv[2], "w"))
E

A1=$(bash "$PS" user); rc=$?
[ "$rc" = 0 ] && ok "T1 resolves rc=0" || bad "T1 rc=$rc"
case "$A1" in */user.json) ok "T1 basename stays <profile>.json" ;; *) bad "T1 basename: $A1" ;; esac
A1_BEFORE=$(cat "$A1")

A2=$(bash "$PS" user)
[ "$A1" = "$A2" ] && ok "T2 same content -> same path (stable)" || bad "T2 path moved: $A1 vs $A2"

B=$(PLUGIN_PROFILES_REGISTRY="$TMP/registry-b.json" bash "$PS" user); rc=$?
[ "$rc" = 0 ] && ok "T3 registry B resolves" || bad "T3 rc=$rc"
[ "$B" != "$A1" ] && ok "T3 different content -> different path" || bad "T3 same path for different content: $B"
[ "$(cat "$A1")" = "$A1_BEFORE" ] && ok "T4 first file untouched by the second resolution" || bad "T4 first file was rewritten"
[ -f "$B" ] && ! cmp -s "$A1" "$B" && ok "T4 second file holds the second content" || bad "T4 second file missing or equal"

bash "$PS" no-such-profile >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "T5 unknown profile fails closed (rc=2)" || bad "T5 rc=$rc"

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "ALL PASS"
