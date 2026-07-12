#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-unwire-pretooluse-hooks.sh -- hermetic tests for unwire-pretooluse-hooks.sh.
# Covers: removes only the UNIVERSAL himmel stanzas; SC12 (a SessionStart sibling
# like check-update-available survives); HIMMEL-DEV-ONLY PreToolUse hooks survive;
# idempotent; absent -> no-op; invalid JSON refused; --scope project --target.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
unwire="$here/unwire-pretooluse-hooks.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# Build a realistic settings.json: UNIVERSAL trio + a HIMMEL-DEV-ONLY PreToolUse
# (auto-arm) + a rtk guard co-located, and SessionStart with inject-initiative
# beside check-update-available (the SC12 sibling).
mk() {
  printf '%s' '{
    "hooks": {
      "PreToolUse": [
        {"matcher":"Bash","hooks":[
          {"type":"command","command":"bash C:/h/scripts/hooks/auto-approve-safe-bash.sh"},
          {"type":"command","command":"bash /opt/rtk-hook-guard.sh"}
        ]},
        {"matcher":"Edit|Write|MultiEdit|NotebookEdit","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/block-edit-on-main.sh"}]},
        {"matcher":"Bash|PowerShell|Read|Grep","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/block-read-secrets.sh"}]},
        {"matcher":"*","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/auto-arm-on-cap.sh"}]}
      ],
      "SessionStart": [
        {"hooks":[
          {"type":"command","command":"bash C:/h/scripts/hooks/check-update-available.sh"},
          {"type":"command","command":"bash C:/h/scripts/hooks/inject-initiative.sh"}
        ]}
      ]
    }
  }' > "$1"
}

# 1. removes the UNIVERSAL trio, keeps rtk guard + the dev-only auto-arm hook.
s1="$td/s1.json"; mk "$s1"
bash "$unwire" "$s1" >/dev/null
check "trio removed (auto-approve)" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s1")" "0"
check "trio removed (block-edit)"   "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main"))] | length' "$s1")" "0"
check "trio removed (block-read)"   "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-read-secrets"))] | length' "$s1")" "0"
check "rtk guard survives"          "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$s1")" "1"
check "dev-only auto-arm survives"  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-arm-on-cap"))] | length' "$s1")" "1"

# 2. SC12: inject-initiative spliced out, check-update-available sibling survives.
check "inject-initiative removed"   "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s1")" "0"
check "SC12 sibling survives"       "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("check-update-available"))] | length' "$s1")" "1"
check "SessionStart stanza kept"    "$(jq '.hooks.SessionStart | length' "$s1")" "1"

# 3. SessionStart stanza pruned when it ONLY held inject-initiative.
s3="$td/s3.json"
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/inject-initiative.sh"}]}]}}' > "$s3"
bash "$unwire" "$s3" >/dev/null
check "empty SessionStart stanza pruned" "$(jq '.hooks.SessionStart | length' "$s3")" "0"

# 4. idempotent: second run no-ops, identical bytes.
b1="$(cat "$s1")"
bash "$unwire" "$s1" >/dev/null
check "idempotent re-run" "$(cat "$s1")" "$b1"

# 5. absent file -> no-op, rc 0.
s5="$td/missing.json"
bash "$unwire" "$s5" >/dev/null 2>&1
check "absent -> rc 0" "$?" "0"
check "absent -> not created" "$([ -f "$s5" ] && echo yes || echo no)" "no"

# 6. invalid JSON -> refused, file unchanged.
s6="$td/s6.json"; printf '%s' 'nope {' > "$s6"
if bash "$unwire" "$s6" >/dev/null 2>&1; then echo "FAIL: invalid JSON not refused"; fails=$((fails+1)); else echo "ok - refuses invalid JSON"; fi
check "invalid file unchanged" "$(cat "$s6")" "nope {"

# 7. --scope project --target resolves <repo>/.claude/settings.json and unwires it.
proj="$td/proj"; mkdir -p "$proj/.claude"
mk "$proj/.claude/settings.json"
bash "$unwire" --scope project --target "$proj" >/dev/null
check "project-scope unwire (trio gone)" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$proj/.claude/settings.json")" "0"
check "project-scope dev hook kept"      "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-arm-on-cap"))] | length' "$proj/.claude/settings.json")" "1"

# 8. --dry-run mutates nothing.
s8="$td/s8.json"; mk "$s8"; b8="$(cat "$s8")"
bash "$unwire" "$s8" 1 >/dev/null
check "dry-run no mutation" "$(cat "$s8")" "$b8"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
