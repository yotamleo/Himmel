#!/usr/bin/env bash
# vm-clone.sh — SOURCED library: the VirtualBox linked-clone / restore / ssh
# primitives, extracted from scripts/vm/after-report.sh (HIMMEL-3332 slice S9a)
# so a second consumer (the S9b install-provenance harness) shares ONE copy of
# the incident-hardened code instead of forking it. Behaviour is unchanged:
# after-report.sh and its tests are the proof (see scripts/vm/test-after-report.sh).
#
# Sets no shell options and installs no traps — those stay the caller's.
#
# Caller contract
#   - sources scripts/vm/port-alloc.sh and scripts/vm/vm-lock.sh BEFORE calling
#     vm_clone_ensure (vm_ar_* / vm_lock_* functions); the vm-lock around the
#     clone name, and the EXIT trap that powers the clone off and releases it,
#     are the caller's (after-report.sh owns them).
#   - may define fail() (one string arg, must exit): every refusal in this lib
#     goes through it, so the caller keeps its own message frame and host
#     fallback. Without one, a refusal prints `ERROR: vm-clone: <reason>` and
#     exits 1.
#
# Globals (in / out)
#   in : SOURCE_VM  the base VM the clones link to          (vm_clone_ensure)
#        GUEST_USER the guest login                          (vm_ssh, vm_scp)
#   out: VBOXMANAGE, HIMMEL_VM_PYTHON                        (vm_env_init)
#        CLONE_IDX, CLONE_FD, CLONE_NAME                     (vm_slot_acquire)
#        PORT  the clone's loopback ssh forward              (vm_restore)
#   Every env knob keeps its existing name: HIMMEL_VM_AR_{MAX,SOURCE_VM,SNAPSHOT,
#   GUEST_USER,SSH_KEY,SSH_WAIT,SLOT_WAIT,LOCK_DIR,RAM_MB,LIVE,VBOXMANAGE_DEFAULT},
#   VBOXMANAGE_PATH, HIMMEL_VM_PYTHON.
#
# Functions
#   vm_env_init        VBoxManage guard + binary + venv-python checks
#   vbox_py <code> [argv...]   run a scripts/lib/vbox.py snippet through the venv python
#   vm_slot_acquire    claim a free clone slot 1..HIMMEL_VM_AR_MAX (flock; a cap, not a FIFO)
#   vm_slot_release    close the slot's fd
#   vm_clone_ensure <snapshot>  create $CLONE_NAME (linked clone + forward + baseline) if absent
#   vm_restore <snapshot>       verify the baseline exists, restore it, read $PORT
#   vm_boot            RAM budget check, start the clone, wait for ssh
#   vm_ssh <cmd...>    run a command on the guest (stdin passes through)
#   vm_scp <guest-path> <local-path>   copy one file guest -> host
#   vm_stage_tree <repo> <remote_dir> <runner> <rsync_e> <rsync_host> <path>...
#                      stage repo paths onto a guest, then assert it carries no host secret

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"

_vm_fail() {
    if declare -F fail >/dev/null 2>&1; then
        fail "$1"
    fi
    echo "ERROR: vm-clone: $1" >&2
    exit 1
}

# --- HIMMEL-2623 incident hardening: an unset VBOXMANAGE_PATH must NEVER
# fall through to a real binary without a deliberate opt-in. The incident
# that prompted this was exactly that: a debug invocation simply forgot to
# set VBOXMANAGE_PATH, and nothing STRUCTURAL stood between it and the
# station's real VirtualBox — it cloned and snapshotted a real VM. This
# check runs BEFORE the fallback assignment below is ever evaluated: with
# the opt-in unset, $VBOXMANAGE is never assigned the real default at all,
# so there is nothing here for a bug two lines down to invoke.
#
# The real default lives in a NAMED variable (never inlined at the fallback
# site) purely so a test can override it with a call-COUNTING fake and
# prove zero invocations ever reach it when the guard fires — the test
# never touches the real /usr/bin/VBoxManage to prove this; overriding this
# variable is not something production use ever does.
vm_env_init() {
    HIMMEL_VM_AR_VBOXMANAGE_DEFAULT="${HIMMEL_VM_AR_VBOXMANAGE_DEFAULT:-/usr/bin/VBoxManage}"
    if [ -z "${VBOXMANAGE_PATH:-}" ] && [ "${HIMMEL_VM_AR_LIVE:-0}" != "1" ]; then
        _vm_fail "VBOXMANAGE_PATH is unset and HIMMEL_VM_AR_LIVE is not '1' — refusing to fall through to a real VBoxManage (HIMMEL-2623 incident hardening). Set VBOXMANAGE_PATH explicitly (a real path, or a stub for testing), or HIMMEL_VM_AR_LIVE=1 to run for real."
    fi
    VBOXMANAGE="${VBOXMANAGE_PATH:-$HIMMEL_VM_AR_VBOXMANAGE_DEFAULT}"
    export VBOXMANAGE_PATH="$VBOXMANAGE"
    command -v "$VBOXMANAGE" >/dev/null 2>&1 || [ -x "$VBOXMANAGE" ] \
        || _vm_fail "VBoxManage not found at '$VBOXMANAGE' (set VBOXMANAGE_PATH)"

    HIMMEL_VM_PYTHON="${HIMMEL_VM_PYTHON:-$HOME/.himmel/vm-venv/bin/python}"
    [ -x "$HIMMEL_VM_PYTHON" ] \
        || _vm_fail "venv python not found/executable at '$HIMMEL_VM_PYTHON' (needed to drive scripts/lib/vbox.py; set HIMMEL_VM_PYTHON)"
}

