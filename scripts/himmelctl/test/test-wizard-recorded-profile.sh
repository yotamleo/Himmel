#!/usr/bin/env bash
# test-wizard-recorded-profile.sh — hermetic tests for HIMMEL-2349: the
# recorded install-profile.json must reach desired-state computation
# (additive-only), and `ensure`'s disable/prune consent must be split from
# its converge consent with per-item evidence and an under-recorded guard.
#
# Reproduces (paths scrubbed) the operator machine's actual shapes: a
# recorded install-profile.json (schemaVersion 2, profile 'operator',
# scope 'user') whose vault is really configured (vault.mode
# 'default-template', giving manifest category 'all' via
# helpers.js's profileForVault) while state.json's persisted 'user' target
# is still stamped profile 'core' (derived once, long ago, before richer
# recorded answers existed) with several luna-category items enabled:false
# even though they are live and working.
#
# Covers:
#   a. two live, recorded-but-undeclared items (luna-a/luna-b) resolve
#      desired:true / severity:green via the additive overlay — never n/a —
#      and `status --json`'s detail names the recorded-install-profile
#      reason.
#   b. an item carrying an explicit override (luna-override, no `removable`
#      so it can never become a disable candidate either) is left
#      COMPLETELY alone by the additive reconcile: desired stays false, and
#      its persisted state.json entry (enabled + overrides) is
#      byte-unchanged across an `ensure` run.
#   c. the converge-only path still fixes a genuinely-missing item
#      (core-item, himmel-ops-plugin-shaped): `ensure --yes` (no --prune)
#      installs it, exit 0.
#   d. default `ensure` (no --prune) NEVER disables anything — a genuine,
#      undeclared-but-live, no-override disable candidate (stale-item) is
#      only described (per-item evidence line: recorded profile/scope,
#      live probe result, the exact command disabling would run) and left
#      untouched; luna-a/luna-b (fixed by the additive overlay) are not
#      even mentioned. ALSO (codex-3, re-raise): this fixture's recorded
#      profile ('operator', in install-profile.json) and its persisted
#      target category ('core', stale in state.json) genuinely differ —
#      the evidence line must attribute 'operator' to install-profile.json
#      (the truth), never 'core' (a different, resolved fact), though the
#      resolved category is still shown, honestly labeled as such.
#   e. --prune opts in and the same candidate genuinely disables (its
#      unwire primitive runs, marker removed, "converged" count includes
#      it) — the positive control paired with case d's negative one.
#   f. the under-recorded guard: when the record simply doesn't declare a
#      HANDFUL of live items (a thin/legacy vault.mode='none' record, not
#      an override), `ensure` — with OR without --prune — refuses to touch
#      any of them, names HIMMEL-2350, and points at the fix (now also
#      naming the --profile escape hatch), instead of offering a mass
#      disable. The converge-only phase still proceeds independently.
#   f2. (codex-2, re-raise) the guard has an escape hatch and does not
#      wedge: WITHOUT --profile, the same thin-record/3-present shape still
#      blocks (negative control); WITH an explicit --profile (even the SAME
#      category value), the guard defers and --prune genuinely unwinds
#      every item — proving the disable actually completes, not merely
#      that the warning is skipped.
#   j. (codex-1, Critical, cross-run) an explicit, consented downgrade
#      (`ensure --profile core --prune --yes`) must survive the VERY NEXT
#      ordinary `ensure` — the additive overlay, seeing the recorded
#      profile still covers the just-disabled item, must NOT silently
#      re-enable and reinstall it one run later. Two invocations against
#      the SAME persisted state; the bug only appears across the boundary
#      between them, never within one run.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (a piped `... | grep -q` false-negatives under `set -o pipefail`
# whenever the match lands early — HIMMEL-1430). Matches every sibling
# test-wizard-*.sh suite's own helper verbatim.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

fail() { echo "FAIL: $1" >&2; exit 1; }

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || fail "$wizard not found"
command -v node >/dev/null 2>&1 || fail "node required"
command -v jq >/dev/null 2>&1 || fail "jq required"

node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-recorded-profile.XXXXXX") || fail "mktemp -d failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# ── HERMETICITY (HIMMEL-2349 brief, load-bearing): USERPROFILE, not just
# HOME, redirected — os.homedir() reads USERPROFILE first on Windows, so HOME
# alone is a no-op for node.exe children under Git Bash. HIMMELCTL_CACHE_DIR
# and HIMMEL_LUNA_CONFIG_PATH are ALSO redirected (statusReport() calls
# lunaConfig.load() unconditionally on every run) — this suite never reads or
# writes the operator's real ~/.himmel or ~/.claude/himmel. ────────────────
homeDir="$work/home"; mkdir -p "$homeDir"
lunaConfigPath="$work/himmel-config.json"

