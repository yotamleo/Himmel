#!/usr/bin/env bash
# ci-runner.sh — the host side of the himmel-vm self-hosted Actions runner
# (HIMMEL-5037). Run it on the station; the runner itself only ever runs inside
# the himmel-ci-1 test VM, a linked clone of ubuntu_new@suite-ready-v4.
#
#   bash scripts/vm/ci-runner.sh build         bake the ci-runner-v1 snapshot (unregistered)
#   bash scripts/vm/ci-runner.sh run [--once]  the job loop (registers with GitHub)
#
# One loop iteration = one job, from a clean VM:
#   1. kill switch: stop unless the repo variable HIMMEL_VM_RUNNER is `on` and
#      the local stop file is absent;
#   2. preflight: the repo's fork-PR approval policy must still be
#      all_external_contributors (a weaker policy refuses, exit 3);
#   3. restore ci-runner-v1, hide the station loopback, turn the VirtualBox
#      clipboard and drag-and-drop off (each asserted, fail closed), boot, and
#      check the guest's himmel_egress nft table is loaded (else refuse);
#   4. mint a single-use, repo-level JIT runner config (labels self-hosted,
#      himmel-vm) and hand it to the guest on ssh STDIN — never an argv on this
#      host, never a file, never a log line;
#   5. the guest runs ONE job as the non-root `runner` user (its job-started
#      hook refuses fork PRs and non-owner actors), bounded by
#      HIMMEL_CI_RUNNER_JOB_MAX seconds; while it waits, a watcher re-reads the
#      kill switch every HIMMEL_CI_RUNNER_WATCH_SECS (30) and deregisters the
#      runner at once when it is off (a runner mid-job is refused by GitHub and
#      finishes that job);
#   6. deregister the runner, power off. The next iteration restores again, so
#      nothing one job leaves on the disk reaches the next.
#
# Kill switch (one action, both halves): `gh variable set HIMMEL_VM_RUNNER
# --body off` stops this loop at its next iteration (an idle registered runner
# is deregistered within the watch interval), and ci.yml routes on the same
# variable. A local `touch $HIMMEL_CI_RUNNER_STOP_FILE` stops the loop alone.
#
# Platform guard (linux-only): drives VirtualBox through scripts/vm/lib/vm-clone.sh.
#
# ponytail: the loop mints a runner before it knows a himmel-vm job is queued, so
# an idle VM waits up to JOB_MAX and is then recycled; upgrade to demand-driven
# minting (poll queued workflow_job labels) if idle VM time ever matters.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="${HIMMEL_CI_RUNNER_REPO:-yotamleo/Himmel}"
CLONE_NAME="${HIMMEL_CI_RUNNER_VM:-himmel-ci-1}"
SOURCE_VM="ubuntu_new"
BASE_SNAPSHOT="suite-ready-v4"
RUNNER_SNAPSHOT="ci-runner-v1"
GUEST_USER="himmel"
JOB_MAX="${HIMMEL_CI_RUNNER_JOB_MAX:-4500}"
WATCH="${HIMMEL_CI_RUNNER_WATCH_SECS:-30}"
STOP_FILE="${HIMMEL_CI_RUNNER_STOP_FILE:-$HOME/.himmel/ci-runner.stop}"
LABEL="himmel-vm"
# shellcheck disable=SC2034 # read by the sourced vm-clone.sh
export SOURCE_VM GUEST_USER

die() { echo "ci-runner: $1" >&2; exit "${2:-1}"; }

if [ -n "${CI_RUNNER_VM_LIB:-}" ]; then
    # shellcheck source=/dev/null
    . "$CI_RUNNER_VM_LIB"
