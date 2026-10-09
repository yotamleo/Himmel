#!/usr/bin/env bash
# test-ci-runner.sh — hermetic suite for the HIMMEL-5037 self-hosted runner
# tooling: the guest job-started fork guard, the host loop's preflight, kill
# switch and JIT-config handling, and the guest provisioner's bare-metal
# refusal. No VirtualBox, no network: gh, ssh and the VM lib are stubs.
#
# Platform guard (linux-only): the runner tooling it tests drives VirtualBox
# on the Linux station and provisions an Ubuntu guest.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/vm/ci-runner/job-started-hook.sh"
LOOP="$REPO_ROOT/scripts/vm/ci-runner.sh"
PROVISION="$REPO_ROOT/scripts/vm/ci-runner/guest-provision.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-ci-runner.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

# --- the job-started fork guard -------------------------------------------
# hook_case <label> <want-rc> <event-name> <ref> <event-json>
hook_case() {
    local label="$1" want="$2" ev="$3" ref="$4" json="$5" rc
    printf '%s' "$json" > "$TMP/event.json"
    GITHUB_EVENT_NAME="$ev" GITHUB_REF="$ref" GITHUB_REPOSITORY="yotamleo/Himmel" \
        GITHUB_ACTOR="${HOOK_ACTOR-yotamleo}" GITHUB_TRIGGERING_ACTOR="${HOOK_TRIG-yotamleo}" \
        GITHUB_EVENT_PATH="$TMP/event.json" HIMMEL_CI_RUNNER_REPO="yotamleo/Himmel" \
        bash "$HOOK" >"$TMP/hook.out" 2>&1
    rc=$?
    if [ "$rc" = "$want" ]; then
        ok "hook: $label (rc=$rc)"
    else
        bad "hook: $label (want $want, got rc=$rc): $(cat "$TMP/hook.out")"
    fi
}

echo "T1 job-started fork guard"
same='{"pull_request":{"user":{"login":"yotamleo"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"yotamleo"}}'
fork='{"pull_request":{"head":{"repo":{"full_name":"mallory/Himmel"}}}}'
hook_case "same-repo PR runs"            0 pull_request refs/pull/1/merge "$same"
hook_case "fork PR refused"              1 pull_request refs/pull/1/merge "$fork"
# 5070(a): the PR author and the event sender must be operator accounts too.
dep='{"pull_request":{"user":{"login":"dependabot[bot]"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"yotamleo"}}'
own='{"pull_request":{"user":{"login":"yotamleo"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"yotamleo"}}'
hook_case "owner re-run of a third-party PR refused" 1 pull_request refs/pull/1/merge "$dep"
hook_case "owner PR with owner sender runs"          0 pull_request refs/pull/1/merge "$own"
hook_case "PR with a non-owner sender refused"       1 pull_request refs/pull/1/merge '{"pull_request":{"user":{"login":"yotamleo"},"head":{"repo":{"full_name":"yotamleo/Himmel"}}},"sender":{"login":"mallory"}}'
hook_case "PR with no head repo refused" 1 pull_request refs/pull/1/merge '{"pull_request":{}}'
hook_case "push to main runs"            0 push refs/heads/main '{}'
hook_case "push to a branch refused"     1 push refs/heads/feat/x '{}'
hook_case "pull_request_target refused"  1 pull_request_target refs/heads/main "$same"
hook_case "workflow_dispatch runs"       0 workflow_dispatch refs/heads/main '{}'
hook_case "schedule runs"                0 schedule refs/heads/main '{}'
# R3: workflow_dispatch and same-repo PRs run only for the operator's accounts.
HOOK_ACTOR=mallory HOOK_TRIG=mallory hook_case "dispatch by a non-owner refused" 1 workflow_dispatch refs/heads/main '{}'
HOOK_ACTOR=mallory HOOK_TRIG=mallory hook_case "same-repo PR by a non-owner refused" 1 pull_request refs/pull/1/merge "$same"
HOOK_ACTOR=yotamleo11-test HOOK_TRIG=yotamleo11-test hook_case "same-repo PR by the test account runs" 0 pull_request refs/pull/1/merge "$same"
HOOK_ACTOR=yotamleo HOOK_TRIG=mallory hook_case "dispatch re-run by a non-owner refused" 1 workflow_dispatch refs/heads/main '{}'
HOOK_ACTOR='' HOOK_TRIG='' hook_case "dispatch with no actor refused" 1 workflow_dispatch refs/heads/main '{}'
HOOK_ACTOR=mallory HOOK_TRIG=mallory hook_case "push to main needs no owner" 0 push refs/heads/main '{}'
# The repository itself must be the pinned one, whatever the event says.
printf '%s' "$same" > "$TMP/event.json"
GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/1/merge GITHUB_REPOSITORY=mallory/Himmel \
    GITHUB_EVENT_PATH="$TMP/event.json" HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel \
    bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "hook: other repository refused"; else bad "hook: other repository (rc=$rc)"; fi
GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=yotamleo/Himmel \
    GITHUB_EVENT_PATH="$TMP/missing.json" HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel \
    bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "hook: missing event file refused"; else bad "hook: missing event file (rc=$rc)"; fi

# --- host loop stubs ------------------------------------------------------
# gh stub: answers the three reads the loop makes and logs every call's argv.
# GH_APPROVAL / GH_KILL steer the fork-approval policy and the kill-switch var.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/gh.argv"
case "$*" in
    *fork-pr-contributor-approval*) echo "${GH_APPROVAL:-all_external_contributors}" ;;
    *actions/variables/HIMMEL_VM_RUNNER*)
        [ -n "${GH_KILL:-}" ] || exit 1
        if [ -e "$STUB_LOG/kill-off" ]; then echo off; else echo "$GH_KILL"; fi ;;
    *generate-jitconfig*) printf '%s\n%s\n' 4242 "JITSECRET-not-for-argv" ;;
    *"-X DELETE"*) : > "$STUB_LOG/deleted"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
# VM lib stub: records which primitives ran; vm_ssh logs its argv and stdin.
cat > "$TMP/vmlib.sh" <<'EOF'
vm_env_init()  { :; }
vm_lock_acquire_waiting() { :; }
vm_lock_release() { echo "release" >> "$STUB_LOG/vm.calls"; }
vm_restore()   { echo "restore $1" >> "$STUB_LOG/vm.calls"; PORT=2299; }
vm_boot()      { echo "boot" >> "$STUB_LOG/vm.calls"; }
vm_poweroff()  { echo "poweroff" >> "$STUB_LOG/vm.calls"; return "${STUB_POWEROFF_RC:-0}"; }
nat_localhost_off() { echo "nat-localhost-off" >> "$STUB_LOG/vm.calls"; }
clipboard_dnd_off() { echo "clipboard-dnd-off" >> "$STUB_LOG/vm.calls"; }
clipboard_dnd_disabled() { [ -z "${STUB_CLIPBOARD_ON:-}" ]; }
localhost_unreachable() { [ -z "${STUB_LOCALHOST_REACHABLE:-}" ]; }
vm_ssh() {
    printf '%s\n' "$*" >> "$STUB_LOG/ssh.argv"; cat >> "$STUB_LOG/ssh.stdin"
    case "$*" in *"nft list table inet himmel_egress"*) [ -z "${STUB_NO_EGRESS:-}" ]; return ;; esac
    [ -n "${STUB_SSH_HARD_SLEEP:-}" ] && case "$*" in *himmel-ci-run-job*) sleep "$STUB_SSH_HARD_SLEEP" ;; esac
    if [ -n "${STUB_SSH_SLEEP:-}" ]; then
        for _ in $(seq 1 $((STUB_SSH_SLEEP * 5))); do [ -e "$STUB_LOG/deleted" ] && break; sleep 0.2; done
    fi
    return "${STUB_SSH_RC:-0}"
}
EOF

run_loop() {
    STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
        HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
        bash "$LOOP" "$@"
}
reset_log() { rm -rf "$TMP/log"; mkdir -p "$TMP/log"; : > "$TMP/log/gh.argv"; }

echo "T2 preflight refuses a weaker fork-approval policy"
reset_log
GH_APPROVAL=first_time_contributors GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && [ ! -s "$TMP/log/vm.calls" ]; then
    ok "weaker policy: refused before any VM or mint (rc=$rc)"
else
    bad "weaker policy: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T3 kill switch"
for k in off "" ; do
    reset_log
    GH_KILL="$k" run_loop run --once >"$TMP/out" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && [ ! -s "$TMP/log/vm.calls" ]; then
        ok "variable '${k:-unset}': exits 0, mints nothing, boots nothing"
    else
        bad "variable '${k:-unset}': rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
    fi