# ═══════════════════════════════════════════════════════════════════════
# Phase 1 — additive overlay, override preserved, split consent, per-item
# evidence (cases a-e).
# ═══════════════════════════════════════════════════════════════════════
fixtureRepo="$work/repo1"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/lib"
# stale-item's `profiles: []` is deliberate: helpers.js's profileForVault()
# only ever returns 'core' or 'all' (never 'luna') — so the ONLY category
# value that can flip an item luna-a/luna-b's shape (["luna","all"]) on via
# the additive overlay is 'all', and 'all' is a member of every category any
# OTHER item declares too. Giving stale-item an empty profiles list is the
# only way this fixture can carry a genuine, permanently-undeclared-by-any-
# category disable candidate alongside items the recorded profile DOES
# cover, with a single recorded install-profile.json.
cat > "$fixtureRepo/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "core-item", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "core.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "full-offboard-only"
    },
    {
      "id": "luna-a", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-a.marker" },
      "removable": "full-offboard-only"
    },
    {
      "id": "luna-b", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-b.marker" },
      "removable": "full-offboard-only"
    },
    {
      "id": "luna-override", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "override.marker" }
    },
    {
      "id": "stale-item", "kind": "wiring", "scopes": ["project", "user"], "profiles": [], "deps": [],
      "probe": { "type": "file-exists", "path": "stale.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$fixtureRepo/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > core.marker
exit 0
SH
cat > "$fixtureRepo/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > stale.marker
exit 0
SH
cat > "$fixtureRepo/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
rm -f stale.marker
exit 0
SH

cacheDir="$work/cache1"; mkdir -p "$cacheDir"

# The recorded install-profile: schemaVersion 2, profile 'operator', scope
# 'user', vault.mode 'default-template' — the concrete value that makes
# helpers.js's profileForVault(cachedAnswers) return manifest category
# 'all' (every manifest item's `profiles` list includes 'all' — verified
# against the real scripts/install/manifest.json). ASSUMPTION (stated
# explicitly, per the ticket's own evidence not naming vault.mode
# literally): the operator's real vault.mode may instead be 'existing',
# for which profileForVault ALSO returns 'core' (a separate, narrower,
# pre-existing gap in that function's own mode->category mapping — NOT
# touched by this fix; see the final report).
cat > "$cacheDir/install-profile.json" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "scope": "user",
  "pluginSet": "lean",
  "vault": { "mode": "default-template", "path": "$(winpath "$work/vault1")" },
  "handover": { "mode": "inline" },
  "lanes": [], "lanesMeaningful": true
}
JSON

# state.json: 'user' target persisted at profile 'core' (stale — derived
# before this operator's vault existed) with EVERY item enabled:false.
# luna-override carries a deliberate recorded per-item override
# (overrides.consent — the ONE populated `overrides` shape this codebase
# has today, guardrail-block-global's ask-first gate; a non-empty
# `overrides` bag is what state.js's own hasDeliberateOverride() treats as
# "a deliberate choice was recorded, never second-guess it").
claudeHimmelDir="$homeDir/.claude/himmel"; mkdir -p "$claudeHimmelDir"
cat > "$claudeHimmelDir/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "core", "scope": "user",
      "items": {
        "core-item": { "enabled": false, "overrides": {} },
        "luna-a": { "enabled": false, "overrides": {} },
        "luna-b": { "enabled": false, "overrides": {} },
        "luna-override": { "enabled": false, "overrides": { "consent": "no" } },
        "stale-item": { "enabled": false, "overrides": {} }
      },
      "lastEnsured": null
    }
  }
}
JSON

# HIMMELCTL_CACHE_DIR points at cacheDir (install-profile.json), but
# state.json itself is only ever resolved via cacheDir() too (same
# helpers.js function) — so state.json must live in cacheDir, NOT under
# $homeDir/.claude/himmel. Move it there and drop the now-empty stand-in.
mv "$claudeHimmelDir/state.json" "$cacheDir/state.json"

# luna-a/luna-b/stale-item/override are already "live" — created directly,
# standing in for a luna feature the operator installed independently of
# himmelctl (qmd/tokensave/etc in the real incident).
( cd "$fixtureRepo" && : > luna-a.marker && : > luna-b.marker && : > override.marker && : > stale.marker )

