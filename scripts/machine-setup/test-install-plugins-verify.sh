#!/usr/bin/env bash
# test-install-plugins-verify.sh — hermetic test for the HIMMEL-361 post-install
# PRESENCE verification in scripts/machine-setup/install-plugins.sh.
#
# Stubs the `claude` CLI on PATH so nothing touches the operator's real plugin
# set, then drives the real script against a temp template and asserts:
#   1. every template plugin present → exit 0 + "All N enabled plugins present"
#   2. one template plugin absent    → exit 1, naming the absent plugin
#   3. --dry-run                     → exit 0, verify skipped
#
# install-plugins.ps1 carries the SAME verify logic as a PowerShell twin — it is
# covered by its own twin test-install-plugins-verify.ps1 (HIMMEL-364); keep
# both in lockstep when changing either.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "PASS (skipped)"; exit 0; }

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stub `claude`: install/marketplace are no-ops; `plugin list` prints whatever
# specs $STUB_PRESENT names (space-separated). The real script extracts specs
# from the list output by regex, so a plain "  <spec>" line is enough.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  # STUB_LIST_FAIL simulates `claude plugin list` erroring out (e.g. broken CLI).
  if [ -n "${STUB_LIST_FAIL:-}" ]; then echo "stub: list boom" >&2; exit 3; fi
  for s in ${STUB_PRESENT:-}; do printf '  %s\n' "$s"; done
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Temp template: two good plugins + one the "failing" run won't report present.
TEMPLATE="$TMP/settings-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {
    "good-a@mp": true,
    "good-b@mp": true,
    "bogus@nowhere": true
  },
  "extraKnownMarketplaces": {}
}
JSON

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

# 1. all present → exit 0 + summary
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="good-a@mp good-b@mp bogus@nowhere" \
      bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
assert_rc "all-present exits 0" 0 "$rc"
assert_has "all-present prints summary" "All 3 enabled plugins present" "$out"

# 2. one absent → exit 1, names it (the present two must NOT be flagged)
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="good-a@mp good-b@mp" \
      bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
assert_rc "missing exits 1" 1 "$rc"
assert_has "missing names the absent plugin" "bogus@nowhere" "$out"
assert_has "missing reports a failure count" "1 plugin(s) not present" "$out"
case "$out" in
    *"good-a@mp —"*|*"good-b@mp —"*) echo "FAIL present plugin wrongly flagged"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS present plugins not flagged" ;;
esac

# 3. --dry-run → exit 0, verify skipped (no plugin list call)
out=$(PATH="$STUB_DIR:$PATH" STUB_PRESENT="" \
      bash "$script" --template "$TEMPLATE" --dry-run 2>&1); rc=$?
assert_rc "dry-run exits 0" 0 "$rc"
assert_has "dry-run skips verify" "verify skipped" "$out"

# 4. `claude plugin list` fails → fail closed (exit 1) + surface the error
out=$(PATH="$STUB_DIR:$PATH" STUB_LIST_FAIL=1 \
      bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
assert_rc "list-failure fails closed (exit 1)" 1 "$rc"
assert_has "list-failure surfaces claude stderr" "stub: list boom" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
