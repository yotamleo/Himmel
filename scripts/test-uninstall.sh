#!/usr/bin/env bash
# Smoke test for scripts/uninstall.sh (HIMMEL-227 offboard).
# State-touching invocations point TELEGRAM_CHANNEL_DIR + BRIDGE_ROOT at temp
# dirs and pass --skip-tasks --skip-plugins --skip-hooks where destructive, so
# the operator's real bridge, scheduled tasks, plugins, and git hooks are
# never touched. Two deliberate exceptions: test 2 sets no env overrides (the
# unknown flag must abort during arg parsing, before any state is read or
# removed), and test 6 points TELEGRAM_CHANNEL_DIR at $HOME on purpose to
# prove the suspicious-path guard refuses it (nothing is removed). The
# bridge-stop step runs only against a stubbed `bun` + supervisor.pid seeded
# in a temp BRIDGE_ROOT; scheduled-job discovery runs only against
# PATH-stubbed schtasks/atq/at/crontab under --dry-run — except 9e/9f, which
# exercise the WET crontab rewrite against a stdin-capturing crontab stub
# (PATH puts the stub first, so the real crontab is never invoked).
# Partial-delete residue detection (an open handle surviving rm) is covered
# by the PS sibling test-uninstall.ps1 — bash has no portable way to hold an
# open handle that blocks rm, so this suite does not assert it.
set -uo pipefail

CLI="$(cd "$(dirname "$0")" && pwd)/uninstall.sh"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — output missing: $needle"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL $label — output unexpectedly contains: $needle"
            FAILED=$((FAILED + 1))
            ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Redirect the [6/6] settings-unwire target away from the operator's REAL
# ~/.claude/settings.json for the whole suite (HIMMEL-460). The dedicated SC6
# cases re-seed this file per-test; the others simply never touch the real one.
export HIMMEL_USER_SETTINGS="$TMP/user-settings.json"
printf '{}\n' > "$HIMMEL_USER_SETTINGS"

mk_state() {
    CHANNEL="$TMP/channels/telegram"
    BRIDGE="$TMP/bridge"
    rm -rf "$CHANNEL" "$BRIDGE"
    mkdir -p "$CHANNEL" "$BRIDGE/sessions/S1"
    printf 'TELEGRAM_BOT_TOKEN=123:abc\n' > "$CHANNEL/.env"
    printf '{"allowFrom":["42"]}\n' > "$CHANNEL/access.json"
    printf 'x\n' > "$BRIDGE/sessions/S1/inbox.jsonl"
}

# 1. fail-closed: non-interactive without --yes aborts, removes nothing
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" \
    bash "$CLI" --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "non-interactive without --yes aborts" 2 "$rc"
assert_has "abort message names --yes" "non-interactive run without --yes" "$out"
if [ -f "$CHANNEL/access.json" ] && [ -d "$BRIDGE" ]; then
    echo "PASS nothing removed on abort"
else
    echo "FAIL state was removed despite abort"; FAILED=$((FAILED + 1))
fi

# 2. unknown flag rejected
out=$(bash "$CLI" --bogus </dev/null 2>&1); rc=$?
assert_rc "unknown flag rejected" 2 "$rc"

# 3. dry-run: prints actions, removes nothing, needs no confirmation
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" \
    bash "$CLI" --dry-run --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "dry-run exits 0" 0 "$rc"
assert_has "dry-run prints DRY rm for channel dir" "DRY: rm -rf -- $CHANNEL" "$out"
assert_has "dry-run prints DRY rm for bridge root" "DRY: rm -rf -- $BRIDGE" "$out"
if [ -f "$CHANNEL/access.json" ] && [ -f "$BRIDGE/sessions/S1/inbox.jsonl" ]; then
    echo "PASS dry-run removed nothing"
else
    echo "FAIL dry-run removed state"; FAILED=$((FAILED + 1))
fi
assert_has "dry-run reports bridge not running" "bridge not running" "$out"

