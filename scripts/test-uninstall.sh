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
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-suite.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || exit 1
trap 'rm -rf "$TMP"' EXIT

# HIMMEL-2505 (the 2026-09-03 real-HOME wipe): no case in this suite may fall
# through to the operator's REAL $HOME. Capture it for the assertion below,
# then override HOME for the WHOLE suite with an empty fixture that carries
# none of uninstall.sh's wet-run fence markers — a case that forgets its own
# per-invocation HOME override lands here, not on the operator's profile.
REAL_HOME="$HOME"
unset HIMMEL_UNINSTALL_REAL_HOME
SUITE_HOME="$TMP/suitehome"
mkdir -p "$SUITE_HOME"
export HOME="$SUITE_HOME"
case "$REAL_HOME" in
    "$TMP"|"$TMP"/*)
        echo "FAIL the operator's real \$HOME resolved under this suite's \$TMP — refusing to proceed"
        FAILED=$((FAILED + 1))
        ;;
    *) echo "PASS the operator's real \$HOME is not under this suite's \$TMP" ;;
esac
if [ -e "$SUITE_HOME/.claude/.credentials.json" ]; then
    echo "FAIL the suite HOME fixture already carries a live-operator marker"
    FAILED=$((FAILED + 1))
else
    echo "PASS the suite HOME fixture carries no live-operator marker"
fi

# HIMMEL-2505/HIMMEL-874: build a hermetic PATH ONCE, before the first case,
# and thread it through EVERY invocation below (moved up from its old home
# near the SC7 section, which now just adds FAKE_HOME/EMPTY_HOME on top of
# it). A suite that reaches a real claude/pre-commit/bun/crontab/schtasks/
# systemctl is exactly the accident class this ticket exists to close off.
HBIN="$TMP/hbin"
mkdir -p "$HBIN"
# shellcheck disable=SC2317,SC2329  # invoked indirectly by link_hermetic_tool (0.10 reports SC2317, 0.11 SC2329)
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }   # link_hermetic_tool's diagnostic hook
# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$(dirname "$CLI")/lib/hermetic-path.sh"
for _t in bash env sed grep awk tr sort head tail cut wc cat ls rm cp mv ln mkdir chmod \
          basename dirname readlink mktemp uname date id find xargs git jq node; do
    link_hermetic_tool "$_t" "$HBIN"
done
for _excluded in claude pre-commit bun crontab schtasks systemctl; do
    if PATH="$HBIN" command -v "$_excluded" >/dev/null 2>&1; then
        echo "FAIL hermetic \$HBIN unexpectedly resolves $_excluded"
        FAILED=$((FAILED + 1))
    else
        echo "PASS hermetic \$HBIN never resolves $_excluded"
    fi
done

# Redirect the [6/7] settings-unwire target away from the operator's REAL
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
    bash "$CLI" --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "non-interactive without --yes aborts" 2 "$rc"
assert_has "abort message names --yes" "non-interactive run without --yes" "$out"
if [ -f "$CHANNEL/access.json" ] && [ -d "$BRIDGE" ]; then
    echo "PASS nothing removed on abort"
else
    echo "FAIL state was removed despite abort"; FAILED=$((FAILED + 1))
fi

# 2. unknown flag rejected
out=$(PATH="$HBIN" bash "$CLI" --bogus </dev/null 2>&1); rc=$?
assert_rc "unknown flag rejected" 2 "$rc"

# 3. dry-run: prints actions, removes nothing, needs no confirmation
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
    bash "$CLI" --yes --keep-telegram-state --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "--keep-telegram-state run exits 0" 0 "$rc"
if [ -f "$CHANNEL/access.json" ] && [ -d "$BRIDGE" ]; then
    echo "PASS telegram state kept"
else
    echo "FAIL telegram state removed despite --keep-telegram-state"; FAILED=$((FAILED + 1))
fi

# 6. suspicious-path guard: refuses HOME even when asked. HIMMEL-2505: a
#    refused removal now HALTS the run (a partial teardown is safer left in
#    place than guessed past), so this exits 2/INCOMPLETE, not 0 — the
#    corollary of making the halt behavior real.
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$HOME" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "HOME-as-target run halts, exits 2" 2 "$rc"
assert_has "refuses to rm HOME" "refusing to remove suspicious path" "$out"
assert_not_has "guard refusal not reported as rm failure" "failed to remove" "$out"
assert_not_has "guard refusal does not suggest manual removal" "residue remains" "$out"
assert_has "guard refusal halts later steps" "Uninstall INCOMPLETE" "$out"
if [ -d "$HOME" ]; then
    echo "PASS HOME survived"
else
    echo "FAIL HOME gone (!)"; FAILED=$((FAILED + 1))
fi

# Tests 7-12 run the CLI under a controlled PATH (stub dir first, the
# hermetic $HBIN second: "$STUB_WIN/$STUB_NIX/$STUB_BUN:$HBIN" — HIMMEL-2505,
# $HBIN never carries claude/pre-commit/bun/crontab/schtasks/systemctl) so
# command -v resolves to the stubs (and, for the unix-branch tests, so the
# real Windows schtasks is invisible). All discovery tests use --dry-run:
# even if a stub leaked a name, no delete would execute.

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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_WIN:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_WIN:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
    bash "$CLI" --dry-run --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "stubbed at/crontab dry-run exits 0" 0 "$rc"
assert_has "at job extracted" "DRY: atrm 5" "$out"
assert_has "crontab strip previewed" "DRY: crontab — strip lines containing HIMMEL-Resume-" "$out"

# 9b. atq enumeration failure is WARNed
cat > "$STUB_NIX/atq" <<'STUB_EOF'
#!/usr/bin/env bash
exit 1
STUB_EOF
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_NIX:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$STUB_BUN:$HBIN" \
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
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" BUN_STUB_RC=2 PATH="$STUB_BUN:$HBIN" \
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
#     HIMMEL-2505: $HBIN is built (hermetic-path.sh) to NEVER carry bun, so
#     the bun-missing branch is deterministically reachable under it — no
#     "SKIP if a real bun leaked in" guard needed (the old guard checked
#     /usr/bin:/bin directly; that raw system PATH is never used by this
#     suite any more).
mk_state
printf '99999999\n' > "$BRIDGE/supervisor.pid"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "bun-missing run still exits 0" 0 "$rc"
assert_has "bun missing WARNs" "bun is not on PATH" "$out"
assert_has "bun-missing run skips state removal" "SKIPPED: step 1 could not stop the bridge" "$out"
if [ -f "$CHANNEL/access.json" ]; then
    echo "PASS state preserved when bridge cannot be stopped"
else
    echo "FAIL state removed though bridge could not be stopped"; FAILED=$((FAILED + 1))
fi

# ── SC6 (HIMMEL-460): [6/7] settings unwire ─────────────────────────────────
# Seed a settings.json carrying everything setup/adopt wire PLUS non-himmel keys
# that MUST survive (rtk guard, a custom statusLine sibling, an MCP allow).
seed_settings() {
  cat > "$HIMMEL_USER_SETTINGS" <<'JSON'
{
  "statusLine": {"type":"command","command":"bash \"C:/h/scripts/statusline/bin/statusline.sh\""},
  "env": {"HIMMEL_REPO":"C:/h","LUNA_VAULT_PATH":"C:/v","HANDOVER_DIR":"C:/v/handovers","KEEP_ME":"1"},
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

# 13. [6/7] clears the wiring, preserves non-himmel keys.
seed_settings
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none1" BRIDGE_ROOT="$TMP/none1b" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "[6/7] run exits 0" 0 "$rc"
assert_has "[6/7] banner present" "[6/7] Unwiring" "$out"
assert_rc "statusLine removed"      "null"   "$(jq -r '.statusLine // "null"' "$HIMMEL_USER_SETTINGS")"
assert_rc "HIMMEL_REPO removed"     "null"   "$(jq -r '.env.HIMMEL_REPO // "null"' "$HIMMEL_USER_SETTINGS")"
assert_rc "LUNA_VAULT_PATH removed" "null"   "$(jq -r '.env.LUNA_VAULT_PATH // "null"' "$HIMMEL_USER_SETTINGS")"
assert_rc "HANDOVER_DIR removed"    "null"   "$(jq -r '.env.HANDOVER_DIR // "null"' "$HIMMEL_USER_SETTINGS")"
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
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none2" BRIDGE_ROOT="$TMP/none2b" PATH="$HBIN" \
    bash "$CLI" --yes --skip-settings --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "--skip-settings run exits 0" 0 "$rc"
assert_has "--skip-settings honored" "kept (--skip-settings)" "$out"
assert_rc "--skip-settings leaves file unchanged" "$before" "$(cat "$HIMMEL_USER_SETTINGS")"

# 15. --dry-run does not mutate the settings file.
seed_settings
before=$(cat "$HIMMEL_USER_SETTINGS")
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none3" BRIDGE_ROOT="$TMP/none3b" PATH="$HBIN" \
    bash "$CLI" --dry-run --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "dry-run [6/7] exits 0" 0 "$rc"
assert_has "dry-run prints [6/7] DRY" "DRY: unwire statusLine" "$out"
assert_rc "dry-run leaves settings unchanged" "$before" "$(cat "$HIMMEL_USER_SETTINGS")"

# ── SC7 (HIMMEL-2458): steps 4+5 must never SILENTLY skip ───────────────────
# A stock Ubuntu account has two PATH layers — ~/.profile owns ~/.local/bin
# (login shells only) and ~/.bashrc owns ~/.bun/bin while early-returning for
# non-interactive shells — so an uninstall driven from a context that never
# sourced the login profile (ssh host 'cmd', cron, CI, an agent) sees neither
# claude nor pre-commit. Before this ticket that printed one "skipping" line
# per step and STILL ended with "Uninstall complete." at rc=0.
#
# Every case runs --dry-run against a fake HOME, so the planted stubs are only
# ever RESOLVED — nothing real is uninstalled, and the operator's own
# ~/.claude/himmel is never the [7/7] target.
FAKE_HOME="$TMP/fakehome"
mkdir -p "$FAKE_HOME/.local/bin"
for _t in claude pre-commit; do
    printf '#!/usr/bin/env bash\necho "STUB %s $*"\nexit 0\n' "$_t" > "$FAKE_HOME/.local/bin/$_t"
    chmod +x "$FAKE_HOME/.local/bin/$_t"
done
EMPTY_HOME="$TMP/emptyhome"
mkdir -p "$EMPTY_HOME"

# Tests 16-18 need claude + pre-commit OFF the PATH, so that the resolver's
# fallback search is what finds them (16) or fails to (17/18). `/usr/bin:/bin`
# is not that on a distro that packages pre-commit itself (Arch/CachyOS ship
# /usr/bin/pre-commit): the system binary shadowed the fake-HOME stub and 16/17
# went red on an otherwise green box. $HBIN (built at the top of this file,
# HIMMEL-2505) links only the tools uninstall.sh runs and never claude/
# pre-commit, so these three cases run against it alone.
#
# 16. POSITIVE control: both tools are OFF the PATH but present exactly where
#     setup.sh puts them. Both steps must run against the resolved binaries.
out=$(HOME="$FAKE_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/none7" BRIDGE_ROOT="$TMP/none7b" \
    HIMMELCTL_CACHE_DIR="$TMP/none7c" \
    bash "$CLI" --dry-run --skip-tasks </dev/null 2>&1); rc=$?
assert_rc "off-PATH tools resolved: exits 0" 0 "$rc"
assert_not_has "claude not reported missing" "claude CLI not on PATH" "$out"
assert_not_has "pre-commit not reported missing" "pre-commit not on PATH" "$out"
assert_has "resolved claude named" "$FAKE_HOME/.local/bin/claude" "$out"
assert_has "step 5 runs the resolved pre-commit" \
    "DRY: $FAKE_HOME/.local/bin/pre-commit uninstall" "$out"
assert_has "completion reported when nothing was skipped" "Uninstall complete." "$out"

# 17. NEGATIVE control: neither tool exists anywhere. The run must refuse to
#     claim completion, name both steps and where it looked, and exit 2.
out=$(HOME="$EMPTY_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/none8" BRIDGE_ROOT="$TMP/none8b" \
    HIMMELCTL_CACHE_DIR="$TMP/none8c" \
    bash "$CLI" --dry-run --skip-tasks </dev/null 2>&1); rc=$?
assert_rc "unresolvable tools exit 2" 2 "$rc"
assert_not_has "no false completion claim" "Uninstall complete." "$out"
assert_has "incomplete verdict named" "Uninstall INCOMPLETE" "$out"
assert_has "skipped plugin step named" "[4/7] Claude plugins + marketplaces" "$out"
assert_has "skipped hook step named" "[5/7] git hooks" "$out"
assert_has "search locations printed" "looked in:" "$out"
assert_has "a known install location is named" ".local/bin/pre-commit" "$out"

# 18. An EXPLICIT opt-out is not a silent skip: the same unresolvable
#     environment exits 0 when the operator passed both skip flags.
out=$(HOME="$EMPTY_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/none9" BRIDGE_ROOT="$TMP/none9b" \
    HIMMELCTL_CACHE_DIR="$TMP/none9c" \
    bash "$CLI" --dry-run --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "explicit --skip-plugins/--skip-hooks exits 0" 0 "$rc"
assert_has "explicit skip still completes" "Uninstall complete." "$out"

# 18b (HIMMEL-2458): step 4 runs, but every `claude plugin uninstall` /
#     `marketplace remove` call fails — uninstall-plugins.sh exits 1. A WARN
#     alone left plugins installed while the run still claimed completion at
#     rc=0. Own fake HOME (failhome) so case 16's stub `claude` (which always
#     exits 0) is untouched; only step 4 is live (--skip-hooks/--skip-tasks/
#     --skip-settings keep the rest inert, and the fresh none* dirs make
#     steps 1/2/7 no-ops).
FAILHOME="$TMP/failhome"
mkdir -p "$FAILHOME/.local/bin"
printf '#!/usr/bin/env bash\necho "STUB claude (failing) $*"\nexit 1\n' > "$FAILHOME/.local/bin/claude"
chmod +x "$FAILHOME/.local/bin/claude"
out=$(HOME="$FAILHOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/none10" BRIDGE_ROOT="$TMP/none10b" \
    HIMMELCTL_CACHE_DIR="$TMP/none10c" \
    bash "$CLI" --yes --skip-tasks --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "failing claude stub exits 2" 2 "$rc"
assert_not_has "no false completion claim (failing plugins)" "Uninstall complete." "$out"
assert_has "incomplete verdict named (failing plugins)" "Uninstall INCOMPLETE" "$out"
assert_has "step 4 named incomplete" "[4/7] Claude plugins + marketplaces" "$out"
assert_has "uninstall-plugins.sh WARN still present" "uninstall-plugins.sh reported failures" "$out"

# 18c (HIMMEL-2458): step 5 runs, but `pre-commit uninstall` fails for every
#     hook type — same shape, own fake HOME (failhome2) so the other stubs
#     are untouched. --skip-plugins keeps step 4 inert this time.
FAILHOME2="$TMP/failhome2"
mkdir -p "$FAILHOME2/.local/bin"
printf '#!/usr/bin/env bash\necho "STUB pre-commit (failing) $*"\nexit 1\n' > "$FAILHOME2/.local/bin/pre-commit"
chmod +x "$FAILHOME2/.local/bin/pre-commit"
out=$(HOME="$FAILHOME2" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/none11" BRIDGE_ROOT="$TMP/none11b" \
    HIMMELCTL_CACHE_DIR="$TMP/none11c" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-settings </dev/null 2>&1); rc=$?
assert_rc "failing pre-commit stub exits 2" 2 "$rc"
assert_not_has "no false completion claim (failing hooks)" "Uninstall complete." "$out"
assert_has "incomplete verdict named (failing hooks)" "Uninstall INCOMPLETE" "$out"
assert_has "step 5 named incomplete" "[5/7] git hooks" "$out"
assert_has "pre-commit uninstall WARN still present" "pre-commit uninstall pre-commit (default) failed" "$out"

# ── SC8 (HIMMEL-2459): the himmelctl cache + state dir is removed ───────────
# ~/.claude/himmel (install-profile.json + state.json) survived a COMPLETE
# uninstall, so a re-install started against the previous install's profile
# and state ledger. HIMMELCTL_CACHE_DIR is the same override himmelctl reads.
mk_cache() {
    CACHE="$TMP/himmel-cache"
    rm -rf "$CACHE"
    mkdir -p "$CACHE"
    printf '{"profile":"starter"}\n' > "$CACHE/install-profile.json"
    printf '{"items":{}}\n' > "$CACHE/state.json"
}

# 19. --dry-run names what it would remove and leaves the cache in place.
mk_cache
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none10" BRIDGE_ROOT="$TMP/none10b" \
    HIMMELCTL_CACHE_DIR="$CACHE" PATH="$HBIN" \
    bash "$CLI" --dry-run --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "cache dry-run exits 0" 0 "$rc"
assert_has "dry-run previews the cache removal" "DRY: rm -rf -- $CACHE" "$out"
assert_has "dry-run names the install profile" "install-profile.json" "$out"
if [ -f "$CACHE/install-profile.json" ] && [ -f "$CACHE/state.json" ]; then
    echo "PASS dry-run left the himmelctl cache in place"
else
    echo "FAIL dry-run removed the himmelctl cache"; FAILED=$((FAILED + 1))
fi

# 20. a wet run removes it, honouring HIMMELCTL_CACHE_DIR.
mk_cache
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none11" BRIDGE_ROOT="$TMP/none11b" \
    HIMMELCTL_CACHE_DIR="$CACHE" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "cache removal run exits 0" 0 "$rc"
assert_has "cache removal reported" "removed: $CACHE" "$out"
if [ -e "$CACHE" ]; then
    echo "FAIL himmelctl cache survived uninstall"; FAILED=$((FAILED + 1))
else
    echo "PASS himmelctl cache removed"
fi

# 21. an absent cache is not an error.
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none12" BRIDGE_ROOT="$TMP/none12b" \
    HIMMELCTL_CACHE_DIR="$TMP/no-such-cache" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "absent cache exits 0" 0 "$rc"
assert_has "absent cache reported, not removed" "absent, skipping: $TMP/no-such-cache" "$out"

# 22. the suspicious-path guard covers the cache target too — pointing
#     HIMMELCTL_CACHE_DIR at $HOME must refuse, not wipe the home directory.
out=$(HOME="$FAKE_HOME" TELEGRAM_CHANNEL_DIR="$TMP/none13" BRIDGE_ROOT="$TMP/none13b" \
    HIMMELCTL_CACHE_DIR="$FAKE_HOME" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_has "suspicious cache path refused" "refusing to remove suspicious path" "$out"
if [ -x "$FAKE_HOME/.local/bin/claude" ]; then
    echo "PASS suspicious cache path left \$HOME intact"
else
    echo "FAIL suspicious cache path removed \$HOME contents"; FAILED=$((FAILED + 1))
fi

# 22b. the guard must survive an ALIAS of $HOME, not just the literal string.
#      `$HOME/.` resolves to $HOME but is not equal to it as text, so a plain
#      string compare would let it through and take the home directory with it.
out=$(HOME="$FAKE_HOME" TELEGRAM_CHANNEL_DIR="$TMP/none14" BRIDGE_ROOT="$TMP/none14b" \
    HIMMELCTL_CACHE_DIR="$FAKE_HOME/." PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_has "\$HOME/. alias refused as suspicious" "refusing to remove suspicious path" "$out"
if [ -x "$FAKE_HOME/.local/bin/claude" ]; then
    echo "PASS \$HOME/. alias left \$HOME intact"
else
    echo "FAIL \$HOME/. alias removed \$HOME contents"; FAILED=$((FAILED + 1))
fi
# A refusal is not a teardown — the cache is still there, so the run must NOT
# claim completion. This is the same rule step [4/7]/[5/7] follow.
assert_rc "refused cache path exits 2, not 0" 2 "$rc"
assert_not_has "refused cache path claims no completion" "Uninstall complete." "$out"

# 22d. Windows drive-root spellings must ALL be refused. MSYS/Git Bash
#      canonicalizes a drive root to a bare one-letter top-level path
#      (`cd -- "C:/" && pwd -P` -> `/c`), which is neither `/` nor $HOME, so
#      a caller pointing HIMMELCTL_CACHE_DIR at a drive root would otherwise
#      sail past every check above and `rm -rf` the whole drive. These three
#      spellings are refused on the RAW argument, before any `cd`.
#
#      --dry-run on EVERY row here on purpose, unlike the $FAKE_HOME cases
#      above: those targets are synthetic paths under $TMP, but these are
#      REAL system drive roots (`C:/`, `/c`, …) that genuinely exist on this
#      box. The refuse-check runs identically under --dry-run (it is not
#      gated on DRY_RUN), so every assertion below still holds — but if the
#      guard regresses and stops refusing, --dry-run is what keeps the
#      fallthrough `rm -rf` from ever actually running instead of just
#      printing "DRY: rm -rf -- C:/". A wet run here would be exactly the
#      "point it at an actual root" mistake this guard exists to prevent.
_drive_n=0
for _drive_spelling in 'C:/' "C:\\" 'D:/'; do
    _drive_n=$((_drive_n + 1))
    out=$(TELEGRAM_CHANNEL_DIR="$TMP/nonedr${_drive_n}" BRIDGE_ROOT="$TMP/nonedr${_drive_n}b" \
        HIMMELCTL_CACHE_DIR="$_drive_spelling" PATH="$HBIN" \
        bash "$CLI" --dry-run --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
    assert_has "drive root '$_drive_spelling' refused as suspicious" "refusing to remove suspicious path" "$out"
    assert_rc "drive root '$_drive_spelling' exits 2, not 0" 2 "$rc"
    assert_not_has "drive root '$_drive_spelling' claims no completion" "Uninstall complete." "$out"
done

# 22e. `/c` and `/c/` are already in the form MSYS canonicalizes a drive root
#      TO, so these exercise the post-`pwd -P` arm directly rather than the
#      raw-spelling short-circuit above. Only meaningful where `/c` is a real
#      mount (Git Bash / MSYS) — skipped elsewhere so the suite stays
#      portable to a Linux/macOS runner without one. --dry-run for the same
#      reason as 22d: `/c` is this box's real C: drive, not a synthetic path.
if [ -d "/c" ]; then
    _drive_n=0
    for _drive_spelling in '/c' '/c/'; do
        _drive_n=$((_drive_n + 1))
        out=$(TELEGRAM_CHANNEL_DIR="$TMP/nonedrr${_drive_n}" BRIDGE_ROOT="$TMP/nonedrr${_drive_n}b" \
            HIMMELCTL_CACHE_DIR="$_drive_spelling" PATH="$HBIN" \
            bash "$CLI" --dry-run --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
        assert_has "resolved drive root '$_drive_spelling' refused as suspicious" "refusing to remove suspicious path" "$out"
        assert_rc "resolved drive root '$_drive_spelling' exits 2, not 0" 2 "$rc"
        assert_not_has "resolved drive root '$_drive_spelling' claims no completion" "Uninstall complete." "$out"
    done
else
    echo "SKIP resolved drive-root cases (/c, /c/) — no /c mount on this platform"
fi

# 22f. positive control: a normal deep path must still PASS the guard —
#      without this, a guard that refused everything would pass every
#      drive-root row above and look correct. $TMP already lives several
#      levels under a drive root (e.g. /c/Users/…/Temp/…), so this doubles as
#      coverage that the letter-class arm does not over-match a real subpath.
_deep_cache="$TMP/drive-control-cache"
mkdir -p "$_deep_cache"
out=$(TELEGRAM_CHANNEL_DIR="$TMP/nonedc" BRIDGE_ROOT="$TMP/nonedcb" \
    HIMMELCTL_CACHE_DIR="$_deep_cache" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_not_has "deep cache path is NOT refused as suspicious" "refusing to remove suspicious path" "$out"
assert_rc "deep cache path completes normally" 0 "$rc"

# 22c. a regular FILE at the cache path is residue too — reporting it "absent"
#      would leave it behind while claiming a complete uninstall.
CACHE_FILE="$TMP/himmel-cache-file"
printf '{"profile":"starter"}\n' > "$CACHE_FILE"
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none15" BRIDGE_ROOT="$TMP/none15b" \
    HIMMELCTL_CACHE_DIR="$CACHE_FILE" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "cache path that is a FILE exits 0" 0 "$rc"
assert_not_has "a file at the cache path is not reported absent" "absent, skipping: $CACHE_FILE" "$out"
if [ -e "$CACHE_FILE" ]; then
    echo "FAIL a file at the cache path survived uninstall"; FAILED=$((FAILED + 1))
else
    echo "PASS a file at the cache path is removed"
fi

# 22g. a DANGLING symlink at the cache path is residue too — `-e` follows the
#      link and is false for a target that doesn't exist, so a bare `-e`
#      check would report it "absent" and leave the dead link behind while
#      claiming a complete uninstall.
CACHE_DANGLING="$TMP/himmel-cache-dangling"
ln -sf "$TMP/himmel-cache-nonexistent-target" "$CACHE_DANGLING"
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none16" BRIDGE_ROOT="$TMP/none16b" \
    HIMMELCTL_CACHE_DIR="$CACHE_DANGLING" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "dangling symlink cache path exits 0" 0 "$rc"
assert_not_has "a dangling symlink is not reported absent" "absent, skipping: $CACHE_DANGLING" "$out"
# HIMMEL-2505 gap A.3: a symlink target (dangling or not) is now unlinked via
# the dedicated -L branch, reported as "removed symlink (link only)" rather
# than the generic rm -rf "removed:" — never followed/recursed into.
assert_has "dangling symlink cache removal reported" "removed symlink (link only): $CACHE_DANGLING" "$out"
if [ -L "$CACHE_DANGLING" ]; then
    echo "FAIL dangling symlink at the cache path survived uninstall"; FAILED=$((FAILED + 1))
else
    echo "PASS dangling symlink at the cache path is removed"
fi

# ── SC9 (HIMMEL-2505): the wet-run fence refuses a live-looking $HOME ───────
# mk_fence seeds a fixture HOME carrying the credentials marker, PLUS
# populated telegram/bridge/cache state as SIBLINGS under $TMP (not nested
# under $FENCE_HOME): since HIMMEL-2505 gap 2, an override target inside a
# protected location like $HOME is refused unless it names one of the three
# documented removal targets, so a channel/bridge/cache override actually
# meant to exercise the wet-run fence (not protected_path) has to live
# outside $HOME entirely, same as every other override in this suite.
FENCE_HOME="$TMP/fencehome"
FENCE_CHANNEL="$TMP/fence-channel"
FENCE_BRIDGE="$TMP/fence-bridge"
FENCE_CACHE="$TMP/fence-cache"
mk_fence() {
    rm -rf "$FENCE_HOME" "$FENCE_CHANNEL" "$FENCE_BRIDGE" "$FENCE_CACHE"
    mkdir -p "$FENCE_HOME/.claude" "$FENCE_CHANNEL" "$FENCE_BRIDGE" "$FENCE_CACHE"
    printf '{"token":"x"}\n' > "$FENCE_HOME/.claude/.credentials.json"
    printf 'x\n' > "$FENCE_CHANNEL/access.json"
    printf 'x\n' > "$FENCE_BRIDGE/marker"
    printf '{"profile":"starter"}\n' > "$FENCE_CACHE/install-profile.json"
}

# 23a. a wet run against that HOME is refused (rc=3), names the marker and
#      the escape-hatch env var, and leaves every fixture file in place.
mk_fence
out=$(HOME="$FENCE_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$FENCE_CHANNEL" BRIDGE_ROOT="$FENCE_BRIDGE" \
    HIMMELCTL_CACHE_DIR="$FENCE_CACHE" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "fence refuses a wet run against a live-looking HOME" 3 "$rc"
assert_has "fence names the credentials marker" ".claude/.credentials.json" "$out"
assert_has "fence names the escape-hatch env var" "HIMMEL_UNINSTALL_REAL_HOME" "$out"
assert_not_has "fence run does not claim completion" "Uninstall complete." "$out"
if [ -f "$FENCE_CHANNEL/access.json" ] && [ -f "$FENCE_BRIDGE/marker" ] \
    && [ -f "$FENCE_CACHE/install-profile.json" ]; then
    echo "PASS fence run left every fixture file in place"
else
    echo "FAIL fence run removed fixture state despite refusing"; FAILED=$((FAILED + 1))
fi

# 23b. HIMMEL_UNINSTALL_REAL_HOME=1 lifts the fence and the run proceeds.
out=$(HOME="$FENCE_HOME" PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
    TELEGRAM_CHANNEL_DIR="$FENCE_CHANNEL" BRIDGE_ROOT="$FENCE_BRIDGE" \
    HIMMELCTL_CACHE_DIR="$FENCE_CACHE" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "HIMMEL_UNINSTALL_REAL_HOME=1 proceeds" 0 "$rc"
if [ -e "$FENCE_CACHE" ]; then
    echo "FAIL cache survived despite HIMMEL_UNINSTALL_REAL_HOME=1"; FAILED=$((FAILED + 1))
else
    echo "PASS cache removed once HIMMEL_UNINSTALL_REAL_HOME=1 is set"
fi

# 23c. the same fixture with --dry-run and no env var also proceeds (fenced
#      only against a WET run) and removes nothing.
mk_fence
out=$(HOME="$FENCE_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$FENCE_CHANNEL" BRIDGE_ROOT="$FENCE_BRIDGE" \
    HIMMELCTL_CACHE_DIR="$FENCE_CACHE" \
    bash "$CLI" --dry-run --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "--dry-run is never fenced" 0 "$rc"
if [ -f "$FENCE_CHANNEL/access.json" ] && [ -f "$FENCE_BRIDGE/marker" ] \
    && [ -f "$FENCE_CACHE/install-profile.json" ]; then
    echo "PASS --dry-run against a live-looking HOME removed nothing"
else
    echo "FAIL --dry-run removed fixture state"; FAILED=$((FAILED + 1))
fi

# 23d. an ssh private key alone (no credentials.json) also fences a wet run.
FENCE_SSH_HOME="$TMP/fencehome-ssh"
mkdir -p "$FENCE_SSH_HOME/.ssh"
printf 'PRIVATE KEY\n' > "$FENCE_SSH_HOME/.ssh/id_ed25519"
out=$(HOME="$FENCE_SSH_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/fence-ssh-channel" BRIDGE_ROOT="$TMP/fence-ssh-bridge" \
    HIMMELCTL_CACHE_DIR="$TMP/fence-ssh-cache" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "an ssh private key alone fences a wet run" 3 "$rc"
assert_has "fence names the ssh key marker" "id_ed25519" "$out"

# 23e. a Codex-only profile (~/.codex present, no other marker) also fences a
#      wet run — the header (HIMMEL-2505) names ~/.codex among what the
#      2026-09-03 incident swept, so the fence must catch it too.
FENCE_CODEX_HOME="$TMP/fencehome-codex"
mkdir -p "$FENCE_CODEX_HOME/.codex"
out=$(HOME="$FENCE_CODEX_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/fence-codex-channel" BRIDGE_ROOT="$TMP/fence-codex-bridge" \
    HIMMELCTL_CACHE_DIR="$TMP/fence-codex-cache" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "a Codex-only profile (~/.codex alone) fences a wet run" 3 "$rc"
assert_has "fence names the .codex marker" "refusing a wet uninstall — found $FENCE_CODEX_HOME/.codex" "$out"

# ── SC10 (HIMMEL-2505): protected_path — a fixed hard-refuse allowlist ──────
# Exercised end-to-end through the CLI via HIMMELCTL_CACHE_DIR (the isolated
# predicate itself is proven in test-uninstall-guard.sh).
PHOME="$TMP/protectedhome"
mkdir -p "$PHOME/.claude/himmel" "$PHOME/.ssh"
printf '{"profile":"starter"}\n' > "$PHOME/.claude/himmel/install-profile.json"

_pn=0
for _ptarget in "$PHOME" "$PHOME/.claude" "/" "$PHOME/.ssh"; do
    _pn=$((_pn + 1))
    out=$(HOME="$PHOME" PATH="$HBIN" \
        TELEGRAM_CHANNEL_DIR="$TMP/protected-none${_pn}" BRIDGE_ROOT="$TMP/protected-none${_pn}b" \
        HIMMELCTL_CACHE_DIR="$_ptarget" \
        bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
    assert_rc "protected ancestor '$_ptarget' exits 2" 2 "$rc"
    assert_has "protected ancestor '$_ptarget' refused" "refusing to remove suspicious path" "$out"
    assert_not_has "protected ancestor '$_ptarget' claims no completion" "Uninstall complete." "$out"
    if [ -e "$_ptarget" ]; then
        echo "PASS protected ancestor '$_ptarget' still present"
    else
        echo "FAIL protected ancestor '$_ptarget' was removed (!)"; FAILED=$((FAILED + 1))
    fi
done

# control: the fixed allowed target UNDER the protected $HOME/.claude dir is
# still removed normally — protected_path must not over-refuse a descendant.
out=$(HOME="$PHOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/protected-ctrl-channel" BRIDGE_ROOT="$TMP/protected-ctrl-bridge" \
    HIMMELCTL_CACHE_DIR="$PHOME/.claude/himmel" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "allowed cache target under \$HOME/.claude removed: exits 0" 0 "$rc"
if [ -e "$PHOME/.claude/himmel" ]; then
    echo "FAIL allowed cache target under \$HOME/.claude survived"; FAILED=$((FAILED + 1))
else
    echo "PASS allowed cache target under \$HOME/.claude removed"
fi

# ── SC10b (HIMMEL-2505 gap 2): an override inside a protected location, that
# is NOT one of the three documented removal targets, is refused too — a
# strict DESCENDANT of protected $HOME/.ssh, not an ancestor/equal of it.
FAKE_HOME="$PHOME"
mkdir -p "$FAKE_HOME/.ssh/keys"
printf 'PRIVATE KEY\n' > "$FAKE_HOME/.ssh/keys/id_ed25519"
out=$(HOME="$FAKE_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/protected-desc-channel" BRIDGE_ROOT="$TMP/protected-desc-bridge" \
    HIMMELCTL_CACHE_DIR="$FAKE_HOME/.ssh/keys" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "descendant of protected \$HOME/.ssh refused: exits 2" 2 "$rc"
assert_has "descendant of protected path refused" "refusing to remove suspicious path" "$out"
assert_not_has "descendant refusal claims no completion" "Uninstall complete." "$out"
if [ -e "$FAKE_HOME/.ssh/keys" ]; then
    echo "PASS descendant of protected \$HOME/.ssh survives"
else
    echo "FAIL descendant of protected \$HOME/.ssh was removed (!)"; FAILED=$((FAILED + 1))
fi

# ── SC11 (HIMMEL-2505): a failed removal HALTS every later step ────────────
# Step [2/7]'s channel-dir removal is made to FAIL (not merely refused): the
# channel dir's PARENT is chmod'd 0555 so rm can empty the dir but cannot
# unlink the directory entry itself. chmod back to 0755 right after the run
# so the suite's own $TMP cleanup can remove it. BRIDGE_ROOT — the SECOND dir
# in step [2/7]'s loop — is a populated, perfectly removable dir: the only
# reason it must survive is that step [2/7] halts after the FIRST dir fails
# and skips the rest of the loop (HIMMEL-2505 gap 1), not because removing it
# would itself fail. --skip-tasks is deliberately NOT passed (and the
# hermetic $HBIN never resolves schtasks/crontab/atq) so step [3/7] is
# exercised too: it must halt-skip rather than run past the failure.
#
# HIMMEL-2505 gap B (suggestion): this whole row depends on chmod 0555
# denying `rm` permission to unlink the directory entry — root ignores unix
# permission bits, so as root the removal would SUCCEED instead of failing
# and every assertion below would go red for a reason unrelated to the
# product code. SKIP it under root, following the suite's own SKIP
# convention (grep ^SKIP above).
if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP SC11 halt row: running as root, chmod cannot make rm fail"
else
    HALT_HOME="$TMP/halthome"
    mkdir -p "$HALT_HOME"
    HALT_PARENT="$HALT_HOME/channel-parent"
    mkdir -p "$HALT_PARENT/telegram"
    printf 'x\n' > "$HALT_PARENT/telegram/access.json"
    HALT_BRIDGE="$TMP/halt-bridge"
    mkdir -p "$HALT_BRIDGE"
    printf 'x\n' > "$HALT_BRIDGE/supervisor-state.json"
    HALT_CACHE="$TMP/halt-cache"
    mkdir -p "$HALT_CACHE"
    printf '{"profile":"starter"}\n' > "$HALT_CACHE/install-profile.json"
    chmod 0555 "$HALT_PARENT"
    out=$(HOME="$HALT_HOME" PATH="$HBIN" \
        TELEGRAM_CHANNEL_DIR="$HALT_PARENT/telegram" BRIDGE_ROOT="$HALT_BRIDGE" \
        HIMMELCTL_CACHE_DIR="$HALT_CACHE" \
        bash "$CLI" --yes --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
    chmod 0755 "$HALT_PARENT"
    assert_rc "a failed step-2 removal halts the run: exits 2" 2 "$rc"
    assert_has "step 7 reports the halted-skip" "skipped (halted after a failed removal)" "$out"
    assert_has "verdict names step 2's failure" "[2/7]" "$out"
    assert_has "verdict names step 7's skip" "[7/7]" "$out"
    assert_has "verdict says INCOMPLETE" "Uninstall INCOMPLETE" "$out"
    if [ -e "$HALT_CACHE" ]; then
        echo "PASS cache dir survives after a halt"
    else
        echo "FAIL cache dir was removed despite the halt"; FAILED=$((FAILED + 1))
    fi
    # Gap 1a: the SECOND dir in step [2/7]'s loop must not be removed once
    # the FIRST dir's removal has halted the run.
    if [ -e "$HALT_BRIDGE" ]; then
        echo "PASS bridge root survives — step 2 halts before the second dir"
    else
        echo "FAIL bridge root was removed despite the halt"; FAILED=$((FAILED + 1))
    fi
    assert_has "step 2 skips the remaining dir once halted" "[2/7] telegram pairing + bridge state: $HALT_BRIDGE skipped — halted" "$out"
    # Gap 1b: step [3/7] (scheduled jobs) must not run past the halt either.
    assert_has "step 3 skips once halted" "[3/7] scheduled jobs: skipped — halted after a failed removal" "$out"
fi

# ── SC12 (HIMMEL-2505 revised): allowed targets matched by LITERAL path, not
# their leaf-resolved (symlink-followed) identity — a LEAF-symlinked
# documented target ($HOME/.claude/himmel itself a symlink) now REFUSES
# outright (same hardening as the ancestor-symlink cases in SC13/SC14),
# superseding the old "unlink the link only" behavior: a symlinked leaf on
# a documented target is exactly as suspicious as a symlinked ancestor, and
# protected_path's target_has_symlinked_component_below_home walk already
# says "the leaf included" — the pre-revision code just didn't act on that
# for this exact shape. Neither the symlink nor its target may be touched.
SC12_HOME="$TMP/sc12home"
mkdir -p "$SC12_HOME/.claude"
SC12_REAL="$TMP/sc12-linktarget"
mkdir -p "$SC12_REAL"
printf '{"profile":"starter"}\n' > "$SC12_REAL/install-profile.json"
ln -s "$SC12_REAL" "$SC12_HOME/.claude/himmel"
out=$(HOME="$SC12_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/sc12-channel" BRIDGE_ROOT="$TMP/sc12-bridge" \
    HIMMELCTL_CACHE_DIR="$SC12_HOME/.claude/himmel" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "leaf-symlinked allowed target refused: exits 2" 2 "$rc"
assert_has "leaf-symlinked allowed target refused" "refusing to remove suspicious path" "$out"
assert_not_has "leaf-symlinked refusal claims no completion" "Uninstall complete." "$out"
if [ -L "$SC12_HOME/.claude/himmel" ]; then
    echo "PASS symlink itself survives the refusal"
else
    echo "FAIL symlink was removed despite the refusal"; FAILED=$((FAILED + 1))
fi
if [ -d "$SC12_REAL" ] && [ -f "$SC12_REAL/install-profile.json" ]; then
    echo "PASS link target and its contents survive"
else
    echo "FAIL link target or its contents were removed"; FAILED=$((FAILED + 1))
fi

# SC12b: same fixture, but the override carries a trailing slash — same
# refusal (a trailing slash must not make the guard follow, or misjudge,
# the link).
SC12B_HOME="$TMP/sc12bhome"
mkdir -p "$SC12B_HOME/.claude"
SC12B_REAL="$TMP/sc12b-linktarget"
mkdir -p "$SC12B_REAL"
printf '{"profile":"starter"}\n' > "$SC12B_REAL/install-profile.json"
ln -s "$SC12B_REAL" "$SC12B_HOME/.claude/himmel"
out=$(HOME="$SC12B_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$TMP/sc12b-channel" BRIDGE_ROOT="$TMP/sc12b-bridge" \
    HIMMELCTL_CACHE_DIR="$SC12B_HOME/.claude/himmel/" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "leaf-symlinked allowed target with trailing slash refused: exits 2" 2 "$rc"
assert_has "trailing-slash leaf-symlinked target refused" "refusing to remove suspicious path" "$out"
assert_not_has "trailing-slash refusal claims no completion" "Uninstall complete." "$out"
if [ -L "$SC12B_HOME/.claude/himmel" ]; then
    echo "PASS symlink itself survives the refusal (trailing slash case)"
else
    echo "FAIL symlink was removed despite the refusal (trailing slash case)"; FAILED=$((FAILED + 1))
fi
if [ -d "$SC12B_REAL" ] && [ -f "$SC12B_REAL/install-profile.json" ]; then
    echo "PASS link target and its contents survive (trailing slash case)"
else
    echo "FAIL link target or its contents were removed (trailing slash case)"; FAILED=$((FAILED + 1))
fi

# ── SC13 (HIMMEL-2505 revised): the allowed-target exemption's SYMLINKED-
# COMPONENT half, exercised end-to-end. $FAKE_HOME/.claude/channels is a
# symlink to $FAKE_HOME/Documents (populated with telegram/x, real user
# data); TELEGRAM_CHANNEL_DIR names the documented default path itself
# ($FAKE_HOME/.claude/channels/telegram), which lexically matches the
# allowed suffix but walks through that symlinked ancestor. This must
# refuse — a lexical match alone (the pre-fix behavior) is not enough.
SC13_HOME="$TMP/sc13-fakehome"
mkdir -p "$SC13_HOME/.claude" "$SC13_HOME/Documents/telegram"
printf 'x\n' > "$SC13_HOME/Documents/telegram/x"
ln -s "$SC13_HOME/Documents" "$SC13_HOME/.claude/channels"
out=$(HOME="$SC13_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$SC13_HOME/.claude/channels/telegram" BRIDGE_ROOT="$TMP/sc13-bridge" \
    HIMMELCTL_CACHE_DIR="$TMP/sc13-cache" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "symlinked-parent telegram override refused: exits 2" 2 "$rc"
assert_has "symlinked-parent override refused" "refusing to remove suspicious path" "$out"
assert_not_has "symlinked-parent refusal claims no completion" "Uninstall complete." "$out"
if [ -f "$SC13_HOME/Documents/telegram/x" ]; then
    echo "PASS real Documents/telegram/x survives the symlinked-parent override"
else
    echo "FAIL Documents/telegram/x was removed through the symlinked parent (!)"; FAILED=$((FAILED + 1))
fi

# ── SC14 (HIMMEL-2505 revised): same symlinked-ANCESTOR shape as SC13, but
# the link target is OUTSIDE $HOME entirely ($TMP/sc14-elsewhere, not a
# protected destination) — unlike SC13's link into $HOME/Documents, this one
# would pass the resolved-path protected-set checks if the outright refusal
# didn't catch it first. Must refuse identically.
SC14_HOME="$TMP/sc14-fakehome"
mkdir -p "$SC14_HOME/.claude" "$TMP/sc14-elsewhere/telegram"
printf 'x\n' > "$TMP/sc14-elsewhere/telegram/x"
ln -s "$TMP/sc14-elsewhere" "$SC14_HOME/.claude/channels"
out=$(HOME="$SC14_HOME" PATH="$HBIN" \
    TELEGRAM_CHANNEL_DIR="$SC14_HOME/.claude/channels/telegram" BRIDGE_ROOT="$TMP/sc14-bridge" \
    HIMMELCTL_CACHE_DIR="$TMP/sc14-cache" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc "symlinked-parent-outside-HOME telegram override refused: exits 2" 2 "$rc"
assert_has "symlinked-parent-outside-HOME override refused" "refusing to remove suspicious path" "$out"
assert_not_has "symlinked-parent-outside-HOME refusal claims no completion" "Uninstall complete." "$out"
if [ -f "$TMP/sc14-elsewhere/telegram/x" ]; then
    echo "PASS real sc14-elsewhere/telegram/x survives the symlinked-parent override"
else
    echo "FAIL sc14-elsewhere/telegram/x was removed through the symlinked parent (!)"; FAILED=$((FAILED + 1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
