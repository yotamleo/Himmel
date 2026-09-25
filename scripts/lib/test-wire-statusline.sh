#!/usr/bin/env bash
# Hermetic test for wire-statusline.sh (HIMMEL-359 / HIMMEL-718). No network,
# temp dir only. HIMMEL-718 Task 4.1 switched the command to the hud renderer
# (node) + added the .env extra-cmd gate + the dropped hud config.
#
# HIMMEL-2892: the hud config now lands under ${CLAUDE_CONFIG_DIR:-~/.claude},
# never beside the settings file — so every case that can reach the drop pins
# CLAUDE_CONFIG_DIR at a throwaway dir. Without that pin this suite would write
# into the RUNNER'S real ~/.claude/claude-hud.json.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/wire-statusline.sh"
REPO_ROOT="$(cd -- "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
# HIMMEL-3332: the wire writes provenance rows; keep them out of the real ~/.himmel.
export HIMMEL_PROVENANCE_DIR="$TMP/prov"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
# HIMMEL-3332 (HIMMEL-3312): the statusLine command wire-statusline.sh writes —
# node on the hud renderer, guarded so a deleted clone renders nothing instead
# of failing on every session start.
guarded_cmd() {
  local js="$1/marketplace/plugins/claude-hud/dist/index.js"
  printf '[ -f "%s" ] && exec node "%s" || true' "$js" "$js"
}

# 1. fresh file gets a valid hud statusLine + the extra-cmd gate.
bash "$HELPER" "$TMP/s1.json" "/c/Users/me/himmel" >/dev/null
[ "$(jq -r .statusLine.type "$TMP/s1.json")" = "command" ] || fail "fresh type"
[ "$(jq -r .statusLine.command "$TMP/s1.json")" = "$(guarded_cmd /c/Users/me/himmel)" ] || fail "fresh command"
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
[ "$(jq -r .statusLine.command "$TMP/s4.json")" = "$(guarded_cmd C:/Users/me/himmel)" ] || fail "backslash normalize"
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
dropped="$cfgdir/claude-hud.json"
[ -f "$dropped" ] || fail "hud config not dropped under CLAUDE_CONFIG_DIR"
jq -e . "$dropped" >/dev/null 2>&1 || fail "dropped config not valid JSON"
grep -q '<himmel-path>' "$dropped" && fail "placeholder <himmel-path> left in dropped config"
grep -qF "$REPO_ROOT" "$dropped" || fail "real himmel path not substituted into dropped config"
[ "$(jq -r .statusLine.command "$sdir/settings.json")" = "$(guarded_cmd "$REPO_ROOT")" ] || fail "command not node w/ real path"
[ "$(jq -r .display.showPromptCache "$dropped")" = "true" ] || fail "dropped config missing showPromptCache: true"
[ ! -f "$cfgdir/plugins/claude-hud/config.json" ] \
  || fail "HIMMEL-3334: a fresh wire also (or instead) wrote the swept plugins/claude-hud/config.json path"
echo "ok 10 hud config dropped under CLAUDE_CONFIG_DIR + substituted, nothing under plugins/"

# 11. config drop is idempotent too (deterministic)
B="$(cat "$dropped")"
CLAUDE_CONFIG_DIR="$cfgdir" bash "$HELPER" "$sdir/settings.json" "$REPO_ROOT" >/dev/null
[ "$B" = "$(cat "$dropped")" ] || fail "config drop not idempotent"
echo "ok 11 config drop idempotent"

# 12. HIMMEL-2892 RED control: a PROJECT settings path must leave NOTHING under
# the project dir — the hud config is per-user config and belongs in the config
# dir even when the caller hands us a repo-local settings.json. This is the
# 2026-09-09 dogfood incident: `himmelctl install --scope project` dropped an
# untracked .claude/claude-hud.json inside the himmel repo.
proj12="$TMP/proj12"
cfg12="$TMP/cfg12"
mkdir -p "$proj12/.claude"
CLAUDE_CONFIG_DIR="$cfg12" bash "$HELPER" "$proj12/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ ! -e "$proj12/.claude/plugins" ] \
  || fail "hud config dropped INSIDE the project dir ($proj12/.claude/plugins) — it belongs under the config dir"
[ -f "$cfg12/claude-hud.json" ] \
  || fail "hud config not written under CLAUDE_CONFIG_DIR ($cfg12) for a project settings path"
[ "$(jq -r .statusLine.type "$proj12/.claude/settings.json")" = "command" ] \
  || fail "project settings.json did not get its statusLine"
echo "ok 12 project settings path: hud config lands under the config dir, nothing inside the repo"

# 13. no CLAUDE_CONFIG_DIR -> \$HOME/.claude (the documented default). HOME is
# faked so this never touches the runner's real config dir.
home13="$TMP/home13"; mkdir -p "$home13"
proj13="$TMP/proj13"; mkdir -p "$proj13/.claude"
env -u CLAUDE_CONFIG_DIR HOME="$home13" bash "$HELPER" "$proj13/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ -f "$home13/.claude/claude-hud.json" ] \
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
[ -f "$padded_cfg/claude-hud.json" ] \
  || fail "a PADDED CLAUDE_CONFIG_DIR must resolve to the same dir the hud reads (expected $padded_cfg)"
