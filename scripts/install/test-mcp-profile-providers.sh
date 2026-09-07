#!/usr/bin/env bash
# test-mcp-profile-providers.sh — regression guard for HIMMEL-2634 (tokensave
# installer-provisioning removal). Formerly test-tokensave-mcp-install.sh
# (HIMMEL-2547, the tokensave-mcp `himmelctl deps` install descriptor) —
# renamed in place, history preserved via `git mv`, because tokensave-mcp no
# longer exists as a manifest item: DROP was ruled HIMMEL-2581, and this
# ticket removed its installer provisioning (manifest.json, install-engine.js,
# manifest-lint.mjs).
#
# PLATFORM GUARD (no .ps1 twin -- this note is that decision, not a
# placeholder for one): this suite is plain POSIX shell driving `jq` and
# `node`, and the two things it reads -- profiles.json and manifest.json --
# are plain JSON with no platform-specific shape, so there is no
# PowerShell-specific behaviour here for a `.ps1` twin to assert
# differently. It is already Git-Bash-aware where it has to be: every path
# handed to node goes through the `winpath()` helper below, which converts
# MSYS/Cygwin paths with `cygpath -m` on Windows and passes them through
# unchanged elsewhere. What this suite does NOT prove on Windows: it has
# never actually been RUN there (this session has no Windows station), so
# `cygpath` availability and Git Bash's own quoting of the node argv are
# unverified rather than merely untested. A future Windows run is what
# closes that gap.
#
# tokensave used to be a universal MCP-profile member (every profile in
# .claude/mcp-profiles/profiles.json listed it, including `minimal` on its
# own) SAFELY, because the installer manifest guaranteed it was registered.
# Removing that provisioning without replacing the guarantee would have left
# `minimal` resolving to zero servers — a hard FAILED from
# build-mcp-profiles.mjs (it refuses to write an empty profile and exits
# non-zero). The console FIRST ruled `minimal` becomes `["graphify"]`
# (reasoning: "the one remaining installer-provisioned MCP server") — that
# ruling was WRONG and was REVERSED once this suite's own panel caught it:
# `graphify-mcp` has NO `install` descriptor, its `graphify` dep has none
# either (`offboard: advise`), and a `mcp-registered` probe only DETECTS an
# existing registration, it does not perform one — `minimal: ["graphify"]`
# would have given `unresolved server "graphify"` (build-mcp-profiles.mjs:68)
# on any fresh machine, the exact hard failure this whole effort exists to
# prevent. The CORRECTED ruling: `minimal` becomes `["context7-remote"]` — a
# key in build-mcp-profiles.mjs's own `PLUGIN_SERVERS` map, so it resolves
# with no machine state and no installer step at all. `tokensave` stays
# stripped from the other four profiles. This file's new primary content
# (case "provider invariant" below) is the regression guard for that
# property in general — not just for this one migration — so a future
# profiles.json edit that adds an unprovided member (graphify included)
# fails loudly instead of shipping a profile that resolves to nothing on a
# fresh machine.
#
# Cases (fates of the original six, "a" is dropped from that lettering same
# as before since the file it now guards is a different invariant):
#   a. RETIRED — manifest.json lints clean is generic and redundant with
#      manifest-lint.mjs's own test coverage; not tokensave-specific.
#   b. RETIRED — tokensave-mcp carried install.type:tokensave; the item is
#      gone.
#   c. PRESERVED, retargeted at qmd-index — a malformed install descriptor
#      (unknown extra field) is REJECTED by manifest-lint, naming the bad
#      field. This is the only test anywhere of manifest-lint's closed-shape
#      install validator, so it survives the item swap.
#   d. RETIRED — install-engine.js's install.type:tokensave dispatch; the
#      dispatch arm is gone.
#   e. RETIRED — running the tokensave install entry end-to-end; same
#      dispatch arm, gone.
#   f. Checked against test-wizard-probes.sh's HIMMEL-1093 bin/initMarker
#      deepening block (fixed in this same ticket to use a synthetic fixture
#      descriptor instead of the now-gone tokensave-mcp manifest item): that
#      block already asserts fully-satisfied->present,
#      missing-binary->degraded (naming the binary), and
#      missing-initMarker->degraded (naming "project not initialized").
#      "Not registered at all -> absent" is covered by that same file's
#      earlier mcp-registered registration-only block (mcp_server_missing_home
#      etc.) — probes.js's probeMcpRegistered() returns 'absent' on an
#      unregistered server BEFORE ever consulting bin/initMarker, so an item
#      that also carries those fields takes the identical code path. Case f
#      is therefore fully redundant with test-wizard-probes.sh post-fix; NOT
#      migrated here to avoid duplicating coverage.
#
# New primary content — the provider invariant: every member of every
# profile in .claude/mcp-profiles/profiles.json must resolve to EITHER (i) a
# key in build-mcp-profiles.mjs's PLUGIN_SERVERS map, OR (ii) an item in
# manifest.json whose probe is {type:"mcp-registered", server:<member>} AND
# which ALSO carries a real `install` descriptor that actually provisions
# that server — EXCEPT members on the in-checker OPERATOR_PROVIDED allow-list
# (machine-local servers the operator registers by hand in ~/.claude.json —
# himmel does not guarantee them; currently obsidian-vault and onepassword).
#
# Criterion (ii) is intentionally NARROWER than "carries an mcp-registered
# probe" alone — that broader version is exactly what let the graphify
# ruling above through: a `mcp-registered` probe DETECTS an existing
# registration, it does not PERFORM one, so probe presence alone is not
# proof of provisioning. `graphify` must FAIL this invariant (RED control #3
# below) and must NEVER be laundered onto OPERATOR_PROVIDED — it isn't
# operator-provided either, it's simply unprovisioned. Today NO manifest
# item satisfies the tightened (ii) (tokensave-mcp, the one item that used
# to carry both fields, was removed by this same ticket) — that is CORRECT,
# not a bug to paper over; the rule stands ready for a future item that
# genuinely provisions its own MCP registration.
#
# Without the allow-list this invariant is RED on 2 of 5 profiles the day it
# lands, since nothing in himmel provisions those two (manifest.json's
# obsidian-second-brain is a `plugin`-kind item with a file-exists probe, not
# an MCP registration) — the point of the list is that adding a genuinely
# unprovided member costs a visible, reviewable edit instead of silently
# shipping a profile that resolves to nothing on a fresh machine. Hermetic:
# never reads ~/.claude.json — that's exactly the machine-state dependency
# this invariant exists to avoid.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
manifest_path="$repo_root/scripts/install/manifest.json"
lint="$repo_root/scripts/install/manifest-lint.mjs"
profiles_path="$repo_root/.claude/mcp-profiles/profiles.json"
build_profiles="$repo_root/scripts/mcp/build-mcp-profiles.mjs"
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
[ -f "$profiles_path" ] || { echo "FAIL: $profiles_path not found" >&2; exit 1; }
[ -f "$build_profiles" ] || { echo "FAIL: $build_profiles not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/himmel-mcp-profile-providers-test.XXXXXX") || fail "mktemp -d failed"
[ -n "$work" ] || fail "mktemp -d produced an empty path"
trap 'rm -rf "$work"' EXIT

