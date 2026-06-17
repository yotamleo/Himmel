#!/usr/bin/env bash
# test-install-plugins-autoupdate.sh — hermetic test for the HIMMEL-365
# marketplace auto-update patch in scripts/machine-setup/install-plugins.sh.
#
# Stubs the `claude` CLI on PATH (marketplace add / install no-op; `plugin list`
# reports the enabled specs so the verify step passes), seeds a scope settings
# file as `marketplace add` would have written it, runs the REAL script
# (--scope local from a temp cwd), and asserts the patch:
#   1. flagged + registered marketplace → autoUpdate:true added
#   2. unflagged marketplace            → left untouched (no autoUpdate)
#   3. flagged but NOT registered       → skipped (no orphan entry created)
#   4. unrelated keys                   → preserved
#   5. re-run                           → idempotent (stays true, exit 0)
#
# install-plugins.ps1 carries the SAME patch as a PowerShell twin — covered by
# test-install-plugins-autoupdate.ps1; keep both in lockstep when changing either.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "PASS (skipped)"; exit 0; }

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# Stub `claude`: install/marketplace add are no-ops; `plugin list` prints the
# enabled specs so the post-install verify passes.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  printf '  %s\n' "good@flagged" "good@unflagged"
fi
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Template: flagged + unflagged + ghost marketplaces; enabledPlugins match the
# stub's `plugin list` so verify is satisfied.
TEMPLATE="$TMP/settings-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": { "good@flagged": true, "good@unflagged": true },
  "extraKnownMarketplaces": {
    "flagged":   { "source": { "source": "github", "repo": "a/flagged" }, "autoUpdate": true },
    "unflagged": { "source": { "source": "github", "repo": "a/unflagged" } },
    "ghost":     { "source": { "source": "github", "repo": "a/ghost" }, "autoUpdate": true }
  }
}
JSON

# Seed settings.local.json as `marketplace add` would: flagged + unflagged
# registered, ghost absent (exercises the existence guard).
WORK="$TMP/work"
mkdir -p "$WORK/.claude"
SF="$WORK/.claude/settings.local.json"
cat > "$SF" <<'JSON'
{
  "theme": "dark",
  "extraKnownMarketplaces": {
    "flagged":   { "source": { "source": "github", "repo": "a/flagged" } },
    "unflagged": { "source": { "source": "github", "repo": "a/unflagged" } }
  }
}
JSON

( cd "$WORK" && PATH="$STUB_DIR:$PATH" bash "$script" --scope local --template "$TEMPLATE" ) \
  >/dev/null 2>&1 || fail "first run exited non-zero"

[ "$(jq -r '.extraKnownMarketplaces.flagged.autoUpdate' "$SF")" = "true" ] \
  || fail "flagged marketplace not patched"
[ "$(jq -r '.extraKnownMarketplaces.unflagged.autoUpdate // "absent"' "$SF")" = "absent" ] \
  || fail "unflagged marketplace wrongly patched"
[ "$(jq -r '.extraKnownMarketplaces | has("ghost")' "$SF")" = "false" ] \
  || fail "ghost (unregistered) entry wrongly created"
[ "$(jq -r '.theme' "$SF")" = "dark" ] \
  || fail "unrelated keys not preserved"
[ "$(jq -r '.extraKnownMarketplaces.flagged.source.repo' "$SF")" = "a/flagged" ] \
  || fail "flagged.source sub-object not preserved through the patch"
[ "$FAILED" -eq 0 ] && echo "ok: flagged patched, unflagged + ghost skipped, keys + source preserved"

# Idempotent re-run: still true, exit 0.
( cd "$WORK" && PATH="$STUB_DIR:$PATH" bash "$script" --scope local --template "$TEMPLATE" ) \
  >/dev/null 2>&1 || fail "second run (idempotency) exited non-zero"
[ "$(jq -r '.extraKnownMarketplaces.flagged.autoUpdate' "$SF")" = "true" ] \
  || fail "idempotent re-run lost autoUpdate"
[ "$FAILED" -eq 0 ] && echo "ok: idempotent re-run"

# Guard: an existing but invalid-JSON settings file → skipped, left byte-identical
# (this is the branch that protects a hand-edited settings.json from a clobber).
BAD='{ this is not valid json'
printf '%s' "$BAD" > "$SF"
( cd "$WORK" && PATH="$STUB_DIR:$PATH" bash "$script" --scope local --template "$TEMPLATE" ) \
  >/dev/null 2>&1 || fail "invalid-JSON run exited non-zero"
[ "$(cat "$SF")" = "$BAD" ] || fail "invalid-JSON settings file was modified"
[ "$FAILED" -eq 0 ] && echo "ok: invalid-JSON settings left untouched"

# Guard: no settings file present → skipped cleanly, file not created.
rm -f "$SF"
( cd "$WORK" && PATH="$STUB_DIR:$PATH" bash "$script" --scope local --template "$TEMPLATE" ) \
  >/dev/null 2>&1 || fail "missing-file run exited non-zero"
[ ! -f "$SF" ] || fail "missing settings file was created"
[ "$FAILED" -eq 0 ] && echo "ok: missing settings file stays absent"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
