#!/usr/bin/env bash
# Smoke test for scripts/lib/vbox.py's VBoxManage path resolution
# (HIMMEL-2512): PATH-first on Linux, explicit VBOXMANAGE_PATH always wins,
# and the Windows default is a last-resort fallback when `which` finds
# nothing. Hermetic — never invokes a real VBoxManage.
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows; a test
# fixture needs no .ps1 twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vbox-path.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — expected '$expected', got '$actual'"
        FAILED=$((FAILED + 1))
    fi
}

PYTHON3="$(command -v python3)"

resolve() {
    # Print vbox.VBOXMANAGE as resolved under the given env.
    "$PYTHON3" -c "import sys; sys.path.insert(0, '$LIB_DIR'); import vbox; print(vbox.VBOXMANAGE)"
}

# T1: VBOXMANAGE_PATH unset, a fake VBoxManage on PATH → resolves via which.
FAKE_BIN_DIR="$TMP/bin"
mkdir -p "$FAKE_BIN_DIR"
FAKE_VBOXMANAGE="$FAKE_BIN_DIR/VBoxManage"
cat >"$FAKE_VBOXMANAGE" <<'EOF'
#!/usr/bin/env bash
echo "fake VBoxManage $*"
EOF
chmod +x "$FAKE_VBOXMANAGE"

got=$(unset VBOXMANAGE_PATH; PATH="$FAKE_BIN_DIR:$PATH" resolve)
expected="$FAKE_VBOXMANAGE"
assert_eq "T1 PATH resolution finds fake VBoxManage" "$expected" "$got"

# T2: explicit VBOXMANAGE_PATH override wins even with a fake on PATH.
got=$(VBOXMANAGE_PATH="/custom/VBoxManage" PATH="$FAKE_BIN_DIR:$PATH" resolve)
assert_eq "T2 explicit VBOXMANAGE_PATH overrides PATH" "/custom/VBoxManage" "$got"

# T3: VBOXMANAGE_PATH unset, nothing on PATH → falls back to the Windows
# default path (a directory with no VBoxManage binary, isolated PATH).
EMPTY_BIN_DIR="$TMP/empty-bin"
mkdir -p "$EMPTY_BIN_DIR"
got=$(unset VBOXMANAGE_PATH; PATH="$EMPTY_BIN_DIR" resolve)
assert_eq "T3 falls back to Windows default when PATH has nothing" \
    'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe' "$got"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILED"
    exit 1
fi