else
    # shellcheck source=scripts/vm/port-alloc.sh
    . "$REPO_ROOT/scripts/vm/port-alloc.sh"
    # shellcheck source=scripts/vm/lib/vm-clone.sh
    . "$REPO_ROOT/scripts/vm/lib/vm-clone.sh"
    # shellcheck source=scripts/vm/vm-lock.sh
    . "$REPO_ROOT/scripts/vm/vm-lock.sh"
    # shellcheck source=scripts/lib/vm-guest-excludes.sh
    . "$REPO_ROOT/scripts/lib/vm-guest-excludes.sh"
    # The NAT setting that hides the station's loopback (10.0.2.2) is applied  # leak-allow: private-lan-ip VBox NAT address
    # after EVERY restore, powered off: VirtualBox 7.2 serializes it into a
    # snapshot as localhost-reachable="true" whatever the live value, so a
    # restore always brings it back on.
    nat_localhost_off() {
        (cd "$HOME" && "$VBOXMANAGE" modifyvm "$CLONE_NAME" --nat-localhostreachable1 off)
    }
    localhost_unreachable() {
        (cd "$HOME" && "$VBOXMANAGE" showvminfo "$CLONE_NAME" --machinereadable) | grep -qx 'localhostReachable="0"'
    }
    # Clipboard and drag-and-drop are MACHINE CONFIG a restore reverts to the
    # snapshot's value; the ci-runner-v1 snapshot is baked with both off, and
    # this sets and asserts them again after every restore, powered off.
    clipboard_dnd_off() {
        (cd "$HOME" && "$VBOXMANAGE" modifyvm "$CLONE_NAME" --clipboard-mode disabled --drag-and-drop disabled)
    }
    clipboard_dnd_disabled() {
        local info
        info=$(cd "$HOME" && "$VBOXMANAGE" showvminfo "$CLONE_NAME" --machinereadable) || return 1
        printf '%s\n' "$info" | grep -qx 'clipboard="disabled"' && printf '%s\n' "$info" | grep -qx 'draganddrop="disabled"'
    }
    # Succeeds only once the clone is really off: the lock must never be
    # released over a VM that is still running a job.
    vm_poweroff() {
        vbox_py 'vbox.power_off(sys.argv[1], graceful=False)' "$CLONE_NAME" >/dev/null 2>&1
        (cd "$HOME" && "$VBOXMANAGE" showvminfo "$CLONE_NAME" --machinereadable) | grep -qx 'VMState="poweroff"'
    }
fi
fail() { die "$1"; }
# The secret scan runs as root: the login user cannot read runner's home or /root.
vm_ssh_root() { vm_ssh sudo bash -c "$(printf '%q' "$1")"; }

kill_switch_on() {
    local v
    [ ! -e "$STOP_FILE" ] || { echo "ci-runner: stop file $STOP_FILE present — stopping"; return 1; }
    v=$(gh api "repos/$REPO/actions/variables/HIMMEL_VM_RUNNER" --jq .value 2>/dev/null) || v=""
    [ "$v" = on ] || { echo "ci-runner: repo variable HIMMEL_VM_RUNNER is '${v:-unset}', not 'on' — stopping"; return 1; }
}

preflight() {
    local policy
    policy=$(gh api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2>/dev/null) || policy=""
    [ "$policy" = all_external_contributors ] \
        || die "fork-PR approval policy on $REPO is '${policy:-unreadable}', not all_external_contributors — refusing to serve a public repo" 3
}

RUNNER_ID=""
JOB_PID=""
LOCKED=0
cleanup() {
    if [ -n "$JOB_PID" ]; then
        kill "$JOB_PID" 2>/dev/null
        JOB_PID=""
    fi
    if [ -n "$RUNNER_ID" ]; then
        gh api -X DELETE "repos/$REPO/actions/runners/$RUNNER_ID" >/dev/null 2>&1 || true
        RUNNER_ID=""
    fi
    if [ "$LOCKED" = 1 ]; then
        LOCKED=0
        if ! vm_poweroff; then
            echo "ci-runner: $CLONE_NAME still running after power-off — keeping its vm-lock; power it off by hand, then release the lock" >&2
            return 1
        fi
        vm_lock_release "$CLONE_NAME"
    fi
}
# A signal exits through the EXIT trap, so a killed loop still deregisters its
# runner and powers the VM off.
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

lock_clone() {
    vm_lock_acquire_waiting "$CLONE_NAME" || die "could not take the vm-lock on $CLONE_NAME"
    LOCKED=1
}

