#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-uninstall-provenance.sh -- HIMMEL-3332 S6 RED tests (RED3-RED8): the
# ledger-driven excision scripts/uninstall.sh does not have yet. Six hermetic
# cases, each with its own scratch HOME + scratch HIMMEL_PROVENANCE_DIR,
# seeding a REAL ledger via scripts/lib/provenance.sh (or deliberately
# omitting/foreign-ing one), then driving the REAL scripts/uninstall.sh with a
# fake `claude` first on PATH. Every RED here is proven failing against
# TODAY's uninstall.sh: it does not consult the provenance ledger anywhere
# yet. RED1/RED2 (the settings-restore half of this same S6 slice) live in
# scripts/test-e2e-symmetry.sh.
#
# jq-only. Usage: bash scripts/test-uninstall-provenance.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"

command -v jq >/dev/null 2>&1 || { echo "test-uninstall-provenance: jq required" >&2; exit 2; }
# shellcheck source=scripts/lib/provenance.sh
. "$lib/provenance.sh"

# HIMMEL-3332 S6 safety: the real-ledger tripwire. REAL_HOME is captured
# before ANY case below exports its own scratch HOME, so a bug that let a
# case's HOME leak back to the operator's real one is caught by an
# existence/sha mismatch at the end of the run instead of silently touching
# the operator's ~/.himmel/provenance.jsonl.
REAL_HOME="$HOME"
REAL_LEDGER="$REAL_HOME/.himmel/provenance.jsonl"
real_ledger_state() {
  if [ -f "$REAL_LEDGER" ]; then prov_sha_file "$REAL_LEDGER" 2>/dev/null || echo "ERROR-UNREADABLE"
  else echo "ABSENT"; fi
}
REAL_LEDGER_BEFORE=$(real_ledger_state)

SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-prov.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$SUITE_TMP"' EXIT

fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# ---- fake claude stub (adapted from scripts/test-uninstall-plugins.sh) -----
# One binary shared by every case; CLAUDE_CALL_LOG/STUB_PLUGINS_JSON/
# STUB_MARKETPLACES_JSON (set per run_uninstall call) point it at that case's
# own state, so cases never share plugin/marketplace state.
mkdir -p "$SUITE_TMP/bin"
FAKE_CLAUDE="$SUITE_TMP/bin/claude"
cat > "$FAKE_CLAUDE" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
json_list() {
    if [ ! -s "$1" ]; then echo '[]'
    else cat "$1"
    fi
}
case "$*" in
    'plugin list --json') json_list "$STUB_PLUGINS_JSON" ;;
    'plugin marketplace list --json') json_list "$STUB_MARKETPLACES_JSON" ;;
    'plugin uninstall '* )
        [ "$#" -eq 5 ] && [ "$4" = '--scope' ] || exit 2
        jq --arg id "$3" --arg scope "$5" '[.[] | select(.id != $id or .scope != $scope)]' \
            "$STUB_PLUGINS_JSON" > "$STUB_PLUGINS_JSON.next"
        mv "$STUB_PLUGINS_JSON.next" "$STUB_PLUGINS_JSON"
        ;;
    'plugin marketplace remove '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        jq --arg name "$4" '[.[] | select(.name != $name)]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    'plugin marketplace add '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        jq --arg name "himmel" '. + [{name: $name}]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    *) exit 2 ;;
esac
STUB_EOF
chmod 755 "$FAKE_CLAUDE"

# new_case <name> -- fresh scratch HOME/cwd/provenance dir + fresh plugin and
# marketplace stub state for one case. Sets the CASE_* globals the rest of
# the case (and run_uninstall) uses.
new_case() {
  CASE_DIR="$SUITE_TMP/$1"
  mkdir -p "$CASE_DIR/home/.claude" "$CASE_DIR/cwd" "$CASE_DIR/prov"
  export HOME="$CASE_DIR/home"
  export HIMMEL_PROVENANCE_DIR="$CASE_DIR/prov"
  unset CLAUDE_CONFIG_DIR
  CASE_SETTINGS="$HOME/.claude/settings.json"
  printf '{}\n' > "$CASE_SETTINGS"
  CASE_CLAUDE_LOG="$CASE_DIR/claude.log"; : > "$CASE_CLAUDE_LOG"
  CASE_PLUGINS_JSON="$CASE_DIR/plugins.json"; printf '[]\n' > "$CASE_PLUGINS_JSON"
  CASE_MARKETPLACES_JSON="$CASE_DIR/marketplaces.json"; printf '[]\n' > "$CASE_MARKETPLACES_JSON"
}

