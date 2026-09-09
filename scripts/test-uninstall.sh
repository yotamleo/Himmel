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
          basename dirname readlink mktemp uname date id find xargs jq node; do
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

# Redirect the [6/8] settings-unwire target away from the operator's REAL
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

# 3b. RED 9 (HIMMEL-2754): plugin confirmation names user-scope reach.
mk_state
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" PATH="$HBIN" \
    bash "$CLI" --dry-run --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
assert_has "RED 9: banner warns about user-scope reach" \
    "USER-SCOPE: affects every repo on this machine" "$out"

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
assert_rc "query-failure dry-run halts with rc=2" 2 "$rc"
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
assert_rc "atq-failure dry-run halts with rc=2" 2 "$rc"
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
assert_rc "crontab-failure dry-run halts with rc=2" 2 "$rc"
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
assert_rc "rc1-real-stderr dry-run halts with rc=2" 2 "$rc"
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
assert_rc "kill-failure run halts with rc=2" 2 "$rc"
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
assert_rc "bun-missing run halts with rc=2" 2 "$rc"
assert_has "bun missing WARNs" "bun is not on PATH" "$out"
assert_has "bun-missing run skips state removal" "SKIPPED: step 1 could not stop the bridge" "$out"
if [ -f "$CHANNEL/access.json" ]; then
    echo "PASS state preserved when bridge cannot be stopped"
else
    echo "FAIL state removed though bridge could not be stopped"; FAILED=$((FAILED + 1))
fi

# ── SC6 (HIMMEL-460): [6/8] settings unwire ─────────────────────────────────
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

# 13. [6/8] clears the wiring, preserves non-himmel keys.
seed_settings
out=$(TELEGRAM_CHANNEL_DIR="$TMP/none1" BRIDGE_ROOT="$TMP/none1b" PATH="$HBIN" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "[6/8] run exits 0" 0 "$rc"
assert_has "[6/8] banner present" "[6/8] Unwiring" "$out"
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
assert_rc "dry-run [6/8] exits 0" 0 "$rc"
assert_has "dry-run prints [6/8] DRY" "DRY: unwire statusLine" "$out"
assert_rc "dry-run leaves settings unchanged" "$before" "$(cat "$HIMMEL_USER_SETTINGS")"

# SC6P (HIMMEL-2776): project scope resolves from the install invocation's CWD,
# not the himmel clone containing uninstall.sh. Omitting the project pass must
# fail these residue/output assertions independently of the plugin-scope rows.
PROJECT="$TMP/adopted project"
mkdir -p "$PROJECT/.claude"
seed_settings
cp "$HIMMEL_USER_SETTINGS" "$TMP/user-before.json"
# Hand-derived surviving user keys, formatted as the existing jq writers emit.
jq -n '{env:{KEEP_ME:"1"},hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:"bash /opt/rtk-hook-guard.sh"}]},
    {matcher:"*",hooks:[{type:"command",command:"bash C:/h/scripts/hooks/auto-arm-on-cap.sh"}]}
  ],SessionStart:[{hooks:[{type:"command",command:"bash C:/h/scripts/hooks/check-update-available.sh"}]}]},
  permissions:{allow:["mcp__obsidian-vault__obsidian_simple_search"]}}' > "$TMP/user-expected.json"
jq '.hooks.PreToolUse = [range(0;10) | {matcher:"Bash",hooks:[{type:"command",command:"bash $CLAUDE_PROJECT_DIR/scripts/hooks/block-edit-on-main.sh"}]}]' \
    "$HIMMEL_USER_SETTINGS" > "$PROJECT/.claude/settings.json"
