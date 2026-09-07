#!/usr/bin/env bash
# test-uninstall-plugins-scope.sh — Platform guard: POSIX-only bash test (no
# .ps1 twin; mirrors test-install-plugins-verify.sh, which also ships
# POSIX-only) for the HIMMEL-2694 --scope fix in
# scripts/machine-setup/uninstall-plugins.sh.
#
# HIMMEL-2694: a project/local-scope plugin install could never be
# uninstalled — uninstall-plugins.sh never passed --scope to `claude plugin
# uninstall`/`marketplace remove`, so every call ran at the CLI's default
# scope and every plugin refused removal ("Plugin ... is enabled at project
# scope ..."). Also covers the sibling defect: uninstall-plugins.sh used to
# attempt EVERY settings-template.json key regardless of its true/false
# flag, so a lean install (13 true-flagged entries) produced 18 spurious
# "not found" failures for the false-flagged entries it never installed.
#
# Stubs `claude` on PATH to RECORD its argv (never a real plugin
# uninstall) and drives the real script (no --dry-run — dry-run never
# invokes the stub, and the whole point here is to inspect the recorded
# argv) against a temp template with a marketplace + 2 true-flagged +
# 1 false-flagged plugin. Covers:
#   1. default (no --scope)  -> every claude call carries --scope user
#   2. --scope project       -> every claude call carries --scope project
#   3. --scope bogus         -> exit 2, validation runs before preflight
#   4. false-flagged entry   -> never uninstalled (mirrors install's own
#      select(.value == true) filter)
#   5. RED control: the SAME drive against a FROZEN inline reproduction of
#      the pre-HIMMEL-2694 call shape (a heredoc stub written by this test,
#      NOT `git show HEAD:...`) proves it (a) still uninstalls the
#      true-flagged plugins, (b) also attempts the false-flagged one (the
#      31-vs-13 noise), and (c) never passes --scope at all. A git-history
#      read of uninstall-plugins.sh cannot serve as this control: the
#      instant this branch's fix is committed, `HEAD:...` IS the fixed
#      script, and the "never passes --scope" assertion would flip to a
#      false pass forever after — the control must outlive its own fix.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/uninstall-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-uninstall-plugins-scope.XXXXXX") || { echo "FAIL: mktemp -d failed — cannot create the scratch dir this suite needs" >&2; exit 1; }
[ -n "$TMP" ] || { echo "FAIL: mktemp -d produced an empty path" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Stub `claude`: every subcommand is a no-op that records its full argv (one
# line per call) to $ARGV_LOG, so the test can assert on exactly what was
# passed without ever touching a real plugin.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
ARGV_LOG="$TMP/argv.log"
: > "$ARGV_LOG"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$ARGV_LOG"
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Template: one marketplace, two true-flagged plugins, one false-flagged
# plugin (the HIMMEL-816 lean-profile shape — install-plugins.sh never
# installs it, so uninstall must never attempt it either).
TEMPLATE="$TMP/settings-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {
    "good-a@mp": true,
    "good-b@mp": true,
    "lean-off@mp": false
  },
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "url", "url": "https://example.invalid/mp.json" } }
  }
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
        *) echo "FAIL $label — output/log missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — unexpectedly present: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

# ── 1. default scope (no --scope) -> every call carries --scope user ────────
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "default scope exits 0" 0 "$rc"
assert_has "default: uninstall good-a carries --scope user" "plugin uninstall good-a@mp --scope user" "$log"
assert_has "default: uninstall good-b carries --scope user" "plugin uninstall good-b@mp --scope user" "$log"
assert_has "default: marketplace remove carries --scope user" "plugin marketplace remove mp --scope user" "$log"
assert_not_has "default: false-flagged plugin never uninstalled" "lean-off@mp" "$log"

# ── 2. --scope project -> every call carries --scope project ────────────────
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      bash "$script" --template "$TEMPLATE" --scope project 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "project scope exits 0" 0 "$rc"
assert_has "project: uninstall good-a carries --scope project" "plugin uninstall good-a@mp --scope project" "$log"
assert_has "project: uninstall good-b carries --scope project" "plugin uninstall good-b@mp --scope project" "$log"
assert_has "project: marketplace remove carries --scope project" "plugin marketplace remove mp --scope project" "$log"
assert_not_has "project: no call falls back to user scope" "--scope user" "$log"
assert_not_has "project: false-flagged plugin never uninstalled" "lean-off@mp" "$log"

# ── 3. invalid --scope -> exit 2, validation before preflight ───────────────
out=$(PATH="$STUB_DIR:$PATH" bash "$script" --template "$TEMPLATE" --scope bogus 2>&1); rc=$?
assert_rc "invalid scope exits 2" 2 "$rc"
assert_has "invalid scope names the diagnostic" "invalid --scope: bogus" "$out"

# ── 5. RED control: a FROZEN reproduction of the pre-HIMMEL-2694 call shape ──
# This is a frozen reproduction written by this test, NOT the historical
# file (no `git show HEAD:...`). A git-history read would only be correct
# until the parent commits this branch's fix — at that point
# `HEAD:scripts/machine-setup/uninstall-plugins.sh` IS the fixed script, so
# a "never passes --scope" assertion sourced from HEAD would silently flip
# to a false pass forever after, on every run, in CI and on every adopter
# clone. Freezing the pre-fix SHAPE inline instead — unfiltered
# `.enabledPlugins | keys[]` (every template key, true- and false-flagged
# alike) and bare `claude plugin uninstall "$SPEC"` /
# `claude plugin marketplace remove "$NAME"` calls with no --scope — means
# this control keeps proving the OLD bug regardless of what HEAD contains.
PRE_FIX="$TMP/pre-2694-uninstall-plugins.sh"
cat > "$PRE_FIX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
PLUGIN_SPECS="$(jq -r '.enabledPlugins | keys[]' "$TEMPLATE")"
MARKETPLACES="$(jq -r '.extraKnownMarketplaces | keys[]' "$TEMPLATE")"
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  claude plugin uninstall "$SPEC" || true
done <<EOF
$PLUGIN_SPECS
EOF
while IFS= read -r NAME; do
  [[ -z "$NAME" ]] && continue
  claude plugin marketplace remove "$NAME" || true
done <<EOF
$MARKETPLACES
EOF
SH
chmod +x "$PRE_FIX"

: > "$ARGV_LOG"
PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
    bash "$PRE_FIX" --template "$TEMPLATE" >/dev/null 2>&1
prelog=$(cat "$ARGV_LOG")
assert_has "RED: pre-2694 shape still uninstalls the true-flagged plugins" "plugin uninstall good-a@mp" "$prelog"
assert_has "RED: pre-2694 shape ALSO attempts the false-flagged plugin (31-vs-13 noise)" "plugin uninstall lean-off@mp" "$prelog"
assert_not_has "RED: pre-2694 shape NEVER passes --scope to any claude call" "--scope" "$prelog"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
