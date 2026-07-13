#!/usr/bin/env bash
# Smoke test for scripts/cleanup/codex-sweep-cadence.sh (HIMMEL-892).
#
# Single daily task (HIMMEL-CodexOrphanSweep) fires a runner .bat that runs
# scripts/cleanup/sweep-codex-orphans.ps1 -Kill then scripts/codex/
# reap-mcp-fleet.ps1 -Kill via a resolved pwsh/powershell. Windows-only
# (schtasks + cygpath): the malformed-input rc-1 path and the POSIX rc-2
# refusal path are pure-unit / platform-detect checks that run on EVERY
# platform (they short-circuit before any schtasks/cygpath call); the full
# arm suite (schtasks create + runner-emission + post-arm verify) is gated
# Windows-only, mirroring scripts/luna/test-graphmap-cadence.sh's SKIP block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/codex-sweep-cadence.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

REAL_BASH="$(command -v bash)"

export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

# ============================================================================
# Pure / platform-detect suite — runs on EVERY platform (no schtasks/cygpath
# needed): --time validation happens BEFORE the platform gate (T4), and the
# platform gate itself is the very first schtasks-touching decision (T5).
# ============================================================================

echo "TEST: malformed --time rejected before the platform gate (T4)"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm --time 23:5 2>&1) || rc=$?
assert_rc "malformed --time -> rc 1 (all platforms)" 1 "$rc"
assert_contains "malformed --time message" "--time" "$out"

echo "TEST: --time with no value -> rc 1, usage message, not a raw bash shift error (FIX 3 / coderabbit-1)"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm --time 2>&1) || rc=$?
assert_rc "arm --time (missing value) -> rc 1" 1 "$rc"
assert_contains "arm --time (missing value) message" "--time requires a value" "$out"
assert_not_contains "arm --time (missing value) is not a raw bash shift error" "shift count" "$out"

echo "TEST: non-Windows platform refused Windows-only (T5)"
rc=0; out=$(env HOME="$HOME" OSTYPE=linux-gnu "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "POSIX platform -> rc 2" 2 "$rc"
assert_contains "POSIX platform message" "Windows-only" "$out"
rc=0; out=$(env HOME="$HOME" OSTYPE=darwin20 "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "macOS platform -> rc 2" 2 "$rc"

echo "TEST: usage errors"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"

echo "TEST: --time is arm-only -> rc 1 on status/disarm (even well-formed)"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" status --time 09:00 2>&1) || rc=$?
assert_rc "status --time -> rc 1" 1 "$rc"
assert_contains "status --time message" "--time is arm-only" "$out"
rc=0; out=$(env HOME="$HOME" "$REAL_BASH" "$SCRIPT" disarm --time 09:00 2>&1) || rc=$?
assert_rc "disarm --time -> rc 1" 1 "$rc"
assert_contains "disarm --time message" "--time is arm-only" "$out"

# ============================================================================
# schtasks suite — Windows-only (needs cygpath/schtasks shapes), mirrors
# test-graphmap-cadence.sh's platform-gate SKIP block.
# ============================================================================

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) : ;;
    *)
        echo "SKIP: schtasks suite (Windows-only — needs cygpath/schtasks shapes)"
        summary
        ;;
esac

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/tasks"

# Fake schtasks: persists tasks as files under $STATE/tasks/<name> (content =
# the created XML). Records every invocation's argv to $STATE/calls.log so
# --dry-run can be asserted to have made no /create or /delete calls (T6).
# /query /tn <name> returns a canned "Next Run Time" line (used by the dedup
# guard and cmd_status/cmd_disarm's own /query classifier — the post-arm
# verify itself no longer reads schtasks text, see FAKE_PWSH below) unless
# $STATE/fail-query is present (simulates the query tool itself erroring,
# regardless of tn); if $STATE/localized-not-found is present, a missing-task
# /query emits a non-English not-found message instead of the English one
# (FIX 2 / codex-7 — exercises the locale-independent probe fallback).
FAKE_SCHTASKS="$TMP_ROOT/schtasks-fake.sh"
cat >"$FAKE_SCHTASKS" <<FAKE
#!$REAL_BASH
STATE="$STATE"
FAKE
cat >>"$FAKE_SCHTASKS" <<'FAKE'
printf '%s\n' "$*" >> "$STATE/calls.log"
tn=""; mode=""; xmlpath=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        /create|/delete|/query) mode="${args[$i]}" ;;
        /tn) i=$((i+1)); tn="${args[$i]}" ;;
        /xml) i=$((i+1)); xmlpath="${args[$i]}" ;;
    esac
    i=$((i+1))
