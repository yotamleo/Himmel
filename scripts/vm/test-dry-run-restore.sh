#!/usr/bin/env bash
# test-dry-run-restore.sh — hermetic coverage for scripts/vm/dry-run-restore.sh
# (HIMMEL-2623 PR-B). Never touches a real VM: the same stateful fake
# VBoxManage pattern as test-after-report.sh, plus a real (throwaway) TCP
# listener standing in for the guest's sshd banner.
#
# The RED control (T1) is the point of this file: a prior live run of this
# script printed its ERROR line and STILL exited 0 — the exact vacuous-rc
# trap that has bitten this station before (an apt install failing under a
# dpkg lock also reported 0, masked by a pipeline). T1 asserts the NON-ZERO
# exit status directly (a plain `$(...)` capture, no pipe into the assertion
# itself — the failure mode this guards against is specifically a lost exit
# code, so the check must read it the one way that cannot itself lose it),
# not merely the presence of the ERROR/DRY-RUN FAILED text.
#
# Platform guard (linux-only): a bash test harness driving a FAKE
# VBoxManage plus a real loopback TCP listener, never a real VM — a
# documented guard suffices here (project convention: a test harness
# needs no .ps1 twin). Bash-only because the script it covers,
# dry-run-restore.sh, is itself linux-only.
#
# Usage: bash scripts/vm/test-dry-run-restore.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/dry-run-restore.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-dry-run-restore.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

PYTHON_BIN=$(command -v python3)
if [ -z "$PYTHON_BIN" ]; then
    # CR finding codex-12: every case in this file needs python3 (vbox.py) —
    # printing "ALL PASS" and exiting 0 here would be a run that verified
    # ZERO cases reading identically to one where every case genuinely
    # passed, to any caller checking only the exit code (this suite's own
    # runner, scripts/ci/run-shell-tests.sh, included). Fail the
    # prerequisite instead: a distinct nonzero exit, never "ALL PASS".
    echo "SKIP: no python3 on PATH — this suite needs it for scripts/lib/vbox.py; NO cases ran, this is UNVERIFIED, not a pass" >&2
    exit 2
fi

FAKEBIN="$WORK/bin"
mkdir -p "$FAKEBIN"
FAKE_VBOXMANAGE="$FAKEBIN/VBoxManage"
cat >"$FAKE_VBOXMANAGE" <<'VBOXEOF'
#!/usr/bin/env bash
set -uo pipefail
STATE="${FAKE_VBOX_STATE:?FAKE_VBOX_STATE not set}"
mkdir -p "$STATE"
reg_file="$STATE/registered.list"
touch "$reg_file"
# Per-VM state files are keyed by a HASH of the name, not the raw name
# (codex-15's own test coverage needs to inject "/" and other path-hostile
# characters into a VM name without that breaking the FIXTURE's filename
# scheme — a limitation of this stand-in, not of real VBoxManage, which
# would refuse such a name outright; the fixture must not constrain what
# the security test is allowed to try).
_vm_key() { printf '%s' "$1" | cksum | awk '{print $1}'; }
state_file() { echo "$STATE/$(_vm_key "$1").state"; }
fwd_file()   { echo "$STATE/$(_vm_key "$1").forwards"; }
snap_file()  { echo "$STATE/$(_vm_key "$1").snapshots"; }
is_registered() { grep -qxF "$1" "$reg_file" 2>/dev/null; }