[ ! -e "$TMP/   $padded_cfg" ] || fail "padded CLAUDE_CONFIG_DIR leaked its whitespace into the path"
echo "ok 14 padded CLAUDE_CONFIG_DIR is trimmed"

# 15. ...and a WHITESPACE-ONLY value is treated as UNSET (the hud's trim makes
# it falsy). Without the trim, bash resolves a RELATIVE directory literally
# named with spaces, under whatever the cwd happens to be.
home15="$TMP/home15"; mkdir -p "$home15"
proj15="$TMP/proj15"; mkdir -p "$proj15/.claude"
CLAUDE_CONFIG_DIR="   " HOME="$home15" bash "$HELPER" "$proj15/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ -f "$home15/.claude/claude-hud.json" ] \
  || fail "a whitespace-only CLAUDE_CONFIG_DIR must fall back to \$HOME/.claude"
[ ! -e "$proj15/.claude/plugins" ] || fail "whitespace-only CLAUDE_CONFIG_DIR leaked the hud config into the project dir"
echo "ok 15 whitespace-only CLAUDE_CONFIG_DIR falls back to \$HOME/.claude"

# ── HIMMEL-3065: the hud's RUNTIME cache state is dropped when the wiring
# CHANGES, and only then. The dir under test is the hud's own plugin dir
# (${CLAUDE_CONFIG_DIR}/plugins/claude-hud) — HIMMEL-3334 moved the config this
# script owns to a sibling path (${CLAUDE_CONFIG_DIR}/claude-hud.json), never
# inside this dir; everything still under it is per-session snapshot state that
# must not survive a migration onto a different install.

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
[ -f "$cfg16/claude-hud.json" ] || fail "16: config.json must SURVIVE the purge — this script owns it"
jq -e . "$cfg16/claude-hud.json" >/dev/null 2>&1 || fail "16: surviving config.json is not valid JSON"
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
printf '{"display":{"showPromptCache":false}}\n' > "$cfg16/claude-hud.json"
seed_hud_cache "$hud16"
CLAUDE_CONFIG_DIR="$cfg16" bash "$HELPER" "$s16" "$REPO_ROOT" >/dev/null
[ ! -e "$hud16/transcript-cache" ] || fail "18: a stale hud config did not trigger the purge"
[ "$(jq -r .display.showPromptCache "$cfg16/claude-hud.json")" = "true" ] || fail "18: hud config not refreshed"
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

# 21. CR round 1 [codex-2]: the two halves have different SCOPES — the hud
# config is per-USER, but the settings file may be a PROJECT one. Wiring a
# machine's SECOND project (same clone, same hud config, a project settings
# file with no statusLine of its own) is not a migration, and must not purge
# the caches every other project's live session is using.
cfg21="$TMP/cfg21"; hud21="$cfg21/plugins/claude-hud"
proj21a="$TMP/proj21a"; mkdir -p "$proj21a/.claude"
proj21b="$TMP/proj21b"; mkdir -p "$proj21b/.claude"
CLAUDE_CONFIG_DIR="$cfg21" bash "$HELPER" "$proj21a/.claude/settings.json" "$REPO_ROOT" >/dev/null
seed_hud_cache "$hud21"
CLAUDE_CONFIG_DIR="$cfg21" bash "$HELPER" "$proj21b/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ -f "$hud21/transcript-cache/deadbeef.json" ] \
  || fail "21: wiring a second PROJECT on the same install purged the per-user cache state"
[ -f "$hud21/daily-cost.json" ] || fail "21: second-project wire purged the daily-cost ledger"
echo "ok 21 a second project on the same install preserves the hud cache state"

# 22. ...and the migration it must still catch on that same path: a project
# wired against an OLD clone. The dropped config embeds the clone path, so the
# config half differs even though this project's settings file is new.
cfg22="$TMP/cfg22"; hud22="$cfg22/plugins/claude-hud"
proj22="$TMP/proj22"; mkdir -p "$proj22/.claude"
mkdir -p "$hud22"
printf '{"display":{"showPromptCache":true},"customLineCommand":"/old/clone/x.sh"}\n' > "$cfg22/claude-hud.json"
seed_hud_cache "$hud22"
CLAUDE_CONFIG_DIR="$cfg22" bash "$HELPER" "$proj22/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ ! -e "$hud22/transcript-cache" ] \
  || fail "22: a config from an OLD clone did not trigger the purge on a fresh project settings file"
echo "ok 22 an old clone's hud config still purges on a fresh project wire"

# 23. CR round 2: a FAILED purge must abort the wire with nothing published, so
# the retry still sees a changed wiring and tries again. Publishing first left a
# failed purge unrepeatable — the next run saw wiring that already matched, took
# the no-change path, and the stale state survived every run after that.
#
# The failure is injected with a PATH `rm` stub that refuses ONLY the seeded
# cache entries and delegates everything else to the real rm (CodeRabbit, PR
# #772). An earlier version made the hud dir read-only instead, which stopped
# being a control the moment round 6 moved staging ahead of the purge: staging
# used to write .config.json.tmp INTO that dir, so the wire failed before the
# purge was ever reached and the case passed without exercising the path it
# names (HIMMEL-3334 moved the staged config out to the config dir root, but
# the stub stays the more direct control either way). The stub also keeps the
# case meaningful as root and on Git Bash, where directory permissions do not
# bind the same way. The asserted precondition is that the staged config was
# cleaned up — that only happens on the purge-failure path.
rm_bin23="$TMP/rm23-bin"; mkdir -p "$rm_bin23"
real_rm23="$(command -v rm)"
cfg23="$TMP/cfg23"; hud23="$cfg23/plugins/claude-hud"
proj23="$TMP/proj23"; mkdir -p "$proj23/.claude"
s23="$proj23/.claude/settings.json"
old23='node "/old/himmel/marketplace/plugins/claude-hud/dist/index.js"'
# An earlier install: its command is wired, its config and snapshots are on disk.
printf '{"statusLine":{"type":"command","command":%s}}\n' "\"$(printf '%s' "$old23" | sed 's/"/\\"/g')\"" > "$s23"
mkdir -p "$hud23"
printf '{"display":{"showPromptCache":false}}\n' > "$cfg23/claude-hud.json"
seed_hud_cache "$hud23"