# 4. --yes: removes telegram + bridge state (skips tasks/plugins/hooks)
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "--yes run exits 0" 0 "$rc"
if [ -e "$CHANNEL" ] || [ -e "$BRIDGE" ]; then
    echo "FAIL --yes run left state behind"
    FAILED=$((FAILED + 1))
else
    echo "PASS telegram pairing + bridge state removed"
fi
assert_has "--yes run notes BotFather revocation" "revoke the token via @BotFather" "$out"
assert_has "skip-tasks honored" "kept (--skip-tasks)" "$out"
assert_has "skip-plugins honored" "kept (--skip-plugins)" "$out"
assert_has "skip-hooks honored" "kept (--skip-hooks)" "$out"

# 5. --keep-telegram-state: state survives a --yes run
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" \
    bash "$CLI" --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "--keep-telegram-state run exits 0" 0 "$rc"
if [ -f "$CHANNEL/access.json" ] && [ -d "$BRIDGE" ]; then
    echo "PASS telegram state kept"
else
    echo "FAIL telegram state removed despite --keep-telegram-state"; FAILED=$((FAILED + 1))
fi

# 6. suspicious-path guard: refuses HOME even when asked
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$HOME" BRIDGE_ROOT="$BRIDGE" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "HOME-as-target run exits 0" 0 "$rc"
assert_has "refuses to rm HOME" "refusing to remove suspicious path" "$out"
assert_not_has "guard refusal not reported as rm failure" "failed to remove" "$out"
assert_not_has "guard refusal does not suggest manual removal" "residue remains" "$out"
if [ -d "$HOME" ]; then
    echo "PASS HOME survived"
else
    echo "FAIL HOME gone (!)"; FAILED=$((FAILED + 1))
fi

# Tests 7-12 run the CLI under a controlled PATH (stub dir first:
# "$STUB_WIN/$STUB_NIX/$STUB_BUN:/usr/bin:/bin") so command -v resolves to
# the stubs (and, for the unix-branch tests, so the real Windows schtasks is
# invisible). All discovery tests use --dry-run: even if a stub leaked a
# name, no delete would execute.

# 7. scheduled-task discovery (stubbed schtasks): CSV extraction incl. a
#    path-prefixed task name + DRY delete preview
mk_state
STUB_WIN="$TMP/stub-win"
mkdir -p "$STUB_WIN"
cat > "$STUB_WIN/schtasks" <<'STUB_EOF'
#!/usr/bin/env bash
case "$*" in
  *"/query /fo CSV /nh"*)
    printf '%s\n' '"\HIMMEL-Resume-X","Ready"' '"HIMMEL-Resume-Y","Running"' '"UnrelatedTask","Ready"'
    exit 0 ;;
  *"/query /tn HimmelTelegramBridge"*) exit 0 ;;
  *) exit 1 ;;
esac
STUB_EOF
chmod +x "$STUB_WIN/schtasks"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_WIN:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "stubbed schtasks dry-run exits 0" 0 "$rc"
assert_has "path-prefixed task name extracted" "DRY: schtasks /delete /tn HIMMEL-Resume-X /f" "$out"
assert_has "plain task name extracted" "DRY: schtasks /delete /tn HIMMEL-Resume-Y /f" "$out"
assert_has "bridge logon task included" "DRY: schtasks /delete /tn HimmelTelegramBridge /f" "$out"
assert_not_has "unrelated task untouched" "UnrelatedTask" "$out"

# 8. schtasks enumeration failure is WARNed, not masked as "no tasks"
cat > "$STUB_WIN/schtasks" <<'STUB_EOF'
#!/usr/bin/env bash
exit 1
STUB_EOF
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_WIN:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "query-failure dry-run still exits 0" 0 "$rc"
assert_has "query failure WARNs" "WARN: schtasks /query failed (rc=1)" "$out"
assert_not_has "query failure not masked as no-tasks" "no matching scheduled tasks found" "$out"

