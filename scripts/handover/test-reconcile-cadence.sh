#!/usr/bin/env bash
# test-reconcile-cadence.sh -- HIMMEL-1880 regression suite for the periodic
# seat-liveness runner: reconcile-workers.sh --report classifies every running
# seat as DIED / NEVER-STARTED / STILL-RUNNING, and reconcile-cadence.sh arms
# it on cron idempotently.
#
# PID liveness is stubbed except in R2b, which probes a REAL live non-claude
# process (a recycled pid) through the production kill -0 path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE="$SCRIPT_DIR/reconcile-workers.sh"
CADENCE="$SCRIPT_DIR/reconcile-cadence.sh"
CADENCE_PS1="$SCRIPT_DIR/reconcile-cadence.ps1"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" -eq "$expected" ]; then pass "$label"; else fail "$label (expected rc=$expected, got $actual)"; fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) pass "$label" ;; *) fail "$label (missing: $needle)" ;; esac
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) fail "$label (unexpected: $needle)" ;; *) pass "$label" ;; esac
}
assert_file_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then pass "$label"; else fail "$label ($file missing: $needle)"; fi
}

TMP="$(mktemp -d -t reconcile-cadence.XXXXXX)" || { echo "FAIL: mktemp"; exit 1; }
SLEEPER_PID=""
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below.
cleanup() {
    [ -n "$SLEEPER_PID" ] && kill "$SLEEPER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

export WORKER_BRIDGE_ROOT="$TMP/bridge"
SESS="$WORKER_BRIDGE_ROOT/claudex-sessions"
mkdir -p "$WORKER_BRIDGE_ROOT/glm-sessions" "$SESS"

PID_STUB="$TMP/pid-alive"
cat > "$PID_STUB" <<'EOF'
#!/usr/bin/env bash
case ",${LIVE_PIDS:-}," in
    *",$1,"*) exit 0 ;;
esac
case ",${UNPROBEABLE_PIDS:-}," in
    *",$1,"*) exit 2 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$PID_STUB"
export WORKER_PID_ALIVE_CMD="$PID_STUB"

# _set_mtime_seconds_ago <path> <secs>
_set_mtime_seconds_ago() {
    node -e '
const fs = require("fs");
const t = (Date.now() - Number(process.argv[2]) * 1000) / 1000;
fs.utimesSync(process.argv[1], t, t);
' "$1" "$2"
}