# The stub TOUCHES a marker before refusing, so the case can assert the purge
# was actually reached rather than inferring it (CR round 11): a staging failure
# would satisfy every other assertion below just as well.
rm_marker23="$TMP/rm23-was-called"
cat > "$rm_bin23/rm" <<EOF
#!/usr/bin/env bash
# Refuse exactly the seeded cache entries; everything else (the staged config,
# the settings temp file) goes to the real rm.
for _a in "\$@"; do
  case "\$_a" in
    "$hud23/transcript-cache"|"$hud23/context-cache"|"$hud23/config-cache"|\\
    "$hud23/cache-economics-all.json"|"$hud23/daily-cost.json")
      : > "$rm_marker23"
      exit 1 ;;
  esac
done
exec "$real_rm23" "\$@"
EOF
chmod +x "$rm_bin23/rm"

rc23=0
PATH="$rm_bin23:$PATH" CLAUDE_CONFIG_DIR="$cfg23" bash "$HELPER" "$s23" "$REPO_ROOT" >/dev/null 2>&1 || rc23=$?
[ "$rc23" -ne 0 ] || fail "23: a failed purge must fail the wire, not report success"
[ -e "$rm_marker23" ] \
  || fail "23: precondition — the purge was never reached; this case proves nothing about a failed purge"
[ ! -e "$cfg23/claude-hud.json.tmp" ] \
  || fail "23: the staged config was left behind after the failed purge"
[ ! -e "$s23.statusline.tmp" ] || fail "23: the staged settings file was left behind"
[ "$(jq -r .statusLine.command "$s23")" = "$old23" ] \
  || fail "23: the settings file was published despite the failed purge — the retry will see no change"
[ "$(jq -r .display.showPromptCache "$cfg23/claude-hud.json")" = "false" ] \
  || fail "23: the hud config was published despite the failed purge"
[ -e "$hud23/transcript-cache" ] || fail "23: the seeded cache dir should have survived the failed purge"
[ -e "$hud23/daily-cost.json" ] || fail "23: the seeded ledger should have survived the failed purge"

# The retry, without the stub on PATH, still sees the same changed wiring.
CLAUDE_CONFIG_DIR="$cfg23" bash "$HELPER" "$s23" "$REPO_ROOT" >/dev/null
[ ! -e "$hud23/transcript-cache" ] || fail "23: the retry did not purge — the failure was not repeatable"
[ "$(jq -r .statusLine.command "$s23")" != "$old23" ] || fail "23: the retry did not wire"
echo "ok 23 a failed purge aborts the wire and the retry still purges"

# 24. CR round 3 [codex-2]: this library is SOURCED (himmel-update.sh does), so
# the purge cannot rely on the caller's glob settings to skip the staged config.
# With `shopt -s dotglob`, `"$hud_dir"/*` used to match .config.json.tmp before
# HIMMEL-3334 moved staging to the config-dir root (a sibling of $hud_dir, never
# inside it) — the purge-skip guard for config.json/.* stays as belt-and-braces
# for a leftover pre-migration file, and this case still proves dotglob can't
# make the purge eat live config, staged or not.
cfg24="$TMP/cfg24"; hud24="$cfg24/plugins/claude-hud"
proj24="$TMP/proj24"; mkdir -p "$proj24/.claude"
s24="$proj24/.claude/settings.json"
mkdir -p "$hud24"
printf '{"display":{"showPromptCache":false}}\n' > "$cfg24/claude-hud.json"
seed_hud_cache "$hud24"
(
  shopt -s dotglob
  # shellcheck disable=SC1090  # the helper under test, resolved at runtime
  . "$HELPER"
  # shellcheck disable=SC2030,SC2031  # deliberately subshell-local: the sourced
  # helper must see it, the surrounding suite must not.
  export CLAUDE_CONFIG_DIR="$cfg24"
  wire_statusline "$s24" "$REPO_ROOT"
) >/dev/null || fail "24: sourced wire_statusline failed under dotglob"
[ -f "$cfg24/claude-hud.json" ] || fail "24: the staged config was purged under dotglob — nothing published"
[ "$(jq -r .display.showPromptCache "$cfg24/claude-hud.json")" = "true" ] \
  || fail "24: the published config under dotglob is not this clone's"
[ ! -e "$hud24/transcript-cache" ] || fail "24: the purge itself did not run under dotglob"
echo "ok 24 the purge skips the staged config even with dotglob set"

