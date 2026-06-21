#!/usr/bin/env bash
# test-luna-upgrade-vm.sh -- host-driven, CROSS-OS VM e2e for the luna-second-
# brain upgrade roundtrip (HIMMEL-493 Linux + HIMMEL-522 Windows, epic
# HIMMEL-483). Copies the shipped templates/luna-second-brain/ tree to a clean
# Ubuntu OR Windows VM over ssh (key auth) and, on the VM:
#   A. runs the shipped hermetic engine suite (scripts/test-upgrade.sh) against
#      the REAL template -- proves the T1..Tn cases pass on the VM, not just the
#      host. On Windows it ALSO runs the PowerShell smoke (test-upgrade.ps1) to
#      prove the PS entry (upgrade.ps1 -> Git Bash -> upgrade.sh) wires through.
#   B. runs a REAL scaffold -> rollback -> upgrade ROUNDTRIP with the real
#      template: scaffold a fresh vault, plant user content, diverge a
#      template-owned file, roll the version stamp back, then
#      --check / --dry-run / --yes and assert the engine refreshes owned files,
#      preserves user content, stamps the new version, and is idempotent.
#
# This is the upgrade-path counterpart to test-install-symmetry-vm.sh: that
# proves install/uninstall on a fresh VM; this proves the /luna-upgrade ENGINE
# (templates/luna-second-brain/scripts/upgrade.sh, the deterministic core the
# skill orchestrates) on a fresh VM. No claude / no LLM call -- deterministic.
#
# Cross-OS notes (HIMMEL-522): the guest is detected via `echo %OS%`
# (Windows_NT on cmd.exe, the Windows OpenSSH default shell; literal "%OS%" on a
# POSIX guest). On Windows the engine runs under Git Bash; staging streams a
# plain tar over ssh stdin and the remote body is fed via stdin with vars
# PREPENDED (cmd.exe does not honor POSIX `VAR=x cmd` env-prefixes). The engine's
# real deps are a WORKING python + git + sha256sum -- NOT node (never invoked).
# On Windows `python3` is the Microsoft Store stub (on PATH but emits no stdout),
# so a working python is resolved by probing stdout, not `command -v`. A
# bootstrap-floor Linux VM lacking python3 gets a best-effort `sudo apt-get`
# install (scoped NOPASSWD drop-in, HIMMEL-492).
#
# Usage:
#   bash scripts/test-luna-upgrade-vm.sh [user@host] [port] [identity]
#   defaults: localhost 2222 $HOME/.ssh/id_ed25519
#   Windows:  bash scripts/test-luna-upgrade-vm.sh <winuser>@localhost 2223 <key>
#
# Exit codes: 0 = all assertions passed; 1 = an assertion failed; 3 = the VM was
# unreachable (key auth) -- not a code failure, re-run when the VM is provisioned.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
#
# No `set -e` (matches test-install-symmetry-vm.sh): the remote body is a
# fails-counter test harness that must run ALL assertions, not bail on the first
# — so it deliberately does not use -e either. The final `ssh` carries the remote
# body's exit code, which is captured into `rc` and propagated via `exit "$rc"`,
# so a remote failure still fails this script.
set -uo pipefail

HOSTSPEC="${1:-localhost}"
PORT="${2:-2222}"
IDENT="${3:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-p $PORT -i $IDENT -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="/tmp/himmel-luna-upgrade-vm"
TEMPLATE="$REPO/templates/luna-second-brain"
OUT_LOG="$(mktemp -t luna-upgrade-vm-out.XXXXXX)"
trap 'rm -f "$OUT_LOG"' EXIT   # clean the capture temp on every exit path (incl. rc 1/3)

# Intentional: $SSH_OPTS word-splits into flags (SC2086) and the remote command
# expands host-side before transport (SC2029 -- we WANT host vars like
# REMOTE_DIR substituted before the VM runs the body).
# shellcheck disable=SC2086,SC2029
ssh_vm() { ssh $SSH_OPTS "$HOSTSPEC" "$@"; }

echo "==> luna-upgrade VM e2e: $HOSTSPEC:$PORT (template: $TEMPLATE)"

if [ ! -d "$TEMPLATE" ] || [ ! -f "$TEMPLATE/scripts/upgrade.sh" ]; then
  echo "ERROR: template not found at $TEMPLATE (scripts/upgrade.sh missing)" >&2
  exit 1
