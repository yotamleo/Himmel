#!/usr/bin/env bash
# run-codex-adversarial.sh (HIMMEL-1474) - launch the companion with an actual
# node pid, start its Windows client-lease heartbeat, and optionally bound it.
# Exit 125 means launch ownership could not be established or a successful
# companion left process-group cleanup unverified; companion failures and the
# timeout rc 124 keep their original status. Exit 75 means the branch launch
# claim was REFUSED (HIMMEL-1509): when RENDER_LEASE_BRANCH is set in the
# environment, this launcher acquires the per-branch render lease from the
# scripts/lib/render-lease.sh registry before spawning node - a live or
# unverifiable lease on the branch, lock contention, or an unusable registry
# all refuse the launch instead of racing (fail-closed; closes the
# HIMMEL-1496 same-branch TOCTOU). The lease is released ONLY when cleanup
# verifies clean (cleanup rc 0); every other exit leaves the lease for the
# sweep/orchestrator to adjudicate.
set -u

if [ "$#" -lt 4 ] || [ "$#" -gt 7 ]; then
    echo "usage: run-codex-adversarial.sh <companion> <base> <stdout> <stderr> [pid-file] [timeout-seconds] [cleanup-rc-file]" >&2
    exit 2
fi

companion=$1
base=$2
stdout_file=$3
stderr_file=$4
pid_file=${5:-}
timeout_secs=${6:-0}
cleanup_rc_file=${7:-}

# HIMMEL-1957/HIMMEL-2056: keep the adversarial lane dormant until its
# empty-output and timeout behavior is understood. Exit cleanly before
# creating any ownership sidecar or acquiring a render lease so /pr-check
# harvests this exactly like an absent companion (no pid means no
# attempted-review availability record) - and write the one-line
# machine-readable sentinel to stdout_file so codex-adv-completion-check.sh
# can positively recognize this as ABSENT rather than a HIMMEL-1420 silent
# death, if anything ever inspects it.
if [ "${CODEX_ADV_OK:-}" != "1" ]; then
    echo "codex adversarial pass skipped: dormant pending investigation (HIMMEL-1957); set CODEX_ADV_OK=1 to launch" >&2
    printf '%s\n' "codex-adv: dormant (HIMMEL-1957)" > "$stdout_file"
    exit 0
fi
[ -n "$cleanup_rc_file" ] || cleanup_rc_file="${stdout_file}.cleanup-rc"
case "$timeout_secs" in ''|*[!0-9]*) timeout_secs=0 ;; esac
rm -f "$cleanup_rc_file"

self_dir=$(cd "$(dirname "$0")" && pwd)
lease_script="$self_dir/codex-render-client-lease.ps1"
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$self_dir/../lib/proc-tree.sh"
# shellcheck source=../lib/render-lease.sh
# shellcheck disable=SC1091
. "$self_dir/../lib/render-lease.sh"

# HIMMEL-1509 launch claim: opt-in via RENDER_LEASE_BRANCH (pr-check exports
# it). Acquired BEFORE node exists so two same-branch kickoffs race no further
# than one atomic mkdir; released only from publish_cleanup_rc's verified-clean
# path below.
render_lease_branch=${RENDER_LEASE_BRANCH:-}
lease_held=0
if [ -n "$render_lease_branch" ]; then
    launch_cwd=$(pwd)
    if command -v cygpath >/dev/null 2>&1; then
        launch_cwd=$(cygpath -m "$launch_cwd")
    fi
    claim_rc=0
    render_lease_claim "$render_lease_branch" "$launch_cwd" || claim_rc=$?
    if [ "$claim_rc" -ne 0 ]; then
        echo "codex adversarial launch REFUSED: render lease for branch '$render_lease_branch' unavailable (claim rc=$claim_rc; registry $(render_lease_registry_dir)) - a live render owns this branch, the registry lock is contended, or the registry is unusable (HIMMEL-1509); no process was launched" >&2
        exit 75
    fi
    lease_held=1
fi

node_pid=''
node_identity=''
ownership_published=0
identity_file=''
identity_tmp=''
pid_tmp=''
survivors_file=''
survivors_tmp=''
if [ -n "$pid_file" ]; then
    identity_file="${pid_file}.identity"
    identity_tmp="${identity_file}.tmp.$$"
    pid_tmp="${pid_file}.tmp.$$"
    survivors_file="${pid_file}.survivors"
    survivors_tmp="${survivors_file}.tmp.$$"
    rm -f "$pid_file" "$identity_file" "$identity_tmp" "$pid_tmp" "$survivors_file" "$survivors_tmp"
fi

