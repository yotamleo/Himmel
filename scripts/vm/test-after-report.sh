#!/usr/bin/env bash
# test-after-report.sh — hermetic coverage for scripts/vm/after-report.sh and
# scripts/vm/port-alloc.sh (HIMMEL-2623 PR-B). NEVER touches a real
# VirtualBox VM: a fake, stateful `VBoxManage` on PATH stands in for the
# whole VM lifecycle (list/showvminfo/clonevm/snapshot/startvm/controlvm/
# modifyvm), fake `ssh`/`scp` scripts pattern-match the exact guest command
# shapes after-report.sh sends and answer from test-controlled fixtures
# (never a real network, never a real guest filesystem), and a fake `gh`
# records what would have been posted instead of calling GitHub. The venv
# python (HIMMEL_VM_PYTHON) is left pointed at a REAL python3 — vbox.py has
# no dependency beyond the stdlib (subprocess/socket/time), so this is still
# fully hermetic; only the ssh/paramiko-shaped path (unused by
# after-report.sh, which never calls vmsdk.py) would need stubbing further.
#
# Covers: port allocation skipping claimed ports, HIMMEL_VM_AR_MAX being
# honoured, the copied-back log landing at the quiet-run-ar-<ticket>-<ts>.log
# path shape with both the `== Summary ==` and `GAVE UP` markers intact, the
# HIMMEL-2540 absence-assertions refusing to proceed when a guest checkout
# carries .env/.claude/settings.local.json/.himmel-dev, and the fallback
# message naming the host invocation when VBoxManage is missing or the guest
# never answers ssh.
#
# Platform guard (linux-only): a bash test harness driving a FAKE
# VBoxManage/ssh/scp/gh, never a real VM — a documented guard suffices
# here (project convention: a test harness needs no .ps1 twin). Bash-only
# because the script it covers, after-report.sh, is itself linux-only.
#
# Usage: bash scripts/vm/test-after-report.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/after-report.sh"
PORT_ALLOC="$REPO_ROOT/scripts/vm/port-alloc.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-after-report.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

# Resolved early (not just before T3) so EVERY case that invokes
# after-report.sh — including T2 — can pin HIMMEL_VM_PYTHON to it (CR
# finding codex-11): without an explicit pin, after-report.sh falls back to
# ~/.himmel/vm-venv/bin/python, which happens to exist on this station —
# making the suite pass by relying on the OPERATOR'S real venv rather than
# being hermetic.
PYTHON_BIN=$(command -v python3)
[ -n "$PYTHON_BIN" ] || echo "SKIP: no python3 on PATH — several cases need it for wait_for_ssh's real socket check" >&2

# --- fake VBoxManage: a minimal, STATEFUL VirtualBox stand-in, enough to
# drive after-report.sh's clonevm/snapshot/startvm/controlvm/modifyvm calls
# and scripts/lib/vbox.py's state/get_forwards/restore/power lifecycle.
# State lives in flat files under $FAKE_VBOX_STATE so it persists across the
# many separate VBoxManage invocations one after-report.sh run makes. -----
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
state_file() { echo "$STATE/$1.state"; }
fwd_file()   { echo "$STATE/$1.forwards"; }
snap_file()  { echo "$STATE/$1.snapshots"; }
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
    is_registered "$vm" || { echo "VBoxManage: error: Could not find a registered machine named '$vm'" >&2; exit 1; }
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
  clonevm)
    source="$2"; shift 2
    name=""; snap=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --snapshot) snap="$2"; shift 2 ;;
        --register|--options) shift ;;
        *) shift ;;
      esac
    done
    is_registered "$source" || { echo "clonevm: source $source not registered" >&2; exit 1; }
    echo "$name" >> "$reg_file"
    echo poweroff > "$(state_file "$name")"
    : > "$(fwd_file "$name")"
    : > "$(snap_file "$name")"
    [ -n "$snap" ] && echo "$snap" >> "$(snap_file "$name")"
    ;;
  snapshot)
    vm="$2"; op="$3"; name="${4:-}"
    is_registered "$vm" || { echo "snapshot: $vm not registered" >&2; exit 1; }
    case "$op" in
      take) echo "$name" >> "$(snap_file "$vm")" ;;
      restore)
        grep -qxF "$name" "$(snap_file "$vm")" 2>/dev/null \
          || { echo "snapshot restore: '$name' not found on $vm" >&2; exit 1; }
        ;;
      list)
        # scripts/lib/vbox.py's list_snapshots() parses lines starting with
        # "SnapshotName" from `--machinereadable` output — match that shape.
        sf="$(snap_file "$vm")"
        if [ -f "$sf" ]; then
          i=0
          while IFS= read -r sname; do
            [ -n "$sname" ] || continue
            if [ "$i" -eq 0 ]; then
              printf 'SnapshotName="%s"\n' "$sname"
            else
              printf 'SnapshotName-%d="%s"\n' "$i" "$sname"
            fi
            i=$((i + 1))
          done < "$sf"
        fi
        ;;
    esac
    ;;
  startvm)
    vm="$2"
    is_registered "$vm" || { echo "startvm: $vm not registered" >&2; exit 1; }
    echo running > "$(state_file "$vm")"
    ;;
  controlvm)
    vm="$2"; op="$3"
    is_registered "$vm" || { echo "controlvm: $vm not registered" >&2; exit 1; }
    case "$op" in
      acpipowerbutton|poweroff)
        # HIMMEL-2688: logged into the SAME log the fake ssh writes to
        # (when asked), so a case can assert cross-process ORDERING
        # between an ssh call (e.g. cleanup_guest_token's cleanup) and
        # this power-off call — both happen strictly serially within
        # after-report.sh's own single-threaded execution, so sequential
        # appends to one shared file preserve real execution order.
        if [ -n "${FAKE_SSH_CALLS_LOG:-}" ]; then
            printf 'VBOXMANAGE controlvm %s %s\n-----\n' "$vm" "$op" >> "$FAKE_SSH_CALLS_LOG"
        fi
        echo poweroff > "$(state_file "$vm")"
        ;;
    esac
    ;;
  modifyvm)
    vm="$2"; shift 2
    is_registered "$vm" || { echo "modifyvm: $vm not registered" >&2; exit 1; }
    if [ "${1:-}" = "--natpf1" ]; then
      shift
      ff="$(fwd_file "$vm")"
      if [ "${1:-}" = "delete" ]; then
        name="$2"
        grep -v "^${name}," "$ff" 2>/dev/null > "$ff.tmp" || true
        mv "$ff.tmp" "$ff" 2>/dev/null || : > "$ff"
      else
        echo "$1" >> "$ff"
      fi
    fi
    ;;
  *)
    echo "fake VBoxManage: unhandled command: $*" >&2
    exit 1
    ;;
esac
exit 0
VBOXEOF
chmod +x "$FAKE_VBOXMANAGE"

# vbox_seed <vm> <port> <guest-port> — pre-register a VM with an existing NAT
# forward, simulating a VM VBoxManage already knows about (ubuntu_new,
# win11_base_himmel, himmel-parity-audit).
vbox_seed() {
    local vm="$1" port="$2" gport="${3:-22}"
    echo "$vm" >> "$FAKE_VBOX_STATE/registered.list"
    echo poweroff > "$FAKE_VBOX_STATE/$vm.state"
    echo "ssh,tcp,127.0.0.1,$port,,$gport" >> "$FAKE_VBOX_STATE/$vm.forwards"
}

