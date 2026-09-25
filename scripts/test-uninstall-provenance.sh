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
# shellcheck source=scripts/lib/provenance-identity.sh
. "$lib/provenance-identity.sh"

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

# fake qmd stub -- qmd_cmd (scripts/lib/qmd-bin.sh) falls back to `qmd` on
# PATH whenever its bun-direct qmd.js path (BUN_INSTALL, pointed at a fresh
# scratch dir by run_uninstall) does not exist, so this is always what
# handles `qmd collection remove` in these tests, real bun on PATH or not.
# RED26: `collection remove` refuses (exit 127, matching a real qmd_cmd
# "not found" when the bun-global link/fork are already gone) if
# QMD_ORDER_CHECK_FORK_DIR/QMD_ORDER_CHECK_SYMLINK are set and either has
# already been removed -- this is how a real qmd_cmd resolution would fail if
# uninstall.sh unwired the fork checkout or global symlink before removing
# the collection, since prod's `qmd collection remove` is served through
# exactly one of those two paths.
# HIMMEL-3525 S16: `collection show <name>` answers the uninstall verdict's
# live-identity read with QMD_STUB_SHOW_PATH as the Path; unset, it answers
# qmd's own "Collection not found" (exit 1).
FAKE_QMD="$SUITE_TMP/bin/qmd"
cat > "$FAKE_QMD" <<'QMD_STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${QMD_CALL_LOG:-/dev/null}"
case "$*" in
    'collection show '*)
        if [ -z "${QMD_STUB_SHOW_PATH:-}" ]; then
            echo "Collection not found: $3" >&2
            exit 1
        fi
        printf 'Collection: %s\n  Path:     %s\n  Pattern:  **/*.md\n' "$3" "$QMD_STUB_SHOW_PATH"
        exit 0 ;;
    'collection remove '*)
        if [ -n "${QMD_ORDER_CHECK_FORK_DIR:-}" ] && [ ! -d "$QMD_ORDER_CHECK_FORK_DIR" ]; then
            echo "fake qmd: collection remove called after the fork checkout was already removed" >&2
            exit 127
        fi
        if [ -n "${QMD_ORDER_CHECK_SYMLINK:-}" ] && [ ! -L "$QMD_ORDER_CHECK_SYMLINK" ]; then
            echo "fake qmd: collection remove called after the global symlink was already removed" >&2
            exit 127
        fi
        exit 0 ;;
    *) exit 2 ;;
esac
QMD_STUB_EOF
chmod 755 "$FAKE_QMD"

# fake crontab stub (HIMMEL-3525 S18): `-l` prints CRONTAB_STATE_FILE (a
# per-case scratch table; missing/empty means "no crontab for tester", the
# same message real crontab gives an unset table -- both _provid_job and
# uninstall.sh's [3/8] cron rewrite classify that string as ABSENT/no-op, never
# a read failure). `-` reads a replacement table from stdin and overwrites the
# same file, so the [3/8] `crontab -` rewrite is observable afterwards without
# ever touching the operator's real crontab.
FAKE_CRONTAB="$SUITE_TMP/bin/crontab"
cat > "$FAKE_CRONTAB" <<'CRONTAB_STUB_EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
    -l)
        if [ -z "${CRONTAB_STATE_FILE:-}" ] || [ ! -f "$CRONTAB_STATE_FILE" ]; then
            echo "no crontab for tester" >&2
            exit 1
        fi
        cat "$CRONTAB_STATE_FILE" ;;
    -)
        [ -n "${CRONTAB_STATE_FILE:-}" ] || exit 1
        cat > "$CRONTAB_STATE_FILE" ;;
    *) exit 2 ;;
esac
CRONTAB_STUB_EOF
chmod 755 "$FAKE_CRONTAB"

# new_case <name> -- fresh scratch HOME/cwd/provenance dir + fresh plugin and
# marketplace stub state for one case. Sets the CASE_* globals the rest of
# the case (and run_uninstall) uses.
new_case() {
  # HIMMEL-3336: CASE_DIR is grounded in a literal mktemp template (not "$1")
  # so the real-home-callers static scan can verify HOME stays scratch.
  CASE_DIR="$(mktemp -d "$SUITE_TMP/case.XXXXXX")" || { echo "FAIL: mktemp CASE_DIR ($1)" >&2; exit 1; }
  mkdir -p "$CASE_DIR/home/.claude" "$CASE_DIR/cwd" "$CASE_DIR/prov"
  export HOME="$CASE_DIR/home"
  export HIMMEL_PROVENANCE_DIR="$CASE_DIR/prov"
  unset CLAUDE_CONFIG_DIR
  CASE_SETTINGS="$HOME/.claude/settings.json"
  printf '{}\n' > "$CASE_SETTINGS"
  CASE_CLAUDE_LOG="$CASE_DIR/claude.log"; : > "$CASE_CLAUDE_LOG"
  CASE_PLUGINS_JSON="$CASE_DIR/plugins.json"; printf '[]\n' > "$CASE_PLUGINS_JSON"
  CASE_MARKETPLACES_JSON="$CASE_DIR/marketplaces.json"; printf '[]\n' > "$CASE_MARKETPLACES_JSON"
  # A case that wants a real qmd fixture sets these itself, right after
  # calling new_case -- unset here so a case that does NOT set them never
  # inherits a stale dir from an earlier case in the same suite run.
  unset CASE_QMD_FORK_DIR CASE_BUN_INSTALL CASE_QMD_ORDER_CHECK_FORK_DIR CASE_QMD_ORDER_CHECK_SYMLINK
  unset CASE_QMD_COLLECTION_PATH
  # A case that wants a fake crontab table sets this itself, right after
  # calling new_case -- unset here so a case that does NOT set it never
  # inherits a stale file from an earlier case (default: no crontab).
  unset CASE_CRONTAB_FILE
}