fi

# 0. connectivity (fail soft with rc 3 -- VM not ready is not a code defect).
if ! ssh_vm 'echo connected' >/dev/null 2>&1; then
  echo "ERROR: cannot ssh to $HOSTSPEC:$PORT with key $IDENT (publickey rejected)." >&2
  echo "  The VM is not reachable by this session -- run this once the VM is" >&2
  echo "  provisioned (the agent's pubkey in the VM's authorized_keys)." >&2
  exit 3
fi

# 0b. Detect the guest OS. cmd.exe (Windows OpenSSH default shell) expands %OS%
# to "Windows_NT"; a POSIX guest echoes the literal "%OS%". A Windows guest runs
# the engine under Git Bash and additionally exercises the PowerShell entry.
GUEST_OS="$(ssh_vm 'echo %OS%' 2>/dev/null || true)"
case "$GUEST_OS" in
  Windows_NT*) GUEST_WIN=1 ;;
  *)           GUEST_WIN=0 ;;
esac
echo "[detect] guest OS probe='$GUEST_OS' -> GUEST_WIN=$GUEST_WIN"

# 1. stage the real template to $REMOTE_DIR (a Git-Bash path on both OSes).
echo "[stage] copying $TEMPLATE to $REMOTE_DIR ..."
if [ "$GUEST_WIN" -eq 1 ]; then
  # Windows guest: the default ssh shell is cmd.exe, so POSIX rm/mkdir and env-
  # prefixes are not available directly -- route through Git Bash via
  # bash -lc "..." (cmd keeps the double-quoted arg intact). Stage by streaming a
  # plain tar over ssh stdin (no -z: avoids a gzip dependency; the link is
  # loopback). This dodges both scp Windows-path translation AND cmd quoting.
  ssh_vm "bash -lc \"rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR\""
  # Exclude .git/node_modules for parity with the Linux rsync/scp branch (keeps
  # the stream small + deterministic even if the template ever grows them).
  tar -C "$(dirname "$TEMPLATE")" --exclude='*/.git' --exclude='*/node_modules' \
    -cf - "$(basename "$TEMPLATE")" \
    | ssh_vm "bash -lc \"tar -C $REMOTE_DIR -xf -\""
else
  ssh_vm "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
  if command -v rsync >/dev/null 2>&1 && ssh_vm 'command -v rsync >/dev/null 2>&1'; then
    rsync -az -e "ssh $SSH_OPTS" --exclude '.git' --exclude 'node_modules' \
      "$TEMPLATE" "$HOSTSPEC:$REMOTE_DIR/"
  else
    # shellcheck disable=SC2086
    scp -P $PORT -i "$IDENT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -r \
      "$TEMPLATE" "$HOSTSPEC:$REMOTE_DIR/"
  fi
fi