case "${1:-}" in
  list)
    if [ "${2:-}" = "vms" ]; then
      while IFS= read -r name; do
        [ -n "$name" ] && printf '"%s" {%s-uuid}\n' "$name" "$name"
      done < "$reg_file"
    fi
    ;;
  showvminfo)
    vm="$2"
    is_registered "$vm" || { echo "not found" >&2; exit 1; }
    st=$(cat "$(state_file "$vm")" 2>/dev/null || echo poweroff)
    printf 'VMState="%s"\n' "$st"
    ff="$(fwd_file "$vm")"
    if [ -f "$ff" ]; then
      i=0
      while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        printf 'Forwarding(%d)="%s"\n' "$i" "$rule"
        i=$((i + 1))
      done < "$ff"
    fi
    ;;
  snapshot)
    vm="$2"; op="$3"; name="${4:-}"
    is_registered "$vm" || { echo "not reg" >&2; exit 1; }
    case "$op" in
      restore)
        grep -qxF "$name" "$(snap_file "$vm")" 2>/dev/null \
          || { echo "no snap" >&2; exit 1; }
        ;;
      list)
        sf="$(snap_file "$vm")"
        if [ -f "$sf" ]; then
          i=0
          while IFS= read -r sname; do
            [ -n "$sname" ] || continue
            if [ "$i" -eq 0 ]; then printf 'SnapshotName="%s"\n' "$sname"
            else printf 'SnapshotName-%d="%s"\n' "$i" "$sname"; fi
            i=$((i + 1))
          done < "$sf"
        fi
        ;;
    esac
    ;;
  startvm)
    vm="$2"; is_registered "$vm" || exit 1
    # HIMMEL-2675: the state change and the reported exit status are two
    # INDEPENDENT things here on purpose — real VBoxManage can start a VM
    # (the side effect) and still report failure on the CLI call itself
    # (a timeout, a late warning). FAKE_VBOX_STARTVM_FAIL simulates that:
    # the VM really does end up running, but this command still exits
    # nonzero.
    echo running > "$(state_file "$vm")"
    [ "${FAKE_VBOX_STARTVM_FAIL:-0}" = 1 ] && exit 1
    ;;
  controlvm)
    vm="$2"; op="$3"; is_registered "$vm" || exit 1
    case "$op" in acpipowerbutton|poweroff) echo poweroff > "$(state_file "$vm")" ;; esac
    ;;
  *) echo "fake VBoxManage: unhandled command: $*" >&2; exit 1 ;;
esac
exit 0
VBOXEOF
chmod +x "$FAKE_VBOXMANAGE"

# start_ssh_banner_listener <port> — same trick as test-after-report.sh:
# redirect stdout/stderr on the backgrounded listener itself, or the
# `$(...)` capturing its pid never sees EOF and hangs forever.
start_ssh_banner_listener() {
    local port="$1"
    "$PYTHON_BIN" -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(5)
while True:
    conn, _ = s.accept()
    try:
        conn.sendall(b'SSH-2.0-fake\r\n')
    except Exception:
        pass
    conn.close()
" >/dev/null 2>&1 &
    echo $!
}

seed_vm() {
    local state="$1" vm="$2" port="$3" snap="$4" key
    key=$(printf '%s' "$vm" | cksum | awk '{print $1}')
    mkdir -p "$state"
    echo "$vm" >> "$state/registered.list"
    echo poweroff > "$state/$key.state"
    echo "ssh,tcp,127.0.0.1,$port,,22" > "$state/$key.forwards"
    [ -n "$snap" ] && echo "$snap" > "$state/$key.snapshots"
}

# =====================================================================
# T1 (RED control): ssh never answers -> non-zero exit, asserted directly
# (no pipe into the assertion) -- this is the exact class of bug reported
# live against a previous version of this script.
# =====================================================================
STATE_T1="$WORK/vbox-t1"
seed_vm "$STATE_T1" himmel-ar-x 2281 "suite-ready-v3"
t1_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
    HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t1" FAKE_VBOX_STATE="$STATE_T1" \
    HIMMEL_VM_AR_SSH_WAIT=2 \
    bash "$SCRIPT" himmel-ar-x suite-ready-v3 2>&1)
t1_rc=$?
if [ "$t1_rc" -ne 0 ] \
   && grep -q "did not answer ssh" <<< "$t1_out" \
   && grep -q "^DRY-RUN FAILED:" <<< "$t1_out"; then
    pass "T1 RED control: unreachable ssh -> non-zero exit (asserted directly, not just ERROR text) + DRY-RUN FAILED marker"
else
    fail_case "T1 — rc=$t1_rc out:"
    printf '%s\n' "$t1_out" | sed 's/^/    /'
fi

