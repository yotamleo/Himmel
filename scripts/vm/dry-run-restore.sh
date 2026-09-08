#!/usr/bin/env bash
# dry-run-restore.sh — prove a clone can be restored/booted/reached over ssh
# and then powered back off, WITHOUT touching its guest filesystem at all
# (HIMMEL-2623 PR-B — written to verify himmel-ar-1's usability after it was
# interrupted mid-restore_snapshot during the after-report.sh incident this
# ticket's hardening responds to; the operator runs this, not this session).
#
# Platform guard (linux-only): drives VirtualBox via VBoxManage/vbox.py and
# ssh-probes the guest on the Linux station; NOT ported to native
# PowerShell. Same sibling as after-report.sh — a Windows port needs a
# VBoxManage.exe equivalent for every call here, and no Windows VM lane
# exists to test it against.
#
# Does exactly four real VBoxManage-touching things, in order, all under the
# SAME vm-lock as after-report.sh (scripts/vm/vm-lock.sh) so it can never
# race a live after-report.sh run against the same clone:
#   1. restore_snapshot(<vm>, <snapshot>)
#   2. ensure_running(<vm>)
#   3. wait_for_ssh(127.0.0.1, <port>)   -- proves the guest actually boots
#      and its sshd answers; NEVER logs in, NEVER touches the guest checkout
#   4. power_off(<vm>)                   -- always, even on failure
#
# Usage: scripts/vm/dry-run-restore.sh <vm-name> [snapshot]
#   snapshot defaults to HIMMEL_VM_AR_SNAPSHOT or "suite-ready-v4" (the
#   current default as of HIMMEL-2747) — NOT "suite-ready" (v1, kept
#   deliberately, never deleted: himmel-ar-1's disk chain still runs back
#   through it), which pinned netplan to the SOURCE VM's own MAC and so could
#   never answer ssh from any clone at all; NOT "suite-ready-v2" (fixed that,
#   but still exists on ubuntu_new, superseded); and NOT "suite-ready-v3"
#   (also kept, also superseded) — a linked clone also inherits the source's
#   /etc/machine-id and ssh host keys verbatim, an identity collision v2
#   predates and v3 fixed by shipping unpersonalised (machine-id zeroed, host
#   keys removed, a first-boot oneshot regenerating both). That is why a
#   clone's OWN baseline snapshot must be taken AFTER its first boot, not
#   before — a rule v4 inherits unchanged. v4 (HIMMEL-2738/2681) adds Guest
#   Additions, bidirectional clipboard AND drag-and-drop as machine config, a
#   tty1 auto-login console, and node 24.20.0 + npm 11.19.0 + bun 1.4.2 +
#   Claude Code 2.1.263 on top, closing HIMMEL-2681's runtime-skew gap (v3
#   shipped node 18.19.1 against this repo's .nvmrc pin of 24). See
#   after-report.sh's own header for the full image-level explanation and
#   the HIMMEL-2747 migration record (himmel-ar-1 was deleted and re-cloned
#   from the golden v4 image, identity verified regenerated, not a rename of
#   the snapshot name). This script itself verifies the named snapshot
#   actually exists on <vm-name> before touching anything (see the
#   vbox.list_snapshots check below) rather than assuming.
#
# Same opt-in guard as after-report.sh (HIMMEL-2623 incident hardening): an
# unset VBOXMANAGE_PATH requires HIMMEL_VM_AR_LIVE=1 to fall through to the
# real default. Env otherwise mirrors after-report.sh's own knobs
# (VBOXMANAGE_PATH, HIMMEL_VM_PYTHON, HIMMEL_VM_AR_SSH_WAIT, the HIMMEL_VM_LOCK*
# family) — see that script's header for the full list and defaults.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

VM_NAME="${1:-}"
SNAPSHOT="${2:-${HIMMEL_VM_AR_SNAPSHOT:-suite-ready-v4}}"
[ -n "$VM_NAME" ] || { echo "usage: scripts/vm/dry-run-restore.sh <vm-name> [snapshot]" >&2; exit 2; }

# fail <reason> — the ONE failure exit path. Prints BOTH an ERROR: line
# (stderr, for a human reading live) and a DRY-RUN FAILED: line (STDOUT,
# unambiguous and grep-safe on its own) — belt AND braces against exactly
# the vacuous-rc trap that has bitten this station twice before (a masked
# pipeline/dpkg-lock apt-install case): even a caller whose own pipe or
# wrapper loses this process's real exit status still has an unambiguous,
# greppable verdict in the captured text. `exit 1` is still the primary
# signal and is verified directly (no pipe) by test-dry-run-restore.sh's RED
# control.
fail() {
    echo "ERROR: dry-run-restore for '$VM_NAME' did not complete: $1" >&2
    printf 'DRY-RUN FAILED: %s\n' "$1"
    exit 1
}