# vbox_py <python-code> [argv...] — run a vbox.py-scoped snippet through the
# venv python; `import vbox` has already been done, so callers just reference
# `vbox.<fn>(...)`. CR finding codex-15 (same shape, swept here from
# dry-run-restore.sh): <python-code> is a FIXED, trusted literal, never
# containing a shell variable — every piece of DATA (CLONE_NAME, SNAPSHOT,
# PORT) is passed as a trailing argv element and read via sys.argv[N], never
# interpolated into the python SOURCE text. CLONE_NAME/PORT are
# internally-generated and currently safe by construction, and
# SNAPSHOT/SOURCE_VM are operator-set config, not attacker input — but the
# INTERPOLATION PATTERN itself is what breaks the moment any future edit
# routes less-trusted data through it, so it is removed here too rather
# than left as a trap for the next person to trip.
vbox_py() {
    local code="$1"; shift
    # $REPO_ROOT is passed through argv too (residual of codex-15 the first
    # pass missed): it was still interpolated straight into the python
    # SOURCE text below, and a worktree path derives from a branch name —
    # `.claude/worktrees/feat+...` — which may legally contain an
    # apostrophe, breaking the string literal (verified: "unterminated
    # string literal"). `sys.argv.pop(1)` consumes it here, inside vbox_py
    # itself, so every call site's OWN sys.argv[N] numbering for ITS data is
    # completely unaffected.
    "$HIMMEL_VM_PYTHON" -c "
import sys
_repo_root = sys.argv.pop(1)
sys.path.insert(0, _repo_root + '/scripts/lib')
import vbox
$code
" "$REPO_ROOT" "$@"
}

# vm_slot_acquire — claim a clone slot (1..HIMMEL_VM_AR_MAX), FIFO not required
# here: PR-A's host lock already owns fairness for the machine-wide lock this VM
# path exists to avoid; this is just a concurrency CAP on the clones themselves.
# Runs in the CALLER's shell (the lock is the open fd, which a subshell would
# drop on return) and sets CLONE_IDX, CLONE_FD and CLONE_NAME.
vm_slot_acquire() {
    local max="${HIMMEL_VM_AR_MAX:-2}" lock_dir slot_wait deadline i fd lockfile
    case "$max" in
        ''|*[!0-9]*|0) _vm_fail "HIMMEL_VM_AR_MAX must be a positive integer, got '$max'" ;;
    esac
    # CodeRabbit (PR #2206): the slot loop below calls `flock -n` with no check
    # that it exists. If it is absent, EVERY slot's `flock -n "$fd"` fails the
    # same way an actually-busy slot would, so this is not a portability
    # concern on THIS linux-only runner (see the platform guard above — flock
    # is near-universal there) — it is a FAILURE-MODE one: an absent `flock`
    # reads identically to "every slot busy," and the loop then spins silently
    # against SLOT_WAIT, whose default is 7200s. A two-hour silent spin ending
    # in the same "all slots busy" message a real contention case would give
    # is a far worse failure than an immediate, correctly-attributed refusal.
    # Preflight once, before the loop, and fail loudly naming the real cause.
    command -v flock >/dev/null 2>&1 || _vm_fail "'flock' not found on PATH — required to claim a clone slot (scripts/vm/after-report.sh's platform guard assumes it; install util-linux or equivalent)"
    lock_dir="${HIMMEL_VM_AR_LOCK_DIR:-/tmp}"
    mkdir -p "$lock_dir" || _vm_fail "cannot create lock directory $lock_dir"
    slot_wait="${HIMMEL_VM_AR_SLOT_WAIT:-7200}"
    CLONE_IDX=""
    CLONE_FD=""
    deadline=$(( $(date +%s) + slot_wait ))
    while [ -z "$CLONE_IDX" ]; do
        i=1
        while [ "$i" -le "$max" ]; do
            lockfile="$lock_dir/himmel-vm-ar-$i.lock"
            fd=$(( 200 + i ))
            # A literal fd number is required immediately before `>` in bash's
            # redirection grammar (a variable there is not recognized as the fd
            # prefix), hence eval — the path is shell-quoted via printf %q first
            # so this never re-interprets anything in $lockfile.
            eval "exec $fd>$(printf '%q' "$lockfile")" 2>/dev/null || _vm_fail "cannot open lock file $lockfile"
            if flock -n "$fd"; then
                CLONE_IDX=$i
                CLONE_FD=$fd
                break
            fi
            eval "exec $fd>&-"
            i=$((i + 1))
        done
        if [ -n "$CLONE_IDX" ]; then
            break
        fi
        [ "$(date +%s)" -lt "$deadline" ] || _vm_fail "all $max clone slot(s) busy after ${slot_wait}s (HIMMEL_VM_AR_MAX=$max)"
        sleep 5
    done
    CLONE_NAME="himmel-ar-$CLONE_IDX"
}