publish_survivors() {
    local members='' member member_identity snapshot_unverified=0
    [ -n "$survivors_file" ] || return 0
    : > "$survivors_tmp" || return 1
    members=$(proc_tree_group_members "$node_pid") || snapshot_unverified=1
    for member in $members; do
        member_identity=$(proc_tree_process_identity "$member") || member_identity=''
        if [ -z "$member_identity" ] || ! proc_tree_process_identity_matches "$member" "$member_identity"; then
            snapshot_unverified=1
            break
        fi
        if ! printf '%s\t%s\n' "$member" "$member_identity" >> "$survivors_tmp"; then
            snapshot_unverified=1
            break
        fi
    done
    if [ "$snapshot_unverified" -ne 0 ] || ! mv -f "$survivors_tmp" "$survivors_file"; then
        rm -f "$survivors_tmp" "$survivors_file"
        echo "codex adversarial survivor snapshot unavailable for pid/group $node_pid: recovery sidecar not published" >&2
        return 1
    fi
    return 0
}

publish_cleanup_rc() {
    case "$1" in
        # HIMMEL-1501: 3 (proc_tree_terminate confirmed the leader already
        # exited/recycled before any signal) joins 1|2 here -- the group may
        # still have unreaped descendants the leader-only check never saw.
        1|2|3) publish_survivors || true ;;
        0) [ -z "$survivors_file" ] || rm -f "$survivors_file" "$survivors_tmp" ;;
    esac
    # HIMMEL-1509: cleanup rc 0 is the ONLY verified-clean signal, so it is the
    # only place the branch render lease may be released. Any other status
    # leaves the lease as adjudication evidence for the sweep/orchestrator.
    if [ "$lease_held" -eq 1 ]; then
        if [ "$1" = "0" ]; then
            render_lease_release "$render_lease_branch"
        else
            echo "codex adversarial render lease preserved for adjudication (cleanup rc=$1): $(render_lease_dir_for "$render_lease_branch")" >&2
        fi
    fi
    printf '%s\n' "$1" > "$cleanup_rc_file"
}

publish_ownership_sidecars() {
    [ -n "$pid_file" ] || return 1
    [ -n "$node_pid" ] && [ -n "$node_identity" ] || return 1
    if ! printf '%s\n' "$node_identity" > "$identity_tmp" || ! mv -f "$identity_tmp" "$identity_file" ||
       ! printf '%s\n' "$node_pid" > "$pid_tmp" || ! mv -f "$pid_tmp" "$pid_file"; then
        rm -f "$identity_tmp" "$pid_tmp" "$identity_file" "$pid_file"
        return 1
    fi
    ownership_published=1
    return 0
}

stop_node_tree() {
    local leader_exited="${1:-0}" identity_rc=2 cleanup_rc
    [ -n "$node_pid" ] || return 0
    if [ "$leader_exited" = "1" ]; then
        identity_rc=1
    elif [ -n "$node_identity" ]; then
        identity_rc=0
        proc_tree_process_identity_matches "$node_pid" "$node_identity" || identity_rc=$?
    fi
    if [ "$identity_rc" -eq 0 ]; then
        proc_tree_terminate "$node_pid" 1 "$node_identity"
        cleanup_rc=$?
    elif [ "$identity_rc" -eq 1 ]; then
        # HIMMEL-1474 r4: after leader exit, sweep any observed launch-group
        # survivors without ever signaling a bare, potentially-recycled leader pid.
        proc_tree_group_terminate "$node_pid" 1
        cleanup_rc=$?
    else
        echo "codex adversarial cleanup failed for pid/group $node_pid: identity probe unavailable; no signal sent" >&2
        return 2
    fi
    if [ "$cleanup_rc" -ne 0 ]; then
        echo "codex adversarial cleanup failed for pid/group $node_pid (rc=$cleanup_rc): processes may remain alive" >&2
    fi
    return "$cleanup_rc"
}

# shellcheck disable=SC2317,SC2329  # invoked by trap
terminate_on_signal() {
    local cleanup_rc=0 identity_attempt=0 candidate_identity=''
    if [ -n "$node_pid" ] && [ -z "$node_identity" ]; then
        # Before the launch identity is captured, this wrapper still exclusively
        # owns the dedicated group. Sweep that observed group instead of refusing
        # every signal for lack of the not-yet-published identity.
        proc_tree_group_terminate "$node_pid" 1 || cleanup_rc=$?
    else
        stop_node_tree || cleanup_rc=$?
    fi
    publish_cleanup_rc "$cleanup_rc"
    if [ "$cleanup_rc" -ne 0 ] && [ "$ownership_published" -eq 0 ]; then
        # The initial handshake may have been interrupted before it captured the
        # leader identity. Briefly retry against the still-observed leader, and
        # publish recovery handles only after immediate identity revalidation.
        while [ -z "$node_identity" ] && [ "$identity_attempt" -lt 5 ]; do
            candidate_identity=$(proc_tree_process_identity "$node_pid") || candidate_identity=''
            if [ -n "$candidate_identity" ] && proc_tree_process_identity_matches "$node_pid" "$candidate_identity"; then
                node_identity=$candidate_identity
                break
            fi
            identity_attempt=$((identity_attempt + 1))
            sleep 0.1
        done
        if ! publish_ownership_sidecars; then
            echo "codex adversarial signal cleanup UNRECOVERABLE for pid/group $node_pid (rc=$cleanup_rc): leader identity could not be reacquired; no recovery pid marker published" >&2
        fi
    fi
    exit 143
}
trap terminate_on_signal HUP INT TERM