# winpath <path> — MSYS/Git Bash paths confuse node's own path resolution
# when handed straight through; convert to a Windows-form path there, pass
# through unchanged elsewhere. Mirrors sibling test-*-manifest.sh's own
# helper.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── case c (preserved, retargeted at qmd-index): a malformed install
# descriptor (unknown extra field) is REJECTED by manifest-lint, naming the
# bad field — the only test anywhere of the closed-shape install validator ──
badManifest="$work/manifest-bad-install.json"
jq '(.items[] | select(.id == "qmd-index") | .install) |= (. + {"bogus": true})' \
  "$manifest_path" > "$badManifest"
outC=$(MANIFEST_PATH="$(winpath "$badManifest")" "$node_bin" "$(winpath "$lint")" 2>&1) && \
  fail "case c: manifest-lint should have REJECTED a qmd-index install descriptor with an unknown 'bogus' field, but it exited 0: $outC"
outC_match=$(printf '%s' "$outC" | grep -E "unexpected field" || true)
[ -n "$outC_match" ] \
  || fail "case c: manifest-lint's rejection should name the unexpected field, got: $outC"
echo "ok: case c — a malformed install descriptor (extra field) on a still-live item (qmd-index) is rejected, naming the field"

# ── provider invariant checker — text-extracts PLUGIN_SERVERS' keys from
# build-mcp-profiles.mjs (never imports/runs it — that script has real side
# effects: reading ~/.claude.json, writing local.*.json, process.exit) ─────
# CR fix (codex-1): anchoring on indentation alone is indentation-agnostic —
# it would ALSO match a nested property (e.g. `command:`) if the map were
# ever reformatted to multi-line entries, silently widening PLUGIN_SERVERS
# with a false key. Requiring the top-level 2-space indent AND a `{` value
# on the SAME line (every real entry opens its object right there) makes a
# future reformat UNDER-count instead — tripping the zero-keys guard below
# or surfacing as a missing provider, loud rather than silent. Do not relax
# this back toward a bare `[[:space:]]*`.
pluginServerKeys=$( (awk '/const PLUGIN_SERVERS = \{/,/^\};/' "$build_profiles" \
  | grep -oE '^  "?[A-Za-z0-9_-]+"?: *\{' | tr -d ' "{' | tr -d ':' | sort -u) || true)
