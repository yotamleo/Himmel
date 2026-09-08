#!/usr/bin/env bash
# Hermetic marketplace-source guard (HIMMEL-2837): every plugin id in
# docs/setup/settings-template.json's enabledPlugins, except the
# claude-plugins-official marketplace (Anthropic's own, exempt), must
# resolve to a marketplace whose extraKnownMarketplaces source is "url"
# (explicit HTTPS git clone) or "directory" (a local vendored path — e.g.
# himmel's own marketplace) — never "github" (owner/repo shorthand, which
# clones over SSH and fails host-key verification on a fresh guest with no
# github.com in ~/.ssh/known_hosts and no SSH key: HIMMEL-549, HIMMEL-2836).
# This is exactly the class of regression HIMMEL-2733 introduced by adding
# plannotator-effective-html@effective-html — a github-shorthand marketplace
# source — to the ALWAYS-installed tier. HIMMEL-2837 fixed that instance by
# vendoring the plugin as plannotator-effective-html@himmel, a url-sourced
# per-plugin pin inside the himmel marketplace; this guard stops the class
# from recurring for any future plugin.
#
# Fail-closed on detected drift; skips (exit 0) only when jq is unavailable
# or the template is MISSING (fresh clone / CI without it — a legitimate
# skip). An input that EXISTS but is unreadable is not a skip: it would
# otherwise read as empty and report a false PASS, so that case fails closed
# (exit 1) with a named diagnostic. Input path is env-overridable for testing.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure jq + POSIX shell; no .ps1 twin needed.
set -euo pipefail

TEMPLATE_JSON="${HIMMEL_SETTINGS_TEMPLATE:-docs/setup/settings-template.json}"

command -v jq >/dev/null 2>&1 || { echo "marketplace-source-hermetic: jq not on PATH — skipping"; exit 0; }

[ -f "$TEMPLATE_JSON" ] || { echo "marketplace-source-hermetic: $TEMPLATE_JSON missing — skipping"; exit 0; }
if [ ! -r "$TEMPLATE_JSON" ]; then
  echo "ERR marketplace-source-hermetic: $TEMPLATE_JSON exists but is unreadable — refusing to skip (fail-closed)." >&2
  exit 1
fi

bad=""

specs="$(jq -r '.enabledPlugins // {} | keys[]' "$TEMPLATE_JSON" | tr -d '\r')"
while IFS= read -r spec; do
  [ -z "$spec" ] && continue
  market="${spec##*@}"
  [ "$market" = "claude-plugins-official" ] && continue
  src_type="$(jq -r --arg m "$market" '(.extraKnownMarketplaces[$m].source.source // "MISSING")' "$TEMPLATE_JSON" | tr -d '\r')"
  case "$src_type" in
    directory) ;;
    url)
      src_url="$(jq -r --arg m "$market" '(.extraKnownMarketplaces[$m].source.url // "MISSING")' "$TEMPLATE_JSON" | tr -d '\r')"
      case "$src_url" in
        https://*) ;;
        *)
          bad="$bad  $spec (marketplace \"$market\" source: url, but url is not HTTPS: $src_url)
"
          ;;
      esac
      ;;
    *)
      bad="$bad  $spec (marketplace \"$market\" source: $src_type)
"
      ;;
  esac
done <<EOF
$specs
EOF

if [ -n "$bad" ]; then
  echo "ERR marketplace-source-hermetic: enabledPlugins entries whose marketplace does not resolve to a url/directory source:" >&2
  printf '%s' "$bad" >&2
  echo "    A \"github\" (owner/repo shorthand) source clones over SSH and fails host-key" >&2
  echo "    verification on a fresh guest with no known_hosts entry and no SSH key (HIMMEL-549," >&2
  echo "    HIMMEL-2836). Use an explicit HTTPS url source (see claude-obsidian / himmel's own" >&2
  echo "    marketplace in marketplace/.claude-plugin/marketplace.json), or a local directory source." >&2
  exit 1
fi

echo "marketplace-source-hermetic: all enabledPlugins entries resolve to a url or directory marketplace source"
