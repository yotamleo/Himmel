#!/usr/bin/env bash
# after-report.sh — run the shell-unit after-report (the local twin of the
# public shell-unit CI job) inside a VirtualBox linked-clone VM instead of on
# this host (HIMMEL-2623 PR-B).
#
# Platform guard (linux-only): drives VirtualBox linked clones via
# VBoxManage and ssh/scp on the Linux station; NOT ported to native
# PowerShell. A Windows port would need a VBoxManage.exe equivalent for
# every call here (clonevm, snapshot, showvminfo, controlvm) plus a
# Windows ssh/scp client, and there is no Windows VM lane to test it
# against.
#
# WHY A VM: scripts/ci/run-shell-tests.sh --changed-since origin/main --pr <N>
# takes ~35-45 min per PR here, and every run serialises on ONE machine-wide
# advisory lock (/tmp/himmel-shell-suite-scripts.lock, HIMMEL-1338/2215) —
# with 5-6 legs live the queue becomes the shift's bottleneck. A VM is a
# SEPARATE host, so a run there never contends for that lock at all; this
# script is what makes that separation actually happen.
#
# WHY A STANDALONE SCRIPT, NOT A vmsdk.py VERB: this is a CI/after-report
# WORKFLOW that happens to use a VM, not a VM-lifecycle operation (up/down/
# snapshot/provision — vmsdk.py's actual verb surface). It lives beside the
# rest of the after-report tooling (scripts/quiet-run.sh, the console launch
# shape), which is bash; vmsdk.py is Python. This script CALLS the SDK/vbox
# primitives (scripts/lib/vbox.py) rather than living inside them.
#
# WHY THE CLONES ARE PERSISTENT AND NEVER DELETED: `VBoxManage unregistervm
# <vm> --delete` is a destructive VM-lifecycle op refused outright by this
# harness's auto-mode classifier, so a create-then-delete-per-run cycle
# cannot run here at all — not "should not," CANNOT. Instead each clone
# (himmel-ar-1 .. himmel-ar-$HIMMEL_VM_AR_MAX) is created ONCE with a
# deterministic name and RESTORED to its own baseline snapshot
# ($HIMMEL_VM_AR_SNAPSHOT, default "suite-ready-v4") before every run — the
# same clean-state guarantee a delete-and-recreate cycle would give, with no
# deletion ever asked for.
#
# WHY THE BASELINE SNAPSHOT IS "suite-ready-v4", NOT AN OLDER SNAPSHOT
# (three image-level design facts, not incident colour — introduced at v2/v3
# and carried forward unchanged into v4; the HIMMEL-2747 re-clone below
# reconfirmed them empirically rather than merely inheriting the assumption):
#   1. `VBoxManage clonevm` regenerates the guest's MACs, but the original
#      "suite-ready" (v1) base image's netplan pinned `match: macaddress:` to
#      the SOURCE VM's own MAC — so every linked clone got a NIC matching
#      nothing: no DHCP, no ssh, ever. No clone of that original base could
#      ever have worked. Fixed at IMAGE level: netplan matches on interface
#      NAME (enp0s3), and cloud-init's network config is disabled so it
#      cannot regenerate a MAC-pinned file on its own.
#   2. `VBoxManage snapshot restore` reverts MACHINE CONFIG, not just disk —
#      a per-clone `modifyvm` fix would be silently undone on the very NEXT
#      restore, which is every run. Only an image-level fix persists, which
#      is why v4 (like v3 before it) bakes every machine-config change —
#      bidirectional clipboard AND drag-and-drop, this time — into the
#      snapshot itself rather than patching it per-clone.
#   3. A linked clone INHERITS the source's `/etc/machine-id` and ssh host
#      keys verbatim unless the golden image ships unpersonalised — an
#      identity collision across every clone of the same base, not just a
#      cosmetic duplicate. Fixed at v3 by shipping an UNPERSONALISED golden
#      image: machine-id truncated to zero bytes, the dbus id symlinked to
#      it, host keys removed, and a first-boot oneshot that regenerates
#      both; v4 ships the same unpersonalised state. Each CLONE of that
#      image then regenerates its own identity on ITS first boot — which is
#      also why a clone's own baseline snapshot must be taken AFTER that
#      first boot, never before: snapshotting the still-unpersonalised state
#      would just push the same collision one level down, clone-to-clone
#      this time. The GOLDEN image is the opposite case: it is snapshotted
#      BEFORE any identity exists at all, so "snapshot after first boot" is
#      a rule for a clone's own baseline, never for the golden image itself.
#      If a leg boots `ubuntu_new` to modify the image, it must re-zero
#      `/etc/machine-id`, remove the ssh host keys and re-create
#      `/etc/himmel-regen-identity` before snapshotting, or the new golden
#      image ships personalised. This is not an assumption carried forward
#      untested: the HIMMEL-2747 re-clone of himmel-ar-1 from
#      `ubuntu_new@suite-ready-v4` (source snapshot
#      92a7e71a-6dbd-48a9-bda3-fc1ef1dadfc7, new VM UUID
#      f657ac00-5a92-4069-a93e-233975b39d3e) proved it empirically on
#      2026-09-07: machine-id 3234173620d64e4abedbf4756cb3812c and all three
#      ssh host keys (ECDSA SHA256:c7/D07snTSLMRztT4v/nBi70OP2bV8g28cfvewGUlsY,
#      ED25519 SHA256:P+1BfqjlejSTjasOlMj5H1XJDd6m5HgeOCaU4bnxgQ0, RSA
#      SHA256:AMmgHT+b1nf7wOlxa9Ev11iekL/va8F5NXl1iDZcicc) were freshly
#      generated at the clone's first boot, not inherited from `ubuntu_new` —
#      exactly what a correctly-unpersonalised golden image predicts, and
#      the opposite of what the v1/v2 inheritance bug produced.
# The old "suite-ready" (v1) snapshot is DELIBERATELY KEPT, not tidied up:
# himmel-ar-1's linked-clone disk chain still runs back through FOUR
# `ubuntu_new` differencing disks down to the base cloud image — v4 -> ... ->
# v1 -> `ubuntu-noble-24.04-cloudimg.vmdk` — so deleting any snapshot in that
# chain would break the clone. "suite-ready-v2" and "suite-ready-v3" also
# still exist on ubuntu_new for the same reason: superseded, never deleted,
# and not the default.
#
# THE DEFAULT IS "suite-ready-v4" (HIMMEL-2738/2681/2747). v4 adds, over v3:
# VirtualBox Guest Additions userspace (`virtualbox-guest-utils`, installed
# from the guest side because the host has no VBoxGuestAdditions.iso to
# attach); bidirectional clipboard AND drag-and-drop set as MACHINE CONFIG
# (draganddrop moved disabled -> bidirectional; clipboard was already
# bidirectional); a tty1 auto-login drop-in so an operator has a console to
# reach the guest at all; and node 24.20.0 + npm 11.19.0 + bun 1.4.2 + unzip
# + Claude Code 2.1.263, which closes HIMMEL-2681's runtime-skew precondition
# (v3 shipped node 18.19.1 against this repo's `.nvmrc` pin of 24, and no bun
# at all — the skew HIMMEL-2681 measured as the cause of several reds in the
# first VM suite run).
#
# HOW THE MOVE WAS ACTUALLY MADE (HIMMEL-2747, 2026-09-07): NOT by pointing
# this script's default at a newer snapshot name against the SAME clone —
# himmel-ar-1 cannot be REBASED onto a newer source snapshot; a linked
# clone's disk chain is bound to the source snapshot it was cut from, and no
# VBoxManage operation re-points it. Instead the operator ran `VBoxManage
# unregistervm himmel-ar-1 --delete` on the old v3-based clone (machine-id
# 545dddc624234605ab16e348a6706c12) and re-created himmel-ar-1 as a fresh
# linked clone of `ubuntu_new@suite-ready-v4`. It was booted once so
# himmel-firstboot-identity could regenerate machine-id and host keys
# (confirmed empirically, see fact 3 above), then powered off and
# snapshotted as the clone's OWN baseline `suite-ready-v4`
# (6b4330b0-7da8-4ae4-a660-42cca9dd43ae) — never before that first boot, for
# the reason given above. Machine config was reproduced from the persisted
# pre-delete baseline: NAT forward ssh,tcp,127.0.0.1,2231,,22, 4096MB RAM, 4
# cpus, vram 32, vmsvga, nic1 nat, with draganddrop moved disabled ->
# bidirectional to match the new image. Guest content confirmed present:
# node 24.20.0, npm 11.19.0, claude 2.1.263, bun 1.4.2.
#
# KNOWN CAVEAT (do not "fix" this here — it is a separate ticket): bun lives
# at ~/.bun/bin/bun and is on the LOGIN-shell PATH via .bashrc, but is NOT on
# the non-interactive ssh PATH that this script's own guest_ssh() uses (a
# plain `ssh user@host "cmd"`, below). A guest suite run through this script
# therefore does not currently see bun even though the image has it
# installed.
#
# THE VACUOUS-PASS TRAP THIS SCRIPT MUST NEVER FALL INTO AGAIN (read this
# before touching the default for the NEXT migration, v4 -> v5): a snapshot
# merely NAMED suite-ready-vN on a clone that still carries the PREVIOUS
# image's guest content reports green while silently measuring the suites on
# stale software — the exact trap HIMMEL-2681 exists to stop, and the reason
# "just rename the snapshot" is never an acceptable migration here.
# Hand-upgrading the guest INSIDE a clone's own writable differencing disk
# (boot it, apt-install the new packages, snapshot that as its own baseline)
# is technically possible and is STILL rejected on MERIT, not impossibility:
# it produces a hand-provisioned near-duplicate of the golden image that no
# longer descends from it, drifting silently out from under whoever
# provisioned it — "restore to the baseline" would then mean "restore to
# whatever someone typed into this one clone." The only sound path,
# demonstrated by this migration: delete the clone for real (an operator
# action — this harness's auto-mode classifier refuses `VBoxManage
# unregistervm --delete` outright, so it CANNOT happen from a session),
# re-clone from the new golden snapshot, boot once to regenerate identity,
# VERIFY machine-id/host-keys are actually fresh (not inherited) and guest
# content actually matches the new image's manifest, THEN move this script's
# SNAPSHOT default together with dry-run-restore.sh's and SKILL.md's — T10 in
# test-after-report.sh asserts all three agree, by design. Editing only the
# docs to claim a newer default, without ever re-cutting the clone, produces
# an outright false claim rather than a vacuous pass, but is exactly as
# unacceptable.
#
# WHY NO clone_himmel(): scripts/lib/vmsdk.py's VM.clone_himmel() is the
# credential-safe pattern this script's guest checkout follows (HTTPS with an
# ephemeral x-access-token PAT, never an operator SSH key) — but it refuses
# when its destination already exists, and the "suite-ready-v4" snapshot
# bakes a WARM checkout at ~/himmel (with origin/main already fetched)
# precisely so every run does NOT re-clone from scratch. This script instead
# does the credential-safe part clone_himmel does — get the PAT from the
# PRIMARY checkout's .env, use it ONLY as a positional `git fetch` source
# URL, never write it into `git remote` config (so it never touches
# .git/config at all, stripping included) — applied to a FETCH of the PR
# branch (and a refresh of origin/main) into that warm checkout instead of a
# fresh clone.
#
# THE GUEST USER, ONE LINE TO CHANGE (HIMMEL-2623): the guest SSH login for
# $HIMMEL_VM_AR_SOURCE_VM is read from scripts/lib/vms.json's
# "<source-vm>".user field (a literal, resolved the same way
# scripts/lib/vmsdk.py's VM class now resolves it — literal `user` wins over
# a possibly-stale `user_env`). To repoint every after-report run at a
# different guest login, edit THAT ONE JSON field; $HIMMEL_VM_AR_GUEST_USER
# below is a test/dev override only, never touched in production use.
#
# Usage: scripts/vm/after-report.sh <branch> <pr>
#
# Env (all optional):
#   HIMMEL_VM_AR_MAX          concurrent clone cap (default 2; 1 is valid,
#                             just not the default)
#   HIMMEL_VM_AR_BASE_PORT    port-allocator floor (default 2231 — see
#                             scripts/vm/port-alloc.sh)
#   HIMMEL_VM_AR_SOURCE_VM    base VM to clone from (default ubuntu_new)
#   HIMMEL_VM_AR_SNAPSHOT     baseline snapshot name (default suite-ready-v4)
#   HIMMEL_VM_AR_GUEST_USER   TEST/DEV override for the guest SSH login —
#                             production resolves this from vms.json (see
#                             above); never set in production use
#   HIMMEL_VM_AR_SSH_KEY      ssh identity (default ~/.ssh/id_ed25519)
#   HIMMEL_VM_AR_SUITE_TIMEOUT  guest-side wall-clock cap for the suite run,
#                             seconds (default 3600)
#   HIMMEL_VM_AR_SSH_WAIT     seconds to wait for the guest's ssh banner
#                             after boot before giving up (default 180; a
#                             test seam so an unreachable-guest case does not
#                             have to wait 3 minutes to prove the fallback)
#   HIMMEL_VM_AR_SLOT_WAIT    seconds to wait for a free clone slot before
#                             giving up (default 7200)
#   HIMMEL_VM_AR_LOCK_DIR     clone-slot lock directory (default /tmp; test
#                             seam)
#   VBOXMANAGE_PATH           VBoxManage binary. UNSET requires
#                             HIMMEL_VM_AR_LIVE=1 (see below) — an unset
#                             VBOXMANAGE_PATH can never silently resolve to a
#                             real binary (HIMMEL-2623 incident hardening).
#                             When set (a real path, or a test stub) it is
#                             used as-is regardless of HIMMEL_VM_AR_LIVE.
#   HIMMEL_VM_AR_LIVE         must be exactly "1" to let an UNSET
#                             VBOXMANAGE_PATH fall through to the real
#                             default (/usr/bin/VBoxManage on this station).
#                             Never set this for a test — set VBOXMANAGE_PATH
#                             to a stub instead.
#   HIMMEL_VM_PYTHON          venv python for driving scripts/lib/vbox.py
#                             (default ~/.himmel/vm-venv/bin/python — the
#                             system python on this station is
#                             externally-managed)
#   HIMMEL_VM_LOCK, HIMMEL_VM_LOCK_DIR, HIMMEL_VM_LOCK_TTL,
#   HIMMEL_VM_LOCK_WAIT, HIMMEL_VM_LOCK_WAIT_INTERVAL,
#   HIMMEL_VM_QUEUE_STALE_AFTER_CEILING
#                             the vm-lock (scripts/vm/vm-lock.sh) held around
#                             every real VBoxManage-touching span — same
#                             knob shapes as the suite lock's own
#                             SUITE_LOCK*/SUITE_QUEUE_STALE_AFTER_CEILING;
#                             see that file's own header for defaults + design
#   GH_CMD, GH_TIMEOUT_SECS   same knobs run-shell-tests.sh's own --pr post
#                             uses; kept identical so the two posting paths
#                             behave the same under the same overrides
#
# FALLBACK: if the VM runner is unavailable for ANY reason (VBoxManage
# missing, the venv python missing, no free clone slot, the guest
# unreachable, the guest checkout carrying host secrets it must never carry
# — see HIMMEL-2540 below), this script FAILS LOUDLY (never a silent green)
# and names the host invocation to run instead:
#   bash scripts/ci/run-shell-tests.sh --changed-since origin/main --pr <N>
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/vm/port-alloc.sh
. "$REPO_ROOT/scripts/vm/port-alloc.sh"

