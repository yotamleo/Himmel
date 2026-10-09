#!/usr/bin/env bash
# test-install-plugins-drift.sh — a marketplace whose source in the scope's
# extraKnownMarketplaces differs from the template's is DRIFT, not an install
# failure: install-plugins.sh reports both sources + a reconcile command and
# exits 0 instead of aborting with "marketplace registration failed". A genuine
# add failure still exits 1. Stubs `claude` on PATH. (HIMMEL-4270.)
# SUT=<path> overrides the script under test (used to show the RED run).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$SCRIPT_DIR/install-plugins.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-plugins-drift.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_PROVENANCE_DIR="$TMP/provenance"
export CLAUDE_CONFIG_DIR="$TMP/cfg"
mkdir -p "$CLAUDE_CONFIG_DIR"

fail() { echo "FAIL: $1"; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
# HIMMEL-4279: a negated grep reads a grep error (rc 2) as "no match"; only
# rc 1 is a genuine no-match.
nogrep() { local _rc=0; grep -q "$@" || _rc=$?; [ "$_rc" -eq 1 ]; }

# The station case: obsidian-skills / openai-codex registered under another source.
cat > "$TMP/template.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "obsidian-skills": { "source": { "source": "url", "url": "https://github.com/kepano/obsidian-skills.git" } },
    "openai-codex": { "source": { "source": "url", "url": "https://github.com/openai/codex-plugin-cc.git" } },
    "himmel": { "source": { "source": "directory", "path": "<himmel-path>/marketplace" } }
  },
  "enabledPlugins": {}
}
JSON
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "obsidian-skills": { "source": { "source": "github", "repo": "kepano/obsidian-skills" } },
    "openai-codex": { "source": { "source": "github", "repo": "openai/codex-plugin-cc" } },
    "himmel": { "source": { "source": "directory", "path": "/old/checkout/marketplace" } }
  }
}
JSON

# Stub `claude` behaves like the real CLI: add fails when the name is already
# registered under a different source (here: any add for the three names).
STUB_DIR="$TMP/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "$1 $2 $3" = "plugin marketplace add" ]; then
  if [ -n "${STUB_NET_FAIL:-}" ]; then echo "network unreachable" >&2; exit 7; fi
  echo "Error: marketplace source mismatch with extraKnownMarketplaces" >&2; exit 1
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"
export STUB_LOG="$TMP/claude.log"; : > "$STUB_LOG"

rc=0
out=$(PATH="$STUB_DIR:$PATH" bash "$SUT" --scope user --template "$TMP/template.json" --himmel-path '/new checkout' 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "source mismatch must not abort the adopt (rc=$rc): $out"
grepq "$out" "DRIFT: marketplace 'obsidian-skills'" || fail "no drift line for obsidian-skills: $out"
grepq "$out" "DRIFT: marketplace 'openai-codex'" || fail "no drift line for openai-codex: $out"
grepq "$out" "settings has 'kepano/obsidian-skills', template wants 'https://github.com/kepano/obsidian-skills.git'" || fail "drift line must name both sources: $out"
grepq "$out" "claude plugin marketplace remove obsidian-skills --scope user" || fail "no reconcile command: $out"
grepq "$out" -F 'marketplace add /new\ checkout/marketplace --scope user' || fail "reconcile command must shell-quote a path with a space: $out"
grepq "$out" "keeping the settings source" || fail "third-party must recommend the settings side: $out"
grepq "$out" "himmel's own manifest is right" || fail "himmel-owned marketplace must say the manifest wins: $out"
nogrep "marketplace registration failed" <<< "$out" || fail "still reports a registration failure: $out"
[ -f "$STUB_LOG" ] || fail "stub log missing: the no-add check would be vacuous"
nogrep "marketplace add" "$STUB_LOG" || fail "must not call marketplace add for a drifted entry"
echo "ok: source mismatch reports DRIFT with both sources + remedy and exits 0"

# HIMMEL-4279: the same string under a different source type is still drift.
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "obsidian-skills": { "source": { "source": "directory", "path": "kepano/obsidian-skills" } } } }
JSON
cat > "$TMP/template2.json" <<'JSON'
{ "extraKnownMarketplaces": { "obsidian-skills": { "source": { "source": "github", "repo": "kepano/obsidian-skills" } } }, "enabledPlugins": {} }
JSON
: > "$STUB_LOG"
rc=0
out=$(PATH="$STUB_DIR:$PATH" bash "$SUT" --scope user --template "$TMP/template2.json" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "a source-type mismatch must not abort the adopt (rc=$rc): $out"
grepq "$out" "DRIFT: marketplace 'obsidian-skills'" || fail "same string, different source type must read as drift: $out"
nogrep "marketplace add" "$STUB_LOG" || fail "must not call marketplace add for a type-drifted entry"
echo "ok: same source string under a different source type reports DRIFT"

# A matching entry still goes through `marketplace add` (idempotent path).
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "obsidian-skills": { "source": { "source": "url", "url": "https://github.com/kepano/obsidian-skills.git" } } } }
JSON
cat > "$TMP/template1.json" <<'JSON'
{ "extraKnownMarketplaces": { "obsidian-skills": { "source": { "source": "url", "url": "https://github.com/kepano/obsidian-skills.git" } } }, "enabledPlugins": {} }
JSON
: > "$STUB_LOG"
rc=0
out=$(PATH="$STUB_DIR:$PATH" STUB_NET_FAIL=1 bash "$SUT" --scope user --template "$TMP/template1.json" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "a genuine add failure on a matching source must still exit 1 (rc=$rc): $out"
grepq "$out" "marketplace registration failed" || fail "genuine failure must still be reported: $out"
echo "ok: genuine add failure (matching source) still exits 1"

echo "$(basename "$0"): PASS"