done
reset_log
: > "$TMP/stop"
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
rm -f "$TMP/stop"
if [ "$rc" -eq 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv"; then
    ok "local stop file: exits 0, mints nothing"
else
    bad "local stop file: rc=$rc"
fi

echo "T4 one job: restore, boot, JIT config on stdin only, deregister, power off"
reset_log
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "run --once exits 0"; else bad "run --once rc=$rc: $(cat "$TMP/out")"; fi
if [ "$(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)" = "restore ci-runner-v1|nat-localhost-off|clipboard-dnd-off|boot|poweroff|release|" ]; then
    ok "restored ci-runner-v1, hid the station loopback, turned clipboard and drag-and-drop off, booted, powered off, released the lock"
else
    bad "vm calls: $(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)"
fi
if grep -q "JITSECRET" "$TMP/log/ssh.stdin" 2>/dev/null; then
    ok "JIT config reached the guest on stdin"
else
    bad "JIT config never reached the guest"
fi
grep -q "JITSECRET" "$TMP/log/ssh.argv" "$TMP/log/gh.argv" "$TMP/out"
rc=$?
case "$rc" in
    1) ok "JIT config absent from every argv and the output" ;;
    0) bad "JIT config leaked into an argv or the log" ;;
    *) bad "leak scan could not read its inputs (grep rc=$rc)" ;;
esac
if grep -q -- "generate-jitconfig" "$TMP/log/gh.argv" && grep -q "labels\[\]=himmel-vm" "$TMP/log/gh.argv"; then
    ok "minted a repo-level JIT runner labelled himmel-vm"
else
    bad "mint call: $(grep jit "$TMP/log/gh.argv")"
fi
if grep -q -- "-X DELETE repos/yotamleo/Himmel/actions/runners/4242" "$TMP/log/gh.argv"; then
    ok "runner 4242 deregistered after the job"
else
    bad "no deregister: $(tr '\n' '|' < "$TMP/log/gh.argv")"
fi
grep -rq "JITSECRET" "$TMP" --exclude-dir=log --exclude-dir=bin --exclude=out --exclude=hook.out
rc=$?
case "$rc" in
    1) ok "JIT config written to no file" ;;
    0) bad "JIT config written to a file" ;;
    *) bad "file leak scan could not read the tree (grep rc=$rc)" ;;
esac

echo "T4b an image that reaches the station loopback refuses to serve"
reset_log
STUB_LOCALHOST_REACHABLE=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "station loopback" "$TMP/out"; then
    ok "loopback-reachable image: refused before mint (rc=$rc)"
else
    bad "loopback-reachable image: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T4g R1: a restore with the clipboard or drag-and-drop on refuses to serve"
reset_log
STUB_CLIPBOARD_ON=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "clipboard" "$TMP/out"; then
    ok "clipboard on after restore: refused before mint (rc=$rc)"
else
    bad "clipboard on: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T4h R2: a boot without the himmel_egress table refuses to mint"
reset_log
STUB_NO_EGRESS=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "himmel_egress" "$TMP/out" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "no egress table in the guest: refused before mint, VM powered off (rc=$rc)"
else
    bad "no egress table: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi
grep -q "nft list table inet himmel_egress" "$TMP/log/ssh.argv" 2>/dev/null || bad "egress check never ran"
# 5070(b): the per-boot check asks for every private-range reject, not just the LAN one.
reset_log
GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
for r in '10\.0\.0\.0/8' '172\.16\.0\.0/12' '192\.168\.0\.0/16' '169\.254\.0\.0/16' '100\.64\.0\.0/10'; do
    if grep -q -- "$r" "$TMP/log/ssh.argv" 2>/dev/null; then ok "egress check requires reject of $r"; else bad "egress check ignores $r"; fi
done

echo "T4i R5: off during the job wait deregisters the idle runner promptly"
reset_log
STUB_SSH_SLEEP=20 GH_KILL=on STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
    HIMMEL_CI_RUNNER_WATCH_SECS=1 HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
    bash "$LOOP" run --once >"$TMP/out" 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do grep -q himmel-ci-run-job "$TMP/log/ssh.argv" 2>/dev/null && break; sleep 0.2; done
t0=$SECONDS
: > "$TMP/log/kill-off"
wait "$loop_pid"
rc=$?
if [ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -lt 10 ] && [ "$(grep -c -- "-X DELETE" "$TMP/log/gh.argv")" = 1 ]; then
    ok "off: runner deregistered once within $((SECONDS - t0))s, loop ended (rc=$rc)"
else
    bad "off during wait: rc=$rc after $((SECONDS - t0))s, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

echo "T4i2 5070(d): a guest that outlives the deregistration does not hold the loop"
reset_log
STUB_SSH_HARD_SLEEP=25 GH_KILL=on STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
    HIMMEL_CI_RUNNER_WATCH_SECS=1 HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
    bash "$LOOP" run --once >"$TMP/out" 2>&1 &
