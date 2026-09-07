#!/usr/bin/env bash
# test-himmel-ops-plugin-enablement.sh — regression guard for HIMMEL-2292.
#
# himmel-ops (marketplace/plugins/himmel-ops/hooks/hooks.json) delivers
# block-glm-external-writes.sh — but delivery isn't enablement: a plugin can
# be fully wired and still sit at "himmel-ops@himmel": false in a machine's
# live ~/.claude/settings.json (existence != enablement), leaving the guard
# silently inert. HIMMEL-2292 closes that structurally:
#   1. scripts/install/manifest.json carries a dedicated "himmel-ops-plugin"
#      item whose probe checks the LIVE enabled VALUE (not mere key
#      presence) via the new settings-key 'expect' field.
#   2. docs/setup/settings-template.json (the HIMMEL-1032 reconciler's own
#      whitelist/floor) flags himmel-ops@himmel true.
#   3. install-plugins.sh's new force-enable step (always-on, additive-only)
#      is what `himmelctl ensure`/`install` actually runs for that item —
#      it flips a drifted false back to true.
#
# Cases a/b/c are the static regression guard this ticket's DoD asks for:
# strip the manifest item or the template entry and these go red — proving
# the FAIL side red-before-green (see the ticket's own worker report for the
# manual proof; not repeated here as a self-referential in-test toggle).
# Case d proves the probe itself distinguishes false from true (not just
# presence). Case e proves the installer mechanism this probe is meant to
# trigger actually repairs a drifted machine end-to-end.
set -euo pipefail

# grepq <text> [grep-args...] — see test-wizard-manifest-v2.sh's own header
# for why this avoids `printf | grep -q` under `set -o pipefail`.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
manifest_path="$repo_root/scripts/install/manifest.json"
lint="$repo_root/scripts/install/manifest-lint.mjs"
template_path="$repo_root/docs/setup/settings-template.json"
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
install_plugins_sh="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
[ -f "$template_path" ] || { echo "FAIL: $template_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# winpath <path> — see test-wizard-manifest-v2.sh's own header.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── case a: the real manifest.json still lints clean under manifest-lint ───
outA=$(MANIFEST_PATH="$(winpath "$manifest_path")" "$node_bin" "$(winpath "$lint")" 2>&1) \
  || fail "case a: manifest.json should lint clean (got): $outA"
echo "ok: case a — manifest.json lints clean"

# ── case b: manifest.json carries an item checking himmel-ops@himmel's LIVE
# value (not just presence), dispatched to the 'plugins' installer ─────────
himmelOpsItem=$(jq -c '[.items[] | select(.probe.type == "settings-key" and .probe.key == "enabledPlugins.himmel-ops@himmel")] | .[0] // empty' "$manifest_path")
[ -n "$himmelOpsItem" ] || fail "case b: manifest.json has no item probing enabledPlugins.himmel-ops@himmel — himmel-ops is not enforced by the installer (HIMMEL-2292 regression)"
[ "$(echo "$himmelOpsItem" | jq -r '.probe.expect')" = "true" ] \
  || fail "case b: the himmel-ops probe must assert expect:true (a presence-only probe can't catch a false value), got: $himmelOpsItem"
[ "$(echo "$himmelOpsItem" | jq -r '.install.type')" = "plugins" ] \
  || fail "case b: the himmel-ops item's install.type must be 'plugins' (the dispatch that runs install-plugins.sh's force-enable step), got: $himmelOpsItem"
echo "ok: case b — manifest.json has a himmel-ops item probing its live enabled value with install.type:plugins"

# ── case c: settings-template.json (the HIMMEL-1032 reconciler's own
# whitelist/floor) flags himmel-ops@himmel true ────────────────────────────
[ "$(jq -r '.enabledPlugins["himmel-ops@himmel"] // "absent"' "$template_path")" = "true" ] \
  || fail "case c: docs/setup/settings-template.json must flag \"himmel-ops@himmel\": true (the reconciler whitelist) — HIMMEL-2292 regression"
echo "ok: case c — settings-template.json (reconciler whitelist) flags himmel-ops@himmel true"

# ── case d: probeSettingsKey's 'expect' actually distinguishes false from
# true (not merely key presence) — runs the REAL probe function ───────────
outD=$("$node_bin" -e "
const { runProbe } = require(process.argv[1]);
const fs = require('fs');
const path = require('path');
// case-d dir lives under \$work (the outer script's own mktemp -d), which
// the EXIT trap already removes — no separate temp dir to leak/clean here.
const dir = path.join(process.argv[2], 'probe-d');
fs.mkdirSync(path.join(dir, '.claude'), { recursive: true });
const settingsFile = path.join(dir, '.claude', 'settings.json');
const item = { probe: { type: 'settings-key', file: '.claude/settings.json', key: 'enabledPlugins.himmel-ops@himmel', expect: true } };
const ctx = { repoRoot: dir, targetPath: dir, scope: 'project', env: { HOME: dir } };
fs.writeFileSync(settingsFile, JSON.stringify({ enabledPlugins: { 'himmel-ops@himmel': false } }));
const off = runProbe(item, ctx);
fs.writeFileSync(settingsFile, JSON.stringify({ enabledPlugins: { 'himmel-ops@himmel': true } }));
const on = runProbe(item, ctx);
console.log(JSON.stringify({ off, on }));
" "$(winpath "$probes_lib")" "$(winpath "$work")")
[ "$(echo "$outD" | jq -r '.off.actual')" = "absent" ] \
  || fail "case d: enabledPlugins.himmel-ops@himmel:false must probe 'absent' (existence != enablement), got: $outD"
[ "$(echo "$outD" | jq -r '.on.actual')" = "present" ] \
  || fail "case d: enabledPlugins.himmel-ops@himmel:true must probe 'present', got: $outD"
echo "ok: case d — probeSettingsKey's 'expect' distinguishes false (absent) from true (present)"

# ── case e: install-plugins.sh's force-enable step actually repairs a
# drifted machine end-to-end — the mechanism the manifest item's
# install.type:plugins dispatch triggers ───────────────────────────────────
STUB_DIR="$work/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
  echo "himmel-ops@himmel"
  echo "some-other@mp"
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

TARGET="$work/target"
mkdir -p "$TARGET/.claude"
cat > "$TARGET/.claude/settings.json" <<'JSON'
{ "theme": "dark", "enabledPlugins": { "himmel-ops@himmel": false, "some-other@mp": true } }
JSON
TEMPLATE_E="$work/template.json"
cat > "$TEMPLATE_E" <<'JSON'
{ "extraKnownMarketplaces": {}, "enabledPlugins": { "himmel-ops@himmel": true, "some-other@mp": true } }
JSON

outE=$(PATH="$STUB_DIR:$PATH" bash "$install_plugins_sh" \
  --scope project --template "$TEMPLATE_E" --settings "$TARGET/.claude/settings.json" 2>&1) \
  || fail "case e: install-plugins.sh should exit 0 against a drifted-but-installed himmel-ops (got): $outE"
[ "$(jq -r '.enabledPlugins["himmel-ops@himmel"]' "$TARGET/.claude/settings.json")" = "true" ] \
  || fail "case e: install-plugins.sh's force-enable step should have flipped himmel-ops@himmel back to true (got): $(cat "$TARGET/.claude/settings.json")"
[ "$(jq -r '.theme' "$TARGET/.claude/settings.json")" = "dark" ] \
  || fail "case e: unrelated settings.json keys must be preserved through the force-enable patch"
echo "ok: case e — install-plugins.sh's force-enable step repairs a drifted himmel-ops@himmel:false back to true, additive-only"

echo "PASS"