done
case "$mode" in
    /create)
        if [ -e "$STATE/fail-create" ]; then
            echo "ERROR: Access is denied." >&2
            exit 1
        fi
        if [ -n "$xmlpath" ]; then
            xml_posix=$(cygpath -u "$xmlpath" 2>/dev/null || echo "$xmlpath")
            cat "$xml_posix" > "$STATE/tasks/$tn"
            # Immediate-fire regression probe (round-3 CR fix, HIMMEL-892):
            # read the runner .bat at its FINAL path (as embedded in the
            # just-created task's <Command>) and copy it to a probe file --
            # proves the runner is fully published BEFORE the task can
            # possibly exist to fire it (the exact publish-before-create
            # ordering this fix guarantees).
            cmd_win=$(grep -o '<Command>[^<]*</Command>' "$xml_posix" | sed -e 's/<Command>//' -e 's#</Command>##')
            if [ -n "$cmd_win" ]; then
                cmd_posix=$(cygpath -u "$cmd_win" 2>/dev/null || echo "$cmd_win")
                if [ -f "$cmd_posix" ]; then
                    cp "$cmd_posix" "$STATE/create-time-runner-probe.bat"
                fi
            fi
        else
            printf '%s\n' "$*" > "$STATE/tasks/$tn"
        fi
        echo "SUCCESS: The scheduled task \"$tn\" has successfully been created."
        ;;
    /delete)
        echo "$tn" >> "$STATE/deleted.log"
        if [ -f "$STATE/tasks/$tn" ]; then rm -f "$STATE/tasks/$tn"; fi
        echo "SUCCESS: The scheduled task \"$tn\" was successfully deleted."
        ;;
    /query)
        if [ -e "$STATE/fail-query" ]; then
            echo "ERROR: Access is denied." >&2
            exit 1
        fi
        if [ -f "$STATE/tasks/$tn" ]; then
            printf 'TaskName:      \\%s\nNext Run Time: 7/10/2026 9:00:00 AM\n' "$tn"
            exit 0
        fi
        if [ -e "$STATE/localized-not-found" ]; then
            echo "FEHLER: Das System kann die angegebene Datei nicht finden." >&2
            exit 1
        fi
        echo "ERROR: The system cannot find the file specified." >&2
        exit 1
        ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE_SCHTASKS"

BAT_DIR="$TMP_ROOT/bats"

# Fake pwsh — a real executable script. It serves three roles: (1) a path
# cygpath -w can convert for the runner .bat (the .bat itself is only ever
# inspected as text, never fired); (2) the post-arm NextRunTime verify probe
# (HIMMEL-892 review fix, invokes Get-ScheduledTaskInfo) DOES execute this
# directly; (3) query_task's locale-independent existence probe (FIX 2 /
# codex-7, invokes Get-ScheduledTask) ALSO executes this directly. Both (2)
# and (3) must behave like real scripts, not inert stubs, so this dispatches
# on which probe's -Command text it was invoked with (Get-ScheduledTaskInfo
# is checked FIRST since Get-ScheduledTask is a substring of it). Outcome is
# driven by state markers so each test can pick a canned response without
# touching the real ScheduledTasks module:
#   NextRunTime verify probe (Get-ScheduledTaskInfo):
#     $STATE/verify-epoch        — cat its contents as the epoch answer
#     $STATE/verify-nextrun-none — print NEXTRUN-NONE, rc 0
#     $STATE/verify-probe-fail   — rc 1, empty stdout (simulates a dead probe)
#     (none present)             — default healthy epoch answer, rc 0
#   Existence probe (Get-ScheduledTask):
#     $STATE/query-probe-exists              — print EXISTS, rc 0
#     $STATE/query-probe-object-not-found    — print ABSENT, rc 0
#     $STATE/query-probe-command-not-found   — rc 1 (simulates CommandNotFoundException)
#     (none present)                         — rc 1 (no marker set for this test)
FAKE_PWSH="$TMP_ROOT/bin/fake-pwsh.sh"
mkdir -p "$TMP_ROOT/bin"
cat >"$FAKE_PWSH" <<FAKE
#!$REAL_BASH
STATE="$STATE"
FAKE
cat >>"$FAKE_PWSH" <<'FAKE'
argv="$*"
case "$argv" in
    *Get-ScheduledTaskInfo*)
        if [ -e "$STATE/verify-probe-fail" ]; then
            echo "fake-pwsh: simulated probe failure" >&2
            exit 1
        fi
        if [ -e "$STATE/verify-nextrun-none" ]; then
            echo "NEXTRUN-NONE"
            exit 0
        fi
        if [ -e "$STATE/verify-epoch" ]; then
            cat "$STATE/verify-epoch"
            exit 0
        fi
        echo "1799999999"
        exit 0
        ;;
    *Get-ScheduledTask*)
        if [ -e "$STATE/query-probe-command-not-found" ]; then
            echo "fake-pwsh: simulated CommandNotFoundException" >&2
            exit 1
        fi
        if [ -e "$STATE/query-probe-object-not-found" ]; then
            echo "ABSENT"
            exit 0
        fi
        if [ -e "$STATE/query-probe-exists" ]; then
            echo "EXISTS"
            exit 0
        fi
        echo "fake-pwsh: no query-probe state marker set" >&2
        exit 1
        ;;
    *)
        echo "fake-pwsh: unrecognized probe command" >&2
        exit 1
        ;;
