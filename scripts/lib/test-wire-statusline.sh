#!/usr/bin/env bash
# Hermetic test for wire-statusline.sh (HIMMEL-359 / HIMMEL-718). No network,
# temp dir only. HIMMEL-718 Task 4.1 switched the command to the hud renderer
# (node) + added the .env extra-cmd gate + the dropped hud config.
#
# HIMMEL-2892: the hud config now lands under ${CLAUDE_CONFIG_DIR:-~/.claude},
# never beside the settings file — so every case that can reach the drop pins
# CLAUDE_CONFIG_DIR at a throwaway dir. Without that pin this suite would write
# into the RUNNER'S real ~/.claude/plugins/claude-hud/config.json.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/wire-statusline.sh"
REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. fresh file gets a valid hud statusLine + the extra-cmd gate.
bash "$HELPER" "$TMP/s1.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s1.json")" = "command" ] || fail "fresh type"
[ "$(jq -r .statusLine.command "$TMP/s1.json")" = 'node "/c/Users/me/himmel/marketplace/plugins/claude-hud/dist/index.js"' ] || fail "fresh command"
[ "$(jq -r .env.CLAUDE_HUD_ALLOW_EXTRA_CMD "$TMP/s1.json")" = "1" ] || fail "extra-cmd gate set"
echo "ok 1 fresh file"

# 2. existing keys preserved, incl. pre-existing .env keys (non-destructive merge)
echo '{"theme":"dark","hooks":{"PreToolUse":[1]},"env":{"CR_PROFILE":"paid"}}' > "$TMP/s2.json"
bash "$HELPER" "$TMP/s2.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .theme "$TMP/s2.json")" = "dark" ] || fail "theme preserved"
[ "$(jq -r '.hooks.PreToolUse[0]' "$TMP/s2.json")" = "1" ] || fail "hooks preserved"
[ "$(jq -r .env.CR_PROFILE "$TMP/s2.json")" = "paid" ] || fail "pre-existing env key preserved"
[ "$(jq -r .env.CLAUDE_HUD_ALLOW_EXTRA_CMD "$TMP/s2.json")" = "1" ] || fail "extra-cmd gate merged"
[ "$(jq -r .statusLine.type "$TMP/s2.json")" = "command" ] || fail "statusLine added"
echo "ok 2 existing keys preserved"

# 3. idempotent
bash "$HELPER" "$TMP/s3.json" "/c/Users/me/himmel" >/dev/null
A="$(cat "$TMP/s3.json")"
bash "$HELPER" "$TMP/s3.json" "/c/Users/me/himmel" >/dev/null
[ "$A" = "$(cat "$TMP/s3.json")" ] || fail "not idempotent"
echo "ok 3 idempotent"

# 4. backslash himmel path normalized to forward slashes
bash "$HELPER" "$TMP/s4.json" 'C:\Users\me\himmel' >/dev/null
[ "$(jq -r .statusLine.command "$TMP/s4.json")" = 'node "C:/Users/me/himmel/marketplace/plugins/claude-hud/dist/index.js"' ] || fail "backslash normalize"
echo "ok 4 backslash normalized"

# 5. overwrites a stale statusLine (authoritative)
echo '{"statusLine":{"type":"command","command":"OLD"}}' > "$TMP/s5.json"
bash "$HELPER" "$TMP/s5.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.command "$TMP/s5.json")" != "OLD" ] || fail "stale not refreshed"
echo "ok 5 stale refreshed"

# 6. empty file → treated as {}, gets a valid statusLine (gemini-1/2)
: > "$TMP/s6.json"
bash "$HELPER" "$TMP/s6.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s6.json")" = "command" ] || fail "empty file not handled"
echo "ok 6 empty file handled"

# 7. non-empty INVALID json → refuse (exit non-zero), do not clobber
printf '{not valid' > "$TMP/s7.json"
if bash "$HELPER" "$TMP/s7.json" "/c/Users/me/himmel" >/dev/null 2>&1; then
  fail "invalid json was not refused"
fi
[ "$(cat "$TMP/s7.json")" = '{not valid' ] || fail "invalid json was clobbered"
echo "ok 7 invalid json refused"