# 25. CR round 5: publish the config THIS call staged, never one a previous
# call left behind. A run that staged the config and then failed on the settings
# write used to leave .config.json.tmp in place, and the next source-absent call
# (a synthetic himmel path, which promises to be a pure statusLine/env op)
# published that stale file as the machine's hud config.
cfg25="$TMP/cfg25"; hud25="$cfg25/plugins/claude-hud"
proj25="$TMP/proj25"; mkdir -p "$proj25/.claude"
mkdir -p "$hud25"
printf '{"display":{"showPromptCache":"STALE-STAGED"}}\n' > "$cfg25/claude-hud.json.tmp"
CLAUDE_CONFIG_DIR="$cfg25" bash "$HELPER" "$proj25/.claude/settings.json" "/synthetic/himmel" >/dev/null
[ ! -e "$cfg25/claude-hud.json" ] \
  || fail "25: a source-absent wire published a temp file a previous call left behind"
[ "$(jq -r .statusLine.type "$proj25/.claude/settings.json")" = "command" ] \
  || fail "25: the source-absent wire should still do its statusLine/env half"
echo "ok 25 a source-absent wire never publishes a leftover staged config"

# 26. CR round 6: a settings file that PARSES but cannot take the transform —
# `{"env":"invalid"}` is valid JSON, yet `.env.KEY = …` cannot be assigned into
# a string — must abort before the purge, not after it. Staging the transform
# first is what makes the whole "purge ran, publish failed" class impossible
# rather than fixed one instance at a time.
cfg26="$TMP/cfg26"; hud26="$cfg26/plugins/claude-hud"
proj26="$TMP/proj26"; mkdir -p "$proj26/.claude"
s26="$proj26/.claude/settings.json"
old26='node "/old/himmel/marketplace/plugins/claude-hud/dist/index.js"'
printf '{"env":"invalid","statusLine":{"type":"command","command":%s}}\n' "\"$(printf '%s' "$old26" | sed 's/"/\\"/g')\"" > "$s26"
mkdir -p "$hud26"
seed_hud_cache "$hud26"
rc26=0
CLAUDE_CONFIG_DIR="$cfg26" bash "$HELPER" "$s26" "$REPO_ROOT" >/dev/null 2>&1 || rc26=$?
[ "$rc26" -ne 0 ] || fail "26: an untransformable settings file must fail the wire"
[ -f "$hud26/transcript-cache/deadbeef.json" ] \
  || fail "26: live cache state was purged for a wire that could never publish"
[ "$(jq -r .statusLine.command "$s26")" = "$old26" ] || fail "26: the settings file was modified"
[ ! -e "$cfg26/claude-hud.json.tmp" ] || fail "26: the staged config was left behind"
echo "ok 26 an untransformable settings file aborts before the purge"

# 27. CodeRabbit round 2: the two publishes are two renames, not one atomic
# operation. They are ordered config-then-settings so that a failed SECOND one
# leaves the machine on its OLD statusLine command — the previous wiring, intact
# — which the next run still sees as changed and re-wires AND re-purges. The
# failure is injected with a PATH `mv` stub that refuses only the settings
# publish and delegates everything else.
mv_bin27="$TMP/mv27-bin"; mkdir -p "$mv_bin27"
real_mv27="$(command -v mv)"
cfg27="$TMP/cfg27"; hud27="$cfg27/plugins/claude-hud"
proj27="$TMP/proj27"; mkdir -p "$proj27/.claude"
s27="$proj27/.claude/settings.json"
old27='node "/old/himmel/marketplace/plugins/claude-hud/dist/index.js"'
printf '{"statusLine":{"type":"command","command":%s}}\n' "\"$(printf '%s' "$old27" | sed 's/"/\\"/g')\"" > "$s27"
mkdir -p "$hud27"
printf '{"display":{"showPromptCache":false}}\n' > "$cfg27/claude-hud.json"
seed_hud_cache "$hud27"

cat > "$mv_bin27/mv" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"$s27.statusline.tmp"*) exit 1 ;;
esac
exec "$real_mv27" "\$@"
EOF
chmod +x "$mv_bin27/mv"

rc27=0
PATH="$mv_bin27:$PATH" CLAUDE_CONFIG_DIR="$cfg27" bash "$HELPER" "$s27" "$REPO_ROOT" >/dev/null 2>&1 || rc27=$?
[ "$rc27" -ne 0 ] || fail "27: a failed settings publish must fail the wire"
[ "$(jq -r .statusLine.command "$s27")" = "$old27" ] \
  || fail "27: precondition — the settings publish is what failed, so the OLD command must still be wired"
[ ! -e "$s27.statusline.tmp" ] || fail "27: the staged settings file was left behind"
[ "$(jq -r .display.showPromptCache "$cfg27/claude-hud.json")" = "true" ] \
  || fail "27: the config publish ran first, so it should have landed"
[ ! -e "$hud27/transcript-cache" ] || fail "27: the purge runs before either publish and should have happened"

# The retry, without the stub, still sees a changed wiring via the command half
# (the config half now matches) and completes.
CLAUDE_CONFIG_DIR="$cfg27" bash "$HELPER" "$s27" "$REPO_ROOT" >/dev/null
[ "$(jq -r .statusLine.command "$s27")" != "$old27" ] || fail "27: the retry did not wire"
echo "ok 27 a failed settings publish leaves the OLD command wired and the retry completes"

