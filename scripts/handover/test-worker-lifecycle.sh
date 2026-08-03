#!/usr/bin/env bash
# test-worker-lifecycle.sh -- HIMMEL-1463 regression suite for the pre-arm
# live-worker guard, stale-running reconciliation, and shared-lock cleanup.
#
# PID liveness is fully stubbed. No assertion depends on a real process or on
# the host's MSYS/native pid namespace.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
RECONCILE="$SCRIPT_DIR/reconcile-workers.sh"
LOCK="$SCRIPT_DIR/../lib/shared-branch-lock.sh"

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
assert_file_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then pass "$label"; else fail "$label ($file missing: $needle)"; fi
}

TMP="$(mktemp -d -t worker-lifecycle.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

export WORKER_BRIDGE_ROOT="$TMP/bridge"
mkdir -p "$WORKER_BRIDGE_ROOT/glm-sessions" "$WORKER_BRIDGE_ROOT/claudex-sessions"

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

WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"
HANDOVER_DIR="$TMP/state/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/state"
HANDOVER="$HANDOVER_DIR/himmel-1463.md"
cat > "$HANDOVER" <<EOF
---
resume_cwd: $WORK_REPO
---
# HIMMEL-1463 test handover
EOF

export HANDOVER_DIR
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export ARM_BRIDGE_LIVE=0
export ARM_MAX_SLOTS=0

SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
for cmd in schtasks atq powershell; do
    cat > "$SCHED_STUB/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$SCHED_STUB/$cmd"
done
cat > "$SCHED_STUB/at" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
cat > "$SCHED_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCHED_STUB/at" "$SCHED_STUB/claude"

NEAR_HHMM=$(node -e 'const d = new Date(Date.now() + 5 * 60 * 1000); process.stdout.write(String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"))')

# T1: a running row with a stub-live pid blocks and is listed.
LIVE_DIR="$WORKER_BRIDGE_ROOT/glm-sessions/glm-live"
mkdir -p "$LIVE_DIR"
cat > "$LIVE_DIR/meta.json" <<'EOF'
{
  "status": "running",
  "pid": 111,
  "started_at": "2026-08-03T00:00:00Z",
  "lane": "glm",
  "task_name": "live-guard"
}
EOF
out=$(PATH="$SCHED_STUB:$PATH" LIVE_PIDS=111 bash "$ARM" --time "$NEAR_HHMM" --handover "$HANDOVER" 2>&1)
rc=$?
assert_rc "T1 live worker blocks arm" 10 "$rc"
assert_contains "T1 refusal lists task" "task=live-guard pid=111" "$out"
assert_contains "T1 refusal names override" "ARM_WITH_LIVE_WORKERS=1" "$out"
assert_file_contains "T1 live metadata remains running" '"status": "running"' "$LIVE_DIR/meta.json"
rm -rf "$LIVE_DIR"

# T2: a dead running row is reconciled before the guard, then the arm proceeds.
DEAD_DIR="$WORKER_BRIDGE_ROOT/claudex-sessions/claudex-dead"
mkdir -p "$DEAD_DIR"
cat > "$DEAD_DIR/meta.json" <<'EOF'
{
  "status": "running",
  "pid": 222,
  "started_at": "2026-08-03T00:00:00Z",
  "lane": "codex",
  "task_name": "dead-row",
  "preserve_me": "yes"
}
EOF
out=$(TMPDIR="$TMP" PATH="$SCHED_STUB:$PATH" LIVE_PIDS='' RECONCILE_GRACE_SECS=0 bash "$ARM" --time "$NEAR_HHMM" --handover "$HANDOVER" 2>&1)
rc=$?
assert_rc "T2 dead row is reconciled and arm proceeds" 0 "$rc"
assert_contains "T2 reconciliation is reported" "reconcile-workers: orphaned codex/dead-row pid=222" "$out"
assert_contains "T2 scheduler was still armed" "RESUME ARMED" "$out"
assert_file_contains "T2 metadata marked orphaned" '"status": "orphaned"' "$DEAD_DIR/meta.json"
assert_file_contains "T2 unrelated metadata preserved" '"preserve_me": "yes"' "$DEAD_DIR/meta.json"
rm -rf "$DEAD_DIR"

# T3: shared locks are released only when their own holder pid is dead.
LOCK_REPO="$TMP/lock-repo"
mkdir -p "$LOCK_REPO"
git init -q "$LOCK_REPO"
git -C "$LOCK_REPO" config user.email test@example.com
git -C "$LOCK_REPO" config user.name "Test User"
: > "$LOCK_REPO/README.md"
git -C "$LOCK_REPO" add README.md
git -C "$LOCK_REPO" commit -q -m init