# 8. whitespace-only file (non-empty bytes, all blank) → treated as {}
printf '  \n\t ' > "$TMP/s8.json"
bash "$HELPER" "$TMP/s8.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s8.json")" = "command" ] || fail "whitespace-only not handled"
echo "ok 8 whitespace-only handled"

# 9. nested parent dir created when absent
bash "$HELPER" "$TMP/nested/deep/s9.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/nested/deep/s9.json")" = "command" ] || fail "nested dir not created"
echo "ok 9 nested parent dir created"

# 10. hud config dropped under CLAUDE_CONFIG_DIR with <himmel-path> SUBSTITUTED.
# Uses the REAL himmel clone so the source himmel-config.json exists.
sdir="$TMP/cfgdrop"
cfgdir="$TMP/cfgdrop-config"
CLAUDE_CONFIG_DIR="$cfgdir" bash "$HELPER" "$sdir/settings.json" "$REPO_ROOT" >/dev/null
dropped="$cfgdir/plugins/claude-hud/config.json"
[ -f "$dropped" ] || fail "hud config not dropped under CLAUDE_CONFIG_DIR"
jq -e . "$dropped" >/dev/null 2>&1 || fail "dropped config not valid JSON"
grep -q '<himmel-path>' "$dropped" && fail "placeholder <himmel-path> left in dropped config"
grep -qF "$REPO_ROOT" "$dropped" || fail "real himmel path not substituted into dropped config"
[ "$(jq -r .statusLine.command "$sdir/settings.json")" = "node \"$REPO_ROOT/marketplace/plugins/claude-hud/dist/index.js\"" ] || fail "command not node w/ real path"
[ "$(jq -r .display.showPromptCache "$dropped")" = "true" ] || fail "dropped config missing showPromptCache: true"
echo "ok 10 hud config dropped under CLAUDE_CONFIG_DIR + substituted"

# 11. config drop is idempotent too (deterministic)
B="$(cat "$dropped")"
CLAUDE_CONFIG_DIR="$cfgdir" bash "$HELPER" "$sdir/settings.json" "$REPO_ROOT" >/dev/null
[ "$B" = "$(cat "$dropped")" ] || fail "config drop not idempotent"
echo "ok 11 config drop idempotent"

# 12. HIMMEL-2892 RED control: a PROJECT settings path must leave NOTHING under
# the project dir — the hud config is per-user config and belongs in the config
# dir even when the caller hands us a repo-local settings.json. This is the
# 2026-09-09 dogfood incident: `himmelctl install --scope project` dropped an
# untracked .claude/plugins/claude-hud/config.json inside the himmel repo.
proj12="$TMP/proj12"
cfg12="$TMP/cfg12"
mkdir -p "$proj12/.claude"
CLAUDE_CONFIG_DIR="$cfg12" bash "$HELPER" "$proj12/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ ! -e "$proj12/.claude/plugins" ] \
  || fail "hud config dropped INSIDE the project dir ($proj12/.claude/plugins) — it belongs under the config dir"
[ -f "$cfg12/plugins/claude-hud/config.json" ] \
  || fail "hud config not written under CLAUDE_CONFIG_DIR ($cfg12) for a project settings path"
[ "$(jq -r .statusLine.type "$proj12/.claude/settings.json")" = "command" ] \
  || fail "project settings.json did not get its statusLine"
echo "ok 12 project settings path: hud config lands under the config dir, nothing inside the repo"

# 13. no CLAUDE_CONFIG_DIR -> \$HOME/.claude (the documented default). HOME is
# faked so this never touches the runner's real config dir.
home13="$TMP/home13"; mkdir -p "$home13"
proj13="$TMP/proj13"; mkdir -p "$proj13/.claude"
env -u CLAUDE_CONFIG_DIR HOME="$home13" bash "$HELPER" "$proj13/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ -f "$home13/.claude/plugins/claude-hud/config.json" ] \
  || fail "with CLAUDE_CONFIG_DIR unset the hud config should land under \$HOME/.claude"
[ ! -e "$proj13/.claude/plugins" ] || fail "hud config leaked into the project dir with CLAUDE_CONFIG_DIR unset"
echo "ok 13 CLAUDE_CONFIG_DIR unset falls back to \$HOME/.claude"