# --- T1b: the SAME failure, this time invoked through a pipe (as the live
# incident's dpkg-lock/apt-install case was), to actually DEMONSTRATE that a
# pipe loses the raw exit status downstream of this process when the
# CALLER's shell does not have pipefail on (the realistic case — an
# operator's plain shell piped into `tee`, not this test's own shell).
#
# CR finding codex-13: this test's OWN shell has `set -o pipefail` (see the
# top of this file), so a bare `... | cat` HERE does NOT actually lose the
# exit status — pipefail makes the pipeline report dry-run-restore.sh's own
# nonzero rc regardless of cat's 0, so the previous version of this test
# only CLAIMED the failure mode in a comment without ever forcing pipefail
# OFF to reproduce it, and never asserted the captured status at all. This
# explicitly disables pipefail inside the very subshell that runs the pipe
# (never touching this file's OWN pipefail setting, which stays on outside
# that subshell) and asserts the resulting exit code IS wrongly 0 — proving
# the failure mode, not just asserting the marker survives it. ------------
STATE_T1B="$WORK/vbox-t1b"
seed_vm "$STATE_T1B" himmel-ar-x 2282 "suite-ready-v3"
t1b_combined=$(
    export VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN"
    export HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t1b" FAKE_VBOX_STATE="$STATE_T1B"
    export HIMMEL_VM_AR_SSH_WAIT=2
    set +o pipefail
    bash "$SCRIPT" himmel-ar-x suite-ready-v3 2>&1 | cat
    echo "T1B_PIPE_RC=$?"
)
t1b_pipe_rc=$(printf '%s\n' "$t1b_combined" | grep '^T1B_PIPE_RC=' | tail -n1 | cut -d= -f2)
t1b_piped_text=$(printf '%s\n' "$t1b_combined" | grep -v '^T1B_PIPE_RC=')
if [ "$t1b_pipe_rc" = "0" ] && grep -q "^DRY-RUN FAILED:" <<< "$t1b_piped_text"; then
    pass "T1b demonstrated pipe case: WITHOUT pipefail the pipeline's own \$? is wrongly 0 (proven, not just claimed), yet the DRY-RUN FAILED marker still survives in the captured text"
else
    fail_case "T1b — pipe_rc=$t1b_pipe_rc (want 0, proving the loss) marker_present=$(grep -q '^DRY-RUN FAILED:' <<< "$t1b_piped_text" && echo yes || echo no)"
fi

# =====================================================================
# T2 (positive control): a full success path -> exit 0, DRY-RUN OK marker,
# proving T1 isn't just "the script always fails."
# =====================================================================
STATE_T2="$WORK/vbox-t2"
seed_vm "$STATE_T2" himmel-ar-y 2283 "suite-ready-v3"
listener_pid=$(start_ssh_banner_listener 2283)
sleep 0.3
t2_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
    HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t2" FAKE_VBOX_STATE="$STATE_T2" \
    HIMMEL_VM_AR_SSH_WAIT=5 \
    bash "$SCRIPT" himmel-ar-y suite-ready-v3 2>&1)
t2_rc=$?
kill "$listener_pid" 2>/dev/null || true
wait "$listener_pid" 2>/dev/null || true
if [ "$t2_rc" -eq 0 ] && grep -q "^DRY-RUN OK:" <<< "$t2_out"; then
    pass "T2 positive control: a clean restore/boot/ssh cycle exits 0 with the DRY-RUN OK marker"
else
    fail_case "T2 — rc=$t2_rc out:"
    printf '%s\n' "$t2_out" | sed 's/^/    /'
fi

# =====================================================================
# T3: the referenced snapshot name must actually exist on the VM — a
# renamed/missing baseline (suite-ready -> suite-ready-v3 already happened
# once) fails with a specific message, before touching anything.
# =====================================================================
STATE_T3="$WORK/vbox-t3"
seed_vm "$STATE_T3" himmel-ar-z 2284 "suite-ready"   # only the OLD name exists
t3_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
    HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t3" FAKE_VBOX_STATE="$STATE_T3" \
    bash "$SCRIPT" himmel-ar-z suite-ready-v3 2>&1)
t3_rc=$?
if [ "$t3_rc" -ne 0 ] && grep -q "snapshot 'suite-ready-v3' does not exist on himmel-ar-z" <<< "$t3_out"; then
    pass "T3 refuses (before touching anything) when the referenced snapshot name does not exist on the VM"
else
    fail_case "T3 — rc=$t3_rc out:"
    printf '%s\n' "$t3_out" | sed 's/^/    /'
fi

