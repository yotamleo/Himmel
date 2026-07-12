#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-wire-luna-vault.sh -- hermetic tests for wire-luna-vault.sh (HIMMEL-458).
# Verifies the settings.json .env.LUNA_VAULT_PATH merge: create, preserve
# siblings (F1-SC2), forward-slash, refuse invalid JSON (F1-SC3), idempotent,
# last-adopt-wins overwrite to a different target (F1-SC6).
set -u
# Fixture values use a Windows-style path (C:/Documents/luna) -- exactly what a
# scaffolded vault dir looks like on the operator's primary platform, and
# unaffected by Git-Bash's leading-slash->drive path translation.
here="$(cd "$(dirname "$0")" && pwd)"
wire="$here/wire-luna-vault.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# 1. missing file -> creates {"env":{"LUNA_VAULT_PATH":"C:/Documents/luna"}}.
s1="$td/s1.json"
bash "$wire" "$s1" "C:/Documents/luna" >/dev/null
check "create on missing file" "$(jq -r '.env.LUNA_VAULT_PATH' "$s1")" "C:/Documents/luna"

# 2. existing siblings preserved (F1-SC2: other env key + a top-level key).
s2="$td/s2.json"
printf '%s' '{"statusLine":{"type":"command"},"env":{"HIMMEL_REPO":"C:/himmel"}}' > "$s2"
bash "$wire" "$s2" "C:/Documents/luna" >/dev/null
check "sibling env key preserved" "$(jq -r '.env.HIMMEL_REPO' "$s2")" "C:/himmel"
check "top-level key preserved"   "$(jq -r '.statusLine.type' "$s2")" "command"
check "LUNA_VAULT_PATH added"      "$(jq -r '.env.LUNA_VAULT_PATH' "$s2")" "C:/Documents/luna"

# 3. backslash path arg -> stored forward-slashed.
s3="$td/s3.json"
bash "$wire" "$s3" 'C:\Users\me\Documents\luna' >/dev/null
check "backslash forward-slashed" "$(jq -r '.env.LUNA_VAULT_PATH' "$s3")" "C:/Users/me/Documents/luna"

# 4. invalid JSON -> rc != 0, file unchanged (F1-SC3).
s4="$td/s4.json"
printf '%s' 'not json {' > "$s4"
if bash "$wire" "$s4" "C:/Documents/luna" >/dev/null 2>&1; then
  echo "FAIL: invalid JSON not refused"; fails=$((fails+1))
else
  echo "ok - refuses invalid JSON"
fi
check "invalid file unchanged" "$(cat "$s4")" "not json {"

# 5. idempotent -> second run identical bytes.
s5="$td/s5.json"
bash "$wire" "$s5" "C:/Documents/luna" >/dev/null
h5a="$(cat "$s5")"
bash "$wire" "$s5" "C:/Documents/luna" >/dev/null
check "idempotent re-run" "$(cat "$s5")" "$h5a"

# 6. last-adopt-wins (F1-SC6): re-run with a DIFFERENT target overwrites, keeps sibling.
s6="$td/s6.json"
printf '%s' '{"env":{"LUNA_VAULT_PATH":"C:/Documents/luna-old","KEEP":"x"}}' > "$s6"
bash "$wire" "$s6" "C:/Documents/luna-new" >/dev/null
check "last-adopt-wins overwrite" "$(jq -r '.env.LUNA_VAULT_PATH' "$s6")" "C:/Documents/luna-new"
check "overwrite keeps sibling"   "$(jq -r '.env.KEEP' "$s6")" "x"

# 7. empty / whitespace-only file -> treated as {}, not refused as invalid JSON.
s7="$td/s7.json"
printf '   \n' > "$s7"
bash "$wire" "$s7" "C:/Documents/luna" >/dev/null
check "whitespace file -> created" "$(jq -r '.env.LUNA_VAULT_PATH' "$s7")" "C:/Documents/luna"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
