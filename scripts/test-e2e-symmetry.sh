#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-e2e-symmetry.sh -- END-TO-END install -> uninstall roundtrip for the
# settings.json wiring (HIMMEL-469). Unlike the hermetic unit suites (which test
# one helper in isolation), this drives the REAL setup `[9/10]` wire sequence and
# the REAL `uninstall.sh [6/6]` against a sandbox settings.json, then asserts the
# round trip leaves it byte-clean of himmel wiring while preserving the operator's
# own keys.
#
# jq-only (no git / node / bun) -- runs on a bare test VM and in CI, not just on a
# full himmel install. This is the foundation the VM harness uses for uninstall
# (and, later, upgrade) e2e coverage.
#
# Usage: bash scripts/test-e2e-symmetry.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"   # <repo>/scripts
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

command -v jq >/dev/null 2>&1 || { echo "test-e2e-symmetry: jq required" >&2; exit 2; }

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
HIMMEL_FAKE="C:/fake/himmel"             # stand-in clone path (string only)
SETTINGS="$td/home/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")"

# Seed a realistic pre-existing settings.json: the operator's OWN rtk guard +
# a custom MCP allow that MUST survive the whole round trip.
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"}]}
    ]
  },
  "permissions": {"allow":["mcp__obsidian-vault__obsidian_simple_search"]}
}
JSON

echo "==== PHASE INSTALL (the setup [9/10] wire sequence) ===="
# Exactly what setup.sh [9/10] runs, by subprocess (no set -e leak).
bash "$lib/wire-statusline.sh"        "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-himmel-repo.sh"       "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  --sessionstart "$SETTINGS" "$HIMMEL_FAKE" "inject-initiative.sh" >/dev/null

check "install: 3 PreToolUse himmel hooks present" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)"))] | length' "$SETTINGS")" "3"
check "install: SessionStart inject-initiative present" \
  "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$SETTINGS")" "1"
check "install: statusLine wired"    "$(jq -r '.statusLine.type' "$SETTINGS")" "command"
check "install: env.HIMMEL_REPO set" "$(jq -r '.env.HIMMEL_REPO' "$SETTINGS")" "C:/fake/himmel"
check "install: rtk guard preserved" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$SETTINGS")" "1"
check "install: MCP allow preserved" "$(jq -r '.permissions.allow[0]' "$SETTINGS")" "mcp__obsidian-vault__obsidian_simple_search"

echo "==== PHASE UNINSTALL (the real uninstall.sh [6/6]) ===="
# Drive the REAL uninstall.sh with the settings target redirected to the sandbox,
# everything else skipped + non-interactive. Telegram/bridge point at empty temp
# dirs so steps 1-2 no-op.
out=$(HIMMEL_USER_SETTINGS="$SETTINGS" TELEGRAM_CHANNEL_DIR="$td/none" BRIDGE_ROOT="$td/noneb" \
  bash "$repo_root/scripts/uninstall.sh" --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1) || true

printf '%s\n' "$out" | grep -q '\[6/6\] Unwiring' && check "uninstall: [6/6] ran" yes yes || check "uninstall: [6/6] ran" no yes
check "uninstall: PreToolUse himmel hooks gone" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)"))] | length' "$SETTINGS")" "0"
check "uninstall: SessionStart inject-initiative gone" \
  "$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(test("inject-initiative"))] | length' "$SETTINGS")" "0"
check "uninstall: statusLine removed"      "$(jq -r 'has("statusLine")' "$SETTINGS")" "false"
check "uninstall: env.HIMMEL_REPO removed"  "$(jq -r '.env.HIMMEL_REPO // "ABSENT"' "$SETTINGS")" "ABSENT"
check "uninstall: rtk guard SURVIVED"       "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$SETTINGS")" "1"
check "uninstall: MCP allow SURVIVED"       "$(jq -r '.permissions.allow[0]' "$SETTINGS")" "mcp__obsidian-vault__obsidian_simple_search"

echo "==== ROUNDTRIP INVARIANT ===="
# After install->uninstall, the only himmel-managed keys are gone and the
# operator's seed survives: assert no himmel hook command remains anywhere.
check "roundtrip: zero himmel hook commands remain" \
  "$(jq -r '[.. | .command? // empty | strings | select(test("/scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets|inject-initiative)"))] | length' "$SETTINGS")" "0"

[ "$fails" -eq 0 ] && echo "E2E ALL PASS" || { echo "$fails E2E FAILED"; exit 1; }