# 28. CR round 11: the purge pins its own glob options, because this library is
# sourced and the caller's shopt settings would otherwise decide what the loop
# sees. `failglob` is the sharp one — a hud dir holding nothing but the staged
# dotfile makes "$hud_dir"/* an expansion ERROR that aborts the wire.
cfg28="$TMP/cfg28"; hud28="$cfg28/plugins/claude-hud"
proj28="$TMP/proj28"; mkdir -p "$proj28/.claude"
s28="$proj28/.claude/settings.json"
mkdir -p "$hud28"
(
  shopt -s failglob
  # shellcheck disable=SC1090  # the helper under test, resolved at runtime
  . "$HELPER"
  # shellcheck disable=SC2030,SC2031  # deliberately subshell-local: the sourced
  # helper must see it, the surrounding suite must not.
  export CLAUDE_CONFIG_DIR="$cfg28"
  wire_statusline "$s28" "$REPO_ROOT"
) >/dev/null || fail "28: sourced wire_statusline failed under failglob"

[ -f "$cfg28/claude-hud.json" ] || fail "28: the config was not published under failglob"
[ "$(jq -r .statusLine.type "$s28")" = "command" ] || fail "28: the statusLine was not wired under failglob"
echo "ok 28 the purge survives a caller's failglob on an otherwise-empty hud dir"

# 29. HIMMEL-3157: an operator-set HIMMEL_STATUSLINE_ECON=<val> prefix on the
# previous hud config's .display.customLineCommand must be carried forward
# across a rewire — dropping it lets the suppressed HUD economics rows come
# back on every run (the operator's own report).
cfg29="$TMP/cfg29"; hud29="$cfg29/plugins/claude-hud"
proj29="$TMP/proj29"; mkdir -p "$proj29/.claude" "$hud29"
s29="$proj29/.claude/settings.json"
printf '{"display":{"customLineCommand":"HIMMEL_STATUSLINE_ECON=off bash \\"/old/himmel/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$cfg29/claude-hud.json"
CLAUDE_CONFIG_DIR="$cfg29" bash "$HELPER" "$s29" "$REPO_ROOT" >/dev/null
newcmd29="$(jq -r .display.customLineCommand "$cfg29/claude-hud.json")"
case "$newcmd29" in
  "HIMMEL_STATUSLINE_ECON=off "*) : ;;
  *) fail "29: HIMMEL_STATUSLINE_ECON=off prefix was not carried forward" ;;
esac
case "$newcmd29" in
  *"$REPO_ROOT/scripts/statusline/hud-custom-lines.sh"*) : ;;
  *) fail "29: carried prefix did not still point at the new himmel path" ;;
esac
echo "ok 29 HIMMEL_STATUSLINE_ECON prefix carried forward across a rewire"

# 30. ...and with no prefix on the previous config, the rewire yields the bare
# template command unchanged (no prefix invented out of nowhere).
cfg30="$TMP/cfg30"; hud30="$cfg30/plugins/claude-hud"
proj30="$TMP/proj30"; mkdir -p "$proj30/.claude" "$hud30"
s30="$proj30/.claude/settings.json"
printf '{"display":{"customLineCommand":"bash \\"/old/himmel/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$cfg30/claude-hud.json"
CLAUDE_CONFIG_DIR="$cfg30" bash "$HELPER" "$s30" "$REPO_ROOT" >/dev/null
expected30="bash \"$REPO_ROOT/scripts/statusline/hud-custom-lines.sh\""
[ "$(jq -r .display.customLineCommand "$cfg30/claude-hud.json")" = "$expected30" ] \
  || fail "30: no-prefix rewire should yield the bare template command"
echo "ok 30 no prefix on the previous config leaves the bare template command"

# 31. ...and a foreign or malformed prefix is never carried — only the exact
# HIMMEL_STATUSLINE_ECON=<alnum> shape is recognized.
cfg31="$TMP/cfg31"; hud31="$cfg31/plugins/claude-hud"
proj31="$TMP/proj31"; mkdir -p "$proj31/.claude" "$hud31"
s31="$proj31/.claude/settings.json"
printf '{"display":{"customLineCommand":"FOO=1 bash \\"/old/himmel/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$cfg31/claude-hud.json"
CLAUDE_CONFIG_DIR="$cfg31" bash "$HELPER" "$s31" "$REPO_ROOT" >/dev/null
expected31="bash \"$REPO_ROOT/scripts/statusline/hud-custom-lines.sh\""
[ "$(jq -r .display.customLineCommand "$cfg31/claude-hud.json")" = "$expected31" ] \
  || fail "31: a foreign FOO=1 prefix must not be carried"
echo "ok 31a a foreign prefix is not carried"

cfg31b="$TMP/cfg31b"; hud31b="$cfg31b/plugins/claude-hud"
proj31b="$TMP/proj31b"; mkdir -p "$proj31b/.claude" "$hud31b"
s31b="$proj31b/.claude/settings.json"
# shellcheck disable=SC2016  # literal $(x) fixture text, not meant to expand
printf '{"display":{"customLineCommand":"HIMMEL_STATUSLINE_ECON=$(x) bash \\"/old/himmel/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$cfg31b/claude-hud.json"
CLAUDE_CONFIG_DIR="$cfg31b" bash "$HELPER" "$s31b" "$REPO_ROOT" >/dev/null
[ "$(jq -r .display.customLineCommand "$cfg31b/claude-hud.json")" = "$expected31" ] \
  || fail "31b: a malformed HIMMEL_STATUSLINE_ECON=\$(x) prefix must not be carried"