# run_uninstall <uninstall.sh args...> -- the real uninstall.sh, confined to
# this case's scratch HOME/cwd, with the fake claude first on PATH. Telegram/
# bridge/himmelctl-cache all point at fresh nonexistent dirs so steps 1-2-8
# no-op no matter what the case is testing.
run_uninstall() {
  ( cd "$CASE_DIR/cwd" && \
    HIMMEL_USER_SETTINGS="$CASE_SETTINGS" \
    TELEGRAM_CHANNEL_DIR="$CASE_DIR/no-telegram" BRIDGE_ROOT="$CASE_DIR/no-bridge" \
    HIMMELCTL_CACHE_DIR="$CASE_DIR/no-cache" \
    HIMMEL_PROVENANCE_DIR="$HIMMEL_PROVENANCE_DIR" \
    CLAUDE_CALL_LOG="$CASE_CLAUDE_LOG" STUB_PLUGINS_JSON="$CASE_PLUGINS_JSON" \
    STUB_MARKETPLACES_JSON="$CASE_MARKETPLACES_JSON" \
    PATH="$SUITE_TMP/bin:$PATH" \
    bash "$repo_root/scripts/uninstall.sh" "$@" </dev/null 2>&1 )
}

echo "==== RED3: plugin ownership via ledger register rows ===="
new_case red3
( prov_begin --writer install-plugins.sh -- seed-red3 >/dev/null
  prov_record register plugin - --unit himmel-ops@himmel --scope machine --class code \
    --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field preexisted=false >/dev/null
  prov_record register plugin - --unit context7@claude-plugins-official --scope machine --class code \
    --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field preexisted=true >/dev/null
  prov_record register marketplace - --unit himmel --scope machine --class code \
    --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=false >/dev/null
  prov_record register marketplace - --unit claude-plugins-official --scope machine --class code \
    --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
printf '[{"id":"himmel-ops@himmel","scope":"user"},{"id":"context7@claude-plugins-official","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
printf '[{"name":"himmel"},{"name":"claude-plugins-official"}]\n' > "$CASE_MARKETPLACES_JSON"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks --skip-settings >/dev/null
context7_kept=$(jq -r '[.[] | select(.id=="context7@claude-plugins-official")] | length>0' "$CASE_PLUGINS_JSON")
himmelops_removed=$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length==0' "$CASE_PLUGINS_JSON")
check "RED3 uninstall: ledger-preexisted plugin kept, himmel-installed plugin removed" \
  "$context7_kept $himmelops_removed" "true true"

echo "==== RED4: adopter-scripts file restore with backup+mode ===="
new_case red4
mkdir -p "$CASE_DIR/cwd/scripts"
DEST4="$CASE_DIR/cwd/scripts/foo.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST4"
chmod 700 "$DEST4"
ORIG4_BYTES=$(cat "$DEST4")
ORIG4_MODE=$(_prov_mode "$DEST4")
SNAP4=$(mktemp "$SUITE_TMP/SNAP4.XXXXXX") || exit 1
cp -p "$DEST4" "$SNAP4"
# simulate adopt.sh's real overwrite (copy_recorded): new bytes, new mode
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST4"
chmod 755 "$DEST4"
( prov_begin --writer adopt.sh -- seed-red4 >/dev/null
  prov_record replace file "$DEST4" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP4" --backup --post-file "$DEST4" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP4"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings >/dev/null
AFTER4_BYTES=$(cat "$DEST4")
AFTER4_MODE=$(_prov_mode "$DEST4")
check "RED4 uninstall: adopter-scripts file restored from ledger backup (bytes+mode)" \
  "$AFTER4_BYTES|$AFTER4_MODE" "$ORIG4_BYTES|$ORIG4_MODE"

echo "==== RED5: user-modified file protected (kept, not restored/removed) ===="
new_case red5
mkdir -p "$CASE_DIR/cwd/scripts"
DEST5="$CASE_DIR/cwd/scripts/bar.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST5"
SNAP5=$(mktemp "$SUITE_TMP/SNAP5.XXXXXX") || exit 1
cp -p "$DEST5" "$SNAP5"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST5"
( prov_begin --writer adopt.sh -- seed-red5 >/dev/null
  prov_record replace file "$DEST5" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP5" --backup --post-file "$DEST5" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP5"
# the operator edits the file again AFTER install recorded it -- current
# bytes no longer match the ledger's recorded post-sha.
printf '#!/bin/sh\necho operator-edited-after-install\n' > "$DEST5"
USER_MODIFIED5_BYTES=$(cat "$DEST5")
out5=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks --skip-settings)
AFTER5_BYTES=$(cat "$DEST5")
kept_line5=$(printf '%s\n' "$out5" | grep -c -E 'kept.*bar\.sh.*user-modified')
check "RED5 uninstall: user-modified adopter-script kept as-is + reported user-modified" \
  "$AFTER5_BYTES|$kept_line5" "$USER_MODIFIED5_BYTES|1"

echo "==== RED6: missing ledger -- six overwrite-prone rows protected, plugins skipped ===="
new_case red6
mkdir -p "$HOME/.claude/plugins/claude-hud"
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""},
  "env": {"HANDOVER_DIR": "/opt/red6-handover"}
}
JSON
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HOME/.claude/plugins/claude-hud/config.json"
printf '[{"id":"himmel-ops@himmel","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
printf '[{"name":"himmel"}]\n' > "$CASE_MARKETPLACES_JSON"
LEDGER_PATH6=$(prov_ledger_path)
out6=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks)
warn6=$(printf '%s\n' "$out6" | grep -c -F "provenance: no ledger at $LEDGER_PATH6; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept")
statusline_kept6=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
handover_kept6=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")
hud_kept6=$([ -f "$HOME/.claude/plugins/claude-hud/config.json" ] && echo yes || echo no)
plugin_kept6=$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length>0' "$CASE_PLUGINS_JSON")
check "RED6 uninstall: no ledger -> warning printed + statusLine/HANDOVER_DIR/hud-config/plugins all protected" \
  "$warn6|$statusline_kept6|$handover_kept6|$hud_kept6|$plugin_kept6" "1|true|/opt/red6-handover|yes|true"