cp "$PROJECT/.claude/settings.json" "$TMP/project-before.json"
project_uninstall() {
    (cd "$PROJECT" && TELEGRAM_CHANNEL_DIR="$TMP/none-project" BRIDGE_ROOT="$TMP/none-project-bridge" PATH="$TMP/project-bin:$HBIN" \
        bash "$CLI" --skip-tasks --skip-plugins --skip-hooks "$@" </dev/null 2>&1)
}
out=$(project_uninstall); rc=$?
assert_rc "SC6P no consent aborts" 2 "$rc"
assert_rc "SC6P no consent preserves project" "$(cat "$TMP/project-before.json")" "$(cat "$PROJECT/.claude/settings.json")"
out=$(project_uninstall --dry-run); rc=$?
assert_rc "SC6P dry-run exits 0" 0 "$rc"
assert_has "SC6P dry-run names project" "DRY: project settings: would unwire $PROJECT/.claude/settings.json" "$out"
assert_rc "SC6P dry-run preserves project" "$(cat "$TMP/project-before.json")" "$(cat "$PROJECT/.claude/settings.json")"
out=$(project_uninstall --yes --skip-settings); rc=$?
assert_rc "SC6P skip exits 0" 0 "$rc"
assert_rc "SC6P skip preserves project" "$(cat "$TMP/project-before.json")" "$(cat "$PROJECT/.claude/settings.json")"
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P project unwire exits 0" 0 "$rc"
assert_has "SC6P project outcome" "project settings: unwired $PROJECT/.claude/settings.json" "$out"
assert_rc "SC6P project residue is zero" 0 "$(jq '[.statusLine, .env.HIMMEL_REPO, .env.LUNA_VAULT_PATH, .env.HANDOVER_DIR, .hooks.PreToolUse[].hooks[]] | map(select(. != null)) | length' "$PROJECT/.claude/settings.json")"
assert_rc "SC6P preserves unrelated env" 1 "$(jq -r '.env.KEEP_ME' "$PROJECT/.claude/settings.json")"
cmp -s "$TMP/user-expected.json" "$HIMMEL_USER_SETTINGS"; rc=$?
assert_rc "SC6P user behavior byte-identical" 0 "$rc"
rm "$PROJECT/.claude/settings.json"
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P absent project exits 0" 0 "$rc"
assert_has "SC6P absent project outcome" "project settings: none found" "$out"
# A failed user pass must halt before touching project settings.
cp "$TMP/project-before.json" "$PROJECT/.claude/settings.json"
printf 'invalid json\n' > "$HIMMEL_USER_SETTINGS"
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P invalid user halts" 2 "$rc"
assert_rc "SC6P halted project unchanged" "$(cat "$TMP/project-before.json")" "$(cat "$PROJECT/.claude/settings.json")"
cp "$TMP/user-before.json" "$HIMMEL_USER_SETTINGS"
printf 'invalid json\n' > "$PROJECT/.claude/settings.json"
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P invalid project halts" 2 "$rc"
assert_not_has "SC6P invalid project never claims unwired" "project settings: unwired" "$out"
assert_not_has "SC6P invalid project never completes" "Uninstall complete." "$out"
# Identity controls use a disposable source checkout, never live repo settings.
# Removing the own-checkout exemption must change these seeded bytes.
REAL_CLI="$CLI"
SOURCE_FIXTURE="$TMP/source-checkout"
mkdir -p "$SOURCE_FIXTURE/scripts" "$SOURCE_FIXTURE/.claude" "$TMP/project-bin"
cp "$CLI" "$SOURCE_FIXTURE/scripts/uninstall.sh"
ln -s "$(dirname "$REAL_CLI")/lib" "$SOURCE_FIXTURE/scripts/lib"
link_hermetic_tool git "$TMP/project-bin"
git init -q "$SOURCE_FIXTURE"
cp "$TMP/project-before.json" "$SOURCE_FIXTURE/.claude/settings.json"
git -C "$SOURCE_FIXTURE" add scripts/uninstall.sh .claude/settings.json
git -C "$SOURCE_FIXTURE" -c user.name=Test -c user.email=test@example.invalid commit -qm 'test: fixture'
CLI="$SOURCE_FIXTURE/scripts/uninstall.sh"
PROJECT="$SOURCE_FIXTURE"
seed_settings
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P own source checkout exits 0" 0 "$rc"
assert_has "SC6P own source checkout kept" "himmel's own checkout" "$out"
cmp -s "$TMP/project-before.json" "$PROJECT/.claude/settings.json"; rc=$?
assert_rc "SC6P own tracked settings unchanged" 0 "$rc"
git -C "$SOURCE_FIXTURE" worktree add -q --detach "$TMP/source-linked" HEAD
PROJECT="$TMP/source-linked"
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P linked source checkout exits 0" 0 "$rc"
assert_has "SC6P linked source checkout kept" "himmel's own checkout" "$out"
cmp -s "$TMP/project-before.json" "$PROJECT/.claude/settings.json"; rc=$?
assert_rc "SC6P linked tracked settings unchanged" 0 "$rc"
CLI="$REAL_CLI"
PROJECT="$TMP/adopted project"
# An adopter may track their settings: tracked does not mean himmel-owned.
git init -q "$PROJECT"
cp "$TMP/project-before.json" "$PROJECT/.claude/settings.json"
git -C "$PROJECT" add .claude/settings.json
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P tracked adopter unwire exits 0" 0 "$rc"
assert_has "SC6P tracked adopter unwired" "project settings: unwired" "$out"
# Refuse settings symlinks instead of following one into unrelated settings.
rm "$PROJECT/.claude/settings.json"
ln -s "$TMP/project-before.json" "$PROJECT/.claude/settings.json"
cp "$TMP/project-before.json" "$TMP/symlink-before.json"
out=$(project_uninstall --yes); rc=$?
assert_rc "SC6P symlink target refused" 2 "$rc"
cmp -s "$TMP/symlink-before.json" "$TMP/project-before.json"; rc=$?
assert_rc "SC6P symlink destination unchanged" 0 "$rc"
# Restore the existing user fixture for the subsequent suites.
seed_settings

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
# ~/.claude/himmel is never the [8/8] target.
FAKE_HOME="$TMP/fakehome"
mkdir -p "$FAKE_HOME/.local/bin"
for _t in claude pre-commit; do
    printf '#!/usr/bin/env bash\necho "STUB %s $*"\nexit 0\n' "$_t" > "$FAKE_HOME/.local/bin/$_t"
    chmod +x "$FAKE_HOME/.local/bin/$_t"