esac
FAKE
chmod +x "$FAKE_PWSH"

reset_state() {
    rm -rf "$STATE"
    mkdir -p "$STATE/tasks"
    rm -rf "$BAT_DIR"
}

run_sc() {
    env SWEEP_SCHTASKS="$FAKE_SCHTASKS" SWEEP_BAT_DIR="$BAT_DIR" SWEEP_PWSH="$FAKE_PWSH" \
        HOME="$HOME" "$REAL_BASH" "$SCRIPT" "$@"
}

# Test T1 / T1b / T2: arm creates the task + emits the runner .bat -----------

echo "TEST: arm creates task via /create /tn ... /xml, emits runner .bat (T1)"
reset_state
out=$(run_sc arm)
assert_contains "arm banner" "CODEX-SWEEP CADENCE ARMED" "$out"
if [ -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ]; then
    pass "task created under the fixed name HIMMEL-CodexOrphanSweep"
else
    fail "task not created" "$(ls "$STATE/tasks" 2>/dev/null || true)"
fi
calls=$(cat "$STATE/calls.log" 2>/dev/null || echo MISSING)
assert_contains "schtasks invoked with /create /tn HIMMEL-CodexOrphanSweep /xml" "/create /tn HIMMEL-CodexOrphanSweep /xml" "$calls"

bat=$(cat "$BAT_DIR/codex-sweep.bat" 2>/dev/null || echo MISSING)
assert_contains "bat stamps the format version (HIMMEL-588)" "himmel-cadence-runner-format: 3" "$bat"
assert_contains "bat fires sweep-codex-orphans.ps1 -Kill" "sweep-codex-orphans.ps1" "$bat"
assert_contains "bat fires reap-mcp-fleet.ps1 -Kill" "reap-mcp-fleet.ps1" "$bat"
assert_contains "bat passes -Kill to the sweep payload" "sweep-codex-orphans.ps1" "$bat"
if printf '%s' "$bat" | grep -qE 'sweep-codex-orphans\.ps1"[^\r\n]*-Kill'; then
    pass "sweep payload line carries -Kill"
else
    fail "sweep payload line missing -Kill"
fi
if printf '%s' "$bat" | grep -qE 'reap-mcp-fleet\.ps1"[^\r\n]*-Kill'; then
    pass "reap payload line carries -Kill"
else
    fail "reap payload line missing -Kill"
fi
assert_contains "bat stamps sweep exit rc" "sweep exit rc=%ERRORLEVEL%" "$bat"
assert_contains "bat stamps reap exit rc" "reap exit rc=%ERRORLEVEL%" "$bat"
assert_contains "bat rotates the log (move /y)" "move /y" "$bat"
fake_pwsh_win=$(cygpath -w "$FAKE_PWSH")
assert_contains "bat carries the resolved pwsh path" "$fake_pwsh_win" "$bat"
for what in --settings "< NUL" "< /dev/null"; do
    assert_not_contains "bat has no claude-session marker ($what)" "$what" "$bat"
done

echo "TEST: created XML carries InteractiveToken/LeastPrivilege + default 09:00 (T1b)"
xml=$(cat "$STATE/tasks/HIMMEL-CodexOrphanSweep" 2>/dev/null || echo MISSING)
assert_contains "XML LogonType InteractiveToken" "<LogonType>InteractiveToken</LogonType>" "$xml"
assert_contains "XML RunLevel LeastPrivilege" "<RunLevel>LeastPrivilege</RunLevel>" "$xml"
assert_contains "XML StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$xml"
assert_contains "XML default time 09:00" "T09:00:00" "$xml"
assert_contains "XML Actions Context=Author" '<Actions Context="Author">' "$xml"

# Test FIX-A: HIMMEL_ROOT resolves to the PRIMARY checkout, not this script's
# own dirname (codex-adv-1, HIMMEL-892) --------------------------------------

