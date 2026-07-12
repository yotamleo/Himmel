#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-wire-himmel-repo.sh -- hermetic tests for wire-himmel-repo.sh (HIMMEL-453).
# Verifies the settings.json .env.HIMMEL_REPO merge: create, preserve siblings,
# forward-slash, refuse invalid JSON, idempotent.
set -u
# Fixture values use a Windows-style path (C:/himmel) -- exactly what
# `git rev-parse --show-toplevel` yields on the operator's primary platform, and
# unaffected by Git-Bash's leading-slash->drive path translation. A bare
# /x/himmel would be mangled to X:/himmel by MSYS before the callee sees it.
here="$(cd "$(dirname "$0")" && pwd)"
wire="$here/wire-himmel-repo.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# 1. missing file -> creates {"env":{"HIMMEL_REPO":"C:/himmel"}}.
s1="$td/s1.json"
bash "$wire" "$s1" "C:/himmel" >/dev/null
check "create on missing file" "$(jq -r '.env.HIMMEL_REPO' "$s1")" "C:/himmel"

# 2. existing siblings preserved (other env key + a top-level key).
s2="$td/s2.json"
printf '%s' '{"statusLine":{"type":"command"},"env":{"HIMMEL_INITIATIVE":"all"}}' > "$s2"
bash "$wire" "$s2" "C:/himmel" >/dev/null
check "sibling env key preserved" "$(jq -r '.env.HIMMEL_INITIATIVE' "$s2")" "all"
check "top-level key preserved"   "$(jq -r '.statusLine.type' "$s2")" "command"
check "HIMMEL_REPO added"         "$(jq -r '.env.HIMMEL_REPO' "$s2")" "C:/himmel"

# 3. backslash path arg -> stored forward-slashed.
s3="$td/s3.json"
bash "$wire" "$s3" 'C:\Users\me\himmel' >/dev/null
check "backslash forward-slashed" "$(jq -r '.env.HIMMEL_REPO' "$s3")" "C:/Users/me/himmel"

# 4. invalid JSON -> rc != 0, file unchanged.
s4="$td/s4.json"
printf '%s' 'not json {' > "$s4"
if bash "$wire" "$s4" "C:/himmel" >/dev/null 2>&1; then
  echo "FAIL: invalid JSON not refused"; fails=$((fails+1))
else
  echo "ok - refuses invalid JSON"
fi
check "invalid file unchanged" "$(cat "$s4")" "not json {"

# 5. idempotent -> second run identical bytes.
s5="$td/s5.json"
bash "$wire" "$s5" "C:/himmel" >/dev/null
h5a="$(cat "$s5")"
bash "$wire" "$s5" "C:/himmel" >/dev/null
check "idempotent re-run" "$(cat "$s5")" "$h5a"

# 6. replace an EXISTING HIMMEL_REPO value (the update arm, not add).
s6="$td/s6.json"
printf '%s' '{"env":{"HIMMEL_REPO":"C:/old","KEEP":"x"}}' > "$s6"
bash "$wire" "$s6" "C:/new" >/dev/null
check "replaces existing value" "$(jq -r '.env.HIMMEL_REPO' "$s6")" "C:/new"
check "replace keeps sibling"   "$(jq -r '.env.KEEP' "$s6")" "x"

# 7. empty / whitespace-only file -> treated as {}, not refused as invalid JSON.
s7="$td/s7.json"
printf '   \n' > "$s7"
bash "$wire" "$s7" "C:/himmel" >/dev/null
check "whitespace file -> created" "$(jq -r '.env.HIMMEL_REPO' "$s7")" "C:/himmel"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