loop_pid=$!
for _ in $(seq 1 50); do grep -q himmel-ci-run-job "$TMP/log/ssh.argv" 2>/dev/null && break; sleep 0.2; done
t0=$SECONDS
: > "$TMP/log/kill-off"
wait "$loop_pid"
rc=$?
if [ "$rc" -eq 0 ] && [ $((SECONDS - t0)) -lt 10 ]; then
    ok "idle deregistration ends the loop within $((SECONDS - t0))s"
else
    bad "loop held $((SECONDS - t0))s after deregistration (rc=$rc)"
fi

echo "T4c a failed guest job fails run --once, and still cleans up"
reset_log
STUB_SSH_RC=7 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 7 ] && grep -q -- "-X DELETE" "$TMP/log/gh.argv" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "guest job rc=7 propagated; runner deregistered, VM powered off"
else
    bad "failed job: rc=$rc, vm=$(tr '\n' '|' < "$TMP/log/vm.calls")"
fi

echo "T4d a power-off that fails keeps the vm-lock"
reset_log
STUB_POWEROFF_RC=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -qx release "$TMP/log/vm.calls" && grep -q "still running" "$TMP/out"; then
    ok "power-off failure: lock kept, run fails (rc=$rc)"
else
    bad "power-off failure: rc=$rc, vm=$(tr '\n' '|' < "$TMP/log/vm.calls")"
fi

echo "T4e SIGTERM mid-job still deregisters and powers off"
reset_log
# Not through run_loop: $! must be the loop's own pid, not a wrapper subshell's.
STUB_SSH_SLEEP=5 GH_KILL=on STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" CI_RUNNER_VM_LIB="$TMP/vmlib.sh" \
    HIMMEL_CI_RUNNER_REPO=yotamleo/Himmel HIMMEL_CI_RUNNER_STOP_FILE="$TMP/stop" \
    bash "$LOOP" run --once >"$TMP/out" 2>&1 &
loop_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q himmel-ci-run-job "$TMP/log/ssh.argv" 2>/dev/null && break
    sleep 0.2
done
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid"
rc=$?
if [ "$rc" -ne 0 ] && grep -q -- "-X DELETE" "$TMP/log/gh.argv" && grep -qx poweroff "$TMP/log/vm.calls"; then
    ok "SIGTERM: runner deregistered, VM powered off (rc=$rc)"
else
    bad "SIGTERM: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv"), vm=$(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)"
fi

echo "T4f a zero or non-numeric job bound is refused before any mint"
for m in 0 abc; do
    reset_log
    HIMMEL_CI_RUNNER_JOB_MAX="$m" GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
    rc=$?
    if [ "$rc" -eq 2 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv"; then
        ok "JOB_MAX='$m' refused (rc=$rc)"
    else
        bad "JOB_MAX='$m': rc=$rc"
    fi
done

echo "T5 guest provisioner refuses bare metal"
cat > "$TMP/bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo none; exit 1
EOF
chmod +x "$TMP/bin/systemd-detect-virt"
PATH="$TMP/bin:$PATH" bash "$PROVISION" >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && grep -q "not a VM" "$TMP/out"; then
    ok "bare metal refused (rc=$rc)"
else
    bad "bare metal: rc=$rc: $(cat "$TMP/out")"
fi

echo "T6 R1/R6 static: image purges guest utils, build disables clipboard before the snapshot, no jitconfig argv"
if grep -q 'apt-get purge.*virtualbox-guest-utils' "$PROVISION"; then ok "provisioner removes virtualbox-guest-utils"; else bad "provisioner keeps virtualbox-guest-utils"; fi
bstart=$(grep -n '^build()' "$LOOP" | cut -d: -f1)
# shellcheck disable=SC2016 # literal text to find in ci-runner.sh
tline=$(grep -n 'take "$RUNNER_SNAPSHOT"' "$LOOP" | head -1 | cut -d: -f1)
if [ -n "$bstart" ] && [ -n "$tline" ] && sed -n "${bstart},${tline}p" "$LOOP" | grep -q '^[[:space:]]*clipboard_dnd_off'; then
    ok "build turns clipboard and drag-and-drop off before the snapshot"
else
    bad "build does not disable clipboard before snapshotting"
fi
wrapper=$(sed -n '/^cat > \/usr\/local\/sbin\/himmel-ci-run-job/,/^EOF/p' "$PROVISION")
if ! printf '%s\n' "$wrapper" | grep -v '^#' | grep -q -- '--jitconfig' && printf '%s\n' "$wrapper" | grep -q ACTIONS_RUNNER_INPUT_JITCONFIG; then
    ok "run-job wrapper hands the JIT config over by environment, not argv"
else
    bad "run-job wrapper still passes --jitconfig in argv"
fi

echo
echo "test-ci-runner: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