# vm_slot_release — safe to call unconditionally (an EXIT trap may fire before
# any slot was claimed).
vm_slot_release() {
    if [ -n "${CLONE_FD:-}" ]; then
        eval "exec $CLONE_FD>&-" 2>/dev/null || true
        CLONE_FD=""
    fi
}

# vm_clone_ensure <snapshot> — create $CLONE_NAME from $SOURCE_VM if it does not
# exist yet. The caller already holds the vm-lock on $CLONE_NAME.
vm_clone_ensure() {
    local snapshot="$1" _reg_lock_rc _port_rc
    vm_ar_vm_exists "$CLONE_NAME" && return 0
    # A SECOND, nested lock on a fixed sentinel name ("himmel-vm-registry",
    # not a real VM — the vm-lock library takes any name, a VM name is just
    # the common case) serializes port allocation + clonevm + the forward +
    # the baseline snapshot ACROSS DIFFERENT clone names. The outer
    # CLONE_NAME lock alone does not close this race: two slot-holders
    # creating himmel-ar-1 and himmel-ar-2 for the FIRST time never contend
    # on the SAME lock name, so without this they could both read "port 2231
    # is free" and both claim it. Held only for the creation span — never
    # needed again once a clone's own forward is on record.
    vm_lock_acquire_waiting "himmel-vm-registry"
    _reg_lock_rc=$?
    case "$_reg_lock_rc" in
        0) ;;
        5) _vm_fail "timed out waiting for the vm-lock on 'himmel-vm-registry' while creating $CLONE_NAME" ;;
        *) _vm_fail "could not acquire the vm-lock on 'himmel-vm-registry' while creating $CLONE_NAME" ;;
    esac
    PORT=$(vm_ar_next_ports 1)
    _port_rc=$?
    if [ "$_port_rc" -ne 0 ]; then
        vm_lock_release "himmel-vm-registry"
        _vm_fail "port allocation failed"
    fi
    if ! "$VBOXMANAGE" clonevm "$SOURCE_VM" --snapshot "$snapshot" --options link \
            --name "$CLONE_NAME" --register; then
        vm_lock_release "himmel-vm-registry"
        _vm_fail "clonevm $SOURCE_VM -> $CLONE_NAME failed"
    fi
    if ! vbox_py 'vbox.ensure_persistent_forward(sys.argv[1], "ssh", int(sys.argv[2]), 22)' "$CLONE_NAME" "$PORT"; then
        vm_lock_release "himmel-vm-registry"
        _vm_fail "could not set the persistent NAT forward on $CLONE_NAME (port $PORT)"
    fi
    if ! "$VBOXMANAGE" snapshot "$CLONE_NAME" take "$snapshot"; then
        vm_lock_release "himmel-vm-registry"
        _vm_fail "could not take the baseline '$snapshot' snapshot on the new clone $CLONE_NAME"
    fi
    vm_lock_release "himmel-vm-registry"
}