# =====================================================================
# T4/T5 (CR finding codex-15): a VM/snapshot name is interpolated straight
# into argv now, never into python SOURCE text — an apostrophe must not
# break execution, and a crafted value must not EXECUTE. Both names are
# registered in the fake VBoxManage state (a real VirtualBox would refuse
# such a name at creation time, but the argv-safety this proves must not
# depend on upstream naming rules as the only defense).
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    # --- T4: a plain apostrophe must not break python execution at all ---
    APOSTROPHE_VM="cant'stop"
    STATE_T4="$WORK/vbox-t4"
    seed_vm "$STATE_T4" "$APOSTROPHE_VM" 2285 "suite-ready-v3"
    listener_pid=$(start_ssh_banner_listener 2285)
    sleep 0.3
    t4_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t4" FAKE_VBOX_STATE="$STATE_T4" \
        HIMMEL_VM_AR_SSH_WAIT=5 \
        bash "$SCRIPT" "$APOSTROPHE_VM" suite-ready-v3 2>&1)
    t4_rc=$?
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    if [ "$t4_rc" -eq 0 ] && grep -q "^DRY-RUN OK:" <<< "$t4_out"; then
        pass "T4 a VM name containing an apostrophe does not break execution"
    else
        fail_case "T4 — rc=$t4_rc out:"
        printf '%s\n' "$t4_out" | sed 's/^/    /'
    fi

    # --- T5: a name CRAFTED to break out of the old single-quoted python
    # literal and execute code must be handled as inert DATA — no
    # injected command may run, proven the same way the pre-fix
    # vulnerability was proven (a marker file the payload would create). ---
    PWNED_MARKER="$WORK/PWNED_T5"
    rm -f "$PWNED_MARKER"
    INJECT_VM="x'); import os; os.system('touch $PWNED_MARKER'); a=('x"
    STATE_T5="$WORK/vbox-t5"
    seed_vm "$STATE_T5" "$INJECT_VM" 2286 "suite-ready-v3"
    listener_pid=$(start_ssh_banner_listener 2286)
    sleep 0.3
    t5_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t5" FAKE_VBOX_STATE="$STATE_T5" \
        HIMMEL_VM_AR_SSH_WAIT=5 \
        bash "$SCRIPT" "$INJECT_VM" suite-ready-v3 2>&1)
    t5_rc=$?
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    if [ ! -e "$PWNED_MARKER" ] && [ "$t5_rc" -eq 0 ] && grep -q "^DRY-RUN OK:" <<< "$t5_out"; then
        pass "T5 a name crafted to inject python code executes NOTHING (no marker file created) and is handled as plain data"
    else
        fail_case "T5 — pwned_marker_exists=$([ -e "$PWNED_MARKER" ] && echo YES-INJECTION-RAN || echo no) rc=$t5_rc out:"
        printf '%s\n' "$t5_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T4/T5: no python3 on PATH"
fi

# =====================================================================
# T6 (CR follow-up on codex-15, coordinator-verified residual): vbox_py()
# still interpolated $REPO_ROOT straight into the python SOURCE text even
# after argv-ifying VM/snapshot names. A worktree path derives from a
# branch name (.claude/worktrees/feat+...), which may legally carry an
# apostrophe — the coordinator reproduced "SyntaxError: unterminated string
# literal" against a repo root containing one. This runs dry-run-restore.sh
# (plus vm-lock.sh/port-alloc.sh/vbox.py) from a COPY of the tree placed
# under a directory whose name contains an apostrophe, so $REPO_ROOT itself
# carries one for real, and proves the fixed vbox_py (argv.pop(1) for the
# repo root) still boots and completes cleanly.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    APOSTROPHE_REPO_ROOT="$WORK/repo's copy"
    mkdir -p "$APOSTROPHE_REPO_ROOT/scripts/vm" "$APOSTROPHE_REPO_ROOT/scripts/lib"
    cp "$REPO_ROOT/scripts/vm/dry-run-restore.sh" "$APOSTROPHE_REPO_ROOT/scripts/vm/"
    cp "$REPO_ROOT/scripts/vm/vm-lock.sh" "$APOSTROPHE_REPO_ROOT/scripts/vm/"
    cp "$REPO_ROOT/scripts/vm/port-alloc.sh" "$APOSTROPHE_REPO_ROOT/scripts/vm/"
    cp "$REPO_ROOT/scripts/lib/vbox.py" "$APOSTROPHE_REPO_ROOT/scripts/lib/"
    chmod +x "$APOSTROPHE_REPO_ROOT/scripts/vm/dry-run-restore.sh"
    APOSTROPHE_SCRIPT="$APOSTROPHE_REPO_ROOT/scripts/vm/dry-run-restore.sh"

    STATE_T6="$WORK/vbox-t6"
    seed_vm "$STATE_T6" himmel-ar-t6 2287 "suite-ready-v3"
    listener_pid=$(start_ssh_banner_listener 2287)
    sleep 0.3
    t6_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t6" FAKE_VBOX_STATE="$STATE_T6" \
        HIMMEL_VM_AR_SSH_WAIT=5 \
        bash "$APOSTROPHE_SCRIPT" himmel-ar-t6 suite-ready-v3 2>&1)
    t6_rc=$?
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    if [ "$t6_rc" -eq 0 ] && grep -q "^DRY-RUN OK:" <<< "$t6_out" \
       && ! grep -qi "SyntaxError\|unterminated string" <<< "$t6_out"; then
        pass "T6 a repo root containing an apostrophe does not break vbox_py (REPO_ROOT is now argv, not source text)"
    else
        fail_case "T6 — rc=$t6_rc out:"
        printf '%s\n' "$t6_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T6: no python3 on PATH"