# 14. CR (CodeRabbit) round 1: CLAUDE_CONFIG_DIR is TRIMMED, matching the hud's
# own getClaudeConfigDir (`process.env.CLAUDE_CONFIG_DIR?.trim()`). A PADDED
# value must resolve to the same directory as the unpadded one — otherwise the
# installer writes the config somewhere the hud never reads it.
padded_cfg="$TMP/cfg14"
proj14="$TMP/proj14"; mkdir -p "$proj14/.claude"
CLAUDE_CONFIG_DIR="   $padded_cfg   " bash "$HELPER" "$proj14/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ -f "$padded_cfg/plugins/claude-hud/config.json" ] \
  || fail "a PADDED CLAUDE_CONFIG_DIR must resolve to the same dir the hud reads (expected $padded_cfg)"
[ ! -e "$TMP/   $padded_cfg" ] || fail "padded CLAUDE_CONFIG_DIR leaked its whitespace into the path"
echo "ok 14 padded CLAUDE_CONFIG_DIR is trimmed"

# 15. ...and a WHITESPACE-ONLY value is treated as UNSET (the hud's trim makes
# it falsy). Without the trim, bash resolves a RELATIVE directory literally
# named with spaces, under whatever the cwd happens to be.
home15="$TMP/home15"; mkdir -p "$home15"
proj15="$TMP/proj15"; mkdir -p "$proj15/.claude"
CLAUDE_CONFIG_DIR="   " HOME="$home15" bash "$HELPER" "$proj15/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ -f "$home15/.claude/plugins/claude-hud/config.json" ] \
  || fail "a whitespace-only CLAUDE_CONFIG_DIR must fall back to \$HOME/.claude"
[ ! -e "$proj15/.claude/plugins" ] || fail "whitespace-only CLAUDE_CONFIG_DIR leaked the hud config into the project dir"
echo "ok 15 whitespace-only CLAUDE_CONFIG_DIR falls back to \$HOME/.claude"

# ── HIMMEL-3065: the hud's RUNTIME cache state is dropped when the wiring
# CHANGES, and only then. The dir under test is the hud's own plugin dir
# (${CLAUDE_CONFIG_DIR}/plugins/claude-hud) — config.json is settings this
# script owns; everything beside it is per-session snapshot state that must not
# survive a migration onto a different install.

# Seed the three cache dirs + the two ledgers the hud writes, with one file
# under each dir, so a purge is observable per-entry rather than only per-dir.
seed_hud_cache() {
  local dir="$1" sub
  for sub in transcript-cache context-cache config-cache; do
    mkdir -p "$dir/$sub"
    printf '{"stale":true}' > "$dir/$sub/deadbeef.json"
  done
  printf '{"reads":1,"writes":2,"inputs":3,"computedAt":1}' > "$dir/cache-economics-all.json"
  printf '{"date":"20260101","sessions":{}}' > "$dir/daily-cost.json"
}

# 16. migration: an EARLIER install's statusLine command is already wired and
# the hud plugin dir is full of that install's snapshots. Re-wiring onto this
# clone must drop every one of them — the macOS report: an expired cache clock,
# the previous install's counts, and no cost figure.
cfg16="$TMP/cfg16"; hud16="$cfg16/plugins/claude-hud"
proj16="$TMP/proj16"; mkdir -p "$proj16/.claude"
s16="$proj16/.claude/settings.json"
echo '{"statusLine":{"type":"command","command":"node \"/old/himmel/marketplace/plugins/claude-hud/dist/index.js\""}}' > "$s16"
seed_hud_cache "$hud16"
CLAUDE_CONFIG_DIR="$cfg16" bash "$HELPER" "$s16" "$REPO_ROOT" >/dev/null
[ ! -e "$hud16/transcript-cache" ] || fail "16: transcript-cache survived a changed wiring"
[ ! -e "$hud16/context-cache" ]    || fail "16: context-cache survived a changed wiring"
[ ! -e "$hud16/config-cache" ]     || fail "16: config-cache survived a changed wiring"
[ ! -e "$hud16/cache-economics-all.json" ] || fail "16: cache-economics ledger survived a changed wiring"
[ ! -e "$hud16/daily-cost.json" ]  || fail "16: daily-cost ledger survived a changed wiring"
[ -f "$hud16/config.json" ] || fail "16: config.json must SURVIVE the purge — this script owns it"
jq -e . "$hud16/config.json" >/dev/null 2>&1 || fail "16: surviving config.json is not valid JSON"
echo "ok 16 changed wiring drops the hud cache state, keeps config.json"