BRANCH="${1:-}"
PR="${2:-}"

usage() {
    echo "usage: scripts/vm/after-report.sh <branch> <pr>" >&2
    exit 2
}
if [ -z "$BRANCH" ] || [ -z "$PR" ]; then
    usage
fi
case "$BRANCH" in
    *[!A-Za-z0-9._/-]*)
        echo "after-report.sh: invalid branch '$BRANCH' (branch/tag characters only)" >&2
        exit 2
        ;;
esac
case "$PR" in
    ''|*[!0-9]*)
        echo "after-report.sh: PR must be a number, got '$PR'" >&2
        exit 2
        ;;
esac

HOST_FALLBACK="bash scripts/ci/run-shell-tests.sh --changed-since origin/main --pr $PR"

# fail <reason> — the ONE exit path for "the VM runner did not deliver an
# after-report," whether that is unavailability (VBoxManage/python/slot/ssh
# missing) or a genuine run-time refusal (secrets in the guest checkout). It
# never lets the run be silently reported as clean — HIMMEL-2623 requirement
# 7: the host path is the fallback, always named, never assumed.
fail() {
    echo "ERROR: VM after-report runner did not complete: $1" >&2
    echo "Run the host after-report instead:" >&2
    echo "  $HOST_FALLBACK" >&2
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
HIMMEL_VM_AR_VBOXMANAGE_DEFAULT="${HIMMEL_VM_AR_VBOXMANAGE_DEFAULT:-/usr/bin/VBoxManage}"
if [ -z "${VBOXMANAGE_PATH:-}" ] && [ "${HIMMEL_VM_AR_LIVE:-0}" != "1" ]; then
    fail "VBOXMANAGE_PATH is unset and HIMMEL_VM_AR_LIVE is not '1' — refusing to fall through to a real VBoxManage (HIMMEL-2623 incident hardening). Set VBOXMANAGE_PATH explicitly (a real path, or a stub for testing), or HIMMEL_VM_AR_LIVE=1 to run for real."
fi
VBOXMANAGE="${VBOXMANAGE_PATH:-$HIMMEL_VM_AR_VBOXMANAGE_DEFAULT}"
export VBOXMANAGE_PATH="$VBOXMANAGE"
command -v "$VBOXMANAGE" >/dev/null 2>&1 || [ -x "$VBOXMANAGE" ] \
    || fail "VBoxManage not found at '$VBOXMANAGE' (set VBOXMANAGE_PATH)"

# shellcheck source=scripts/vm/vm-lock.sh
. "$REPO_ROOT/scripts/vm/vm-lock.sh"

HIMMEL_VM_PYTHON="${HIMMEL_VM_PYTHON:-$HOME/.himmel/vm-venv/bin/python}"
[ -x "$HIMMEL_VM_PYTHON" ] \
    || fail "venv python not found/executable at '$HIMMEL_VM_PYTHON' (needed to drive scripts/lib/vbox.py; set HIMMEL_VM_PYTHON)"

MAX="${HIMMEL_VM_AR_MAX:-2}"
case "$MAX" in
    ''|*[!0-9]*|0)
        echo "after-report.sh: HIMMEL_VM_AR_MAX must be a positive integer, got '$MAX'" >&2
        exit 2
        ;;