done
printf '#!/usr/bin/env bash\necho "[]"\n' > "$FAKE_HOME/.local/bin/claude"
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
assert_has "skipped plugin step named" "[4/8] Claude plugins" "$out"
assert_has "skipped hook step named" "[5/8] git hooks" "$out"
assert_has "search locations printed" "looked in:" "$out"
assert_has "a known install location is named" ".local/bin/claude" "$out"

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
assert_has "step 4 named incomplete" "[4/8] Claude plugins" "$out"
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
assert_has "step 5 named incomplete" "[5/8] git hooks" "$out"
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
# claim completion. This is the same rule step [4/8]/[5/8] follow.
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
# Step [2/8]'s channel-dir removal is made to FAIL (not merely refused): the
# channel dir's PARENT is chmod'd 0555 so rm can empty the dir but cannot
# unlink the directory entry itself. chmod back to 0755 right after the run
# so the suite's own $TMP cleanup can remove it. BRIDGE_ROOT — the SECOND dir
# in step [2/8]'s loop — is a populated, perfectly removable dir: the only
# reason it must survive is that step [2/8] halts after the FIRST dir fails
# and skips the rest of the loop (HIMMEL-2505 gap 1), not because removing it
# would itself fail. --skip-tasks is deliberately NOT passed (and the
# hermetic $HBIN never resolves schtasks/crontab/atq) so step [3/8] is
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
    assert_has "step 8 reports the halted-skip" "skipped (halted after an earlier failure)" "$out"
    assert_has "verdict names step 2's failure" "[2/8]" "$out"
    assert_has "verdict names step 8's skip" "[8/8]" "$out"
    assert_has "verdict says INCOMPLETE" "Uninstall INCOMPLETE" "$out"
    if [ -e "$HALT_CACHE" ]; then
        echo "PASS cache dir survives after a halt"
    else
        echo "FAIL cache dir was removed despite the halt"; FAILED=$((FAILED + 1))
    fi
    # Gap 1a: the SECOND dir in step [2/8]'s loop must not be removed once
    # the FIRST dir's removal has halted the run.
    if [ -e "$HALT_BRIDGE" ]; then
        echo "PASS bridge root survives — step 2 halts before the second dir"
    else
        echo "FAIL bridge root was removed despite the halt"; FAILED=$((FAILED + 1))
    fi
    assert_has "step 2 skips the remaining dir once halted" "[2/8] telegram pairing + bridge state: $HALT_BRIDGE skipped — halted" "$out"
    # Gap 1b: step [3/8] (scheduled jobs) must not run past the halt either.
    assert_has "step 3 skips once halted" "[3/8] scheduled jobs: skipped — halted after an earlier failure" "$out"
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

# ── SC15 (HIMMEL-2694): step 4 forwards the RECORDED install scope ──────────
# uninstall-plugins.sh grew a --scope flag, and uninstall.sh must hand it the
# scope the INSTALL recorded (install-profile.json's own `scope` field) — a
# project-scope install is refused by `claude plugin uninstall` at any other
# scope, which is the whole defect. The cases below drive the REAL uninstall.sh
# with an argv-RECORDING `claude` stub and assert on what step 4 actually
# invoked, not on the preview text: the preview is prose and could drift from
# the call it describes. Each case gets its own fake HOME so the stubs above
# are untouched, and its own cache dir so profiles cannot leak between cases.
scope_case() {
    # $1 = case slug, $2 = the install-profile.json body (empty = write none)
    SC15_HOME="$TMP/sc15-$1-home"
    SC15_CACHE="$TMP/sc15-$1-cache"
    SC15_LOG="$TMP/sc15-$1-argv.log"
    mkdir -p "$SC15_HOME/.local/bin" "$SC15_CACHE"
    : > "$SC15_LOG"
    # The log path is baked into the stub at generation time: uninstall.sh
    # reaches the stub through uninstall-plugins.sh, so an env var would have
    # to survive two hops; hardcoding keeps the stub hermetic.
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> %s\n' "$SC15_LOG"
        printf 'exit 0\n'
    } > "$SC15_HOME/.local/bin/claude"
    chmod +x "$SC15_HOME/.local/bin/claude"
    if [ -n "$2" ]; then
        printf '%s\n' "$2" > "$SC15_CACHE/install-profile.json"
    fi
    HOME="$SC15_HOME" PATH="$HBIN" \
        TELEGRAM_CHANNEL_DIR="$TMP/sc15-$1-none" BRIDGE_ROOT="$TMP/sc15-$1-noneb" \
        HIMMELCTL_CACHE_DIR="$SC15_CACHE" \
        bash "$CLI" --yes --skip-tasks --skip-hooks --skip-settings </dev/null >/dev/null 2>&1
}

# 15a. a project-scope install: EVERY plugin uninstall carries --scope project,
#      and none silently falls back to the `user` default.
scope_case project '{"profile":"starter","scope":"project"}'
sc15_log="$(cat "$TMP/sc15-project-argv.log")"
assert_has "SC15a project profile -> plugin uninstall invoked" \
    "plugin uninstall" "$sc15_log"
assert_has "SC15a project profile -> --scope project forwarded" \
    "--scope project" "$sc15_log"
assert_not_has "SC15a project profile -> no call falls back to user scope" \
    "--scope user" "$sc15_log"

# 15b. no profile at all (a pre-2694 cache, or an install that never recorded
#      one): fall back to install-plugins.sh's own default, `user`.
scope_case noprofile ''
sc15_log="$(cat "$TMP/sc15-noprofile-argv.log")"
assert_has "SC15b no profile -> falls back to --scope user" \
    "--scope user" "$sc15_log"
assert_not_has "SC15b no profile -> never invents a project scope" \
    "--scope project" "$sc15_log"

# 15c. a profile carrying a scope OUTSIDE the accepted set: fall back to `user`
#      rather than passing the garbage through (uninstall-plugins.sh exits 2 on
#      an invalid --scope, turning a stale cache into a failed teardown).
scope_case garbage '{"profile":"starter","scope":"not-a-scope"}'
sc15_log="$(cat "$TMP/sc15-garbage-argv.log")"
assert_has "SC15c garbage scope -> falls back to --scope user" \
    "--scope user" "$sc15_log"
assert_not_has "SC15c garbage scope -> the bad value never reaches the CLI" \
    "not-a-scope" "$sc15_log"

