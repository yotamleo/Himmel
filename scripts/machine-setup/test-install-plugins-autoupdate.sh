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
#   6. HIMMEL-2324: link pre-planted at the OLD predictable temp path
#      ("$SF.autoupdate.tmp") → not written through; patch still lands.
#
# install-plugins.ps1 carries the SAME patch as a PowerShell twin — covered by
# test-install-plugins-autoupdate.ps1; keep both in lockstep when changing either.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/install-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# plant_attack_link <path-to-plant> <target-file> — simulates an attacker with
# write access to the settings dir pre-planting something at a PREDICTABLE
# temp path before the script runs (HIMMEL-2324). Prefers a real symlink (it
# proves both attack vectors: content written through it, AND `mv` replacing
# the destination with the symlink itself) but falls back to a hardlink (still
# proves the write-through vector) when a symlink can't be created — this
# Windows sandbox has no Developer Mode/admin, so `ln -s` here silently copies
# instead of linking (`[ -L ]` catches that) and `New-Item -ItemType
# SymbolicLink` refuses with "Administrator privilege required".
# file_id <path> — portable inode identity (GNU `stat -c`, falling back to
# BSD/macOS `stat -f`; CodeRabbit round 4, test-install-plugins-autoupdate.sh
# was one of two sites CodeRabbit named — the GNU-only form was reached only
# on the hardlink fallback, but the caller HARD-FAILS when it can't verify a
# link, so a BSD host reaching this path would abort loudly rather than lose
# coverage silently — still worth making portable). Empty output (both
# variants fail) preserves the existing empty-result-still-aborts fallback.
file_id() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || true
}
plant_attack_link() {
  local link="$1" target="$2" li ti
  rm -f "$link"
  if ln -s "$target" "$link" 2>/dev/null && [ -L "$link" ]; then return 0; fi
  rm -f "$link"
  if command -v cygpath >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 cmd.exe /c mklink /H "$(cygpath -w "$link")" "$(cygpath -w "$target")" >/dev/null 2>&1 || true
    li="$(file_id "$link")"; ti="$(file_id "$target")"
    if [ -n "$li" ] && [ "$li" = "$ti" ]; then return 0; fi
    rm -f "$link"
  fi
  ln "$target" "$link" 2>/dev/null || true
  li="$(file_id "$link")"; ti="$(file_id "$target")"
  if [ -n "$li" ] && [ "$li" = "$ti" ]; then return 0; fi
  # CR round 2 (codex-1): a security test that cannot tell "attack blocked"
  # from "attack never attempted" is worse than no test. Hard-fail here — the
  # chokepoint every caller routes through — instead of returning quietly: if
  # none of the three methods actually planted a link (verified as a real
  # symlink, or the same inode as the target for a hardlink), no caller can
  # proceed unplanted, regardless of whether it checks this function's status.
  echo "FATAL: plant_attack_link: could not plant an attack link at '$link' -- cannot exercise the HIMMEL-2324 case in this environment" >&2
  exit 1
}

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

# HIMMEL-2324: a link pre-planted at the OLD predictable temp path
# ("$SF.autoupdate.tmp") must not be written through, and the intended
# autoUpdate patch must still land via the (now-unpredictable) mktemp path.
cat > "$SF" <<'JSON'
{
  "extraKnownMarketplaces": {
    "flagged":   { "source": { "source": "github", "repo": "a/flagged" } },
    "unflagged": { "source": { "source": "github", "repo": "a/unflagged" } }
  }
}
JSON
CANARY="$TMP/canary.txt"
printf 'CANARY-UNCHANGED\n' > "$CANARY"
plant_attack_link "$SF.autoupdate.tmp" "$CANARY"
( cd "$WORK" && PATH="$STUB_DIR:$PATH" bash "$script" --scope local --template "$TEMPLATE" ) \
  >/dev/null 2>&1 || fail "HIMMEL-2324 run exited non-zero"
[ "$(cat "$CANARY")" = "CANARY-UNCHANGED" ] || fail "HIMMEL-2324: write landed through the predictable temp path onto the canary file"
[ -f "$SF" ] || fail "HIMMEL-2324: settings file missing after patch"
[ ! -L "$SF" ] || fail "HIMMEL-2324: settings file ended up as a symlink"
[ "$(jq -r '.extraKnownMarketplaces.flagged.autoUpdate' "$SF")" = "true" ] \
  || fail "HIMMEL-2324: intended autoUpdate patch did not land"
[ "$FAILED" -eq 0 ] && echo "ok: HIMMEL-2324 — pre-planted link at the predictable temp path is not written through"

# HIMMEL-2324 (CR round 6, codex-4): exclusivity primitive, not just naming.
# The case above proves the temp NAME is unpredictable — it does NOT prove
# the CREATE is exclusive. It would still pass even if the real
# implementation regressed to a non-exclusive create at the (still random)
# path, because the pre-plant above targets the OLD fixed name, which the
# fixed code never touches either way. Test the primitive directly instead:
# mktemp "<template>" — the exact call shape install-plugins.sh and
# reconcile-enabled-plugins.sh use — must never return/reuse an
# already-existing path. Two calls against the identical template prove it:
# each must create its OWN distinct file, or the second collided with (and
# silently reused) the first.
EXCL_DIR="$TMP/exclusivity"
mkdir -p "$EXCL_DIR"
EXCL_FIRST="$(mktemp "$EXCL_DIR/settings.json.autoupdate.XXXXXX")" || fail "exclusivity: first mktemp call failed"
EXCL_SECOND="$(mktemp "$EXCL_DIR/settings.json.autoupdate.XXXXXX")" || fail "exclusivity: second mktemp call failed"
[ "$EXCL_FIRST" != "$EXCL_SECOND" ] || fail "exclusivity: mktemp returned the SAME path twice — not exclusive"
if [ ! -f "$EXCL_FIRST" ] || [ ! -f "$EXCL_SECOND" ]; then
  fail "exclusivity: both mktemp paths should exist as real, distinct files"
fi
[ "$FAILED" -eq 0 ] && echo "ok: exclusivity — mktemp never returns/reuses an existing path"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