esac

SOURCE_VM="${HIMMEL_VM_AR_SOURCE_VM:-ubuntu_new}"
SNAPSHOT="${HIMMEL_VM_AR_SNAPSHOT:-suite-ready-v4}"
VMS_JSON="$REPO_ROOT/scripts/lib/vms.json"

# vbox_py <python-code> — run a vbox.py-scoped snippet through the venv
# python; $1 is appended after `import vbox` has already been done, so
# callers just reference `vbox.<fn>(...)`.
# vbox_py <python-code> [argv...] — run a vbox.py-scoped snippet through the
# venv python. CR finding codex-15 (same shape, swept here from
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

# --- guest user (HIMMEL-2623: ONE place — see the file header) -----------
if [ -n "${HIMMEL_VM_AR_GUEST_USER:-}" ]; then
    GUEST_USER="$HIMMEL_VM_AR_GUEST_USER"
else
    # CR finding codex-2: $VMS_JSON/$SOURCE_VM used to be interpolated
    # straight into the python SOURCE text — same class as the vbox_py fix
    # above (codex-15), just missed here. An apostrophe in either value
    # breaks the string literal, and a crafted value injects python
    # statements. Both now travel through sys.argv instead.
    GUEST_USER=$("$HIMMEL_VM_PYTHON" -c '
import json, sys
d = json.load(open(sys.argv[1]))
u = d.get(sys.argv[2], {}).get("user")
sys.exit(1) if not u else print(u)
' "$VMS_JSON" "$SOURCE_VM" 2>/dev/null) || fail "no literal 'user' set for '$SOURCE_VM' in scripts/lib/vms.json — that JSON field is the single line to fix (HIMMEL-2623)"
fi

# --- claim a clone slot (1..MAX), FIFO not required here: PR-A's host lock
# already owns fairness for the machine-wide lock this VM path exists to
# avoid; this is just a concurrency CAP on the clones themselves -----------
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
command -v flock >/dev/null 2>&1 || fail "'flock' not found on PATH — required to claim a clone slot (scripts/vm/after-report.sh's platform guard assumes it; install util-linux or equivalent)"
LOCK_DIR="${HIMMEL_VM_AR_LOCK_DIR:-/tmp}"
mkdir -p "$LOCK_DIR" || fail "cannot create lock directory $LOCK_DIR"
SLOT_WAIT="${HIMMEL_VM_AR_SLOT_WAIT:-7200}"
CLONE_IDX=""
CLONE_FD=""
_slot_deadline=$(( $(date +%s) + SLOT_WAIT ))
while [ -z "$CLONE_IDX" ]; do
    i=1
    while [ "$i" -le "$MAX" ]; do
        lockfile="$LOCK_DIR/himmel-vm-ar-$i.lock"
        fd=$(( 200 + i ))
        # A literal fd number is required immediately before `>` in bash's
        # redirection grammar (a variable there is not recognized as the fd
        # prefix), hence eval — the path is shell-quoted via printf %q first
        # so this never re-interprets anything in $lockfile.
        eval "exec $fd>$(printf '%q' "$lockfile")" 2>/dev/null || fail "cannot open lock file $lockfile"
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
    [ "$(date +%s)" -lt "$_slot_deadline" ] || fail "all $MAX clone slot(s) busy after ${SLOT_WAIT}s (HIMMEL_VM_AR_MAX=$MAX)"
    sleep 5
done
CLONE_NAME="himmel-ar-$CLONE_IDX"

# --- vm-lock: held around EVERY real VBoxManage-touching span for this
# clone, without exception — clone/snapshot/restore/start/stop, the whole
# way from here to the cleanup trap's power_off (HIMMEL-2623 incident
# hardening; see scripts/vm/vm-lock.sh's own header for the design this
# mirrors — the FIFO suite lock — and every deliberate divergence from it).
# Acquired BEFORE the very first VBoxManage-touching call (the existence
# check just below), so a lock refusal is a control proving "a real call
# without holding the lock is refused" — nothing above this line has
# touched VBoxManage yet.
vm_lock_acquire_waiting "$CLONE_NAME"
_vm_lock_rc=$?
case "$_vm_lock_rc" in
    0) ;;
    5) fail "timed out waiting for the vm-lock on '$CLONE_NAME' (HIMMEL_VM_LOCK_WAIT=${HIMMEL_VM_LOCK_WAIT:-0}s)" ;;
    *) fail "could not acquire the vm-lock on '$CLONE_NAME' — see the REFUSED line above" ;;