runEnsure() {
  ( cd "$fixtureRepo" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
runStatus() {
  ( cd "$fixtureRepo" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" status "$@" </dev/null )
}

# ── case a: luna-a/luna-b resolve desired:true, severity:green (never
# n/a), via the additive overlay — the detail names the recorded-profile
# reason. ────────────────────────────────────────────────────────────────
outStatus1=$(runStatus --json)
for id in luna-a luna-b; do
  echo "$outStatus1" | jq -e --arg id "$id" '.items[] | select(.id==$id) | .desired == true and .severity == "green"' >/dev/null \
    || fail "case a: $id should resolve desired:true/severity:green (got: $outStatus1)"
  echo "$outStatus1" | jq -e --arg id "$id" '.items[] | select(.id==$id) | (.detail | contains("recorded install-profile"))' >/dev/null \
    || fail "case a: $id's detail should name the recorded-install-profile reason (got: $outStatus1)"
done
echo "ok: case a — recorded-but-undeclared live items (luna-a, luna-b) resolve desired:true/severity:green, detail names why"

# ── negative control for case a: luna-override (the SAME shape, but with a
# recorded override) stays desired:false/n/a — proves the additive overlay
# is not simply "every item that's live goes green". ───────────────────────
echo "$outStatus1" | jq -e '.items[] | select(.id=="luna-override") | .desired == false and .severity == "n/a"' >/dev/null \
  || fail "negative control: luna-override (overridden) should stay desired:false/n/a (got: $outStatus1)"
echo "ok: negative control — luna-override (recorded override present) is NOT swept into the additive overlay"

# ── case c: the converge-only path still fixes a genuinely-missing item
# (core-item, himmel-ops-plugin-shaped). ───────────────────────────────────
set +e
outEnsure1=$(runEnsure --yes 2>&1); rcEnsure1=$?
set -e
[ "$rcEnsure1" -eq 0 ] || fail "case c: ensure --yes should exit 0 (got rc=$rcEnsure1): $outEnsure1"
[ -f "$fixtureRepo/core.marker" ] || fail "case c: core-item should have converged (core.marker missing): $outEnsure1"
echo "ok: case c — the converge-only path still installs a genuinely red/desired item (core-item)"

# ── case a (surfaced): the SAME ensure run must have printed the additive
# reconcile so the operator can see WHY the answer changed. ───────────────
grepq "$outEnsure1" -F 'recorded install-profile enables' || fail "case a: ensure should surface the additive reconcile in its own output (got: $outEnsure1)"
grepq "$outEnsure1" -F 'luna-a' || fail "case a: the additive-reconcile line should name luna-a (got: $outEnsure1)"
grepq "$outEnsure1" -F 'luna-b' || fail "case a: the additive-reconcile line should name luna-b (got: $outEnsure1)"
echo "ok: case a (surfaced) — ensure's own output names which items the recorded profile turned on"

# ── case d: default ensure (no --prune) NEVER disables anything. luna-a/
# luna-b (fixed by the overlay) are not even mentioned; stale-item (a
# genuine, undeclared+live+no-override candidate) is only DESCRIBED — a
# per-item evidence line naming the recorded profile/scope, the live probe
# result, and the exact disable command — and left untouched. ─────────────
grepq "$outEnsure1" -F 'converge-only by default' || fail "case d: default ensure should say converge-only by default (got: $outEnsure1)"
grepq "$outEnsure1" -F 'stale-item: recorded install-profile says' || fail "case d: should print stale-item's per-item evidence line (got: $outEnsure1)"
grepq "$outEnsure1" -F 'live state says present' || fail "case d: the evidence line should name the live probe result (got: $outEnsure1)"
grepq "$outEnsure1" -F 'disabling would run' || fail "case d: the evidence line should name what disabling would run (got: $outEnsure1)"
# (codex-3, re-raise) THIS fixture's whole point: install-profile.json
# genuinely records profile='operator', while state.json's persisted
# target category is the STALE 'core' (derived long ago, per the fixture's
# own header comment) — a fixture where the two agreed would prove
# nothing. The evidence line must attribute 'operator' to install-
# profile.json (what it actually says), never 'core' (the resolved
# manifest category, a DIFFERENT fact) — that mix-up was the bug.
grepq "$outEnsure1" -F 'profile=operator scope=' || fail "case d: the evidence line must name the GENUINELY recorded profile (operator, from install-profile.json), not the persisted-but-stale category (got: $outEnsure1)"
if grepq "$outEnsure1" -F 'profile=core scope='; then
  fail "case d: the evidence line must NOT attribute state.json's stale persisted category ('core') to install-profile.json as if it were the recorded profile (got: $outEnsure1)"
fi
# the resolved category is still honestly shown, just correctly labeled.
grepq "$outEnsure1" -F "resolves to manifest category 'core'" || fail "case d: the resolved manifest category should still be shown, honestly labeled as distinct from the recorded profile (got: $outEnsure1)"
# luna-a/luna-b must never get a per-item disable-evidence line of their
# own (that line format is always "<id>: recorded install-profile says..." —
# see describeDisableCandidate() in bin.js) — they're fully green now, so
# the towardDisabled loop never even reaches them.
if grepq "$outEnsure1" -F 'luna-a: recorded install-profile says' || grepq "$outEnsure1" -F 'luna-b: recorded install-profile says'; then
  fail "case d: luna-a/luna-b (fixed by the overlay) must never get their own disable-evidence line (got: $outEnsure1)"
fi
[ -f "$fixtureRepo/stale.marker" ] || fail "case d: stale-item must be left untouched by default (marker missing): $outEnsure1"
echo "ok: case d — default ensure describes the one genuine disable candidate but disables NOTHING (negative control)"

# ── case b: luna-override's persisted state.json entry is byte-unchanged
# by the ensure run above (the additive reconcile never touched it, and
# the ordinary disable path never reaches it — it carries no `removable`).
# ────────────────────────────────────────────────────────────────────────
overrideEntry=$(jq -c '.targets.user.items["luna-override"]' "$cacheDir/state.json")
[ "$overrideEntry" = '{"enabled":false,"overrides":{"consent":"no"}}' ] \
  || fail "case b: luna-override's persisted entry should be byte-unchanged (got: $overrideEntry)"
[ -f "$fixtureRepo/override.marker" ] || fail "case b: override.marker should still exist (item was never touched)"
echo "ok: case b — an item carrying an explicit override is left completely alone (state.json entry byte-unchanged)"

# ── case e (positive control for case d): --prune opts in, and the SAME
# candidate genuinely disables. ────────────────────────────────────────────
set +e
outEnsure2=$(runEnsure --yes --prune 2>&1); rcEnsure2=$?
set -e
[ "$rcEnsure2" -eq 0 ] || fail "case e: ensure --yes --prune should exit 0 (got rc=$rcEnsure2): $outEnsure2"
[ ! -f "$fixtureRepo/stale.marker" ] || fail "case e: --prune should have disabled stale-item (marker should be gone): $outEnsure2"
grepq "$outEnsure2" -F 'converged' || fail "case e: the completion summary should mention converged (got: $outEnsure2)"
echo "ok: case e — --prune genuinely disables the described candidate (positive control for case d)"

# luna-override must STILL be untouched after the --prune run too (it was
# never a disable candidate to begin with — no `removable`).
overrideEntry2=$(jq -c '.targets.user.items["luna-override"]' "$cacheDir/state.json")
[ "$overrideEntry2" = '{"enabled":false,"overrides":{"consent":"no"}}' ] \
  || fail "case b (post --prune): luna-override's persisted entry should still be byte-unchanged (got: $overrideEntry2)"
[ -f "$fixtureRepo/override.marker" ] || fail "case b (post --prune): override.marker should still exist"
echo "ok: case b (post --prune) — the overridden item survives a --prune run too"

# ═══════════════════════════════════════════════════════════════════════
# Phase 2 — under-recorded guard (case f): a thin/legacy record simply
# doesn't declare a HANDFUL of live items (no override involved) — ensure
# must refuse to touch them, WITH or WITHOUT --prune, and point at the fix.
# ═══════════════════════════════════════════════════════════════════════
fixtureRepo2="$work/repo2"
mkdir -p "$fixtureRepo2/scripts/install" "$fixtureRepo2/scripts/lib"
cat > "$fixtureRepo2/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "core-item2", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "core2.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "full-offboard-only"
    },
    {
      "id": "luna-x", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-x.marker" }, "removable": "full-offboard-only"
    },
    {
      "id": "luna-y", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-y.marker" }, "removable": "full-offboard-only"
    },
    {
      "id": "luna-z", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-z.marker" }, "removable": "full-offboard-only"
    }
  ]
}
JSON
cat > "$fixtureRepo2/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > core2.marker
exit 0
SH