fi

# =====================================================================
# T7 (CR finding codex-5, round 2): a preflight refusal must touch NOTHING.
# `trap cleanup EXIT` used to be installed before the snapshot-existence
# check, and cleanup() unconditionally powered off the VM — so a refusal
# on a bad snapshot name against an ALREADY-RUNNING VM (the realistic
# case: the operator's real himmel-ar-1 mid-suite) powered it off while
# claiming a preflight-only refusal. Seeds the VM as already `running`
# with NO recorded snapshot at all, so the snapshot-existence check fails
# before restore_snapshot (and therefore before BOOTED is ever set), and
# asserts the VM's own state file is UNTOUCHED (still "running") after the
# refusal — not merely that the process exited nonzero.
# =====================================================================
STATE_T7="$WORK/vbox-t7"
seed_vm "$STATE_T7" himmel-ar-w 2288 ""
KEY_T7=$(printf '%s' himmel-ar-w | cksum | awk '{print $1}')
echo running > "$STATE_T7/$KEY_T7.state"   # simulate an already-running VM
t7_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
    HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t7" FAKE_VBOX_STATE="$STATE_T7" \
    bash "$SCRIPT" himmel-ar-w suite-ready-v3 2>&1)
t7_rc=$?
t7_state=$(cat "$STATE_T7/$KEY_T7.state" 2>/dev/null || echo MISSING)
if [ "$t7_rc" -ne 0 ] && grep -q "^DRY-RUN FAILED:" <<< "$t7_out" && [ "$t7_state" = "running" ]; then
    pass "T7 (CR finding codex-5 round 2) a preflight refusal (missing snapshot) never powers off an already-running VM"
else
    fail_case "T7 — rc=$t7_rc state=$t7_state out:"
    printf '%s\n' "$t7_out" | sed 's/^/    /'
fi

# =====================================================================
# T8 (HIMMEL-2675): a boot that STARTS the VM but then still reports
# failure must still get powered off by cleanup(). Before this fix,
# BOOTED was armed only once ensure_running CONFIRMED success — so a
# startvm that changed the VM's state to running and THEN reported
# failure (a realistic VBoxManage race: a timeout/late-warning on the CLI
# call itself, independent of whether the VM actually came up) left
# BOOTED at 0, and cleanup skipped the power-off, releasing the lock with
# the guest left running. FAKE_VBOX_STARTVM_FAIL makes the fake
# VBoxManage set state=running (the real side effect) AND exit nonzero
# (the reported failure) from the SAME startvm call, so ensure_running
# fails while the VM is genuinely up.
# =====================================================================
STATE_T8="$WORK/vbox-t8"
seed_vm "$STATE_T8" himmel-ar-boot-fail 2289 "suite-ready-v3"
KEY_T8=$(printf '%s' himmel-ar-boot-fail | cksum | awk '{print $1}')
t8_out=$(env VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_PYTHON="$PYTHON_BIN" \
    HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t8" FAKE_VBOX_STATE="$STATE_T8" \
    FAKE_VBOX_STARTVM_FAIL=1 \
    bash "$SCRIPT" himmel-ar-boot-fail suite-ready-v3 2>&1)
t8_rc=$?
t8_state=$(cat "$STATE_T8/$KEY_T8.state" 2>/dev/null || echo MISSING)
if [ "$t8_rc" -ne 0 ] && grep -q "^DRY-RUN FAILED:" <<< "$t8_out" \
   && grep -q "could not power on" <<< "$t8_out" \
   && [ "$t8_state" = "poweroff" ]; then
    pass "T8 (HIMMEL-2675) a boot that starts the VM then fails still gets powered off by cleanup"
else
    fail_case "T8 — rc=$t8_rc state=$t8_state out:"
    printf '%s\n' "$t8_out" | sed 's/^/    /'
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILED"
    exit 1
fi