KEEP_DIR="$WORKER_BRIDGE_ROOT/glm-sessions/glm-keep-lock"
DROP_DIR="$WORKER_BRIDGE_ROOT/claudex-sessions/claudex-drop-lock"
mkdir -p "$KEEP_DIR" "$DROP_DIR"
cat > "$KEEP_DIR/meta.json" <<EOF
{"status":"running","pid":333,"lane":"glm","task_name":"keep-lock","shared_branch":"feat/keep-lock","repo_dir":"$LOCK_REPO"}
EOF
cat > "$DROP_DIR/meta.json" <<EOF
{"status":"running","pid":555,"lane":"codex","task_name":"drop-lock","shared_branch":"feat/drop-lock","repo_dir":"$LOCK_REPO"}
EOF
SHARED_BRANCH_LOCK_HOLDER_PID=444 bash "$LOCK" acquire "$LOCK_REPO" "feat/keep-lock" glm >/dev/null 2>&1
SHARED_BRANCH_LOCK_HOLDER_PID=666 bash "$LOCK" acquire "$LOCK_REPO" "feat/drop-lock" codex >/dev/null 2>&1
KEEP_LOCK=$(git -C "$LOCK_REPO" rev-parse --path-format=absolute --git-common-dir)/himmel-shared-branch/feat-keep-lock.lock
DROP_LOCK=$(git -C "$LOCK_REPO" rev-parse --path-format=absolute --git-common-dir)/himmel-shared-branch/feat-drop-lock.lock
out=$(LIVE_PIDS=444 RECONCILE_GRACE_SECS=0 bash "$RECONCILE" 2>&1)
rc=$?
assert_rc "T3 reconciliation succeeds" 0 "$rc"
if [ -d "$KEEP_LOCK" ]; then pass "T3 live holder lock retained"; else fail "T3 live holder lock was removed"; fi
if [ ! -d "$DROP_LOCK" ]; then pass "T3 dead holder lock released"; else fail "T3 dead holder lock remains"; fi
assert_contains "T3 dead-holder release reported" "released shared lock feat/drop-lock" "$out"
assert_file_contains "T3 live-holder worker still orphaned" '"status": "orphaned"' "$KEEP_DIR/meta.json"
assert_file_contains "T3 dead-holder worker orphaned" '"status": "orphaned"' "$DROP_DIR/meta.json"
bash "$LOCK" release "$LOCK_REPO" "feat/keep-lock" >/dev/null 2>&1
rm -rf "$KEEP_DIR" "$DROP_DIR"

# T3b: a confirmed-dead worker with fresh metadata is still settling. Its row
# and shared lock stay untouched until the terminal writer's grace expires.
SETTLING_DIR="$WORKER_BRIDGE_ROOT/claudex-sessions/claudex-settling"
mkdir -p "$SETTLING_DIR"
cat > "$SETTLING_DIR/meta.json" <<EOF
{"status":"running","pid":999,"lane":"codex","task_name":"fresh-row","shared_branch":"feat/settling","repo_dir":"$LOCK_REPO"}
EOF
SHARED_BRANCH_LOCK_HOLDER_PID=999 bash "$LOCK" acquire "$LOCK_REPO" "feat/settling" codex >/dev/null 2>&1
SETTLING_LOCK=$(git -C "$LOCK_REPO" rev-parse --path-format=absolute --git-common-dir)/himmel-shared-branch/feat-settling.lock
out=$(LIVE_PIDS='' bash "$RECONCILE" 2>&1)
rc=$?
assert_rc "T3b fresh dead-pid reconciliation succeeds safely" 0 "$rc"
assert_contains "T3b settling row is reported" "settling codex/fresh-row pid=999" "$out"
assert_file_contains "T3b settling metadata remains running" '"status":"running"' "$SETTLING_DIR/meta.json"
if [ -d "$SETTLING_LOCK" ]; then pass "T3b settling lock retained"; else fail "T3b settling lock was removed"; fi
out=$(LIVE_PIDS='' bash "$RECONCILE" --list-live 2>&1)
assert_contains "T3b settling row remains guard-visible" "task=fresh-row pid=999 state=settling" "$out"
bash "$LOCK" release "$LOCK_REPO" "feat/settling" >/dev/null 2>&1
rm -rf "$SETTLING_DIR"