[ -n "$pluginServerKeys" ] \
  || fail "extracted ZERO keys from build-mcp-profiles.mjs's PLUGIN_SERVERS ($build_profiles) — the extraction pattern is broken, this is NOT a genuinely empty map"
pluginServerKeysCsv=$(printf '%s' "$pluginServerKeys" | paste -sd, -)

checker="$work/check-providers.js"
cat > "$checker" <<'JS'
// Provider invariant: every profiles.json member must resolve to a
// PLUGIN_SERVERS key, a manifest.json item that both DETECTS (mcp-registered
// probe) and PROVISIONS (a real `install` descriptor) that server, or the
// OPERATOR_PROVIDED allow-list. Hermetic — never reads ~/.claude.json.
const fs = require('fs');
// Machine-local servers the operator registers by hand in ~/.claude.json;
// himmel provisions neither, so they are exempt from the provider check by
// deliberate, reviewed decision (HIMMEL-2634) rather than by omission.
// `graphify` is DELIBERATELY NOT on this list: it is not operator-provided
// either, it is simply unprovisioned (graphify-mcp/graphify carry no
// `install` descriptor) — the console was explicit that this must fail
// loudly (RED control #3), never be laundered onto this allow-list.
const OPERATOR_PROVIDED = ['obsidian-vault', 'onepassword'];
const [, , profilesPath, manifestPath, pluginServerKeysCsv] = process.argv;
const profiles = JSON.parse(fs.readFileSync(profilesPath, 'utf8')).profiles;
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const pluginServers = new Set(pluginServerKeysCsv.split(',').filter(Boolean));
// Criterion (ii), TIGHTENED: an mcp-registered probe alone is not proof of
// provisioning — it DETECTS an existing registration, it does not PERFORM
// one (this over-broad version is exactly what let the bad graphify ruling
// through). Require a real `install` descriptor too. No current manifest
// item satisfies both (tokensave-mcp, the one item that used to, was
// removed by this same ticket) — correct, not a bug: the rule stands ready
// for a future item that genuinely provisions its own MCP registration.
const manifestMcpServers = new Set(
  manifest.items
    .filter((i) => i.probe && i.probe.type === 'mcp-registered' && i.install)
    .map((i) => i.probe.server)
);
const failures = [];
for (const [profile, members] of Object.entries(profiles)) {
  // CR fix (codex-2): an empty profile passes the per-member loop below
  // trivially — but build-mcp-profiles.mjs REFUSES to write an empty
  // profile and exits non-zero (the exact failure that forced `minimal` to
  // carry a non-empty ruling in the first place — HIMMEL-2634). A distinct
  // failure category so it reads differently from a no-provider member.
  if (members.length === 0) {
    failures.push(`${profile}: has no members — build-mcp-profiles.mjs refuses to write an empty profile and exits non-zero`);
    continue;
  }
  for (const member of members) {
    if (OPERATOR_PROVIDED.includes(member)) continue;
    if (pluginServers.has(member)) continue;
    if (manifestMcpServers.has(member)) continue;
    failures.push(`${profile}: "${member}" has no provider (not in PLUGIN_SERVERS, not manifest-provisioned mcp-registered, not OPERATOR_PROVIDED)`);
  }
}
if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
console.log('OK: every profile member is provided by PLUGIN_SERVERS, the manifest, or OPERATOR_PROVIDED');
JS

