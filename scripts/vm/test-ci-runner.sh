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

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
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
same='{"pull_request":{"head":{"repo":{"full_name":"yotamleo/Himmel"}}}}'
fork='{"pull_request":{"head":{"repo":{"full_name":"mallory/Himmel"}}}}'
hook_case "same-repo PR runs"            0 pull_request refs/pull/1/merge "$same"
hook_case "fork PR refused"              1 pull_request refs/pull/1/merge "$fork"
hook_case "PR with no head repo refused" 1 pull_request refs/pull/1/merge '{"pull_request":{}}'
hook_case "push to main runs"            0 push refs/heads/main '{}'
hook_case "push to a branch refused"     1 push refs/heads/feat/x '{}'
hook_case "pull_request_target refused"  1 pull_request_target refs/heads/main "$same"
hook_case "workflow_dispatch runs"       0 workflow_dispatch refs/heads/main '{}'
hook_case "schedule runs"                0 schedule refs/heads/main '{}'
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
        echo "$GH_KILL" ;;
    *generate-jitconfig*) printf '%s\n%s\n' 4242 "JITSECRET-not-for-argv" ;;
    *"-X DELETE"*) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
# VM lib stub: records which primitives ran; vm_ssh logs its argv and stdin.
cat > "$TMP/vmlib.sh" <<'EOF'
vm_env_init()  { :; }
vm_lock_acquire_waiting() { :; }
vm_lock_release() { :; }
vm_restore()   { echo "restore $1" >> "$STUB_LOG/vm.calls"; PORT=2299; }
vm_boot()      { echo "boot" >> "$STUB_LOG/vm.calls"; }
vm_poweroff()  { echo "poweroff" >> "$STUB_LOG/vm.calls"; }
nat_localhost_off() { echo "nat-localhost-off" >> "$STUB_LOG/vm.calls"; }
localhost_unreachable() { [ -z "${STUB_LOCALHOST_REACHABLE:-}" ]; }
vm_ssh()       { printf '%s\n' "$*" >> "$STUB_LOG/ssh.argv"; cat >> "$STUB_LOG/ssh.stdin"; }
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
if [ "$(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)" = "restore ci-runner-v1|nat-localhost-off|boot|poweroff|" ]; then
    ok "restored ci-runner-v1, hid the station loopback, booted, powered off"
else
    bad "vm calls: $(tr '\n' '|' < "$TMP/log/vm.calls" 2>/dev/null)"
fi
if grep -q "JITSECRET" "$TMP/log/ssh.stdin" 2>/dev/null; then
    ok "JIT config reached the guest on stdin"
else
    bad "JIT config never reached the guest"
fi
if grep -q "JITSECRET" "$TMP/log/ssh.argv" "$TMP/log/gh.argv" "$TMP/out"; then
    bad "JIT config leaked into an argv or the log"
else
    ok "JIT config absent from every argv and the output"
fi
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
if grep -rq "JITSECRET" "$TMP" --exclude-dir=log --exclude-dir=bin --exclude=out --exclude=hook.out 2>/dev/null; then
    bad "JIT config written to a file"
else
    ok "JIT config written to no file"
fi

echo "T4b an image that reaches the station loopback refuses to serve"
reset_log
STUB_LOCALHOST_REACHABLE=1 GH_KILL=on run_loop run --once >"$TMP/out" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q generate-jitconfig "$TMP/log/gh.argv" && grep -q "station loopback" "$TMP/out"; then
    ok "loopback-reachable image: refused before mint (rc=$rc)"
else
    bad "loopback-reachable image: rc=$rc, gh=$(tr '\n' '|' < "$TMP/log/gh.argv")"
fi

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

echo
echo "test-ci-runner: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