echo "TEST: emitted .bat payload paths resolve to the PRIMARY checkout via git-common-dir, not this script's own dirname (FIX A / codex-adv-1)"
reset_state
# Independently compute the expected primary root the SAME WAY the fix does
# (git-common-dir -> parent dir), so this proves the derivation rather than
# just re-reading the script's own logic. If SCRIPT_DIR itself sits inside a
# worktree (as it does when this suite runs from a feature worktree), this
# independently-computed root will differ from SCRIPT_DIR/../.. -- that
# divergence is exactly what codex-adv-1 exists to catch.
_common_dir=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$_common_dir" ]; then
    case "$_common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *) _common_dir="$SCRIPT_DIR/$_common_dir" ;;
    esac
    _primary_root=$(cd "$(dirname "$_common_dir")" && pwd)
    _primary_sweep_win=$(cygpath -w "$_primary_root/scripts/cleanup/sweep-codex-orphans.ps1")
    _primary_reap_win=$(cygpath -w "$_primary_root/scripts/codex/reap-mcp-fleet.ps1")
    run_sc arm >/dev/null
    bat=$(cat "$BAT_DIR/codex-sweep.bat" 2>/dev/null || echo MISSING)
    assert_contains "bat sweep payload path is the git-common-dir-derived primary root" "$_primary_sweep_win" "$bat"
    assert_contains "bat reap payload path is the git-common-dir-derived primary root" "$_primary_reap_win" "$bat"
else
    fail "could not independently compute the primary root via git-common-dir (test setup broken)"
fi

