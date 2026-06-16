#!/usr/bin/env bash
# Smoke test for scripts/setup/install-cs.sh (HIMMEL-152).
#
# Usage: bash scripts/setup/test-install-cs.sh
#
# Strategy: run the installer with a hermetic PATH built from PATH-stub
# fakes in mktemp -d dirs — a fake `uname` (driven by FAKE_UNAME), fake
# `cs` binaries, and wrapper shims for the few real utilities the tested
# branches need (tr/grep/head/sed). No network: curl + brew are stubbed
# to no-ops that log to net.log, and the test asserts the log stays empty.
#
# Covers (offline-testable branches, per HIMMEL-152):
#   1. Windows refusal (mingw uname -> rc=2)
#   2. Already-installed early return (cs prints claude-squad version -> rc=0)
#   3. Name-collision refusal (cs prints non-claude-squad version -> rc=1)
#   4. Unsupported platform (uname=FreeBSD -> rc=1)
#   5. No-package-manager linux branch (no apt-get/dnf/yum/pacman -> rc=1)
#   6. darwin Homebrew-missing refusal (no brew on PATH -> rc=1)
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/install-cs.sh"
REAL_BASH="$(command -v bash)"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_rc() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then pass "$name (rc=$actual)"; else fail "$name" "expected rc=$expected, got rc=$actual"; fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}

# Keep mktemp output in POSIX form — a cygpath -m mixed path (C:/...)
# would break PATH splitting on the colon.
TMP_ROOT=$(mktemp -d)

# --- stub PATH layout -------------------------------------------------
# bin-base:  fake uname (FAKE_UNAME-driven) + no-op curl/brew (net.log)
#            + wrapper shims for the real utilities install-cs.sh needs.
# bin-no-brew: copy of bin-base minus brew — simulates a darwin host
#              without Homebrew (case 6).
# bin-cs-good: fake cs whose version output says claude-squad.
# bin-cs-bad:  fake cs whose version output is an unrelated tool.
BIN_BASE="$TMP_ROOT/bin-base"
BIN_NO_BREW="$TMP_ROOT/bin-no-brew"
BIN_CS_GOOD="$TMP_ROOT/bin-cs-good"
BIN_CS_BAD="$TMP_ROOT/bin-cs-bad"
NET_LOG="$TMP_ROOT/net.log"
mkdir -p "$BIN_BASE" "$BIN_NO_BREW" "$BIN_CS_GOOD" "$BIN_CS_BAD"

# Wrapper shims: exec the real binary by absolute path so the hermetic
# PATH still provides the utilities install-cs.sh uses. Deliberately NO
# tmux/apt-get/dnf/yum/pacman — their absence is what cases 4-5 exercise.
for tool in tr grep head sed; do
    real="$(command -v "$tool")"
    if [ -z "$real" ]; then
        echo "SETUP FAIL: required utility '$tool' not found on PATH" >&2
        exit 1
    fi
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$real" > "$BIN_BASE/$tool"
    chmod +x "$BIN_BASE/$tool"
done

cat > "$BIN_BASE/uname" <<'FAKE'
#!/bin/bash
printf '%s\n' "${FAKE_UNAME:-Linux}"
FAKE
chmod +x "$BIN_BASE/uname"

# curl + brew: no-op, but record any invocation — the smoke suite must
# never reach the network-touching branches.
for tool in curl brew; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 0\n' "$tool" "$NET_LOG" > "$BIN_BASE/$tool"
    chmod +x "$BIN_BASE/$tool"
done

# bin-no-brew: everything in bin-base EXCEPT brew (curl stub stays, so
# the no-network guard still covers case 6).
for stub in "$BIN_BASE"/*; do
    name="$(basename "$stub")"
    [ "$name" = "brew" ] && continue
    cp "$stub" "$BIN_NO_BREW/$name"
    chmod +x "$BIN_NO_BREW/$name"
done

cat > "$BIN_CS_GOOD/cs" <<'FAKE'
#!/bin/bash
echo "claude-squad version 1.0.0"
FAKE
chmod +x "$BIN_CS_GOOD/cs"

cat > "$BIN_CS_BAD/cs" <<'FAKE'
#!/bin/bash
echo "Coursier 2.1.10 (https://get-coursier.io)"
FAKE
chmod +x "$BIN_CS_BAD/cs"

# run_case <fake_uname> <extra_path_dir_or_empty> [base_dir] — runs
# install-cs.sh under the hermetic PATH; base_dir defaults to BIN_BASE
# (pass BIN_NO_BREW to simulate brew absence). Captures combined output
# in OUT, rc in RC.
OUT=""
RC=0
run_case() {
    local fake_uname="$1" extra_dir="$2" base_dir="${3:-$BIN_BASE}" stub_path
    stub_path="$base_dir"
    if [ -n "$extra_dir" ]; then
        stub_path="$extra_dir:$base_dir"
    fi
    RC=0
    OUT=$(PATH="$stub_path" FAKE_UNAME="$fake_uname" "$REAL_BASH" "$SCRIPT" 2>&1) || RC=$?
}

# Case 1: Windows refusal ----------------------------------------------

echo "TEST 1: mingw uname refuses with rc=2"
run_case "MINGW64_NT-10.0-26100" ""
assert_rc "windows refusal exit code" 2 "$RC"
assert_contains "points at setup.ps1" "scripts/setup.ps1" "$OUT"

# Case 2: already installed early return -------------------------------

echo "TEST 2: claude-squad cs on PATH -> skip install, rc=0"
run_case "Linux" "$BIN_CS_GOOD"
assert_rc "already-installed exit code" 0 "$RC"
assert_contains "skip message" "skipping install" "$OUT"
assert_contains "version echoed" "claude-squad version 1.0.0" "$OUT"

# Case 3: name-collision refusal ---------------------------------------

echo "TEST 3: non-claude-squad cs on PATH -> refuse, rc=1"
run_case "Linux" "$BIN_CS_BAD"
assert_rc "collision exit code" 1 "$RC"
assert_contains "collision message" "does not look like claude-squad" "$OUT"
assert_contains "collision shows imposter" "Coursier" "$OUT"

# Case 4: unsupported platform -----------------------------------------

echo "TEST 4: uname=FreeBSD -> unsupported, rc=1"
run_case "FreeBSD" ""
assert_rc "unsupported platform exit code" 1 "$RC"
assert_contains "unsupported message" "unsupported platform 'freebsd'" "$OUT"

# Case 5: linux without a package manager ------------------------------

echo "TEST 5: linux, no tmux, no apt-get/dnf/yum/pacman -> rc=1"
run_case "Linux" ""
assert_rc "no-package-manager exit code" 1 "$RC"
assert_contains "no-package-manager message" "no known package manager" "$OUT"

# Case 6: darwin without Homebrew ---------------------------------------

echo "TEST 6: darwin, no tmux, no brew -> refuse tmux auto-install, rc=1"
run_case "Darwin" "" "$BIN_NO_BREW"
assert_rc "darwin brew-missing exit code" 1 "$RC"
assert_contains "brew-missing message" "Homebrew not installed; cannot auto-install tmux" "$OUT"
assert_contains "brew-missing points at brew.sh" "https://brew.sh" "$OUT"

# No network: curl/brew stubs must never have fired --------------------

echo "TEST 7: no curl/brew invocations across all cases"
if [ -s "$NET_LOG" ]; then
    fail "network stubs invoked" "$(cat "$NET_LOG")"
else
    pass "net.log empty"
fi

# Summary ---------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
