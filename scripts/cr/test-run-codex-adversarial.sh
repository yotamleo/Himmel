#!/usr/bin/env bash
# Execution tests for run-codex-adversarial.sh process cleanup and leases (HIMMEL-1474 r6).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-codex-adversarial.sh"
PR_CHECK="$HERE/../../.claude/commands/pr-check.md"
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$HERE/../lib/proc-tree.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-run-codex-adversarial.XXXXXX")"
fails=0
unrelated_pid=''

cleanup() {
    if [ -n "$unrelated_pid" ]; then
        kill -9 "$unrelated_pid" 2>/dev/null || true
        wait "$unrelated_pid" 2>/dev/null || true
    fi
    if [ -s "$tmp/child.pid" ]; then
        child_pid=$(cat "$tmp/child.pid")
        kill -9 "$child_pid" 2>/dev/null || true
        if command -v taskkill >/dev/null 2>&1; then
            MSYS_NO_PATHCONV=1 taskkill /PID "$child_pid" /T /F >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

cat > "$tmp/stubborn-child.mjs" <<'JS'
import fs from 'node:fs';
const heartbeat = process.argv[2];
process.on('SIGTERM', () => {});
setInterval(() => fs.appendFileSync(heartbeat, 'x'), 100);
JS

cat > "$tmp/companion.mjs" <<'JS'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const childScript = process.env.HIMMEL_R2_CHILD_SCRIPT;
const childPidFile = process.env.HIMMEL_R2_CHILD_PID_FILE;
const heartbeat = process.env.HIMMEL_R2_HEARTBEAT;
const child = spawn(process.execPath, [childScript, heartbeat], { stdio: 'ignore' });
fs.writeFileSync(childPidFile, String(child.pid));
process.on('SIGTERM', () => {});
setInterval(() => {}, 1000);
JS

cat > "$tmp/companion-exits.mjs" <<'JS'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
const childScript = process.env.HIMMEL_R2_CHILD_SCRIPT;
const childPidFile = process.env.HIMMEL_R2_CHILD_PID_FILE;
const heartbeat = process.env.HIMMEL_R2_HEARTBEAT;
const child = spawn(process.execPath, [childScript, heartbeat], { stdio: 'ignore' });
fs.writeFileSync(childPidFile, String(child.pid));
child.unref();
await new Promise(resolve => setTimeout(resolve, 2500));
JS

# HIMMEL-1474 r5: exercise the lease launch against a copied runner and a
# proc-tree stub so both host branches are deterministic on every platform.
mkdir -p "$tmp/lease-fixture/cr" "$tmp/lease-fixture/lib" "$tmp/lease-fixture/stub-bin"
cp "$RUNNER" "$tmp/lease-fixture/cr/run-codex-adversarial.sh"
# HIMMEL-1509: the runner sources the real render-lease lib; lease behavior
# stays inert unless a test opts in via RENDER_LEASE_BRANCH.
cp "$HERE/../lib/render-lease.sh" "$tmp/lease-fixture/lib/render-lease.sh"
: > "$tmp/lease-fixture/cr/codex-render-client-lease.ps1"
cat > "$tmp/lease-fixture/lib/proc-tree.sh" <<'SH'
proc_tree_is_windows() {
    [ "${HIMMEL_R5_WINDOWS:-0}" = "1" ]
}
proc_tree_winpid() {
    printf '%s\n' "${HIMMEL_R5_WINPID:-}"
}
proc_tree_process_identity() {
    if [ "${HIMMEL_R11_IDENTITY_UNAVAILABLE:-0}" = "1" ]; then
        [ -z "${HIMMEL_R12_IDENTITY_PROBE_CALLED:-}" ] || printf x >> "$HIMMEL_R12_IDENTITY_PROBE_CALLED"
        return 1
    fi
    printf '%s\n' test-identity
}
proc_tree_process_identity_matches() {
    return "${HIMMEL_R6_IDENTITY_RC:-0}"
}
proc_tree_group_members() {
    [ -z "${HIMMEL_R14_GROUP_MEMBERS:-}" ] || printf '%s\n' "$HIMMEL_R14_GROUP_MEMBERS"
    return "${HIMMEL_R14_GROUP_MEMBERS_RC:-0}"
}
proc_tree_terminate() {
    return "${HIMMEL_R6_TERMINATE_RC:-0}"
}
proc_tree_group_terminate() {
    [ -z "${HIMMEL_R6_GROUP_TERMINATE_CALLED:-}" ] || : > "$HIMMEL_R6_GROUP_TERMINATE_CALLED"
    if [ "${HIMMEL_R11_TERMINATE_REAL_GROUP:-0}" = "1" ]; then
        kill -TERM -"$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null || true
    fi
    return "${HIMMEL_R6_GROUP_TERMINATE_RC:-0}"
}
SH
cat > "$tmp/lease-fixture/stub-bin/pwsh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${HIMMEL_R5_PWSH_ARGS:?}"
SH
chmod +x "$tmp/lease-fixture/stub-bin/pwsh"
cat > "$tmp/lease-fixture/companion.mjs" <<'JS'
await new Promise(resolve => setTimeout(resolve, 100));
JS
cat > "$tmp/lease-fixture/companion-lease.mjs" <<'JS'
await new Promise(resolve => setTimeout(resolve, 3000));
JS
cat > "$tmp/lease-fixture/companion-delayed.mjs" <<'JS'
await new Promise(resolve => setTimeout(resolve, 12000));
JS
cat > "$tmp/lease-fixture/companion-fails.mjs" <<'JS'
process.exit(7);
JS

rm -f "$tmp/lease-windows.args" "$tmp/lease-windows.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
HIMMEL_R5_WINDOWS=1 \
HIMMEL_R5_WINPID=424242 \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-windows.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-lease.mjs" main "$tmp/lease-windows.stdout" "$tmp/lease-windows.stderr" "$tmp/lease-windows.pid" || runner_rc=$?
check "Windows lease runner exits 0" "$runner_rc" "0"
check "Windows ownership pid sidecar is nonempty" "$(test -s "$tmp/lease-windows.pid" && echo nonempty || echo empty)" "nonempty"
check "Windows ownership identity sidecar is nonempty" "$(test -s "$tmp/lease-windows.pid.identity" && echo nonempty || echo empty)" "nonempty"
lease_pid=$(awk 'previous == "-ClientPid" { print; exit } { previous = $0 }' "$tmp/lease-windows.args" 2>/dev/null)
check "Windows lease receives translated native pid" "$lease_pid" "424242"

rm -f "$tmp/lease-posix.args" "$tmp/lease-posix.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
HIMMEL_R5_WINDOWS=0 \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-posix.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-posix.stdout" "$tmp/lease-posix.stderr" "$tmp/lease-posix.pid" || runner_rc=$?
check "POSIX lease runner exits 0" "$runner_rc" "0"
check "POSIX ownership pid sidecar is nonempty" "$(test -s "$tmp/lease-posix.pid" && echo nonempty || echo empty)" "nonempty"
check "POSIX ownership identity sidecar is nonempty" "$(test -s "$tmp/lease-posix.pid.identity" && echo nonempty || echo empty)" "nonempty"
lease_pid=$(awk 'previous == "-ClientPid" { print; exit } { previous = $0 }' "$tmp/lease-posix.args" 2>/dev/null)
check "POSIX lease receives unchanged node pid" "$lease_pid" "$(cat "$tmp/lease-posix.pid")"

rm -f "$tmp/lease-invalid.args" "$tmp/lease-invalid.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
HIMMEL_R5_WINDOWS=1 \
HIMMEL_R5_WINPID=not-a-pid \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-invalid.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-invalid.stdout" "$tmp/lease-invalid.stderr" "$tmp/lease-invalid.pid" || runner_rc=$?
check "invalid native pid runner exits 0" "$runner_rc" "0"
check "invalid native pid skips lease writer" "$(test -e "$tmp/lease-invalid.args" && echo launched || echo skipped)" "skipped"

# HIMMEL-1509: the branch render lease. RENDER_LEASE_BRANCH opts the launcher
# into the registry: atomic claim before node spawns, release only on a
# verified-clean exit, refusal (exit 75) on a held branch or unusable registry.
reg1509="$tmp/reg-1509"
rm -rf "$reg1509" "$tmp/lease-1509.pid"
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-clean \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R5_WINDOWS=0 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509.stdout" "$tmp/lease-1509.stderr" "$tmp/lease-1509.pid" 2>"$tmp/lease-1509-runner.stderr" || runner_rc=$?
check "leased clean run exits 0" "$runner_rc" "0"
check "leased clean run creates the registry" "$(test -d "$reg1509" && echo present || echo absent)" "present"
check "verified-clean exit releases the branch lease" "$(test -e "$reg1509/feat+2F1509-clean" && echo held || echo released)" "released"

# The Windows heartbeat writer receives the lease dir so it can refresh the
# registry heartbeat + tokens alongside the cxc client lease.
rm -f "$tmp/lease-1509-win.args" "$tmp/lease-1509-win.pid"
runner_rc=0
PATH="$tmp/lease-fixture/stub-bin:$PATH" \
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-win \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R5_WINDOWS=1 \
HIMMEL_R5_WINPID=424242 \
HIMMEL_R5_PWSH_ARGS="$tmp/lease-1509-win.args" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-lease.mjs" main "$tmp/lease-1509-win.stdout" "$tmp/lease-1509-win.stderr" "$tmp/lease-1509-win.pid" || runner_rc=$?
check "leased Windows runner exits 0" "$runner_rc" "0"
lease_dir_arg=$(awk 'previous == "-LeaseDir" { print; exit } { previous = $0 }' "$tmp/lease-1509-win.args" 2>/dev/null)
check "heartbeat writer receives the lease dir" "$(printf '%s\n' "$lease_dir_arg" | grep -Fc 'feat+2F1509-win')" "1"

# Second launch on a branch holding a live lease refuses loudly, spawns
# nothing, and preserves the holder's record (the HIMMEL-1496 TOCTOU closure).
mkdir -p "$reg1509/feat+2F1509-held"
printf 'branch\tfeat/1509-held\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t424242\nleader_winpid\t424242\nleader_identity\ttest-identity\nstatus\trunning\n' \
    "$tmp" > "$reg1509/feat+2F1509-held/lease.record"
rm -f "$tmp/lease-1509-refused.stdout"
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-held \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R6_IDENTITY_RC=0 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-refused.stdout" "$tmp/lease-1509-refused.stderr" 2>"$tmp/lease-1509-refused-runner.stderr" || runner_rc=$?
check "second launch on a held branch exits 75" "$runner_rc" "75"
check "refused launch emits loud diagnostic" "$(grep -Fc 'launch REFUSED' "$tmp/lease-1509-refused-runner.stderr" 2>/dev/null)" "1"
check "refused launch spawns no companion" "$(test -e "$tmp/lease-1509-refused.stdout" && echo spawned || echo refused)" "refused"
check "refused launch preserves the holder record" "$(test -s "$reg1509/feat+2F1509-held/lease.record" && echo preserved || echo missing)" "preserved"

# A stale lease with a CONFIRMED-dead leader is reclaimed by the next launch.
mkdir -p "$reg1509/feat+2F1509-stale"
printf 'branch\tfeat/1509-stale\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2020-01-01T00:00:00Z\nleader_pid\t424243\nleader_winpid\t424243\nleader_identity\ttest-identity\nstatus\trunning\n' \
    "$tmp" > "$reg1509/feat+2F1509-stale/lease.record"
touch -t 202001010000 "$reg1509/feat+2F1509-stale/lease.record"
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-stale \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R6_IDENTITY_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-stale.stdout" "$tmp/lease-1509-stale.stderr" 2>"$tmp/lease-1509-stale-runner.stderr" || runner_rc=$?
check "stale-lease launch reclaims and exits 0" "$runner_rc" "0"
check "stale-lease launch announces the reclaim" "$(grep -Fc 'reclaiming stale lease' "$tmp/lease-1509-stale-runner.stderr" 2>/dev/null)" "1"
check "reclaimed lease is released on clean exit" "$(test -e "$reg1509/feat+2F1509-stale" && echo held || echo released)" "released"

# An UNVERIFIED exit (cleanup rc nonzero) leaves the lease for adjudication.
runner_rc=0
RENDER_LEASE_DIR="$reg1509" RENDER_LEASE_BRANCH=feat/1509-dirty \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
HIMMEL_R6_GROUP_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-dirty.stdout" "$tmp/lease-1509-dirty.stderr" 2>"$tmp/lease-1509-dirty-runner.stderr" || runner_rc=$?
check "unverified-cleanup leased run exits 125" "$runner_rc" "125"
check "unverified exit preserves the lease" "$(test -s "$reg1509/feat+2F1509-dirty/lease.record" && echo preserved || echo released)" "preserved"
check "preserved lease is announced for adjudication" "$(grep -Fc 'lease preserved for adjudication' "$tmp/lease-1509-dirty-runner.stderr" 2>/dev/null)" "1"

# An unusable registry refuses the launch (fail-closed) instead of running
# untracked.
printf 'not a dir' > "$tmp/reg-blocker"
runner_rc=0
RENDER_LEASE_DIR="$tmp/reg-blocker/sub" RENDER_LEASE_BRANCH=feat/1509-broken \
RENDER_LEASE_LOCK_ATTEMPTS=2 RENDER_LEASE_LOCK_DELAY_SECS=0 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/lease-1509-broken.stdout" "$tmp/lease-1509-broken.stderr" 2>"$tmp/lease-1509-broken-runner.stderr" || runner_rc=$?
check "unusable registry refuses the launch with 75" "$runner_rc" "75"
check "unusable registry refusal is loud" "$(grep -Fc 'launch REFUSED' "$tmp/lease-1509-broken-runner.stderr" 2>/dev/null)" "1"

# pr-check wiring: kickoff probe + both fences exporting the launch claim.
# shellcheck disable=SC2016
lease_export_wiring=$(grep -Fc 'export RENDER_LEASE_BRANCH="$branch"' "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest both export the launch claim" "$lease_export_wiring" "2"
# shellcheck disable=SC2016
lease_probe_wiring=$(grep -Fc 'render_lease_probe "$branch"' "$PR_CHECK" 2>/dev/null)
check "kickoff pre-flights the branch lease probe" "$lease_probe_wiring" "1"
lease_source_wiring=$(grep -Fc '. scripts/lib/render-lease.sh' "$PR_CHECK" 2>/dev/null)
check "kickoff sources the render-lease lib" "$lease_source_wiring" "1"

# HIMMEL-1474 r11: launch identity is a required ownership handshake. Persistent
# INITIAL probe failure must terminate the still-owned group before returning,
# and must never publish a pid without its identity anchor.
rm -f "$tmp/initial-identity.pid" "$tmp/initial-identity.pid.identity" "$tmp/initial-identity-terminated"
runner_rc=0
HIMMEL_R11_IDENTITY_UNAVAILABLE=1 \
HIMMEL_R11_TERMINATE_REAL_GROUP=1 \
HIMMEL_R6_GROUP_TERMINATE_CALLED="$tmp/initial-identity-terminated" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/initial-identity.stdout" "$tmp/initial-identity.stderr" "$tmp/initial-identity.pid" 2>"$tmp/initial-identity-runner.stderr" || runner_rc=$?
check "initial identity failure returns unavailable" "$runner_rc" "125"
check "initial identity failure terminates the owned group" "$(test -e "$tmp/initial-identity-terminated" && echo terminated || echo missed)" "terminated"
check "initial identity failure publishes no pid" "$(test -e "$tmp/initial-identity.pid" && echo published || echo absent)" "absent"
check "initial identity failure publishes no identity" "$(test -e "$tmp/initial-identity.pid.identity" && echo published || echo absent)" "absent"
initial_identity_diagnostic=$(grep -Fc "process identity could not be captured" "$tmp/initial-identity-runner.stderr" 2>/dev/null)
check "initial identity failure reports unavailable launch" "$initial_identity_diagnostic" "1"

# HIMMEL-1474 r12: a signal during that identity retry window must either reap
# the still-owned group or publish recovery handles before the wrapper exits.
rm -f "$tmp/handshake-signal.pid" "$tmp/handshake-signal.pid.identity" "$tmp/handshake-signal.pid.cleanup-rc" "$tmp/handshake-signal-probed"
HIMMEL_R11_IDENTITY_UNAVAILABLE=1 \
HIMMEL_R12_IDENTITY_PROBE_CALLED="$tmp/handshake-signal-probed" \
HIMMEL_R11_TERMINATE_REAL_GROUP=1 \
HIMMEL_R6_GROUP_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/handshake-signal.stdout" "$tmp/handshake-signal.stderr" "$tmp/handshake-signal.pid" 0 "$tmp/handshake-signal.pid.cleanup-rc" 2>"$tmp/handshake-signal-runner.stderr" &
handshake_wrapper_pid=$!
waited=0
while [ ! -e "$tmp/handshake-signal-probed" ] && kill -0 "$handshake_wrapper_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
handshake_probes_before=$(wc -c < "$tmp/handshake-signal-probed" | tr -d ' ')
kill -TERM "$handshake_wrapper_pid" 2>/dev/null || true
handshake_signal_rc=0
wait "$handshake_wrapper_pid" 2>/dev/null || handshake_signal_rc=$?
handshake_probes_after=$(wc -c < "$tmp/handshake-signal-probed" | tr -d ' ')
check "signal during identity handshake exits 143" "$handshake_signal_rc" "143"
check "failed signal cleanup retries identity acquisition" "$([ "$handshake_probes_after" -gt "$handshake_probes_before" ] && echo retried || echo missed)" "retried"
check "failed handshake identity reacquisition leaves no pid marker" "$(test -e "$tmp/handshake-signal.pid" && echo published || echo absent)" "absent"
check "failed handshake identity reacquisition leaves no identity marker" "$(test -e "$tmp/handshake-signal.pid.identity" && echo published || echo absent)" "absent"
check "unverified handshake signal publishes cleanup status" "$(cat "$tmp/handshake-signal.pid.cleanup-rc" 2>/dev/null)" "1"
handshake_unrecoverable_diagnostic=$(grep -Fc "signal cleanup UNRECOVERABLE" "$tmp/handshake-signal-runner.stderr" 2>/dev/null)
check "failed handshake identity reacquisition emits loud diagnostic" "$handshake_unrecoverable_diagnostic" "1"

# HIMMEL-1474 r6: a cleanup primitive failure is separate from the companion
# result. A clean companion cannot publish rc 0 while its group may survive.
runner_rc=0
HIMMEL_R6_GROUP_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/cleanup.stdout" "$tmp/cleanup.stderr" 2>"$tmp/cleanup-runner.stderr" || runner_rc=$?
check "cleanup failure after companion success exits 125" "$runner_rc" "125"
cleanup_diagnostic=$(grep -Fc "codex adversarial cleanup failed for pid/group" "$tmp/cleanup-runner.stderr" 2>/dev/null)
check "cleanup failure names the pid/group on stderr" "$cleanup_diagnostic" "1"

rm -f "$tmp/group-terminate-called" "$tmp/identity-unavailable.pid" "$tmp/identity-unavailable.pid.identity"
runner_rc=0
identity_started=$SECONDS
HIMMEL_R6_IDENTITY_RC=2 HIMMEL_R6_GROUP_TERMINATE_CALLED="$tmp/group-terminate-called" \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/identity-unavailable.stdout" "$tmp/identity-unavailable.stderr" "$tmp/identity-unavailable.pid" 1 2>"$tmp/identity-unavailable-runner.stderr" || runner_rc=$?
identity_elapsed=$((SECONDS - identity_started))
check "identity-unavailable timeout keeps rc 124" "$runner_rc" "124"
check "identity-unavailable timeout skips blocking wait" "$([ "$identity_elapsed" -lt 10 ] && echo bounded || echo blocked)" "bounded"
check "identity-unavailable cleanup sends no group signal" "$(test -e "$tmp/group-terminate-called" && echo signaled || echo skipped)" "skipped"
check "identity-unavailable timeout preserves pid sidecar" "$(test -s "$tmp/identity-unavailable.pid" && echo preserved || echo missing)" "preserved"
check "identity-unavailable timeout preserves identity sidecar" "$(test -s "$tmp/identity-unavailable.pid.identity" && echo preserved || echo missing)" "preserved"
identity_cleanup_diagnostic=$(grep -Fc "identity probe unavailable; no signal sent" "$tmp/identity-unavailable-runner.stderr" 2>/dev/null)
check "identity-unavailable cleanup emits diagnostic" "$identity_cleanup_diagnostic" "1"
identity_wait_diagnostic=$(grep -Fc "timeout cleanup incomplete for pid/group" "$tmp/identity-unavailable-runner.stderr" 2>/dev/null)
check "identity-unavailable timeout reports skipped blocking wait" "$identity_wait_diagnostic" "1"
identity_unavailable_pid=$(cat "$tmp/identity-unavailable.pid")
kill -9 "$identity_unavailable_pid" 2>/dev/null || true
if command -v taskkill >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 taskkill /PID "$identity_unavailable_pid" /T /F >/dev/null 2>&1 || true
fi

runner_rc=0
HIMMEL_R6_TERMINATE_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/cleanup-timeout.stdout" "$tmp/cleanup-timeout.stderr" "" 1 2>"$tmp/cleanup-timeout-runner.stderr" || runner_rc=$?
check "timeout keeps rc 124 when cleanup fails" "$runner_rc" "124"
timeout_cleanup_diagnostic=$(grep -Fc "codex adversarial cleanup failed for pid/group" "$tmp/cleanup-timeout-runner.stderr" 2>/dev/null)
check "timeout cleanup failure still emits diagnostic" "$timeout_cleanup_diagnostic" "1"

# HIMMEL-1501: proc_tree_terminate rc 3 (confirmed-gone before any signal) is
# distinct from rc 1/2 but must still be treated as "cleanup unverified" by
# publish_cleanup_rc -- the leader-only check never saw the group, so a
# survivors sidecar is still published for recovery.
rm -f "$tmp/cleanup-confirmed-gone.pid" "$tmp/cleanup-confirmed-gone.pid.identity" "$tmp/cleanup-confirmed-gone.pid.survivors"
runner_rc=0
HIMMEL_R6_TERMINATE_RC=3 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/cleanup-confirmed-gone.stdout" "$tmp/cleanup-confirmed-gone.stderr" "$tmp/cleanup-confirmed-gone.pid" 1 2>"$tmp/cleanup-confirmed-gone-runner.stderr" || runner_rc=$?
check "confirmed-gone (rc 3) timeout keeps rc 124" "$runner_rc" "124"
check "confirmed-gone (rc 3) preserves ownership pid sidecar" "$(test -s "$tmp/cleanup-confirmed-gone.pid" && echo preserved || echo missing)" "preserved"
check "confirmed-gone (rc 3) publishes a survivors sidecar" "$(test -e "$tmp/cleanup-confirmed-gone.pid.survivors" && echo published || echo absent)" "published"
confirmed_gone_pid=$(cat "$tmp/cleanup-confirmed-gone.pid" 2>/dev/null)
if [ -n "$confirmed_gone_pid" ]; then
    kill -9 "$confirmed_gone_pid" 2>/dev/null || true
    if command -v taskkill >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 taskkill /PID "$confirmed_gone_pid" /T /F >/dev/null 2>&1 || true
    fi
fi

runner_rc=0
HIMMEL_R2_CHILD_SCRIPT="$tmp/stubborn-child.mjs" \
HIMMEL_R2_CHILD_PID_FILE="$tmp/child.pid" \
HIMMEL_R2_HEARTBEAT="$tmp/heartbeat" \
    bash "$RUNNER" "$tmp/companion.mjs" main "$tmp/stdout" "$tmp/stderr" "" 1 || runner_rc=$?
check "timeout exits 124" "$runner_rc" "124"

waited=0
while [ ! -s "$tmp/heartbeat" ] && [ "$waited" -lt 20 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ -s "$tmp/heartbeat" ]; then
    size_before=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    sleep 2
    size_after=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    check "timeout stops stubborn descendants with the companion group" "$size_after" "$size_before"
else
    echo "FAIL - stubborn child never wrote its heartbeat"
    fails=$((fails + 1))
fi

# HIMMEL-1474 r4: a successful leader exit is not group completion. The runner
# must sweep stubborn descendants before returning the leader's rc.
rm -f "$tmp/child.pid" "$tmp/heartbeat"
runner_rc=0
HIMMEL_R2_CHILD_SCRIPT="$tmp/stubborn-child.mjs" \
HIMMEL_R2_CHILD_PID_FILE="$tmp/child.pid" \
HIMMEL_R2_HEARTBEAT="$tmp/heartbeat" \
    bash "$RUNNER" "$tmp/companion-exits.mjs" main "$tmp/stdout-exit" "$tmp/stderr-exit" || runner_rc=$?
check "leader-exit companion preserves rc 0" "$runner_rc" "0"
if [ -s "$tmp/heartbeat" ]; then
    size_before=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    sleep 2
    size_after=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    check "leader exit sweeps stubborn group descendants" "$size_after" "$size_before"
else
    echo "FAIL - leader-exit stubborn child never wrote its heartbeat"
    fails=$((fails + 1))
fi

# HIMMEL-1474 r3: production uses the 5-argument async kickoff, then harvests
# the recorded node group leader later. A taskkill stub makes any Windows-only
# escape visible while the portable group kill must stop the stubborn child.
rm -f "$tmp/child.pid" "$tmp/heartbeat" "$tmp/async.pid" "$tmp/async.rc" "$tmp/taskkill-called"
mkdir -p "$tmp/stub-bin"
cat > "$tmp/stub-bin/taskkill" <<'SH'
#!/usr/bin/env bash
: > "${HIMMEL_R3_TASKKILL_CALLED:?}"
exit 127
SH
chmod +x "$tmp/stub-bin/taskkill"
(
    PATH="$tmp/stub-bin:$PATH" \
    HIMMEL_R2_CHILD_SCRIPT="$tmp/stubborn-child.mjs" \
    HIMMEL_R2_CHILD_PID_FILE="$tmp/child.pid" \
    HIMMEL_R2_HEARTBEAT="$tmp/heartbeat" \
    HIMMEL_R3_TASKKILL_CALLED="$tmp/taskkill-called" \
        bash "$RUNNER" "$tmp/companion.mjs" main "$tmp/stdout-async" "$tmp/stderr-async" "$tmp/async.pid"
    printf '%s\n' "$?" > "$tmp/async.rc"
) &
async_job=$!

waited=0
while { [ ! -s "$tmp/async.pid" ] || [ ! -s "$tmp/async.pid.identity" ] || [ ! -s "$tmp/heartbeat" ]; } && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ -s "$tmp/async.pid" ] && [ -s "$tmp/async.pid.identity" ] && [ -s "$tmp/heartbeat" ]; then
    async_pid=$(cat "$tmp/async.pid")
    async_identity=$(cat "$tmp/async.pid.identity")
    check "5-arg kickoff publishes matching process identity" "$(proc_tree_process_identity_matches "$async_pid" "$async_identity" && echo match || echo mismatch)" "match"
    PATH="$tmp/stub-bin:$PATH" HIMMEL_R3_TASKKILL_CALLED="$tmp/taskkill-called" \
        proc_tree_terminate "$async_pid" 1 "$async_identity" || true
    wait "$async_job" 2>/dev/null || true
    size_before=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    sleep 2
    size_after=$(wc -c < "$tmp/heartbeat" | tr -d ' ')
    check "5-arg harvest stops stubborn descendants with the recorded group" "$size_after" "$size_before"
    check "5-arg harvest does not need taskkill" "$(test -e "$tmp/taskkill-called" && echo called || echo absent)" "absent"
else
    echo "FAIL - 5-arg kickoff did not publish pid and child heartbeat"
    fails=$((fails + 1))
fi

# HIMMEL-1474 r4: model the recycled-pid harvest case against the same guarded
# primitive wired into pr-check. A mismatched anchor must return before signal.
# HIMMEL-1501: identity_matches confirms this mismatch (rc 1, not the probe
# being merely unavailable), so proc_tree_terminate now returns the distinct
# rc 3 rather than the collapsed rc 2 -- the safety property under test
# (no signal reaches the unrelated live process) is unchanged.
set -m
sleep 30 &
unrelated_pid=$!
set +m
unrelated_identity=$(proc_tree_process_identity "$unrelated_pid") || unrelated_identity=''
guard_rc=0
proc_tree_terminate "$unrelated_pid" 0 "${unrelated_identity}-recycled" || guard_rc=$?
check "identity mismatch refuses to signal recycled pid" "$guard_rc" "3"
check "identity-mismatched unrelated process remains alive" "$(kill -0 "$unrelated_pid" 2>/dev/null && echo alive || echo dead)" "alive"
kill -9 "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
unrelated_pid=''

# HIMMEL-1474 r6: identity checks distinguish confirmed mismatch/exit from an
# unavailable probe so harvest can wait through transient infrastructure gaps.
identity_match_rc=0
(
    # shellcheck disable=SC2317,SC2329
    proc_tree_is_windows() { return 1; }
    # shellcheck disable=SC2317,SC2329
    ps() { printf '%s\n' 'Mon Aug  3 00:00:00 2026 bash test-runner'; }
    current_identity=$(proc_tree_process_identity "$$") || exit 9
    proc_tree_process_identity_matches "$$" "$current_identity"
) || identity_match_rc=$?
check "identity probe returns 0 for a confirmed match" "$identity_match_rc" "0"

identity_exit_rc=0
(
    # shellcheck disable=SC2317,SC2329
    proc_tree_is_windows() { return 1; }
    proc_tree_process_identity_matches 2147483647 "posix:gone"
) || identity_exit_rc=$?
check "identity probe returns 1 for a confirmed exit" "$identity_exit_rc" "1"

identity_unavailable_rc=0
(
    # shellcheck disable=SC2317,SC2329
    proc_tree_is_windows() { return 1; }
    # shellcheck disable=SC2317,SC2329
    ps() { return 1; }
    proc_tree_process_identity_matches "$$" "posix:unavailable"
) || identity_unavailable_rc=$?
check "identity probe returns 2 when ps fails for a live pid" "$identity_unavailable_rc" "2"

process_alive_rc=0
proc_tree_process_alive "$$" || process_alive_rc=$?
check "identity-free liveness probe confirms current shell" "$process_alive_rc" "0"
process_gone_rc=0
proc_tree_process_alive 2147483647 || process_gone_rc=$?
check "identity-free liveness probe confirms absent pid" "$process_gone_rc" "1"

# HIMMEL-1474 r6b: execute the production harvest loop with deterministic
# identity and sleep stubs. An unavailable probe must consume the wait budget;
# only a confirmed mismatch/exit may abandon the wait at waited=0.
harvest_loop_extract_rc=0
harvest_loop=$(awk '
    /while \[ ! -s "\$codex_rc_file" \]; do/ { capture=1 }
    capture {
        sub(/^       /, "")
        print
        if ($0 == "done") { complete=1; exit }
    }
    END { if (!complete) exit 42 }
' "$PR_CHECK") || harvest_loop_extract_rc=$?
check "harvest-loop extractor reaches its terminating done" "$harvest_loop_extract_rc" "0"
# shellcheck disable=SC2034,SC2317,SC2329
harvest_unavailable_result=$(
    codex_rc_file="$tmp/harvest-unavailable.rc"
    codex_pid=424242
    codex_identity=''
    codex_to=5
    waited=0
    probe_count=0
    proc_tree_process_identity_matches() {
        probe_count=$((probe_count + 1))
        return 2
    }
    sleep() { :; }
    eval "$harvest_loop"
    printf '%s:%s\n' "$probe_count" "$waited"
)
check "identity-unavailable harvest waits through waited=0" "$harvest_unavailable_result" "2:5"

# shellcheck disable=SC2034,SC2317,SC2329
harvest_mismatch_result=$(
    codex_rc_file="$tmp/harvest-mismatch.rc"
    codex_pid=424242
    codex_identity='test-identity'
    codex_to=5
    waited=0
    probe_count=0
    proc_tree_process_identity_matches() {
        probe_count=$((probe_count + 1))
        return 1
    }
    sleep() { :; }
    eval "$harvest_loop"
    printf '%s:%s\n' "$probe_count" "$waited"
)
check "identity mismatch harvest breaks at waited=0" "$harvest_mismatch_result" "1:0"

harvest_wiring=$(grep -Fc "proc_tree_terminate \"\$codex_pid\" 1 \"\$codex_identity\"" "$PR_CHECK" 2>/dev/null)
check "production harvest passes launch identity to proc_tree_terminate" "$harvest_wiring" "1"
identity_file_wiring=$(grep -Fc "codex_identity_file=\"\${codex_pid_file}.identity\"" "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest share the identity sidecar" "$identity_file_wiring" "2"
survivors_file_wiring=$(grep -Fc "codex_survivors_file=\"\${codex_pid_file}.survivors\"" "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest share the survivor sidecar" "$survivors_file_wiring" "2"
rc_first_wiring=$(grep -Fc "while [ ! -s \"\$codex_rc_file\" ]; do" "$PR_CHECK" 2>/dev/null)
check "production harvest checks rc before identity probing" "$rc_first_wiring" "1"

# HIMMEL-1474 r11/r12: execute the kickoff recovery fence. Cleanup status is
# record-scoped, so a clean primary can be cleared independently of a failed
# retry while an unverifiable record still blocks overwrite.
kickoff_recovery_extract_rc=0
kickoff_recovery_block=$(awk '
    /HIMMEL-1474 r11 kickoff recovery start/ { capture=1; next }
    /HIMMEL-1474 r11 kickoff recovery end/ {
        if (capture) complete=1
        exit
    }
    capture { sub(/^   /, ""); print }
    END { if (!complete) exit 42 }
' "$PR_CHECK") || kickoff_recovery_extract_rc=$?
check "kickoff-recovery extractor reaches its end marker" "$kickoff_recovery_extract_rc" "0"
handshake_next_kickoff_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/handshake-signal.pid"
    codex_retry_pid_file="$tmp/handshake-signal-retry.pid"
    proc_tree_process_identity_matches() { return 9; }
    proc_tree_terminate() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/handshake-next-kickoff.stderr" || handshake_next_kickoff_rc=$?
check "failed blank-identity recovery does not block the next kickoff" "$handshake_next_kickoff_rc" "0"
check "next kickoff clears orphan cleanup status without a pid marker" "$(test -e "$tmp/handshake-signal.pid.cleanup-rc" && echo preserved || echo cleared)" "cleared"

rm -f "$tmp/kickoff-primary.pid" "$tmp/kickoff-primary.pid.identity" "$tmp/kickoff-primary.pid.cleanup-rc" \
      "$tmp/kickoff-retry.pid" "$tmp/kickoff-retry.pid.identity" "$tmp/kickoff-retry.pid.cleanup-rc"
printf '%s\n' 424243 > "$tmp/kickoff-primary.pid"
printf '%s\n' primary-identity > "$tmp/kickoff-primary.pid.identity"
printf '%s\n' 0 > "$tmp/kickoff-primary.pid.cleanup-rc"
printf '%s\n' 424244 > "$tmp/kickoff-retry.pid"
printf '%s\n' retry-identity > "$tmp/kickoff-retry.pid.identity"
printf '%s\n' 1 > "$tmp/kickoff-retry.pid.cleanup-rc"
kickoff_mixed_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/kickoff-primary.pid"
    codex_retry_pid_file="$tmp/kickoff-retry.pid"
    proc_tree_process_identity_matches() { return 2; }
    proc_tree_terminate() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/kickoff-mixed.stderr" || kickoff_mixed_rc=$?
check "failed retry blocks kickoff after clean primary is cleared" "$kickoff_mixed_rc" "1"
check "clean primary record is removed independently" "$(test -e "$tmp/kickoff-primary.pid" && echo preserved || echo cleared)" "cleared"
check "clean primary cleanup status is removed independently" "$(test -e "$tmp/kickoff-primary.pid.cleanup-rc" && echo preserved || echo cleared)" "cleared"
check "failed retry pid remains preserved" "$(test -s "$tmp/kickoff-retry.pid" && echo preserved || echo missing)" "preserved"
check "failed retry cleanup status remains preserved" "$(cat "$tmp/kickoff-retry.pid.cleanup-rc" 2>/dev/null)" "1"

kickoff_recover_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/kickoff-primary.pid"
    codex_retry_pid_file="$tmp/kickoff-retry.pid"
    proc_tree_process_identity_matches() { return 0; }
    proc_tree_terminate() { return 0; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/kickoff-recover.stderr" || kickoff_recover_rc=$?
check "kickoff recovers prior retry ownership state" "$kickoff_recover_rc" "0"
check "kickoff recovery clears retry pid sidecar" "$(test -e "$tmp/kickoff-retry.pid" && echo preserved || echo cleared)" "cleared"
check "kickoff recovery clears retry identity sidecar" "$(test -e "$tmp/kickoff-retry.pid.identity" && echo preserved || echo cleared)" "cleared"
check "kickoff recovery clears retry cleanup status" "$(test -e "$tmp/kickoff-retry.pid.cleanup-rc" && echo preserved || echo cleared)" "cleared"
kickoff_recover_diagnostic=$(grep -Fc "recovered prior retry render" "$tmp/kickoff-recover.stderr" 2>/dev/null)
check "kickoff recovery reports recovered retry" "$kickoff_recover_diagnostic" "1"

printf '%s\n' 424245 > "$tmp/kickoff-primary.pid"
printf '%s\n' primary-identity > "$tmp/kickoff-primary.pid.identity"
printf '%s\n' 2 > "$tmp/kickoff-primary.pid.cleanup-rc"
kickoff_block_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/kickoff-primary.pid"
    codex_retry_pid_file="$tmp/kickoff-retry.pid"
    proc_tree_process_identity_matches() { return 2; }
    proc_tree_terminate() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/kickoff-block.stderr" || kickoff_block_rc=$?
check "kickoff blocks unverifiable preserved state" "$kickoff_block_rc" "1"
check "blocked kickoff preserves primary pid sidecar" "$(test -s "$tmp/kickoff-primary.pid" && echo preserved || echo missing)" "preserved"
check "blocked kickoff preserves primary identity sidecar" "$(test -s "$tmp/kickoff-primary.pid.identity" && echo preserved || echo missing)" "preserved"
check "blocked kickoff preserves primary cleanup status" "$(cat "$tmp/kickoff-primary.pid.cleanup-rc" 2>/dev/null)" "2"
kickoff_block_diagnostic=$(grep -Fc "kickoff BLOCKED" "$tmp/kickoff-block.stderr" 2>/dev/null)
check "blocked kickoff emits actionable diagnostic" "$kickoff_block_diagnostic" "1"

# HIMMEL-1474 r14: once a failed cleanup record's leader exits, survivor
# identities are the remaining recovery authority. Exercise both unverified
# cleanup statuses through the launcher and the next kickoff fence.
for survivor_cleanup_rc in 1 2; do
    survivor_prefix="$tmp/survivor-anchor-$survivor_cleanup_rc"
    rm -f "$survivor_prefix.pid" "$survivor_prefix.pid.identity" "$survivor_prefix.pid.cleanup-rc" "$survivor_prefix.pid.survivors" "$survivor_prefix-killed" "$survivor_prefix-signals"
    runner_rc=0
    HIMMEL_R6_GROUP_TERMINATE_RC="$survivor_cleanup_rc" HIMMEL_R14_GROUP_MEMBERS=5151 \
        bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$survivor_prefix.stdout" "$survivor_prefix.stderr" "$survivor_prefix.pid" 0 "$survivor_prefix.pid.cleanup-rc" 2>"$survivor_prefix-runner.stderr" || runner_rc=$?
    check "cleanup rc $survivor_cleanup_rc after leader exit remains unavailable" "$runner_rc" "125"
    survivor_record=$(awk -F'\t' '{ print $1 ":" $2; exit }' "$survivor_prefix.pid.survivors" 2>/dev/null)
    check "cleanup rc $survivor_cleanup_rc publishes survivor identity sidecar" "$survivor_record" "5151:test-identity"
    survivor_leader_pid=$(cat "$survivor_prefix.pid")
    survivor_recover_rc=0
    # shellcheck disable=SC2034,SC2317,SC2329
    (
        codex_pid_file="$survivor_prefix.pid"
        codex_retry_pid_file="$survivor_prefix-retry.pid"
        proc_tree_process_identity_matches() {
            if [ "$1" = "$survivor_leader_pid" ]; then
                return 1
            fi
            if [ "$1" = "5151" ] && [ "$2" = "test-identity" ] && [ ! -e "$survivor_prefix-killed" ]; then
                return 0
            fi
            return 1
        }
        proc_tree_process_alive() {
            [ "$1" = "5151" ] && [ ! -e "$survivor_prefix-killed" ]
        }
        proc_tree_process_identity() { return 1; }
        proc_tree_terminate() { return 9; }
        kill() {
            printf '%s:%s\n' "$1" "$2" >> "$survivor_prefix-signals"
            [ "$1" != "-TERM" ] || : > "$survivor_prefix-killed"
            return 0
        }
        sleep() { :; }
        eval "$kickoff_recovery_block"
    ) 2>"$survivor_prefix-recover.stderr" || survivor_recover_rc=$?
    check "cleanup rc $survivor_cleanup_rc next kickoff recovers through survivor anchor" "$survivor_recover_rc" "0"
    check "cleanup rc $survivor_cleanup_rc recovery signals verified survivor" "$(grep -Fc -- '-TERM:5151' "$survivor_prefix-signals" 2>/dev/null)" "1"
    check "cleanup rc $survivor_cleanup_rc recovery clears survivor sidecar" "$(test -e "$survivor_prefix.pid.survivors" && echo preserved || echo cleared)" "cleared"
done

# An unavailable process-table snapshot must not publish an empty sidecar that
# a later kickoff could mistake for definitive group absence.
rm -f "$tmp/survivor-snapshot-failed.pid" "$tmp/survivor-snapshot-failed.pid.identity" "$tmp/survivor-snapshot-failed.pid.cleanup-rc" "$tmp/survivor-snapshot-failed.pid.survivors"
runner_rc=0
HIMMEL_R6_GROUP_TERMINATE_RC=1 HIMMEL_R14_GROUP_MEMBERS_RC=1 \
    bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion.mjs" main "$tmp/survivor-snapshot-failed.stdout" "$tmp/survivor-snapshot-failed.stderr" "$tmp/survivor-snapshot-failed.pid" 0 "$tmp/survivor-snapshot-failed.pid.cleanup-rc" 2>"$tmp/survivor-snapshot-failed-runner.stderr" || runner_rc=$?
check "unavailable survivor snapshot keeps cleanup unavailable" "$runner_rc" "125"
check "unavailable survivor snapshot publishes no false-empty sidecar" "$(test -e "$tmp/survivor-snapshot-failed.pid.survivors" && echo published || echo absent)" "absent"
check "unavailable survivor snapshot emits diagnostic" "$(grep -Fc 'survivor snapshot unavailable' "$tmp/survivor-snapshot-failed-runner.stderr" 2>/dev/null)" "1"

# A complete r14 snapshot may name survivors that exited before the next
# kickoff. Confirmed absence is definitive and clears the preserved record.
printf '%s\n' 424250 > "$tmp/survivors-gone.pid"
printf '%s\n' leader-identity > "$tmp/survivors-gone.pid.identity"
printf '%s\n' 1 > "$tmp/survivors-gone.pid.cleanup-rc"
printf '5152\ttest-identity\n' > "$tmp/survivors-gone.pid.survivors"
survivors_gone_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/survivors-gone.pid"
    codex_retry_pid_file="$tmp/survivors-gone-retry.pid"
    proc_tree_process_identity_matches() { return 1; }
    proc_tree_process_alive() { return 1; }
    proc_tree_process_identity() { return 1; }
    proc_tree_terminate() { return 9; }
    kill() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/survivors-gone.stderr" || survivors_gone_rc=$?
check "exited leader with all survivor anchors gone proceeds" "$survivors_gone_rc" "0"
check "all-gone survivor recovery clears ownership record" "$(test -e "$tmp/survivors-gone.pid" && echo preserved || echo cleared)" "cleared"

# HIMMEL-1501: a preserved cleanup rc of 3 (confirmed-gone before any signal
# was sent) must be recovered the same way as 1/2 -- the survivors sidecar
# stays the authority regardless of which rc the prior run left behind.
printf '%s\n' 424254 > "$tmp/confirmed-gone-record.pid"
printf '%s\n' leader-identity > "$tmp/confirmed-gone-record.pid.identity"
printf '%s\n' 3 > "$tmp/confirmed-gone-record.pid.cleanup-rc"
printf '5154\ttest-identity\n' > "$tmp/confirmed-gone-record.pid.survivors"
confirmed_gone_record_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/confirmed-gone-record.pid"
    codex_retry_pid_file="$tmp/confirmed-gone-record-retry.pid"
    proc_tree_process_identity_matches() { return 1; }
    proc_tree_process_alive() { return 1; }
    proc_tree_process_identity() { return 1; }
    proc_tree_terminate() { return 9; }
    kill() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/confirmed-gone-record.stderr" || confirmed_gone_record_rc=$?
check "state cleanup rc=3 with all survivor anchors gone proceeds" "$confirmed_gone_record_rc" "0"
check "rc=3 survivor recovery clears ownership record" "$(test -e "$tmp/confirmed-gone-record.pid" && echo preserved || echo cleared)" "cleared"

# The leader can match at the first probe and then exit before the guarded
# terminate call. Confirmed-gone rc 3 must join the same survivor recovery path
# rather than blocking the next kickoff.
printf '%s\n' 424255 > "$tmp/terminate-confirmed-gone.pid"
printf '%s\n' leader-identity > "$tmp/terminate-confirmed-gone.pid.identity"
printf '%s\n' 1 > "$tmp/terminate-confirmed-gone.pid.cleanup-rc"
printf '5156\ttest-identity\n' > "$tmp/terminate-confirmed-gone.pid.survivors"
rm -f "$tmp/terminate-confirmed-gone-killed" "$tmp/terminate-confirmed-gone-signals" "$tmp/terminate-confirmed-gone-called"
terminate_confirmed_gone_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/terminate-confirmed-gone.pid"
    codex_retry_pid_file="$tmp/terminate-confirmed-gone-retry.pid"
    proc_tree_process_identity_matches() {
        if [ "$1" = "424255" ]; then
            return 0
        fi
        if [ "$1" = "5156" ] && [ "$2" = "test-identity" ] && [ ! -e "$tmp/terminate-confirmed-gone-killed" ]; then
            return 0
        fi
        return 1
    }
    proc_tree_process_alive() { [ "$1" = "5156" ] && [ ! -e "$tmp/terminate-confirmed-gone-killed" ]; }
    proc_tree_terminate() { : > "$tmp/terminate-confirmed-gone-called"; return 3; }
    kill() {
        printf '%s:%s\n' "$1" "$2" >> "$tmp/terminate-confirmed-gone-signals"
        [ "$1" != "-TERM" ] || : > "$tmp/terminate-confirmed-gone-killed"
        return 0
    }
    sleep() { :; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/terminate-confirmed-gone.stderr" || terminate_confirmed_gone_rc=$?
check "identity match followed by terminate rc 3 recovers through survivor anchor" "$terminate_confirmed_gone_rc" "0"
check "terminate rc 3 recovery attempted guarded leader cleanup" "$(test -e "$tmp/terminate-confirmed-gone-called" && echo called || echo missed)" "called"
check "terminate rc 3 recovery signals verified survivor" "$(grep -Fc -- '-TERM:5156' "$tmp/terminate-confirmed-gone-signals" 2>/dev/null)" "1"
check "terminate rc 3 recovery clears ownership record" "$(test -e "$tmp/terminate-confirmed-gone.pid" && echo preserved || echo cleared)" "cleared"

# A live pid with a different identity is not the recorded survivor and cannot
# be signaled or silently treated as absence.
printf '%s\n' 424251 > "$tmp/survivor-mismatch.pid"
printf '%s\n' leader-identity > "$tmp/survivor-mismatch.pid.identity"
printf '%s\n' 2 > "$tmp/survivor-mismatch.pid.cleanup-rc"
printf '5153\ttest-identity\n' > "$tmp/survivor-mismatch.pid.survivors"
survivor_mismatch_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/survivor-mismatch.pid"
    codex_retry_pid_file="$tmp/survivor-mismatch-retry.pid"
    proc_tree_process_identity_matches() { return 1; }
    proc_tree_process_alive() { [ "$1" = "5153" ]; }
    proc_tree_process_identity() {
        [ "$1" != "5153" ] || printf '%s\n' recycled-identity
    }
    proc_tree_terminate() { return 9; }
    kill() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/survivor-mismatch.stderr" || survivor_mismatch_rc=$?
check "identity-mismatched survivor blocks kickoff" "$survivor_mismatch_rc" "1"
check "identity-mismatched survivor record stays preserved" "$(test -s "$tmp/survivor-mismatch.pid.survivors" && echo preserved || echo missing)" "preserved"
check "identity-mismatched survivor diagnostic names mismatch" "$(grep -Fc 'identity mismatch' "$tmp/survivor-mismatch.stderr" 2>/dev/null)" "1"

# Pre-r14 failed records have no survivor anchors. Preserve the old fail-closed
# manual path instead of guessing that a dead leader means an empty group.
printf '%s\n' 424252 > "$tmp/legacy-record.pid"
printf '%s\n' leader-identity > "$tmp/legacy-record.pid.identity"
printf '%s\n' 1 > "$tmp/legacy-record.pid.cleanup-rc"
rm -f "$tmp/legacy-record.pid.survivors"
legacy_record_rc=0
# shellcheck disable=SC2034,SC2317,SC2329
(
    codex_pid_file="$tmp/legacy-record.pid"
    codex_retry_pid_file="$tmp/legacy-record-retry.pid"
    proc_tree_process_identity_matches() { return 1; }
    proc_tree_process_identity() { return 1; }
    proc_tree_terminate() { return 9; }
    eval "$kickoff_recovery_block"
) 2>"$tmp/legacy-record.stderr" || legacy_record_rc=$?
check "legacy failed record without survivor sidecar stays blocked" "$legacy_record_rc" "1"
check "legacy failed record stays preserved" "$(test -s "$tmp/legacy-record.pid" && echo preserved || echo missing)" "preserved"
check "legacy record diagnostic names manual recovery path" "$(grep -Fc 'legacy pre-r14 record); manual recovery required' "$tmp/legacy-record.stderr" 2>/dev/null)" "1"

# HIMMEL-1474 r8: terminate rc 2 means no signal was sent. Execute the
# production timeout-classification/cleanup block and prove its recovery
# handles survive instead of being erased as though the render had exited.
harvest_timeout_extract_rc=0
harvest_timeout_block=$(awk '
    /harvest_timed_out=0/ { capture=1 }
    capture {
        raw=$0
        sub(/^       /, "")
        print
        if (raw ~ /^       if \[ "\$harvest_live_unreaped" -eq 0 \] && \[ "\$harvest_survivors" -eq 0 \] && \[ "\$harvest_cleanup_unverified" -eq 0 \]; then/) cleanup=1
        else if (cleanup && raw == "       fi") { complete=1; exit }
    }
    END { if (!complete) exit 42 }
' "$PR_CHECK") || harvest_timeout_extract_rc=$?
check "harvest-timeout extractor reaches the cleanup block terminator" "$harvest_timeout_extract_rc" "0"
printf '%s\n' 424242 > "$tmp/harvest-live.pid"
printf '%s\n' test-identity > "$tmp/harvest-live.pid.identity"
rm -f "$tmp/harvest-live.rc"
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
harvest_live_result=$(
    codex_pid=424242
    codex_identity=test-identity
    codex_pid_file="$tmp/harvest-live.pid"
    codex_identity_file="$tmp/harvest-live.pid.identity"
    codex_survivors_file="$tmp/harvest-live.pid.survivors"
    codex_rc_file="$tmp/harvest-live.rc"
    codex_err_file="$tmp/harvest-live.err"
    codex_out="$tmp/harvest-live.out"
    codex_to=5
    waited=5
    codex_findings=stale
    codex_rc=0
    codex_avail_status=''
    proc_tree_terminate() { return 2; }
    eval "$harvest_timeout_block" 2>"$tmp/harvest-live.stderr"
    printf '%s:%s:%s:%s\n' "$harvest_live_unreaped" "$harvest_timed_out" "$codex_rc" "$codex_avail_status"
)
check "terminate-rc-2 harvest is live-but-unreaped" "$harvest_live_result" "1:0:2:unavailable"
check "live-but-unreaped harvest preserves pid sidecar" "$(test -s "$tmp/harvest-live.pid" && echo preserved || echo missing)" "preserved"
check "live-but-unreaped harvest preserves identity sidecar" "$(test -s "$tmp/harvest-live.pid.identity" && echo preserved || echo missing)" "preserved"
harvest_live_diagnostic=$(grep -Fc "live but unreaped" "$tmp/harvest-live.stderr" 2>/dev/null)
check "live-but-unreaped harvest reports distinct state" "$harvest_live_diagnostic" "1"
harvest_preserve_diagnostic=$(grep -Fc "because no signal was sent" "$tmp/harvest-live.stderr" 2>/dev/null)
check "live-but-unreaped harvest explains preserved handles" "$harvest_preserve_diagnostic" "1"

# HIMMEL-1474 r9: terminate rc 1 means escalated cleanup left survivors. The
# gate remains a timeout while its recovery handles stay available.
printf '%s\n' 424243 > "$tmp/harvest-survivors.pid"
printf '%s\n' test-identity > "$tmp/harvest-survivors.pid.identity"
rm -f "$tmp/harvest-survivors.rc"
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
harvest_survivors_result=$(
    codex_pid=424243
    codex_identity=test-identity
    codex_pid_file="$tmp/harvest-survivors.pid"
    codex_identity_file="$tmp/harvest-survivors.pid.identity"
    codex_survivors_file="$tmp/harvest-survivors.pid.survivors"
    codex_rc_file="$tmp/harvest-survivors.rc"
    codex_err_file="$tmp/harvest-survivors.err"
    codex_out="$tmp/harvest-survivors.out"
    codex_to=5
    waited=5
    codex_findings=stale
    codex_rc=0
    codex_avail_status=''
    proc_tree_terminate() { return 1; }
    eval "$harvest_timeout_block" 2>"$tmp/harvest-survivors.stderr"
    printf '%s:%s:%s:%s\n' "$harvest_live_unreaped" "$harvest_timed_out" "$codex_rc" "$codex_avail_status"
)
check "terminate-rc-1 harvest remains a timeout" "$harvest_survivors_result" "0:1:124:unavailable"
check "terminate-rc-1 harvest preserves pid sidecar" "$(test -s "$tmp/harvest-survivors.pid" && echo preserved || echo missing)" "preserved"
check "terminate-rc-1 harvest preserves identity sidecar" "$(test -s "$tmp/harvest-survivors.pid.identity" && echo preserved || echo missing)" "preserved"
harvest_survivors_diagnostic=$(grep -Fc "survivors after escalated cleanup — sidecars preserved for recovery" "$tmp/harvest-survivors.stderr" 2>/dev/null)
check "terminate-rc-1 harvest reports preserved recovery sidecars" "$harvest_survivors_diagnostic" "1"

# HIMMEL-1501: terminate rc 3 means the leader was CONFIRMED already
# exited/recycled before any signal was sent. Unlike rc 2, this must NOT be
# classified as live-but-unreaped -- it falls through to the ordinary
# "exited" harvest path below, and once the launcher's own rc/cleanup status
# lands (simulated here via the rc_wait poll, same as the real "a beat
# later" race the production code documents), sidecars are removed rather
# than preserved.
printf '%s\n' 424244 > "$tmp/harvest-confirmed-gone.pid"
printf '%s\n' test-identity > "$tmp/harvest-confirmed-gone.pid.identity"
rm -f "$tmp/harvest-confirmed-gone.rc" "$tmp/harvest-confirmed-gone.pid.cleanup-rc" "$tmp/harvest-confirmed-gone.pid.survivors" "$tmp/harvest-confirmed-gone-killed" "$tmp/harvest-confirmed-gone-signals"
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
harvest_confirmed_gone_result=$(
    codex_pid=424244
    codex_identity=test-identity
    codex_pid_file="$tmp/harvest-confirmed-gone.pid"
    codex_identity_file="$tmp/harvest-confirmed-gone.pid.identity"
    codex_survivors_file="$tmp/harvest-confirmed-gone.pid.survivors"
    codex_rc_file="$tmp/harvest-confirmed-gone.rc"
    codex_cleanup_rc_file="$tmp/harvest-confirmed-gone.pid.cleanup-rc"
    codex_err_file="$tmp/harvest-confirmed-gone.err"
    codex_out="$tmp/harvest-confirmed-gone.out"
    codex_to=5
    waited=5
    codex_findings=stale
    codex_rc=0
    codex_avail_status=''
    proc_tree_terminate() { return 3; }
    proc_tree_process_identity_matches() {
        [ "$1" = "5155" ] && [ "$2" = "test-identity" ] && [ ! -e "$tmp/harvest-confirmed-gone-killed" ]
    }
    proc_tree_process_alive() { [ "$1" = "5155" ] && [ ! -e "$tmp/harvest-confirmed-gone-killed" ]; }
    kill() {
        printf '%s:%s\n' "$1" "$2" >> "$tmp/harvest-confirmed-gone-signals"
        [ "$1" != "-TERM" ] || : > "$tmp/harvest-confirmed-gone-killed"
        return 0
    }
    # shellcheck disable=SC2329  # invoked indirectly by the harvest's rc_wait poll
    sleep() {
        printf '%s\n' 1 > "$codex_rc_file"
        printf '5155\ttest-identity\n' > "$codex_survivors_file"
        printf '%s\n' 3 > "$codex_cleanup_rc_file"
    }
    eval "$harvest_timeout_block" 2>"$tmp/harvest-confirmed-gone.stderr"
    printf '%s:%s:%s:%s\n' "$harvest_live_unreaped" "$harvest_timed_out" "$codex_rc" "$codex_avail_status"
)
check "terminate-rc-3 harvest is NOT live-but-unreaped" "$harvest_confirmed_gone_result" "0:0:1:unavailable"
check "confirmed-gone harvest resolves survivor anchor" "$(grep -Fc -- '-TERM:5155' "$tmp/harvest-confirmed-gone-signals" 2>/dev/null)" "1"
check "confirmed-gone harvest removes pid sidecar" "$(test -e "$tmp/harvest-confirmed-gone.pid" && echo preserved || echo cleared)" "cleared"
check "confirmed-gone harvest removes identity sidecar" "$(test -e "$tmp/harvest-confirmed-gone.pid.identity" && echo preserved || echo cleared)" "cleared"
check "confirmed-gone harvest removes survivor sidecar" "$(test -e "$tmp/harvest-confirmed-gone.pid.survivors" && echo preserved || echo cleared)" "cleared"
harvest_confirmed_gone_diagnostic=$(grep -Fc "live but unreaped" "$tmp/harvest-confirmed-gone.stderr" 2>/dev/null)
check "confirmed-gone harvest never reports live-but-unreaped" "$harvest_confirmed_gone_diagnostic" "0"

# HIMMEL-1474 r12: cleanup is removable only after BOTH launcher status and a
# zero cleanup status exist. A killed-pre-write launcher and a late cleanup
# publication each preserve the ownership handles.
printf '%s\n' 424246 > "$tmp/harvest-no-rc.pid"
printf '%s\n' test-identity > "$tmp/harvest-no-rc.pid.identity"
printf '%s\n' 0 > "$tmp/harvest-no-rc.pid.cleanup-rc"
rm -f "$tmp/harvest-no-rc.rc"
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
harvest_no_rc_result=$(
    codex_pid=424246
    codex_identity=test-identity
    codex_pid_file="$tmp/harvest-no-rc.pid"
    codex_identity_file="$tmp/harvest-no-rc.pid.identity"
    codex_survivors_file="$tmp/harvest-no-rc.pid.survivors"
    codex_rc_file="$tmp/harvest-no-rc.rc"
    codex_cleanup_rc_file="$tmp/harvest-no-rc.pid.cleanup-rc"
    codex_err_file="$tmp/harvest-no-rc.err"
    codex_out="$tmp/harvest-no-rc.out"
    codex_to=5
    waited=0
    codex_findings=stale
    codex_rc=0
    codex_avail_status=''
    sleep() { :; }
    eval "$harvest_timeout_block" 2>"$tmp/harvest-no-rc.stderr"
    printf '%s:%s:%s\n' "$harvest_cleanup_unverified" "$codex_rc" "$codex_avail_status"
)
check "missing launcher rc marks cleanup unverified" "$harvest_no_rc_result" "1:1:unavailable"
check "missing launcher rc preserves pid sidecar" "$(test -s "$tmp/harvest-no-rc.pid" && echo preserved || echo missing)" "preserved"
check "missing launcher rc preserves identity sidecar" "$(test -s "$tmp/harvest-no-rc.pid.identity" && echo preserved || echo missing)" "preserved"
check "missing launcher rc preserves cleanup status" "$(cat "$tmp/harvest-no-rc.pid.cleanup-rc" 2>/dev/null)" "0"
no_rc_diagnostic=$(grep -Fc "launcher status missing" "$tmp/harvest-no-rc.stderr" 2>/dev/null)
check "missing launcher rc reports preserved handles" "$no_rc_diagnostic" "1"

printf '%s\n' 424247 > "$tmp/harvest-late-cleanup.pid"
printf '%s\n' test-identity > "$tmp/harvest-late-cleanup.pid.identity"
printf '%s\n' 7 > "$tmp/harvest-late-cleanup.rc"
rm -f "$tmp/harvest-late-cleanup.pid.cleanup-rc"
# shellcheck disable=SC2034,SC2154
harvest_late_cleanup_result=$(
    codex_pid=424247
    codex_identity=test-identity
    codex_pid_file="$tmp/harvest-late-cleanup.pid"
    codex_identity_file="$tmp/harvest-late-cleanup.pid.identity"
    codex_survivors_file="$tmp/harvest-late-cleanup.pid.survivors"
    codex_rc_file="$tmp/harvest-late-cleanup.rc"
    codex_cleanup_rc_file="$tmp/harvest-late-cleanup.pid.cleanup-rc"
    codex_err_file="$tmp/harvest-late-cleanup.err"
    codex_out="$tmp/harvest-late-cleanup.out"
    codex_to=5
    waited=0
    codex_findings=stale
    codex_rc=0
    codex_avail_status=''
    eval "$harvest_timeout_block" 2>"$tmp/harvest-late-cleanup.stderr"
    printf '%s:%s:%s\n' "$harvest_cleanup_unverified" "$codex_rc" "$codex_avail_status"
)
check "late cleanup status marks cleanup unverified" "$harvest_late_cleanup_result" "1:7:unavailable"
check "late cleanup status preserves pid sidecar" "$(test -s "$tmp/harvest-late-cleanup.pid" && echo preserved || echo missing)" "preserved"
check "late cleanup status preserves identity sidecar" "$(test -s "$tmp/harvest-late-cleanup.pid.identity" && echo preserved || echo missing)" "preserved"
late_cleanup_diagnostic=$(grep -Fc "cleanup unverified (rc=missing)" "$tmp/harvest-late-cleanup.stderr" 2>/dev/null)
check "late cleanup status reports missing cleanup rc" "$late_cleanup_diagnostic" "1"

# HIMMEL-1474 r10/r12: the synchronous retry owns distinct recovery sidecars. Its
# timeout status remains 124 while cleanup rc 1/2 and both handles survive.
# shellcheck disable=SC2016
retry_pid_wiring=$(grep -Fc 'codex_retry_pid_file="${codex_pid_file}.retry"' "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest share the dedicated retry pid sidecar" "$retry_pid_wiring" "2"
# shellcheck disable=SC2016
retry_survivors_wiring=$(grep -Fc 'codex_retry_survivors_file="${codex_retry_pid_file}.survivors"' "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest share the dedicated retry survivor sidecar" "$retry_survivors_wiring" "2"
# shellcheck disable=SC2016
retry_launcher_wiring=$(grep -Fc '"$codex_retry_pid_file" "$codex_timeout" "$codex_retry_cleanup_rc_file"' "$PR_CHECK" 2>/dev/null)
check "production retry passes its pid and cleanup sidecars to the launcher" "$retry_launcher_wiring" "1"
# shellcheck disable=SC2016
primary_cleanup_wiring=$(grep -Fc 'codex_cleanup_rc_file="${codex_pid_file}.cleanup-rc"' "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest derive primary cleanup status from its pid record" "$primary_cleanup_wiring" "2"
# shellcheck disable=SC2016
retry_cleanup_wiring=$(grep -Fc 'codex_retry_cleanup_rc_file="${codex_retry_pid_file}.cleanup-rc"' "$PR_CHECK" 2>/dev/null)
check "kickoff and harvest derive retry cleanup status from its pid record" "$retry_cleanup_wiring" "2"
for retry_cleanup_rc in 1 2; do
    rm -f "$tmp/retry-$retry_cleanup_rc.pid" "$tmp/retry-$retry_cleanup_rc.pid.identity" "$tmp/retry-$retry_cleanup_rc.pid.cleanup-rc"
    runner_rc=0
    HIMMEL_R6_TERMINATE_RC="$retry_cleanup_rc" \
        bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-delayed.mjs" main "$tmp/retry-$retry_cleanup_rc.stdout" "$tmp/retry-$retry_cleanup_rc.stderr" "$tmp/retry-$retry_cleanup_rc.pid" 1 "$tmp/retry-$retry_cleanup_rc.pid.cleanup-rc" 2>"$tmp/retry-$retry_cleanup_rc-runner.stderr" || runner_rc=$?
    check "retry-shaped cleanup rc $retry_cleanup_rc keeps exit 124" "$runner_rc" "124"
    check "retry-shaped cleanup rc $retry_cleanup_rc publishes record cleanup status" "$(cat "$tmp/retry-$retry_cleanup_rc.pid.cleanup-rc" 2>/dev/null)" "$retry_cleanup_rc"
    check "retry-shaped cleanup rc $retry_cleanup_rc preserves pid sidecar" "$(test -s "$tmp/retry-$retry_cleanup_rc.pid" && echo preserved || echo missing)" "preserved"
    check "retry-shaped cleanup rc $retry_cleanup_rc preserves identity sidecar" "$(test -s "$tmp/retry-$retry_cleanup_rc.pid.identity" && echo preserved || echo missing)" "preserved"
    retry_pid=$(cat "$tmp/retry-$retry_cleanup_rc.pid")
    kill -9 "$retry_pid" 2>/dev/null || true
    if command -v taskkill >/dev/null 2>&1; then
        MSYS_NO_PATHCONV=1 taskkill /PID "$retry_pid" /T /F >/dev/null 2>&1 || true
    fi
done

# Companion failure keeps its own rc, while the independent cleanup status lets
# harvest preserve recovery handles for cleanup rc 1/2 instead of deleting them.
for companion_cleanup_rc in 1 2; do
    companion_prefix="$tmp/companion-cleanup-$companion_cleanup_rc"
    rm -f "$companion_prefix.pid" "$companion_prefix.pid.identity" "$companion_prefix.rc" "$companion_prefix.pid.cleanup-rc"
    runner_rc=0
    HIMMEL_R6_GROUP_TERMINATE_RC="$companion_cleanup_rc" \
        bash "$tmp/lease-fixture/cr/run-codex-adversarial.sh" "$tmp/lease-fixture/companion-fails.mjs" main "$companion_prefix.stdout" "$companion_prefix.stderr" "$companion_prefix.pid" 0 "$companion_prefix.pid.cleanup-rc" 2>"$companion_prefix-runner.stderr" || runner_rc=$?
    check "companion rc wins over cleanup rc $companion_cleanup_rc" "$runner_rc" "7"
    check "companion failure publishes cleanup rc $companion_cleanup_rc" "$(cat "$companion_prefix.pid.cleanup-rc" 2>/dev/null)" "$companion_cleanup_rc"
    printf '%s\n' "$runner_rc" > "$companion_prefix.rc"
    # shellcheck disable=SC2034,SC2154
    companion_harvest_result=$(
        codex_pid=$(cat "$companion_prefix.pid")
        codex_identity=$(cat "$companion_prefix.pid.identity")
        codex_pid_file="$companion_prefix.pid"
        codex_identity_file="$companion_prefix.pid.identity"
        codex_survivors_file="$companion_prefix.pid.survivors"
        codex_rc_file="$companion_prefix.rc"
        codex_cleanup_rc_file="$companion_prefix.pid.cleanup-rc"
        codex_err_file="$companion_prefix.stderr"
        codex_out="$companion_prefix.stdout"
        codex_to=5
        waited=0
        codex_findings=stale
        codex_rc=0
        codex_avail_status=''
        eval "$harvest_timeout_block" 2>"$companion_prefix-harvest.stderr"
        printf '%s:%s:%s\n' "$harvest_cleanup_unverified" "$codex_rc" "$codex_avail_status"
    )
    check "harvest sees companion cleanup rc $companion_cleanup_rc" "$companion_harvest_result" "1:7:unavailable"
    check "companion cleanup rc $companion_cleanup_rc preserves pid sidecar" "$(test -s "$companion_prefix.pid" && echo preserved || echo missing)" "preserved"
    check "companion cleanup rc $companion_cleanup_rc preserves identity sidecar" "$(test -s "$companion_prefix.pid.identity" && echo preserved || echo missing)" "preserved"
    check "companion cleanup rc $companion_cleanup_rc preserves cleanup status" "$(cat "$companion_prefix.pid.cleanup-rc" 2>/dev/null)" "$companion_cleanup_rc"
done

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