cacheDir2="$work/cache2"; mkdir -p "$cacheDir2"

# A genuinely THIN record: vault.mode 'none' -> profileForVault gives
# category 'core' -> the luna-only items are NOT declared, honestly (no
# override involved — this is the "no usable record" residual case Fix B3
# names, distinct from Fix A's "record exists and is richer than the
# target" case in phase 1 above).
cat > "$cacheDir2/install-profile.json" <<'JSON'
{
  "schemaVersion": 2, "profile": "starter", "devOverlay": false, "scope": "user",
  "pluginSet": "lean",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline" },
  "lanes": [], "lanesMeaningful": true
}
JSON
cat > "$cacheDir2/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "core", "scope": "user",
      "items": {
        "core-item2": { "enabled": false, "overrides": {} },
        "luna-x": { "enabled": false, "overrides": {} },
        "luna-y": { "enabled": false, "overrides": {} },
        "luna-z": { "enabled": false, "overrides": {} }
      },
      "lastEnsured": null
    }
  }
}
JSON
( cd "$fixtureRepo2" && : > luna-x.marker && : > luna-y.marker && : > luna-z.marker )

runEnsure2() {
  ( cd "$fixtureRepo2" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo2")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir2")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

set +e
outUR1=$(runEnsure2 --yes 2>&1); rcUR1=$?
set -e
[ "$rcUR1" -eq 0 ] || fail "case f: ensure --yes should exit 0 (core-item2 still converges) (got rc=$rcUR1): $outUR1"
[ -f "$fixtureRepo2/core2.marker" ] || fail "case f: core-item2 should still converge under the guard: $outUR1"
grepq "$outUR1" -F 'UNDER-RECORDED' || fail "case f: should name the record as under-recorded (got: $outUR1)"
grepq "$outUR1" -F 'HIMMEL-2350' || fail "case f: should name HIMMEL-2350 (got: $outUR1)"
for id in luna-x luna-y luna-z; do
  grepq "$outUR1" -F "$id: recorded install-profile says" || fail "case f: should list $id's evidence line (got: $outUR1)"
  [ -f "$fixtureRepo2/$id.marker" ] || fail "case f: $id must be left untouched (got: $outUR1)"
done
echo "ok: case f (no --prune) — the under-recorded guard describes every live-undeclared item and touches none, converge still proceeds"

# --prune must NOT override the under-recorded guard.
set +e
outUR2=$(runEnsure2 --yes --prune 2>&1); rcUR2=$?
set -e
[ "$rcUR2" -eq 0 ] || fail "case f (--prune): should still exit 0 (got rc=$rcUR2): $outUR2"
grepq "$outUR2" -F 'UNDER-RECORDED' || fail "case f (--prune): should STILL refuse via the under-recorded guard (got: $outUR2)"
# (codex-2, re-raise) the guard's own message must name the way forward —
# a block that doesn't say how to proceed is the anti-pattern this ticket
# is about. It already pointed at re-recording the profile; it must ALSO
# name the --profile escape hatch for a genuinely deliberate downgrade.
grepq "$outUR2" -F -- '--profile' || fail "case f (--prune): the guard message should name the --profile escape hatch as a way forward (got: $outUR2)"
for id in luna-x luna-y luna-z; do
  [ -f "$fixtureRepo2/$id.marker" ] || fail "case f (--prune): $id must still be untouched (got: $outUR2)"
done
echo "ok: case f (--prune) — the under-recorded guard overrides an explicit --prune too, WITHOUT --profile (negative control for case f2 below); its message names the --profile escape hatch"

# ── case f2 (codex-2, re-raise — THE ESCAPE HATCH + WEDGE PROOF): the SAME
# guard, on a fixture whose items CAN actually be unwound (removable:
# per-item, unlike repo2's full-offboard-only items above — a real
# escape-hatch proof needs the disable to actually SUCCEED, not just avoid
# the guard's message). Mirrors repo2's exact mechanism (`desired` is the
# PERSISTED `enabled` flag — state.js: `desired = Boolean(entry &&
# entry.enabled)` — recomputed only by an explicit reconcile, never
# implicitly from category on every run): 3 items persisted enabled:false
# under category 'core' (both recorded and persisted), genuinely present.
# The negative-control run below passes NO --profile at all (identical
# shape/mechanism to case f); the positive-control run passes --profile
# core (the SAME category value — deference is keyed on --profile being
# PASSED, not on it changing anything). Proves there is no permanent
# wedge: the escape hatch genuinely unwinds every item, not merely skips
# the warning. ─────────────────────────────────────────────────────────
fixtureRepo2b="$work/repo2b"
mkdir -p "$fixtureRepo2b/scripts/install" "$fixtureRepo2b/scripts/lib"
cat > "$fixtureRepo2b/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "wedge-a", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wedge-a.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "wedge-b", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wedge-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" },
      "unwire": { "type": "wire", "target": "pretooluse-hooks" },
      "removable": "per-item"
    },
    {
      "id": "wedge-c", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wedge-c.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$fixtureRepo2b/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixtureRepo2b/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixtureRepo2b/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
rm -f wedge-a.marker wedge-c.marker
exit 0
SH
cat > "$fixtureRepo2b/scripts/lib/unwire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
rm -f wedge-b.marker
exit 0
SH

cacheDir2b="$work/cache2b"; mkdir -p "$cacheDir2b"
cat > "$cacheDir2b/install-profile.json" <<'JSON'
{
  "schemaVersion": 2, "profile": "starter", "devOverlay": false, "scope": "user",
  "pluginSet": "lean",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline" },
  "lanes": [], "lanesMeaningful": true
}
JSON
cat > "$cacheDir2b/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "core", "scope": "user",
      "items": {
        "wedge-a": { "enabled": false, "overrides": {} },
        "wedge-b": { "enabled": false, "overrides": {} },
        "wedge-c": { "enabled": false, "overrides": {} }
      },
      "lastEnsured": null
    }
  }
}
JSON
( cd "$fixtureRepo2b" && : > wedge-a.marker && : > wedge-b.marker && : > wedge-c.marker )

