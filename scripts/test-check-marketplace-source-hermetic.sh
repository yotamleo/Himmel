#!/usr/bin/env bash
# Smoke test for check-marketplace-source-hermetic.sh. Drives the guard with
# fixture settings-template.json files via its env-override seam.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure jq + POSIX shell; no .ps1 twin needed.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/check-marketplace-source-hermetic.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-marketplace-source-hermetic-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

run_guard() { HIMMEL_SETTINGS_TEMPLATE="$1" bash "$GUARD"; }

# Case 1 (RED — the exact HIMMEL-2733 regression shape): a plugin enabled
# under a marketplace whose extraKnownMarketplaces source is "github"
# (owner/repo shorthand, SSH clone) must FAIL.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "plannotator-effective-html@effective-html": true
  },
  "extraKnownMarketplaces": {
    "effective-html": {"source": {"source": "github", "repo": "plannotator/effective-html"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a github-shorthand marketplace source"; exit 1
fi
echo "ok: github-shorthand source detected (RED, HIMMEL-2733 regression shape)"

# Case 2 (GREEN — the HIMMEL-2837 fix shape): the same plugin re-homed under
# a marketplace whose source is a local "directory" (himmel's own
# marketplace, which vendors the plugin with its own per-plugin url+sha
# source) must PASS.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "/x/himmel/marketplace"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a directory-sourced marketplace"; exit 1
fi
echo "ok: directory-sourced marketplace passes"

# Case 3: an explicit HTTPS "url" source (e.g. claude-obsidian's own
# marketplace shape) must also PASS.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "claude-obsidian@claude-obsidian-fork": true
  },
  "extraKnownMarketplaces": {
    "claude-obsidian-fork": {"source": {"source": "url", "url": "https://github.com/yotamleo/claude-obsidian.git"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a url-sourced marketplace"; exit 1
fi
echo "ok: url-sourced marketplace passes"

# Case 3b (RED — codex-adv finding, pr-check round 1): a "url"-typed source
# whose url is NOT https:// (e.g. ssh:// or a bare git@ scp-style remote)
# still requires the exact SSH host-key setup this guard exists to catch —
# typing alone is not enough, the scheme itself must be checked.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "claude-obsidian@claude-obsidian-fork": true
  },
  "extraKnownMarketplaces": {
    "claude-obsidian-fork": {"source": {"source": "url", "url": "ssh://git@github.com/yotamleo/claude-obsidian.git"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a non-HTTPS url source"; exit 1
fi
echo "ok: non-HTTPS url source detected"

# Case 4: claude-plugins-official is exempt even though this fixture gives
# it no extraKnownMarketplaces entry at all (real state: Anthropic's own
# marketplace, source type irrelevant to this guard).
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on claude-plugins-official, which must be exempt"; exit 1
fi
echo "ok: claude-plugins-official exempt"

# Case 5: a marketplace suffix with NO extraKnownMarketplaces entry at all
# (unregistered) cannot resolve to url/directory either -> FAIL.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "some-plugin@unregistered": true
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite an unregistered marketplace"; exit 1
fi
echo "ok: unregistered marketplace detected"

# Case 6: missing input file -> fail-OPEN skip (exit 0), matching the
# always_run convention (a partial checkout must not start blocking).
if ! run_guard "$tmp/does-not-exist.json" >/dev/null 2>&1; then
  echo "FAIL: guard did not skip (exit 0) on a missing template file"; exit 1
fi
echo "ok: missing input skips"

echo "ALL PASS"
