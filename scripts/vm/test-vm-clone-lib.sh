#!/usr/bin/env bash
# test-vm-clone-lib.sh — hermetic coverage for scripts/vm/lib/vm-clone.sh
# (HIMMEL-3332 slice S9a). No real VM, no network: a fake VBoxManage / ssh /
# scp / rsync on PATH, a throwaway lock dir, and a fixture repo. The clone /
# restore / boot bodies are proven by scripts/vm/test-after-report.sh and
# test-dry-run-restore.sh, which run UNCHANGED against the extracted lib.
#
# Platform guard (linux-only): flock + a bash harness, no .ps1 twin needed
# (project convention: a documented guard suffices for a test harness).
#
# Usage: bash scripts/vm/test-vm-clone-lib.sh
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c bodies are single-quoted on purpose; trap/exported-function bodies run indirectly
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/vm/lib/vm-clone.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-clone-lib.XXXXXX") || exit 1
HOLD_PIDS=()
cleanup() {
    if [ "${#HOLD_PIDS[@]}" -gt 0 ]; then kill "${HOLD_PIDS[@]}" 2>/dev/null; wait "${HOLD_PIDS[@]}" 2>/dev/null; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

BIN="$WORK/bin"; mkdir -p "$BIN"
# Counting fake VBoxManage: every call is recorded, so a guard that must never
# reach it can prove it did not.
cat > "$BIN/VBoxManage" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_VBOX_CALLS:?}"
exit 0
EOS
# ssh / scp record their argv one arg per line, then a separator.
for tool in ssh scp; do
    cat > "$BIN/$tool" <<'EOS'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo ----; } >> "${FAKE_NET_LOG:?}"
