#!/usr/bin/env bash
# test-install-plugins-diagnostics.sh — install-plugins.sh surfaces a real step
# failure LOUDLY (with the CLI's own output) and exits non-zero via the
# presence-verify, while a benign "already installed" re-run stays exit 0
# (idempotent). Stubs `claude` on PATH so nothing touches the real plugin state.
# (HIMMEL-438 — C2.)
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "PASS (skipped)"; exit 0; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/install-plugins.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Minimal template: one marketplace (autoUpdate:false so the script never patches
# a real settings.json) and one enabled plugin.
cat > "$TMP/template.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "github", "repo": "x/y" }, "autoUpdate": false }
  },
  "enabledPlugins": { "foo@mp": true }
}
JSON

# Stub `claude`: marketplace add → ok; plugin install → behavior from env;
# plugin list → whatever $STUB_PRESENT names (space-separated).
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ] && [ "$3" = "add" ]; then exit 0; fi
if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then
  if [ -n "${STUB_INSTALL_FAIL:-}" ]; then echo "error: failed to clone marketplace: network unreachable" >&2; exit 1; fi
  if [ -n "${STUB_INSTALL_BENIGN:-}" ]; then echo "Plugin already installed"; exit 1; fi
  exit 0
fi
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  for s in ${STUB_PRESENT:-}; do printf '  %s\n' "$s"; done
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

fail() { echo "FAIL: $1"; exit 1; }

# ── Case 1: real install failure → loud diagnostics + non-zero (verify misses foo)
set +e
out1=$(PATH="$STUB_DIR:$PATH" STUB_INSTALL_FAIL=1 STUB_PRESENT="" \
       bash "$SUT" --scope user --template "$TMP/template.json" 2>&1)
rc1=$?
set -e
[ "$rc1" -ne 0 ] || fail "real failure should exit non-zero (got $rc1)"
printf '%s' "$out1" | grep -q "step FAILED"            || fail "missing loud 'step FAILED' marker"
printf '%s' "$out1" | grep -q "network unreachable"    || fail "captured CLI error text not surfaced"

# ── Case 2: benign already-installed + present in list → quiet + exit 0
set +e
out2=$(PATH="$STUB_DIR:$PATH" STUB_INSTALL_BENIGN=1 STUB_PRESENT="foo@mp" \
       bash "$SUT" --scope user --template "$TMP/template.json" 2>&1)
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "benign already-installed re-run should exit 0 (got $rc2): $out2"
printf '%s' "$out2" | grep -q "already present"        || fail "benign path should print quiet 'already present'"
printf '%s' "$out2" | grep -q "step FAILED"            && fail "benign path must NOT print 'step FAILED'"

echo "PASS"