# =====================================================================
# T1 — port allocator skips ports already claimed by ANY registered VM
# =====================================================================
FAKE_VBOX_STATE="$WORK/vbox-t1"
mkdir -p "$FAKE_VBOX_STATE"
: > "$FAKE_VBOX_STATE/registered.list"
export FAKE_VBOX_STATE
vbox_seed ubuntu_new 2222
vbox_seed win11_base_himmel 2223
vbox_seed himmel-parity-audit 2224
# A THIRD ar-clone already claims 2231 too — proves the allocator does not
# just skip the three well-known ports, it re-derives the claimed set live.
vbox_seed himmel-ar-9 2231

t1_out=$(
    export VBOXMANAGE_PATH="$FAKE_VBOXMANAGE"
    export HIMMEL_VM_AR_BASE_PORT=2222
    # shellcheck source=scripts/vm/port-alloc.sh
    . "$PORT_ALLOC"
    vm_ar_next_ports 2 | tr '\n' ','
)
if [ "$t1_out" = "2225,2226," ]; then
    pass "T1 port allocator skips every claimed port (2222/2223/2224/2231), returns 2225,2226"
else
    fail_case "T1 port allocator — got '$t1_out', want '2225,2226,'"
fi

# --- T1b (CR finding codex-5): an enumeration failure (VBoxManage broken)
# must FAIL CLOSED — refuse to allocate — never read as "confirmed zero
# claimed ports" and hand out one that might already be in use. -----------
BROKEN_VBOXMANAGE="$WORK/bin/broken-VBoxManage"
mkdir -p "$(dirname "$BROKEN_VBOXMANAGE")"
cat >"$BROKEN_VBOXMANAGE" <<'BROKENEOF'
#!/usr/bin/env bash
echo "simulated: VBoxManage: error: could not connect to VBoxSVC" >&2
exit 1
BROKENEOF
chmod +x "$BROKEN_VBOXMANAGE"
t1b_out=$(env VBOXMANAGE_PATH="$BROKEN_VBOXMANAGE" HIMMEL_VM_AR_BASE_PORT=2222 bash -c '
    # shellcheck source=scripts/vm/port-alloc.sh
    . "'"$PORT_ALLOC"'"
    vm_ar_next_ports 1
    echo "rc=$?"
')
if grep -q '^rc=1$' <<< "$t1b_out"; then
    pass "T1b port allocator fails CLOSED (refuses to allocate) when it cannot enumerate claimed ports at all"
else
    fail_case "T1b — $t1b_out"
fi

# =====================================================================
# T2 — HIMMEL_VM_AR_MAX is honoured: with MAX=1 and the only slot already
# held, a second run refuses rather than exceeding the cap.
# =====================================================================
# CodeRabbit (PR #2206): without errexit, if flock is absent the holder
# subshell's own `flock 209` at line ~247 below returns 127 and the
# subshell just keeps going into `sleep 15` anyway — this case would then
# report ok while having simulated nothing (no lock was ever actually
# held). Skip it with an explicit reason instead, same shape as the
# python3 guard above (HIMMEL-2676).
if [ -n "$PYTHON_BIN" ] && command -v flock >/dev/null 2>&1; then
    LOCK_DIR_T2="$WORK/locks-t2"
    mkdir -p "$LOCK_DIR_T2"
    # Hold slot 1's lock in a background subshell for the duration of this case.
    (
        exec 209>"$LOCK_DIR_T2/himmel-vm-ar-1.lock"
        flock 209
        sleep 15
    ) &
    holder_pid=$!
    sleep 0.5   # let the holder actually acquire the flock first
    # Holder sleeps 15s; after-report.sh's own slot-retry sleeps 5s between
    # passes, so with SLOT_WAIT=2 its deadline is provably exceeded (~5s in) long
    # before the holder could ever release — no race between "waited past the
    # budget" and "the lock happened to free up."

    t2_out=$(VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" HIMMEL_VM_AR_MAX=1 \
        HIMMEL_VM_AR_LOCK_DIR="$LOCK_DIR_T2" HIMMEL_VM_AR_SLOT_WAIT=2 \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t2" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-9999-x" 1 2>&1)
    t2_rc=$?
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    if [ "$t2_rc" -ne 0 ] && grep -q "all 1 clone slot(s) busy" <<< "$t2_out"; then
        pass "T2 HIMMEL_VM_AR_MAX=1 refuses rather than exceeding the cap while the only slot is held"
    else
        fail_case "T2 cap not honoured — rc=$t2_rc out=$(printf '%s' "$t2_out" | tail -3)"
    fi
elif [ -z "$PYTHON_BIN" ]; then
    echo "SKIP T2: no python3 on PATH"
else
    echo "SKIP T2: no flock on PATH — this case's own holder subshell needs it to simulate a busy slot"
fi

# =====================================================================
# Shared fixtures for T3/T4/T5: fake ssh/scp/gh + a suite-log fixture.
# =====================================================================
FAKE_SSH="$FAKEBIN/ssh"
FAKE_SCP="$FAKEBIN/scp"
FAKE_GH="$FAKEBIN/gh"
GUEST_LOG_FIXTURE="$WORK/guest-suite.log"
cat >"$GUEST_LOG_FIXTURE" <<'LOGEOF'
[PASS] scripts/test-example-one.sh (rc=0, 4s)
[PASS] scripts/test-example-two.sh (rc=0, 9s)
WAITING: another waiter ahead in the FIFO queue (simulated, mechanical pass-through check)
GAVE UP: waited 120s for the machine lock of scan root "scripts" — still behind an older waiter in the queue (pid=1 host=simulated); refusing (the verdict above describes the queue as it is now).

== Summary ==
 PASS: 42
 SKIP: 3
 FAIL: 0
EXITCODE=0
LOGEOF

# A guest run killed mid-suite (e.g. SUITE_TIMEOUT) before it ever reached
# its OWN "== Summary ==" print — only the EXITCODE marker after-report.sh's
# own `; echo EXITCODE=$?` always appends exists. CR finding codex-3.
DIED_MID_SUITE_FIXTURE="$WORK/guest-suite-died.log"
cat >"$DIED_MID_SUITE_FIXTURE" <<'LOGEOF'
[PASS] scripts/test-example-one.sh (rc=0, 4s)
[PASS] scripts/test-example-two.sh (rc=0, 9s)
EXITCODE=124
LOGEOF

cat >"$FAKE_SSH" <<'SSHEOF'
#!/usr/bin/env bash
# Fake ssh: pattern-matches the exact guest-command shapes after-report.sh
# sends (there are exactly nine) and answers from test-controlled env/files.
# Never touches a network or a real guest filesystem.
cmd="${*: -1}"
# HIMMEL-2678: logs every command string this fake ever receives, when
# asked, so a test can assert something about the WHOLE sequence (e.g. "no
# call ever carried a credentialed URL") rather than just one call's rc.
if [ -n "${FAKE_SSH_CALLS_LOG:-}" ]; then
    printf '%s\n-----\n' "$cmd" >> "$FAKE_SSH_CALLS_LOG"
fi
case "$cmd" in
  *"run-shell-tests.sh"*)
    mkdir -p "$(dirname "$FAKE_GUEST_LOG")"
    cp "$GUEST_LOG_FIXTURE" "$FAKE_GUEST_LOG"
    exit 0
    ;;
  *"test -e"*".env"*)
    # A transport failure (ssh convention: 255) is distinct from "the file
    # is absent" (1) — codex-4's whole point is that these must not be the
    # same code path.
    [ "${FAKE_SSH_ENV_TRANSPORT_FAIL:-0}" = 1 ] && exit 255
    [ "${FAKE_SSH_ENV_PRESENT:-0}" = 1 ] && exit 0 || exit 1
    ;;
  *"test -e"*"settings.local.json"*)
    [ "${FAKE_SSH_SETTINGS_PRESENT:-0}" = 1 ] && exit 0 || exit 1
    ;;
  *"test -e"*".himmel-dev"*)
    [ "${FAKE_SSH_HIMMELDEV_PRESENT:-0}" = 1 ] && exit 0 || exit 1
    ;;
  *"test -f"*".git/shallow"*)
    # HIMMEL-2677: after-report.sh probes this before deciding whether the
    # fetch below needs --unshallow. Defaults to "not shallow" (1), same
    # convention as the other presence checks above.
    [ "${FAKE_SSH_GUEST_SHALLOW:-0}" = 1 ] && exit 0 || exit 1
    ;;
  *"mktemp -d"*)
    # HIMMEL-2678: stands in for the guest tmp dir the askpass helper and
    # token file live under. Never a real path — nothing downstream ever
    # reads it back off a real filesystem, only re-embeds the string in
    # later command text this same fake pattern-matches on.
    printf '%s\n' "${FAKE_SSH_GUEST_TMP:-/home/testuser/tmp.himmel2678}"
    exit 0
    ;;
  *"INNER_EOF"*)
    # HIMMEL-2678: writes the guest askpass helper. Content is paths and a
    # literal username only, never the real token, so a fixed success is
    # all this needs to fake.
    exit 0
    ;;
  *"cat > '"*"/token'"*)
    # HIMMEL-2678: the ONE call that carries the real secret, and it
    # arrives over STDIN, never as an argv element of $cmd above. Saved to
    # a test-controlled path (if asked) so a case can assert it arrived
    # intact via stdin, without it ever needing to appear in a logged
    # command string.
    if [ -n "${FAKE_SSH_TOKEN_RECEIVED:-}" ]; then
        cat > "$FAKE_SSH_TOKEN_RECEIVED"
    else
        cat > /dev/null
    fi
    # HIMMEL-2688: touched only AFTER the token has actually landed, so a
    # case can poll for this instead of a fixed sleep to know precisely
    # when to interrupt the parent after-report.sh process — the exact
    # window (token delivered, fetch chain not yet run) this fix closes.
    # A subsequent HOLD (if asked) keeps after-report.sh genuinely BLOCKED
    # on this call for a moment, so the driver has a real window to land a
    # signal on it instead of racing an instantaneous fake against a
    # 0.05s poll — everything else in this harness is local calls with no
    # natural pause, so without this the whole run can complete before
    # the driver's kill ever lands.
    if [ -n "${FAKE_SSH_TOKEN_DELIVERED_MARKER:-}" ]; then
        touch "$FAKE_SSH_TOKEN_DELIVERED_MARKER"
        [ -n "${FAKE_SSH_TOKEN_DELIVERED_HOLD:-}" ] && sleep "$FAKE_SSH_TOKEN_DELIVERED_HOLD"
    fi
    exit 0
    ;;
  *"rm -rf '"*)
    # HIMMEL-2678: cleanup_guest_token's own call — removes the ephemeral
    # askpass/token tmp dir. Logged like every other call above; a case
    # asserts this fires on both the success and failure fetch paths.
    exit 0
    ;;
  *"rev-parse HEAD"*)
    echo "${FAKE_SSH_HEAD:-deadbeefcafefeed0123456789abcdef01234567}"
    exit 0
    ;;
  *"fetch "*"checkout -B"*)
    exit "${FAKE_SSH_FETCH_RC:-0}"
    ;;
  *)
    echo "fake ssh: unrecognized remote command: $cmd" >&2
    exit 99
    ;;