echo "==== RED7: foreign ledger (recorded home != current home) -- same warning + statusLine protected ===="
new_case red7
# shellcheck disable=SC2030  # the foreign HOME is deliberately subshell-local
( HOME="$CASE_DIR/foreign-home"
  prov_begin --writer test-uninstall-provenance.sh -- seed-red7 >/dev/null
  prov_end ok >/dev/null )
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""}
}
JSON
LEDGER_PATH7=$(prov_ledger_path)
out7=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
warn7=$(printf '%s\n' "$out7" | grep -c -F "provenance: no ledger at $LEDGER_PATH7; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept")
statusline_kept7=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
check "RED7 uninstall: foreign-home ledger -> same no-ledger warning + statusLine protected" \
  "$warn7|$statusline_kept7" "1|true"

echo "==== RED8: --dry-run --purge-state provenance cleanup DRY lines are the LAST two ===="
new_case red8
( prov_begin --writer test-uninstall-provenance.sh -- seed-red8 >/dev/null
  prov_end ok >/dev/null )
BACKUPS_DIR8="$(prov_dir)/provenance-backups"
LEDGER_PATH8="$(prov_ledger_path)"
out8=$(run_uninstall --dry-run --purge-state --skip-tasks --skip-plugins --skip-hooks)
last_dry8=$(printf '%s\n' "$out8" | grep '^DRY:' | tail -n 2)
expected8=$'DRY: rm -rf -- '"$BACKUPS_DIR8"$'\n''DRY: rm -f -- '"$LEDGER_PATH8"
check "RED8 uninstall --dry-run --purge-state: provenance cleanup is the LAST two DRY lines" \
  "$last_dry8" "$expected8"