esac

# HIMMEL-2688: GUEST_TMP/cleanup_guest_token are declared HERE — before
# `cleanup()` and its EXIT trap even exist — not down at the guest-checkout
# section where the token actually gets used. cleanup() runs under `set -u`
# and can fire before GUEST_TMP is ever assigned a real value (any early
# `fail`, or a signal landing before the guest checkout starts), so the
# empty default here is what keeps that a clean no-op instead of an
# unbound-variable error. cleanup_guest_token is self-guarding for the same
# reason: safe to call unconditionally, including on a tmp dir this process
# never actually created, mirroring vm_lock_release's own "safe to call
# unconditionally" contract elsewhere in this file's design. Calling
# guest_ssh from inside it is safe even though guest_ssh is only defined
# later in the script: GUEST_TMP is never non-empty until AFTER guest_ssh
# has already run once (to produce it), so by the time the guard above lets
# execution reach the guest_ssh call, it is always already defined.
GUEST_TMP=""
cleanup_guest_token() {
    [ -n "${GUEST_TMP:-}" ] || return 0
    guest_ssh "rm -rf '$GUEST_TMP'" >/dev/null 2>&1 || true
}

# shellcheck disable=SC2317,SC2329 # invoked indirectly via `trap cleanup EXIT` below
cleanup() {
    # Capture the PENDING exit status FIRST, before anything else in this
    # trap can touch $? (HIMMEL-2623 belt and braces: every step below
    # already returns explicitly, but an explicit final `exit "$rc"` states
    # the final status as a fact rather than an inference from "nothing in
    # here happened to clobber it").
    local rc=$?
    # HIMMEL-2688 (CodeRabbit, PR #2206 review): a TERM/INT landing between
    # the token reaching the guest and the fetch chain completing used to
    # route through this trap WITHOUT ever cleaning it up — cleanup_guest_token
    # was called only from the three guest-checkout call sites below, none
    # of which this trap invoked. The clone got powered off with the PAT
    # still sitting on its disk. Called FIRST, before power_off: removing a
    # file needs the guest actually running — after power-off this would be
    # a silent no-op, which is the one outcome here that looks fixed and
    # is not.
    cleanup_guest_token
    # Best-effort power-off — at end of run, not deferred (HIMMEL-2623): this
    # trap fires on every exit path (success, failure, or an early `fail`
    # after boot), so the clone is never left running past this process.
    # Still holding the vm-lock at this point by construction — power_off is
    # itself a real VBoxManage call, so it must run before the lock below is
    # released, never after.
    # CR finding codex-7: the power-off failure used to be caught inside
    # python, printed as a WARN, and `|| true`'d — so a failed power-off
    # still let $rc report SUCCESS, while the vm-lock and this slot's fd
    # were released right below regardless, making the slot reusable for a
    # VM that may still be running. Re-raise on failure so the shell side
    # can see it, and fold it into $rc — but still unconditionally release
    # the lock and close the fd after: an honest exit status is the fix
    # here, never a wedged machine from a retained lock.
    local poweroff_rc=0
    vbox_py '
try:
    vbox.power_off(sys.argv[1])
except Exception as e:
    print(f"WARN: power_off {sys.argv[1]} failed: {e}", file=sys.stderr)
    sys.exit(1)
' "$CLONE_NAME" 2>&1 >&2 || poweroff_rc=$?
    if [ "$poweroff_rc" -ne 0 ] && [ "$rc" -eq 0 ]; then
        rc=1
    fi
    vm_lock_release "$CLONE_NAME"
    # CR finding codex-2 (round 2): a TERM/INT during first-time clone
    # creation exits through this trap while "himmel-vm-registry" (acquired
    # above, before port allocation) is still held, and the earlier version
    # of this trap released only $CLONE_NAME — leaking the registry lock
    # until its own TTL reclaim, stalling every OTHER runner's first-time
    # clone creation in the meantime. vm_lock_release is documented (see
    # vm-lock.sh) as safe to call unconditionally, including on a name this
    # process never held — it only acts on a name recorded in
    # _VM_LOCK_GEN — so no flag is needed here for the common case where
    # this lock was never taken.
    vm_lock_release "himmel-vm-registry"
    if [ -n "$CLONE_FD" ]; then
        eval "exec $CLONE_FD>&-" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT
# CR finding codex-6: an EXIT-only trap relies on bash's default signal
# disposition for TERM/INT still routing through it in every environment
# this ever runs in — true in ad-hoc testing here, but not something worth
# betting a real VM's power-off and lock release on implicitly. Explicit
# handlers make it a stated fact rather than an inherited default: `exit
# <128+signum>` is the standard portable idiom (it still runs the EXIT trap
# above, so cleanup and the lock release happen exactly once either way).
trap 'exit 143' TERM
trap 'exit 130' INT

# --- create the clone if it does not exist yet -----------------------------
if ! vm_ar_vm_exists "$CLONE_NAME"; then
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
        5) fail "timed out waiting for the vm-lock on 'himmel-vm-registry' while creating $CLONE_NAME" ;;
        *) fail "could not acquire the vm-lock on 'himmel-vm-registry' while creating $CLONE_NAME" ;;
    esac
    PORT=$(vm_ar_next_ports 1)
    _port_rc=$?
    if [ "$_port_rc" -ne 0 ]; then
        vm_lock_release "himmel-vm-registry"
        fail "port allocation failed"
    fi
    if ! "$VBOXMANAGE" clonevm "$SOURCE_VM" --snapshot "$SNAPSHOT" --options link \
            --name "$CLONE_NAME" --register; then
        vm_lock_release "himmel-vm-registry"
        fail "clonevm $SOURCE_VM -> $CLONE_NAME failed"
    fi
    if ! vbox_py 'vbox.ensure_persistent_forward(sys.argv[1], "ssh", int(sys.argv[2]), 22)' "$CLONE_NAME" "$PORT"; then
        vm_lock_release "himmel-vm-registry"
        fail "could not set the persistent NAT forward on $CLONE_NAME (port $PORT)"
    fi
    if ! "$VBOXMANAGE" snapshot "$CLONE_NAME" take "$SNAPSHOT"; then
        vm_lock_release "himmel-vm-registry"
        fail "could not take the baseline '$SNAPSHOT' snapshot on the new clone $CLONE_NAME"
    fi
    vm_lock_release "himmel-vm-registry"