# 9. at/crontab discovery (no schtasks on PATH): stubbed atq/at/crontab
mk_state
STUB_NIX="$TMP/stub-nix"
mkdir -p "$STUB_NIX"
cat > "$STUB_NIX/atq" <<'STUB_EOF'
#!/usr/bin/env bash
printf '5\tTue Jun 16 03:00:00 2026 a user\n'
STUB_EOF
cat > "$STUB_NIX/at" <<'STUB_EOF'
#!/usr/bin/env bash
echo 'claude resume for HIMMEL-Resume-X'
STUB_EOF
cat > "$STUB_NIX/crontab" <<'STUB_EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-l" ] && echo '0 3 * * 0 run-something # HIMMEL-Resume-Y'
exit 0
STUB_EOF
chmod +x "$STUB_NIX/atq" "$STUB_NIX/at" "$STUB_NIX/crontab"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "stubbed at/crontab dry-run exits 0" 0 "$rc"
assert_has "at job extracted" "DRY: atrm 5" "$out"
assert_has "crontab strip previewed" "DRY: crontab — strip lines containing HIMMEL-Resume-" "$out"

# 9b. atq enumeration failure is WARNed
cat > "$STUB_NIX/atq" <<'STUB_EOF'
#!/usr/bin/env bash
exit 1
STUB_EOF
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "atq-failure dry-run still exits 0" 0 "$rc"
assert_has "atq failure WARNs" "WARN: atq failed (rc=1)" "$out"

# 9c. crontab read failure (rc!=1 + real error) is WARNed, not masked as
#     "no jobs" — and the rewrite (which would install an EMPTY crontab from
#     the failed listing) must not run.
cat > "$STUB_NIX/atq" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
cat > "$STUB_NIX/crontab" <<'STUB_EOF'
#!/usr/bin/env bash
echo 'crontab: cannot connect to cron daemon' >&2
exit 2
STUB_EOF
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "crontab-failure dry-run still exits 0" 0 "$rc"
assert_has "crontab read failure WARNs" "WARN: crontab -l failed (rc=2)" "$out"
assert_not_has "crontab failure not masked as no-jobs" "no matching scheduled jobs found" "$out"
assert_not_has "no rewrite attempted on failed listing" "stripped HIMMEL-Resume-" "$out"

# 9d. the trusted no-crontab-yet signature (rc=1 + "no crontab for <user>")
#     is NOT a failure — quiet, and "no matching" is reported.
cat > "$STUB_NIX/crontab" <<'STUB_EOF'
#!/usr/bin/env bash
echo 'no crontab for fakeuser' >&2
exit 1
STUB_EOF
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "no-crontab dry-run exits 0" 0 "$rc"
assert_not_has "no-crontab signature not WARNed" "WARN: crontab -l failed" "$out"
assert_has "no-crontab reports no matching jobs" "no matching scheduled jobs found" "$out"

# 9d2. rc=1 WITH real stderr (the fail-closed else branch): the classifier
#     must NOT treat this as a trusted "no crontab" response — it must WARN
#     and skip the rewrite, so unrelated cron jobs are never wiped.
cat > "$STUB_NIX/crontab" <<'STUB_EOF'
#!/usr/bin/env bash
echo 'crontab: some real error' >&2
exit 1
STUB_EOF
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "rc1-real-stderr dry-run still exits 0" 0 "$rc"
assert_has "rc1-real-stderr WARNs" "WARN: crontab -l failed (rc=1)" "$out"
assert_not_has "rc1-real-stderr not masked as no-jobs" "no matching scheduled jobs found" "$out"
assert_not_has "rc1-real-stderr rewrite not attempted" "stripped HIMMEL-Resume-" "$out"