echo "TEST: missing payload script under SWEEP_HIMMEL_ROOT -> rc 2, no schtasks touched (FIX A / codex-adv-1)"
reset_state
EMPTY_ROOT="$TMP_ROOT/no-payloads-here"
mkdir -p "$EMPTY_ROOT"
rc=0
out=$(env SWEEP_SCHTASKS="$FAKE_SCHTASKS" SWEEP_BAT_DIR="$BAT_DIR" SWEEP_PWSH="$FAKE_PWSH" \
    SWEEP_HIMMEL_ROOT="$EMPTY_ROOT" HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "missing payload (SWEEP_HIMMEL_ROOT override) -> rc 2" 2 "$rc"
assert_contains "missing payload message names sweep-codex-orphans.ps1" "sweep-codex-orphans.ps1 not found" "$out"
if [ ! -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ] && [ ! -f "$STATE/calls.log" ]; then
    pass "no task/schtasks call made when payload missing"
else
    fail "schtasks touched despite missing payload" "$(cat "$STATE/calls.log" 2>/dev/null || true)"
fi

echo "TEST: --time 06:30 flips the StartBoundary"
reset_state
run_sc arm --time 06:30 >/dev/null
xml=$(cat "$STATE/tasks/HIMMEL-CodexOrphanSweep" 2>/dev/null || echo MISSING)
assert_contains "XML overridden time 06:30" "T06:30:00" "$xml"

echo "TEST: post-arm verify succeeds when Get-ScheduledTaskInfo reports a NextRunTime epoch (T2)"
reset_state
echo "1799999999" > "$STATE/verify-epoch"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "arm with healthy post-arm verify -> rc 0" 0 "$rc"
if [ -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ]; then
    pass "task left armed after successful post-arm verify"
else
    fail "task missing after successful post-arm verify"
fi
# The banner renders the epoch human-readable (same conversion the script
# uses; falls back to the raw epoch where date -d is unavailable).
expected_next=$(date -d "@1799999999" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "1799999999")
assert_contains "success banner reports the verified NextRunTime (formatted)" "$expected_next" "$out"
rm -f "$STATE/verify-epoch"

# Test T3: NEXTRUN-NONE answer rolls back + exits 4 (fail CLOSED) ------------

echo "TEST: post-arm verify NEXTRUN-NONE answer rolls back, rc 4 (T3)"
reset_state
touch "$STATE/verify-nextrun-none"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "post-arm verify NEXTRUN-NONE -> rc 4" 4 "$rc"
if [ ! -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ]; then
    pass "task deleted after failed post-arm verify"
else
    fail "task left behind after failed post-arm verify"
fi
deleted=$(cat "$STATE/deleted.log" 2>/dev/null || echo MISSING)
assert_contains "rollback recorded a /delete call" "HIMMEL-CodexOrphanSweep" "$deleted"
assert_contains "rollback NOTE names the --force re-arm recovery command (FIX B)" "re-arm with: bash scripts/cleanup/codex-sweep-cadence.sh arm" "$out"
rm -f "$STATE/verify-nextrun-none"

# Test T3b: probe failure fails OPEN -- arm stands, rc 0, WARN present -------

echo "TEST: post-arm verify probe failure fails OPEN -- arm stands, rc 0, WARN present (T3b)"
reset_state
touch "$STATE/verify-probe-fail"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "post-arm verify probe failure -> rc 0 (fail open)" 0 "$rc"
if [ -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ]; then
    pass "task left armed despite post-arm verify probe failure"
else
    fail "task deleted despite post-arm verify probe failure (should fail OPEN)"
fi
assert_contains "WARN present when verify probe fails" "WARN" "$out"
assert_contains "WARN names the unverified-arm reason" "post-arm NextRunTime verify could not run" "$out"
rm -f "$STATE/verify-probe-fail"

# Test FIX 1: atomic runner publication (codex-adv + qwenor-4/6, HIMMEL-892;
# reordered to publish BEFORE /create + verify in round-3, codex-adv round 3
# Important) -----------------------------------------------------------------

echo "TEST: atomic runner publication -- /create failure still leaves the published COMPLETE new .bat (not the old sentinel, not partial), no temp left (FIX 1a, round-3 reorder)"
reset_state
mkdir -p "$BAT_DIR"
printf 'SENTINEL-PRE-EXISTING-BAT\r\n' > "$BAT_DIR/codex-sweep.bat"
touch "$STATE/fail-create"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "arm with /create failure -> rc 4" 4 "$rc"
bat_after=$(cat "$BAT_DIR/codex-sweep.bat" 2>/dev/null || echo MISSING)
assert_not_contains "pre-existing sentinel .bat is GONE after /create failure (publish happens before /create now)" "SENTINEL-PRE-EXISTING-BAT" "$bat_after"
assert_contains "bat holds the COMPLETE new runner content after /create failure" "sweep-codex-orphans.ps1" "$bat_after"
assert_contains "bat holds the COMPLETE new runner content after /create failure (reap payload too, not partial)" "reap-mcp-fleet.ps1" "$bat_after"
if ls "$BAT_DIR"/.codex-sweep.bat.* >/dev/null 2>&1; then
    fail "temp runner file left behind after /create failure" "$(ls "$BAT_DIR"/.codex-sweep.bat.* 2>/dev/null)"
else
    pass "no temp runner file left behind after /create failure"
fi
rm -f "$STATE/fail-create"

echo "TEST: atomic runner publication -- NEXTRUN-NONE rollback deletes the task but still leaves the published COMPLETE new .bat (not the old sentinel), no temp left (FIX 1b, round-3 reorder)"
reset_state
mkdir -p "$BAT_DIR"
printf 'SENTINEL-PRE-EXISTING-BAT\r\n' > "$BAT_DIR/codex-sweep.bat"
touch "$STATE/verify-nextrun-none"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "arm with NEXTRUN-NONE rollback -> rc 4" 4 "$rc"
bat_after=$(cat "$BAT_DIR/codex-sweep.bat" 2>/dev/null || echo MISSING)
assert_not_contains "pre-existing sentinel .bat is GONE after NEXTRUN-NONE rollback (publish happens before /create now)" "SENTINEL-PRE-EXISTING-BAT" "$bat_after"
assert_contains "bat holds the COMPLETE new runner content after NEXTRUN-NONE rollback (inert without the deleted task)" "sweep-codex-orphans.ps1" "$bat_after"
if ls "$BAT_DIR"/.codex-sweep.bat.* >/dev/null 2>&1; then
    fail "temp runner file left behind after NEXTRUN-NONE rollback" "$(ls "$BAT_DIR"/.codex-sweep.bat.* 2>/dev/null)"
else
    pass "no temp runner file left behind after NEXTRUN-NONE rollback"
fi
rm -f "$STATE/verify-nextrun-none"

echo "TEST: atomic runner publication -- success path publishes new .bat content, no temp left (FIX 1c)"
reset_state
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "arm success -> rc 0" 0 "$rc"
bat=$(cat "$BAT_DIR/codex-sweep.bat" 2>/dev/null || echo MISSING)
assert_contains "published .bat holds new runner content" "sweep-codex-orphans.ps1" "$bat"
if ls "$BAT_DIR"/.codex-sweep.bat.* >/dev/null 2>&1; then
    fail "temp runner file left behind after success" "$(ls "$BAT_DIR"/.codex-sweep.bat.* 2>/dev/null)"
else
    pass "no temp runner file left behind after success"
fi

echo "TEST: immediate-fire regression -- the runner is fully published and readable at its FINAL path AT /create TIME, before the task can possibly exist (FIX 1d, round-3 CR fix, HIMMEL-892)"
reset_state
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "arm success -> rc 0" 0 "$rc"
if [ -f "$STATE/create-time-runner-probe.bat" ]; then
    pass "runner was readable at its final path at /create time (publish-before-create ordering holds)"
else
    fail "runner NOT readable at its final path at /create time -- publish-before-create ordering broken"
fi
probe=$(cat "$STATE/create-time-runner-probe.bat" 2>/dev/null || echo MISSING)
assert_contains "create-time probe carries the full new runner content (sweep payload)" "sweep-codex-orphans.ps1" "$probe"
assert_contains "create-time probe carries the full new runner content (reap payload)" "reap-mcp-fleet.ps1" "$probe"
assert_contains "create-time probe carries the format-version stamp (proves COMPLETE content, not partial)" "himmel-cadence-runner-format: 3" "$probe"

# Test T6: --dry-run touches nothing ------------------------------------------

echo "TEST: --dry-run makes no mutating schtasks calls, creates no .bat (T6)"
reset_state
out=$(run_sc arm --dry-run)
assert_contains "dry-run mentions the runner path" "codex-sweep.bat" "$out"
assert_contains "dry-run mentions schtasks /create" "/create /tn HIMMEL-CodexOrphanSweep" "$out"
# The dedup guard (Task 2) issues a read-only /query even under --dry-run —
# it must still surface an already-armed conflict in the preview — but
# --dry-run must never /create or /delete.
calls=$(cat "$STATE/calls.log" 2>/dev/null || echo "")
assert_not_contains "dry-run made no /create call" "/create " "$calls"
assert_not_contains "dry-run made no /delete call" "/delete " "$calls"
if [ ! -f "$BAT_DIR/codex-sweep.bat" ]; then
    pass "dry-run wrote no .bat file"
else
    fail "dry-run wrote a .bat file"
fi

# Test T7: hostile-but-legal BAT_DIR is cmd-escaped in the .bat --------------

echo "TEST: hostile %&^ in BAT_DIR arrives cmd-escaped in the .bat (T7)"
reset_state
EVIL_DIR="$TMP_ROOT/cr%on rnr&x^y"
out=$(env SWEEP_SCHTASKS="$FAKE_SCHTASKS" SWEEP_BAT_DIR="$EVIL_DIR" SWEEP_PWSH="$FAKE_PWSH" \
    HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm)
evil_bat=$(cat "$EVIL_DIR/codex-sweep.bat" 2>/dev/null || echo MISSING)
assert_contains "percent doubled (%% in bat)" '%%' "$evil_bat"
assert_contains "ampersand careted (^& in bat)" '^&' "$evil_bat"
assert_contains "caret doubled (^^ in bat)" '^^' "$evil_bat"
env SWEEP_SCHTASKS="$FAKE_SCHTASKS" SWEEP_BAT_DIR="$EVIL_DIR" SWEEP_PWSH="$FAKE_PWSH" \
    HOME="$HOME" "$REAL_BASH" "$SCRIPT" arm >/dev/null 2>&1 || true

# Test T7b: no pwsh/powershell resolvable -> rc 2 -----------------------------

echo "TEST: SWEEP_PWSH unset + no pwsh/powershell on PATH -> rc 2 (T7b)"
reset_state
CYGPATH_DIR="$(dirname "$(command -v cygpath)")"
rc=0
out=$(env SWEEP_SCHTASKS="$FAKE_SCHTASKS" SWEEP_BAT_DIR="$BAT_DIR" HOME="$HOME" \
    PATH="$TMP_ROOT/bin:$CYGPATH_DIR" "$REAL_BASH" "$SCRIPT" arm 2>&1) || rc=$?
assert_rc "no payload shell resolvable -> rc 2" 2 "$rc"
assert_contains "no payload shell message" "pwsh" "$out"
if [ ! -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ] && [ ! -f "$STATE/calls.log" ]; then
    pass "no task/schtasks call made when payload shell unresolvable"
else
    fail "schtasks touched despite unresolvable payload shell"
fi

# Test T8: status when not armed ----------------------------------------------

echo "TEST: status when not armed -> prints 'not armed', rc 0 (T8)"
reset_state
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status not armed -> rc 0" 0 "$rc"
assert_contains "status not armed -> 'not armed'" "not armed" "$out"
assert_contains "status not armed -> task name" "HIMMEL-CodexOrphanSweep" "$out"

# Test T9 / T9b / T9c: status when armed + log evidence + WARN delta ---------

echo "TEST: status when armed -> task name + Next Run Time + log evidence (T9)"
reset_state
run_sc arm >/dev/null
mkdir -p "$BAT_DIR"
printf '[fired 07/10/2026 09:00:00.00]\r\n[sweep exit rc=0]\r\n[reap exit rc=0]\r\n' > "$BAT_DIR/codex-sweep.log"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status armed -> rc 0" 0 "$rc"
assert_contains "status armed -> ARMED" "ARMED" "$out"
assert_contains "status armed -> task name" "HIMMEL-CodexOrphanSweep" "$out"
assert_contains "status armed -> Next Run Time evidence" "next run:" "$out"
assert_contains "status armed -> log path evidence" "codex-sweep.log" "$out"
assert_not_contains "status armed, both rc=0 -> no WARN" "WARN" "$out"

echo "TEST: status WARN when sweep exit rc is non-zero, reap rc=0 (T9b, deliberate delta)"
printf '[fired 07/10/2026 09:00:00.00]\r\n[sweep exit rc=1]\r\n[reap exit rc=0]\r\n' > "$BAT_DIR/codex-sweep.log"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_contains "status WARN present (sweep rc=1, reap rc=0 — a tail-1 port would miss this)" "WARN: last fire had non-zero payload rc" "$out"

echo "TEST: status WARN when both stamps are rc=0 -> no WARN (T9b)"
printf '[fired 07/10/2026 09:00:00.00]\r\n[sweep exit rc=0]\r\n[reap exit rc=0]\r\n' > "$BAT_DIR/codex-sweep.log"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_not_contains "status no WARN when both rc=0" "WARN: last fire had non-zero payload rc" "$out"

echo "TEST: status reports rotated log when .log absent but .log.prev present (T9c)"
mv -f "$BAT_DIR/codex-sweep.log" "$BAT_DIR/codex-sweep.log.prev"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status rotated-only -> rc 0" 0 "$rc"
assert_contains "status rotated-only -> mentions rotation" "rotated" "$out"
assert_contains "status rotated-only -> log path" "codex-sweep.log" "$out"

# Test T10 / T11: dedup guard on arm -------------------------------------------

echo "TEST: second arm without --force -> rc 3, no new /create recorded (T10)"
reset_state
run_sc arm >/dev/null
creates_before=$(grep -c '^/create ' "$STATE/calls.log" 2>/dev/null || true)
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "second arm without --force -> rc 3" 3 "$rc"
assert_contains "dedup message names the task" "HIMMEL-CodexOrphanSweep" "$out"
creates_after=$(grep -c '^/create ' "$STATE/calls.log" 2>/dev/null || true)
assert_rc "no new /create call recorded" "$creates_before" "$creates_after"

echo "TEST: arm --force replaces create-only, NO /delete (transactional --force, FIX B / codex-adv-2, T11)"
: > "$STATE/calls.log"
rc=0; out=$(run_sc arm --force 2>&1) || rc=$?
assert_rc "arm --force -> rc 0" 0 "$rc"
del_calls=$(grep -c '^/delete ' "$STATE/calls.log" 2>/dev/null || true)
cre_calls=$(grep -c '^/create ' "$STATE/calls.log" 2>/dev/null || true)
assert_rc "arm --force records NO /delete call" 0 "${del_calls:-0}"
assert_rc "arm --force records exactly one /create call" 1 "${cre_calls:-0}"
assert_contains "arm --force /create carries /f" "/create /tn HIMMEL-CodexOrphanSweep /xml" "$(cat "$STATE/calls.log")"
if grep -q '^/create .*[[:space:]]/f\($\|[[:space:]]\)' "$STATE/calls.log" 2>/dev/null; then
    pass "arm --force /create call carries /f (atomic in-place replace)"
else
    fail "arm --force /create call missing /f" "$(cat "$STATE/calls.log")"
fi

echo "TEST: dedup unchanged -- plain arm still rc 3 when already armed; arm --force proceeds create-only (T11b)"
reset_state
run_sc arm >/dev/null
: > "$STATE/calls.log"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "plain arm against an already-armed task -> rc 3 (dedup unchanged)" 3 "$rc"
calls_after_plain=$(cat "$STATE/calls.log" 2>/dev/null || echo "")
assert_not_contains "plain arm dedup block makes no /create call" "/create " "$calls_after_plain"
assert_not_contains "plain arm dedup block makes no /delete call" "/delete " "$calls_after_plain"
: > "$STATE/calls.log"
rc=0; out=$(run_sc arm --force 2>&1) || rc=$?
assert_rc "arm --force against an already-armed task -> rc 0 (proceeds)" 0 "$rc"
calls_after_force=$(cat "$STATE/calls.log" 2>/dev/null || echo "")
assert_not_contains "arm --force still makes no /delete call" "/delete " "$calls_after_force"
assert_contains "arm --force makes exactly the /create call" "/create /tn HIMMEL-CodexOrphanSweep /xml" "$calls_after_force"

# Test T12: disarm removes task + idempotency ----------------------------------

echo "TEST: disarm removes task; disarm again -> rc 0 idempotent (T12)"
reset_state
run_sc arm >/dev/null
rc=0; out=$(run_sc disarm 2>&1) || rc=$?
assert_rc "disarm -> rc 0" 0 "$rc"
assert_contains "disarm reports removal" "disarmed" "$out"
if [ ! -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ]; then
    pass "disarm deleted the task"
else
    fail "disarm left the task behind"
fi
rc=0; out=$(run_sc disarm 2>&1) || rc=$?
assert_rc "second disarm -> rc 0 idempotent" 0 "$rc"
assert_contains "second disarm -> no-op message" "nothing armed" "$out"

# Test T12b: disarm --dry-run while armed touches nothing --------------------

echo "TEST: disarm --dry-run while armed -> rc 0, no /delete, .bat still present (T12b)"
reset_state
run_sc arm >/dev/null
rc=0; out=$(run_sc disarm --dry-run 2>&1) || rc=$?
assert_rc "disarm --dry-run while armed -> rc 0" 0 "$rc"
assert_contains "disarm --dry-run mentions dry-run/no changes" "DRY" "$out"
calls=$(cat "$STATE/calls.log" 2>/dev/null || echo "")
assert_not_contains "disarm --dry-run made no /delete call" "/delete " "$calls"
if [ -f "$BAT_DIR/codex-sweep.bat" ]; then
    pass "disarm --dry-run left the .bat in place"
else
    fail "disarm --dry-run removed the .bat"
fi
if [ -f "$STATE/tasks/HIMMEL-CodexOrphanSweep" ]; then
    pass "disarm --dry-run left the task armed"
else
    fail "disarm --dry-run removed the task"
fi

# Test T13: not-found stderr classification fails CLOSED on unrelated error --

echo "TEST: unrelated schtasks query error does NOT classify as not-armed (T13, fail closed)"
reset_state
touch "$STATE/fail-query"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status with unrelated query error -> rc 2 (fail closed)" 2 "$rc"
# NOTE: the fail-closed diagnostic itself legitimately says "refusing to treat
# as 'not armed'" — check for the actual status-line misclassification
# ("not armed  HIMMEL-CodexOrphanSweep"), not a blind substring match.
assert_not_contains "unrelated query error is not misreported as 'not armed'" "not armed  HIMMEL-CodexOrphanSweep" "$out"
rc=0; out=$(run_sc disarm 2>&1) || rc=$?
assert_rc "disarm with unrelated query error -> rc 2 (fail closed)" 2 "$rc"
rm -f "$STATE/fail-query"

# Test FIX 2: locale-independent task-existence classification (codex-7) -----

echo "TEST: locale-independent classification -- localized not-found stderr + probe ObjectNotFound -> treated as not-armed (FIX 2a)"
reset_state
touch "$STATE/localized-not-found"
touch "$STATE/query-probe-object-not-found"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status, localized stderr + probe ObjectNotFound -> rc 0 (not armed)" 0 "$rc"
assert_contains "status, localized stderr + probe ObjectNotFound -> 'not armed'" "not armed" "$out"
rc=0; out=$(run_sc arm 2>&1) || rc=$?
assert_rc "arm, localized stderr + probe ObjectNotFound -> dedup treats as unarmed, proceeds, rc 0" 0 "$rc"
rm -f "$STATE/localized-not-found" "$STATE/query-probe-object-not-found"

echo "TEST: locale-independent classification -- localized not-found stderr + probe EXISTS -> rc 2 fail closed (FIX 2b)"
reset_state
touch "$STATE/localized-not-found"
touch "$STATE/query-probe-exists"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status, localized stderr + probe EXISTS -> rc 2 (fail closed)" 2 "$rc"
assert_contains "status, localized stderr + probe EXISTS message names the probe confirmation" "Get-ScheduledTask probe confirms the task EXISTS" "$out"
rm -f "$STATE/localized-not-found" "$STATE/query-probe-exists"

echo "TEST: locale-independent classification -- localized not-found stderr + probe CommandNotFound -> rc 2 fail closed, unchanged (FIX 2c)"
reset_state
touch "$STATE/localized-not-found"
touch "$STATE/query-probe-command-not-found"
rc=0; out=$(run_sc status 2>&1) || rc=$?
assert_rc "status, localized stderr + probe CommandNotFound -> rc 2 (fail closed, unchanged)" 2 "$rc"
assert_not_contains "status, localized stderr + probe CommandNotFound is not misreported as not armed" "not armed  HIMMEL-CodexOrphanSweep" "$out"
rm -f "$STATE/localized-not-found" "$STATE/query-probe-command-not-found"

summary