# ── SC16 (HIMMEL-2754): every failed step halts all later teardown ─────────
# The fixture repo contains only the helpers under test and fake hook files.
# No git binary is on HBIN; hook detection exercises its documented fallback.
U_REPO="$TMP/u-repo"
mkdir -p "$U_REPO/.git/hooks" "$U_REPO/scripts/machine-setup" "$U_REPO/scripts/lib" "$U_REPO/docs/setup"
cp "$(dirname "$CLI")/machine-setup/uninstall-plugins.sh" "$U_REPO/scripts/machine-setup/"
for helper in unwire-statusline unwire-himmel-repo unwire-luna-vault unwire-handover-dir unwire-pretooluse-hooks; do
    cp "$(dirname "$CLI")/lib/$helper.sh" "$U_REPO/scripts/lib/"
done
cp "$(dirname "$CLI")/../docs/setup/settings-template.json" "$U_REPO/docs/setup/"
printf '# pre-commit sample only\n' > "$U_REPO/.git/hooks/pre-commit.sample"
export CLAUDE_CALL_LOG="$TMP/u-claude.log"
export STUB_PLUGINS_JSON="$TMP/u-plugins.json"
export STUB_MARKETPLACES_JSON="$TMP/u-marketplaces.json"
export STUB_FAIL_IDS="" STUB_ADD_NAME="himmel"
U_BIN="$TMP/u-bin"
mkdir -p "$U_BIN"
cat > "$U_BIN/claude" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
json_list() {
    if [ ! -s "$1" ]; then echo '[]'
    elif [ "$(cat "$1")" = "DEGRADED" ]; then exit 1
    else cat "$1"
    fi
}
case "$*" in
    'plugin list --json') json_list "$STUB_PLUGINS_JSON" ;;
    'plugin marketplace list --json') json_list "$STUB_MARKETPLACES_JSON" ;;
    'plugin uninstall '* )
        [ "$#" -eq 5 ] && [ "$4" = '--scope' ] || exit 2
        if grep -qxF -- "$3" <<< "${STUB_FAIL_IDS:-}"; then exit 1; fi
        if [ "$(cat "$STUB_PLUGINS_JSON")" != DEGRADED ]; then
            jq --arg id "$3" --arg scope "$5" '[.[] | select(.id != $id or .scope != $scope)]' \
                "$STUB_PLUGINS_JSON" > "$STUB_PLUGINS_JSON.next"
            mv "$STUB_PLUGINS_JSON.next" "$STUB_PLUGINS_JSON"
        fi
        ;;
    'plugin marketplace remove '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        if grep -qxF -- "$4" <<< "${STUB_FAIL_IDS:-}"; then exit 1; fi
        jq --arg name "$4" '[.[] | select(.name != $name)]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    'plugin marketplace add '* )
        [ "$#" -eq 4 ] || exit 2
        jq --arg name "${STUB_ADD_NAME:-himmel}" '. + [{name: $name}]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    *) exit 2 ;;
esac
STUB_EOF
chmod 755 "$U_BIN/claude"
u_fixture() {
    mk_state
    U_HOME="$TMP/u-$1-home"
    U_CACHE="$TMP/u-$1-cache"
    mkdir -p "$U_HOME" "$U_CACHE"
    printf '{"scope":"user"}\n' > "$U_CACHE/install-profile.json"
    printf '{"env":{"HIMMEL_REPO":"/fixture/himmel","KEEP":"yes"}}\n' > "$HIMMEL_USER_SETTINGS"
    cp "$HIMMEL_USER_SETTINGS" "$TMP/u-settings-before"
    : > "$CLAUDE_CALL_LOG"
    printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
    printf '[{"name":"himmel"},{"name":"obsidian-skills"},{"name":"claude-plugins-official"}]\n' > "$STUB_MARKETPLACES_JSON"
    STUB_FAIL_IDS=""
}
u_run() {
    out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
        TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
        bash "$CLI" --yes --skip-tasks "$@" </dev/null 2>&1); rc=$?
    calls=$(cat "$CLAUDE_CALL_LOG")
}

# U1 — RED: the old plugin failure still unwired settings and deleted cache.
u_fixture u1
STUB_FAIL_IDS='handover@himmel'
u_run
assert_rc 'U1 failed plugins halt teardown' 2 "$rc"
for step in '[6/8] settings unwire' '[7/8] Claude marketplaces' '[8/8] himmelctl cache'; do
    assert_has "U1 $step skipped" "$step: skipped — halted after an earlier failure" "$out"
done
assert_has 'U1 first failure named' 'Halted at: [4/8]' "$out"
cmp -s "$HIMMEL_USER_SETTINGS" "$TMP/u-settings-before"; same=$?
assert_rc 'U1 settings byte-identical' 0 "$same"
if [ -d "$U_CACHE" ] && [ -f "$U_CACHE/install-profile.json" ]; then
    echo 'PASS U1 cache and profile survive'
else
    echo 'FAIL U1 cache or profile removed'; FAILED=$((FAILED + 1))
fi
assert_not_has 'U1 no marketplace removals' 'plugin marketplace remove' "$calls"

# U2 — same fixture with successful uninstalls must finish the teardown.
u_fixture u2
u_run
assert_rc 'U2 successful plugins complete teardown' 0 "$rc"
assert_has 'U2 completion reported' 'Uninstall complete.' "$out"
cmp -s "$HIMMEL_USER_SETTINGS" "$TMP/u-settings-before"; same=$?
assert_rc 'U2 settings unwired' 1 "$same"
if [ ! -e "$U_CACHE" ]; then echo 'PASS U2 cache removed'
else echo 'FAIL U2 cache survived'; FAILED=$((FAILED + 1)); fi
assert_has 'U2 marketplaces removed' 'plugin marketplace remove' "$calls"