esac
SSHEOF
chmod +x "$FAKE_SSH"

cat >"$FAKE_SCP" <<'SCPEOF'
#!/usr/bin/env bash
# Fake scp: after-report.sh only ever copies ONE file back (the suite log),
# so the destination (last arg) is all that matters here.
dst="${*: -1}"
cp "$FAKE_GUEST_LOG" "$dst"
SCPEOF
chmod +x "$FAKE_SCP"

cat >"$FAKE_GH" <<'GHEOF'
#!/usr/bin/env bash
echo "$@" >> "$FAKE_GH_CALLS"
exit 0
GHEOF
chmod +x "$FAKE_GH"

# start_ssh_banner_listener <port> — a tiny TCP server standing in for the
# guest's sshd banner, so vbox.wait_for_ssh (a real, unstubbed socket
# connect) succeeds without a real VM. Printed pid is used to kill it after.
start_ssh_banner_listener() {
    local port="$1"
    local ready="$WORK/listener-ready-$port"
    rm -f "$ready"
    "$PYTHON_BIN" -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(5)
open('$ready', 'w').close()
while True:
    conn, _ = s.accept()
    try:
        conn.sendall(b'SSH-2.0-fake\r\n')
    except Exception:
        pass
    conn.close()
" >/dev/null 2>&1 &
    # >/dev/null above is load-bearing, not cosmetic: without it the
    # backgrounded python inherits THIS function's stdout — the write end of
    # the pipe feeding the caller's `$(start_ssh_banner_listener ...)`
    # command substitution — and since the listener never exits, that pipe
    # never reaches EOF and the substitution hangs forever.
    local pid=$! waited=0
    # CodeRabbit (PR #2206): bind()/listen() can fail (the fixed port
    # already held by a stale/leftover process) and the traceback was
    # swallowed by the >/dev/null redirect above — a case would then
    # SILENTLY pass against whatever OTHER listener already answers that
    # port instead of THIS fixture's own, rather than against what this
    # test actually set up. $ready is only written AFTER a successful
    # bind+listen, so polling for it (not just "the process forked")
    # closes that gap.
    while [ ! -f "$ready" ] && [ "$waited" -lt 40 ]; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
        waited=$((waited + 1))
    done
    if [ ! -f "$ready" ]; then
        echo "start_ssh_banner_listener: port $port never became ready (bind/listen failed, or the listener process died) — aborting rather than let a later case pass for the wrong reason" >&2
        kill "$pid" 2>/dev/null || true
        exit 1
    fi
    rm -f "$ready"
    echo "$pid"
}

# assert_bun_path_prefix <command-line> — true iff the given guest command
# line carries the HIMMEL-2768 bun PATH prefix somewhere ahead of the
# run-shell-tests.sh invocation. Shared by T3g (the real captured command)
# and T3h (its RED control) so both exercise the identical check. The
# expected substrings are single-quoted so the literal `$HOME`/`$PATH` text
# in the guest command is matched as-is, never expanded by this test shell.
assert_bun_path_prefix() {
    # shellcheck disable=SC2016  # literal $HOME/$PATH text in the guest command, not a shell expansion
    case "$1" in
        *'PATH="$HOME/.bun/bin:$PATH"'*"run-shell-tests.sh"*) return 0 ;;
        *) return 1 ;;
    esac
}