echo "ok 31b a malformed HIMMEL_STATUSLINE_ECON value is not carried"

# 32. HIMMEL-3070: a hud dir that is writable but NOT enumerable (mode 300) globs
# to zero entries, so the sweep used to see "nothing to drop" and report success
# while the stale caches stayed on disk — and the wire published over them. It
# must fail like a failed removal does. Staging still succeeds (mode 300 can
# create the dotfile), so the wire reaches the purge; the precondition below
# proves the directory really is unenumerable (permissions do not bind as root
# or on Git Bash, where this case would prove nothing and self-skips).
cfg32="$TMP/cfg32"; hud32="$cfg32/plugins/claude-hud"
proj32="$TMP/proj32"; mkdir -p "$proj32/.claude"
s32="$proj32/.claude/settings.json"
old32='node "/old/himmel/marketplace/plugins/claude-hud/dist/index.js"'
printf '{"statusLine":{"type":"command","command":%s}}\n' "\"$(printf '%s' "$old32" | sed 's/"/\\"/g')\"" > "$s32"
mkdir -p "$hud32"
printf '{"display":{"showPromptCache":false}}\n' > "$cfg32/claude-hud.json"
seed_hud_cache "$hud32"
chmod 300 "$hud32"
if ls "$hud32" >/dev/null 2>&1; then
  chmod 700 "$hud32"
  echo "ok 32 (skipped: directory permissions do not bind here, uid $(id -u))"
else
  rc32=0
  err32="$(CLAUDE_CONFIG_DIR="$cfg32" bash "$HELPER" "$s32" "$REPO_ROOT" 2>&1 >/dev/null)" || rc32=$?
  chmod 700 "$hud32"
  [ "$rc32" -ne 0 ] || fail "32: an unenumerable hud dir must fail the purge, not report success"
  case "$err32" in
    *"$hud32"*) : ;;
    *) fail "32: the failure must name the unreadable directory (got: $err32)" ;;
  esac
  [ ! -e "$cfg32/claude-hud.json.tmp" ] || fail "32: the staged config was left behind after the failed purge"
  [ ! -e "$s32.statusline.tmp" ] || fail "32: the staged settings file was left behind"
  [ "$(jq -r .statusLine.command "$s32")" = "$old32" ] \
    || fail "32: the settings file was published despite the failed purge — the retry will see no change"
  [ "$(jq -r .display.showPromptCache "$cfg32/claude-hud.json")" = "false" ] \
    || fail "32: the hud config was published despite the failed purge"
  [ -e "$hud32/transcript-cache" ] || fail "32: the seeded cache dir should still be there"
  # Readable again, the retry sees the same changed wiring and purges.
  CLAUDE_CONFIG_DIR="$cfg32" bash "$HELPER" "$s32" "$REPO_ROOT" >/dev/null
  [ ! -e "$hud32/transcript-cache" ] || fail "32: the retry did not purge once the dir was readable"
  echo "ok 32 an unenumerable hud dir fails the purge and the retry still purges"
fi