# ── case invariant: the REAL profiles.json satisfies the provider invariant ─
outInv=$("$node_bin" "$(winpath "$checker")" "$(winpath "$profiles_path")" "$(winpath "$manifest_path")" "$pluginServerKeysCsv" 2>&1) \
  || fail "provider invariant: the real profiles.json should satisfy it, got: $outInv"
echo "ok: case invariant — every real profiles.json member resolves to PLUGIN_SERVERS, a manifest mcp-registered item, or OPERATOR_PROVIDED"

# ── RED control (mandatory): a profile member with NO provider and NOT on
# the allow-list must fail the checker — proves the invariant can go red ───
redProfiles="$work/profiles-red.json"
jq '.profiles.minimal += ["definitely-unprovided-server-xyz"]' "$profiles_path" > "$redProfiles"
outRed=$("$node_bin" "$(winpath "$checker")" "$(winpath "$redProfiles")" "$(winpath "$manifest_path")" "$pluginServerKeysCsv" 2>&1) && \
  fail "RED control: an unprovided, non-allow-listed profile member should have FAILED the checker, but it exited 0: $outRed"
redMatch=$(printf '%s' "$outRed" | grep -F "definitely-unprovided-server-xyz" || true)
[ -n "$redMatch" ] \
  || fail "RED control: the failure should name the unprovided member, got: $outRed"
echo "ok: RED control — an unprovided, non-allow-listed profile member fails the checker, naming it: $outRed"

# ── RED control #2 (mandatory, CR fix codex-2): an EMPTY profile must fail
# the checker — this is the exact failure build-mcp-profiles.mjs refuses to
# write (the one that forced the minimal:["graphify"] ruling in the first
# place), so the invariant must not pass it trivially ────────────────────
redEmptyProfiles="$work/profiles-red-empty.json"
jq '.profiles.minimal = []' "$profiles_path" > "$redEmptyProfiles"
outRedEmpty=$("$node_bin" "$(winpath "$checker")" "$(winpath "$redEmptyProfiles")" "$(winpath "$manifest_path")" "$pluginServerKeysCsv" 2>&1) && \
  fail "RED control #2: an empty profile should have FAILED the checker, but it exited 0: $outRedEmpty"
redEmptyMatch=$(printf '%s' "$outRedEmpty" | grep -F "minimal: has no members" || true)
[ -n "$redEmptyMatch" ] \
  || fail "RED control #2: the failure should name the empty profile, got: $outRedEmpty"
echo "ok: RED control #2 — an empty profile fails the checker, naming it: $outRedEmpty"

# ── RED control #3 (mandatory, ruling-A regression guard): `minimal:
# ["graphify"]` — the FIRST, REVERSED console ruling — must fail the
# checker. graphify-mcp's mcp-registered probe only DETECTS a registration,
# it does not PERFORM one (no `install` descriptor), so it is not a
# provisioning source; this locks that fact in so a future editor who tries
# this exact member again gets a loud, named failure instead of a repeat of
# the `unresolved server "graphify"` hard-fail this ticket was fixing.
# RED control #1 (an arbitrary made-up name) already proves the check is
# not graphify-special-cased — this one specifically proves graphify itself
# stays red, and cannot silently start passing (e.g. by future code
# accidentally treating probe-only as sufficient again) ──────────────────
redGraphifyProfiles="$work/profiles-red-graphify.json"
jq '.profiles.minimal = ["graphify"]' "$profiles_path" > "$redGraphifyProfiles"
outRedGraphify=$("$node_bin" "$(winpath "$checker")" "$(winpath "$redGraphifyProfiles")" "$(winpath "$manifest_path")" "$pluginServerKeysCsv" 2>&1) && \
  fail "RED control #3: minimal:[\"graphify\"] (the reverted ruling) should have FAILED the checker, but it exited 0: $outRedGraphify"
redGraphifyMatch=$(printf '%s' "$outRedGraphify" | grep -F '"graphify" has no provider' || true)
[ -n "$redGraphifyMatch" ] \
  || fail "RED control #3: the failure should name graphify, got: $outRedGraphify"
echo "ok: RED control #3 — minimal:[\"graphify\"] (the reverted ruling) fails the checker, naming it: $outRedGraphify"

echo "PASS"