# 9e. WET crontab rewrite (no --dry-run; the cron leg actually executes):
#     atq is stubbed to an empty listing, schtasks is invisible, and the
#     crontab stub captures the rewrite's stdin to a file — the operator's
#     real crontab is never invoked. The failure mode pinned here is wiping
#     unrelated cron jobs: the unrelated line must SURVIVE the rewrite and
#     the HIMMEL line must be gone.
mk_state
CRON_CAPTURE="$TMP/cron-capture"
rm -f "$CRON_CAPTURE"
cat > "$STUB_NIX/atq" <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
cat > "$STUB_NIX/crontab" <<STUB_EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then
  printf '%s\n' '0 3 * * 0 run-himmel # HIMMEL-Resume-Y' '15 4 * * * unrelated-job'
  exit 0
fi
if [ "\${1:-}" = "-" ]; then
  cat > "$CRON_CAPTURE"
  exit 0
fi
exit 1
STUB_EOF
chmod +x "$STUB_NIX/atq" "$STUB_NIX/crontab"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --yes --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "wet crontab rewrite exits 0" 0 "$rc"
assert_has "wet rewrite reports stripped" "stripped HIMMEL-Resume-* lines from crontab" "$out"
assert_not_has "wet rewrite does not WARN" "failed to rewrite crontab" "$out"
if [ -f "$CRON_CAPTURE" ] && grep -qF 'unrelated-job' "$CRON_CAPTURE"; then
    echo "PASS unrelated cron line survives the rewrite"
else
    echo "FAIL unrelated cron line missing from rewritten crontab (capture: $(cat "$CRON_CAPTURE" 2>/dev/null))"
    FAILED=$((FAILED + 1))
fi
if grep -qF 'HIMMEL-Resume-' "$CRON_CAPTURE" 2>/dev/null; then
    echo "FAIL HIMMEL-Resume- line still present in rewritten crontab"
    FAILED=$((FAILED + 1))
else
    echo "PASS HIMMEL-Resume- line stripped from rewritten crontab"
fi

# 9f. WET rewrite where EVERY line matched (the '|| true' leg): grep -v
#     exits 1 with empty output — a legitimately EMPTY crontab is installed.
#     Captured stdin must be empty, reported as stripped, no WARN.
mk_state
rm -f "$CRON_CAPTURE"
cat > "$STUB_NIX/crontab" <<STUB_EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then
  echo '0 3 * * 0 run-himmel # HIMMEL-Resume-Y'
  exit 0
fi
if [ "\${1:-}" = "-" ]; then
  cat > "$CRON_CAPTURE"
  exit 0
fi
exit 1
STUB_EOF
chmod +x "$STUB_NIX/crontab"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:/usr/bin:/bin" \
    bash "$CLI" --yes --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "all-matched wet rewrite exits 0" 0 "$rc"
assert_has "all-matched rewrite reports stripped" "stripped HIMMEL-Resume-* lines from crontab" "$out"
assert_not_has "all-matched rewrite does not WARN" "failed to rewrite crontab" "$out"
if [ -f "$CRON_CAPTURE" ] && [ ! -s "$CRON_CAPTURE" ]; then
    echo "PASS legitimately empty crontab installed (captured stdin empty)"
else
    echo "FAIL expected empty rewrite capture (capture: $(cat "$CRON_CAPTURE" 2>/dev/null))"
    FAILED=$((FAILED + 1))
fi

# Tests 10-12 seed an impossible PID (99999999, > kernel pid_max): even if a
# REAL supervisor --kill ever ran against the seeded pidfile (stub leak), the
# bare number fails parsePidfile (no `supervisor` field) → rc=2, nothing is
# ever signalled.