# T4: a failed worker census leaves the row and lock untouched, warns, and
# remains guard-visible as unprobeable/possibly alive.
UNPROBEABLE_DIR="$WORKER_BRIDGE_ROOT/claudex-sessions/claudex-unprobeable"
mkdir -p "$UNPROBEABLE_DIR"
cat > "$UNPROBEABLE_DIR/meta.json" <<EOF
{"status":"running","pid":888,"lane":"codex","task_name":"census-failed","shared_branch":"feat/unprobeable","repo_dir":"$LOCK_REPO"}
EOF
SHARED_BRANCH_LOCK_HOLDER_PID=888 bash "$LOCK" acquire "$LOCK_REPO" "feat/unprobeable" codex >/dev/null 2>&1
UNPROBEABLE_LOCK=$(git -C "$LOCK_REPO" rev-parse --path-format=absolute --git-common-dir)/himmel-shared-branch/feat-unprobeable.lock
out=$(TMPDIR="$TMP" PATH="$SCHED_STUB:$PATH" LIVE_PIDS='' UNPROBEABLE_PIDS=888 bash "$ARM" --time "$NEAR_HHMM" --handover "$HANDOVER" 2>&1)
rc=$?
assert_rc "T4 unprobeable worker blocks arm" 10 "$rc"
assert_contains "T4 census failure warns" "WARN reconcile-workers: unprobeable codex/census-failed pid=888" "$out"
assert_contains "T4 census summary marks unprobeable" "task=census-failed pid=888 state=unprobeable" "$out"
assert_contains "T4 guard says possibly alive" "live or unprobeable (possibly alive)" "$out"
assert_file_contains "T4 unprobeable metadata remains running" '"status":"running"' "$UNPROBEABLE_DIR/meta.json"
if [ -d "$UNPROBEABLE_LOCK" ]; then pass "T4 unprobeable lock retained"; else fail "T4 unprobeable lock was removed"; fi
bash "$LOCK" release "$LOCK_REPO" "feat/unprobeable" >/dev/null 2>&1
rm -rf "$UNPROBEABLE_DIR"

# T5: a live-meta write fallback with no pid is also unprobeable, never dead.
MARKER_DIR="$WORKER_BRIDGE_ROOT/claudex-sessions/claudex-marker"
mkdir -p "$MARKER_DIR"
cat > "$MARKER_DIR/meta.json" <<'EOF'
{"status":"running","pid_probe":"unprobeable","lane":"codex","task_name":"meta-write-failed"}
EOF
out=$(LIVE_PIDS='' UNPROBEABLE_PIDS='' bash "$RECONCILE" 2>&1)
rc=$?
assert_rc "T5 missing-pid reconciliation succeeds safely" 0 "$rc"
assert_contains "T5 missing-pid row warns unprobeable" "unprobeable codex/meta-write-failed pid=absent" "$out"
assert_file_contains "T5 missing-pid metadata remains running" '"status":"running"' "$MARKER_DIR/meta.json"
out=$(LIVE_PIDS='' UNPROBEABLE_PIDS='' bash "$RECONCILE" --list-live 2>&1)
assert_contains "T5 missing-pid row remains guard-visible" "task=meta-write-failed pid=absent state=unprobeable" "$out"
rm -rf "$MARKER_DIR"

# T6: the explicit bypass warns loudly, lists workers, and still arms.
BYPASS_DIR="$WORKER_BRIDGE_ROOT/claudex-sessions/claudex-bypass"
mkdir -p "$BYPASS_DIR"
cat > "$BYPASS_DIR/meta.json" <<'EOF'
{"status":"running","pid":777,"lane":"codex","task_name":"bypass-live"}
EOF
out=$(TMPDIR="$TMP" PATH="$SCHED_STUB:$PATH" LIVE_PIDS=777 ARM_WITH_LIVE_WORKERS=1 bash "$ARM" --time "$NEAR_HHMM" --handover "$HANDOVER" --force 2>&1)
rc=$?
assert_rc "T6 explicit bypass still arms" 0 "$rc"
assert_contains "T6 bypass warning is loud" "WARN arm-resume: ARM_WITH_LIVE_WORKERS=1" "$out"
assert_contains "T6 bypass warning lists worker" "task=bypass-live pid=777" "$out"
assert_contains "T6 bypass reaches scheduler success" "RESUME ARMED" "$out"
assert_file_contains "T6 live bypass metadata remains running" '"status":"running"' "$BYPASS_DIR/meta.json"

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
if [ "$FAILED" -eq 0 ]; then
    echo "SUITE-EXIT=0"
    exit 0
fi
echo "SUITE-EXIT=1"
exit 1