fi

# --- restore to the clean baseline, boot, wait for ssh ---------------------
# Verify the SNAPSHOT NAME actually exists on this clone before touching
# anything (HIMMEL-2623): a stale-default/missing baseline — this script's
# default has already moved once in substance (suite-ready -> suite-ready-v3
# -> suite-ready-v4, the last via the HIMMEL-2747 delete-and-re-clone above,
# not a rename) and will move again for a future migration — must fail with
# a clear, specific message here, not an opaque VBoxManage error three calls
# later.
vbox_py '
names = vbox.list_snapshots(sys.argv[1])
sys.exit(1) if sys.argv[2] not in names else None
' "$CLONE_NAME" "$SNAPSHOT" || fail "snapshot '$SNAPSHOT' does not exist on $CLONE_NAME — check HIMMEL_VM_AR_SNAPSHOT (or that the clone predates a base-snapshot rename)"
vbox_py 'vbox.restore_snapshot(sys.argv[1], sys.argv[2])' "$CLONE_NAME" "$SNAPSHOT" \
    || fail "restore_snapshot($CLONE_NAME, $SNAPSHOT) failed"

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
' "$CLONE_NAME") || fail "$CLONE_NAME is registered but has no loopback ssh (tcp/22) NAT forward — remove it manually or fix scripts/vm/after-report.sh's port bookkeeping"

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
    _free_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
    if [ -n "$_free_mb" ] && [ "$_free_mb" -lt "$HIMMEL_VM_AR_RAM_MB" ]; then
        fail "only ${_free_mb}MB free host RAM, below the HIMMEL_VM_AR_RAM_MB=${HIMMEL_VM_AR_RAM_MB}MB per-clone budget — refusing to boot $CLONE_NAME"
    fi