runEnsure2b() {
  ( cd "$fixtureRepo2b" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo2b")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir2b")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# negative control (paired with case f/f2, same shape): WITHOUT --profile,
# the guard still blocks — 3 live-undeclared items, present, --prune asked
# for -> UNDER-RECORDED, nothing unwound.
set +e
outF2neg=$(runEnsure2b --yes --prune 2>&1); rcF2neg=$?
set -e
[ "$rcF2neg" -eq 0 ] || fail "case f2 (negative control, no --profile): should exit 0 (got rc=$rcF2neg): $outF2neg"
grepq "$outF2neg" -F 'UNDER-RECORDED' || fail "case f2 (negative control): the guard should still block without --profile (got: $outF2neg)"
for id in wedge-a wedge-b wedge-c; do
  [ -f "$fixtureRepo2b/$id.marker" ] || fail "case f2 (negative control): $id must be untouched without --profile (got: $outF2neg)"
done
echo "ok: case f2 (negative control) — without --profile, the guard still blocks --prune (3 present, thin record)"

# positive control: an explicit --profile (even naming the SAME category,
# 'core') defers the guard -> --prune genuinely proceeds, every item
# actually unwinds. This is the wedge fix: the escape hatch must not just
# avoid the warning, it must let the disable actually complete.
set +e
outF2pos=$(runEnsure2b --profile core --yes --prune 2>&1); rcF2pos=$?
set -e
[ "$rcF2pos" -eq 0 ] || fail "case f2 (escape hatch): ensure --profile core --yes --prune should exit 0 (got rc=$rcF2pos): $outF2pos"
if grepq "$outF2pos" -F 'UNDER-RECORDED'; then
  fail "case f2 (escape hatch): an explicit --profile must defer the under-recorded guard (got: $outF2pos)"
fi
grepq "$outF2pos" -F 'converged' || fail "case f2 (escape hatch): the completion summary should mention converged (got: $outF2pos)"
for id in wedge-a wedge-b wedge-c; do
  [ ! -f "$fixtureRepo2b/$id.marker" ] || fail "case f2 (escape hatch): $id should be GENUINELY unwound (marker should be gone), not just past the guard's message (got: $outF2pos)"
done
echo "ok: case f2 (escape hatch) — an explicit --profile defers the under-recorded guard and --prune genuinely disables every item; no wedge"

# ═══════════════════════════════════════════════════════════════════════
# Phase 3 — RETASK 01S-A-2349-b73d: the membership CATEGORY the additive
# overlay checks must come from the recorded schema-v2 `profile` field
# (starter->core, luna/operator->all), not from profileForVault(vault.mode)
# — which maps vault.mode:'existing' the same as 'none' (category 'core'),
# silently dropping every luna-category item for an operator who already
# has a real vault. Small shared manifest: two luna-only items (no `all`-
# only escape hatch — this is what actually distinguishes the mapping from
# "everything goes green regardless").
# ═══════════════════════════════════════════════════════════════════════
fixtureRepo3="$work/repo3"
mkdir -p "$fixtureRepo3/scripts/install"
cat > "$fixtureRepo3/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "luna-p", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-p.marker" }, "removable": "full-offboard-only"
    },
    {
      "id": "luna-q", "kind": "dep", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "luna-q.marker" }, "removable": "full-offboard-only"
    }
  ]
}
JSON
( cd "$fixtureRepo3" && : > luna-p.marker && : > luna-q.marker )