# run_uninstall <uninstall.sh args...> -- the real uninstall.sh, confined to
# this case's scratch HOME/cwd, with the fake claude first on PATH. Telegram/
# bridge/himmelctl-cache all point at fresh nonexistent dirs so steps 1-2-8
# no-op no matter what the case is testing. QMD_FORK_DIR/BUN_INSTALL default
# the same way (a case that wants a real qmd fixture sets CASE_QMD_FORK_DIR /
# CASE_BUN_INSTALL before calling).
run_uninstall() {
  ( cd "$CASE_DIR/cwd" && \
    HIMMEL_USER_SETTINGS="$CASE_SETTINGS" \
    TELEGRAM_CHANNEL_DIR="$CASE_DIR/no-telegram" BRIDGE_ROOT="$CASE_DIR/no-bridge" \
    HIMMELCTL_CACHE_DIR="$CASE_DIR/no-cache" \
    QMD_FORK_DIR="${CASE_QMD_FORK_DIR:-$CASE_DIR/no-qmd-fork}" \
    BUN_INSTALL="${CASE_BUN_INSTALL:-$CASE_DIR/no-bun}" \
    QMD_CALL_LOG="$CASE_DIR/qmd.log" \
    QMD_STUB_SHOW_PATH="${CASE_QMD_COLLECTION_PATH:-}" \
    QMD_ORDER_CHECK_FORK_DIR="${CASE_QMD_ORDER_CHECK_FORK_DIR:-}" \
    QMD_ORDER_CHECK_SYMLINK="${CASE_QMD_ORDER_CHECK_SYMLINK:-}" \
    CRONTAB_STATE_FILE="${CASE_CRONTAB_FILE:-$CASE_DIR/no-crontab}" \
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

echo "==== RED6: missing ledger -- six overwrite-prone rows protected (hud-config's own path), plugins skipped; a legacy pre-HIMMEL-3334 swept-path leftover is removed regardless ===="
new_case red6
mkdir -p "$HOME/.claude/plugins/claude-hud"
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""},
  "env": {"HANDOVER_DIR": "/opt/red6-handover"}
}
JSON
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HOME/.claude/claude-hud.json"
# HIMMEL-3334: a leftover config at the pre-migration swept path
# (plugins/claude-hud/config.json, inside Claude Code's plugin-manager
# sweep) is removed unconditionally -- ledger-independent, gated only by
# unwire_hud_config's customLineCommand shape check -- since leaving it
# there defeats the whole point of the fix. It is not one of the six
# overwrite-prone rows the no-ledger branch otherwise protects; the row's
# OWN (new, un-swept) path still is, asserted separately below.
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HOME/.claude/plugins/claude-hud/config.json"
printf '[{"id":"himmel-ops@himmel","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
printf '[{"name":"himmel"}]\n' > "$CASE_MARKETPLACES_JSON"
LEDGER_PATH6=$(prov_ledger_path)
out6=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks)
warn6=$(printf '%s\n' "$out6" | grep -c -F "provenance: no ledger at $LEDGER_PATH6; pre-existing units cannot be told from himmel's — the six overwrite-prone rows are kept")
statusline_kept6=$(jq -r 'has("statusLine")' "$CASE_SETTINGS")
handover_kept6=$(jq -r '.env.HANDOVER_DIR // "ABSENT"' "$CASE_SETTINGS")
hud_kept6=$([ -f "$HOME/.claude/claude-hud.json" ] && echo yes || echo no)
hud_legacy_removed6=$([ -f "$HOME/.claude/plugins/claude-hud/config.json" ] && echo no || echo yes)
plugin_kept6=$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length>0' "$CASE_PLUGINS_JSON")
check "RED6 uninstall: no ledger -> warning printed + statusLine/HANDOVER_DIR/hud-config(new path)/plugins protected, legacy swept-path leftover always removed" \
  "$warn6|$statusline_kept6|$handover_kept6|$hud_kept6|$hud_legacy_removed6|$plugin_kept6" "1|true|/opt/red6-handover|yes|yes|true"

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
# HIMMEL-3386: assert rc=0 BEFORE the survival check. A backup that survives
# an uninstall that crashed early looks identical to one that survives a
# clean dry-run, so the survival check alone is vacuous against a crash.
# (--skip-settings used to be withheld here because it skipped the
# unwire_settings `_LEDGER_PROTECTED=""` reset and the script then aborted
# on an unbound variable; uninstall.sh now initialises it once globally, so
# that is no longer a hazard and the rc check would catch it if it returned.)
run_uninstall --dry-run --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
rc9=$?
check "RED9 codex-1: dry-run uninstall exits 0" "$rc9" "0"
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
# RED7's HOME override, `( HOME set inside a subshell )`, closed long before this line; HOME here is the
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

echo "==== RED13 (codex-4): ledger loaded but silent on statusLine/HANDOVER_DIR/hud -- kept like no-ledger, not stripped; a legacy swept-path leftover is still removed regardless ===="
new_case red13
# RED7's HOME override, `( HOME set inside a subshell )`, closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
HUD13="$HOME/.claude/claude-hud.json"
mkdir -p "$(dirname "$HUD13")"
# HIMMEL-3334: a leftover legacy-path config, same reasoning as RED6 --
# removed unconditionally regardless of the ledger's loaded-but-silent
# state, since it is never one of the ledger-decided six-row fallbacks.
HUD13_LEGACY="$HOME/.claude/plugins/claude-hud/config.json"
mkdir -p "$(dirname "$HUD13_LEGACY")"
cat > "$CASE_SETTINGS" <<JSON
{
  "statusLine": {"type":"command","command":"bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""},
  "env": {"HANDOVER_DIR": "/opt/red13-handover"}
}
JSON
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HUD13"
printf '{"display":{"customLineCommand":"bash \\"/fake/scripts/statusline/hud-custom-lines.sh\\""}}\n' \
  > "$HUD13_LEGACY"
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
hud_legacy_removed13=$([ -f "$HUD13_LEGACY" ] && echo no || echo yes)
notinledger13=$(printf '%s\n' "$out13" | grep -c 'kept (not in ledger)')
# HIMMEL-3332 S6 slice2: workspace-trust is now ledger-decided too, so a
# loaded-but-silent ledger also keeps it "not in ledger" -- a 4th line,
# alongside statusLine, env.HANDOVER_DIR and the hud config.
check "RED13 codex-4: loaded-but-silent ledger keeps statusLine/HANDOVER_DIR/hud-config(new path) like the no-ledger branch, legacy swept-path leftover still removed" \
  "$statusline_kept13|$handover_kept13|$hud_kept13|$hud_legacy_removed13|$notinledger13" "true|/opt/red13-handover|yes|yes|4"

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
# (HIMMEL-3386: the former note about --skip-settings and the unbound
# `_LEDGER_PROTECTED` was stale -- uninstall.sh initialises it globally now.)
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

echo "==== RED17 (HIMMEL-3389): a himmel-created empty hooks object is dropped; a pre-existing one survives ===="
# The REAL wire records the /hooks container it creates; uninstall then drops the
# empty object only when that governed /hooks unit says himmel created it.
new_case red17
bash "$lib/wire-pretooluse-hooks.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 HIMMEL-3389: a himmel-created hooks object is gone after uninstall" \
  "$(jq -c '.hooks // "ABSENT"' "$CASE_SETTINGS")" '"ABSENT"'
new_case red17c
printf '{"hooks":{}}\n' > "$CASE_SETTINGS"
bash "$lib/wire-pretooluse-hooks.sh" "$CASE_SETTINGS" "C:/fake/himmel" >/dev/null
run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks >/dev/null
check "RED17 control: a pre-existing empty hooks object survives uninstall" \
  "$(jq -c '.hooks // "ABSENT"' "$CASE_SETTINGS")" '{}'

echo "==== RED18 (HIMMEL-3398): a protected /statusLineX or /env/HIMMEL_REPOX never masks /statusLine or /env/HIMMEL_REPO ===="
# /statusLineX and /env/HIMMEL_REPOX are kept (noop-preexisted), so they land in
# _LEDGER_PROTECTED. /statusLine is a heuristic unit (noop, not preexisted) and
# env.HIMMEL_REPO has no unit at all, so only today's helpers remove them --
# unless a prefix match on the protected list wrongly masks those helpers.
new_case red18
SL18="bash \"$repo_root/marketplace/plugins/claude-hud/dist/index.js\""
jq -n --arg c "$SL18" '{statusLine: {type: "command", command: $c}, statusLineX: "u",
  env: {HIMMEL_REPO: "C:/fake/himmel", HIMMEL_REPOX: "x"}}' > "$CASE_SETTINGS"