fi

SSH_WAIT="${HIMMEL_VM_AR_SSH_WAIT:-180}"
vbox_py '
vbox.ensure_running(sys.argv[1])
print(vbox.wait_for_ssh("127.0.0.1", int(sys.argv[2]), timeout=int(sys.argv[3])))
' "$CLONE_NAME" "$PORT" "$SSH_WAIT" >/dev/null || fail "$CLONE_NAME did not answer ssh on 127.0.0.1:$PORT after boot (waited ${SSH_WAIT}s)"

# --- ssh/scp to the clone. StrictHostKeyChecking=no + a null known_hosts
# file are load-bearing here, not cosmetic: this host's known_hosts holds
# stale keys for [127.0.0.1]:2222 from a retired VM, so a plain ssh to a
# freshly (re)keyed guest on a REUSED loopback port reports HOST
# IDENTIFICATION CHANGED and refuses to connect. ---------------------------
SSH_KEY="${HIMMEL_VM_AR_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-i "$SSH_KEY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -o BatchMode=yes)
SCP_OPTS=(-i "$SSH_KEY" -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15 -o BatchMode=yes)
# shellcheck disable=SC2029 # deliberate: the remote command string is built
# with LOCAL variables (branch, dest, token) client-side on purpose.
guest_ssh() { ssh "${SSH_OPTS[@]}" "${GUEST_USER}@127.0.0.1" "$@"; }

# --- guest checkout: fetch the PR branch + refresh origin/main. The PAT is
# never written to `git remote`/.git/config (still true, no token to strip
# afterward — a stronger guarantee than clone_himmel's clone-then-strip, and
# the reason this script does not call clone_himmel: its dest-must-not-exist
# precondition does not fit the warm ~/himmel checkout the suite-ready-v4
# snapshot bakes in) — but that guarantee said nothing about argv, which was
# the actual gap.
#
# HIMMEL-2678 (CodeRabbit, Major/Security): the PAT used to be embedded
# directly in the fetch URL (`https://x-access-token:$TOKEN@github.com/...`).
# `.git/config` was never touched, but the WHOLE URL, token included, was an
# argv element to `ssh` on THIS host (visible in that process's own
# /proc/<pid>/cmdline for as long as it ran) and to `git fetch` on the GUEST
# — a real leak even though the .git/config claim held. The PAT now travels
# only over ssh STDIN, never an argument on either side: written into a file
# under a guest tmp dir readable only by the guest user (umask 077), read by
# a GIT_ASKPASS helper the fetch below points at instead of a credentialed
# URL. cleanup_guest_token (declared up near cleanup(), before this section
# even runs) removes both the token file and the helper on EVERY exit path
# — the three explicit call sites below, AND the EXIT trap itself
# (HIMMEL-2688: a TERM/INT landing in this window used to route through
# that trap without ever calling it, leaving the PAT on the guest's disk) —
# not relied on via the snapshot restore that bounds it anyway.
# -----------------------------------------------------------------------
# shellcheck source=scripts/lib/load-dotenv.sh
. "$REPO_ROOT/scripts/lib/load-dotenv.sh"
load_dotenv himmel_github_token_vm
[ -n "${himmel_github_token_vm:-}" ] || fail "himmel_github_token_vm not set in the primary checkout's .env"
FETCH_URL="https://github.com/yotamleo/himmel.git" # leak-allow: hostname the actual private repo this VM script fetches from
# shellcheck disable=SC2088 # a REMOTE path handed to guest_ssh's command
# string — the tilde is expanded by the GUEST's shell, not this one.
GUEST_DEST="~/himmel"

GUEST_TMP=$(guest_ssh "umask 077 && mktemp -d") \
    || fail "could not create a guest tmp dir for the ephemeral fetch token"
GUEST_TOKEN_FILE="$GUEST_TMP/token"
GUEST_ASKPASS="$GUEST_TMP/askpass"

# cleanup_guest_token (defined up near cleanup(), see HIMMEL-2688) removes
# the whole ephemeral tmp dir — askpass helper + token file together,
# whichever of them made it that far. Called explicitly at each `fail`
# between here and the fetch chain completing below, AND unconditionally
# from the EXIT trap itself, so nothing token-shaped survives this process
# on any path — not reliance on the guest's own snapshot-restore-before-
# every-run alone.

# Write the askpass helper first — its content references only PATHS, no
# secret, so this call carries nothing sensitive. It answers BOTH the
# username and password askpass prompts the now-tokenless $FETCH_URL
# triggers (git also asks for a username when the URL carries none): the
# literal `x-access-token` username GitHub's PAT auth expects, and the
# actual token read back out of $GUEST_TOKEN_FILE for anything else.
ASKPASS_SETUP=$(cat <<EOF
cat > '$GUEST_ASKPASS' <<'INNER_EOF'
#!/usr/bin/env bash
case "\$1" in
    Username*) printf '%s' x-access-token ;;
    *) cat '$GUEST_TOKEN_FILE' ;;
esac
INNER_EOF
chmod 700 '$GUEST_ASKPASS'
EOF
)
if ! guest_ssh "$ASKPASS_SETUP"; then
    cleanup_guest_token
    fail "could not write the guest askpass helper"
fi

# The token itself travels over ssh STDIN only — the one place in this
# whole flow an actual secret exists, and it is never an argv element.
if ! printf '%s' "$himmel_github_token_vm" | guest_ssh "umask 077 && cat > '$GUEST_TOKEN_FILE'"; then
    cleanup_guest_token
    fail "could not deliver the fetch token to the guest"
fi