# U3 — absent pre-commit with only sample hooks is a note, not a halt.
u_fixture u3
u_run
assert_rc 'U3 no framework hooks completes' 0 "$rc"
assert_has 'U3 absent pre-commit is a note' "note: \`pre-commit\` not found and this repo carries no framework hooks — nothing to uninstall" "$out"
assert_has 'U3 settings ran' '[6/8] Unwiring' "$out"
assert_has 'U3 marketplaces ran' 'plugin marketplace remove himmel' "$calls"
assert_not_has 'U3 later steps not skipped' 'skipped — halted' "$out"
if [ ! -e "$U_CACHE" ]; then echo 'PASS U3 step 8 removed cache'
else echo 'FAIL U3 step 8 left cache'; FAILED=$((FAILED + 1)); fi

# U4 — a real framework hook requires the missing tool and halts step 5.
u_fixture u4
printf '# pre-commit managed hook\n' > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U4 framework hooks require pre-commit' 2 "$rc"
assert_has 'U4 first failure is hooks' 'Halted at: [5/8]' "$out"
cmp -s "$HIMMEL_USER_SETTINGS" "$TMP/u-settings-before"; same=$?
assert_rc 'U4 settings byte-identical' 0 "$same"
assert_not_has 'U4 no marketplace removals' 'plugin marketplace remove' "$calls"

# U4b — RED HIMMEL-2754: a worktree's .git file must resolve shared hooks.
u_fixture u4b
U_CHECKOUT="$U_REPO"
U_REPO="$TMP/u-worktree"
mkdir -p "$U_REPO" "$TMP/u-gitdir/hooks"
ln -s "$U_CHECKOUT/scripts" "$U_REPO/scripts"
ln -s "$U_CHECKOUT/docs" "$U_REPO/docs"
printf 'gitdir: %s/u-gitdir\n' "$TMP" > "$U_REPO/.git"
printf '# pre-commit managed hook\n' > "$TMP/u-gitdir/hooks/pre-commit"
# Stub only the two read-only queries; never invoke real git. Return a
# relative hooks path to also exercise resolution against REPO_ROOT.
cat > "$U_BIN/git" <<'STUB_EOF'
#!/usr/bin/env bash
[ "$1" = '-C' ] || exit 1
case "$3 $4 $5" in
    'config --get core.hooksPath') exit 1 ;;
    'rev-parse --git-path hooks')
        IFS= read -r gitdir < "$2/.git"
        [ "$gitdir" = "gitdir: ${2%/*}/u-gitdir" ] || exit 1
        printf '../u-gitdir/hooks\n'
        ;;
    *) exit 1 ;;
esac
STUB_EOF
chmod 755 "$U_BIN/git"
u_run
assert_rc 'U4b worktree hooks require pre-commit' 2 "$rc"
assert_has 'U4b first failure is hooks' 'Halted at: [5/8]' "$out"
assert_not_has 'U4b no marketplace removals' 'plugin marketplace remove' "$calls"
rm "$U_BIN/git"
U_REPO="$U_CHECKOUT"

# U4c — HIMMEL-2839 native-gate removal + HIMMEL-2841 RED control: a
# native-only repo (three HIMMEL-2771 marker hooks, one foreign hook, plus
# the pre-existing .sample) with pre-commit absent from PATH completes all 8
# steps and removes only the marker-bearing files. Under the pre-fix code
# (no native-gate removal at all, and repo_has_framework_hooks matching the
# bare substring "pre-commit" — which the marker text itself contains) this
# halted at [5/8] with rc=2 and left steps 6-8 undone; run against that code
# this test fails.
u_fixture u4c
rm -f "$U_REPO/.git/hooks/commit-msg"
for hook in commit-msg pre-commit pre-push; do
    printf '#!/usr/bin/env bash\n# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.\nexit 0\n' \
        > "$U_REPO/.git/hooks/$hook"
    chmod 755 "$U_REPO/.git/hooks/$hook"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$U_REPO/.git/hooks/post-checkout"
chmod 755 "$U_REPO/.git/hooks/post-checkout"
u_run
assert_rc 'U4c native-only completes all 8 steps' 0 "$rc"
assert_has 'U4c completion reported' 'Uninstall complete.' "$out"
assert_not_has 'U4c no halted steps' 'skipped — halted' "$out"
assert_has 'U4c framework-absent noted' "note: \`pre-commit\` not found and this repo carries no framework hooks — nothing to uninstall" "$out"
for hook in commit-msg pre-commit pre-push; do
    assert_has "U4c removed $hook reported" "removed native gate: $U_REPO/.git/hooks/$hook" "$out"
    if [ ! -e "$U_REPO/.git/hooks/$hook" ]; then echo "PASS U4c $hook removed"
    else echo "FAIL U4c $hook survived"; FAILED=$((FAILED + 1)); fi
done
if [ -f "$U_REPO/.git/hooks/post-checkout" ]; then echo 'PASS U4c foreign hook intact'
else echo 'FAIL U4c foreign hook removed'; FAILED=$((FAILED + 1)); fi
if [ -f "$U_REPO/.git/hooks/pre-commit.sample" ]; then echo 'PASS U4c sample intact'
else echo 'FAIL U4c sample removed'; FAILED=$((FAILED + 1)); fi