echo "==== RED9 (codex-1): --dry-run never prunes provenance-backups/ ===="
new_case red9
mkdir -p "$CASE_DIR/cwd/scripts"
DEST9="$CASE_DIR/cwd/scripts/red9.sh"
printf '#!/bin/sh\necho orig9\n' > "$DEST9"
SNAP9=$(mktemp "$SUITE_TMP/SNAP9.XXXXXX") || exit 1; cp -p "$DEST9" "$SNAP9"
printf '#!/bin/sh\necho himmel9\n' > "$DEST9"
( prov_begin --writer adopt.sh -- seed-red9 >/dev/null
  prov_record replace file "$DEST9" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP9" --backup --post-file "$DEST9" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP9"
BACKUP9=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
# NOTE: --skip-settings is deliberately NOT passed here. With it, the
# unwire_settings loop (uninstall.sh ~2010-2023) never runs, so its
# `_LEDGER_PROTECTED=""` reset (line 2000) never executes; the later
# adopter-scripts loop then references `_LEDGER_PROTECTED` unset under
# `set -uo pipefail` and the whole script aborts BEFORE reaching the
# ledger-session-close code this RED targets -- a crash that would falsely
# make the backup file "survive" for a reason unrelated to codex-1.
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED9 codex-1: dry-run does not prune the backup file" \
  "$([ -n "$BACKUP9" ] && [ -f "$BACKUP9" ] && echo yes || echo no)" "yes"

echo "==== RED10 (codex-2): adopter-scripts filtered to the current project root ===="
new_case red10
mkdir -p "$CASE_DIR/cwd/scripts" "$CASE_DIR/sibling/scripts"
DEST10A="$CASE_DIR/cwd/scripts/in-project.sh"
DEST10B="$CASE_DIR/sibling/scripts/other-project.sh"
printf '#!/bin/sh\necho a-original\n' > "$DEST10A"
printf '#!/bin/sh\necho b-original\n' > "$DEST10B"
SNAP10A=$(mktemp "$SUITE_TMP/SNAP10A.XXXXXX") || exit 1; cp -p "$DEST10A" "$SNAP10A"
SNAP10B=$(mktemp "$SUITE_TMP/SNAP10B.XXXXXX") || exit 1; cp -p "$DEST10B" "$SNAP10B"
printf '#!/bin/sh\necho a-himmel\n' > "$DEST10A"
printf '#!/bin/sh\necho b-himmel\n' > "$DEST10B"
B10B_INSTALLED=$(cat "$DEST10B")
( prov_begin --writer adopt.sh -- seed-red10 >/dev/null
  prov_record replace file "$DEST10A" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP10A" --backup --post-file "$DEST10A" >/dev/null
  prov_record replace file "$DEST10B" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP10B" --backup --post-file "$DEST10B" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP10A" "$SNAP10B"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER10B=$(cat "$DEST10B")
check "RED10 codex-2: sibling-project adopter-scripts file untouched" "$AFTER10B" "$B10B_INSTALLED"

echo "==== RED11 (codex-8): file_created=false ledger row passes --file-created no ===="
new_case red11
# RED7's `( HOME=… )` subshell closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
RULE11="$HOME/.claude/CLAUDE.md"
printf '<!-- BEGIN HIMMEL:working-principles -->\n## Working principles\n- think first\n<!-- END HIMMEL:working-principles -->\n' > "$RULE11"
( prov_begin --writer test-uninstall-provenance.sh -- seed-red11 >/dev/null
  prov_record create block "$RULE11" --scope user --class code \
    --writer test-uninstall-provenance.sh --field file_created=false --pre-absent --post-json '"x"' >/dev/null
  prov_end ok >/dev/null )
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED11 codex-8: file_created=false keeps the rule file (not deleted)" \
  "$([ -f "$RULE11" ] && echo yes || echo no)" "yes"

echo "==== RED12 (codex-9): a failed unit in the adopter-scripts loop halts iteration ===="
new_case red12
mkdir -p "$CASE_DIR/cwd/scripts"
DEST12A="$CASE_DIR/cwd/scripts/aaa-fails.sh"
DEST12B="$CASE_DIR/cwd/scripts/zzz-second.sh"
printf '#!/bin/sh\necho a-original\n' > "$DEST12A"
printf '#!/bin/sh\necho b-original\n' > "$DEST12B"
SNAP12A=$(mktemp "$SUITE_TMP/SNAP12A.XXXXXX") || exit 1; cp -p "$DEST12A" "$SNAP12A"
SNAP12B=$(mktemp "$SUITE_TMP/SNAP12B.XXXXXX") || exit 1; cp -p "$DEST12B" "$SNAP12B"
printf '#!/bin/sh\necho a-himmel\n' > "$DEST12A"
printf '#!/bin/sh\necho b-himmel\n' > "$DEST12B"
B12B_INSTALLED=$(cat "$DEST12B")
( prov_begin --writer adopt.sh -- seed-red12 >/dev/null
  prov_record replace file "$DEST12A" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP12A" --backup --post-file "$DEST12A" >/dev/null
  prov_record replace file "$DEST12B" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP12B" --backup --post-file "$DEST12B" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP12A" "$SNAP12B"
# Corrupt (not delete) DEST12A's recorded backup: prov_read_verdict only
# checks the backup is present+readable ("restore ours"), so a MISSING
# backup verdicts "keep no-backup" instead and never reaches
# prov_read_apply at all -- no failure, no halt. A backup whose CONTENT no
# longer matches the unit's recorded eff_pre.sha lets the restore copy
# succeed mechanically but fail prov_read_apply's post-restore sha check
# (provenance-read.sh's file-restore case), which is a real `failed`
# outcome -> fail_step -> HALTED=1.
BK12A=$(grep -rl "a-original" "$(prov_dir)/provenance-backups" 2>/dev/null | head -n1)
[ -n "$BK12A" ] || { echo "FAIL - RED12 setup: backup for DEST12A not found"; fails=$((fails+1)); }
printf '#!/bin/sh\necho corrupted-backup\n' > "$BK12A"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
AFTER12B=$(cat "$DEST12B")
check "RED12 codex-9: second adopter-scripts unit untouched after the first failed" \
  "$AFTER12B" "$B12B_INSTALLED"

echo "==== RED13 (codex-4): ledger loaded but silent on statusLine/HANDOVER_DIR/hud -- kept like no-ledger, not stripped ===="
new_case red13
# RED7's `( HOME=… )` subshell closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
HUD13="$HOME/.claude/plugins/claude-hud/config.json"
mkdir -p "$(dirname "$HUD13")"
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""},
  "env": {"HANDOVER_DIR": "/opt/red13-handover"}
}
JSON
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HUD13"
# a REAL, loaded ledger (LEDGER_OK=1) that records only an UNRELATED unit --
# never a json-key unit for /statusLine or /env/HANDOVER_DIR, and never a
# file unit for the hud config path -- so every one of these six-row
# fallbacks must trigger on "ledger loaded but silent", not "no ledger".
( prov_begin --writer install-plugins.sh -- seed-red13 >/dev/null
  prov_record register plugin - --unit unrelated-plugin@some-marketplace --scope machine --class code \
    --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out13=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
statusline_kept13=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
handover_kept13=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")
hud_kept13=$([ -f "$HUD13" ] && echo yes || echo no)
notinledger13=$(printf '%s\n' "$out13" | grep -c 'kept (not in ledger)')
check "RED13 codex-4: loaded-but-silent ledger keeps statusLine/HANDOVER_DIR/hud-config like the no-ledger branch" \
  "$statusline_kept13|$handover_kept13|$hud_kept13|$notinledger13" "true|/opt/red13-handover|yes|3"

echo "==== RED14 (codex-5): a halted per-unit settings loop must not fall through to the legacy helper for a unit it never reached ===="
new_case red14
cat > "$CASE_SETTINGS" <<JSON
{
  "env": {"HANDOVER_DIR": "/opt/red14-handover", "LUNA_VAULT_PATH": "/opt/red14-preexisting-vault"}
}
JSON
# Two json-key units on the same settings path: /env/HANDOVER_DIR sorts
# before /env/LUNA_VAULT_PATH (fold groups are alphabetical by unit), so
# corrupting HANDOVER_DIR's backup forces the per-unit loop to halt on the
# FIRST unit -- LUNA_VAULT_PATH (a "keep user-modified" verdict, since its
# current value is the pre-existing one, not the installed one) is never
# reached and never added to _LEDGER_PROTECTED. Without the codex-5 halt
# check, the unconditional legacy helper loop below would still run and
# unwire-luna-vault.sh strips env.LUNA_VAULT_PATH unconditionally.
( prov_begin --writer adopt.sh -- seed-red14 >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env/HANDOVER_DIR --scope user --class code \
    --writer adopt.sh --row env --pre-json '"/opt/red14-pre-handover"' --backup --post-json '"/opt/red14-handover"' >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env/LUNA_VAULT_PATH --scope user --class code \
    --writer adopt.sh --row env --pre-json '"/opt/red14-preexisting-vault"' --backup --post-json '"/opt/red14-himmel-vault"' >/dev/null
  prov_end ok >/dev/null )
BACKUP14=$(grep -rl 'red14-pre-handover' "$(prov_dir)/provenance-backups" 2>/dev/null | head -n1)
[ -n "$BACKUP14" ] || { echo "FAIL - RED14 setup: backup for HANDOVER_DIR not found"; fails=$((fails+1)); }
printf '%s' '"tampered"' > "$BACKUP14"
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
vault_after14=$(jq -r '.env.LUNA_VAULT_PATH // "ABSENT"' "$CASE_SETTINGS")
check "RED14 codex-5: LUNA_VAULT_PATH unit never reached after the halt is left untouched, not legacy-stripped" \
  "$vault_after14" "/opt/red14-preexisting-vault"

echo "==== RED15 (codex-6): --purge-state --keep-backups spares provenance-backups/ ===="
new_case red15
mkdir -p "$CASE_DIR/cwd/scripts"
DEST15="$CASE_DIR/cwd/scripts/red15.sh"
printf '#!/bin/sh\necho original-user-script\n' > "$DEST15"
SNAP15=$(mktemp "$SUITE_TMP/SNAP15.XXXXXX") || exit 1; cp -p "$DEST15" "$SNAP15"
printf '#!/bin/sh\necho himmel-installed-script\n' > "$DEST15"
( prov_begin --writer adopt.sh -- seed-red15 >/dev/null
  prov_record replace file "$DEST15" --scope project --class code --row adopter-scripts \
    --writer adopt.sh --pre-file "$SNAP15" --backup --post-file "$DEST15" >/dev/null
  prov_end ok >/dev/null )
rm -f "$SNAP15"
# the operator edits the file again after install recorded it -- verdict
# "keep user-modified", so its backup is NOT pruned by the ordinary
# per-unit prune (codex-1) and survives to see whether --purge-state /
# --keep-backups treats it correctly.
printf '#!/bin/sh\necho operator-edited-after-install\n' > "$DEST15"
BACKUP15=$(find "$(prov_dir)/provenance-backups" -type f | head -n1)
[ -n "$BACKUP15" ] || { echo "FAIL - RED15 setup: backup for DEST15 not found"; fails=$((fails+1)); }
LEDGER_PATH15="$(prov_ledger_path)"
# NOTE: --skip-settings is deliberately NOT passed here (see RED9's note
# above): it skips unwire_settings, whose `_LEDGER_PROTECTED=""` reset the
# adopter-scripts loop later relies on -- without it the script aborts on an
# unset variable under `set -uo pipefail` before ever reaching the
# provenance session-close code this RED targets.
run_uninstall --yes --purge-state --keep-backups --skip-tasks --skip-plugins --skip-hooks >/dev/null
ledger_gone15=$([ -f "$LEDGER_PATH15" ] && echo present || echo gone)
backup_kept15=$([ -f "$BACKUP15" ] && echo yes || echo no)
check "RED15 codex-6: --purge-state --keep-backups removes the ledger but keeps a kept-unit's backup" \
  "$ledger_gone15|$backup_kept15" "gone|yes"

echo "==== RED16 (R2-codex8): DRY preview never announces removing a unit the ledger pass already kept ===="
new_case red16
printf '{"env":{"HIMMEL_REPO":"/opt/red16-operator-value"}}\n' > "$CASE_SETTINGS"
# A ledger unit for env.HIMMEL_REPO whose recorded post value differs from
# the settings file's CURRENT value (the operator changed it since install)
# -> prov_read_verdict returns "keep user-modified", so ledger_apply_unit
# masks env.HIMMEL_REPO out of the DRY preview via _mask_repo. Before the
# codex-8 fix, himmel_wiring_lines was always called with a literal 0 for
# mask_repo, so the preview still announced removing it despite the ledger
# pass one line above having just kept it.
( prov_begin --writer install.sh -- seed-red16 >/dev/null
  prov_record replace json-key "$CASE_SETTINGS" --unit /env/HIMMEL_REPO --scope machine --class code \
    --writer install.sh --row env --pre-absent --post-json '"/opt/red16-himmel-value"' >/dev/null
  prov_end ok >/dev/null )
out16=$(run_uninstall --dry-run --yes --skip-tasks --skip-plugins --skip-hooks)
kept_line16=$(printf '%s\n' "$out16" | grep -c 'DRY: would keep /env/HIMMEL_REPO (user-modified)')
removed_line16=$(printf '%s\n' "$out16" | grep -c 'would remove env\.HIMMEL_REPO=')
check "RED16 R2-codex8: masked env.HIMMEL_REPO kept once and never also previewed as removed" \
  "$kept_line16|$removed_line16" "1|0"

echo "==== REAL-LEDGER TRIPWIRE ===="
REAL_LEDGER_AFTER=$(real_ledger_state)
check "tripwire: operator's real ~/.himmel/provenance.jsonl untouched by this suite" \
  "$REAL_LEDGER_AFTER" "$REAL_LEDGER_BEFORE"

[ "$fails" -eq 0 ] && echo "UNINSTALL-PROVENANCE ALL PASS" || { echo "$fails UNINSTALL-PROVENANCE FAILED"; exit 1; }
