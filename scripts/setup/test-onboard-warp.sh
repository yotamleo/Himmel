#!/usr/bin/env bash
# Smoke test for scripts/setup/onboard-warp.sh (HIMMEL-360). Runs against a
# controlled WARP_EXE + a clean PATH so the result never depends on whether
# Warp is actually installed on the test machine.
set -uo pipefail

CLI="$(cd "$(dirname "$0")" && pwd)/onboard-warp.sh"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — output missing: $needle"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Clean PATH with bash + coreutils but (almost certainly) no `warp`, so the
# `command -v warp` branch is deterministic regardless of the host.
BASH_BIN_DIR="$(dirname "$(command -v bash)")"
CLEAN_PATH="$BASH_BIN_DIR:/usr/bin:/bin"

# 1. binary MISSING: WARP_EXE points nowhere, warp not on PATH
out=$(PATH="$CLEAN_PATH" WARP_EXE="$TMP/none.exe" bash "$CLI" 2>&1); rc=$?
assert_rc "missing run exits 0" 0 "$rc"
assert_has "missing run reports MISSING" "warp binary: MISSING" "$out"
assert_has "missing run prints skills line" "/open-warp" "$out"
assert_has "missing run prints plugin line" "warp@claude-code-warp" "$out"

# 2. binary present via WARP_EXE (not on PATH)
touch "$TMP/warp.exe"
out=$(PATH="$CLEAN_PATH" WARP_EXE="$TMP/warp.exe" bash "$CLI" 2>&1); rc=$?
assert_rc "WARP_EXE run exits 0" 0 "$rc"
assert_has "WARP_EXE run reports the path" "$TMP/warp.exe" "$out"

# 3. binary present on PATH takes precedence over WARP_EXE
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\n' > "$TMP/bin/warp"
chmod +x "$TMP/bin/warp"
out=$(PATH="$TMP/bin:$CLEAN_PATH" WARP_EXE="$TMP/none.exe" bash "$CLI" 2>&1); rc=$?
assert_rc "PATH-warp run exits 0" 0 "$rc"
assert_has "PATH-warp run reports the PATH location" "$TMP/bin/warp" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
