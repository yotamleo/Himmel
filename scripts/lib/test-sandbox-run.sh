#!/usr/bin/env bash
# HIMMEL-4912: real filesystem boundary, not assertions about bwrap flags.
# Regression: dropping the read-only root lets the executing canary row escape.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/scripts/lib/sandbox-run.sh"
TMP="$(mktemp -d /tmp/sandbox-run-test.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# RED control: this harmless corpus row really executes, only in throwaway tmp.
CANARY="$TMP/canary"
printf 'touch %q\n' "$CANARY" > "$TMP/row.sh"
bash "$TMP/row.sh"
if [ ! -e "$CANARY" ]; then
    bad 'unsandboxed canary control did not execute'
else
    printf 'RED control: canary untouched assertion FAILS without sandbox\n'
    ok 'unsandboxed harmless row trips canary check'
fi
rm -f "$CANARY"

if [ ! -f "$RUNNER" ]; then
    bad 'sandbox runner missing: filesystem isolation not implemented'
    exit 1
fi

OUT=$(bash "$RUNNER" --canary "$CANARY" --read-only "$TMP/row.sh" -- bash -c 'echo ROW_STARTED; bash "$1"' _ "$TMP/row.sh" 2>&1); RC=$?
if [ "$RC" = 0 ] && [ ! -e "$CANARY" ] && [[ "$OUT" == *ROW_STARTED* ]]; then
    ok 'executing harmless canary row cannot write outside sandbox'
else
    bad "canary boundary: rc=$RC output=$OUT"
fi
# A real Unix socket inode on the host must not cross the bind boundary.
python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$TMP/host.sock"
if [ ! -S "$TMP/host.sock" ]; then bad 'host socket control missing'; exit 1; fi
OUT=$(bash "$RUNNER" -- bash -c 'test ! -S "$1"' _ "$TMP/host.sock" 2>&1); RC=$?
if [ "$RC" = 0 ]; then ok 'host Unix socket absent inside'; else bad "host Unix socket exposed: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- bash -c 'touch "$HOME/ok" "$TMPDIR/ok"; test -f "$HOME/ok" && test -f "$TMPDIR/ok" && echo WRITABLE' 2>&1); RC=$?
if [ "$RC" = 0 ] && [[ "$OUT" == *WRITABLE* ]]; then ok 'HOME and scratch are writable'; else bad "writable fixtures: $OUT"; fi
OUT=$(bash "$RUNNER" -- bash -c 'echo HOOK_DENY; exit 2' 2>&1); RC=$?
if [ "$RC" = 2 ] && [[ "$OUT" == *HOOK_DENY* ]]; then ok 'hook deny status and output preserved'; else bad "hook status: rc=$RC $OUT"; fi
OUT=$(PATH=/nonexistent /bin/bash "$RUNNER" -- /bin/true 2>&1); RC=$?
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'bwrap is required'* ]]; then ok 'missing bwrap fails closed'; else bad "missing dependency: rc=$RC $OUT"; fi
OUT=$(SANDBOX_TEST_SECRET=private-fixture bash "$RUNNER" -- bash -c 'printf "%s" "${SANDBOX_TEST_SECRET-unset}"' 2>&1); RC=$?
if [ "$RC" = 0 ] && [ "$OUT" = unset ]; then ok 'ambient environment not inherited'; else bad "environment: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- python3 -I -c 'import socket; s=socket.socket(); s.settimeout(1); s.connect(("1.1.1.1",443))' 2>&1); RC=$?
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'Network is unreachable'* ]]; then ok 'network namespace blocks outbound connection'; else bad "network isolation: rc=$RC $OUT"; fi
mkdir "$TMP/readonly"
OUT=$(bash "$RUNNER" --read-only "$TMP/readonly" -- bash -c 'echo WRITE_STARTED; touch "$1/escape"' _ "$TMP/readonly" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && [[ "$OUT" == *WRITE_STARTED* ]] && [[ "$OUT" == *'Read-only file system'* ]] && [ ! -e "$TMP/readonly/escape" ]; then
    ok 'explicit fixture bind is read-only'
else bad "fixture bind writable or command did not run: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" --read-only "$TMP/host.sock" -- /usr/bin/true 2>&1); RC=$?
if [ "$RC" = 125 ] && [[ "$OUT" == *'refusing socket/device/FIFO input'* ]]; then ok 'socket input refused'; else bad "socket input: rc=$RC $OUT"; fi
OUT=$(bash "$RUNNER" -- python3 -I -c 'import resource; assert resource.getrlimit(resource.RLIMIT_AS)==(1073741824,1073741824); assert resource.getrlimit(resource.RLIMIT_CPU)==(60,60); assert resource.getrlimit(resource.RLIMIT_NPROC)==(128,128)' 2>&1); RC=$?
if [ "$RC" = 0 ]; then ok 'child address-space CPU and process limits enforced'; else bad "resource limits: rc=$RC $OUT"; fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