# 17. steady state: the SAME clone re-wired over its own wiring changes nothing,
# so the caches stay. Without this, every himmel-update would throw away the
# context fallback snapshot of every live session.
seed_hud_cache "$hud16"
CLAUDE_CONFIG_DIR="$cfg16" bash "$HELPER" "$s16" "$REPO_ROOT" >/dev/null
[ -f "$hud16/transcript-cache/deadbeef.json" ] || fail "17: an unchanged re-wire purged the transcript cache"
[ -f "$hud16/context-cache/deadbeef.json" ]    || fail "17: an unchanged re-wire purged the context cache"
[ -f "$hud16/daily-cost.json" ]                || fail "17: an unchanged re-wire purged the daily-cost ledger"
echo "ok 17 unchanged re-wire preserves the hud cache state"

# 18. the CONFIG half on its own: same command, but the hud config on disk is
# the earlier install's. An older himmel instance ships an older
# himmel-config.json, so this is the migration case where the clone path
# happens to be unchanged.
printf '{"display":{"showPromptCache":false}}\n' > "$hud16/config.json"
seed_hud_cache "$hud16"
CLAUDE_CONFIG_DIR="$cfg16" bash "$HELPER" "$s16" "$REPO_ROOT" >/dev/null
[ ! -e "$hud16/transcript-cache" ] || fail "18: a stale hud config did not trigger the purge"
[ "$(jq -r .display.showPromptCache "$hud16/config.json")" = "true" ] || fail "18: hud config not refreshed"
echo "ok 18 a changed hud config drops the cache state"

# 19. a MOVED/renamed clone (the command half on its own), with the hud config
# source absent on both sides — a synthetic himmel path never drops a config, so
# the command comparison has to carry the decision by itself.
cfg19="$TMP/cfg19"; hud19="$cfg19/plugins/claude-hud"
proj19="$TMP/proj19"; mkdir -p "$proj19/.claude"
s19="$proj19/.claude/settings.json"
CLAUDE_CONFIG_DIR="$cfg19" bash "$HELPER" "$s19" "/old/path/himmel" >/dev/null
seed_hud_cache "$hud19"
CLAUDE_CONFIG_DIR="$cfg19" bash "$HELPER" "$s19" "/new/path/himmel" >/dev/null
[ ! -e "$hud19/transcript-cache" ] || fail "19: a moved clone did not drop the hud cache state"
[ ! -e "$hud19/daily-cost.json" ]  || fail "19: a moved clone did not drop the daily-cost ledger"
echo "ok 19 a moved himmel clone drops the hud cache state"

# 20. the purge never reaches outside the hud plugin dir: Claude Code keeps its
# real plugin installs (installed_plugins.json, marketplaces/) as siblings.
cfg20="$TMP/cfg20"; hud20="$cfg20/plugins/claude-hud"
proj20="$TMP/proj20"; mkdir -p "$proj20/.claude" "$cfg20/plugins/marketplaces/m1"
s20="$proj20/.claude/settings.json"
printf 'keep me\n' > "$cfg20/plugins/installed_plugins.json"
printf 'keep me\n' > "$cfg20/plugins/marketplaces/m1/plugin.json"
seed_hud_cache "$hud20"
CLAUDE_CONFIG_DIR="$cfg20" bash "$HELPER" "$s20" "$REPO_ROOT" >/dev/null
[ -f "$cfg20/plugins/installed_plugins.json" ] || fail "20: purge deleted a sibling of the hud plugin dir"
[ -f "$cfg20/plugins/marketplaces/m1/plugin.json" ] || fail "20: purge reached into another plugin's dir"
[ ! -e "$hud20/transcript-cache" ] || fail "20: purge did not run for a first-time wire"
echo "ok 20 purge stays inside the hud plugin dir"

echo "ALL PASS"