# 2. run the assertions on the VM. The default ssh shell differs by OS (cmd.exe
#    on Windows, sh on Linux), so a POSIX env-prefix (VAR=x bash -s) is NOT
#    portable -- instead PREPEND the host-resolved vars to the stdin body and run
#    a bare `bash -s` (works under both cmd.exe and sh). Self-contained body;
#    echoes RESULT:/RAN: lines and exits non-zero on any failure.
{
printf 'REMOTE_DIR=%s\nWIN=%s\n' "$REMOTE_DIR" "$GUEST_WIN"
cat <<'REMOTE'
set -uo pipefail
TMPL="$REMOTE_DIR/luna-second-brain"
UPGRADE="$TMPL/scripts/upgrade.sh"
fails=0
ran=0
pass() { echo "PASS  $1"; ran=$((ran+1)); }
fail() { echo "FAIL  $1 -- $2"; fails=$((fails+1)); ran=$((ran+1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2' got '$3'"; fi; }
sha_of() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo MISSING; fi; }

echo "---- VM: $(uname -srm) ----"

if [ ! -f "$UPGRADE" ]; then
  echo "FAIL  template not staged ($UPGRADE missing)"; echo "RESULT: 1 failure(s)"; exit 1
fi

# Resolve a WORKING python the way the engine does (on Windows `python3` is the
# Microsoft Store stub: on PATH but emits no stdout). The engine's real deps are
# a working python + git + sha256sum -- NOT node (it is never invoked; the prior
# node gate was vestigial).
_have_py() {
  for c in python3 python py; do
    command -v "$c" >/dev/null 2>&1 && [ "$("$c" -c 'print(1)' 2>/dev/null)" = "1" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
PYBIN="$(_have_py || true)"
HAVE_PY=0; [ -n "$PYBIN" ] && HAVE_PY=1

# On a bootstrap-floor Linux VM python3 may be absent; install best-effort via
# the scoped NOPASSWD drop-in (HIMMEL-492). Windows has python; skip apt there.
if [ "$HAVE_PY" -ne 1 ] && [ "${WIN:-0}" != 1 ]; then
  echo "  [setup] no working python -- installing via sudo apt-get (HIMMEL-492 NOPASSWD) ..."
  sudo -n apt-get install -y python3 >/tmp/luna-upgrade-py.log 2>&1 \
    || echo "  [setup] apt-get install python3 failed (see /tmp/luna-upgrade-py.log)"
  PYBIN="$(_have_py || true)"; HAVE_PY=0; [ -n "$PYBIN" ] && HAVE_PY=1
fi

# GAP scan for the engine's actual hard deps.
[ "$HAVE_PY" -eq 1 ] || echo "GAP:  no working python on VM -- the upgrade engine needs python3/python/py" >&2
for t in git sha256sum; do
  command -v "$t" >/dev/null 2>&1 || echo "GAP:  '$t' missing on VM -- the upgrade engine needs it" >&2
done

# --------------------------------------------------------------------------
# Phase A: shipped engine suite against the REAL template, on the VM. Proves the
# T1..Tn engine cases pass on this OS (under Git Bash on Windows). On Windows,
# ALSO run the PowerShell smoke test-upgrade.ps1 to prove the PS entry
# (upgrade.ps1 -> Git Bash -> upgrade.sh) wires through on real Windows.
# --------------------------------------------------------------------------
echo "---- Phase A: shipped engine suite (scripts/test-upgrade.sh) ----"
if [ "$HAVE_PY" -eq 1 ] && command -v git >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
  if bash "$TMPL/scripts/test-upgrade.sh" >/tmp/luna-upgrade-engine.log 2>&1; then
    pass "engine suite (test-upgrade.sh) green on VM"
  else
    fail "engine suite (test-upgrade.sh) on VM" "see tail below"
    tail -15 /tmp/luna-upgrade-engine.log | sed 's/^/      /'
  fi
else
  echo "GAP:  engine suite SKIPPED -- needs python+git+sha256sum" >&2
fi

if [ "${WIN:-0}" = 1 ]; then
  echo "---- Phase A (Windows): PowerShell smoke (scripts/test-upgrade.ps1) ----"
  if command -v pwsh >/dev/null 2>&1 && pwsh -NoProfile -Command "exit 0" >/dev/null 2>&1; then
    ps1_win="$(cygpath -w "$TMPL/scripts/test-upgrade.ps1")"
    if pwsh -NoProfile -File "$ps1_win" >/tmp/luna-upgrade-ps.log 2>&1; then
      pass "PowerShell smoke (test-upgrade.ps1) green on Windows"
    else
      fail "PowerShell smoke (test-upgrade.ps1) on Windows" "see tail below"
      tail -15 /tmp/luna-upgrade-ps.log | sed 's/^/      /'
    fi
  else
    echo "GAP:  PS smoke SKIPPED -- pwsh (PowerShell 7) not available on the guest" >&2
  fi
fi

# --------------------------------------------------------------------------
# Phase B: REAL scaffold -> rollback -> upgrade roundtrip with the real template.
# --------------------------------------------------------------------------
echo "---- Phase B: real-template scaffold -> upgrade roundtrip ----"
if [ "$HAVE_PY" -ne 1 ]; then
  echo "GAP:  roundtrip SKIPPED -- the engine needs a working python" >&2
  echo "RAN: $ran assertions"; echo "RESULT: $fails failure(s)"; [ "$fails" -eq 0 ]; exit
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
VAULT="$WORK/vault"
cp -r "$TMPL" "$VAULT"

# Template version (the level a fresh upgrade should stamp the vault to).
TVER=$("$PYBIN" -c 'import json,sys;print(json.load(open(sys.argv[1]))["metadata"]["version"])' \
  "$TMPL/marketplace/.claude-plugin/marketplace.json" 2>/dev/null)

# Plant pure user content the template never ships -- must survive byte-identical.
mkdir -p "$VAULT/50-Journal/Daily"
printf 'my private daily note -- keep me byte-identical\n' > "$VAULT/50-Journal/Daily/2026-06-21.md"
USER_SHA=$(sha_of "$VAULT/50-Journal/Daily/2026-06-21.md")

# Diverge a template-OWNED file (setup.sh is overwrite-class, asserted by T11) so
# the upgrade has a real refresh to perform; assert it is restored to template.
printf 'USER DIVERGED THIS\n' > "$VAULT/scripts/setup.sh"

# Roll the stamp back so the vault reads as behind (v0.0.0 -> full pass).
rm -f "$VAULT/.vault-template.json"

run_up() { bash "$UPGRADE" --template-dir "$TMPL" --vault-dir "$VAULT" "$@"; }

# B1: --check on the behind vault reports an upgrade available, mutates nothing.
chk_before=$(find "$VAULT" -type f -exec sha256sum {} \; | sort)
out=$(run_up --check 2>&1); rc=$?
assert_eq "B1 --check rc" "0" "$rc"
case "$out" in *available*|*v0.0.0*) pass "B1 --check reports upgrade available" ;; *) fail "B1 --check reports upgrade available" "got: $out" ;; esac
chk_after=$(find "$VAULT" -type f -exec sha256sum {} \; | sort)
assert_eq "B1 --check made zero changes" "$chk_before" "$chk_after"

# B2: --dry-run mutates nothing.
dry_before=$(find "$VAULT" -type f -exec sha256sum {} \; | sort)
run_up --dry-run >/dev/null 2>&1; rc=$?
dry_after=$(find "$VAULT" -type f -exec sha256sum {} \; | sort)
assert_eq "B2 --dry-run rc" "0" "$rc"
assert_eq "B2 --dry-run made zero changes" "$dry_before" "$dry_after"

# B3: --yes applies cleanly.
out=$(run_up --yes 2>&1); rc=$?
assert_eq "B3 --yes rc" "0" "$rc"

# B4: the diverged template-owned file is restored to the template's version.
assert_eq "B4 diverged owned file (scripts/setup.sh) restored" \
  "$(sha_of "$TMPL/scripts/setup.sh")" "$(sha_of "$VAULT/scripts/setup.sh")"

# B5: user content is byte-identical (never touched).
assert_eq "B5 planted user content untouched" "$USER_SHA" "$(sha_of "$VAULT/50-Journal/Daily/2026-06-21.md")"

# B6: the version stamp is written and records the template version.
if [ -f "$VAULT/.vault-template.json" ]; then
  pass "B6 version stamp written"
  got_ver=$("$PYBIN" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
    "$VAULT/.vault-template.json" 2>/dev/null)
  assert_eq "B6 stamp records template version" "$TVER" "$got_ver"
else
  fail "B6 version stamp written" "no .vault-template.json after --yes"
fi

# B7: idempotency -- a second --check now reports current.
out=$(run_up --check 2>&1); rc=$?
assert_eq "B7 second --check rc" "0" "$rc"
case "$out" in *current*) pass "B7 second --check reports current (idempotent)" ;; *) fail "B7 second --check reports current" "got: $out" ;; esac

echo "RAN: $ran assertions"
echo "RESULT: $fails failure(s)"
[ "$fails" -eq 0 ]
REMOTE
} | ssh_vm "bash -s" | tee "$OUT_LOG"
rc=${PIPESTATUS[1]}

# RAN floor: the remote body emits `RAN: <n> assertions`. Assert it cleared the
# Phase B floor (B1..B7 = 12 asserts) so a silent Phase-B skip (e.g. a missing
# python GAP-exit) can NOT report a vacuous green: rc would be 0 but RAN < 12.
PHASE_B_FLOOR=12
ran=$(grep -oE 'RAN: [0-9]+' "$OUT_LOG" | grep -oE '[0-9]+' | tail -1)
if [ "$rc" -eq 0 ] && [ "${ran:-0}" -lt "$PHASE_B_FLOOR" ]; then
  echo "==> luna-upgrade VM e2e FAILED -- only ${ran:-0} assertions ran (floor $PHASE_B_FLOOR); Phase B was skipped (vacuous green)" >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "==> luna-upgrade VM e2e PASSED (RAN ${ran:-?} assertions)"
else
  echo "==> luna-upgrade VM e2e FAILED (rc=$rc)" >&2
fi
exit "$rc"