# --- same opt-in guard as after-report.sh (HIMMEL-2623) --------------------
HIMMEL_VM_AR_VBOXMANAGE_DEFAULT="${HIMMEL_VM_AR_VBOXMANAGE_DEFAULT:-/usr/bin/VBoxManage}"
if [ -z "${VBOXMANAGE_PATH:-}" ] && [ "${HIMMEL_VM_AR_LIVE:-0}" != "1" ]; then
    fail "VBOXMANAGE_PATH is unset and HIMMEL_VM_AR_LIVE is not '1' — refusing to fall through to a real VBoxManage. Set VBOXMANAGE_PATH explicitly, or HIMMEL_VM_AR_LIVE=1 to run for real."
fi
VBOXMANAGE="${VBOXMANAGE_PATH:-$HIMMEL_VM_AR_VBOXMANAGE_DEFAULT}"
export VBOXMANAGE_PATH="$VBOXMANAGE"
command -v "$VBOXMANAGE" >/dev/null 2>&1 || [ -x "$VBOXMANAGE" ] \
    || fail "VBoxManage not found at '$VBOXMANAGE' (set VBOXMANAGE_PATH)"

HIMMEL_VM_PYTHON="${HIMMEL_VM_PYTHON:-$HOME/.himmel/vm-venv/bin/python}"
[ -x "$HIMMEL_VM_PYTHON" ] \
    || fail "venv python not found/executable at '$HIMMEL_VM_PYTHON' (set HIMMEL_VM_PYTHON)"

# shellcheck source=scripts/vm/vm-lock.sh
. "$REPO_ROOT/scripts/vm/vm-lock.sh"
# shellcheck source=scripts/vm/port-alloc.sh
. "$REPO_ROOT/scripts/vm/port-alloc.sh"

# vbox_py <python-code> [argv...] — run a vbox.py-scoped snippet through the
# venv python. CR finding codex-15: <python-code> must be a FIXED, trusted
# literal (never containing a shell variable) — every piece of DATA the
# snippet needs (a VM name, a snapshot name, a port) is passed as a
# trailing argv element and read back via sys.argv[N], never interpolated
# into the python SOURCE text. A VM/snapshot name reaches this script
# straight from argv with no validation regex (unlike after-report.sh's
# BRANCH, which IS regex-validated) — interpolating it into a python
# single-quoted string literal means an apostrophe breaks the literal and a
# crafted value executes arbitrary python. argv is immune to this
# regardless of content; a quoting/escaping patch is not, because the next
# edit re-introduces the same hole.
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

vm_ar_vm_exists "$VM_NAME" || fail "'$VM_NAME' is not a registered VBoxManage VM"

vm_lock_acquire_waiting "$VM_NAME"
_lock_rc=$?
case "$_lock_rc" in
    0) ;;
    5) fail "timed out waiting for the vm-lock on '$VM_NAME' (HIMMEL_VM_LOCK_WAIT=${HIMMEL_VM_LOCK_WAIT:-0}s)" ;;
    *) fail "could not acquire the vm-lock on '$VM_NAME' — see the REFUSED line above" ;;
esac

# CR finding codex-5 (round 2): this script's whole promise is that a
# preflight refusal (bad PORT/snapshot lookup, both below) touches NOTHING —
# but `trap cleanup EXIT` used to be installed before those preflight steps,
# and cleanup() unconditionally powered off $VM_NAME. So a typo'd snapshot
# name against an already-running himmel-ar-1 would power it off while
# printing a "refused at preflight" message. BOOTED gates the power_off so
# a preflight-only exit never touches the VM's power state.
#
# HIMMEL-2675: BOOTED means "this process may have ATTEMPTED to touch the
# VM's power state", not "confirmed a boot" — it is set immediately BEFORE
# the ensure_running call below, not after. Setting it only on a
# CONFIRMED success left a real gap: ensure_running can itself start the
# VM and then fail partway (a subsequent VBoxManage error, a signal), and
# with BOOTED still 0 in that case cleanup skipped the power-off and
# released the lock with the guest left running. Arming BOOTED before the
# attempt still keeps the preflight guarantee above intact — both
# preflight checks run and can `fail` well before this point, with BOOTED
# untouched — while covering the partial-boot case as well.
BOOTED=0

