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

# 8. SEAM (HIMMEL-1269): what wire-luna-vault writes into settings.json .env is
#    exactly what the end-session-wiki resolver consumes at step 3. Claude Code
#    applies a settings.json "env" block to the process env at session start;
#    this test makes that hop explicitly (read the key back, export it) and then
#    asserts resolve_vault_root returns the wired path with an EMPTY config and
#    registry -- i.e. /end-session-wiki-setup's GLOBAL tier actually reaches the
#    hook. A backslash input also proves the forward-slashing survives the seam.
s8="$td/s8.json"
bash "$wire" "$s8" 'C:\Users\me\Documents\luna' >/dev/null
wired="$(jq -r '.env.LUNA_VAULT_PATH' "$s8")"
cfg8="$td/cfg8.json"; printf '%s' '{}' > "$cfg8"
reg8="$td/reg8.json"; printf '%s' '{"vaults":{}}' > "$reg8"
# shellcheck disable=SC1091  # sourced at runtime; linted standalone by pre-commit
. "$here/vault-resolve.sh"
prev_lvp="${LUNA_VAULT_PATH-__UNSET__}"   # save/restore, like the .ps1 twin
export LUNA_VAULT_PATH="$wired"
got8="$(resolve_vault_root "$cfg8" "$reg8")"
check "seam: settings.json env -> resolver step 3" "$got8" "C:/Users/me/Documents/luna"

# 9. SEAM, MSYS form (HIMMEL-1269 / codex-adv): Git Bash expands the documented
#    default ~/Documents/luna to /c/Users/..., which the PowerShell hook would
#    resolve under \c\Users\... . /end-session-wiki-setup step 2c therefore runs
#    `cygpath -m` before calling the helper; this asserts that prescribed
#    conversion yields a drive-qualified value the resolver hands back intact.
#    Skips cleanly off Windows, where cygpath does not exist (and MSYS paths
#    are the native form anyway). No .ps1 twin: PowerShell never produces an
#    MSYS path, so its inputs are already drive-qualified (covered by case 8).
if command -v cygpath >/dev/null 2>&1; then
  s9="$td/s9.json"
  msys_in='/c/Users/me/Documents/luna'
  bash "$wire" "$s9" "$(cygpath -m "$msys_in")" >/dev/null
  wired9="$(jq -r '.env.LUNA_VAULT_PATH' "$s9")"
  export LUNA_VAULT_PATH="$wired9"
  got9="$(resolve_vault_root "$cfg8" "$reg8")"
  check "seam: MSYS input -> drive-qualified via cygpath -m" "$got9" "C:/Users/me/Documents/luna"
else
  echo "skip - MSYS seam (cygpath not found)"
fi

if [ "$prev_lvp" = "__UNSET__" ]; then unset LUNA_VAULT_PATH; else export LUNA_VAULT_PATH="$prev_lvp"; fi

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
