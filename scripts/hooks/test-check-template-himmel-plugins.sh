#!/usr/bin/env bash
# Smoke test for check-template-himmel-plugins.sh. Drives the guard with
# fixture marketplace.json + settings-template.json via its env-override seams.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/check-template-himmel-plugins.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A locally-vendored plugin (handover, obsidian-triage) plus an externally
# sourced one (claude-obsidian, object source) that must be EXEMPT.
cat > "$tmp/market.json" <<'JSON'
{"name":"himmel","plugins":[
  {"name":"handover","source":"./plugins/handover"},
  {"name":"obsidian-triage","source":"./plugins/obsidian-triage"},
  {"name":"claude-obsidian","source":{"source":"github","repo":"x/y"}}
]}
JSON

run_guard() { HIMMEL_MARKETPLACE_JSON="$tmp/market.json" HIMMEL_SETTINGS_TEMPLATE="$1" bash "$GUARD"; }

# Case 1: template missing obsidian-triage@himmel → expect FAIL (exit 1).
printf '{"enabledPlugins":{"handover@himmel":true}}' > "$tmp/tmpl.json"
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite missing obsidian-triage@himmel"; exit 1
fi
echo "ok: drift detected"

# Case 2: all locally-vendored present, claude-obsidian exempt → expect PASS.
printf '{"enabledPlugins":{"handover@himmel":true,"obsidian-triage@himmel":true},"extraKnownMarketplaces":{"himmel":{"source":{"source":"directory","path":"x"}}}}' > "$tmp/tmpl.json"
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a complete template"; exit 1
fi
echo "ok: complete template passes"

# Case 3: missing input file → fail-OPEN skip (exit 0). Pins the deliberate
# skip contract: the always_run hook must not start blocking commits in a
# partial checkout where an input is absent.
if ! run_guard "$tmp/does-not-exist.json" >/dev/null 2>&1; then
  echo "FAIL: guard did not skip (exit 0) on a missing template file"; exit 1
fi
echo "ok: missing input skips"

# Case 4 (HIMMEL-2691): an enabledPlugins marketplace suffix with no matching
# extraKnownMarketplaces entry → expect FAIL. Mirrors the real bug: three
# marketplaces enabled (himmel, obsidian-skills, claude-plugins-official) but
# only two declared.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "handover@himmel": true,
    "obsidian-triage@himmel": true,
    "superpowers@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "x"}},
    "obsidian-skills": {"source": {"source": "github", "repo": "kepano/obsidian-skills"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite claude-plugins-official missing from extraKnownMarketplaces"; exit 1
fi
echo "ok: unregistered marketplace detected"

# Case 5: same shape but every enabled marketplace suffix is registered →
# expect PASS (negative control for case 4).
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "handover@himmel": true,
    "obsidian-triage@himmel": true,
    "superpowers@claude-plugins-official": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "x"}},
    "obsidian-skills": {"source": {"source": "github", "repo": "kepano/obsidian-skills"}},
    "claude-plugins-official": {"source": {"source": "github", "repo": "anthropics/claude-plugins-official"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed despite every enabledPlugins marketplace being registered"; exit 1
fi
echo "ok: fully-registered template passes"

# Case 6 (fail-open lint finding): an EXISTING but unreadable template must
# fail CLOSED (exit 1), not silently read as empty and pass. Skipped when
# running as root (uid 0 ignores file-mode read permission, so chmod 000
# would not reproduce "unreadable" there).
if [ "$(id -u)" -eq 0 ]; then
  echo "skip: unreadable-template case (running as root, chmod is not enforced)"
else
  printf '{"enabledPlugins":{"handover@himmel":true,"obsidian-triage@himmel":true},"extraKnownMarketplaces":{"himmel":{"source":{"source":"directory","path":"x"}}}}' > "$tmp/unreadable.json"
  chmod 000 "$tmp/unreadable.json"
  if run_guard "$tmp/unreadable.json" >/dev/null 2>&1; then
    chmod 644 "$tmp/unreadable.json"
    echo "FAIL: guard passed (exit 0) on an unreadable template — must fail closed"; exit 1
  fi
  chmod 644 "$tmp/unreadable.json"
  echo "ok: unreadable template fails closed"
fi

echo "PASS: check-template-himmel-plugins smoke test"
