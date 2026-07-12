#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1090
# test-wire-pretooluse-hooks.sh -- hermetic tests for wire-pretooluse-hooks.sh.
# Covers: PreToolUse trio wired; dedup-by-basename across a clone-path change
# (SC8 -> no double-wire); rtk-hook-guard / non-himmel hook preserved; SessionStart
# shared-array merge; idempotent re-run.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
wire="$here/wire-pretooluse-hooks.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# 1. missing file -> creates the 3 PreToolUse stanzas, forward-slashed + quoted.
s1="$td/s1.json"
bash "$wire" "$s1" "C:/himmel" >/dev/null
check "3 PreToolUse stanzas"      "$(jq '.hooks.PreToolUse | length' "$s1")" "3"
check "auto-approve quoted path"  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s1")" 'bash "C:/himmel/scripts/hooks/auto-approve-safe-bash.sh"'

# 2. backslash prefix -> forward-slashed in the command.
s2="$td/s2.json"
bash "$wire" "$s2" 'C:\Users\me\himmel' >/dev/null
check "backslash forward-slashed" "$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$s2")" 'bash "C:/Users/me/himmel/scripts/hooks/block-edit-on-main.sh"'

# 3. SC8 dedup-by-basename across a CLONE-PATH change -> still exactly 3, new path.
s3="$td/s3.json"
bash "$wire" "$s3" "C:/old/himmel" >/dev/null
bash "$wire" "$s3" "C:/new/himmel" >/dev/null
check "clone-path change: still 3"   "$(jq '.hooks.PreToolUse | length' "$s3")" "3"
check "clone-path change: new path"  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s3")" 'bash "C:/new/himmel/scripts/hooks/auto-approve-safe-bash.sh"'

# 4. rtk-hook-guard / non-himmel hook in the SAME Bash stanza is preserved.
s4="$td/s4.json"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"},{"type":"command","command":"bash /old/scripts/hooks/auto-approve-safe-bash.sh"}]}]}}' > "$s4"
bash "$wire" "$s4" "C:/himmel" >/dev/null
check "rtk guard survives" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$s4")" "1"
check "himmel object replaced (no dup)" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s4")" "1"

# 5. SessionStart shared-array merge: inject-initiative co-resides with a sibling.
s5="$td/s5.json"
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /x/scripts/hooks/check-update-available.sh"}]}]}}' > "$s5"
# SessionStart wiring is a function call (direct-invoke only does PreToolUse):
( . "$wire"; wire_sessionstart_hook "$s5" "C:/himmel" "inject-initiative.sh" 0 >/dev/null )
check "SessionStart stanza count" "$(jq '.hooks.SessionStart | length' "$s5")" "1"
check "sibling check-update kept"  "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("check-update-available"))] | length' "$s5")" "1"
check "inject-initiative added"    "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s5")" "1"

# 6. SessionStart idempotent across re-run with changed clone path -> single object.
( . "$wire"; wire_sessionstart_hook "$s5" "C:/moved/himmel" "inject-initiative.sh" 0 >/dev/null )
check "inject-initiative dedup"    "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s5")" "1"
check "inject-initiative new path" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))][0]' "$s5")" 'bash "C:/moved/himmel/scripts/hooks/inject-initiative.sh"'

# 7. SessionStart with no prior stanza -> creates a standalone one.
s7="$td/s7.json"
( . "$wire"; wire_sessionstart_hook "$s7" "C:/himmel" "inject-initiative.sh" 0 >/dev/null )
check "standalone SessionStart created" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s7")" "1"

# 7b. --sessionstart CLI dispatch (the subprocess path setup.sh uses) wires it.
s7b="$td/s7b.json"
bash "$wire" --sessionstart "$s7b" "C:/himmel" "inject-initiative.sh" >/dev/null
check "--sessionstart CLI wires inject" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s7b")" "1"

# 8. PreToolUse idempotent re-run (same path) -> identical bytes.
s8="$td/s8.json"
bash "$wire" "$s8" "C:/himmel" >/dev/null
b8="$(cat "$s8")"
bash "$wire" "$s8" "C:/himmel" >/dev/null
check "PreToolUse idempotent" "$(cat "$s8")" "$b8"

# 8b. whitespace-only existing file -> treated as {} (not refused), 3 stanzas.
s8b="$td/s8b.json"; printf '   \n' > "$s8b"
bash "$wire" "$s8b" "C:/himmel" >/dev/null
check "whitespace file -> 3 stanzas" "$(jq '.hooks.PreToolUse | length' "$s8b")" "3"
# 8c. whitespace-only file -> SessionStart wires cleanly too.
s8c="$td/s8c.json"; printf '\t\n ' > "$s8c"
( . "$wire"; wire_sessionstart_hook "$s8c" "C:/himmel" "inject-initiative.sh" 0 >/dev/null )
check "whitespace file -> SessionStart inject" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s8c")" "1"

# 9. invalid JSON -> refused, file unchanged.
s9="$td/s9.json"
printf '%s' 'nope {' > "$s9"
if bash "$wire" "$s9" "C:/himmel" >/dev/null 2>&1; then
  echo "FAIL: invalid JSON not refused"; fails=$((fails+1))
else
  echo "ok - refuses invalid JSON"
fi
check "invalid file unchanged" "$(cat "$s9")" "nope {"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