# =====================================================================
# T3 — happy path: log lands at the quiet-run-ar-<ticket>-<ts>.log shape,
# both `== Summary ==` and `GAVE UP` markers survive the copy verbatim.
#
# HIMMEL-2676: this case never pinned HIMMEL_VM_AR_RAM_MB, so it inherited
# the production 4096 MB default and checked it against the REAL
# /proc/meminfo despite driving a fake VBoxManage and booting nothing —
# inside a 4 GB after-report guest (the exact environment this feature
# exists to create), MemAvailable is necessarily below that, so this case
# failed deterministically there. Every case below that reaches the
# runner's RAM check now pins a small, always-satisfiable budget instead,
# so no verdict here depends on ambient host memory.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t3"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    BASE_PORT_T3=2231
    listener_pid=$(start_ssh_banner_listener "$BASE_PORT_T3")
    sleep 0.3

    FAKE_GUEST_LOG="$WORK/t3-guestfs-log"
    FAKE_GH_CALLS="$WORK/t3-gh-calls.log"
    : > "$FAKE_GH_CALLS"
    FAKE_SSH_CALLS_LOG="$WORK/t3-ssh-calls.log"
    FAKE_SSH_TOKEN_RECEIVED="$WORK/t3-token-received"
    : > "$FAKE_SSH_CALLS_LOG"
    rm -f "$FAKE_SSH_TOKEN_RECEIVED"
    export FAKE_VBOX_STATE FAKE_GUEST_LOG GUEST_LOG_FIXTURE FAKE_GH_CALLS
    export FAKE_SSH_CALLS_LOG FAKE_SSH_TOKEN_RECEIVED

    t3_out=$(PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT="$BASE_PORT_T3" HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t3" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t3" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        GH_CMD="$FAKE_GH" HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t3_rc=$?
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true

    log_path=$(printf '%s\n' "$t3_out" | grep -oE '/tmp/quiet-run-ar-himmel-2623-[0-9]{8}-[0-9]{6}\.log' | head -n1)
    if [ "$t3_rc" -eq 0 ] && [ -n "$log_path" ] && [ -f "$log_path" ] \
       && grep -q '^== Summary ==' "$log_path" && grep -q '^GAVE UP' "$log_path"; then
        pass "T3 log lands at /tmp/quiet-run-ar-himmel-2623-<ts>.log with both markers intact"
        rm -f "$log_path"
    else
        fail_case "T3 happy path — rc=$t3_rc log_path='$log_path' out:"
        printf '%s\n' "$t3_out" | sed 's/^/    /'
    fi
    if grep -q 'pr comment 4242' "$FAKE_GH_CALLS" 2>/dev/null && grep -q 'PASS: 42' "$FAKE_GH_CALLS" 2>/dev/null; then
        pass "T3b after-report comment posted from the HOST with the run's PASS/SKIP/FAIL tally"
    else
        fail_case "T3b gh pr comment not called as expected: $(cat "$FAKE_GH_CALLS" 2>/dev/null)"
    fi

    # --- T3d (HIMMEL-2678): the fake ssh logs every command string it
    # receives. This fixture cannot prove a REAL ssh never sees the token
    # in argv (it never runs one) — what it CAN prove is that none of the
    # constructed command strings after-report.sh actually sent carry the
    # old credentialed-URL shape, that the token arrived intact over
    # STDIN (a channel entirely separate from $cmd/argv above), and that
    # cleanup_guest_token's own `rm -rf` fired on this successful run.
    if grep -q 'x-access-token:' "$FAKE_SSH_CALLS_LOG"; then
        fail_case "T3d — a logged ssh command still carries the old credentialed-URL shape (x-access-token:):"
        sed 's/^/    /' "$FAKE_SSH_CALLS_LOG"
    elif [ ! -f "$FAKE_SSH_TOKEN_RECEIVED" ] || [ "$(cat "$FAKE_SSH_TOKEN_RECEIVED")" != "faketoken123" ]; then
        fail_case "T3d — token not received intact over stdin: $(cat "$FAKE_SSH_TOKEN_RECEIVED" 2>/dev/null || echo MISSING)"
    elif ! grep -q "rm -rf '" "$FAKE_SSH_CALLS_LOG"; then
        fail_case "T3d — cleanup_guest_token's rm -rf never fired on the successful path"
    else
        pass "T3d (HIMMEL-2678) no logged ssh command carries the credentialed URL, the token arrived intact over stdin, and cleanup fired"
    fi

    # --- T3g (HIMMEL-2768): the guest suite invocation must carry the bun
    # PATH prefix ahead of run-shell-tests.sh. suite-ready-v4 ships bun but
    # only puts it on PATH via ~/.bashrc, which guest_ssh's non-interactive
    # shell never sources — so if a future edit to this ONE command line
    # drops the prefix, bun silently vanishes from the guest again and the
    # only symptom is a red in an unrelated suite
    # (test-wizard-luna-sections.sh), not anything that points back here.
    # Targets the prefix specifically (not a hardcoded copy of the whole
    # command) so this survives any unrelated edit to GUEST_DEST/REMOTE_LOG/
    # SUITE_TIMEOUT.
    runshell_line=$(grep 'run-shell-tests.sh' "$FAKE_SSH_CALLS_LOG" | head -n1)
    if [ -n "$runshell_line" ] && assert_bun_path_prefix "$runshell_line"; then
        pass "T3g (HIMMEL-2768) guest suite command carries the bun PATH prefix ahead of run-shell-tests.sh"
    else
        fail_case "T3g — bun PATH prefix missing or not ahead of run-shell-tests.sh in the recorded guest command:"
        echo "    ${runshell_line:-<none>}"
    fi

    # --- T3h (RED control, HIMMEL-2768): strip the prefix from a COPY of
    # the ACTUAL captured command line and re-run the SAME check — same
    # idiom as T10b (mutate a copy, prove the comparison still catches it),
    # applied here to the runtime-captured command instead of a doc file.
    # Proves T3g is not vacuously green regardless of content.
    # shellcheck disable=SC2016  # literal $HOME/$PATH text to strip, not a shell expansion
    stripped_line=$(printf '%s' "$runshell_line" | sed 's/PATH="\$HOME\/\.bun\/bin:\$PATH" //')
    if assert_bun_path_prefix "$stripped_line"; then
        fail_case "T3h RED control — stripping the bun PATH prefix should have failed the T3g check, but it still matched: $stripped_line"
    else
        pass "T3h (RED control, HIMMEL-2768) the T3g check correctly fails once the bun PATH prefix is stripped from a copy of the captured command"
    fi
else
    echo "SKIP T3/T3b/T3d/T3g/T3h: no python3 on PATH"
fi

# =====================================================================
# T3e (HIMMEL-2678): cleanup_guest_token must fire on the FAILURE path
# too, not just success — the whole point of calling it unconditionally
# before checking the fetch chain's own exit status. Forces the
# fetch+checkout chain itself to fail and asserts the same `rm -rf` still
# appears in the logged ssh calls.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t3e"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    BASE_PORT_T3E=2244
    listener_pid=$(start_ssh_banner_listener "$BASE_PORT_T3E")
    sleep 0.3

    FAKE_GUEST_LOG="$WORK/t3e-guestfs-log"
    FAKE_SSH_CALLS_LOG="$WORK/t3e-ssh-calls.log"
    : > "$FAKE_SSH_CALLS_LOG"
    export FAKE_VBOX_STATE FAKE_GUEST_LOG GUEST_LOG_FIXTURE FAKE_SSH_CALLS_LOG

    t3e_out=$(PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT="$BASE_PORT_T3E" HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t3e" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t3e" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        HIMMEL_VM_AR_RAM_MB=64 FAKE_SSH_FETCH_RC=1 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t3e_rc=$?
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true

    if [ "$t3e_rc" -ne 0 ] \
       && grep -q "guest checkout of branch .* failed" <<< "$t3e_out" \
       && grep -q "rm -rf '" "$FAKE_SSH_CALLS_LOG"; then
        pass "T3e (HIMMEL-2678) cleanup_guest_token still fires when the fetch/checkout chain itself fails"
    else
        fail_case "T3e — rc=$t3e_rc out:"
        printf '%s\n' "$t3e_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T3e: no python3 on PATH"
fi

# =====================================================================
# T3f (HIMMEL-2688, RED control): cleanup_guest_token must ALSO fire via
# the EXIT trap when a signal interrupts the run BETWEEN the token landing
# on the guest and the fetch chain completing — the exact gap the
# original PAT fix left open (cleanup_guest_token was called only from
# the three explicit guest-checkout call sites, none of which the trap
# itself invoked; a TERM/INT in that window powered the clone off with
# the token still on its disk). T3d/T3e cover the success and
# fetch-failure paths and both stayed green while this trap path was
# broken — this is the case that would have caught it.
#
# Runs the real script in the BACKGROUND (not `$(...)`, so we have a pid
# to signal), waits for the fake ssh's own "token delivered" marker
# (never a fixed sleep — precise timing on the exact window under test,
# not a guess at it), sends SIGTERM, and asserts: the run exits via our
# own `trap 'exit 143' TERM` convention; the fetch/checkout call NEVER
# happened (proves the interrupt truly landed in the intended window);
# cleanup_guest_token's cleanup call fired; and it fired BEFORE the
# power-off VBoxManage call — both logged into the SAME shared log file
# (the fake VBoxManage's own controlvm case appends to it too, see
# HIMMEL-2688 there), so relative order in that file reflects true
# execution order for this single-threaded script. A cleanup call logged
# AFTER power-off would be worthless: the guest is no longer running to
# act on it.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t3f"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    BASE_PORT_T3F=2245
    listener_pid=$(start_ssh_banner_listener "$BASE_PORT_T3F")
    sleep 0.3

    FAKE_GUEST_LOG="$WORK/t3f-guestfs-log"
    FAKE_SSH_CALLS_LOG="$WORK/t3f-ssh-calls.log"
    FAKE_SSH_TOKEN_DELIVERED_MARKER="$WORK/t3f-token-delivered"
    : > "$FAKE_SSH_CALLS_LOG"
    rm -f "$FAKE_SSH_TOKEN_DELIVERED_MARKER"
    export FAKE_VBOX_STATE FAKE_GUEST_LOG GUEST_LOG_FIXTURE FAKE_SSH_CALLS_LOG
    export FAKE_SSH_TOKEN_DELIVERED_MARKER

    T3F_OUT="$WORK/t3f-out.log"
    PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT="$BASE_PORT_T3F" HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t3f" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t3f" \
        FAKE_SSH_TOKEN_DELIVERED_HOLD=5 \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 >"$T3F_OUT" 2>&1 &
    t3f_script_pid=$!

    t3f_waited=0
    while [ ! -f "$FAKE_SSH_TOKEN_DELIVERED_MARKER" ] && [ "$t3f_waited" -lt 100 ]; do
        kill -0 "$t3f_script_pid" 2>/dev/null || break
        sleep 0.05
        t3f_waited=$((t3f_waited + 1))
    done

    if [ ! -f "$FAKE_SSH_TOKEN_DELIVERED_MARKER" ]; then
        fail_case "T3f — the token-delivered marker never appeared; the run finished or died before reaching the intended window. Output:"
        kill "$t3f_script_pid" 2>/dev/null || true
        wait "$t3f_script_pid" 2>/dev/null
        sed 's/^/    /' "$T3F_OUT"
    else
        kill -TERM "$t3f_script_pid" 2>/dev/null
        wait "$t3f_script_pid" 2>/dev/null
        t3f_rc=$?

        cleanup_line=$(grep -n "rm -rf '" "$FAKE_SSH_CALLS_LOG" | head -n1 | cut -d: -f1)
        poweroff_line=$(grep -n "VBOXMANAGE controlvm" "$FAKE_SSH_CALLS_LOG" | head -n1 | cut -d: -f1)
        if [ "$t3f_rc" -eq 143 ] \
           && ! grep -q "checkout -B" "$FAKE_SSH_CALLS_LOG" \
           && [ -n "$cleanup_line" ] \
           && { [ -z "$poweroff_line" ] || [ "$cleanup_line" -lt "$poweroff_line" ]; }; then
            pass "T3f (HIMMEL-2688) a SIGTERM between token delivery and the fetch chain still runs cleanup_guest_token, before power-off, via the EXIT trap"
        else
            fail_case "T3f — rc=$t3f_rc cleanup_line=${cleanup_line:-<none>} poweroff_line=${poweroff_line:-<none>}. ssh/vbox calls:"
            sed 's/^/    /' "$FAKE_SSH_CALLS_LOG"
            echo "    --- script output ---"
            sed 's/^/    /' "$T3F_OUT"
        fi
    fi
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
else
    echo "SKIP T3f: no python3 on PATH"
fi

# =====================================================================
# T4 — HIMMEL-2540 absence-assertion refuses when the guest checkout
# carries .env / .claude/settings.local.json / .himmel-dev.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    for case_name in FAKE_SSH_ENV_PRESENT FAKE_SSH_SETTINGS_PRESENT FAKE_SSH_HIMMELDEV_PRESENT; do
        FAKE_VBOX_STATE="$WORK/vbox-t4-$case_name"
        mkdir -p "$FAKE_VBOX_STATE"
        : > "$FAKE_VBOX_STATE/registered.list"
        vbox_seed ubuntu_new 2222
        BASE_PORT_T4=2241
        listener_pid=$(start_ssh_banner_listener "$BASE_PORT_T4")
        sleep 0.3

        FAKE_GUEST_LOG="$WORK/t4-guestfs-log-$case_name"
        FAKE_GH_CALLS="$WORK/t4-gh-calls-$case_name.log"
        : > "$FAKE_GH_CALLS"
        export FAKE_VBOX_STATE FAKE_GUEST_LOG GUEST_LOG_FIXTURE FAKE_GH_CALLS

        # env (not bash's own assignment-prefix syntax) for the last var: bash
        # only recognizes a literal `name=value` TOKEN as a prefix assignment
        # at parse time — a quoted "$case_name"=1 is one word AFTER expansion
        # but is not recognized as an assignment and would be run as the
        # command instead. env has no such restriction.
        t4_out=$(env PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
            HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
            HIMMEL_VM_AR_BASE_PORT="$BASE_PORT_T4" HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t4-$case_name" \
            HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t4-$case_name" \
            HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
            GH_CMD="$FAKE_GH" HIMMEL_VM_AR_RAM_MB=64 "$case_name=1" \
            bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
        t4_rc=$?
        kill "$listener_pid" 2>/dev/null || true
        wait "$listener_pid" 2>/dev/null || true

        if [ "$t4_rc" -ne 0 ] && grep -q "guest checkout carries" <<< "$t4_out" \
           && [ ! -s "$FAKE_GH_CALLS" ]; then
            pass "T4 ($case_name) refuses to run the suite and posts nothing when the guest checkout carries a host secret/setting"
        else
            fail_case "T4 ($case_name) — rc=$t4_rc out:"
            printf '%s\n' "$t4_out" | sed 's/^/    /'
        fi
    done
else
    echo "SKIP T4: no python3 on PATH"
fi

# =====================================================================
# T4b (RED control, CR finding codex-4): an ssh TRANSPORT failure while
# checking for a guest secret must REFUSE, not be read as "the secret is
# absent" — today (pre-fix) `if guest_ssh "test -e ..."; then fail; fi`
# treats EVERY nonzero ssh exit (255 = transport failure, exactly like 1 =
# file absent) as proof of absence, so a broken check silently waves the
# run through. The distinction under test is "the check could not run" vs
# "the secret is not there" — not merely "some non-zero exit happened".
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t4b"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    BASE_PORT_T4B=2242
    listener_pid=$(start_ssh_banner_listener "$BASE_PORT_T4B")
    sleep 0.3

    FAKE_GUEST_LOG="$WORK/t4b-guestfs-log"
    FAKE_GH_CALLS="$WORK/t4b-gh-calls.log"
    : > "$FAKE_GH_CALLS"
    export FAKE_VBOX_STATE FAKE_GUEST_LOG GUEST_LOG_FIXTURE FAKE_GH_CALLS

    t4b_out=$(env PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT="$BASE_PORT_T4B" HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t4b" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t4b" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        GH_CMD="$FAKE_GH" FAKE_SSH_ENV_TRANSPORT_FAIL=1 HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t4b_rc=$?
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true

    if [ "$t4b_rc" -ne 0 ] \
       && grep -qi "could not verify" <<< "$t4b_out" \
       && ! grep -q "guest checkout carries" <<< "$t4b_out" \
       && [ ! -s "$FAKE_GH_CALLS" ]; then
        pass "T4b an ssh TRANSPORT failure on the secret check REFUSES (distinctly from 'secret present'), posts nothing"
    else
        fail_case "T4b — rc=$t4b_rc out:"
        printf '%s\n' "$t4b_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T4b: no python3 on PATH"
fi

# =====================================================================
# T3c (RED control, CR finding codex-3): a guest run that dies mid-suite
# (killed by SUITE_TIMEOUT, say) before ever printing its own "== Summary
# ==" must NOT post a "PASS: 0 / FAIL: 0"-shaped comment — that is
# indistinguishable from a genuinely clean, empty run. The posted comment
# must contain NO PASS line at all and must say plainly that no verdict
# exists.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t3c"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    BASE_PORT_T3C=2243
    listener_pid=$(start_ssh_banner_listener "$BASE_PORT_T3C")
    sleep 0.3

    FAKE_GUEST_LOG="$WORK/t3c-guestfs-log"
    FAKE_GH_CALLS="$WORK/t3c-gh-calls.log"
    : > "$FAKE_GH_CALLS"
    export FAKE_VBOX_STATE FAKE_GUEST_LOG FAKE_GH_CALLS
    GUEST_LOG_FIXTURE="$DIED_MID_SUITE_FIXTURE"
    export GUEST_LOG_FIXTURE

    t3c_out=$(env PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT="$BASE_PORT_T3C" HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t3c" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t3c" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        GH_CMD="$FAKE_GH" GUEST_LOG_FIXTURE="$GUEST_LOG_FIXTURE" FAKE_VBOX_STATE="$FAKE_VBOX_STATE" \
        FAKE_GUEST_LOG="$FAKE_GUEST_LOG" FAKE_GH_CALLS="$FAKE_GH_CALLS" HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    # Reset for later tests that expect the ordinary clean fixture.
    GUEST_LOG_FIXTURE="$WORK/guest-suite.log"
    export GUEST_LOG_FIXTURE

    posted_body=$(cat "$FAKE_GH_CALLS" 2>/dev/null || true)
    if [ -s "$FAKE_GH_CALLS" ] \
       && ! grep -qE '^ PASS: ' <<< "$posted_body" \
       && grep -qi "DIED-BEFORE-SUMMARY" <<< "$posted_body"; then
        pass "T3c a guest run that died mid-suite posts NO PASS line and states plainly that no verdict exists"
    else
        fail_case "T3c — posted body:"
        printf '%s\n' "$posted_body" | sed 's/^/    /'
        printf 'T3c — after-report.sh own output:\n' >&2
        printf '%s\n' "$t3c_out" | sed 's/^/    /' >&2
    fi
else
    echo "SKIP T3c: no python3 on PATH"
fi

# =====================================================================
# T5 — fallback message names the host invocation when the VM is
# unreachable (ssh never answers) and when VBoxManage itself is absent.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t5"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    export FAKE_VBOX_STATE
    # No listener started on this port — wait_for_ssh must time out.
    t5_out=$(PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT=2251 HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t5" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t5" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new HIMMEL_VM_AR_SSH_WAIT=2 \
        himmel_github_token_vm=faketoken123 HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t5_rc=$?
    if [ "$t5_rc" -ne 0 ] \
       && grep -q "did not answer ssh" <<< "$t5_out" \
       && grep -qF "bash scripts/ci/run-shell-tests.sh --changed-since origin/main --pr 4242" <<< "$t5_out"; then
        pass "T5a unreachable guest: fails loudly and names the host fallback invocation"
    else
        fail_case "T5a — rc=$t5_rc out:"
        printf '%s\n' "$t5_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T5a: no python3 on PATH"
fi

# Leaves the real PATH intact (bash itself must still be found via it) —
# only VBOXMANAGE_PATH points at a nonexistent binary, which is all
# after-report.sh's own preflight check looks at.
t5b_out=$(VBOXMANAGE_PATH="$WORK/nonexistent-bin/VBoxManage" \
    HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t5b" HIMMEL_VM_AR_RAM_MB=64 \
    bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
t5b_rc=$?
if [ "$t5b_rc" -ne 0 ] \
   && grep -q "VBoxManage not found" <<< "$t5b_out" \
   && grep -qF "bash scripts/ci/run-shell-tests.sh --changed-since origin/main --pr 4242" <<< "$t5b_out"; then
    pass "T5b missing VBoxManage: fails loudly and names the host fallback invocation"
else
    fail_case "T5b — rc=$t5b_rc out:"
    printf '%s\n' "$t5b_out" | sed 's/^/    /'
fi

# =====================================================================
# T6/T7/T8 — HIMMEL-2623 incident hardening: the opt-in guard on an unset
# VBOXMANAGE_PATH, and the vm-lock gating every real VBoxManage call.
#
# A COUNTING wrapper stands in for "the real binary": it appends one line
# to a counter file, then delegates to the same stateful fake VBoxManage
# every other case here uses. It is never installed at the real
# /usr/bin/VBoxManage path — HIMMEL_VM_AR_VBOXMANAGE_DEFAULT (a named,
# test-only override point in after-report.sh) points the script's OWN
# "real default" at it instead, so these controls prove the guard's
# behaviour without ever being able to reach the station's actual
# VirtualBox even if the guard were broken.
# =====================================================================
COUNTING_VBOXMANAGE="$FAKEBIN/counting-vboxmanage"
cat >"$COUNTING_VBOXMANAGE" <<'CVMEOF'
#!/usr/bin/env bash
echo "call: $*" >> "${HIMMEL_VM_AR_TEST_CALL_COUNTER:?HIMMEL_VM_AR_TEST_CALL_COUNTER not set}"
exec "${FAKE_VBOXMANAGE_REAL:?FAKE_VBOXMANAGE_REAL not set}" "$@"
CVMEOF
chmod +x "$COUNTING_VBOXMANAGE"

# --- T6 (RED control): VBOXMANAGE_PATH unset + HIMMEL_VM_AR_LIVE unset
# refuses before ANY invocation reaches the counting wrapper — asserted by
# the counter file being ABSENT (not merely "the script exited non-zero").
# -----------------------------------------------------------------------
T6_COUNTER="$WORK/t6-vboxmanage-calls.log"
rm -f "$T6_COUNTER"
t6_out=$(env -u VBOXMANAGE_PATH -u HIMMEL_VM_AR_LIVE \
    HIMMEL_VM_AR_VBOXMANAGE_DEFAULT="$COUNTING_VBOXMANAGE" \
    HIMMEL_VM_AR_TEST_CALL_COUNTER="$T6_COUNTER" FAKE_VBOXMANAGE_REAL="$FAKE_VBOXMANAGE" \
    HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t6" HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t6" \
    HIMMEL_VM_AR_RAM_MB=64 \
    bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
t6_rc=$?
if [ "$t6_rc" -ne 0 ] \
   && grep -q "HIMMEL_VM_AR_LIVE is not '1'" <<< "$t6_out" \
   && [ ! -e "$T6_COUNTER" ]; then
    pass "T6 RED control: unset VBOXMANAGE_PATH + unset HIMMEL_VM_AR_LIVE refuses with ZERO calls to the real-default binary"
else
    fail_case "T6 — rc=$t6_rc counter_exists=$([ -e "$T6_COUNTER" ] && echo yes || echo no) out:"
    printf '%s\n' "$t6_out" | sed 's/^/    /'
fi

# --- T7 (positive control): HIMMEL_VM_AR_LIVE=1 lets the SAME unset
# VBOXMANAGE_PATH fall through to HIMMEL_VM_AR_VBOXMANAGE_DEFAULT, and a
# real (fake) call DOES happen — proving T6's "zero calls" is a property of
# the guard, not of a counter that never fires at all. -----------------
if [ -n "$PYTHON_BIN" ]; then
    FAKE_VBOX_STATE="$WORK/vbox-t7"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    export FAKE_VBOX_STATE
    T7_COUNTER="$WORK/t7-vboxmanage-calls.log"
    rm -f "$T7_COUNTER"
    t7_out=$(env -u VBOXMANAGE_PATH HIMMEL_VM_AR_LIVE=1 \
        HIMMEL_VM_AR_VBOXMANAGE_DEFAULT="$COUNTING_VBOXMANAGE" \
        HIMMEL_VM_AR_TEST_CALL_COUNTER="$T7_COUNTER" FAKE_VBOXMANAGE_REAL="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT=2261 HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t7" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t7" HIMMEL_VM_AR_SOURCE_VM=ubuntu_new \
        HIMMEL_VM_AR_SSH_WAIT=1 HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t7_rc=$?
    if [ "$t7_rc" -ne 0 ] && [ -s "$T7_COUNTER" ]; then
        pass "T7 positive control: HIMMEL_VM_AR_LIVE=1 lets the run reach the real-default binary (counter mechanism proven non-vacuous)"
    else
        fail_case "T7 — rc=$t7_rc counter=$(cat "$T7_COUNTER" 2>/dev/null || echo '<absent>') out:"
        printf '%s\n' "$t7_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T7: no python3 on PATH"
fi

# --- T8: a real call is refused even with the opt-in set, when the
# vm-lock for the target clone is already held (by someone else) and this
# run does not wait — the two guards are independent and both must bite. --
if [ -n "$PYTHON_BIN" ]; then
    T8_LOCKDIR="$WORK/vmlock-t8"
    mkdir -p "$T8_LOCKDIR"
    (
        HIMMEL_VM_LOCK_DIR="$T8_LOCKDIR" bash -c '. "'"$REPO_ROOT"'/scripts/vm/vm-lock.sh"; vm_lock_acquire_waiting himmel-ar-1 >/dev/null; sleep 3; vm_lock_release himmel-ar-1'
    ) &
    t8_holder_pid=$!
    sleep 0.5
    T8_COUNTER="$WORK/t8-vboxmanage-calls.log"
    rm -f "$T8_COUNTER"
    t8_out=$(env VBOXMANAGE_PATH="$COUNTING_VBOXMANAGE" \
        HIMMEL_VM_AR_TEST_CALL_COUNTER="$T8_COUNTER" FAKE_VBOXMANAGE_REAL="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser HIMMEL_VM_AR_MAX=1 \
        HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t8" HIMMEL_VM_LOCK_DIR="$T8_LOCKDIR" \
        HIMMEL_VM_AR_RAM_MB=64 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t8_rc=$?
    kill "$t8_holder_pid" 2>/dev/null || true
    wait "$t8_holder_pid" 2>/dev/null || true
    if [ "$t8_rc" -ne 0 ] \
       && grep -q "vm-lock on 'himmel-ar-1'" <<< "$t8_out" \
       && [ ! -e "$T8_COUNTER" ]; then
        pass "T8 a real call is refused (ZERO invocations) when the vm-lock is already held, even with the opt-in satisfied"
    else
        fail_case "T8 — rc=$t8_rc counter_exists=$([ -e "$T8_COUNTER" ] && echo yes || echo no) out:"
        printf '%s\n' "$t8_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T8: no python3 on PATH"
fi

# =====================================================================
# T9 (HIMMEL-2676): deliberate coverage of the RAM guard in BOTH
# directions — every other case above pins HIMMEL_VM_AR_RAM_MB small so
# its own verdict does not depend on ambient host memory, which only
# proves the guard stays out of their way; it never exercises the guard
# actually firing. T9a forces an unsatisfiable budget and asserts the
# named refusal; T9b uses a trivially satisfiable one and asserts
# execution proceeds PAST the RAM check to the next stage (boot/
# wait_for_ssh, which then times out since no listener runs here) rather
# than merely asserting the RAM message is absent from an otherwise
# unconstrained failure.
# =====================================================================
if [ -n "$PYTHON_BIN" ]; then
    # --- T9a: an unsatisfiable budget refuses, naming the budget -------
    FAKE_VBOX_STATE="$WORK/vbox-t9a"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    export FAKE_VBOX_STATE
    t9a_out=$(PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT=2271 HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t9a" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t9a" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        HIMMEL_VM_AR_RAM_MB=999999999 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t9a_rc=$?
    if [ "$t9a_rc" -ne 0 ] \
       && grep -q "below the HIMMEL_VM_AR_RAM_MB=999999999MB per-clone budget" <<< "$t9a_out"; then
        pass "T9a (HIMMEL-2676) the RAM guard refuses below budget"
    else
        fail_case "T9a — rc=$t9a_rc out:"
        printf '%s\n' "$t9a_out" | sed 's/^/    /'
    fi

    # --- T9b: a trivially satisfiable budget does not fire -------------
    FAKE_VBOX_STATE="$WORK/vbox-t9b"
    mkdir -p "$FAKE_VBOX_STATE"
    : > "$FAKE_VBOX_STATE/registered.list"
    vbox_seed ubuntu_new 2222
    export FAKE_VBOX_STATE
    t9b_out=$(PATH="$FAKEBIN:$PATH" VBOXMANAGE_PATH="$FAKE_VBOXMANAGE" \
        HIMMEL_VM_PYTHON="$PYTHON_BIN" HIMMEL_VM_AR_GUEST_USER=testuser \
        HIMMEL_VM_AR_BASE_PORT=2272 HIMMEL_VM_AR_LOCK_DIR="$WORK/locks-t9b" \
        HIMMEL_VM_LOCK_DIR="$WORK/vmlock-t9b" \
        HIMMEL_VM_AR_SOURCE_VM=ubuntu_new himmel_github_token_vm=faketoken123 \
        HIMMEL_VM_AR_RAM_MB=1 HIMMEL_VM_AR_SSH_WAIT=1 \
        bash "$SCRIPT" "feat/HIMMEL-2623-vm-after-report" 4242 2>&1)
    t9b_rc=$?
    if [ "$t9b_rc" -ne 0 ] \
       && ! grep -q "per-clone budget" <<< "$t9b_out" \
       && grep -q "did not answer ssh" <<< "$t9b_out"; then
        pass "T9b (HIMMEL-2676) the RAM guard does not fire above budget"
    else
        fail_case "T9b — rc=$t9b_rc out:"
        printf '%s\n' "$t9b_out" | sed 's/^/    /'
    fi
else
    echo "SKIP T9: no python3 on PATH"
fi

# =====================================================================
# T10 (HIMMEL-2738): after-report.sh, dry-run-restore.sh and the vm
# SKILL.md each independently name the default baseline snapshot — and
# nothing structurally stops those three names drifting apart. This has
# already happened twice in substance (suite-ready -> suite-ready-v3, then
# suite-ready-v3 -> suite-ready-v4 as of HIMMEL-2747), each time raising
# exactly the same risk: a doc naming a different image than the code
# restores is how an operator ends up running the wrong baseline. T10
# asserts the three names agree ON THE CURRENT DEFAULT — "suite-ready-v4"
# as of HIMMEL-2747. GENERAL WARNING for whoever touches this next: T10
# only proves the three names agree with EACH OTHER, never that they agree
# with what the clone actually is. A future migration (v4 -> v5, say) must
# never be "fixed" by editing only these three doc/code strings to point at
# a newer image name — that satisfies T10 while the actual `himmel-ar-N`
# clones still restore the OLDER image, a vacuous pass. The strings only
# move together with (and after) a real delete-and-re-clone onto the new
# golden snapshot, identity and guest content verified — see
# after-report.sh's own header for that record. T10b is a RED control
# proving the comparison actually has teeth, not a vacuous empty-equals-empty
# pass. Needs no python/VBoxManage/network, so it runs even on the
# no-python3 SKIP path above.
# =====================================================================

# snapshot_names_from <after-report.sh> <dry-run-restore.sh> <SKILL.md> —
# prints the three default baseline snapshot names on ONE line,
# space-separated, in that order. A name this cannot extract prints as
# the literal "MISSING" (never an empty string), so a missing/
# unextractable name is forced to mismatch rather than silently comparing
# empty to empty. One line + `read` (not an array) so this is bash
# 3.2/Git-Bash portable — no readarray/mapfile.
snapshot_names_from() {
    local ar_file="$1" drr_file="$2" skill_file="$3"
    local ar_name drr_name skill_name
    ar_name=$(grep -oE 'SNAPSHOT="\$\{HIMMEL_VM_AR_SNAPSHOT:-[^}]+\}"' "$ar_file" \
        | head -1 | sed -E 's/.*:-([^}]+)\}"/\1/')
    drr_name=$(grep -oE 'SNAPSHOT="\$\{2:-\$\{HIMMEL_VM_AR_SNAPSHOT:-[^}]+\}\}"' "$drr_file" \
        | head -1 | sed -E 's/.*:-([^}]+)\}\}"/\1/')
    # shellcheck disable=SC2016  # literal backtick-quoted markdown text to grep/sed for, not a shell expansion
    skill_name=$(grep -oE 'The baseline snapshot is `[^`]+`' "$skill_file" \
        | head -1 | sed -E 's/.*`([^`]+)`/\1/')
    echo "${ar_name:-MISSING} ${drr_name:-MISSING} ${skill_name:-MISSING}"
}

DRR_SCRIPT="$REPO_ROOT/scripts/vm/dry-run-restore.sh"
VM_SKILL="$REPO_ROOT/marketplace/plugins/himmel-ops/skills/vm/SKILL.md"

# --- T10: the three real files must agree -------------------------------
t10_line=$(snapshot_names_from "$SCRIPT" "$DRR_SCRIPT" "$VM_SKILL")
t10_ar=""; t10_drr=""; t10_skill=""; t10_extra=""
read -r t10_ar t10_drr t10_skill t10_extra <<< "$t10_line"
if [ -n "$t10_ar" ] && [ -n "$t10_drr" ] && [ -n "$t10_skill" ] && [ -z "$t10_extra" ] \
   && [ "$t10_ar" != "MISSING" ] \
   && [ "$t10_ar" = "$t10_drr" ] \
   && [ "$t10_drr" = "$t10_skill" ]; then
    pass "T10 (HIMMEL-2738) after-report.sh, dry-run-restore.sh and SKILL.md all default to the same baseline snapshot: $t10_ar"
else
    fail_case "T10 — default snapshot names disagree or are missing: ${t10_line:-<none>}"
fi

# --- T10b (RED control): mutate ONLY a doc copy and confirm the SAME
# comparison logic reports a MISMATCH — proves T10 is not a test that can
# never fail. -------------------------------------------------------------
T10B_DIR="$WORK/t10b"
mkdir -p "$T10B_DIR"
cp "$SCRIPT" "$T10B_DIR/after-report.sh"
cp "$DRR_SCRIPT" "$T10B_DIR/dry-run-restore.sh"
# shellcheck disable=SC2016  # literal backtick-quoted markdown text, not a shell expansion
sed -E 's/(The baseline snapshot is `)[^`]+(`)/\1suite-ready-v99-does-not-exist\2/' \
    "$VM_SKILL" > "$T10B_DIR/SKILL.md"
t10b_line=$(snapshot_names_from \
    "$T10B_DIR/after-report.sh" "$T10B_DIR/dry-run-restore.sh" "$T10B_DIR/SKILL.md")
t10b_ar=""; t10b_drr=""; t10b_skill=""; t10b_extra=""
read -r t10b_ar t10b_drr t10b_skill t10b_extra <<< "$t10b_line"
if [ -n "$t10b_ar" ] && [ -n "$t10b_drr" ] && [ -n "$t10b_skill" ] && [ -z "$t10b_extra" ] \
   && [ "$t10b_ar" = "$t10b_drr" ] \
   && [ "$t10b_ar" != "$t10b_skill" ] \
   && [ "$t10b_skill" = "suite-ready-v99-does-not-exist" ]; then
    pass "T10b (RED control, HIMMEL-2738) a doc/code snapshot-name mismatch is caught, not vacuously passed"
else
    fail_case "T10b — mutated doc copy did not produce a detected mismatch: ${t10b_line:-<none>}"
fi

echo
# CR finding codex-5 (round 3): with no python3 on PATH, most cases above
# are SKIPPED (see the SKIP lines), yet this used to still print "ALL
# PASS" and exit 0 whenever the few python-free cases passed — a
# vacuously green suite reporting the STRONGEST verdict while having
# verified almost nothing. Every leg of this review is gated on grepping
# "ALL PASS" out of exactly this kind of log, so this suite must never say
# it without having actually run. Matches test-dry-run-restore.sh's own
# codex-12 fix: a missing prerequisite is UNVERIFIED, not a pass, and gets
# a distinct nonzero exit rather than folding into "ALL PASS".
if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED FAILED"
    exit 1
elif [ -z "$PYTHON_BIN" ]; then
    echo "SKIP: no python3 on PATH — several cases above were skipped (see the SKIP lines); this run is UNVERIFIED, not ALL PASS" >&2
    exit 2
else
    echo "ALL PASS"
    exit 0
fi