# 10. bridge-stop: BRIDGE_ROOT pass-through to the stubbed supervisor --kill
mk_state
printf '99999999\n' > "$BRIDGE/supervisor.pid"
STUB_BUN="$TMP/stub-bun"
mkdir -p "$STUB_BUN"
cat > "$STUB_BUN/bun" <<STUB_EOF
#!/usr/bin/env bash
printf 'BRIDGE_ROOT=%s\nARGS=%s\n' "\$BRIDGE_ROOT" "\$*" > "$TMP/bun-call.log"
exit "\${BUN_STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB_BUN/bun"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_BUN:/usr/bin:/bin" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "bridge-stop run exits 0" 0 "$rc"
if grep -q "^BRIDGE_ROOT=$BRIDGE$" "$TMP/bun-call.log" 2>/dev/null; then
    echo "PASS BRIDGE_ROOT passed through to supervisor --kill"
else
    echo "FAIL BRIDGE_ROOT not passed through (log: $(cat "$TMP/bun-call.log" 2>/dev/null))"
    FAILED=$((FAILED + 1))
fi
if grep -q "supervisor.ts --kill" "$TMP/bun-call.log" 2>/dev/null; then
    echo "PASS supervisor.ts --kill invoked"
else
    echo "FAIL supervisor.ts --kill not invoked"; FAILED=$((FAILED + 1))
fi
if [ -e "$CHANNEL" ] || [ -e "$BRIDGE" ]; then
    echo "FAIL state left behind after successful kill"; FAILED=$((FAILED + 1))
else
    echo "PASS state removed after successful kill"
fi

# 11. bridge-stop failure (rc>=2) WARNs and gates state removal
mk_state
printf '99999999\n' > "$BRIDGE/supervisor.pid"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" BUN_STUB_RC=2 PATH="$STUB_BUN:/usr/bin:/bin" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "kill-failure run still exits 0" 0 "$rc"
assert_has "kill failure WARNs" "supervisor --kill rc=2 — bridge may still be running" "$out"
assert_has "state removal skipped while bridge may run" "SKIPPED: step 1 could not stop the bridge" "$out"
if [ -f "$CHANNEL/access.json" ] && [ -f "$BRIDGE/sessions/S1/inbox.jsonl" ]; then
    echo "PASS state preserved while bridge may be running"
else
    echo "FAIL state removed despite live-bridge risk"; FAILED=$((FAILED + 1))
fi

# 12. bun missing with a live pidfile also gates state removal.
#     Guard: this test relies on bun being ABSENT from /usr/bin:/bin — if a
#     real bun lives there, the REAL supervisor --kill would run against the
#     seeded pidfile (harmless thanks to the impossible PID, but the
#     bun-missing branch is unreachable), so SKIP instead of failing.
if PATH="/usr/bin:/bin" command -v bun >/dev/null 2>&1; then
    echo "SKIP test 12 — real bun found in /usr/bin:/bin; bun-missing branch not reachable here"
else
    mk_state
    printf '99999999\n' > "$BRIDGE/supervisor.pid"
    out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="/usr/bin:/bin" \
        bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
    assert_rc "bun-missing run still exits 0" 0 "$rc"
    assert_has "bun missing WARNs" "bun is not on PATH" "$out"
    assert_has "bun-missing run skips state removal" "SKIPPED: step 1 could not stop the bridge" "$out"
    if [ -f "$CHANNEL/access.json" ]; then
        echo "PASS state preserved when bridge cannot be stopped"
    else
        echo "FAIL state removed though bridge could not be stopped"; FAILED=$((FAILED + 1))
    fi
fi

# ── SC6 (HIMMEL-460): [6/6] settings unwire ─────────────────────────────────
# Seed a settings.json carrying everything setup/adopt wire PLUS non-himmel keys
# that MUST survive (rtk guard, a custom statusLine sibling, an MCP allow).
seed_settings() {
  cat > "$HIMMEL_USER_SETTINGS" <<'JSON'
{
  "statusLine": {"type":"command","command":"bash \"C:/h/scripts/statusline/bin/statusline.sh\""},
  "env": {"HIMMEL_REPO":"C:/h","LUNA_VAULT_PATH":"C:/v","KEEP_ME":"1"},
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[
        {"type":"command","command":"bash C:/h/scripts/hooks/auto-approve-safe-bash.sh"},
        {"type":"command","command":"bash /opt/rtk-hook-guard.sh"}
      ]},
      {"matcher":"*","hooks":[{"type":"command","command":"bash C:/h/scripts/hooks/auto-arm-on-cap.sh"}]}
    ],
    "SessionStart": [
      {"hooks":[
        {"type":"command","command":"bash C:/h/scripts/hooks/check-update-available.sh"},
        {"type":"command","command":"bash C:/h/scripts/hooks/inject-initiative.sh"}
      ]}
    ]
  },
  "permissions": {"allow":["mcp__obsidian-vault__obsidian_simple_search"]}
}
JSON
}