# state.json: 'user' target persisted at profile 'core' (exactly the
# operator's own machine: 32 items enabled under category 'core') with both
# luna items enabled:false.
mkState3() {
  cat > "$1/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "core", "scope": "user",
      "items": {
        "luna-p": { "enabled": false, "overrides": {} },
        "luna-q": { "enabled": false, "overrides": {} }
      },
      "lastEnsured": null
    }
  }
}
JSON
}

runStatus3() {
  ( cd "$fixtureRepo3" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo3")" HIMMELCTL_CACHE_DIR="$(winpath "$1")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" status --json </dev/null )
}
runEnsure3() {
  ( cd "$fixtureRepo3" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo3")" HIMMELCTL_CACHE_DIR="$(winpath "$1")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" ensure --yes </dev/null )
}

# ── case g (THE TICKET'S LITERAL ACCEPTANCE CRITERION): the operator's own
# exact shape — recorded profile 'operator', vault.mode 'existing', scope
# 'user'; state.json target 'core' with the luna items enabled:false; both
# live. Must resolve desired:true/severity:green (not n/a), and `ensure`
# must offer ZERO disables. ─────────────────────────────────────────────
cacheDir3g="$work/cache3g"; mkdir -p "$cacheDir3g"
cat > "$cacheDir3g/install-profile.json" <<JSON
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "scope": "user",
  "pluginSet": "lean",
  "vault": { "mode": "existing", "path": "$(winpath "$work/vault3g")" },
  "handover": { "mode": "inline" },
  "lanes": [], "lanesMeaningful": true
}
JSON
mkState3 "$cacheDir3g"