# U4d — HIMMEL-2839 --dry-run: lists the native gates it would remove and
# removes nothing (byte-identical hooks dir before/after). HIMMEL-2841: does
# not misreport them as framework hooks and halt either, even though the
# marker text on disk still contains the substring "pre-commit" (dry-run
# never deletes, so the old detection bug is live here regardless of the
# native-removal step's own ordering).
u_fixture u4d
for hook in commit-msg pre-commit pre-push; do
    printf '#!/usr/bin/env bash\n# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.\nexit 0\n' \
        > "$U_REPO/.git/hooks/$hook"
    chmod 755 "$U_REPO/.git/hooks/$hook"
done
U4D_BEFORE="$TMP/u4d-hooks-before.txt"
(cd "$U_REPO/.git/hooks" && cksum -- * | sort) > "$U4D_BEFORE"
u_run --dry-run
assert_rc 'U4d dry-run completes' 0 "$rc"
assert_not_has 'U4d no halted steps' 'skipped — halted' "$out"
for hook in commit-msg pre-commit pre-push; do
    assert_has "U4d dry-run would-remove $hook" "DRY: would remove native gate: $U_REPO/.git/hooks/$hook" "$out"
done
U4D_AFTER="$TMP/u4d-hooks-after.txt"
(cd "$U_REPO/.git/hooks" && cksum -- * | sort) > "$U4D_AFTER"
cmp -s "$U4D_BEFORE" "$U4D_AFTER"; same=$?
assert_rc 'U4d hooks byte-identical across dry-run' 0 "$same"

# U4e — HIMMEL-2839 fail-closed: an undeletable native gate hook fails the
# step (rc != 0) and halts every later step — the step's own read-back is
# the evidence, never `rm`'s return code alone.
u_fixture u4e
# U4d's dry-run left its native fixture (and U4c its foreign hook) on disk —
# clean the persistent U_REPO hooks dir down to a single fixture file first.
rm -f "$U_REPO/.git/hooks/post-checkout" "$U_REPO/.git/hooks/pre-commit" "$U_REPO/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\n# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.\nexit 0\n' \
    > "$U_REPO/.git/hooks/commit-msg"
chmod 755 "$U_REPO/.git/hooks/commit-msg"
chmod a-w "$U_REPO/.git/hooks"
if [ -w "$U_REPO/.git/hooks" ]; then
    echo 'SKIP U4e fail-closed (root can write mode a-w dirs; fixture requires an unprivileged user)'
    chmod 755 "$U_REPO/.git/hooks"
    rm -f "$U_REPO/.git/hooks/commit-msg"
else
    u_run
    assert_rc 'U4e undeletable native gate halts' 2 "$rc"
    assert_has 'U4e first failure is hooks' 'Halted at: [5/8]' "$out"
    assert_has 'U4e removal error reported' "could not remove native gate hook $U_REPO/.git/hooks/commit-msg" "$out"
    for step in '[6/8] settings unwire' '[7/8] Claude marketplaces' '[8/8] himmelctl cache'; do
        assert_has "U4e $step skipped" "$step: skipped — halted after an earlier failure" "$out"
    done
    chmod 755 "$U_REPO/.git/hooks"
    rm -f "$U_REPO/.git/hooks/commit-msg"
fi

# WHY (HIMMEL-2754): settings and marketplace failures must preserve the
# retry profile too — the same halt rule applies past the plugin/hook steps.
u_fixture u5
printf 'invalid JSON\n' > "$HIMMEL_USER_SETTINGS"
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
assert_rc 'U5 invalid settings halt teardown' 2 "$rc"
assert_has 'U5 first failure is settings' 'Halted at: [6/8]' "$out"
assert_not_has 'U5 marketplaces untouched' 'plugin marketplace remove' "$(cat "$CLAUDE_CALL_LOG")"
if [ -f "$U_CACHE/install-profile.json" ]; then echo 'PASS U5 retry profile survives'
else echo 'FAIL U5 retry profile removed'; FAILED=$((FAILED + 1)); fi

u_fixture u6
STUB_FAIL_IDS='himmel'
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
assert_rc 'U6 failed marketplace halts teardown' 2 "$rc"
assert_has 'U6 first failure is marketplaces' 'Halted at: [7/8]' "$out"
if [ -f "$U_CACHE/install-profile.json" ]; then echo 'PASS U6 retry profile survives'
else echo 'FAIL U6 retry profile removed'; FAILED=$((FAILED + 1)); fi

# WHY (HIMMEL-2754): both dry-run children retain installed plugins physically.
u_fixture u7
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --dry-run --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF '[7/8] Claude marketplaces:' <<< "$out" &&
    grep -qF 'DRY: claude plugin marketplace remove himmel' <<< "$out"; then
    echo 'ok - U7 healthy dry-run completes marketplace step'
else
    echo 'FAIL - U7: healthy dry-run reported a failed marketplace step'; FAILED=$((FAILED + 1))
fi

# WHY (HIMMEL-2754): installed scope must survive the split child processes.
u_fixture u8
jq -n --arg here "$PWD" '[{id:"handover@himmel",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
out=$(HOME="$U_HOME" PATH="$U_BIN:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" \
    TELEGRAM_CHANNEL_DIR="$CHANNEL" BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --yes --skip-tasks --skip-hooks </dev/null 2>&1); rc=$?
calls=$(cat "$CLAUDE_CALL_LOG")
# WHY (HIMMEL-2796): plugin scopes do not reveal registration scopes, so
# removal also tries the install-profile scope (user) alongside the
# preserved project scope — the persisted project scope must still survive.
if [ "$rc" -eq 0 ] && grep -qxF 'plugin marketplace remove himmel --scope project' <<< "$calls" &&
    grep -qxF 'plugin marketplace remove himmel --scope user' <<< "$calls"; then
    echo 'ok - U8 marketplace removal retains project scope across children'