exit 0
EOS
done
chmod +x "$BIN"/*

# --- T1: slot cap. Two holders take slots 1 and 2 of MAX=2; a third claim
# fails with rc 1 and the message after-report.sh has always printed. A held
# slot is an open fd, so each holder is its own process (re-claiming from the
# SAME shell would reopen, and so release, its own fd).
if [ ! -f "$LIB" ]; then
    fail_case "T1 slot cap — $LIB does not exist"
    fail_case "T2 VBoxManage guard — $LIB does not exist"
    fail_case "T3 vm_ssh/vm_scp argv — $LIB does not exist"
    fail_case "T4 vm_stage_tree — $LIB does not exist"
    echo "RESULT: $FAILED failure(s)"; exit 1
fi
LD="$WORK/locks"; mkdir -p "$LD"
hold() { # $1 = file the holder writes its slot index to
    ( exec env HIMMEL_VM_AR_LOCK_DIR="$LD" HIMMEL_VM_AR_MAX=2 bash -c '
        . "$1"; vm_slot_acquire && echo "$CLONE_IDX $CLONE_NAME" > "$2"; exec sleep 120' _ "$LIB" "$1" ) &
    HOLD_PIDS+=($!)
}
await() { # $1 = file; foreground, bounded
    local n=0
    until [ -s "$1" ] || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
    [ -s "$1" ]
}
hold "$WORK/h1"; await "$WORK/h1"
hold "$WORK/h2"; await "$WORK/h2"
if [ "$(cut -d' ' -f1 "$WORK/h1")" = 1 ] && [ "$(cut -d' ' -f1 "$WORK/h2")" = 2 ] \
   && [ "$(cut -d' ' -f2 "$WORK/h2")" = himmel-ar-2 ]; then
    pass "T1a two holders claim slots 1 and 2 (himmel-ar-1/2)"
else fail_case "T1a holders got: $(cat "$WORK/h1" "$WORK/h2" 2>&1 | tr '\n' ';')"; fi
out=$(HIMMEL_VM_AR_LOCK_DIR="$LD" HIMMEL_VM_AR_MAX=2 HIMMEL_VM_AR_SLOT_WAIT=0 bash -c '. "$1"; vm_slot_acquire; echo claimed' _ "$LIB" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'all 2 clone slot(s) busy' <<< "$out" && ! grep -q claimed <<< "$out"; then
    pass "T1b the third claim fails rc=1 with 'all 2 clone slot(s) busy'"
else fail_case "T1b third claim rc=$rc: $out"; fi
kill "${HOLD_PIDS[@]}" 2>/dev/null; wait "${HOLD_PIDS[@]}" 2>/dev/null; HOLD_PIDS=()
out=$(HIMMEL_VM_AR_LOCK_DIR="$LD" HIMMEL_VM_AR_MAX=2 HIMMEL_VM_AR_SLOT_WAIT=0 bash -c '. "$1"; vm_slot_acquire; echo "got $CLONE_IDX"; vm_slot_release; vm_slot_release; echo released' _ "$LIB" 2>&1)
if grep -q '^got 1$' <<< "$out" && grep -q '^released$' <<< "$out"; then
    pass "T1c a freed slot is claimable again; vm_slot_release is idempotent"
else fail_case "T1c after release: $out"; fi
out=$(HIMMEL_VM_AR_LOCK_DIR="$LD" HIMMEL_VM_AR_MAX=0 bash -c '. "$1"; vm_slot_acquire' _ "$LIB" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'must be a positive integer' <<< "$out"; then
    pass "T1d a non-positive HIMMEL_VM_AR_MAX is refused"
else fail_case "T1d MAX=0 rc=$rc: $out"; fi

# --- T2: the HIMMEL-2623 guard. Unset VBOXMANAGE_PATH without the LIVE opt-in
# must refuse and never reach the (counting) default binary.
calls="$WORK/vbox-calls"; : > "$calls"
out=$(env -u VBOXMANAGE_PATH -u HIMMEL_VM_AR_LIVE PATH="$BIN:$PATH" FAKE_VBOX_CALLS="$calls" HIMMEL_VM_AR_VBOXMANAGE_DEFAULT="$BIN/VBoxManage" \
    bash -c '. "$1"; vm_env_init; echo passed' _ "$LIB" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing to fall through' <<< "$out" && [ ! -s "$calls" ]; then
    pass "T2a unset VBOXMANAGE_PATH without HIMMEL_VM_AR_LIVE refuses, zero VBoxManage calls"
else fail_case "T2a rc=$rc calls=$(wc -l < "$calls"): $out"; fi
out=$(env -u HIMMEL_VM_AR_LIVE PATH="$BIN:$PATH" VBOXMANAGE_PATH="$BIN/VBoxManage" HIMMEL_VM_PYTHON="$(command -v python3)" \
    bash -c '. "$1"; vm_env_init; echo "ok $VBOXMANAGE_PATH"' _ "$LIB" 2>&1)
if grep -qF "ok $BIN/VBoxManage" <<< "$out"; then pass "T2b an explicit VBOXMANAGE_PATH passes and stays exported"
else fail_case "T2b explicit path: $out"; fi
out=$(env -u HIMMEL_VM_AR_LIVE VBOXMANAGE_PATH="$BIN/VBoxManage" HIMMEL_VM_PYTHON="$WORK/no-such-python" \
    bash -c '. "$1"; vm_env_init; echo passed' _ "$LIB" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'venv python not found' <<< "$out"; then pass "T2c a missing venv python is refused"
else fail_case "T2c rc=$rc: $out"; fi
# fail() defined by the caller is the refusal path (after-report keeps its message frame).
out=$(env -u VBOXMANAGE_PATH -u HIMMEL_VM_AR_LIVE bash -c '. "$1"; fail() { echo "CALLER-FRAME: $1"; exit 7; }; vm_env_init' _ "$LIB" 2>&1); rc=$?
if [ "$rc" -eq 7 ] && grep -q '^CALLER-FRAME: VBOXMANAGE_PATH is unset' <<< "$out"; then
    pass "T2d a caller-defined fail() carries the refusal (its own exit code and frame)"
else fail_case "T2d rc=$rc: $out"; fi

# --- T3: vm_ssh / vm_scp argv (the option set after-report.sh has always used)
log="$WORK/net.log"; : > "$log"
PATH="$BIN:$PATH" FAKE_NET_LOG="$log" PORT=2231 GUEST_USER=tester HIMMEL_VM_AR_SSH_KEY=/k \
    bash -c '. "$1"; vm_ssh "echo hi"; vm_scp /r/log /l/log' _ "$LIB"
want_ssh=$'-i\n/k\n-p\n2231\n-o\nStrictHostKeyChecking=no\n-o\nUserKnownHostsFile=/dev/null\n-o\nConnectTimeout=15\n-o\nServerAliveInterval=30\n-o\nServerAliveCountMax=20\n-o\nBatchMode=yes\ntester@127.0.0.1\necho hi\n----'
want_scp=$'-i\n/k\n-P\n2231\n-o\nStrictHostKeyChecking=no\n-o\nUserKnownHostsFile=/dev/null\n-o\nConnectTimeout=15\n-o\nBatchMode=yes\ntester@127.0.0.1:/r/log\n/l/log\n----'
if [ "$(cat "$log")" = "$want_ssh"$'\n'"$want_scp" ]; then pass "T3 vm_ssh and vm_scp carry the exact after-report option set"
else fail_case "T3 argv drifted:
$(cat "$log")"; fi

# --- T4: vm_stage_tree, against a fixture repo and a local "guest".
FIX="$WORK/repo"; mkdir -p "$FIX/scripts/lib" "$FIX/docs/setup"
echo ok > "$FIX/scripts/a.sh"; echo ok > "$FIX/docs/setup/t.json"
echo "KEY=placeholder" > "$FIX/.env.example"
echo "SECRET=1" > "$FIX/scripts/.env"; echo "{}" > "$FIX/scripts/x.local.json"
mkdir -p "$FIX/scripts/lib"; cp "$REPO_ROOT/scripts/lib/vm-guest-excludes.sh" "$FIX/scripts/lib/"
# The local runner IS the guest: stdin passes through; `command -v rsync` is steered by GUEST_HAS_RSYNC.
guest() { case "$1" in "command -v rsync"*) [ "${GUEST_HAS_RSYNC:-0}" = 1 ]; return ;; esac; bash -c "$1"; }
export -f guest
cat > "$BIN/rsync" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_RSYNC_LOG:?}"
exit "${FAKE_RSYNC_RC:-0}"
EOS
chmod +x "$BIN/rsync"

G="$WORK/guest-tar"
out=$(PATH="$BIN:$PATH" GUEST_HAS_RSYNC=0 bash -c '. "$1"; vm_stage_tree "$2" "$3" guest unused unused scripts docs/setup/t.json' _ "$LIB" "$FIX" "$G" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$G/scripts/a.sh" ] && [ -f "$G/docs/setup/t.json" ] && [ -f "$G/.env.example" ] \
   && [ ! -e "$G/scripts/.env" ] && [ ! -e "$G/scripts/x.local.json" ]; then
    pass "T4a tar fallback stages the paths + .env.example and none of the secret-set files"
else fail_case "T4a tar stage rc=$rc: $out; tree: $(find "$G" -type f 2>&1 | tr '\n' ' ')"; fi

rlog="$WORK/rsync.log"; : > "$rlog"; G2="$WORK/guest-rsync"
out=$(PATH="$BIN:$PATH" FAKE_RSYNC_LOG="$rlog" GUEST_HAS_RSYNC=1 bash -c '. "$1"; vm_stage_tree "$2" "$3" guest "ssh -p 9" host scripts docs/setup/t.json' _ "$LIB" "$FIX" "$G2" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -qE '^-azR -e ssh -p 9 ' "$rlog" && grep -qF "$FIX/./scripts" "$rlog" && grep -qF "$FIX/./.env.example" "$rlog" \
   && grep -qE -- '--exclude=\.env( |$)' "$rlog" && grep -qF "host:$G2/" "$rlog"; then
    pass "T4b rsync path: -azR, /./ markers, .env.example, the secret excludes, host:dir destination"
else fail_case "T4b rsync stage rc=$rc: $out; rsync: $(cat "$rlog")"; fi

out=$(PATH="$BIN:$PATH" FAKE_RSYNC_LOG="$rlog" FAKE_RSYNC_RC=1 GUEST_HAS_RSYNC=1 bash -c '. "$1"; vm_stage_tree "$2" "$3" guest x host scripts' _ "$LIB" "$FIX" "$G2" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'STAGE FAILED (rsync)' <<< "$out"; then pass "T4c a failed rsync stops the stage (rc=1, STAGE FAILED)"
else fail_case "T4c rc=$rc: $out"; fi

G3="$WORK/guest-empty"
out=$(PATH="$BIN:$PATH" GUEST_HAS_RSYNC=0 bash -c '. "$1"; vm_guest_rsync_excludes() { :; }; vm_guest_tar_excludes() { :; }; vm_stage_tree "$2" "$3" guest x host scripts' _ "$LIB" "$FIX" "$G3" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'secret-exclusion list is empty' <<< "$out" && [ ! -e "$G3" ]; then
    pass "T4d an empty exclude list refuses BEFORE any copy (guest dir never created)"
else fail_case "T4d rc=$rc: $out"; fi

# A requested path missing on the host makes tar exit non-zero while the guest-side
# extractor still exits 0: the stage must fail even though the caller never enabled
# pipefail (the bash -c below sets no options), else a partial tree reads as staged.
G4="$WORK/guest-partial"
out=$(PATH="$BIN:$PATH" GUEST_HAS_RSYNC=0 bash -c '. "$1"; vm_stage_tree "$2" "$3" guest x host scripts no/such/path' _ "$LIB" "$FIX" "$G4" 2>&1); rc=$?
if [ "$rc" -eq 1 ] && grep -q 'STAGE FAILED (tar)' <<< "$out"; then
    pass "T4e a tar producer failure fails the stage without the caller's pipefail"
else fail_case "T4e rc=$rc: $out"; fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all passed"; exit 0; fi
echo "RESULT: $FAILED failure(s)"; exit 1