outStatus3g=$(runStatus3 "$cacheDir3g")
for id in luna-p luna-q; do
  echo "$outStatus3g" | jq -e --arg id "$id" '.items[] | select(.id==$id) | .desired == true and .severity == "green"' >/dev/null \
    || fail "case g (operator's done-check): $id should resolve desired:true/severity:green under profile=operator+vault.mode=existing (got: $outStatus3g)"
done
set +e
outEnsure3g=$(runEnsure3 "$cacheDir3g" 2>&1); rcEnsure3g=$?
set -e
[ "$rcEnsure3g" -eq 0 ] || fail "case g: ensure --yes should exit 0 (got rc=$rcEnsure3g): $outEnsure3g"
if grepq "$outEnsure3g" -F 'luna-p: recorded install-profile says' || grepq "$outEnsure3g" -F 'luna-q: recorded install-profile says'; then
  fail "case g: ensure must offer ZERO disables for profile=operator+vault.mode=existing (got: $outEnsure3g)"
fi
echo "ok: case g — THE TICKET'S DONE-CHECK: recorded profile='operator' + vault.mode='existing' + live-green items => desired:true/green, ensure offers zero disables"

# ── case h (negative control for case g): profile 'starter' + the SAME
# vault.mode 'existing' — the luna items must stay NOT desired. Without
# this, case g passing would prove nothing (the overlay could just be
# turning everything on unconditionally). ─────────────────────────────────
cacheDir3h="$work/cache3h"; mkdir -p "$cacheDir3h"
cat > "$cacheDir3h/install-profile.json" <<JSON
{
  "schemaVersion": 2, "profile": "starter", "devOverlay": false, "scope": "user",
  "pluginSet": "lean",
  "vault": { "mode": "existing", "path": "$(winpath "$work/vault3h")" },
  "handover": { "mode": "inline" },
  "lanes": [], "lanesMeaningful": true
}
JSON
mkState3 "$cacheDir3h"

outStatus3h=$(runStatus3 "$cacheDir3h")
for id in luna-p luna-q; do
  echo "$outStatus3h" | jq -e --arg id "$id" '.items[] | select(.id==$id) | .desired == false and .severity == "n/a"' >/dev/null \
    || fail "case h (negative control): $id should stay desired:false/n/a under profile=starter+vault.mode=existing (got: $outStatus3h)"
done
echo "ok: case h — negative control: profile='starter' (even with the SAME existing vault) leaves the luna items undesired — the mapping does the work, not a blanket turn-everything-on"

# ── case i: a v1 record (no schemaVersion/profile field at all) falls back
# to profileForVault(cachedAnswers) — unchanged behaviour. vault.mode
# 'existing' -> profileForVault's own fallback ('core') -> luna items stay
# undesired, exactly as before this retask.  ──────────────────────────────
cacheDir3i="$work/cache3i"; mkdir -p "$cacheDir3i"
cat > "$cacheDir3i/install-profile.json" <<JSON
{
  "role": "adopter", "scope": "user",
  "vault": { "mode": "existing", "path": "$(winpath "$work/vault3i")" },
  "handover": { "mode": "inline" },
  "pluginSet": "lean", "lanes": [], "lanesMeaningful": true
}
JSON
mkState3 "$cacheDir3i"

outStatus3i=$(runStatus3 "$cacheDir3i")
for id in luna-p luna-q; do
  echo "$outStatus3i" | jq -e --arg id "$id" '.items[] | select(.id==$id) | .desired == false and .severity == "n/a"' >/dev/null \
    || fail "case i: $id should fall back to profileForVault (desired:false/n/a) for a v1 record with no profile field (got: $outStatus3i)"
done
echo "ok: case i — a v1 record (no profile field) falls back to profileForVault(cachedAnswers), behaviour unchanged"


# ═══════════════════════════════════════════════════════════════════════
# Phase 4 — HIMMEL-2349 (codex-1, Critical): an explicit downgrade must
# survive the NEXT ordinary ensure. The additive overlay is additive-only
# by VALUE, but a target's `profile` value alone can't tell "derived once,
# never revisited" (the incident this whole ticket exists to fix) apart
# from "explicitly reconciled" (an operator decision) — reconcileTarget()
# now stamps profileSource:'explicit' so the overlay can tell them apart.
# case j is the cross-run proof (the bug only appears across TWO
# invocations, never within one); case a/g above (unmodified, no
# profileSource in their fixtures) are the standing regression guard that
# this fix does NOT disable the overlay for a genuinely derived-stale
# target — the actual incident.
# ═══════════════════════════════════════════════════════════════════════
fixtureRepoJ="$work/repoJ"
mkdir -p "$fixtureRepoJ/scripts/install" "$fixtureRepoJ/scripts/lib"
cat > "$fixtureRepoJ/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "wedge-item", "kind": "wiring", "scopes": ["project", "user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wedge-item.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$fixtureRepoJ/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > wedge-item.marker
exit 0
SH
cat > "$fixtureRepoJ/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
rm -f wedge-item.marker
exit 0
SH

