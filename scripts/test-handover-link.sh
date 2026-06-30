#!/usr/bin/env bash
# Smoke test for scripts/handover-link.sh CLI.
set -uo pipefail

CLI="$(cd "$(dirname "$0")" && pwd)/handover-link.sh"
[ -x "$CLI" ] || chmod +x "$CLI"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_stdout_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — stdout missing: $needle"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# T1: status (default) on mode A → rc=0, mentions "mode:       A"
unset HANDOVER_DIR
out=$(bash "$CLI" 2>&1)
rc=$?
assert_rc "T1 status default mode A" 0 "$rc"
assert_stdout_has "T1 reports mode A" "mode:       A" "$out"

# T2: explicit status verb mode B → rc=0, mentions "mode:       B"
mkdir -p "$TMP/ext"
out=$(HANDOVER_DIR="$TMP/ext" bash "$CLI" status 2>&1)
rc=$?
assert_rc "T2 status mode B" 0 "$rc"
assert_stdout_has "T2 reports mode B" "mode:       B" "$out"

# T3: doctor on misconfigured HANDOVER_DIR → rc=1
HANDOVER_DIR="$TMP/does-not-exist" bash "$CLI" doctor >/dev/null 2>&1
assert_rc "T3 doctor fails on missing HANDOVER_DIR" 1 "$?"

# T4: doctor when HANDOVER_DIR is inside the repo → rc=1 (defeats externalisation)
REPO=$(git rev-parse --show-toplevel)
mkdir -p "$REPO/.tmp-handover-self"
HANDOVER_DIR="$REPO/.tmp-handover-self" bash "$CLI" doctor >/dev/null 2>&1
rc=$?
rm -rf "$REPO/.tmp-handover-self"
assert_rc "T4 doctor flags HANDOVER_DIR inside repo" 1 "$rc"

# T5: --help exits 0 and prints usage
out=$(bash "$CLI" --help 2>&1)
rc=$?
assert_rc "T5 --help rc=0" 0 "$rc"
assert_stdout_has "T5 --help prints usage" "Usage:" "$out"

# T6: unknown verb → rc=64 (EX_USAGE)
bash "$CLI" wat >/dev/null 2>&1
assert_rc "T6 unknown verb rc=64" 64 "$?"

# T7: doctor on healthy mode A → rc=0
# Mode A resolves <repo-root>/handovers via `git rev-parse` from cwd. In the
# public mirror, handovers/ is a PRIVATE_PATH (absent), so running doctor from
# this checkout would fail-closed (rc=2 → doctor rc=1). Run it inside an
# isolated temp git repo that owns its own handovers/ dir — hermetic, no
# dependence on the checkout having handovers/.
unset HANDOVER_DIR
T7REPO="$TMP/modeA-repo"
mkdir -p "$T7REPO/handovers"
git init -q "$T7REPO"
( cd "$T7REPO" && bash "$CLI" doctor ) >/dev/null 2>&1
assert_rc "T7 doctor mode A healthy" 0 "$?"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