else
    echo 'FAIL - U8: marketplace removal lost project scope between children'; FAILED=$((FAILED + 1))
fi


# U9 — a halt after project plugin removal must preserve scopes for a retry.
u_fixture u9
jq -n --arg here "$PWD" '[{id:"handover@himmel",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
printf '# pre-commit managed hook\n' > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U9 first run halts after removing project plugin' 2 "$rc"
assert_has 'U9 first failure is hooks' 'Halted at: [5/8]' "$out"
assert_has 'U9 first run removes plugin at project scope' 'plugin uninstall handover@himmel --scope project' "$calls"
if [ -f "$U_CACHE/uninstall-scope-map" ]; then
    echo 'PASS U9 halted run retains scope handoff'
else
    echo 'FAIL U9 halted run lost scope handoff'; FAILED=$((FAILED + 1))
fi
rm "$U_REPO/.git/hooks/commit-msg"
: > "$CLAUDE_CALL_LOG"
u_run
assert_rc 'U9 retry completes teardown' 0 "$rc"
assert_has 'U9 retry removes marketplace at preserved project scope' 'plugin marketplace remove himmel --scope project' "$calls"
# WHY (HIMMEL-2796): also tries the install-profile scope (user) — plugin
# scopes alone do not prove where a marketplace is registered.
assert_has 'U9 retry also tries install-profile user scope for himmel' 'plugin marketplace remove himmel --scope user' "$calls"
if [ ! -e "$U_CACHE" ]; then
    echo 'PASS U9 successful retry removes cache and handoff'
else
    echo 'FAIL U9 successful retry left cache or handoff'; FAILED=$((FAILED + 1))
fi

# U10 — an unused handoff cannot halt --skip-plugins when TMPDIR is unavailable.
u_fixture u10
TMPDIR="$TMP/missing-handoff-dir" u_run --skip-plugins
assert_rc 'U10 skip-plugins completes without a usable temporary directory' 0 "$rc"
assert_has 'U10 skip-plugins reports completion' 'Uninstall complete.' "$out"
if [ ! -e "$U_CACHE/uninstall-scope-map" ]; then
    echo 'PASS U10 skip-plugins creates no scope handoff'
else
    echo 'FAIL U10 skip-plugins created a scope handoff'; FAILED=$((FAILED + 1))
fi

# U11 — a completed retry must keep the first marketplace's real scope.
u_fixture u11
cat > "$U_REPO/docs/setup/settings-template.json" <<'JSON'
{
  "enabledPlugins": {"a@m1": true, "b@m2": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}},
    "m2": {"source": {"source":"github", "repo":"example/m2"}}
  }
}
JSON
jq -n --arg here "$PWD" '[{id:"a@m1",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"},{"name":"m2"}]\n' > "$STUB_MARKETPLACES_JSON"
printf '# pre-commit managed hook\n' > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U11 first run halts after project plugin removal' 2 "$rc"
assert_has 'U11 first failure is hooks' 'Halted at: [5/8]' "$out"
assert_has 'U11 first run removes m1 at project scope' 'plugin uninstall a@m1 --scope project' "$calls"
jq -n '[{id:"b@m2",scope:"user"}]' > "$STUB_PLUGINS_JSON"
rm "$U_REPO/.git/hooks/commit-msg"
: > "$CLAUDE_CALL_LOG"
u_run
assert_rc 'U11 retry completes teardown' 0 "$rc"
assert_has 'U11 retry removes m1 marketplace at project scope' 'plugin marketplace remove m1 --scope project' "$calls"
# WHY (HIMMEL-2796): also tries the install-profile scope (user) for m1 —
# plugin scopes alone do not prove where a marketplace is registered.
assert_has 'U11 retry also tries m1 at install-profile user scope' 'plugin marketplace remove m1 --scope user' "$calls"
assert_has 'U11 retry removes m2 marketplace at user scope' 'plugin marketplace remove m2 --scope user' "$calls"

# U12 — a symlinked cache gets an ephemeral handoff and leaves its target alone.
u_fixture u12
cat > "$U_REPO/docs/setup/settings-template.json" <<'JSON'
{
  "enabledPlugins": {"a@m1": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}}
  }
}
JSON
printf '[{"id":"a@m1","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
U12_TARGET="$TMP/u12-cache-target"
mkdir -p "$U12_TARGET"
printf 'preserve me\n' > "$U12_TARGET/pre-existing"
cp "$U12_TARGET/pre-existing" "$TMP/u12-target-before"
rm -rf "$U_CACHE"
ln -s "$U12_TARGET" "$U_CACHE"
u_run
assert_rc 'U12 symlinked cache completes teardown' 0 "$rc"
assert_has 'U12 reports ephemeral scope-map fallback' 'WARN: using ephemeral scope-map handoff' "$out"
if [ -z "$(find "$U12_TARGET" -name uninstall-scope-map -print -quit)" ]; then
    echo 'PASS U12 symlink target has no scope handoff'
else
    echo 'FAIL U12 symlink target received scope handoff'; FAILED=$((FAILED + 1))
fi
cmp -s "$TMP/u12-target-before" "$U12_TARGET/pre-existing"; u12_target_rc=$?
if [ "$u12_target_rc" -eq 0 ]; then
    echo 'PASS U12 symlink target content survives'
else
    echo 'FAIL U12 symlink target content changed'; FAILED=$((FAILED + 1))
fi

