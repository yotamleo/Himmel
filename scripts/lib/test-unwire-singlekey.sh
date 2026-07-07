#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-unwire-singlekey.sh -- hermetic tests for the single-key unwire helpers
# (unwire-statusline.sh, unwire-himmel-repo.sh, unwire-luna-vault.sh; SC6). Each:
# removes only its key/stanza, preserves siblings, idempotent, absent -> no-op,
# refuses invalid JSON. statusLine removal is conditional (himmel binary only).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sl="$here/unwire-statusline.sh"
hr="$here/unwire-himmel-repo.sh"
lv="$here/unwire-luna-vault.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
td="$(mktemp -d)"

# ── unwire-statusline ───────────────────────────────────────────────────────
# 1. removes himmel statusLine, preserves siblings.
s="$td/sl1.json"
printf '%s' '{"statusLine":{"type":"command","command":"bash \"C:/h/scripts/statusline/bin/statusline.sh\""},"env":{"X":"1"}}' > "$s"
bash "$sl" "$s" >/dev/null
check "statusLine removed"      "$(jq -r 'has("statusLine")' "$s")" "false"
check "statusLine sibling kept" "$(jq -r '.env.X' "$s")" "1"
# 1b. removes the himmel WRAPPER path too (scripts/where-are-we/statusline.sh; HIMMEL-538).
s="$td/sl1b.json"
printf '%s' '{"statusLine":{"type":"command","command":"bash \"C:/h/scripts/where-are-we/statusline.sh\""},"env":{"X":"1"}}' > "$s"
bash "$sl" "$s" >/dev/null
check "wrapper statusLine removed" "$(jq -r 'has("statusLine")' "$s")" "false"
# 1c. removes the NEW hud renderer command too (marketplace/.../claude-hud/dist/index.js;
#     HIMMEL-718) -- single-arg = REMOVE, so uninstall clears a hud-wired statusLine.
s="$td/sl1c.json"
printf '%s' '{"statusLine":{"type":"command","command":"node \"C:/h/marketplace/plugins/claude-hud/dist/index.js\""},"env":{"CLAUDE_HUD_ALLOW_EXTRA_CMD":"1"}}' > "$s"
bash "$sl" "$s" >/dev/null
check "hud statusLine removed" "$(jq -r 'has("statusLine")' "$s")" "false"
# 1d. WITH a himmel path -> REPOINT to the bash-bar fallback (HIMMEL-718 migration
#     rollback); the extra-cmd gate is deliberately left in place.
s="$td/sl1d.json"
printf '%s' '{"statusLine":{"type":"command","command":"node \"C:/h/marketplace/plugins/claude-hud/dist/index.js\""},"env":{"CLAUDE_HUD_ALLOW_EXTRA_CMD":"1"}}' > "$s"
bash "$sl" "$s" "C:/h" >/dev/null
check "repointed to bash bar" "$(jq -r '.statusLine.command' "$s")" 'bash "C:/h/scripts/where-are-we/statusline.sh"'
check "repoint keeps type"    "$(jq -r '.statusLine.type' "$s")" "command"
check "repoint keeps gate"    "$(jq -r '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD' "$s")" "1"
# 1e. backslash himmel path normalized on repoint.
s="$td/sl1e.json"
printf '%s' '{"statusLine":{"type":"command","command":"node \"C:/h/marketplace/plugins/claude-hud/dist/index.js\""}}' > "$s"
bash "$sl" "$s" 'C:\h' >/dev/null
check "repoint backslash normalized" "$(jq -r '.statusLine.command' "$s")" 'bash "C:/h/scripts/where-are-we/statusline.sh"'
# 2. a NON-himmel custom statusLine is left untouched (both remove and repoint modes).
s="$td/sl2.json"
printf '%s' '{"statusLine":{"type":"command","command":"bash /opt/my-own-statusline.sh"}}' > "$s"
bash "$sl" "$s" >/dev/null
check "custom statusLine preserved" "$(jq -r '.statusLine.command' "$s")" "bash /opt/my-own-statusline.sh"
bash "$sl" "$s" "C:/h" >/dev/null
check "custom statusLine preserved (repoint mode)" "$(jq -r '.statusLine.command' "$s")" "bash /opt/my-own-statusline.sh"

# ── unwire-himmel-repo ──────────────────────────────────────────────────────
# 3. removes HIMMEL_REPO, preserves sibling env keys.
s="$td/hr1.json"
printf '%s' '{"env":{"HIMMEL_REPO":"C:/h","HIMMEL_INITIATIVE":"all"}}' > "$s"
bash "$hr" "$s" >/dev/null
check "HIMMEL_REPO removed"     "$(jq -r '.env.HIMMEL_REPO // "ABSENT"' "$s")" "ABSENT"
check "HIMMEL_INITIATIVE kept"  "$(jq -r '.env.HIMMEL_INITIATIVE' "$s")" "all"
# 4. env pruned when it becomes empty.
s="$td/hr2.json"
printf '%s' '{"statusLine":{"x":1},"env":{"HIMMEL_REPO":"C:/h"}}' > "$s"
bash "$hr" "$s" >/dev/null
check "empty env pruned"        "$(jq -r 'has("env")' "$s")" "false"
check "non-env sibling kept"    "$(jq -r '.statusLine.x' "$s")" "1"

# ── unwire-luna-vault ───────────────────────────────────────────────────────
# 5. removes LUNA_VAULT_PATH, preserves sibling env keys.
s="$td/lv1.json"
printf '%s' '{"env":{"LUNA_VAULT_PATH":"C:/v","HIMMEL_REPO":"C:/h"}}' > "$s"
bash "$lv" "$s" >/dev/null
check "LUNA_VAULT_PATH removed"  "$(jq -r '.env.LUNA_VAULT_PATH // "ABSENT"' "$s")" "ABSENT"
check "HIMMEL_REPO kept"         "$(jq -r '.env.HIMMEL_REPO' "$s")" "C:/h"

# ── shared invariants for all three ─────────────────────────────────────────
for h in "$sl" "$hr" "$lv"; do
  n="$(basename "$h")"
  # absent file -> rc 0, not created.
  m="$td/missing-$n.json"
  bash "$h" "$m" >/dev/null 2>&1; check "$n absent -> rc0" "$?" "0"
  check "$n absent -> not created" "$([ -f "$m" ] && echo yes || echo no)" "no"
  # absent key -> content semantically unchanged (jq reformats, like the wire twins).
  k="$td/nokey-$n.json"; printf '%s' '{"permissions":{"allow":[]}}' > "$k"; kb="$(jq -S . "$k")"
  bash "$h" "$k" >/dev/null; check "$n absent-key idempotent" "$(jq -S . "$k")" "$kb"
  # invalid JSON -> refused, unchanged.
  v="$td/bad-$n.json"; printf '%s' 'nope {' > "$v"
  if bash "$h" "$v" >/dev/null 2>&1; then echo "FAIL: $n didn't refuse invalid JSON"; fails=$((fails+1)); else echo "ok - $n refuses invalid JSON"; fi
  check "$n invalid unchanged" "$(cat "$v")" "nope {"
done

# ── idempotent re-run (statusline example) ──────────────────────────────────
s="$td/idem.json"
printf '%s' '{"statusLine":{"type":"command","command":"bash \"C:/h/scripts/statusline/bin/statusline.sh\""},"env":{"HIMMEL_REPO":"C:/h"}}' > "$s"
bash "$sl" "$s" >/dev/null; ba="$(cat "$s")"; bash "$sl" "$s" >/dev/null
check "statusline idempotent" "$(cat "$s")" "$ba"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