# 33-36. HIMMEL-3332 S4: the hud config drop records `file create|replace|noop`
# (row hud-config, scope user, class code, backup on replace) and the cache purge
# records a `tree` row class state.
hud_rows() { jq -c --arg p "$1" 'select(.kind == "file" and (.path | endswith($p)))' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl"; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
cfg33="$TMP/cfg33"; hud33="$cfg33/plugins/claude-hud"
proj33="$TMP/proj33"; mkdir -p "$proj33/.claude" "$hud33"
s33="$proj33/.claude/settings.json"
# a user-edited config: their own customLineCommand, plus a display key of theirs
printf '{"display":{"customLineCommand":"echo mine","showPromptCache":false}}\n' > "$cfg33/claude-hud.json"
chmod 640 "$cfg33/claude-hud.json"
seed33="$(sha_of "$cfg33/claude-hud.json")"
CLAUDE_CONFIG_DIR="$cfg33" bash "$HELPER" "$s33" "$REPO_ROOT" >/dev/null
row33="$(hud_rows "cfg33/claude-hud.json")"
[ "$(printf '%s\n' "$row33" | grep -c .)" = 1 ] || fail "33: want exactly one hud config file row, got: $row33"
[ "$(printf '%s' "$row33" | jq -r '[.op, .scope, .class, .manifest_row, .pre.state, .pre.sha, .pre.mode] | join(",")')" \
  = "replace,user,code,hud-config,present,$seed33,0640" ] \
  || fail "33: the hud config replace row is wrong: $row33"
bk33="$(printf '%s' "$row33" | jq -r .pre.backup)"
[ "$([ -f "$bk33" ] && sha_of "$bk33")" = "$seed33" ] || fail "33: the backup does not hold the user's prior config bytes ($bk33)"
[ "$(printf '%s' "$row33" | jq -r .post.sha)" = "$(sha_of "$cfg33/claude-hud.json")" ] \
  || fail "33: post.sha does not match the config that was published"
[ "$(jq -r .display.customLineCommand "$cfg33/claude-hud.json")" != "echo mine" ] \
  || fail "33: behaviour changed — the install must still overwrite the config"
echo "ok 33 a replaced hud config is recorded and its prior bytes are backed up"

cfg34="$TMP/cfg34"
proj34="$TMP/proj34"; mkdir -p "$proj34/.claude"
CLAUDE_CONFIG_DIR="$cfg34" bash "$HELPER" "$proj34/.claude/settings.json" "$REPO_ROOT" >/dev/null
row34="$(hud_rows "cfg34/claude-hud.json")"
[ "$(printf '%s' "$row34" | jq -r '[.op, .pre.state, .post.sha] | join(",")')" = "create,absent,$(sha_of "$cfg34/claude-hud.json")" ] \
  || fail "34: a first drop must record create/absent: $row34"
# 35. an unchanged re-wire is a noop, with no backup and no second purge
CLAUDE_CONFIG_DIR="$cfg34" bash "$HELPER" "$proj34/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ "$(hud_rows "cfg34/claude-hud.json" | tail -n 1 | jq -r '[.op, .pre.sha == .post.sha, .pre.backup] | map(tostring) | join(",")')" = "noop,true,null" ] \
  || fail "35: an unchanged hud config must record noop with pre.sha == post.sha and no backup"
echo "ok 34-35 a first hud config drop records create/absent and an unchanged re-wire records noop"

# 35b. same bytes, different mode: the publish resets the mode, so it is not a
# noop — the prior mode must be recoverable from a backup (copy_recorded parity).
mode35b="$(stat -c %a "$cfg34/claude-hud.json" 2>/dev/null || stat -f %Lp "$cfg34/claude-hud.json")"
if [ "$mode35b" = 640 ]; then want35b=600; else want35b=640; fi
chmod "$want35b" "$cfg34/claude-hud.json"
CLAUDE_CONFIG_DIR="$cfg34" bash "$HELPER" "$proj34/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ "$(hud_rows "cfg34/claude-hud.json" | tail -n 1 | jq -r '[.op, .pre.mode, (.pre.backup != null)] | map(tostring) | join(",")')" = "replace,0$want35b,true" ] \
  || fail "35b: a mode-only change must record replace with a backup, not noop: $(hud_rows "cfg34/claude-hud.json" | tail -n 1)"
echo "ok 35b a same-bytes hud config with a different mode records replace and a backup"

# 36. the purge, when the wiring changed, is one tree row class state
cfg36="$TMP/cfg36"; hud36="$cfg36/plugins/claude-hud"
proj36="$TMP/proj36"; mkdir -p "$proj36/.claude" "$hud36"
printf '{"display":{"showPromptCache":false}}\n' > "$cfg36/claude-hud.json"
seed_hud_cache "$hud36"
CLAUDE_CONFIG_DIR="$cfg36" bash "$HELPER" "$proj36/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ ! -e "$hud36/transcript-cache" ] || fail "36: precondition — the purge did not run"
tree36="$(jq -c --arg p "cfg36/plugins/claude-hud" 'select(.kind == "tree" and (.path | endswith($p)))' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl")"
[ "$(printf '%s\n' "$tree36" | grep -c .)" = 1 ] || fail "36: want exactly one purge tree row, got: $tree36"
[ "$(printf '%s' "$tree36" | jq -r '[.scope, .class, .manifest_row] | join(",")')" = "user,state,hud-config" ] \
  || fail "36: the purge tree row is wrong: $tree36"
# a wire that purged nothing records no tree row
CLAUDE_CONFIG_DIR="$cfg36" bash "$HELPER" "$proj36/.claude/settings.json" "$REPO_ROOT" >/dev/null
[ "$(jq -c --arg p "cfg36/plugins/claude-hud" 'select(.kind == "tree" and (.path | endswith($p)))' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" | grep -c .)" = 1 ] \
  || fail "36: a re-wire that purged nothing must not record another tree row"
echo "ok 36 a cache purge records one tree row class state and a no-purge wire records none"

# 37. HIMMEL-3363: when mktemp cannot allocate the purge listing, the purge must
# still run, but the skipped tree-row recording is announced like every other
# best-effort recording failure in the file (it used to be silent).
mk_bin37="$TMP/mktemp37-bin"; mkdir -p "$mk_bin37"
printf '#!/usr/bin/env bash\nexit 1\n' > "$mk_bin37/mktemp"; chmod +x "$mk_bin37/mktemp"
cfg37="$TMP/cfg37"; hud37="$cfg37/plugins/claude-hud"
proj37="$TMP/proj37"; mkdir -p "$proj37/.claude" "$hud37"
printf '{"display":{"showPromptCache":false}}\n' > "$cfg37/claude-hud.json"
seed_hud_cache "$hud37"
rc37=0
err37="$(PATH="$mk_bin37:$PATH" CLAUDE_CONFIG_DIR="$cfg37" bash "$HELPER" "$proj37/.claude/settings.json" "$REPO_ROOT" 2>&1 >/dev/null)" || rc37=$?
[ "$rc37" -eq 0 ] || fail "37: a mktemp failure must not fail the wire (rc=$rc37): $err37"
[ ! -e "$hud37/transcript-cache" ] || fail "37: the purge must still run when mktemp fails"
case "$err37" in
  *"wire-statusline: warning: provenance record skipped"*) ;;
  *) fail "37: no warning when the purge recording was skipped for a failed mktemp: $err37" ;;
