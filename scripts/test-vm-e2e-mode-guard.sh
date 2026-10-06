#!/usr/bin/env bash
# test-vm-e2e-mode-guard.sh — the host-driven VM e2e drivers read vm.mode
# (scripts/lib/vm-mode.sh, HIMMEL-4583) instead of hardcoding localhost:2222:
# under vm.mode=none they SKIP (rc 3) before any ssh, and under vm.mode=remote
# they target vm.remote. Hermetic: a temp HOME carries the config and a stub ssh
# records its argv and refuses, so no VM is ever reached, started or provisioned.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/test-vm-e2e-guard.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.himmel" "$T/bin"
unset HIMMEL_VM_MODE_CONFIG
cat > "$T/bin/ssh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
exit 255
SH
chmod +x "$T/bin/ssh"

run_suite() { # <suite> <config json> -> $out, $rc, $sshlog
    printf '%s\n' "$2" > "$T/home/.himmel/config.json"
    : > "$T/ssh.log"
    out="$(HOME="$T/home" SSH_LOG="$T/ssh.log" PATH="$T/bin:$PATH" bash "$REPO/$1" 2>&1)"; rc=$?
    sshlog="$(cat "$T/ssh.log")"
}

for s in scripts/test-install-symmetry-vm.sh scripts/test-luna-upgrade-vm.sh scripts/test-tarball-install-vm.sh; do
    echo "== $s"
    run_suite "$s" '{"vm":{"mode":"none"}}'
    if [ "$rc" = 3 ] && grep -qF 'SKIP: vm.mode=none' <<< "$out" && [ -z "$sshlog" ]; then
        pass "$s: vm.mode=none -> SKIP rc 3, no ssh"
    else fail "$s: none: rc=$rc ssh='$sshlog' out=$(printf '%s' "$out" | head -3)"; fi

    run_suite "$s" '{"vm":{"mode":"remote","remote":{"ssh":"ops@vm.example","port":2201,"identity":"~/.ssh/vm_key"}}}'
    if grep -qF -- "-p 2201 -i $T/home/.ssh/vm_key" <<< "$sshlog" && grep -qF 'ops@vm.example' <<< "$sshlog"; then
        pass "$s: vm.mode=remote -> ssh targets vm.remote"
    else fail "$s: remote: ssh='$sshlog'"; fi

    # J1932 T2: a resolver error is a loud config error (rc 2), not a SKIP,
    # and explicit [host port ident] args do not turn it into an ssh run.
    run_suite "$s" '{"vm":{"mode":"Local"}}'
    if [ "$rc" = 2 ] && grep -qF 'CONFIG ERROR' <<< "$out" && ! grep -qF 'SKIP' <<< "$out" && [ -z "$sshlog" ]; then
        pass "$s: vm.mode config error -> rc 2 CONFIG ERROR, no ssh"
    else fail "$s: config error: rc=$rc ssh='$sshlog' out=$(printf '%s' "$out" | head -3)"; fi
    printf '%s\n' '{"vm":' > "$T/home/.himmel/config.json"
    : > "$T/ssh.log"
    out="$(HOME="$T/home" SSH_LOG="$T/ssh.log" PATH="$T/bin:$PATH" bash "$REPO/$s" ops@h 2201 "$T/home/.ssh/k" 2>&1)"; rc=$?
    sshlog="$(cat "$T/ssh.log")"
    if [ "$rc" = 2 ] && grep -qF 'CONFIG ERROR' <<< "$out" && [ -z "$sshlog" ]; then
        pass "$s: malformed config + explicit target args -> rc 2, no ssh"
    else fail "$s: malformed + args: rc=$rc ssh='$sshlog'"; fi

    run_suite "$s" '{}'
    if grep -qF -- '-p 2222' <<< "$sshlog" && grep -qF 'localhost' <<< "$sshlog"; then
        pass "$s: vm.mode unset -> localhost:2222 (unchanged)"
    else fail "$s: default: ssh='$sshlog'"; fi
done

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