# HIMMEL-2677: the first measured VM run hit two defects here, and fixing
# only the first was not enough. (a) neither refspec forced the ref
# update, so refreshing origin/main from a depth-1 fetch was rejected
# outright as a non-fast-forward against the baseline snapshot's own
# origin/main (which shares no ancestry with a fresh depth-1 tip) — the
# branch refspec only ever "worked" because that ref did not exist yet,
# and would fail identically on any re-run after a force-push. (b) even
# with `+`, a depth-1 tip has no merge base with anything, so
# `run-shell-tests.sh --changed-since origin/main` below would have
# nothing to diff against — silently selecting nothing or everything
# while still reporting green. Both fetches now carry real ancestry (no
# --depth at all) instead: the guest is a WARM checkout that already
# holds most of main's history, so an incremental fetch was never
# expensive here, and giving the branch the same treatment as main keeps
# both fetches structurally identical rather than making the branch's
# correctness depend on which local ref name `--shallow-exclude=main`
# happens to resolve to at fetch time.
#
# A guest whose repo IS shallow (.git/shallow present — possible
# depending on what the baseline image was built with) cannot reconnect
# real history from a plain incremental fetch; `--unshallow` fixes that,
# but ERRORS outright on an already-complete repository, so it can never
# be unconditional. Checked explicitly below rather than assumed either
# way, and applied to the FIRST fetch only: `--unshallow` converts the
# WHOLE repository, not just the ref it's attached to, so the branch
# fetch that follows is already talking to a complete repo either way.
UNSHALLOW=""
guest_ssh "test -f $GUEST_DEST/.git/shallow" && UNSHALLOW="--unshallow"

guest_ssh "GIT_ASKPASS='$GUEST_ASKPASS' GIT_TERMINAL_PROMPT=0 git -C $GUEST_DEST fetch $UNSHALLOW '$FETCH_URL' '+main:refs/remotes/origin/main' \
  && GIT_ASKPASS='$GUEST_ASKPASS' GIT_TERMINAL_PROMPT=0 git -C $GUEST_DEST fetch '$FETCH_URL' '+$BRANCH:refs/remotes/origin/$BRANCH' \
  && git -C $GUEST_DEST checkout -B '$BRANCH' 'origin/$BRANCH'"
FETCH_RC=$?
cleanup_guest_token
[ "$FETCH_RC" -eq 0 ] || fail "guest checkout of branch '$BRANCH' failed (fetch or checkout)"

# --- HIMMEL-2540: never let host secrets/settings reach a guest checkout —
# assert their ABSENCE and refuse to run the suite if any is present. This
# is defense-in-depth (the fetch above never carries them — they are
# gitignored, and the token above was never persisted to .git/config
# either) rather than a one-time bake-time check: it runs on every clone,
# every run. -----------------------------------------------------------
for p in .env .claude/settings.local.json .himmel-dev; do
    # CR finding codex-4: every NONZERO ssh exit used to read as "the file is
    # absent" — including 255, ssh's own convention for a TRANSPORT failure
    # (couldn't connect, connection dropped mid-check), which proves nothing
    # about the file at all. "The check could not run" and "the secret is
    # not there" must never be the same code path on a check that exists to
    # keep .env off a guest — fail CLOSED (refuse) on anything but a clean
    # confirmed-absent (1) or confirmed-present (0).
    guest_ssh "test -e $GUEST_DEST/$p"
    _absence_rc=$?
    case "$_absence_rc" in
        1) ;;  # confirmed absent — the only case that lets the loop continue
        0) fail "guest checkout carries '$p' — refusing to run the suite (HIMMEL-2540: a guest checkout must never carry host secrets or local settings)" ;;
        *) fail "could not verify '$p' is absent from the guest checkout (ssh exited $_absence_rc, not a confirmed 0/1 — likely a transport failure) — refusing to run the suite rather than assume it is safe (HIMMEL-2540)" ;;
    esac
done

REPORT_HEAD=$(guest_ssh "git -C $GUEST_DEST rev-parse HEAD") \
    || fail "could not resolve the guest checkout's HEAD"
REPORT_HEAD=$(printf '%s' "$REPORT_HEAD" | tr -d '[:space:]')

# --- derive the after-report log's ticket label from the branch name; the
# log path shape (/tmp/quiet-run-ar-<ticket>-<ts>.log) matches
# scripts/quiet-run.sh's own naming exactly, because console monitors grep
# for it. --------------------------------------------------------------
TICKET=$(printf '%s' "$BRANCH" | grep -ioE '[a-z]+-[0-9]+' | head -n1 | tr '[:upper:]' '[:lower:]')
if [ -z "$TICKET" ]; then
    TICKET=$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9' '-' | tr '[:upper:]' '[:lower:]' | sed -E 's/-+/-/g; s/^-|-$//g')
fi
TS=$(date +%Y%m%d-%H%M%S)
LOCAL_LOG="/tmp/quiet-run-ar-${TICKET}-${TS}.log"
REMOTE_LOG="himmel-ar-run.log"
SUITE_TIMEOUT="${HIMMEL_VM_AR_SUITE_TIMEOUT:-3600}"

# --- run the suite in the guest. NOT --pr here: the guest has no gh
# credentials and must not get any — the after-report comment is posted
# from the HOST below, mirroring run-shell-tests.sh's own --pr code path. --
#
# HIMMEL-2768: $HOME/.bun/bin is prepended to PATH for the suite command.
# suite-ready-v4 ships bun 1.4.2, but the image only puts it on the PATH via
# ~/.bashrc — and guest_ssh() runs `ssh user@host "cmd"`, a NON-INTERACTIVE,
# non-login shell, where bash's own early return for non-interactive shells
# means .bashrc never executes. So the image shipped bun and the suite runner
# could not see it. That is not a cosmetic gap: it is one loud [SKIP]
# (scripts/telegram/test-phi-egress-guard-parity.sh, via the runner's
# SUITE_REQUIRE_TOOL table) plus one HARD RED —
# scripts/himmelctl/test/test-wizard-luna-sections.sh passes `bun` to
# build_path, which fails closed at scripts/lib/hermetic-path.sh:121
# ("required test tool not found before PATH scrub"). That red is one of the
# nine in HIMMEL-2681's VM baseline and was attributed there to "bun is
# absent entirely", so it was expected to CLEAR on v4 and did not.
#
# Why a PATH prefix on this one command and not `bash -lc`: a login shell
# would source the guest's whole profile for the entire suite run, changing
# PATH ORDER and environment for ~450 suites to fix one missing directory —
# a far wider blast radius than the defect. The prefix applies to `timeout`
# and its children only, which is exactly the runner and the suites it
# spawns. It resolves BEFORE run-shell-tests.sh's own hermetic-PATH scrub,
# which is the moment build_path reads (hence "before PATH scrub" in its own
# error text), so the tool is found where the suite expects to find it.
#
# This is the CALLER-level fix. The image-level one — bun on the system PATH
# (/usr/local/bin symlink, or /etc/environment, which pam_env reads for ssh
# sessions) so every non-interactive consumer sees it without a caller opting
# in — is the correct resting state and is deliberately NOT done here: it
# needs a new golden image, and a linked clone cannot be rebased onto one
# (HIMMEL-2747 had to delete and re-clone for exactly that reason). Fold it
# into whatever cuts suite-ready-v5, then drop this prefix.
guest_ssh "cd $GUEST_DEST && rm -f $REMOTE_LOG && PATH=\"\$HOME/.bun/bin:\$PATH\" timeout $SUITE_TIMEOUT bash scripts/ci/run-shell-tests.sh --changed-since origin/main >$REMOTE_LOG 2>&1; echo EXITCODE=\$? >>$REMOTE_LOG"
guest_run_rc=$?
[ "$guest_run_rc" -ne 255 ] || fail "ssh transport to $CLONE_NAME failed while running the suite (rc 255)"