one_job() {
    local jit="" rc tick off=0
    lock_clone
    vm_restore "$RUNNER_SNAPSHOT"
    nat_localhost_off || die "could not make the station loopback unreachable from $CLONE_NAME"
    localhost_unreachable || die "$CLONE_NAME still reaches the station loopback — not serving a job"
    clipboard_dnd_off || die "could not turn the clipboard and drag-and-drop off on $CLONE_NAME"
    clipboard_dnd_disabled || die "$CLONE_NAME still has the clipboard or drag-and-drop on — not serving a job"
    vm_boot
    # Per boot, not per image: a guest whose egress filter did not load would
    # reach the station LAN.
    # Every private-range reject must be loaded, not just the LAN one (HIMMEL-5070).
    local r chk="sudo nft list table inet himmel_egress | grep -q 'hook output'"
    for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do  # leak-allow: private-lan-ip egress filter ranges
        # Anchored on the set delimiters so a range cannot match a longer one it is a suffix of.
        chk="$chk && sudo nft list table inet himmel_egress | grep -qE '[{ ,]${r//./\\.}[ ,}].*reject'"
    done
    vm_ssh "$chk" \
        || die "the himmel_egress nft table is not loaded in $CLONE_NAME — not minting a runner"
    { IFS= read -r RUNNER_ID && IFS= read -r jit; } < <(
        gh api -X POST "repos/$REPO/actions/runners/generate-jitconfig" \
            -f "name=$LABEL-$(date +%s)" -F runner_group_id=1 \
            -f 'labels[]=self-hosted' -f "labels[]=$LABEL" -f work_folder=_work \
            --jq '.runner.id, .encoded_jit_config')
    case "$RUNNER_ID" in ''|*[!0-9]*) RUNNER_ID=""; die "could not mint a JIT runner config for $REPO" ;; esac
    [ -n "$jit" ] || die "JIT runner $RUNNER_ID came back with no config"
    echo "ci-runner: runner $RUNNER_ID registered on $REPO ($LABEL); waiting for one job (max ${JOB_MAX}s)"
    # In the background so a signal interrupts the wait at once, not after the job.
    printf '%s\n' "$jit" | vm_ssh sudo /usr/local/sbin/himmel-ci-run-job "$JOB_MAX" &
    JOB_PID=$!
    jit=""
    # Poll in 1s steps so a signal is handled at once; the kill switch is
    # re-read only every $WATCH seconds.
    tick=0
    while kill -0 "$JOB_PID" 2>/dev/null; do
        sleep 1
        tick=$((tick + 1))
        if [ $((tick % WATCH)) -eq 0 ] && ! kill_switch_on >/dev/null; then
            if gh api -X DELETE "repos/$REPO/actions/runners/$RUNNER_ID" >/dev/null 2>&1; then
                echo "ci-runner: runner $RUNNER_ID deregistered — kill switch off"
                RUNNER_ID=""
                off=1
                # An idle, now-deregistered runner has nothing to wait for; do
                # not hold the loop until JOB_MAX (HIMMEL-5070).
                kill "$JOB_PID" 2>/dev/null
                break
            fi
        fi
    done
    wait "$JOB_PID"
    rc=$?
    JOB_PID=""
    [ "$off" = 1 ] && rc=0
    echo "ci-runner: runner $RUNNER_ID done (rc=$rc)"
    cleanup || exit 1
    return "$rc"
}

build() {
    local stage=/tmp/himmel-ci-stage f
    vm_env_init
    lock_clone
    vm_clone_ensure "$BASE_SNAPSHOT"
    vm_restore "$BASE_SNAPSHOT"
    clipboard_dnd_off || die "could not turn the clipboard and drag-and-drop off on $CLONE_NAME"
    vm_boot
    vm_ssh "rm -rf $stage && mkdir -p $stage" || die "could not stage in the guest"
    for f in guest-provision.sh job-started-hook.sh; do
        vm_ssh "cat > $stage/$f" < "$REPO_ROOT/scripts/vm/ci-runner/$f" || die "staging $f failed"
    done
    vm_ssh "sudo bash $stage/guest-provision.sh $REPO" || die "guest provisioning failed"
    vm_ssh "rm -rf $stage" || die "could not remove the guest staging dir"
    for f in /home /opt /root /tmp; do
        vm_guest_assert_clean vm_ssh_root "$f" full || die "the guest holds a secret-bearing file under $f — not snapshotting"
    done
    vm_poweroff || die "$CLONE_NAME did not power off — not snapshotting a running VM"
    (cd "$HOME" && "$VBOXMANAGE" snapshot "$CLONE_NAME" take "$RUNNER_SNAPSHOT" \
        --description "HIMMEL-5037: ephemeral Actions runner image, unregistered") \
        || die "could not take $RUNNER_SNAPSHOT"
    echo "ci-runner: $CLONE_NAME@$RUNNER_SNAPSHOT baked"
}

run() {
    local once=0 rc
    [ "${1:-}" = "--once" ] && once=1
    case "$JOB_MAX" in
        ''|*[!0-9]*|0*) die "HIMMEL_CI_RUNNER_JOB_MAX='$JOB_MAX' is not a positive number of seconds" 2 ;;
    esac
    case "$WATCH" in
        ''|*[!0-9]*|0*) die "HIMMEL_CI_RUNNER_WATCH_SECS='$WATCH' is not a positive number of seconds" 2 ;;
    esac
    vm_env_init
    while :; do
        kill_switch_on || exit 0
        preflight
        one_job
        rc=$?
        [ "$once" = 1 ] && exit "$rc"
    done
}

case "${1:-}" in
    build) build ;;
    run) shift; run "$@" ;;
    *) die "usage: ci-runner.sh build | run [--once]" 2 ;;
esac