# seat <name> <json> [age-secs] -- write one claudex meta row; age defaults to
# well past the 120s grace so a confirmed-dead probe is reapable.
seat() {
    local name="$1" json="$2" age="${3:-600}"
    mkdir -p "$SESS/$name"
    printf '%s\n' "$json" > "$SESS/$name/meta.json"
    _set_mtime_seconds_ago "$SESS/$name/meta.json" "$age"
}
clear_seats() { rm -rf "${SESS:?}"/*; }

# --- R1: a killed seat (confirmed-dead pid past grace) is DIED and reaped.
clear_seats
seat r1 '{"status":"running","pid":4101,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r1-killed"}'
out=$(bash "$RECONCILE" --report 2>/dev/null)
rc=$?
assert_rc "R1 --report exits 0" 0 "$rc"
assert_contains "R1 killed seat is DIED" "SEAT DIED codex/r1-killed pid=4101" "$out"
assert_file_contains "R1 killed seat is marked orphaned" '"status": "orphaned"' "$SESS/r1/meta.json"

# --- R2: a seat whose pid is alive is STILL-RUNNING and never reaped.
clear_seats
seat r2 '{"status":"running","pid":4102,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r2-alive"}'
out=$(LIVE_PIDS=4102 bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R2 live seat is STILL-RUNNING" "SEAT STILL-RUNNING codex/r2-alive pid=4102" "$out"
assert_not_contains "R2 live seat is not reported DIED" "SEAT DIED" "$out"
assert_file_contains "R2 live seat stays running" '"status":"running"' "$SESS/r2/meta.json"

# --- R2b: the pid was recycled to a live NON-claude process. The production
# probe (kill -0, no stub) sees it alive and the seat is never reaped -- the
# same err-toward-live behaviour reconcile mode has always had.
clear_seats
sleep 300 &
SLEEPER_PID=$!
seat r2b "{\"status\":\"running\",\"pid\":$SLEEPER_PID,\"started_at\":\"2026-10-01T00:00:00Z\",\"lane\":\"codex\",\"task_name\":\"r2b-recycled\"}"
out=$(env -u WORKER_PID_ALIVE_CMD bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R2b recycled live pid is STILL-RUNNING" "SEAT STILL-RUNNING codex/r2b-recycled pid=$SLEEPER_PID" "$out"
assert_file_contains "R2b recycled live pid stays running" '"status":"running"' "$SESS/r2b/meta.json"
kill "$SLEEPER_PID" 2>/dev/null
wait "$SLEEPER_PID" 2>/dev/null
SLEEPER_PID=""

# --- R3: no pid and no start record is NEVER-STARTED, and is not reaped
# inside the unprobeable ceiling.
clear_seats
seat r3 '{"status":"running","lane":"codex","task_name":"r3-never"}'
out=$(bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R3 no pid + no start record is NEVER-STARTED" "SEAT NEVER-STARTED codex/r3-never pid=absent" "$out"
assert_file_contains "R3 never-started seat is not reaped before the ceiling" '"status":"running"' "$SESS/r3/meta.json"

# --- R3b: the same seat past the 48h ceiling is reaped and still reported
# NEVER-STARTED (it never recorded a start, so DIED would overclaim).
future_ms=$(node -e 'process.stdout.write(String(Date.now() + 49 * 3600 * 1000))')
out=$(RECONCILE_TEST_NOW_MS="$future_ms" bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R3b never-started seat past ceiling stays NEVER-STARTED" "SEAT NEVER-STARTED codex/r3-never pid=absent" "$out"
assert_file_contains "R3b never-started seat past ceiling is reaped" '"status": "orphaned"' "$SESS/r3/meta.json"

# --- R4: pid never written but a start record exists (spawn wrote pid:0 then
# lost the live write) is unprobeable: STILL-RUNNING, not reaped.
clear_seats
seat r4 '{"status":"running","pid":0,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r4-started"}'
out=$(bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R4 started seat without pid is STILL-RUNNING" "SEAT STILL-RUNNING codex/r4-started pid=0 detail=unprobeable" "$out"
assert_file_contains "R4 started seat without pid is not reaped" '"status":"running"' "$SESS/r4/meta.json"

# --- R5: a confirmed-dead pid inside the grace window is still settling:
# STILL-RUNNING, never reaped.
clear_seats
seat r5 '{"status":"running","pid":4105,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r5-settling"}' 5
out=$(bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R5 settling seat is STILL-RUNNING" "SEAT STILL-RUNNING codex/r5-settling pid=4105 detail=settling" "$out"
assert_file_contains "R5 settling seat is not reaped" '"status":"running"' "$SESS/r5/meta.json"

# --- R6: a real pid whose probe FAILED is never reaped, even past the
# ceiling (the ceiling only covers never-written pids).
clear_seats
seat r6 '{"status":"running","pid":4106,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r6-unprobeable"}'
out=$(UNPROBEABLE_PIDS=4106 RECONCILE_TEST_NOW_MS="$future_ms" bash "$RECONCILE" --report 2>/dev/null)
assert_contains "R6 unprobeable real pid is STILL-RUNNING" "SEAT STILL-RUNNING codex/r6-unprobeable pid=4106 detail=unprobeable" "$out"
assert_file_contains "R6 unprobeable real pid is not reaped" '"status":"running"' "$SESS/r6/meta.json"

# --- R7: terminal rows are not tracked seats; the summary counts the rest.
clear_seats
seat r7a '{"status":"completed","pid":4107,"lane":"codex","task_name":"r7-done"}'
seat r7b '{"status":"running","pid":4108,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r7-alive"}'
out=$(LIVE_PIDS=4108 bash "$RECONCILE" --report 2>/dev/null)
assert_not_contains "R7 terminal row gets no SEAT line" "r7-done" "$out"
assert_contains "R7 summary counts seats" "reconcile-report: died=0 never-started=0 still-running=1" "$out"

# --- R8: plain reconcile mode output is unchanged (no SEAT lines).
clear_seats
seat r8 '{"status":"running","pid":4109,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"r8-dead"}'
out=$(bash "$RECONCILE" 2>/dev/null)
assert_contains "R8 reconcile mode still orphans" "reconcile-workers: orphaned codex/r8-dead pid=4109" "$out"
assert_not_contains "R8 reconcile mode prints no SEAT lines" "SEAT " "$out"

# --- Cadence: cron arm/disarm through a crontab stub.
CRON_FILE="$TMP/crontab"
CRON_STUB="$TMP/crontab-stub"
cat > "$CRON_STUB" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -l) if [ -f "$CRON_FILE" ]; then cat "$CRON_FILE"; else echo "no crontab for test" >&2; exit 1; fi ;;
    -) cat > "$CRON_FILE" ;;
    *) exit 9 ;;
esac
EOF
chmod +x "$CRON_STUB"
export RECONCILE_CADENCE_CRONTAB="$CRON_STUB"
printf '%s\n' '0 3 * * * /usr/bin/true # unrelated-job' > "$CRON_FILE"

out=$(bash "$CADENCE" arm 2>&1)
rc=$?
assert_rc "C1 arm exits 0" 0 "$rc"
out=$(bash "$CADENCE" arm 2>&1)
rc=$?
assert_rc "C1 second arm exits 0" 0 "$rc"
n=$(grep -c 'HIMMEL-ReconcileCadence' "$CRON_FILE")
assert_rc "C1 arming twice yields exactly one job" 1 "$n"
assert_file_contains "C1 job runs every 10 minutes by default" '*/10 * * * *' "$CRON_FILE"
assert_file_contains "C1 job invokes the runner" 'reconcile-cadence.sh run' "$CRON_FILE"
assert_file_contains "C2 unrelated crontab entry preserved" '# unrelated-job' "$CRON_FILE"

out=$(bash "$CADENCE" arm --interval-min 5 2>&1)
n=$(grep -c 'HIMMEL-ReconcileCadence' "$CRON_FILE")
assert_rc "C3 re-arm with a new interval still yields one job" 1 "$n"
assert_file_contains "C3 re-arm applies the new interval" '*/5 * * * *' "$CRON_FILE"

out=$(bash "$CADENCE" status 2>&1)
assert_contains "C4 status reports armed" "armed" "$out"

out=$(bash "$CADENCE" arm --interval-min 1 2>&1)
rc=$?
assert_rc "C5 interval below the reap grace is refused" 2 "$rc"

# --- C9: */N is only uniform when N divides 60 (*/59 fires :59 then :00).
out=$(bash "$CADENCE" arm --interval-min 7 2>&1)
rc=$?
assert_rc "C9 interval that does not divide 60 is refused" 2 "$rc"
out=$(bash "$CADENCE" arm --interval-min 59 2>&1)
rc=$?
assert_rc "C9 interval 59 is refused" 2 "$rc"

# --- C10: a leading-zero interval is decimal, not octal.
out=$(bash "$CADENCE" arm --interval-min 010 2>&1)
rc=$?
assert_rc "C10 leading-zero interval accepted" 0 "$rc"
assert_file_contains "C10 leading-zero interval normalised to decimal" '*/10 * * * *' "$CRON_FILE"

# --- C11: the overrides arm validated are baked into the job.
out=$(RECONCILE_GRACE_SECS=180 bash "$CADENCE" arm 2>&1)
assert_file_contains "C11 job carries the armed grace" 'RECONCILE_GRACE_SECS=180' "$CRON_FILE"
assert_file_contains "C11 job carries the armed bridge root" 'WORKER_BRIDGE_ROOT=' "$CRON_FILE"

# --- C13: a zero tick timeout would disable the bound entirely.
out=$(RECONCILE_CADENCE_TIMEOUT_SECS=0 bash "$CADENCE" arm 2>&1)
rc=$?
assert_rc "C13 zero tick timeout is refused" 2 "$rc"

# --- C12: arming without a timeout binary is refused (ticks would be unbounded).
NOTIMEOUT="$TMP/no-timeout-bin"
mkdir -p "$NOTIMEOUT"
for t in bash dirname mktemp grep cat rm; do ln -s "$(command -v "$t")" "$NOTIMEOUT/$t"; done
out=$(PATH="$NOTIMEOUT" "$(command -v bash)" "$CADENCE" arm 2>&1)
rc=$?
assert_rc "C12 arm without timeout is refused" 2 "$rc"
assert_contains "C12 refusal names timeout" "timeout" "$out"

out=$(bash "$CADENCE" disarm 2>&1)
rc=$?
assert_rc "C6 disarm exits 0" 0 "$rc"
n=$(grep -c 'HIMMEL-ReconcileCadence' "$CRON_FILE")
assert_rc "C6 disarm removes the job" 0 "$n"
assert_file_contains "C6 disarm preserves unrelated entries" '# unrelated-job' "$CRON_FILE"
out=$(bash "$CADENCE" status 2>&1)
assert_contains "C6 status reports not armed" "not armed" "$out"

# --- C7: one runner tick reports a killed seat DIED into the log.
clear_seats
seat c7 '{"status":"running","pid":4110,"started_at":"2026-10-01T00:00:00Z","lane":"codex","task_name":"c7-killed"}'
export RECONCILE_CADENCE_LOG="$TMP/cadence.log"
bash "$CADENCE" run >/dev/null 2>&1
rc=$?
assert_rc "C7 runner tick exits 0" 0 "$rc"
assert_file_contains "C7 runner tick logs the DIED seat" "SEAT DIED codex/c7-killed pid=4110" "$RECONCILE_CADENCE_LOG"
assert_file_contains "C7 runner tick stamps the fire time" "[fired " "$RECONCILE_CADENCE_LOG"

# --- C8: the Windows twin parses (only where pwsh exists).
if command -v pwsh >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # PowerShell source, not shell expansion.
    out=$(pwsh -NoProfile -Command '$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($args[0],[ref]$null,[ref]$e); if ($e.Count) { $e | ForEach-Object { $_.Message }; exit 1 }' "$CADENCE_PS1" 2>&1)
    rc=$?
    assert_rc "C8 reconcile-cadence.ps1 parses ($out)" 0 "$rc"
else
    if [ -f "$CADENCE_PS1" ]; then pass "C8 reconcile-cadence.ps1 present (pwsh absent; parse skipped)"; else fail "C8 reconcile-cadence.ps1 missing"; fi
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
if [ "$FAILED" -eq 0 ]; then
    echo "SUITE-EXIT=0"
    exit 0
fi
echo "SUITE-EXIT=1"
exit 1