scp "${SCP_OPTS[@]}" "${GUEST_USER}@127.0.0.1:$GUEST_DEST/$REMOTE_LOG" "$LOCAL_LOG" \
    || fail "could not copy the after-report log back from $CLONE_NAME"

SUITE_RC=$(grep -oE '^EXITCODE=[0-9]+' "$LOCAL_LOG" | tail -n1 | cut -d= -f2)
[ -n "$SUITE_RC" ] || fail "after-report log at $LOCAL_LOG has no EXITCODE marker — the guest run may have been interrupted"

# --- reconstruct run-shell-tests.sh's own --pr summary_block format
# (scripts/ci/run-shell-tests.sh, the block built right before its `gh pr
# comment` call) from the copied-back log, and post it from THIS (host)
# process — mirroring that code path exactly rather than letting the guest
# post (it has no gh credentials and must not get any). ------------------
# CR finding codex-3: a guest run that dies mid-suite (SUITE_TIMEOUT killed
# it, a crash, anything short of reaching its own summary print) still has
# an EXITCODE marker (the trailing `echo EXITCODE=$?` above always runs,
# unconditionally, via `;`) but no PASS/SKIP/FAIL to report. Defaulting
# those to 0 would post "PASS: 0 / FAIL: 0" — indistinguishable from a
# genuinely clean, empty run, which is worse than posting nothing at all.
# The presence of the run's OWN "== Summary ==" line is what actually
# proves it reached a verdict; gate the whole PASS/SKIP/FAIL shape on it.
if grep -q '^== Summary ==' "$LOCAL_LOG"; then
    pass=$(grep -oE '^ PASS: [0-9]+' "$LOCAL_LOG" | tail -n1 | awk '{print $2}')
    skip=$(grep -oE '^ SKIP: [0-9]+' "$LOCAL_LOG" | tail -n1 | awk '{print $2}')
    fail_count=$(grep -oE '^ FAIL: [0-9]+' "$LOCAL_LOG" | tail -n1 | awk '{print $2}')
    timed_out=$(grep -oE '^ TIMED OUT: [0-9]+' "$LOCAL_LOG" | tail -n1 | awk '{print $3}')
    cap_exceeded=$(grep -oE '^ CAP EXCEEDED \(assertions passing\): [0-9]+' "$LOCAL_LOG" | tail -n1 | awk '{print $NF}')
    budget_expired=0
    grep -q '^ERROR: run budget of' "$LOCAL_LOG" && budget_expired=1

    summary_block=$(printf '== Summary ==\n head: %s\n scope: %s\n PASS: %s\n SKIP: %s\n FAIL: %s' \
        "$REPORT_HEAD" "scripts" "${pass:-0}" "${skip:-0}" "${fail_count:-0}")
    if [ -n "$timed_out" ] && [ "$timed_out" -gt 0 ] 2>/dev/null; then
        summary_block="${summary_block}
$(printf ' TIMED OUT: %s (counted in FAIL)' "$timed_out")"
    fi
    if [ -n "$cap_exceeded" ] && [ "$cap_exceeded" -gt 0 ] 2>/dev/null; then
        summary_block="${summary_block}
$(printf ' CAP EXCEEDED (assertions passing): %s' "$cap_exceeded")"
    fi
    if [ "$budget_expired" -eq 1 ]; then
        summary_block="${summary_block}
$(printf ' TRUNCATED: yes (run budget expired — not every suite ran)')"
    fi
    summary_block="${summary_block}
$(printf ' CHANGED-SINCE: origin/main (suites were conditionally filtered — not full scope coverage)')"
    summary_block="${summary_block}
$(printf ' RAN-IN: VM clone %s (HIMMEL-2623 — a separate host, not this machine'"'"'s lock domain)' "$CLONE_NAME")"
else
    summary_block=$(printf 'DIED-BEFORE-SUMMARY: the guest run exited (rc=%s) before printing its own "== Summary ==" — no PASS/SKIP/FAIL verdict exists for this run.\n head: %s\n scope: %s\n RAN-IN: VM clone %s (HIMMEL-2623)' \
        "$SUITE_RC" "$REPORT_HEAD" "scripts" "$CLONE_NAME")
fi

if command -v "${GH_CMD:-gh}" >/dev/null 2>&1; then
    _gh_report_cmd=("${GH_CMD:-gh}" pr comment "$PR" --body "$summary_block")
    if command -v timeout >/dev/null 2>&1; then
        _gh_report_cmd=(timeout "${GH_TIMEOUT_SECS:-30}" "${_gh_report_cmd[@]}")
    fi
    if "${_gh_report_cmd[@]}" >/dev/null 2>&1; then
        echo "NOTE: after-report posted to PR #$PR"
    else
        echo "WARN: could not post the after-report to PR #$PR (gh pr comment failed) — the log at $LOCAL_LOG is still the record." >&2
    fi
else
    echo "WARN: 'gh' is not on PATH — could not post the after-report to PR #$PR." >&2
fi

echo "after-report log: $LOCAL_LOG"
exit "$SUITE_RC"