# vm_restore <snapshot> — restore $CLONE_NAME to the clean baseline and read the
# clone's loopback ssh port into $PORT.
# Verify the SNAPSHOT NAME actually exists on this clone before touching
# anything (HIMMEL-2623): a stale-default/missing baseline — this script's
# default has already moved once in substance (suite-ready -> suite-ready-v3
# -> suite-ready-v4, the last via the HIMMEL-2747 delete-and-re-clone above,
# not a rename) and will move again for a future migration — must fail with
# a clear, specific message here, not an opaque VBoxManage error three calls
# later.
vm_restore() {
    local snapshot="$1"
    vbox_py '
names = vbox.list_snapshots(sys.argv[1])
sys.exit(1) if sys.argv[2] not in names else None
' "$CLONE_NAME" "$snapshot" || _vm_fail "snapshot '$snapshot' does not exist on $CLONE_NAME — check HIMMEL_VM_AR_SNAPSHOT (or that the clone predates a base-snapshot rename)"
    vbox_py 'vbox.restore_snapshot(sys.argv[1], sys.argv[2])' "$CLONE_NAME" "$snapshot" \
        || _vm_fail "restore_snapshot($CLONE_NAME, $snapshot) failed"

    # CR finding codex-3 (round 3): read PORT AFTER restore_snapshot, not
    # before, and for BOTH the freshly-created and the reused-clone case alike
    # — `snapshot restore` reverts MACHINE CONFIG, not just disk, so any
    # pre-restore read (including this clone's OWN forward, if an operator
    # ever hand-edited it since the baseline was taken) can go stale the
    # moment restore reinstates whatever the snapshot itself recorded.
    # CR finding codex-14: select the LOOPBACK ssh (guest port 22) rule
    # explicitly — the previous "first tcp forward, whichever it is" picked
    # an unrelated rule the moment a clone ever carried more than one (an
    # operator-added forward, or a future second port), silently ssh-ing to
    # the wrong port.
    PORT=$(vbox_py '
fw = vbox.get_forwards(sys.argv[1])
ssh_fwds = [f for f in fw if f[1] == "tcp" and f[5] == "22" and f[2] == "127.0.0.1"]
sys.exit(1) if not ssh_fwds else print(ssh_fwds[0][3])
' "$CLONE_NAME") || _vm_fail "$CLONE_NAME is registered but has no loopback ssh (tcp/22) NAT forward — remove it manually or fix scripts/vm/after-report.sh's port bookkeeping"
}

# vm_boot — start $CLONE_NAME and wait until it answers ssh on 127.0.0.1:$PORT.
vm_boot() {
    local free_mb ssh_wait
    # CR finding codex-2: SKILL.md documents "a RAM budget (4 GB each, capped
    # via env against free host RAM)" for after-report clones — a claim with no
    # enforcement was worse than no claim at all. Checked right before boot
    # (the point RAM actually gets committed), against Linux's own
    # MemAvailable (the kernel's own "could I start a program needing this much
    # without swapping" estimate — more honest than raw MemFree). Skips
    # cleanly (fails open) where /proc/meminfo does not exist — a soft resource
    # guard, not a security boundary, and this station's tooling is Linux-only
    # already (see vm-lock.sh's own header).
    HIMMEL_VM_AR_RAM_MB="${HIMMEL_VM_AR_RAM_MB:-4096}"
    if [ -r /proc/meminfo ]; then
        free_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
        if [ -n "$free_mb" ] && [ "$free_mb" -lt "$HIMMEL_VM_AR_RAM_MB" ]; then
            _vm_fail "only ${free_mb}MB free host RAM, below the HIMMEL_VM_AR_RAM_MB=${HIMMEL_VM_AR_RAM_MB}MB per-clone budget — refusing to boot $CLONE_NAME"
        fi
    fi

    ssh_wait="${HIMMEL_VM_AR_SSH_WAIT:-180}"
    vbox_py '
vbox.ensure_running(sys.argv[1])
print(vbox.wait_for_ssh("127.0.0.1", int(sys.argv[2]), timeout=int(sys.argv[3])))
' "$CLONE_NAME" "$PORT" "$ssh_wait" >/dev/null || _vm_fail "$CLONE_NAME did not answer ssh on 127.0.0.1:$PORT after boot (waited ${ssh_wait}s)"
}

# --- ssh/scp to the clone. StrictHostKeyChecking=no + a null known_hosts
# file are load-bearing here, not cosmetic: this host's known_hosts holds
# stale keys for [127.0.0.1]:2222 from a retired VM, so a plain ssh to a
# freshly (re)keyed guest on a REUSED loopback port reports HOST
# IDENTIFICATION CHANGED and refuses to connect. Both read $PORT (set by
# vm_restore) and $GUEST_USER at call time. -----------------------------------
# shellcheck disable=SC2029 # deliberate: the remote command string is built
# with LOCAL variables (branch, dest, token) client-side on purpose.
vm_ssh() {
    ssh -i "${HIMMEL_VM_AR_SSH_KEY:-$HOME/.ssh/id_ed25519}" -p "$PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o BatchMode=yes \
        "${GUEST_USER}@127.0.0.1" "$@"
}

# vm_scp <guest-path> <local-path> — copy one file from the guest to the host.
vm_scp() {
    scp -i "${HIMMEL_VM_AR_SSH_KEY:-$HOME/.ssh/id_ed25519}" -P "$PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 -o BatchMode=yes \
        "${GUEST_USER}@127.0.0.1:$1" "$2"
}

# vm_stage_tree <repo> <remote_dir> <runner> <rsync_e> <rsync_host> <path>...
# Copy repo-relative <path>s (plus the public .env.example placeholder) into
# <remote_dir> on a guest, then assert the guest carries no host secret. Both
# copy paths (rsync when both sides have it, else a tar pipe) apply the shared
# secret excludes (.env, .env.*, *.local.json) — the host checkout's
# gitignored-but-present secrets must never reach the guest (HIMMEL-2540).
#   <runner>      function taking ONE shell-command string and running it on the
#                 guest with stdin passed through (e.g. ssh_vm / vm_ssh)
#   <rsync_e>     the transport for `rsync -e`, e.g. "ssh -p 2222 -i key ..."
#   <rsync_host>  the rsync destination host, e.g. user@host or localhost
# Returns 1 (message on stderr) on a refused stage, a failed copy or a dirty guest.
vm_stage_tree() {
    local repo="$1" remote_dir="$2" runner="$3" rsync_e="$4" rsync_host="$5" _x _p
    shift 5
    local -a rsync_excl=() tar_excl=() rsync_src=()
    declare -F vm_guest_rsync_excludes >/dev/null 2>&1 \
        || . "$repo/scripts/lib/vm-guest-excludes.sh" \
        || { echo "==> REFUSING: cannot load scripts/lib/vm-guest-excludes.sh; nothing was copied" >&2; return 1; }
    while IFS= read -r _x; do rsync_excl+=("$_x"); done < <(vm_guest_rsync_excludes)
    while IFS= read -r _x; do tar_excl+=("$_x"); done < <(vm_guest_tar_excludes)
    # The exclude list must be in force BEFORE any copy: with no errexit a failed load
    # would leave the arrays empty and the secrets already in the guest when the
    # post-copy assert fires (HIMMEL-2540).
    if [ "${#rsync_excl[@]}" -eq 0 ] || [ "${#tar_excl[@]}" -eq 0 ]; then
        echo "==> REFUSING: the secret-exclusion list is empty; nothing was copied" >&2; return 1
    fi

    echo "[stage] copying worktree to $remote_dir ..."
    "$runner" "rm -rf $remote_dir && mkdir -p $remote_dir"
    if command -v rsync >/dev/null 2>&1 && "$runner" 'command -v rsync >/dev/null 2>&1'; then
        # -R + the `/./` marker keeps each path's directories under the guest root (plain
        # rsync would flatten the file entries into it).
        for _p in "$@" .env.example; do rsync_src+=("$repo/./$_p"); done
        rsync -azR -e "$rsync_e" --exclude '.git' --exclude 'node_modules' --exclude 'dist' \
            "${rsync_excl[@]}" "${rsync_src[@]}" "$rsync_host:$remote_dir/" \
            || { echo "==> STAGE FAILED (rsync): the copy to the guest did not complete" >&2; return 1; }
    else
        tar -C "$repo" --exclude=.git --exclude=node_modules --exclude=dist \
            "${tar_excl[@]}" -cf - "$@" | "$runner" "tar -C $remote_dir -xf -" \
            || { echo "==> STAGE FAILED (tar): the copy to the guest did not complete" >&2; return 1; }
        # .env.example is the public placeholder template (a literal file, not the tree).
        "$runner" "cat > $remote_dir/.env.example" 2>/dev/null < "$repo/.env.example" || true
    fi
    # Assert the guest is clean before anything runs there; a secret on the guest is
    # a hard stop, not a warning (HIMMEL-2540).
    vm_guest_assert_clean "$runner" "$remote_dir" full || return 1
}
