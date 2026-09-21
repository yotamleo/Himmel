#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-uninstall-routines.sh -- HIMMEL-3332 S8 RED tests: with a provenance
# ledger present, scripts/uninstall.sh removes the routines himmel brought
# (cron/at `job register` rows at [3/8], the telegram-bridge systemd unit +
# linger at [1/8], recorded project settings targets other than $PWD at [6/8])
# and reports the docs-only rows (`third-party-caches`, `tool register`) in the
# final "Kept" block. Hermetic: fake crontab/systemctl/loginctl/atq/at/atrm
# first on PATH (each logs its argv), a scratch HOME and a scratch
# HIMMEL_PROVENANCE_DIR per case. The operator's real crontab, systemd and HOME
# are never touched; a tripwire at the end checks the real ledger is unchanged.
#
# The crontab cases carry an UNRECORDED lookalike (a himmel-shaped line that no
# ledger row names) and assert it survives: a bug here loses a user's jobs.
#
# jq-only. Usage: bash scripts/test-uninstall-routines.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/scripts/lib"

command -v jq >/dev/null 2>&1 || { echo "test-uninstall-routines: jq required" >&2; exit 2; }
# shellcheck source=scripts/lib/provenance.sh
. "$lib/provenance.sh"

REAL_HOME="$HOME"
REAL_LEDGER="$REAL_HOME/.himmel/provenance.jsonl"
real_ledger_state() {
  if [ -f "$REAL_LEDGER" ]; then prov_sha_file "$REAL_LEDGER" 2>/dev/null || echo "ERROR-UNREADABLE"
  else echo "ABSENT"; fi
}
REAL_LEDGER_BEFORE=$(real_ledger_state)

SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-routines.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$SUITE_TMP"' EXIT

fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
has(){ case "$3" in *"$2"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] not in output"; fails=$((fails+1)) ;; esac; }

# ---- fakes ------------------------------------------------------------------
mkdir -p "$SUITE_TMP/bin"
# crontab: -l prints $FAKE_CRON_FILE (rc 1 + "no crontab" when the file is
# absent); FAKE_CRON_FAIL=1 makes -l fail rc 2 with stderr; `-` replaces the
# file with stdin. Every call's argv lands in $FAKE_CRON_LOG.
cat > "$SUITE_TMP/bin/crontab" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CRON_LOG"
case "${1:-}" in
  -l)
    [ "${FAKE_CRON_FAIL:-0}" = 1 ] && { echo "crontab: cannot read spool" >&2; exit 2; }
    [ -f "$FAKE_CRON_FILE" ] || { echo "no crontab for tester" >&2; exit 1; }
    cat "$FAKE_CRON_FILE" ;;
  -) cat > "$FAKE_CRON_FILE" ;;
  *) exit 2 ;;