# U13 — an unresolved worktree hook location must halt before cache removal.
u_fixture u13
# The preceding rows already removed the fixture pre-commit stub.
mv "$U_REPO/.git" "$TMP/u13-hooks-dir"
printf 'gitdir: /unresolved/fixture\n' > "$U_REPO/.git"
u_run --skip-plugins
assert_rc 'U13 unresolved hooks halt' 2 "$rc"
assert_has 'U13 names unresolved hooks' 'cannot determine whether this repo carries framework hooks' "$out"
assert_has 'U13 halts at hooks step' 'Halted at: [5/8]' "$out"
if [ -d "$U_CACHE" ]; then
    echo 'PASS U13 cache survives unresolved hooks'
else
    echo 'FAIL U13 cache removed despite unresolved hooks'; FAILED=$((FAILED + 1))
fi
rm "$U_REPO/.git"
mv "$TMP/u13-hooks-dir" "$U_REPO/.git"

# U14 — WHY (HIMMEL-2754): a regular cache file is removable residue.
u_fixture u14
printf '[{"id":"a@m1","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
rm -rf "$U_CACHE"
printf 'cache residue\n' > "$U_CACHE"
u_run
assert_rc 'U14 regular cache file completes teardown' 0 "$rc"
assert_has 'U14 reports ephemeral scope-map fallback' 'WARN: using ephemeral scope-map handoff' "$out"
assert_not_has 'U14 does not halt at scope handoff' 'Halted at: [4/8]' "$out"
if [ ! -e "$U_CACHE" ]; then
    echo 'PASS U14 step 8 removes regular cache file'
else
    echo 'FAIL U14 regular cache file survived'; FAILED=$((FAILED + 1))
fi

# U15 — a dry retry must preview persisted scopes without changing the map.
u_fixture u15
cat > "$U_REPO/docs/setup/settings-template.json" <<'JSON'
{
  "enabledPlugins": {"a@m1": true, "b@m2": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}},
    "m2": {"source": {"source":"github", "repo":"example/m2"}}
  }
}
JSON
jq -n --arg here "$PWD" '[{id:"a@m1",scope:"project",projectPath:$here}]' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"},{"name":"m2"}]\n' > "$STUB_MARKETPLACES_JSON"
printf '# pre-commit managed hook\n' > "$U_REPO/.git/hooks/commit-msg"
u_run
assert_rc 'U15 first run halts after project plugin removal' 2 "$rc"
assert_has 'U15 first failure is hooks' 'Halted at: [5/8]' "$out"
assert_has 'U15 first run removes m1 at project scope' 'plugin uninstall a@m1 --scope project' "$calls"
cp "$U_CACHE/uninstall-scope-map" "$TMP/u15-scope-map-before"
jq -n '[{id:"b@m2",scope:"user"}]' > "$STUB_PLUGINS_JSON"
rm "$U_REPO/.git/hooks/commit-msg"
: > "$CLAUDE_CALL_LOG"
u_run --dry-run
assert_rc 'U15 dry retry completes preview' 0 "$rc"
assert_has 'U15 dry retry previews m1 marketplace at project scope' 'DRY: claude plugin marketplace remove m1 --scope project' "$out"
# WHY (HIMMEL-2796): the preview also covers the install-profile scope
# (user) — plugin scopes alone do not prove where a marketplace is registered.
assert_has 'U15 dry retry also previews m1 at install-profile user scope' 'DRY: claude plugin marketplace remove m1 --scope user' "$out"
if [ -f "$U_CACHE/uninstall-scope-map" ] && cmp -s "$TMP/u15-scope-map-before" "$U_CACHE/uninstall-scope-map"; then
    echo 'PASS U15 persisted scope map survives byte-identical'
else
    echo 'FAIL U15 persisted scope map missing or changed'; FAILED=$((FAILED + 1))
fi

# U16 — RED 12 (HIMMEL-2754): a failed map read must warn about fallback scopes.
u_fixture u16
printf '[]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
printf 'm1\tproject\t%s\n' "$PWD" > "$U_CACHE/uninstall-scope-map"
U16_CAT=$(command -v cat)
mkdir -p "$TMP/u16-bin"
cat > "$TMP/u16-bin/cat" <<'STUB'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$HIMMELCTL_CACHE_DIR/uninstall-scope-map" ]; then
    printf 'm1\tproject\t%s\n' "$PWD"
    exit 1
fi
exec "$U16_CAT" "$@"
STUB
chmod +x "$TMP/u16-bin/cat"
out=$(HOME="$U_HOME" PATH="$TMP/u16-bin:$U_BIN:$HBIN" U16_CAT="$U16_CAT" \
    HIMMEL_UNINSTALL_REPO_ROOT="$U_REPO" TELEGRAM_CHANNEL_DIR="$CHANNEL" \
    BRIDGE_ROOT="$BRIDGE" HIMMELCTL_CACHE_DIR="$U_CACHE" \
    bash "$CLI" --yes --dry-run --skip-tasks --skip-hooks --skip-settings </dev/null 2>&1); rc=$?
assert_rc 'RED 12: failed preview map read keeps exit 0' 0 "$rc"
assert_has 'RED 12: failed preview map read warns with map path' \
    "WARN: could not read $U_CACHE/uninstall-scope-map" "$out"
assert_has 'RED 12: warning explains fallback scope' \
    'preview will show marketplace removals at the fallback scope rather than the recorded scopes' "$out"
assert_has 'RED 12: partial read is truncated before fallback preview' \
    'DRY: claude plugin marketplace remove m1 --scope user' "$out"
assert_not_has 'RED 12: partial read never previews recorded scope' \
    'DRY: claude plugin marketplace remove m1 --scope project' "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