# Job control gives the companion and every descendant a dedicated process
# group on POSIX and Git Bash; proc_tree_terminate relies on this invariant.
# HIMMEL-1474 r3/r11: async harvest receives the group leader only after a
# required identity handshake has established ownership of that exact process.
set -m
node "$companion" adversarial-review --wait --base "$base" >"$stdout_file" 2>"$stderr_file" &
node_pid=$!
set +m
identity_attempt=0
while [ -z "$node_identity" ] && [ "$identity_attempt" -lt 20 ]; do
    node_identity=$(proc_tree_process_identity "$node_pid") || node_identity=''
    [ -n "$node_identity" ] && break
    identity_attempt=$((identity_attempt + 1))
    sleep 0.1
done
if [ -z "$node_identity" ]; then
    cleanup_rc=0
    proc_tree_group_terminate "$node_pid" 1 || cleanup_rc=$?
    publish_cleanup_rc "$cleanup_rc"
    if [ "$cleanup_rc" -eq 0 ]; then
        wait "$node_pid" 2>/dev/null || true
    fi
    echo "codex adversarial launch unavailable for pid/group $node_pid: process identity could not be captured; owned group termination rc=$cleanup_rc; no pid published" >&2
    exit 125
fi
if [ -n "$pid_file" ]; then
    if ! publish_ownership_sidecars; then
        cleanup_rc=0
        proc_tree_group_terminate "$node_pid" 1 || cleanup_rc=$?
        publish_cleanup_rc "$cleanup_rc"
        if [ "$cleanup_rc" -eq 0 ]; then
            wait "$node_pid" 2>/dev/null || true
        fi
        echo "codex adversarial launch unavailable for pid/group $node_pid: ownership sidecars could not be published atomically; owned group termination rc=$cleanup_rc" >&2
        exit 125
    fi
fi

lease_client_pid=$node_pid
if proc_tree_is_windows; then
    lease_client_pid=$(proc_tree_winpid "$node_pid")
    case "$lease_client_pid" in ''|*[!0-9]*) lease_client_pid='' ;; esac
fi

# HIMMEL-1509: bind the identity-verified leader onto the held lease so the
# sweep can verify liveness from the record alone (win:<pid>:<startticks>),
# independent of command-line visibility. Best-effort: a failed bind keeps the
# launch-phase record, which stays live via its own freshness anchor.
if [ "$lease_held" -eq 1 ]; then
    render_lease_bind "$render_lease_branch" "$node_pid" "$lease_client_pid" "$node_identity" ||
        echo "codex adversarial render lease bind failed for branch '$render_lease_branch'; lease keeps its launch-phase record" >&2
fi

pwsh_bin=''
for candidate in pwsh pwsh.exe powershell.exe powershell; do
    if command -v "$candidate" >/dev/null 2>&1; then
        pwsh_bin=$candidate
        break
    fi
done
if [ -n "$pwsh_bin" ] && [ -n "$lease_client_pid" ]; then
    lease_arg=$lease_script
    if command -v cygpath >/dev/null 2>&1; then
        lease_arg=$(cygpath -m "$lease_script")
    fi
    if [ "$lease_held" -eq 1 ]; then
        # The heartbeat writer also refreshes the registry lease (heartbeat +
        # observed cxc tokens) so the sweep sees live proof without argv access.
        lease_dir_path=$(render_lease_dir_for "$render_lease_branch")
        if command -v cygpath >/dev/null 2>&1; then
            lease_dir_path=$(cygpath -m "$lease_dir_path")
        fi
        "$pwsh_bin" -NoProfile -ExecutionPolicy Bypass -File "$lease_arg" -ClientPid "$lease_client_pid" -LeaseDir "$lease_dir_path" >/dev/null 2>&1 &
    else
        "$pwsh_bin" -NoProfile -ExecutionPolicy Bypass -File "$lease_arg" -ClientPid "$lease_client_pid" >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
fi

if [ "$timeout_secs" -gt 0 ]; then
    waited=0
    while kill -0 "$node_pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout_secs" ]; then
            cleanup_rc=0
            stop_node_tree || cleanup_rc=$?
            publish_cleanup_rc "$cleanup_rc"
            if [ "$cleanup_rc" -eq 0 ]; then
                wait "$node_pid" 2>/dev/null || true
            else
                echo "codex adversarial timeout cleanup incomplete for pid/group $node_pid (rc=$cleanup_rc): skipping blocking wait; ownership sidecars preserved" >&2
            fi
            exit 124
        fi
        sleep 5
        waited=$((waited + 5))
    done
fi

wait "$node_pid"
node_rc=$?
# HIMMEL-1474 r4: leader exit is not group completion. Reap any stubborn
# descendants before the wrapper publishes the companion rc to harvest.
stop_node_tree 1
cleanup_rc=$?
publish_cleanup_rc "$cleanup_rc"
[ "$node_rc" -ne 0 ] && exit "$node_rc"
[ "$cleanup_rc" -eq 0 ] || exit 125
exit 0
