#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-e2e-symmetry.sh -- END-TO-END install -> uninstall roundtrip for the
# settings.json wiring (HIMMEL-469). Unlike the hermetic unit suites (which test
# one helper in isolation), this drives the REAL setup `[9/10]` wire sequence and
# the REAL `uninstall.sh [6/8]` against a sandbox HOME (a scratch dir the suite
# makes and exports as $HOME -- never the operator's), then asserts the round trip
# leaves its settings.json byte-clean of himmel wiring while preserving the
# operator's own keys.
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
# HIMMEL-3336: a scratch HOME for the whole run. The uninstall manifest rows for
# ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md and the claude-hud config carry no
# override env var -- they resolve {HOME} -- so redirecting HIMMEL_USER_SETTINGS
# alone left them pointing at the operator's real files, and a wet [6/8] deleted
# them. CLAUDE_CONFIG_DIR is unset because the wire scripts honour it while
# uninstall ignores it: left ambient it would split the two phases across homes.
# The cwd moves too, so uninstall's {PWD} project-settings row cannot act on the
# checkout the suite was launched from.
export HOME="$td/home"
# HIMMEL-3332 S6: a scratch provenance dir alongside the scratch HOME, so the
# install-phase wire-*.sh calls below record real ledger rows (RED1/RED2 need
# a ledger to exist for the future ledger-aware restore to have anything to
# read) without ever touching the operator's real ~/.himmel.
export HIMMEL_PROVENANCE_DIR="$td/prov"
unset CLAUDE_CONFIG_DIR
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$SETTINGS")" "$td/cwd"
cd "$td/cwd" || exit 2

# Seed a realistic pre-existing settings.json: the operator's OWN rtk guard,
# a custom MCP allow, a custom statusLine and a custom env.HANDOVER_DIR -- all
# of which MUST survive the whole round trip (HIMMEL-3332 S6: RED1/RED2).
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"}]}
    ]
  },
  "permissions": {"allow":["mcp__obsidian-vault__obsidian_simple_search"]},
  "statusLine": {"type":"command","command":"bash /opt/my-status.sh"},
  "env": {"HANDOVER_DIR": "/srv/my-handovers"}
}
JSON
# Canonical form of the user's OWN pre-existing statusLine, captured straight
# from the seed file so RED1 compares against the literal bytes rather than a
# hand-duplicated JSON literal that could drift from the heredoc above.
USER_STATUSLINE_CANON=$(jq -cS .statusLine "$SETTINGS")

echo "==== PHASE INSTALL (the setup [9/10] wire sequence) ===="
# Exactly what setup.sh [9/10] runs, by subprocess (no set -e leak).
bash "$lib/wire-statusline.sh"        "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-himmel-repo.sh"       "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  --sessionstart "$SETTINGS" "$HIMMEL_FAKE" "inject-initiative.sh" >/dev/null
# HIMMEL-3332 S6: also wire HANDOVER_DIR (a value distinct from the user's
# seeded /srv/my-handovers), exactly like wire-statusline.sh already does for
# .statusLine above -- so uninstall has both a himmel-owned overwrite AND a
# ledger row recording what it replaced.
bash "$lib/wire-handover-dir.sh"      "$SETTINGS" "$td/himmel-handover" >/dev/null

check "install: 3 PreToolUse himmel hooks present" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)"))] | length' "$SETTINGS")" "3"
check "install: SessionStart inject-initiative present" \
  "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$SETTINGS")" "1"
check "install: statusLine wired"    "$(jq -r '.statusLine.type' "$SETTINGS")" "command"
check "install: env.HIMMEL_REPO set" "$(jq -r '.env.HIMMEL_REPO' "$SETTINGS")" "C:/fake/himmel"
check "install: rtk guard preserved" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$SETTINGS")" "1"
check "install: MCP allow preserved" "$(jq -r '.permissions.allow[0]' "$SETTINGS")" "mcp__obsidian-vault__obsidian_simple_search"

echo "==== PHASE UNINSTALL (the real uninstall.sh [6/8]) ===="
# Drive the REAL uninstall.sh against the sandbox HOME (set above), everything
# else skipped + non-interactive. Telegram/bridge/cache point at empty temp dirs
# so steps 1-2-7 no-op — EVERY removal target lives under $td, never the
# operator's real $HOME (HIMMELCTL_CACHE_DIR was missing this before HIMMEL-2505
# and would have pointed [7/7] at the real ~/.claude/himmel). HIMMEL_USER_SETTINGS
# is still passed explicitly, but the sandbox HOME is what confines the rest of
# [6/8]. HIMMEL_UNINSTALL_REAL_HOME is deliberately NOT set: the sandbox carries
# no live-operator marker, so uninstall.sh's own wet-run fence stays armed as a
# second layer — if HOME here ever named a real profile, the run is refused
# (rc=3) and the "[6/8] ran" check below fails instead of deleting anything.
# scripts/test-e2e-symmetry-isolation.sh proves this against an operator-shaped HOME.
out=$(HIMMEL_USER_SETTINGS="$SETTINGS" TELEGRAM_CHANNEL_DIR="$td/none" BRIDGE_ROOT="$td/noneb" \
  HIMMELCTL_CACHE_DIR="$td/nonec" HIMMEL_PROVENANCE_DIR="$HIMMEL_PROVENANCE_DIR" \
  bash "$repo_root/scripts/uninstall.sh" --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1) || true

printf '%s\n' "$out" | grep -q '\[6/8\] Unwiring' && check "uninstall: [6/8] ran" yes yes || check "uninstall: [6/8] ran" no yes
check "uninstall: PreToolUse himmel hooks gone" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)"))] | length' "$SETTINGS")" "0"
check "uninstall: SessionStart inject-initiative gone" \
  "$(jq -r '[.hooks.SessionStart[]?.hooks[]?.command // empty | select(test("inject-initiative"))] | length' "$SETTINGS")" "0"
# HIMMEL-3332 S6: the user's OWN statusLine and env.HANDOVER_DIR were both
# pre-existing (seeded above) before install overwrote them -- a ledger-aware
# uninstall must RESTORE them, not blindly strip the key (which is all
# today's unwire-statusline.sh / unwire-handover-dir.sh do).
check "RED1 uninstall: user statusLine byte-identical after round trip" \
  "$(jq -cS .statusLine "$SETTINGS")" "$USER_STATUSLINE_CANON"
check "RED2 uninstall: user env.HANDOVER_DIR survives" \
  "$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$SETTINGS")" "/srv/my-handovers"
check "uninstall: env.HIMMEL_REPO removed"  "$(jq -r '.env.HIMMEL_REPO // "ABSENT"' "$SETTINGS")" "ABSENT"
check "uninstall: rtk guard SURVIVED"       "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$SETTINGS")" "1"
check "uninstall: MCP allow SURVIVED"       "$(jq -r '.permissions.allow[0]' "$SETTINGS")" "mcp__obsidian-vault__obsidian_simple_search"

echo "==== ROUNDTRIP INVARIANT ===="
# After install->uninstall, the only himmel-managed keys are gone and the
# operator's seed survives: assert no himmel hook command remains anywhere.
check "roundtrip: zero himmel hook commands remain" \
  "$(jq -r '[.. | .command? // empty | strings | select(test("/scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets|inject-initiative)"))] | length' "$SETTINGS")" "0"

[ "$fails" -eq 0 ] && echo "E2E ALL PASS" || { echo "$fails E2E FAILED"; exit 1; }