cacheDirJ="$work/cacheJ"; mkdir -p "$cacheDirJ"
# recorded profile 'operator' -> category 'all' (covers wedge-item) — the
# overlay WOULD cover this item were it not for the provenance guard.
cat > "$cacheDirJ/install-profile.json" <<'JSON'
{
  "schemaVersion": 2, "profile": "operator", "devOverlay": false, "scope": "user",
  "pluginSet": "lean",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline" },
  "lanes": [], "lanesMeaningful": true
}
JSON
# state.json: 'user' target already wired (wedge-item enabled:true, some
# prior converge — how it got there doesn't matter), persisted at profile
# 'all' — recorded profile and persisted category AGREE before the
# downgrade (this fixture is about what happens to an explicit downgrade
# AFTER it, not a stale-derivation scenario — case a/g already cover
# that). No profileSource yet: the first run below is what stamps it.
cat > "$cacheDirJ/state.json" <<'JSON'
{
  "schemaVersion": 1, "harness": "claude",
  "targets": {
    "user": {
      "profile": "all", "scope": "user",
      "items": {
        "wedge-item": { "enabled": true, "overrides": {} }
      },
      "lastEnsured": null
    }
  }
}
JSON
# scope='user' -> baseTargetPath resolves to repoRoot() (bin.js), NOT cwd
# -- so the marker/settings live under fixtureRepoJ itself, matching every
# sibling scope='user' fixture in this file (Phase 1/Phase 3 above).
( cd "$fixtureRepoJ" && : > wedge-item.marker )

runEnsureJ() {
  ( cd "$fixtureRepoJ" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepoJ")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheDirJ")" \
      USERPROFILE="$(winpath "$homeDir")" HOME="$homeDir" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$lunaConfigPath")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# ── case j (part 1): explicit, consented downgrade — --profile core
# excludes wedge-item's category, --prune actually unwinds it. ────────────
set +e
outJ1=$(runEnsureJ --profile core --prune --yes 2>&1); rcJ1=$?
set -e
[ "$rcJ1" -eq 0 ] || fail "case j (part 1): ensure --profile core --prune --yes should exit 0 (got rc=$rcJ1): $outJ1"
[ ! -f "$fixtureRepoJ/wedge-item.marker" ] || fail "case j (part 1): the explicit downgrade should have unwired wedge-item (marker should be gone): $outJ1"
jq -e '.targets.user.profileSource == "explicit"' "$cacheDirJ/state.json" >/dev/null \
  || fail "case j (part 1): reconcileTarget() should stamp profileSource:'explicit' on the persisted target (got: $(cat "$cacheDirJ/state.json"))"
jq -e '.targets.user.items["wedge-item"].enabled == false' "$cacheDirJ/state.json" >/dev/null \
  || fail "case j (part 1): wedge-item should be persisted disabled after the explicit downgrade (got: $(cat "$cacheDirJ/state.json"))"
echo "ok: case j (part 1) — an explicit, consented downgrade genuinely unwinds wedge-item and stamps profileSource:'explicit'"

# ── case j (part 2, THE BUG): a PLAIN ensure (no --profile, no --prune) —
# the recorded profile is STILL 'operator'/'all', which STILL covers
# wedge-item. Without the provenance guard, the additive overlay would see
# wedge-item.enabled==false and the recorded category 'all' covering it,
# flip it back to enabled:true, and the converge pass would REINSTALL it —
# reversing the operator's explicit decision one run later. ───────────────
set +e
outJ2=$(runEnsureJ --yes 2>&1); rcJ2=$?
set -e
[ "$rcJ2" -eq 0 ] || fail "case j (part 2): plain ensure --yes should exit 0 (got rc=$rcJ2): $outJ2"
if grepq "$outJ2" -F 'wedge-item'; then
  fail "case j (part 2): the additive overlay must NOT mention/re-enable wedge-item on an explicitly-reconciled target (got: $outJ2)"
fi
[ ! -f "$fixtureRepoJ/wedge-item.marker" ] || fail "case j (part 2): wedge-item must STAY unwired — the explicit downgrade must survive the next ordinary ensure (got: $outJ2)"
jq -e '.targets.user.items["wedge-item"].enabled == false' "$cacheDirJ/state.json" >/dev/null \
  || fail "case j (part 2): wedge-item must stay persisted disabled (got: $(cat "$cacheDirJ/state.json"))"
echo "ok: case j (part 2) — THE FIX: a plain ensure one run later does NOT reinstall wedge-item; the explicit downgrade survives"

echo "PASS"
