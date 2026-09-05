#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-wire-handover-dir.sh -- hermetic tests for wire-handover-dir.sh (HIMMEL-839).
# Verifies the settings.json .env.HANDOVER_DIR merge: create, preserve
# siblings, forward-slash, refuse invalid JSON, idempotent, last-adopt-wins
# overwrite, plus the seam into handover_root() (scripts/lib/handover-path.sh)
# reading HANDOVER_DIR straight from the process env.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
wire="$here/wire-handover-dir.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# 1. missing file -> creates {"env":{"HANDOVER_DIR":"C:/Documents/luna/handovers"}}.
s1="$td/s1.json"
bash "$wire" "$s1" "C:/Documents/luna/handovers" >/dev/null
check "create on missing file" "$(jq -r '.env.HANDOVER_DIR' "$s1")" "C:/Documents/luna/handovers"

# 2. existing siblings preserved.
s2="$td/s2.json"
printf '%s' '{"statusLine":{"type":"command"},"env":{"HIMMEL_REPO":"C:/himmel"}}' > "$s2"
bash "$wire" "$s2" "C:/Documents/luna/handovers" >/dev/null
check "sibling env key preserved" "$(jq -r '.env.HIMMEL_REPO' "$s2")" "C:/himmel"
check "top-level key preserved"   "$(jq -r '.statusLine.type' "$s2")" "command"
check "HANDOVER_DIR added"        "$(jq -r '.env.HANDOVER_DIR' "$s2")" "C:/Documents/luna/handovers"

# 3. backslash path arg -> stored forward-slashed.
s3="$td/s3.json"
bash "$wire" "$s3" 'C:\Users\me\Documents\luna\handovers' >/dev/null
check "backslash forward-slashed" "$(jq -r '.env.HANDOVER_DIR' "$s3")" "C:/Users/me/Documents/luna/handovers"

# 4. invalid JSON -> rc != 0, file unchanged.
s4="$td/s4.json"
printf '%s' 'not json {' > "$s4"
if bash "$wire" "$s4" "C:/Documents/luna/handovers" >/dev/null 2>&1; then
  echo "FAIL: invalid JSON not refused"; fails=$((fails+1))
else
  echo "ok - refuses invalid JSON"
fi
check "invalid file unchanged" "$(cat "$s4")" "not json {"

# 5. idempotent -> second run identical bytes.
s5="$td/s5.json"
bash "$wire" "$s5" "C:/Documents/luna/handovers" >/dev/null
h5a="$(cat "$s5")"
bash "$wire" "$s5" "C:/Documents/luna/handovers" >/dev/null
check "idempotent re-run" "$(cat "$s5")" "$h5a"

# 6. last-adopt-wins: re-run with a DIFFERENT target overwrites, keeps sibling.
s6="$td/s6.json"
printf '%s' '{"env":{"HANDOVER_DIR":"C:/Documents/luna-old/handovers","KEEP":"x"}}' > "$s6"
bash "$wire" "$s6" "C:/Documents/luna-new/handovers" >/dev/null
check "last-adopt-wins overwrite" "$(jq -r '.env.HANDOVER_DIR' "$s6")" "C:/Documents/luna-new/handovers"
check "overwrite keeps sibling"   "$(jq -r '.env.KEEP' "$s6")" "x"

# 7. empty / whitespace-only file -> treated as {}, not refused as invalid JSON.
s7="$td/s7.json"
printf '   \n' > "$s7"
bash "$wire" "$s7" "C:/Documents/luna/handovers" >/dev/null
check "whitespace file -> created" "$(jq -r '.env.HANDOVER_DIR' "$s7")" "C:/Documents/luna/handovers"

# 8. SEAM (HIMMEL-839): what wire-handover-dir writes into settings.json .env is
#    exactly what handover_root() (scripts/lib/handover-path.sh) reads straight
#    from the process env — Claude Code applies a settings.json "env" block to
#    the process env at session start. This test makes that hop explicit: wire
#    a real, existing dir, export the wired value the same way, and assert
#    handover_root() resolves it (Mode B) instead of falling through to the
#    inline <repo-root>/handovers default.
s8dir="$td/vault8/handovers"
mkdir -p "$s8dir"
s8="$td/s8.json"
bash "$wire" "$s8" "$s8dir" >/dev/null
wired8="$(jq -r '.env.HANDOVER_DIR' "$s8")"
# shellcheck disable=SC1091  # sourced at runtime; linted standalone by pre-commit
. "$here/handover-path.sh"
prev_hd="${HANDOVER_DIR-__UNSET__}"   # save/restore
export HANDOVER_DIR="$wired8"
got8="$(handover_root)"
expected8="$(cd "$s8dir" && pwd)"
check "seam: settings.json env -> handover_root() Mode B" "$got8" "$expected8"

if [ "$prev_hd" = "__UNSET__" ]; then unset HANDOVER_DIR; else export HANDOVER_DIR="$prev_hd"; fi

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
