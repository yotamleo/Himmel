#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-e2e-symmetry-isolation.sh -- HIMMEL-3336: scripts/test-e2e-symmetry.sh must
# stay inside its own fixtures. That suite drives the REAL uninstall.sh through a
# WET [6/8]; after HIMMEL-3251 that step also removes the user-scope files install
# writes beside settings.json (~/.claude/CLAUDE.md block, ~/.codex/AGENTS.md
# block, the claude-hud config). Those manifest rows carry no override env var --
# they resolve {HOME} -- so a suite that only redirects HIMMEL_USER_SETTINGS
# deleted the operator's live hud config on every run, green in CI (no such file
# on a runner) and destructive only on a wired workstation.
#
# This suite stands in for that workstation: a scratch HOME holding a
# himmel-wired CLAUDE.md, AGENTS.md and hud config, the e2e suite run with that
# HOME, and each file asserted byte-identical afterwards. The e2e suite is NEVER
# run against the real HOME here -- the scratch HOME is the only one it sees.
#
# Usage: bash scripts/test-e2e-symmetry-isolation.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"   # <repo>/scripts
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
same(){ if cmp -s "$2" "$3"; then echo "ok - $1"; else echo "FAIL - $1: $3 differs from its pre-run copy (or is gone)"; fails=$((fails+1)); fi; }

command -v jq >/dev/null 2>&1 || { echo "test-e2e-symmetry-isolation: jq required" >&2; exit 2; }

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
mkdir -p "$td/cwd"

# seed_home <home> -- what a himmel-wired workstation holds, made by the REAL
# installers so the fixture is the shape uninstall's helpers actually remove.
# shellcheck source=lib/user-claude-md.sh
. "$lib/user-claude-md.sh"
seed_home() {
  mkdir -p "$1/.claude/plugins/claude-hud" "$1/.codex"
  printf 'my own rules\n' > "$1/.claude/CLAUDE.md"
  wire_user_claude_md "$repo_root/docs/setup/user-scope-claude-md-template.md" "$1/.claude/CLAUDE.md" >/dev/null
  wire_user_claude_md "$repo_root/docs/setup/user-scope-claude-md-template.md" "$1/.codex/AGENTS.md" >/dev/null
  sed 's#<himmel-path>#/fixture/himmel#g' "$repo_root/marketplace/plugins/claude-hud/config/himmel-config.json" \
    > "$1/.claude/plugins/claude-hud/config.json"
}

opshome="$td/opshome"
seed_home "$opshome"
mkdir -p "$td/before"
cp "$opshome/.claude/CLAUDE.md"                      "$td/before/CLAUDE.md"
cp "$opshome/.codex/AGENTS.md"                       "$td/before/AGENTS.md"
cp "$opshome/.claude/plugins/claude-hud/config.json" "$td/before/hud-config.json"

# The scratch HOME is the ONLY home the e2e suite is ever handed. Refuse to go on
# if it somehow is the real one: this suite exists to prevent that run.
if [ "$opshome" -ef "$HOME" ]; then
  echo "test-e2e-symmetry-isolation: scratch HOME resolves to the real HOME -- refusing to run the e2e suite" >&2
  exit 2
fi

echo "==== FIXTURE CONTROL (the seeded files ARE what a wet uninstall removes) ===="
# Without this, "survives" could just mean "the fixture was never himmel-shaped".
# The same call the pre-fix e2e suite made -- real uninstall.sh, wet, HOME = the
# fixture -- against a COPY of the fixture, must strip/remove all three. It is
# also the alarm for the manifest gaining an override env var for these rows.
ctl="$td/ctlhome"
seed_home "$ctl"
ctl_out=$( cd "$td/cwd" && env -u CLAUDE_CONFIG_DIR HOME="$ctl" HIMMEL_UNINSTALL_REAL_HOME=1 \
  HIMMEL_USER_SETTINGS="$ctl/.claude/settings.json" TELEGRAM_CHANNEL_DIR="$td/none" BRIDGE_ROOT="$td/noneb" \
  HIMMELCTL_CACHE_DIR="$td/nonec" \
  bash "$repo_root/scripts/uninstall.sh" --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1 ) || true
printf '%s\n' "$ctl_out" | grep -q '\[6/8\] Unwiring' && check "control: [6/8] ran against the fixture" yes yes || check "control: [6/8] ran against the fixture" no yes
check "control: hud config removed from the fixture HOME"        "$([ -e "$ctl/.claude/plugins/claude-hud/config.json" ] && echo present || echo gone)" "gone"
check "control: AGENTS.md (block only) removed from the fixture" "$([ -e "$ctl/.codex/AGENTS.md" ] && echo present || echo gone)" "gone"
check "control: CLAUDE.md block stripped, operator text kept"    "$(cat "$ctl/.claude/CLAUDE.md" 2>/dev/null)" "my own rules"

echo "==== THE E2E SUITE, HANDED THE OPERATOR-SHAPED SCRATCH HOME ===="
suite_out=$( cd "$td/cwd" && env -u CLAUDE_CONFIG_DIR HOME="$opshome" \
  bash "$repo_root/scripts/test-e2e-symmetry.sh" </dev/null 2>&1 ) && suite_rc=0 || suite_rc=$?
check "e2e suite exits 0"                    "$suite_rc" "0"
printf '%s\n' "$suite_out" | grep -q '^E2E ALL PASS' && check "e2e suite reports ALL PASS" yes yes || check "e2e suite reports ALL PASS" no yes
# Not vacuous: the suite still drives the real [6/8] and asserts its own result.
printf '%s\n' "$suite_out" | grep -q '^ok - uninstall: \[6/8\] ran' && check "e2e suite still runs uninstall [6/8]" yes yes || check "e2e suite still runs uninstall [6/8]" no yes
printf '%s\n' "$suite_out" | grep -q '^ok - uninstall: statusLine removed' && check "e2e suite still asserts the unwire" yes yes || check "e2e suite still asserts the unwire" no yes

same "hud config (~/.claude/plugins/claude-hud/config.json) survived" "$td/before/hud-config.json" "$opshome/.claude/plugins/claude-hud/config.json"
same "user CLAUDE.md (~/.claude/CLAUDE.md) survived"                  "$td/before/CLAUDE.md"       "$opshome/.claude/CLAUDE.md"
same "Codex AGENTS.md (~/.codex/AGENTS.md) survived"                  "$td/before/AGENTS.md"       "$opshome/.codex/AGENTS.md"

[ "$fails" -eq 0 ] && echo "E2E ISOLATION ALL PASS" || { echo "$fails E2E ISOLATION FAILED"; exit 1; }