# 13. [6/6] clears the wiring, preserves non-himmel keys.
seed_settings
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none1" BRIDGE_ROOT="$TMP/none1b" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "[6/6] run exits 0" 0 "$rc"
assert_has "[6/6] banner present" "[6/6] Unwiring" "$out"
assert_rc "statusLine removed"      "null"   "$(jq -r '.statusLine // "null"' "$HIMMEL_USER_SETTINGS")"
assert_rc "HIMMEL_REPO removed"     "null"   "$(jq -r '.env.HIMMEL_REPO // "null"' "$HIMMEL_USER_SETTINGS")"
assert_rc "LUNA_VAULT_PATH removed" "null"   "$(jq -r '.env.LUNA_VAULT_PATH // "null"' "$HIMMEL_USER_SETTINGS")"
assert_rc "non-himmel env kept"     "1"      "$(jq -r '.env.KEEP_ME' "$HIMMEL_USER_SETTINGS")"
assert_rc "UNIVERSAL hook removed"  "0"      "$(jq -r '[.hooks.PreToolUse[].hooks[].command|select(test("auto-approve-safe-bash"))]|length' "$HIMMEL_USER_SETTINGS")"
assert_rc "rtk guard preserved"     "1"      "$(jq -r '[.hooks.PreToolUse[].hooks[].command|select(test("rtk-hook-guard"))]|length' "$HIMMEL_USER_SETTINGS")"
assert_rc "dev-only hook preserved" "1"      "$(jq -r '[.hooks.PreToolUse[].hooks[].command|select(test("auto-arm-on-cap"))]|length' "$HIMMEL_USER_SETTINGS")"
assert_rc "inject-initiative removed" "0"    "$(jq -r '[.hooks.SessionStart[].hooks[].command|select(test("inject-initiative"))]|length' "$HIMMEL_USER_SETTINGS")"
assert_rc "SessionStart sibling kept" "1"    "$(jq -r '[.hooks.SessionStart[].hooks[].command|select(test("check-update-available"))]|length' "$HIMMEL_USER_SETTINGS")"
assert_rc "MCP allow preserved"     "mcp__obsidian-vault__obsidian_simple_search" "$(jq -r '.permissions.allow[0]' "$HIMMEL_USER_SETTINGS")"

# 14. --skip-settings keeps the wiring intact.
seed_settings
before=$(cat "$HIMMEL_USER_SETTINGS")
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none2" BRIDGE_ROOT="$TMP/none2b" \
    bash "$CLI" --yes --skip-settings --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "--skip-settings run exits 0" 0 "$rc"
assert_has "--skip-settings honored" "kept (--skip-settings)" "$out"
assert_rc "--skip-settings leaves file unchanged" "$before" "$(cat "$HIMMEL_USER_SETTINGS")"

# 15. --dry-run does not mutate the settings file.
seed_settings
before=$(cat "$HIMMEL_USER_SETTINGS")
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none3" BRIDGE_ROOT="$TMP/none3b" \
    bash "$CLI" --dry-run --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "dry-run [6/6] exits 0" 0 "$rc"
assert_has "dry-run prints [6/6] DRY" "DRY: unwire statusLine" "$out"
assert_rc "dry-run leaves settings unchanged" "$before" "$(cat "$HIMMEL_USER_SETTINGS")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