( prov_begin --writer install.sh -- seed-red18 >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit /statusLine --scope user --class code --row user-settings \
    --writer wire-statusline.sh --pre-json "$(jq -c .statusLine "$CASE_SETTINGS")" \
    --post-json "$(jq -c .statusLine "$CASE_SETTINGS")" >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit /statusLineX --scope user --class code --row user-settings \
    --writer install.sh --pre-json '"u"' --post-json '"u"' --field preexisted=true >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit /env/HIMMEL_REPOX --scope user --class code --row user-settings \
    --writer install.sh --pre-json '"x"' --post-json '"x"' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out18=$(run_uninstall --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks)
check "RED18 HIMMEL-3398: /statusLine and env.HIMMEL_REPO removed; /statusLineX and env.HIMMEL_REPOX kept" \
  "$(jq -c '[has("statusLine"), (.env | has("HIMMEL_REPO")), .statusLineX, .env.HIMMEL_REPOX]' "$CASE_SETTINGS")" \
  '[false,false,"u","x"]'
check "RED18: both protected units reported kept" \
  "$(printf '%s\n' "$out18" | grep -c -E 'kept /(statusLineX|env/HIMMEL_REPOX) \(noop-preexisted\)')" "2"

echo "==== RED19 (HIMMEL-3332 S6 slice2): workspace-trust json-key ledger excision ===="
# applyWorkspaceTrust (himmelctl bin.js) records a json-key row for
# /projects/<dir>/hasTrustDialogAccepted in ~/.claude.json. Today's
# uninstall.sh has no code path that ever reads ~/.claude.json -- these four
# rows are proven RED against the unfixed tree.
# These fixtures put ~/.claude.json under the case's scratch HOME, which the
# wet-run fence (HIMMEL-2505) reads as a live operator profile. The HOME is a
# temp dir, so lift the fence the way test-uninstall.sh's u_run_fx does --
# for these four calls only.
run_uninstall_fx() { export HIMMEL_UNINSTALL_REAL_HOME=1; run_uninstall "$@"; local rc=$?; unset HIMMEL_UNINSTALL_REAL_HOME; return "$rc"; }
new_case red19a
# RED7's HOME override, `( HOME set inside a subshell )`, closed long before this line; HOME here is the
# suite's own scratch HOME, exactly as intended.
# shellcheck disable=SC2031
CFG19A="$HOME/.claude.json"
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: true}}}' > "$CFG19A"
cp "$CFG19A" "$SUITE_TMP/red19a-before.json"
( prov_begin --writer himmelctl-bin.js -- seed-red19a >/dev/null
  prov_record create json-key "$CFG19A" --unit '/projects/~1proj/hasTrustDialogAccepted' --scope user --class code \
    --writer himmelctl-bin.js --row workspace-trust --pre-absent --post-json 'true' --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19a: uninstall exit status" "$?" "0"
check "RED19a: install-created trust key is removed" \
  "$(jq -c '.projects."/proj" | has("hasTrustDialogAccepted")' "$CFG19A")" "false"
check "RED19a: rest of the project object is byte-identical" \
  "$(jq -c '.projects."/proj" | del(.hasTrustDialogAccepted)' "$CFG19A")" \
  "$(jq -c '.projects."/proj" | del(.hasTrustDialogAccepted)' "$SUITE_TMP/red19a-before.json")"

new_case red19b
# shellcheck disable=SC2031
CFG19B="$HOME/.claude.json"
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: true, otherKey: "x"}}}' > "$CFG19B"
cp "$CFG19B" "$SUITE_TMP/red19b-before.json"
( prov_begin --writer himmelctl-bin.js -- seed-red19b >/dev/null
  prov_record noop json-key "$CFG19B" --unit '/projects/~1proj/hasTrustDialogAccepted' --scope user --class code \
    --writer himmelctl-bin.js --row workspace-trust --pre-json 'true' --post-json 'true' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19b: uninstall exit status" "$?" "0"
check "RED19b: pre-existing trust key survives byte-identical" \
  "$(jq -c . "$CFG19B")" "$(jq -c . "$SUITE_TMP/red19b-before.json")"

new_case red19c
# shellcheck disable=SC2031
CFG19C="$HOME/.claude.json"
# himmel's own row says it wrote "true" at install; the operator has since
# revoked trust (current file has "false") -- verdict must be user-modified.
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: false}}}' > "$CFG19C"
( prov_begin --writer himmelctl-bin.js -- seed-red19c >/dev/null
  prov_record create json-key "$CFG19C" --unit '/projects/~1proj/hasTrustDialogAccepted' --scope user --class code \
    --writer himmelctl-bin.js --row workspace-trust --pre-absent --post-json 'true' --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19c: uninstall exit status" "$?" "0"
check "RED19c: a trust key the user has since revoked is kept (false)" \
  "$(jq -c '.projects."/proj".hasTrustDialogAccepted' "$CFG19C")" "false"

new_case red19d
# shellcheck disable=SC2031
CFG19D="$HOME/.claude.json"
jq -n '{projects: {"/proj": {hasTrustDialogAccepted: true}}}' > "$CFG19D"
cp "$CFG19D" "$SUITE_TMP/red19d-before.json"
# no prov_begin/prov_record/prov_end at all -- a pre-ledger install.
run_uninstall_fx --yes --skip-tasks --skip-plugins --skip-hooks >/dev/null; check "RED19d: uninstall exit status" "$?" "0"
check "RED19d: with no ledger, the trust key is kept exactly as today" \
  "$(jq -c . "$CFG19D")" "$(jq -c . "$SUITE_TMP/red19d-before.json")"

_red_seed_git_fork() {
  # <dir> -- init a one-commit git repo at $1, matching the real fork
  # checkout's shape (a build stamp file that is byte-identical to a fresh
  # clone). Returns with the tree clean and HEAD pushed to a bare "origin".
  # HIMMEL-3524: qmd_unwire_fork_checkout now checks live git state before
  # removing, so every fixture standing in for a real (always-git) fork
  # checkout needs an actual repo, not a plain directory -- a plain directory
  # is itself the "unknown state" the fix is required to keep, not remove.
  local dir="$1" bare
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test"
  # HIMMEL-3534: match the real fork's .gitignore shape (node_modules/,
  # dist/ are the build's own output; notes/ stands in for the fork's many
  # OTHER ignored patterns -- archive/, *.sqlite, etc -- that are NOT build
  # output and so stay off the allowlist).
  printf 'node_modules/\ndist/\nnotes/\n' > "$dir/.gitignore"
  printf 'fork file\n' > "$dir/tracked.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m seed
  # The build stamp is written AFTER the seed commit, same as a real build:
  # untracked, never gitignored (HIMMEL-3534 FINDING) -- present in every
  # fixture from here on so RED27/RED28's clean-tree cases match a real
  # built fork, not one caught mid-build.
  printf 'ok\n' > "$dir/.himmel-build-ok"
  bare="$dir.git-origin"
  git init -q --bare "$bare"
  git -C "$dir" remote add origin "$bare"
  git -C "$dir" push -q origin HEAD:refs/heads/main
}

echo "==== RED20 (HIMMEL-3332 slice3): install-created qmd kept by default, removed under --purge-state; stub never removed ===="
# Fixture shape mirrors the real prov_record call sites (scripts/lib/qmd-bin.sh
# lines 595-655, scripts/lib/fix-qmd-stub.sh line 66): fork checkout is a
# `create file` row on the build stamp, the bun-global link is a `create
# symlink` row (--post-text stores the target string's SHA, never the
# literal), the collection is a `register collection` row (path arg `-`,
# ownership by unit name), and the stub patch is a `replace file` row with
# --backup that NEVER gates a removal (console ruling, 2026-09-23).
new_case red20a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP20A="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'ok\n' > "$STAMP20A"
GLOBAL_DIR20A="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR20A")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR20A"
STUB20A="$CASE_DIR/stub-qmd-20a"; printf 'patched stub\n' > "$STUB20A"
cp "$STUB20A" "$SUITE_TMP/red20a-stub-before"
printf 'orig stub\n' > "$SUITE_TMP/red20a-stub-pre"
( prov_begin --writer install.sh -- seed-red20a >/dev/null
  prov_record create file "$STAMP20A" --pre-absent --post-file "$STAMP20A" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record create symlink "$GLOBAL_DIR20A" --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record register collection - --unit qmd-vault --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record replace file "$STUB20A" --pre-file "$SUITE_TMP/red20a-stub-pre" --backup --post-file "$STUB20A" \
    --scope machine --class code --row qmd-fork --writer fix-qmd-stub.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out20a=$(run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks); rc20a=$?
check "RED20a: uninstall exit status" "$rc20a" "0"
check "RED20a: default run keeps the fork checkout dir" "$([ -d "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED20a: default run keeps the build stamp byte-identical" "$(cat "$STAMP20A" 2>/dev/null)" "ok"
check "RED20a: default run keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR20A" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED20a: default run never calls qmd collection remove" \
  "$(grep -c 'collection remove' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "0"
check "RED20a: default run keeps the stub byte-identical" "$(cat "$STUB20A")" "$(cat "$SUITE_TMP/red20a-stub-before")"
check "RED20a: stub kept line printed" \
  "$(printf '%s\n' "$out20a" | grep -c 'qmd plugin stub himmel patched')" "1"

new_case red20b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
# HIMMEL-3524: a real fork checkout is always a git work tree; a plain
# directory is the "unknown state" the fix now keeps rather than removes, so
# this --purge-state-removes fixture needs a clean git checkout to reach rm.
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
STAMP20B="$CASE_QMD_FORK_DIR/.himmel-build-ok"
GLOBAL_DIR20B="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR20B")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR20B"
STUB20B="$CASE_DIR/stub-qmd-20b"; printf 'patched stub\n' > "$STUB20B"
CASE_QMD_COLLECTION_PATH="$CASE_QMD_FORK_DIR"
cp "$STUB20B" "$SUITE_TMP/red20b-stub-before"
printf 'orig stub\n' > "$SUITE_TMP/red20b-stub-pre"
( prov_begin --writer install.sh -- seed-red20b >/dev/null
  prov_record create file "$STAMP20B" --pre-absent --post-file "$STAMP20B" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record create symlink "$GLOBAL_DIR20B" --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record register collection - --unit qmd-vault --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record replace file "$STUB20B" --pre-file "$SUITE_TMP/red20b-stub-pre" --backup --post-file "$STUB20B" \
    --scope machine --class code --row qmd-fork --writer fix-qmd-stub.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out20b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc20b=$?
check "RED20b: uninstall exit status" "$rc20b" "0"
check "RED20b: --purge-state removes the fork checkout dir" "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED20b: --purge-state removes the global symlink" "$([ -L "$GLOBAL_DIR20B" ] && echo yes || echo no)" "no"
check "RED20b: --purge-state calls qmd collection remove qmd-vault" \
  "$(grep -c 'collection remove qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "1"
check "RED20b: --purge-state STILL never touches the stub" "$(cat "$STUB20B")" "$(cat "$SUITE_TMP/red20b-stub-before")"
check "RED20b: stub kept line still printed under --purge-state" \
  "$(printf '%s\n' "$out20b" | grep -c 'qmd plugin stub himmel patched')" "1"

echo "==== RED21 (HIMMEL-3332 slice3): pre-existing qmd (no qmd-fork ledger rows) survives both modes byte-identical ===="
# The real qmd-bin.sh only ever calls _qmd_prov_record when IT created the
# path (preexisted=false); a pre-existing fork/symlink/collection gets no row
# at all (scripts/lib/qmd-bin.sh lines 590-657). A ledger session that
# recorded something unrelated (so LEDGER_OK=1) but nothing for qmd-fork is
# the realistic pre-existing-qmd shape, not an absent ledger (that is RED22).
new_case red21a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP21A="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'preexisting\n' > "$STAMP21A"
GLOBAL_DIR21A="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR21A")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR21A"
STUB21A="$CASE_DIR/stub-qmd-21a"; printf 'preexisting stub\n' > "$STUB21A"
cp "$STUB21A" "$SUITE_TMP/red21a-stub-before"
( prov_begin --writer install.sh -- seed-red21a >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit '/unrelated' --scope user --class code --row user-settings \
    --writer install.sh --pre-json 'null' --post-json 'null' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out21a=$(run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks); rc21a=$?
check "RED21a: uninstall exit status" "$rc21a" "0"
check "RED21a: default run keeps the fork checkout stamp byte-identical" "$(cat "$STAMP21A")" "preexisting"
check "RED21a: default run keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR21A" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED21a: default run keeps the stub byte-identical" "$(cat "$STUB21A")" "$(cat "$SUITE_TMP/red21a-stub-before")"
check "RED21a: stub kept line printed" \
  "$(printf '%s\n' "$out21a" | grep -c 'qmd plugin stub himmel patched')" "1"

new_case red21b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP21B="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'preexisting\n' > "$STAMP21B"
GLOBAL_DIR21B="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR21B")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR21B"
STUB21B="$CASE_DIR/stub-qmd-21b"; printf 'preexisting stub\n' > "$STUB21B"
cp "$STUB21B" "$SUITE_TMP/red21b-stub-before"
( prov_begin --writer install.sh -- seed-red21b >/dev/null
  prov_record noop json-key "$CASE_SETTINGS" --unit '/unrelated' --scope user --class code --row user-settings \
    --writer install.sh --pre-json 'null' --post-json 'null' --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out21b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc21b=$?
check "RED21b: uninstall exit status" "$rc21b" "0"
check "RED21b: --purge-state still keeps a pre-existing fork checkout stamp byte-identical" "$(cat "$STAMP21B")" "preexisting"
check "RED21b: --purge-state still keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR21B" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED21b: --purge-state never calls qmd collection remove for an unrecorded collection" \
  "$(grep -c 'collection remove' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "0"
check "RED21b: --purge-state still keeps the stub byte-identical" "$(cat "$STUB21B")" "$(cat "$SUITE_TMP/red21b-stub-before")"
check "RED21b: stub kept line still printed under --purge-state" \
  "$(printf '%s\n' "$out21b" | grep -c 'qmd plugin stub himmel patched')" "1"

echo "==== RED22 (HIMMEL-3332 slice3): no ledger at all -- --purge-state keeps qmd, it cannot tell installed from pre-existing ===="
new_case red22
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP22="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'no-ledger\n' > "$STAMP22"
GLOBAL_DIR22="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR22")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR22"
STUB22="$CASE_DIR/stub-qmd-22"; printf 'no-ledger stub\n' > "$STUB22"
cp "$STUB22" "$SUITE_TMP/red22-stub-before"
# no prov_begin/prov_record/prov_end at all -- a pre-ledger install.
out22=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc22=$?
check "RED22: uninstall exit status" "$rc22" "0"
check "RED22: --purge-state with no ledger keeps the fork checkout stamp byte-identical" "$(cat "$STAMP22")" "no-ledger"
check "RED22: --purge-state with no ledger keeps the global symlink pointed at the fork dir" \
  "$(readlink "$GLOBAL_DIR22" 2>/dev/null)" "$CASE_QMD_FORK_DIR"
check "RED22: --purge-state with no ledger never calls qmd collection remove" \
  "$(grep -c 'collection remove' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "0"
check "RED22: --purge-state with no ledger keeps the stub byte-identical" "$(cat "$STUB22")" "$(cat "$SUITE_TMP/red22-stub-before")"
check "RED22: no-ledger kept message printed" \
  "$(printf '%s\n' "$out22" | grep -c 'provenance cannot tell a himmel-created qmd')" "1"
check "RED22: stub kept line printed" \
  "$(printf '%s\n' "$out22" | grep -c 'qmd plugin stub himmel patched')" "1"

echo "==== RED23 (HIMMEL-3332 slice3 console ruling 1): a redirected/tampered fork-checkout stamp path is refused, never rm -rf'd ===="
# The ledger's recorded path for the qmd-fork file-create row resolves
# OUTSIDE the expected fork dir (QMD_FORK_DIR at record time != at uninstall
# time, or a tampered row) -- qmd_unwire_fork_checkout must refuse rather
# than rm -rf whatever dirname(path) turns out to be.
new_case red23
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
DECOY23="$CASE_DIR/decoy-dir"
mkdir -p "$DECOY23"
STAMP23="$DECOY23/.himmel-build-ok"; printf 'decoy\n' > "$STAMP23"
( prov_begin --writer install.sh -- seed-red23 >/dev/null
  prov_record create file "$STAMP23" --pre-absent --post-file "$STAMP23" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out23=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc23=$?
check "RED23: uninstall reports incomplete (halted) rather than a silent success" "$rc23" "2"
check "RED23: the decoy dir is NOT removed" "$([ -d "$DECOY23" ] && echo yes || echo no)" "yes"
check "RED23: the decoy stamp survives byte-identical" "$(cat "$STAMP23" 2>/dev/null)" "decoy"
check "RED23: a refusal warning is printed" \
  "$(printf '%s\n' "$out23" | grep -c 'refusing to remove unexpected path')" "1"

echo "==== RED24 (HIMMEL-3332 slice3 console ruling 1): a noop (not create) fork-checkout row keeps the dir even under --purge-state ===="
new_case red24
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
STAMP24="$CASE_QMD_FORK_DIR/.himmel-build-ok"; printf 'noop\n' > "$STAMP24"
( prov_begin --writer install.sh -- seed-red24 >/dev/null
  prov_record noop file "$STAMP24" --pre-file "$STAMP24" --post-file "$STAMP24" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=true >/dev/null
  prov_end ok >/dev/null )
out24=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc24=$?
check "RED24: uninstall exit status" "$rc24" "0"
check "RED24: a noop row keeps the fork checkout dir under --purge-state" "$([ -d "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED24: a noop row keeps the stamp byte-identical" "$(cat "$STAMP24" 2>/dev/null)" "noop"
check "RED24: a noop row is reported kept, not removed" \
  "$(printf '%s\n' "$out24" | grep -c 'removed:.*qmd fork checkout')" "0"

echo "==== RED25 (HIMMEL-3332 slice3 console ruling 1): a file-create row under a DIFFERENT row id is never touched by qmd dirname-removal ===="
# prov_read_units --row qmd-fork scopes the whole qmd unwire loop; a row filed
# under any other id must never reach qmd_unwire_fork_checkout, no matter its
# kind or ops. Prove it with a decoy dir that a matching bug WOULD remove.
new_case red25
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
mkdir -p "$CASE_QMD_FORK_DIR"
OTHERROW25="$CASE_DIR/other-row-dir"
mkdir -p "$OTHERROW25"
STAMP25="$OTHERROW25/.himmel-build-ok"; printf 'other-row\n' > "$STAMP25"
( prov_begin --writer install.sh -- seed-red25 >/dev/null
  prov_record create file "$STAMP25" --pre-absent --post-file "$STAMP25" --scope machine --class code \
    --row not-qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out25=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc25=$?
check "RED25: uninstall exit status" "$rc25" "0"
check "RED25: a file row under a different row id is never removed" "$([ -d "$OTHERROW25" ] && echo yes || echo no)" "yes"
check "RED25: its stamp survives byte-identical" "$(cat "$STAMP25" 2>/dev/null)" "other-row"
check "RED25: the qmd unwire loop never even mentions the other-row path" \
  "$(printf '%s\n' "$out25" | grep -c "$OTHERROW25")" "0"

echo "==== RED26 (HIMMEL-3332 slice3, critic panel codex-1): qmd collection remove runs before the fork checkout/symlink are unwired ===="
# A real qmd_cmd resolves through the bun-global symlink into the fork
# checkout's dist/cli/qmd.js, or (failing that) a `qmd` already on PATH.
# Removing the fork checkout or the global symlink before calling `qmd
# collection remove` can leave `qmd_cmd` unable to resolve at all in a real
# install. QMD_ORDER_CHECK_FORK_DIR/QMD_ORDER_CHECK_SYMLINK make the fake qmd
# stub fail exactly the way a real one would if the unwire loop got the order
# wrong, independent of which path a real qmd_cmd would have taken.
new_case red26
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
CASE_BUN_INSTALL="$CASE_DIR/bun"
# HIMMEL-3524: a real fork checkout is always a git work tree; a plain
# directory is the "unknown state" the fix now keeps rather than removes, so
# this --purge-state-removes fixture needs a clean git checkout to reach rm.
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
STAMP26="$CASE_QMD_FORK_DIR/.himmel-build-ok"
GLOBAL_DIR26="$CASE_BUN_INSTALL/install/global/node_modules/@tobilu/qmd"
mkdir -p "$(dirname "$GLOBAL_DIR26")"
ln -s "$CASE_QMD_FORK_DIR" "$GLOBAL_DIR26"
CASE_QMD_ORDER_CHECK_FORK_DIR="$CASE_QMD_FORK_DIR"
CASE_QMD_ORDER_CHECK_SYMLINK="$GLOBAL_DIR26"
CASE_QMD_COLLECTION_PATH="$CASE_QMD_FORK_DIR"
( prov_begin --writer install.sh -- seed-red26 >/dev/null
  prov_record create file "$STAMP26" --pre-absent --post-file "$STAMP26" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record create symlink "$GLOBAL_DIR26" --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_record register collection - --unit qmd-vault --post-text "$CASE_QMD_FORK_DIR" --scope machine --class code \
    --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out26=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc26=$?
check "RED26: uninstall exit status (collection remove succeeded while fork/symlink still resolved)" "$rc26" "0"
check "RED26: --purge-state still removes the fork checkout dir" "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED26: --purge-state still removes the global symlink" "$([ -L "$GLOBAL_DIR26" ] && echo yes || echo no)" "no"
check "RED26: --purge-state still calls qmd collection remove qmd-vault" \
  "$(grep -c 'collection remove qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null || echo 0)" "1"
check "RED26: the fake qmd never saw the fork checkout already removed" \
  "$(printf '%s\n' "$out26" | grep -c 'already removed')" "0"

echo "==== RED27 (HIMMEL-3524): a qmd fork checkout carrying user work is kept, never rm -rf'd, even under --purge-state ===="
# qmd_unwire_fork_checkout's ledger verdict only proves himmel CREATED the
# checkout; it says nothing about what has happened in it since. A real fork
# checkout is a git work tree, so the fix checks its live git state before
# removing it: a dirty tree (tracked-file edit or untracked file) or an
# unpushed local commit is user work the ledger cannot see, and must be kept.
new_case red27a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
( prov_begin --writer install.sh -- seed-red27a >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27a=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27a=$?
check "RED27a: uninstall exit status" "$rc27a" "0"
check "RED27a: a clean git fork checkout IS removed under --purge-state" "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED27a: a removed line is printed" \
  "$(printf '%s\n' "$out27a" | grep -c 'removed:.*qmd fork checkout')" "1"

new_case red27b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
printf 'edited by the user\n' > "$CASE_QMD_FORK_DIR/tracked.txt"
( prov_begin --writer install.sh -- seed-red27b >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27b=$?
check "RED27b: uninstall exit status" "$rc27b" "0"
check "RED27b: a fork checkout with a modified tracked file is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED27b: the edit survives byte-identical" "$(cat "$CASE_QMD_FORK_DIR/tracked.txt")" "edited by the user"
check "RED27b: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out27b" | grep -c 'kept:.*user-modified: uncommitted changes')" "1"

new_case red27c
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
printf 'new file\n' > "$CASE_QMD_FORK_DIR/untracked.txt"
( prov_begin --writer install.sh -- seed-red27c >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27c=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27c=$?
check "RED27c: uninstall exit status" "$rc27c" "0"
check "RED27c: a fork checkout with an untracked file is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED27c: the untracked file survives" "$([ -f "$CASE_QMD_FORK_DIR/untracked.txt" ] && echo yes || echo no)" "yes"
check "RED27c: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out27c" | grep -c 'kept:.*user-modified: uncommitted changes')" "1"

new_case red27d
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
printf 'local work\n' > "$CASE_QMD_FORK_DIR/tracked.txt"
git -C "$CASE_QMD_FORK_DIR" commit -q -am "local unpushed commit"
( prov_begin --writer install.sh -- seed-red27d >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out27d=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc27d=$?
check "RED27d: uninstall exit status" "$rc27d" "0"
check "RED27d: a fork checkout with an unpushed local commit is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED27d: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out27d" | grep -c 'kept:.*user-modified: unpushed local commits')" "1"

echo "==== RED28 (HIMMEL-3534): a qmd fork checkout carrying user data in a git-ignored path is kept ===="
# HIMMEL-3524's git-dirty check (RED27) is blind to ignored paths --
# `status --porcelain` never lists them, so a user file placed inside one
# (next to node_modules/ or dist/) read as clean and was silently rm -rf'd.
# The fix diffs ignored paths against an allowlist of what the fork's own
# build creates (node_modules/, dist/): anything else ignored is user work.

new_case red28a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
# Only the build's own output present -- a real built fork, nothing else.
mkdir -p "$CASE_QMD_FORK_DIR/node_modules" "$CASE_QMD_FORK_DIR/dist"
printf 'pkg\n' > "$CASE_QMD_FORK_DIR/node_modules/pkg.js"
printf 'out\n' > "$CASE_QMD_FORK_DIR/dist/out.js"
( prov_begin --writer install.sh -- seed-red28a >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out28a=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc28a=$?
check "RED28a: uninstall exit status" "$rc28a" "0"
check "RED28a: a fork checkout holding only allowlisted build output IS removed under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED28a: a removed line is printed" \
  "$(printf '%s\n' "$out28a" | grep -c 'removed:.*qmd fork checkout')" "1"

new_case red28b
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
# A user file dropped into a git-ignored path OUTSIDE the build's allowlist
# (not node_modules/ or dist/) -- e.g. next to the fork's own build output,
# matching the ticket's "a stray personal note" example.
mkdir -p "$CASE_QMD_FORK_DIR/notes"
printf 'secret user note\n' > "$CASE_QMD_FORK_DIR/notes/mine.txt"
( prov_begin --writer install.sh -- seed-red28b >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out28b=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc28b=$?
check "RED28b: uninstall exit status" "$rc28b" "0"
check "RED28b: a fork checkout with a user file in an ignored path outside the allowlist is KEPT under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "yes"
check "RED28b: the user's note survives" "$(cat "$CASE_QMD_FORK_DIR/notes/mine.txt")" "secret user note"
check "RED28b: a user-modified kept line is printed" \
  "$(printf '%s\n' "$out28b" | grep -c 'kept:.*user-modified: ignored files outside the build output')" "1"

new_case red28c
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
# A user file placed INSIDE an allowlisted dir (node_modules/) is still
# removed with the rest of the checkout -- the documented trade-off: the
# allowlist trusts the build's own directories wholesale, it does not
# distinguish a stray file from real build output within them.
mkdir -p "$CASE_QMD_FORK_DIR/node_modules"
printf 'not really a package\n' > "$CASE_QMD_FORK_DIR/node_modules/users-own-file.txt"
( prov_begin --writer install.sh -- seed-red28c >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out28c=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc28c=$?
check "RED28c: uninstall exit status" "$rc28c" "0"
check "RED28c: a user file inside an allowlisted build dir (node_modules/) is REMOVED with the checkout" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED28c: a removed line is printed" \
  "$(printf '%s\n' "$out28c" | grep -c 'removed:.*qmd fork checkout')" "1"

echo "==== RED29 (HIMMEL-3534, regression from HIMMEL-3524/#1175): the build stamp itself never blocks removal ===="
# _qmd_build_stamp (scripts/lib/qmd-bin.sh:82) writes .himmel-build-ok
# untracked at the fork root on every successful build. RED27's dirty-tree
# check (`status --porcelain --untracked-files=normal`) read that file as an
# untracked change on EVERY built fork, so --purge-state never removed one --
# _red_seed_git_fork now seeds the stamp on every case (matching a real
# build), which is what makes RED27a/26/20b exercise this path too.
new_case red29a
CASE_QMD_FORK_DIR="$CASE_DIR/qmd-fork"
_red_seed_git_fork "$CASE_QMD_FORK_DIR"
( prov_begin --writer install.sh -- seed-red29a >/dev/null
  prov_record create file "$CASE_QMD_FORK_DIR/.himmel-build-ok" --pre-absent --post-file "$CASE_QMD_FORK_DIR/.himmel-build-ok" \
    --scope machine --class code --row qmd-fork --writer qmd-bin.sh --field preexisted=false >/dev/null
  prov_end ok >/dev/null )
out29a=$(run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks); rc29a=$?
check "RED29a: uninstall exit status" "$rc29a" "0"
check "RED29a: a freshly built (stamp-only-dirty) fork checkout IS removed under --purge-state" \
  "$([ -e "$CASE_QMD_FORK_DIR" ] && echo yes || echo no)" "no"
check "RED29a: never reports the stamp itself as a user modification" \
  "$(printf '%s\n' "$out29a" | grep -c 'kept:.*user-modified')" "0"

echo "==== RED30 (HIMMEL-3525 S16 case f): a collection re-pointed after install survives --purge-state ===="
# The install recorded the collection's live identity token (name, canonical
# path, pattern) read back from qmd; the user then re-pointed the same name at
# another vault. The verdict re-reads the live identity, finds a token himmel
# never recorded, and keeps the collection. The control keeps the live path
# where the install left it, and the collection is removed.
tok30=$(printf 'collection\nqmd-vault\n/vaultA\n**/*.md' | _prov_sha256)
for sub in repointed control; do
  new_case "red30-$sub"
  ( prov_begin --writer install.sh -- "seed-red30-$sub" >/dev/null
    prov_record register collection - --unit qmd-vault --post-text "$tok30" --scope machine --class code \
      --row qmd-fork --writer qmd-bin.sh --field preexisted=false --field identity_v=1 >/dev/null
    prov_end ok >/dev/null )
  if [ "$sub" = repointed ]; then CASE_QMD_COLLECTION_PATH=/vaultB; want=0; else CASE_QMD_COLLECTION_PATH=/vaultA; want=1; fi
  run_uninstall --yes --purge-state --skip-tasks --skip-plugins --skip-hooks >/dev/null; rc30=$?
  check "RED30 $sub: uninstall exit status" "$rc30" "0"
  check "RED30 $sub: qmd collection remove qmd-vault called $want time(s)" \
    "$(grep -c 'collection remove qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null)" "$want"
  check "RED30 $sub: the verdict read the live identity" \
    "$(grep -c 'collection show qmd-vault' "$CASE_DIR/qmd.log" 2>/dev/null)" "1"
done
unset rc30 tok30 want

echo "==== RED31 (HIMMEL-3525 S17): a plugin/marketplace re-pointed after install survives --purge-state ===="
# Install recorded the marketplace's + plugin's live identity token (design
# §3.2/§3.3); the plugin's own identity folds in the marketplace's live
# token, so re-pointing the marketplace alone is enough to keep BOTH rows --
# no separate cascade logic needed. The control leaves the marketplace
# source where install left it: both remove.
new_case red31-tok
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
mkdir -p "$HOME/.claude/plugins"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
printf '{"himmel":{"source":{"source":"directory","path":"/clone"}}}\n' > "$HOME/.claude/plugins/known_marketplaces.json"
# shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
printf '{"version":2,"plugins":{"himmel-ops@himmel":[{"scope":"user"}]}}\n' > "$HOME/.claude/plugins/installed_plugins.json"
mkt_tok31=$(_provid_marketplace '{"unit":"himmel"}')
plug_tok31=$(_provid_plugin '{"unit":"himmel-ops@himmel","fields":{"cli_scope":"user","project_path":"","marketplace":"himmel"}}')

for sub in repointed control; do
  new_case "red31-$sub"
  # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
  mkdir -p "$HOME/.claude/plugins"
  if [ "$sub" = repointed ]; then
    # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
    printf '{"himmel":{"source":{"source":"directory","path":"/elsewhere"}}}\n' > "$HOME/.claude/plugins/known_marketplaces.json"
  else
    # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
    printf '{"himmel":{"source":{"source":"directory","path":"/clone"}}}\n' > "$HOME/.claude/plugins/known_marketplaces.json"
  fi
  # shellcheck disable=SC2031  # HOME is new_case's top-level export, not a subshell leak
  printf '{"version":2,"plugins":{"himmel-ops@himmel":[{"scope":"user"}]}}\n' > "$HOME/.claude/plugins/installed_plugins.json"
  ( prov_begin --writer install-plugins.sh -- "seed-red31-$sub" >/dev/null
    prov_record register marketplace - --unit himmel --scope machine --class code \
      --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=false \
      --post-text "$mkt_tok31" --field identity_v=1 >/dev/null
    prov_record register plugin - --unit himmel-ops@himmel --scope machine --class code \
      --writer install-plugins.sh --row plugins --field 'cli_scope="user"' --field 'marketplace="himmel"' \
      --field 'project_path=""' --field preexisted=false \
      --post-text "$plug_tok31" --field identity_v=1 >/dev/null
    prov_end ok >/dev/null )
  printf '[{"id":"himmel-ops@himmel","scope":"user"}]\n' > "$CASE_PLUGINS_JSON"
  printf '[{"name":"himmel"}]\n' > "$CASE_MARKETPLACES_JSON"
  out31=$(run_uninstall --yes --purge-state --skip-tasks --skip-hooks --skip-settings); rc31=$?
  check "RED31 $sub: uninstall exit status" "$rc31" "0"
  if [ "$sub" = repointed ]; then
    check "RED31 $sub: marketplace kept (changed since install)" \
      "$(printf '%s\n' "$out31" | grep -c 'kept (changed since install): himmel$')" "1"
    check "RED31 $sub: plugin kept (changed since install)" \
      "$(printf '%s\n' "$out31" | grep -c 'kept (changed since install): himmel-ops@himmel$')" "1"
    check "RED31 $sub: plugin left installed" \
      "$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length' "$CASE_PLUGINS_JSON")" "1"
    check "RED31 $sub: marketplace left registered" \
      "$(jq -r '[.[] | select(.name=="himmel")] | length' "$CASE_MARKETPLACES_JSON")" "1"
  else
    check "RED31 $sub: plugin removed" \
      "$(jq -r '[.[] | select(.id=="himmel-ops@himmel")] | length' "$CASE_PLUGINS_JSON")" "0"
    check "RED31 $sub: marketplace removed" \
      "$(jq -r '[.[] | select(.name=="himmel")] | length' "$CASE_MARKETPLACES_JSON")" "0"
  fi
done
unset mkt_tok31 plug_tok31 rc31 out31

echo "==== RED32 (HIMMEL-3525 S18): a cron line edited after install survives --purge-state ===="
# Install recorded the LIVE crontab line's identity token (marker-suffixed
# line, design §3.4); the user then hand-edited that line (same marker,
# different schedule). At base (a816d911) ledger_job_markers emits every
# recorded marker unconditionally with no identity check, so the edited line
# is stripped anyway (see the RED-at-base excerpt in the PR body). The
# verdict now re-reads the live crontab, finds a token himmel never
# recorded, and keeps the line. The control leaves the line exactly where
# install left it: it is removed. A duplicated marker (two lines ending in
# the same marker) is never resolved to one at random: kept,
# identity-unreadable.
tok32=$(printf 'job\n0 3 * * * run.sh # HIMMEL-Qmd-Reindex' | _prov_sha256)
for sub in edited control duplicated; do
  new_case "red32-$sub"
  ( prov_begin --writer cadence-arm -- "seed-red32-$sub" >/dev/null
    prov_record register job - --unit HIMMEL-Qmd-Reindex --scope user --class code \
      --writer cadence-arm --field 'scheduler="cron"' --field preexisted=false \
      --post-text "$tok32" --field identity_v=1 >/dev/null
    prov_end ok >/dev/null )
  CASE_CRONTAB_FILE="$CASE_DIR/crontab.txt"
  case "$sub" in
    edited)     printf '0 4 * * * run.sh # HIMMEL-Qmd-Reindex\n' > "$CASE_CRONTAB_FILE" ;;
    control)    printf '0 3 * * * run.sh # HIMMEL-Qmd-Reindex\n' > "$CASE_CRONTAB_FILE" ;;
    duplicated) printf '0 3 * * * run.sh # HIMMEL-Qmd-Reindex\n0 5 * * * other.sh # HIMMEL-Qmd-Reindex\n' > "$CASE_CRONTAB_FILE" ;;
  esac
  out32=$(run_uninstall --yes --skip-plugins --skip-hooks --skip-settings); rc32=$?
  check "RED32 $sub: uninstall exit status" "$rc32" "0"
  case "$sub" in
    edited)
      check "RED32 $sub: kept cron line (user-modified)" \
        "$(printf '%s\n' "$out32" | grep -c 'kept cron line HIMMEL-Qmd-Reindex (user-modified)')" "1"
      check "RED32 $sub: the edited line survives in the crontab" \
        "$(cat "$CASE_CRONTAB_FILE")" "0 4 * * * run.sh # HIMMEL-Qmd-Reindex" ;;
    control)
      check "RED32 $sub: removed cron job reported" \
        "$(printf '%s\n' "$out32" | grep -c 'removed cron job: HIMMEL-Qmd-Reindex')" "1"
      check "RED32 $sub: the line is gone from the crontab" \
        "$(cat "$CASE_CRONTAB_FILE")" "" ;;
    duplicated)
      check "RED32 $sub: kept cron line (identity-unreadable)" \
        "$(printf '%s\n' "$out32" | grep -c 'kept cron line HIMMEL-Qmd-Reindex (identity-unreadable)')" "1"
      check "RED32 $sub: both duplicated lines survive" \
        "$(wc -l < "$CASE_CRONTAB_FILE" | tr -d ' ')" "2" ;;
  esac
done
unset tok32 rc32 out32

echo "==== RED33 (HIMMEL-3541): settings containers + a scope marketplace entry install created ===="
# install-plugins.sh records a created-when-absent json-key row for the
# enabledPlugins / extraKnownMarketplaces containers and for a scope entry the
# CLI added for a marketplace that already existed (its register row reads
# preexisted, so step 7 keeps the marketplace). Uninstall removes the entry
# and drops each container once empty -- but only one the ledger shows absent.
for sub in created control; do
  new_case "red33-$sub"
  ENTRY33='{"source":{"source":"github","repo":"anthropics/claude-plugins-official"}}'
  # the state after step 4 removed the plugins: same bytes in both sub-cases,
  # only the ledger differs
  printf '{"enabledPlugins":{},"extraKnownMarketplaces":{"claude-plugins-official":%s}}\n' "$ENTRY33" > "$CASE_SETTINGS"
  ( prov_begin --writer install-plugins.sh -- seed-red33 >/dev/null
    prov_record register marketplace - --unit claude-plugins-official --scope machine --class code \
      --writer install-plugins.sh --row marketplaces --field 'cli_scope="user"' --field preexisted=true >/dev/null
    if [ "$sub" = created ]; then
      prov_record create json-key "$CASE_SETTINGS" --unit /extraKnownMarketplaces --pre-absent \
        --post-json "{\"claude-plugins-official\":$ENTRY33}" --scope user --class code --row user-settings --writer install-plugins.sh >/dev/null
      prov_record create json-key "$CASE_SETTINGS" --unit /enabledPlugins --pre-absent \
        --post-json '{"himmel-ops@himmel":true}' --scope user --class code --row user-settings --writer install-plugins.sh >/dev/null
    fi
    prov_record create json-key "$CASE_SETTINGS" --unit /extraKnownMarketplaces/claude-plugins-official --pre-absent \
      --post-json "$ENTRY33" --scope user --class code --row user-settings --writer install-plugins.sh >/dev/null
    prov_end ok >/dev/null )
  printf '[{"name":"claude-plugins-official"}]\n' > "$CASE_MARKETPLACES_JSON"
  run_uninstall --yes --keep-telegram-state --skip-tasks --skip-hooks >/dev/null
  case "$sub" in
    created)
      check "RED33 created: entry removed and both created containers dropped" \
        "$(jq -c . "$CASE_SETTINGS")" '{}' ;;
    control)
      check "RED33 control: entry removed, pre-existing containers kept (empty)" \
        "$(jq -c . "$CASE_SETTINGS")" '{"enabledPlugins":{},"extraKnownMarketplaces":{}}' ;;
  esac
done
unset ENTRY33

echo "==== REAL-LEDGER TRIPWIRE ===="
REAL_LEDGER_AFTER=$(real_ledger_state)
check "tripwire: operator's real ~/.himmel/provenance.jsonl untouched by this suite" \
  "$REAL_LEDGER_AFTER" "$REAL_LEDGER_BEFORE"

[ "$fails" -eq 0 ] && echo "UNINSTALL-PROVENANCE ALL PASS" || { echo "$fails UNINSTALL-PROVENANCE FAILED"; exit 1; }