esac
[ "$(jq -c --arg p "cfg37/plugins/claude-hud" 'select(.kind == "tree" and (.path | endswith($p)))' "$HIMMEL_PROVENANCE_DIR/provenance.jsonl" | grep -c .)" = 0 ] \
  || fail "37: no purge tree row can be recorded without a listing file"
echo "ok 37 a failed mktemp warns that the purge recording was skipped and still purges"

# 38. HIMMEL-3332 (HIMMEL-3312): the wired command degrades silently when the
# clone is gone — rc 0, nothing on stdout or stderr — and still renders when
# the renderer is there.
h38="$TMP/h38"; s38="$TMP/s38.json"
mkdir -p "$h38/marketplace/plugins/claude-hud/dist"
printf 'process.stdout.write("HUD-OK")\n' > "$h38/marketplace/plugins/claude-hud/dist/index.js"
CLAUDE_CONFIG_DIR="$TMP/cfg38" bash "$HELPER" "$s38" "$h38" >/dev/null || fail "38: wire failed"
cmd38="$(jq -r .statusLine.command "$s38")"
[ "$cmd38" = "$(guarded_cmd "$h38")" ] || fail "38: not the guarded command: $cmd38"
if command -v node >/dev/null 2>&1; then
  out38="$(sh -c "$cmd38" </dev/null 2>&1)" || fail "38: present renderer failed: $out38"
  [ "$out38" = "HUD-OK" ] || fail "38: present renderer did not render (got: $out38)"
else
  echo "skip 38 present-renderer half: node not on PATH"
fi
rm -rf "$h38"
rc38=0; out38="$(sh -c "$cmd38" </dev/null 2>&1)" || rc38=$?
[ "$rc38" -eq 0 ] || fail "38: a missing clone must not fail the statusLine (rc=$rc38)"
[ -z "$out38" ] || fail "38: a missing clone must render nothing (got: $out38)"
echo "ok 38 guarded statusLine renders when present and is silent when the clone is gone"

# 39. HIMMEL-3332: unwire recognises BOTH forms — an adopter wired before the
# guard (bare node form) and one wired after it — and leaves a user's own
# statusLine alone.
# shellcheck source=unwire-statusline.sh
. "$HERE/unwire-statusline.sh"
for form in bare guarded; do
  s39="$TMP/s39-$form.json"
  if [ "$form" = bare ]; then c39='node "/old/himmel/marketplace/plugins/claude-hud/dist/index.js"'
  else c39="$(guarded_cmd /old/himmel)"; fi
  jq -n --arg c "$c39" '{statusLine:{type:"command",command:$c},theme:"dark"}' > "$s39"
  unwire_statusline "$s39" >/dev/null || fail "39: unwire failed ($form)"
  [ "$(jq -c 'has("statusLine")' "$s39")" = false ] || fail "39: $form form not removed"
  [ "$(jq -r .theme "$s39")" = dark ] || fail "39: sibling key lost ($form)"
done
s39u="$TMP/s39-user.json"
printf '{"statusLine":{"type":"command","command":"[ -f ~/mine.js ] && exec node ~/mine.js || true"}}' > "$s39u"
unwire_statusline "$s39u" >/dev/null || fail "39: unwire failed (user)"
[ "$(jq -r .statusLine.command "$s39u")" = '[ -f ~/mine.js ] && exec node ~/mine.js || true' ] || fail "39: a user's own statusLine was touched"
echo "ok 39 unwire removes the bare and guarded forms, keeps a user statusLine"

# 40. HIMMEL-3334 codex-1 (suggestion): starting from ONLY a legacy-path hud
# config (no new-path file at all — the pre-migration state), a rewire must
# publish the new-path config carrying the previous config's
# HIMMEL_STATUSLINE_ECON prefix forward, and remove the legacy file since its
# customLineCommand matches himmel's own shape.
cfg40="$TMP/cfg40"; hud40="$cfg40/plugins/claude-hud"
proj40="$TMP/proj40"; mkdir -p "$proj40/.claude" "$hud40"
s40="$proj40/.claude/settings.json"
printf '{"display":{"customLineCommand":"HIMMEL_STATUSLINE_ECON=off bash \\"/old/himmel/scripts/statusline/hud-custom-lines.sh\\""}}\n' > "$hud40/config.json"
[ ! -f "$cfg40/claude-hud.json" ] || fail "40 precondition: new-path config must not pre-exist"
CLAUDE_CONFIG_DIR="$cfg40" bash "$HELPER" "$s40" "$REPO_ROOT" >/dev/null
[ -f "$cfg40/claude-hud.json" ] || fail "40: migration did not publish the new-path config"
newcmd40="$(jq -r .display.customLineCommand "$cfg40/claude-hud.json")"
case "$newcmd40" in
  "HIMMEL_STATUSLINE_ECON=off "*) : ;;
  *) fail "40: HIMMEL_STATUSLINE_ECON=off prefix was not carried forward from the legacy-only config" ;;
esac
[ ! -f "$hud40/config.json" ] || fail "40: himmel-owned legacy config was not removed after migration"
echo "ok 40 a legacy-only starting config migrates to the new path with its ECON prefix and the legacy file is removed"

echo "ALL PASS"
