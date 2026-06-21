#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-setup-wire.sh -- hermetic test for the wiring sequence setup.sh's [9/10]
# performs (R3, HIMMEL-460): statusline + HIMMEL_REPO + the UNIVERSAL hooks
# (PreToolUse trio + SessionStart inject-initiative) at user scope.
#   SC1: after wiring, the user settings.json has the UNIVERSAL hooks at abs path
#        AND a pre-existing rtk-hook-guard entry is preserved.
#   SC8: running the sequence TWICE (with a changed clone path the 2nd time) leaves
#        exactly one of each UNIVERSAL stanza (basename dedup survives a path move).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# shellcheck source=wire-statusline.sh
# shellcheck disable=SC1091
. "$here/wire-statusline.sh"
# shellcheck source=wire-himmel-repo.sh
# shellcheck disable=SC1091
. "$here/wire-himmel-repo.sh"
# shellcheck source=wire-pretooluse-hooks.sh
# shellcheck disable=SC1091
. "$here/wire-pretooluse-hooks.sh"

# The exact [9/10] sequence against <settings> referencing himmel root <prefix>.
wire_all() {
  local settings="$1" prefix="$2"
  wire_statusline "$settings" "$prefix" >/dev/null
  wire_himmel_repo "$settings" "$prefix" >/dev/null
  wire_pretooluse_hooks "$settings" "$prefix" 0 >/dev/null
  wire_sessionstart_hook "$settings" "$prefix" "inject-initiative.sh" 0 >/dev/null
}

td="$(mktemp -d)"
s="$td/settings.json"
# Pre-existing rtk-hook-guard in the Bash stanza + a custom SessionStart sibling.
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"bash /x/scripts/hooks/check-update-available.sh"}]}]}}' > "$s"

wire_all "$s" "C:/Users/op/himmel"

# SC1: UNIVERSAL hooks present at the abs path.
check "auto-approve wired"   "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s")" "1"
check "block-edit wired"     "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main"))] | length' "$s")" "1"
check "block-read wired"     "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-read-secrets"))] | length' "$s")" "1"
check "inject-initiative wired" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s")" "1"
check "abs path used"        "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("C:/Users/op/himmel/scripts/hooks/auto-approve"))] | length' "$s")" "1"
# SC1: pre-existing non-himmel entries preserved.
check "rtk guard preserved"  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$s")" "1"
check "SessionStart sibling preserved" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("check-update-available"))] | length' "$s")" "1"
# SC1: statusline + HIMMEL_REPO set.
check "statusLine set"  "$(jq -r '.statusLine.type' "$s")" "command"
check "HIMMEL_REPO set" "$(jq -r '.env.HIMMEL_REPO' "$s")" "C:/Users/op/himmel"

# SC8: re-run with a CHANGED clone path → exactly one of each (basename dedup).
wire_all "$s" "C:/Users/op/himmel-moved"
check "SC8 PreToolUse trio count" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)"))] | length' "$s")" "3"
check "SC8 inject single"         "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s")" "1"
check "SC8 new path applied"      "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("himmel-moved/scripts/hooks/auto-approve"))] | length' "$s")" "1"
check "SC8 rtk still single"      "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$s")" "1"

# SC2: the GOAL behaviour — with the auto-approve hook user-wired, an OUT-OF-REPO
# session's Bash call to the abs-path Jira CLI is auto-approved. The hook decides
# from the command TEXT, so run it from a non-himmel CWD and assert "allow". This
# is the always-running hermetic counterpart to the VM script's SC2.
aa="$repo_root/scripts/hooks/auto-approve-safe-bash.sh"
outdir="$td/somewhere-else"; mkdir -p "$outdir"
sc2_in="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node $repo_root/scripts/jira/dist/index.js transition HIMMEL-1 Done\"}}"
sc2_out=$(cd "$outdir" && printf '%s' "$sc2_in" | bash "$aa" 2>/dev/null)
printf '%s' "$sc2_out" | grep -q '"permissionDecision"[: ]*"allow"' \
  && check "SC2 out-of-repo jira call auto-approved" yes yes \
  || check "SC2 out-of-repo jira call auto-approved" "no: $sc2_out" yes

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