esac
EOF
cat > "$SUITE_TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"
exit "${FAKE_SYSTEMCTL_RC:-0}"
EOF
cat > "$SUITE_TMP/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOGINCTL_LOG"
exit 0
EOF
# at family: $FAKE_AT_DIR/<id> holds a job body; atq lists the ids, at -c <id>
# prints the body, atrm <id> deletes it.
cat > "$SUITE_TMP/bin/atq" <<'EOF'
#!/usr/bin/env bash
for f in "$FAKE_AT_DIR"/*; do [ -f "$f" ] && printf '%s\tMon Jan  1 00:00:00 2099 a tester\n' "$(basename "$f")"; done
exit 0
EOF
cat > "$SUITE_TMP/bin/at" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-c" ] && cat "$FAKE_AT_DIR/$2"
EOF
cat > "$SUITE_TMP/bin/atrm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_AT_LOG"
rm -f "$FAKE_AT_DIR/$1"
EOF
chmod 755 "$SUITE_TMP"/bin/*

new_case() {
  CASE_DIR="$SUITE_TMP/$1"
  mkdir -p "$CASE_DIR/home/.claude" "$CASE_DIR/cwd" "$CASE_DIR/prov" "$CASE_DIR/units" "$CASE_DIR/at"
  export HOME="$CASE_DIR/home"
  export HIMMEL_PROVENANCE_DIR="$CASE_DIR/prov"
  unset CLAUDE_CONFIG_DIR
  CASE_SETTINGS="$HOME/.claude/settings.json"
  printf '{}\n' > "$CASE_SETTINGS"
  CRON="$CASE_DIR/crontab.txt"
  CRON_LOG="$CASE_DIR/crontab.log"; : > "$CRON_LOG"
  SYSTEMCTL_LOG="$CASE_DIR/systemctl.log"; : > "$SYSTEMCTL_LOG"
  LOGINCTL_LOG="$CASE_DIR/loginctl.log"; : > "$LOGINCTL_LOG"
  AT_LOG="$CASE_DIR/at.log"; : > "$AT_LOG"
  UNIT_DIR="$CASE_DIR/units"
  UNIT="$UNIT_DIR/telegram-bridge.service"
  PLUGINS_JSON="$CASE_DIR/plugins.json"; printf '[]\n' > "$PLUGINS_JSON"
  MARKETS_JSON="$CASE_DIR/markets.json"; printf '[]\n' > "$MARKETS_JSON"
}

# A fake claude so the plugin steps never reach a real one.
cat > "$SUITE_TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'plugin list --json'|'plugin marketplace list --json') echo '[]' ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$SUITE_TMP/bin/claude"

run_uninstall() {
  ( cd "$CASE_DIR/cwd" && \
    HIMMEL_USER_SETTINGS="$CASE_SETTINGS" \
    TELEGRAM_CHANNEL_DIR="$CASE_DIR/no-telegram" BRIDGE_ROOT="$CASE_DIR/no-bridge" \
    HIMMELCTL_CACHE_DIR="$CASE_DIR/no-cache" \
    HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$UNIT_DIR" \
    HIMMEL_PROVENANCE_DIR="$HIMMEL_PROVENANCE_DIR" \
    FAKE_CRON_FILE="$CRON" FAKE_CRON_LOG="$CRON_LOG" \
    FAKE_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" FAKE_LOGINCTL_LOG="$LOGINCTL_LOG" \
    FAKE_AT_DIR="$CASE_DIR/at" FAKE_AT_LOG="$AT_LOG" \
    PATH="$SUITE_TMP/bin:$PATH" USER=tester \
    bash "$repo_root/scripts/uninstall.sh" "$@" </dev/null 2>&1 )
}
# flags that isolate the step under test
BASE_FLAGS=(--yes --keep-telegram-state --skip-plugins --skip-hooks --skip-settings)

seed_job() { # <marker> <scheduler> <preexisted>
  ( prov_begin --writer cadence-arm -- "seed-$1" >/dev/null
    prov_record register job - --unit "$1" --scope user --class code --writer cadence-arm \
      --field "scheduler=\"$2\"" --field "preexisted=$3" >/dev/null
    prov_end ok >/dev/null )
}

echo "==== A: cron job rows removed by recorded identity; unrecorded lookalikes survive ===="
new_case a
cat > "$CRON" <<'EOF'
0 9 * * * /usr/bin/backup --mine # my-own-job
15 3 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Reindex
30 4 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Other
45 5 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Reindex-extra
EOF
seed_job HIMMEL-Qmd-Reindex cron false
out=$(run_uninstall "${BASE_FLAGS[@]}"); rc=$?
check "A1 rc" "$rc" "0"
check "A1 recorded cron line removed" "$(grep -c 'HIMMEL-Qmd-Reindex$' "$CRON")" "0"
check "A1 user line survives" "$(grep -c 'my-own-job' "$CRON")" "1"
check "A1 unrecorded lookalike (Other) survives" "$(grep -c 'HIMMEL-Qmd-Other' "$CRON")" "1"
check "A1 unrecorded lookalike (-extra) survives" "$(grep -c 'HIMMEL-Qmd-Reindex-extra' "$CRON")" "1"
has "A1 report names the removed job" "HIMMEL-Qmd-Reindex" "$out"

echo "==== A2: dry-run leaves the crontab alone ===="
new_case a2
cat > "$CRON" <<'EOF'
0 9 * * * /usr/bin/backup --mine # my-own-job
15 3 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Reindex
EOF
cp "$CRON" "$CASE_DIR/cron.before"
seed_job HIMMEL-Qmd-Reindex cron false
out=$(run_uninstall --dry-run "${BASE_FLAGS[@]}")
check "A2 crontab byte-identical" "$(cmp -s "$CRON" "$CASE_DIR/cron.before" && echo same || echo changed)" "same"
check "A2 no crontab write call" "$(grep -c '^-$' "$CRON_LOG")" "0"
has "A2 DRY line names the job" "HIMMEL-Qmd-Reindex" "$out"

echo "==== A3: a failing crontab -l never installs a rewrite (fail-closed) ===="
new_case a3
cat > "$CRON" <<'EOF'
15 3 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Reindex
EOF
seed_job HIMMEL-Qmd-Reindex cron false
out=$(FAKE_CRON_FAIL=1 run_uninstall "${BASE_FLAGS[@]}"); rc=$?
check "A3 no crontab write call" "$(grep -c '^-$' "$CRON_LOG")" "0"
check "A3 nonzero rc" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

echo "==== A4: a preexisted-only job row is kept ===="
new_case a4
cat > "$CRON" <<'EOF'
15 3 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Reindex
EOF
seed_job HIMMEL-Qmd-Reindex cron true
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "A4 preexisted line kept" "$(grep -c 'HIMMEL-Qmd-Reindex$' "$CRON")" "1"

echo "==== A5: no ledger, no recorded-job removal ===="
new_case a5
cat > "$CRON" <<'EOF'
15 3 * * * bash /x/scripts/luna/qmd-cadence.sh run # HIMMEL-Qmd-Reindex
EOF
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "A5 unrecorded line kept" "$(grep -c 'HIMMEL-Qmd-Reindex$' "$CRON")" "1"

echo "==== A6: at job carrying a recorded marker is removed, others kept ===="
new_case a6
printf '#!/bin/sh\necho run # HIMMEL-Pipeline-Sweep\n' > "$CASE_DIR/at/7"
printf '#!/bin/sh\necho run # HIMMEL-Pipeline-Other\n' > "$CASE_DIR/at/8"
printf '#!/bin/sh\necho mine\n' > "$CASE_DIR/at/9"
seed_job HIMMEL-Pipeline-Sweep at false
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "A6 recorded at job removed" "$([ -f "$CASE_DIR/at/7" ] && echo present || echo gone)" "gone"
check "A6 unrecorded lookalike at job kept" "$([ -f "$CASE_DIR/at/8" ] && echo present || echo gone)" "present"
check "A6 user at job kept" "$([ -f "$CASE_DIR/at/9" ] && echo present || echo gone)" "present"

# ---- B: the telegram-bridge systemd unit ------------------------------------
seed_unit() { # <linger true|false|null> [create|replace]
  printf '[Service]\nExecStart=/bin/true\n' > "$UNIT"
  ( prov_begin --writer bridge-persistence -- "seed-unit" >/dev/null
    if [ "${2:-create}" = replace ]; then
      printf '[Service]\nExecStart=/bin/operators-own\n' > "$CASE_DIR/unit.orig"
      prov_record replace file "$UNIT" --scope user --class code --writer bridge-persistence \
        --pre-file "$CASE_DIR/unit.orig" --backup --post-file "$UNIT" >/dev/null
    else
      prov_record create file "$UNIT" --scope user --class code --writer bridge-persistence \
        --pre-absent --post-file "$UNIT" >/dev/null
    fi
    prov_record register unit - --unit telegram-bridge.service --scope user --class code \
      --writer bridge-persistence --field "linger_preexisted=$1" >/dev/null
    prov_end ok >/dev/null )
}

echo "==== B1: bridge unit removed, mine.service untouched, linger preexisted -> no disable-linger ===="
new_case b1
printf '[Service]\nExecStart=/bin/mine\n' > "$UNIT_DIR/mine.service"
seed_unit true
out=$(run_uninstall "${BASE_FLAGS[@]}")
check "B1 bridge unit file removed" "$([ -f "$UNIT" ] && echo present || echo gone)" "gone"
check "B1 mine.service untouched" "$([ -f "$UNIT_DIR/mine.service" ] && echo present || echo gone)" "present"
check "B1 systemctl disable --now called" "$(grep -c '^--user disable --now telegram-bridge.service$' "$SYSTEMCTL_LOG")" "1"
check "B1 no systemctl call on mine.service" "$(grep -c 'mine.service' "$SYSTEMCTL_LOG")" "0"
check "B1 no disable-linger" "$(grep -c 'disable-linger' "$LOGINCTL_LOG")" "0"

echo "==== B2: linger not preexisting -> disable-linger <user> ===="
new_case b2
seed_unit false
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "B2 unit removed" "$([ -f "$UNIT" ] && echo present || echo gone)" "gone"
check "B2 disable-linger tester" "$(grep -c '^disable-linger tester$' "$LOGINCTL_LOG")" "1"

echo "==== B3: linger unknown (null) -> no disable-linger ===="
new_case b3
seed_unit null
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "B3 unit removed" "$([ -f "$UNIT" ] && echo present || echo gone)" "gone"
check "B3 no disable-linger" "$(grep -c 'disable-linger' "$LOGINCTL_LOG")" "0"

echo "==== B4: user-modified unit kept, no disable ===="
new_case b4
seed_unit false
printf '[Service]\nExecStart=/bin/edited-by-user\n' > "$UNIT"
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "B4 edited unit kept" "$(grep -c edited-by-user "$UNIT")" "1"
check "B4 no disable call" "$(grep -c 'disable' "$SYSTEMCTL_LOG")" "0"
check "B4 no disable-linger" "$(grep -c 'disable-linger' "$LOGINCTL_LOG")" "0"

echo "==== B5: replaced operator unit is restored, not disabled ===="
new_case b5
seed_unit false replace
run_uninstall "${BASE_FLAGS[@]}" >/dev/null
check "B5 operator's unit bytes back" "$(grep -c operators-own "$UNIT" 2>/dev/null)" "1"
check "B5 no disable --now" "$(grep -c 'disable --now' "$SYSTEMCTL_LOG")" "0"

echo "==== B6: dry-run changes nothing ===="
new_case b6
seed_unit false
out=$(run_uninstall --dry-run "${BASE_FLAGS[@]}")
check "B6 unit still there" "$([ -f "$UNIT" ] && echo present || echo gone)" "present"
check "B6 no systemctl call" "$(grep -c . "$SYSTEMCTL_LOG")" "0"
check "B6 no loginctl call" "$(grep -c . "$LOGINCTL_LOG")" "0"
has "B6 DRY line for disable" "DRY: systemctl --user disable --now telegram-bridge.service" "$out"

# ---- C: recorded project targets other than $PWD ----------------------------
seed_project() { # <dir>: wire himmel hooks into <dir>/.claude/settings.json under this case's ledger
  mkdir -p "$1/.claude"
  printf '{"foreign":"keep-me"}\n' > "$1/.claude/settings.json"
  bash "$lib/wire-pretooluse-hooks.sh" "$1/.claude/settings.json" '$CLAUDE_PROJECT_DIR' >/dev/null
}
hooks_left() { jq -r '[(.hooks.PreToolUse // [])[].hooks[].command | select(test("scripts/hooks/"))] | length' "$1"; }

echo "==== C1: a recorded second project target is unwired, foreign key survives ===="
new_case c1
OTHER="$CASE_DIR/other project"
seed_project "$OTHER"
check "C1 fixture wired" "$([ "$(hooks_left "$OTHER/.claude/settings.json")" -gt 0 ] && echo wired || echo bare)" "wired"
out=$(run_uninstall --yes --keep-telegram-state --skip-plugins --skip-hooks --skip-tasks); rc=$?
check "C1 rc" "$rc" "0"
check "C1 himmel hooks gone from the other target" "$(hooks_left "$OTHER/.claude/settings.json")" "0"
check "C1 foreign key survives" "$(jq -r .foreign "$OTHER/.claude/settings.json")" "keep-me"

echo "==== C2: a recorded target whose .claude became a symlink is refused, left untouched ===="
new_case c2
OTHER="$CASE_DIR/other project"
seed_project "$OTHER"
mv "$OTHER/.claude" "$CASE_DIR/elsewhere"
ln -s "$CASE_DIR/elsewhere" "$OTHER/.claude"
cp "$CASE_DIR/elsewhere/settings.json" "$CASE_DIR/settings.before"
out=$(run_uninstall --yes --keep-telegram-state --skip-plugins --skip-hooks --skip-tasks); rc=$?
check "C2 nonzero rc" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "C2 symlink destination untouched" "$(cmp -s "$CASE_DIR/elsewhere/settings.json" "$CASE_DIR/settings.before" && echo same || echo changed)" "same"
has "C2 refusal names the symlink" "symlinked target" "$out"

echo "==== C4: a recorded target that is himmel's own checkout is kept ===="
new_case c4
SRC="$CASE_DIR/source-checkout"
mkdir -p "$SRC/scripts"
cp "$repo_root/scripts/uninstall.sh" "$SRC/scripts/uninstall.sh"
ln -s "$lib" "$SRC/scripts/lib"
ln -s "$repo_root/scripts/install" "$SRC/scripts/install"
seed_project "$SRC"
cp "$SRC/.claude/settings.json" "$CASE_DIR/settings.before"
out=$( cd "$CASE_DIR/cwd" && HIMMEL_USER_SETTINGS="$CASE_SETTINGS" \
    TELEGRAM_CHANNEL_DIR="$CASE_DIR/no-telegram" BRIDGE_ROOT="$CASE_DIR/no-bridge" \
    HIMMELCTL_CACHE_DIR="$CASE_DIR/no-cache" PATH="$SUITE_TMP/bin:$PATH" \
    bash "$SRC/scripts/uninstall.sh" --yes --keep-telegram-state --skip-plugins --skip-hooks --skip-tasks </dev/null 2>&1 ); rc=$?
check "C4 rc" "$rc" "0"
check "C4 own checkout's settings byte-identical" "$(cmp -s "$SRC/.claude/settings.json" "$CASE_DIR/settings.before" && echo same || echo changed)" "same"
has "C4 reported kept" "himmel's own checkout" "$out"

echo "==== C3: dry-run leaves the recorded target as is ===="
new_case c3
OTHER="$CASE_DIR/other project"
seed_project "$OTHER"
cp "$OTHER/.claude/settings.json" "$CASE_DIR/settings.before"
run_uninstall --dry-run --yes --keep-telegram-state --skip-plugins --skip-hooks --skip-tasks >/dev/null
check "C3 target byte-identical" "$(cmp -s "$OTHER/.claude/settings.json" "$CASE_DIR/settings.before" && echo same || echo changed)" "same"

# ---- D: env-key removal already on the ledger path (S6) ---------------------
echo "==== D: CLAUDE_HUD_ALLOW_EXTRA_CMD env key removed on the ledger path ===="
new_case d
printf '{"foreign":"keep-me"}\n' > "$CASE_SETTINGS"
bash "$lib/wire-statusline.sh" "$CASE_SETTINGS" "$repo_root" >/dev/null 2>&1
check "D fixture: env key wired" "$(jq -r '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD // "absent"' "$CASE_SETTINGS")" "1"
run_uninstall --yes --keep-telegram-state --skip-plugins --skip-hooks --skip-tasks >/dev/null
check "D env key removed" "$(jq -r '.env.CLAUDE_HUD_ALLOW_EXTRA_CMD // "absent"' "$CASE_SETTINGS")" "absent"
check "D foreign key survives" "$(jq -r .foreign "$CASE_SETTINGS")" "keep-me"

# ---- E: docs-only rows in the final Kept report -----------------------------
echo "==== E: third-party-caches + tool register rows reported as kept ===="
new_case e
( prov_begin --writer machine-setup -- seed-e >/dev/null
  prov_record register tool - --unit qmd --scope machine --class keep --writer machine-setup \
    --field 'note="npm i -g qmd"' >/dev/null
  prov_end ok >/dev/null )
out=$(run_uninstall "${BASE_FLAGS[@]}")
kept_block=${out##*NOT touched (by design):}
has "E tool row reported under NOT touched" "qmd" "$kept_block"
has "E third-party-caches named, not a bare dash" "(third-party-caches)" "$kept_block"

# ---- tripwire ---------------------------------------------------------------
check "real ledger untouched" "$(real_ledger_state)" "$REAL_LEDGER_BEFORE"

echo
[ "$fails" -eq 0 ] && { echo "test-uninstall-routines: all passed"; exit 0; }
echo "test-uninstall-routines: $fails FAILED"; exit 1