# shellcheck disable=SC2317,SC2329 # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    # Capture the PENDING exit status FIRST, before anything else in this
    # trap can touch $? — belt and braces (HIMMEL-2623): every step in this
    # trap already returns explicitly, so nothing SHOULD reset it, but an
    # explicit final `exit "$rc"` makes the final status a fact this
    # function states outright, not an inference from "nothing in here
    # happened to clobber it."
    local rc=$?
    if [ "$BOOTED" -eq 1 ]; then
        vbox_py '
try:
    vbox.power_off(sys.argv[1])
except Exception as e:
    print(f"WARN: power_off {sys.argv[1]} failed: {e}", file=sys.stderr)
' "$VM_NAME" 2>&1 >&2 || true
    fi
    # Lock release is NOT conditional on BOOTED — it is acquired above,
    # before this trap is even installed, so it must always be dropped.
    vm_lock_release "$VM_NAME"
    exit "$rc"
}
trap cleanup EXIT
# CR finding codex-5: same rationale as after-report.sh's codex-6 (an
# EXIT-only trap bets a real VM's power-off and lock release on bash's
# default signal disposition) — this script holds the same vm-lock through
# the same restore/boot/wait sequence, so it needs the same explicit
# handlers, not just the sibling's.
trap 'exit 143' TERM
trap 'exit 130' INT

# Verify the snapshot NAME actually exists on this VM before touching
# anything — a renamed/missing baseline must fail with a clear, specific
# message, not an opaque VBoxManage error from the restore call itself.
vbox_py '
names = vbox.list_snapshots(sys.argv[1])
sys.exit(1) if sys.argv[2] not in names else None
' "$VM_NAME" "$SNAPSHOT" || fail "snapshot '$SNAPSHOT' does not exist on $VM_NAME — check the snapshot argument (or that this clone predates a base-snapshot rename)"

echo "1/4 restoring '$VM_NAME' to snapshot '$SNAPSHOT'..."
vbox_py 'vbox.restore_snapshot(sys.argv[1], sys.argv[2])' "$VM_NAME" "$SNAPSHOT" \
    || fail "restore_snapshot($VM_NAME, $SNAPSHOT) failed"
echo "    OK"

# CR finding codex-4 (round 2): PORT must be read AFTER restore_snapshot,
# not before — `snapshot restore` reverts MACHINE CONFIG, not just disk,
# and NAT forwards are part of that config. Reading PORT pre-restore risks
# a stale value if the snapshot's own forward differs from the VM's
# current one; reading it here uses whatever the restore just put in
# effect, which is what wait_for_ssh below actually needs.
PORT=$(vbox_py '
fw = vbox.get_forwards(sys.argv[1])
ssh_fwds = [f for f in fw if f[1] == "tcp" and f[5] == "22" and f[2] == "127.0.0.1"]
sys.exit(1) if not ssh_fwds else print(ssh_fwds[0][3])
' "$VM_NAME") || fail "'$VM_NAME' has no loopback ssh (tcp/22) NAT forward on record"

echo "2/4 booting '$VM_NAME'..."
BOOTED=1
vbox_py 'vbox.ensure_running(sys.argv[1])' "$VM_NAME" \
    || fail "could not power on '$VM_NAME'"
echo "    OK"

SSH_WAIT="${HIMMEL_VM_AR_SSH_WAIT:-180}"
echo "3/4 waiting up to ${SSH_WAIT}s for ssh on 127.0.0.1:$PORT (banner only — no login, no guest filesystem touched)..."
banner=$(vbox_py 'print(vbox.wait_for_ssh("127.0.0.1", int(sys.argv[1]), timeout=int(sys.argv[2])))' "$PORT" "$SSH_WAIT") \
    || fail "'$VM_NAME' did not answer ssh on 127.0.0.1:$PORT within ${SSH_WAIT}s"
echo "    OK ($banner)"

# CR finding codex-7: "DRY-RUN OK" used to print BEFORE shutdown even
# happened (deferred to the EXIT trap) with that trap's own power_off
# wrapped in a try/except that only WARNs on failure — so a script that hit
# a real power_off error still printed success and exited 0, with the VM
# left running. Do the shutdown HERE, verified, before claiming anything;
# the EXIT trap's own power_off remains as a best-effort safety net for
# every OTHER (failure) exit path and is a harmless no-op here since
# vbox.power_off() already treats an already-poweroff VM as a no-op.
echo "4/4 powering '$VM_NAME' back off..."
vbox_py 'vbox.power_off(sys.argv[1])' "$VM_NAME" \
    || fail "power_off($VM_NAME) failed — the guest may still be running; do NOT trust this as a clean dry-run"
echo "    OK"

echo "DRY-RUN OK: '$VM_NAME' restored to '$SNAPSHOT', booted, answered ssh, and powered back off cleanly."
