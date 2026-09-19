#!/usr/bin/env bash
# scripts/lib/test-cygpath-stub.sh — unit tests for cygpath-stub.sh (HIMMEL-3114).
#
# The cadence suites assert emitted paths against this stub's mapping, so the
# mapping itself must be pinned independently: a stub that drifted would move
# both sides of every emitted-path assertion together and still match.
#
# Platforms tested: linux. The stub is a string mapping, not a Windows
# validation — see the header of cygpath-stub.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/cygpath-stub.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/cygpath-stub.sh"

pass=0
fail=0
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); echo "  ok: $desc"
  else
    fail=$((fail + 1)); echo "  FAIL: $desc"
    echo "        want: [$want]"
    echo "        got:  [$got]"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cygpath-stub-test.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
cygpath_stub_install "$TMP/bin"
CYG="$TMP/bin/cygpath"

echo "[test-cygpath-stub] mapping"
assert_eq "-m maps a POSIX path onto the fake drive (forward slashes)" \
  "$("$CYG" -m /a/b)" 'C:/cygstub/a/b'
assert_eq "-w maps a POSIX path onto the fake drive (backslashes)" \
  "$("$CYG" -w /a/b)" 'C:\cygstub\a\b'
assert_eq "-m preserves a trailing slash (the real tool does)" \
  "$("$CYG" -m /a/b/)" 'C:/cygstub/a/b/'
# shellcheck disable=SC1003  # the expected value really ends in a literal backslash
assert_eq "-w preserves a trailing slash" \
  "$("$CYG" -w /a/b/)" 'C:\cygstub\a\b\'
assert_eq "-m leaves CMD metacharacters and spaces verbatim" \
  "$("$CYG" -m '/t/va&ult %X%^Y')" 'C:/cygstub/t/va&ult %X%^Y'
assert_eq "-m of an already-mixed path is idempotent" \
  "$("$CYG" -m 'C:/cygstub/a/b')" 'C:/cygstub/a/b'
assert_eq "-w of an already-mixed path only flips the slashes" \
  "$("$CYG" -w 'C:/cygstub/a/b')" 'C:\cygstub\a\b'

echo "[test-cygpath-stub] round trip"
assert_eq "-u undoes -m" "$("$CYG" -u "$("$CYG" -m /a/b)")" '/a/b'
assert_eq "-u undoes -w" "$("$CYG" -u "$("$CYG" -w /a/b)")" '/a/b'
assert_eq "-u of the fake root is /" "$("$CYG" -u 'C:/cygstub')" '/'
assert_eq "-u passes a POSIX path through, like the real tool" \
  "$("$CYG" -u /a/b)" '/a/b'
assert_eq "-u maps any OTHER drive path MSYS-style" \
  "$("$CYG" -u 'D:\Users\x')" '/d/Users/x'

echo "[test-cygpath-stub] refusals (never guess)"
for bad in "-m rel/path" "-w rel/path" "-u rel/path" "-x /a" "-m" ""; do
  # shellcheck disable=SC2086  # word-splitting the flag+operand pair is the point
  "$CYG" $bad >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then
    pass=$((pass + 1)); echo "  ok: 'cygpath $bad' exits nonzero (rc=$rc)"
  else
    fail=$((fail + 1)); echo "  FAIL: 'cygpath $bad' exited 0"
  fi
done
"$CYG" -m '' >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then
  pass=$((pass + 1)); echo "  ok: 'cygpath -m <empty>' exits nonzero (rc=$rc)"
else
  fail=$((fail + 1)); echo "  FAIL: 'cygpath -m <empty>' exited 0"
fi

echo "[test-cygpath-stub] install"
if [ -x "$CYG" ]; then
  pass=$((pass + 1)); echo "  ok: stub is executable"
else
  fail=$((fail + 1)); echo "  FAIL: stub is not executable"
fi
assert_eq "shebang is the absolute /bin/sh (cannot recurse into a fake bash)" \
  "$(head -1 "$CYG")" '#!/bin/sh'

echo
echo "test-cygpath-stub: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
