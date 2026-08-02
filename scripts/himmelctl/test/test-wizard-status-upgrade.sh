#!/usr/bin/env bash
# test-wizard-status-upgrade.sh — hermetic tests for HIMMEL-1017 (CR
# follow-up from HIMMEL-1012): himmelctl `status` must reconcile new
# manifest items into an EXISTING state.json, and stop false-redding
# opt-in tools. Mirrors sibling test-wizard-status-*.sh conventions: a fake
# HOME + HIMMELCTL_CACHE_DIR + HIMMELCTL_REPO_ROOT fixture, node launched by
# absolute path, winpath for node.exe's MSYS-path blindness.
#
# Covers:
#   a. UPGRADE: a target's state.json was derived against an OLDER manifest
#      missing an item ('pre-commit-hooks') that a later himmel-update's
#      manifest.json gained. Re-running `status` against the CURRENT
#      (full) manifest — simulating that update — must (1) surface the
#      previously-invisible item in the report instead of silently omitting
#      it, with its genuinely-derived desired/severity (not a stale
#      n/a-forever), and (2) persist that migration into state.json so the
#      NEXT run doesn't need to re-migrate it, while leaving every
#      already-tracked item's state byte-for-byte untouched.
#   b. OPT-IN: graphify-mcp carries profiles:["luna","all"] like any other
#      luna-profile item, so a luna/all target reads it desired:true even
#      though registering it is a genuinely opt-in, manual step (adopt.sh's
#      --with-graphify). Absent -> severity n/a (informational), not red.
#      Present (registered in ~/.claude.json) -> severity green, same as
#      any other item — the fix only silences the "never opted in" alarm,
#      it does not stop tracking the item.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# write_cache <path> <role> <scope> <vault-mode> <vault-path> <handover-mode>
#             <handover-path> <plugin-set> — a minimal valid Draft-A profile
#             (same shape sibling test-wizard-status-cmd.sh's write_cache).
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
}

# ══════════════════════════════════════════════════════════════════════════
# case (a): UPGRADE — a manifest item gained after the target was derived
# ══════════════════════════════════════════════════════════════════════════

fixtureRepoA="$work/repoA"
mkdir -p "$fixtureRepoA/scripts/install"
fixtureRepoA_w="$(winpath "$fixtureRepoA")"

targetA="$work/targetA"; mkdir -p "$targetA/.claude"
# Deliberately no .pre-commit-config.yaml — pre-commit-hooks reads absent
# once it's visible at all.

homeA="$work/homeA"; mkdir -p "$homeA"
cacheA="$work/cacheA"; mkdir -p "$cacheA"
cacheA_w="$(winpath "$cacheA")"

# profile 'core' (vault.mode:none), scope 'project' — pre-commit-hooks
# (profiles:["core","all"], scopes:["project"]) is desired under this
# target.
write_cache "$cacheA/install-profile.json" adopter project none "" inline "" lean

# ── OLD manifest: the real manifest minus pre-commit-hooks — simulates the
# state.json this target would have derived BEFORE a himmel-update added it
# (this is a fixture device: pre-commit-hooks is a real, long-standing item;
# the point is only that SOME item the target's persisted state predates).
"$node_bin" -e "
const fs = require('fs');
const m = JSON.parse(fs.readFileSync('$(winpath "$manifest_path")', 'utf8'));
m.items = m.items.filter((i) => i.id !== 'pre-commit-hooks');
fs.writeFileSync('$fixtureRepoA_w/scripts/install/manifest.json', JSON.stringify(m, null, 2) + '\n');
" || fail "case a setup: failed to write the OLD (item-short) fixture manifest"

# ── seed run: status against the OLD (item-short) manifest derives + saves
# a target entry that never carries pre-commit-hooks at all.
( cd "$targetA" && HIMMELCTL_REPO_ROOT="$fixtureRepoA_w" HIMMELCTL_CACHE_DIR="$cacheA_w" HOME="$homeA" \
    "$node_bin" "$wizard" status --json >/dev/null ) \
  || fail "case a setup: seed status run (old manifest) failed"

targetKeyA=$(jq -r '.targets | keys[0]' "$cacheA/state.json")
if [ -z "$targetKeyA" ] || [ "$targetKeyA" = "null" ]; then
  fail "case a setup: state.json has no derived target key"
fi
jq -e --arg k "$targetKeyA" '.targets[$k].items | has("pre-commit-hooks") | not' "$cacheA/state.json" >/dev/null \
  || fail "case a setup: fixture drift — pre-change state.json should NOT carry pre-commit-hooks yet (got: $(cat "$cacheA/state.json"))"
echo "ok: case a (setup) — seed state.json derived against the OLD manifest never carries pre-commit-hooks"

# Snapshot another item's enabled flag from the pre-migration state, to
# prove the migration below leaves it untouched.
wiringBefore=$(jq -e --arg k "$targetKeyA" '.targets[$k].items["wiring-pretooluse"].enabled' "$cacheA/state.json")

# ── the "upgrade": swap in the REAL (current, full) manifest and re-run
# status — this is the exact scenario a himmel-update delivers.
cp "$manifest_path" "$fixtureRepoA/scripts/install/manifest.json"

outA=$( cd "$targetA" && HIMMELCTL_REPO_ROOT="$fixtureRepoA_w" HIMMELCTL_CACHE_DIR="$cacheA_w" HOME="$homeA" \
    "$node_bin" "$wizard" status --json ) \
  || fail "case a: post-upgrade status run failed"

echo "$outA" | jq -e '.items[] | select(.id=="pre-commit-hooks")' >/dev/null \
  || fail "case a: pre-commit-hooks must now appear in the status report (got: $outA)"
echo "$outA" | jq -e '.items[] | select(.id=="pre-commit-hooks") | .desired == true' >/dev/null \
  || fail "case a: pre-commit-hooks should read desired:true under profile core/scope project (got: $outA)"
echo "$outA" | jq -e '.items[] | select(.id=="pre-commit-hooks") | .severity == "red"' >/dev/null \
  || fail "case a: pre-commit-hooks should be ACTIVELY PROBED (severity red — no .pre-commit-config.yaml here), not silently n/a (got: $outA)"
echo "ok: case a — a manifest item gained after the target's last derive is surfaced (probed, not silently n/a) on the very next status run"

jq -e --arg k "$targetKeyA" '.targets[$k].items | has("pre-commit-hooks")' "$cacheA/state.json" >/dev/null \
  || fail "case a: the migration should be PERSISTED into state.json (got: $(cat "$cacheA/state.json"))"
echo "ok: case a — the migration is persisted into state.json (not just reported in-memory for this one run)"

wiringAfter=$(jq -e --arg k "$targetKeyA" '.targets[$k].items["wiring-pretooluse"].enabled' "$cacheA/state.json")
[ "$wiringBefore" = "$wiringAfter" ] \
  || fail "case a: an already-tracked item's enabled flag must survive the migration unchanged (before=$wiringBefore after=$wiringAfter)"
echo "ok: case a — an already-tracked item's state survives the migration unchanged"

# ── a second post-upgrade run performs zero further state.json writes
# (migration is idempotent — nothing left to backfill). ─────────────────────
before2=$(sha256sum "$cacheA/state.json")
( cd "$targetA" && HIMMELCTL_REPO_ROOT="$fixtureRepoA_w" HIMMELCTL_CACHE_DIR="$cacheA_w" HOME="$homeA" \
    "$node_bin" "$wizard" status --json >/dev/null ) || fail "case a: second post-upgrade run failed"
after2=$(sha256sum "$cacheA/state.json")
[ "$before2" = "$after2" ] || fail "case a: a second run against an already-migrated target should write nothing further to state.json"
echo "ok: case a — a second run against an already-migrated target is a zero-write no-op"

# ══════════════════════════════════════════════════════════════════════════
# case (b): OPT-IN — graphify-mcp reads n/a (not red) when CLEANLY never
# registered, still reads green once it IS registered, and — CR fix
# (HIMMEL-1017 round) — stays red (not silently swallowed to n/a) when its
# config is genuinely broken rather than just never-opted-in. This target is
# scope 'project', so graphify-mcp's registration lives in <targetB>/
# .mcp.json (CR fix: probeMcpRegistered is now scope-aware — see
# probes.js's mcpConfigPath()); the original version of this test wrote to
# ~/.claude.json instead, which happened to pass only because the probe used
# to ignore scope entirely.
# ══════════════════════════════════════════════════════════════════════════

fixtureRepoB="$work/repoB"
mkdir -p "$fixtureRepoB/scripts/install"
cp "$manifest_path" "$fixtureRepoB/scripts/install/manifest.json"
fixtureRepoB_w="$(winpath "$fixtureRepoB")"

targetB="$work/targetB"; mkdir -p "$targetB/.claude"
homeB="$work/homeB"; mkdir -p "$homeB"
cacheB="$work/cacheB"; mkdir -p "$cacheB"
cacheB_w="$(winpath "$cacheB")"

# profile 'all' (vault.mode:default-template), scope 'project' — graphify-mcp
# (profiles:["luna","all"], scopes:["project","user"]) is desired:true here.
vaultB="$work/vault"
write_cache "$cacheB/install-profile.json" adopter project default-template "$(winpath "$vaultB")" inline "" lean

runStatusB() {
  ( cd "$targetB" && HIMMELCTL_REPO_ROOT="$fixtureRepoB_w" HIMMELCTL_CACHE_DIR="$cacheB_w" HOME="$homeB" \
      "$node_bin" "$wizard" status --items graphify-mcp --json )
}

# ── absent: no <targetB>/.mcp.json at all (project scope) -> severity n/a,
# not red, desired stays true (still actively tracked, just not alarmed).
# ENOENT is the ORDINARY case here — most projects never commit a .mcp.json
# at all — so this is a CLEAN absence, not a config error.
outB1=$(runStatusB) || fail "case b: status run (graphify-mcp absent) failed"
echo "$outB1" | jq -e '.items[0].desired == true' >/dev/null \
  || fail "case b: graphify-mcp should read desired:true under profile 'all' (got: $outB1)"
echo "$outB1" | jq -e '.items[0].severity == "n/a"' >/dev/null \
  || fail "case b: graphify-mcp absent should read severity n/a (informational, opt-in), not red (got: $outB1)"
echo "$outB1" | jq -e '.items[0].detail | test("opt-in"; "i")' >/dev/null \
  || fail "case b: graphify-mcp's n/a detail should name it as opt-in (got: $outB1)"
# CR fix (HIMMEL-1017 round): the n/a row must PRESERVE the underlying probe
# diagnostic (which file/condition was actually checked), not just the
# friendly opt-in framing — proves the fix doesn't discard information.
echo "$outB1" | jq -e '.items[0].detail | test("does not exist")' >/dev/null \
  || fail "case b: graphify-mcp's n/a detail should still name the underlying probe diagnostic (got: $outB1)"
echo "$outB1" | jq -e '.summary.red == 0' >/dev/null \
  || fail "case b: graphify-mcp absent must not count toward summary.red (got: $outB1)"
echo "ok: case b — graphify-mcp cleanly absent (never opted in) reads n/a, not a false red, and keeps its diagnostic detail"

# ── malformed config (CR fix, HIMMEL-1017 round): .mcp.json EXISTS but is
# unparseable — a lost/corrupted registration, NOT "never opted in". Must
# stay on the standard red path with the RAW probe diagnostic, never the
# friendly opt-in message (which would hide a genuine regression).
printf '{not valid json' > "$targetB/.mcp.json"
outB2=$(runStatusB) || fail "case b: status run (graphify-mcp malformed config) failed"
echo "$outB2" | jq -e '.items[0].severity == "red"' >/dev/null \
  || fail "case b: graphify-mcp with an unparseable .mcp.json must stay red, not be swallowed into n/a (got: $outB2)"
echo "$outB2" | jq -e '.items[0].detail | test("cannot read/parse")' >/dev/null \
  || fail "case b: graphify-mcp's red detail (malformed config) should carry the RAW probe diagnostic (got: $outB2)"
echo "$outB2" | jq -e '.items[0].detail | test("opt-in"; "i") | not' >/dev/null \
  || fail "case b: a broken config must NOT read the friendly opt-in message (got: $outB2)"
echo "$outB2" | jq -e '.summary.red == 1' >/dev/null \
  || fail "case b: a broken graphify-mcp config must count toward summary.red (got: $outB2)"
echo "ok: case b — a malformed graphify-mcp config stays red with its raw diagnostic, never silently downgraded"

# ── present: register it in <targetB>/.mcp.json -> severity green, same as
# any other present item — the fix must not stop tracking it once it IS
# there, and project scope must resolve .mcp.json (not ~/.claude.json).
# HIMMEL-1093 round 3: graphify-mcp's `bin` descriptor field was DROPPED
# (redundant/wrong — see manifest.json's comment); the registered entry's
# OWN `command` ("graphify-mcp", a bare name here) is now what must resolve,
# unconditionally. The stub is named to match that EXACT registered command
# — not the (now-irrelevant) `graphify` CLI name — and prepended ahead of
# the real PATH so the assertion doesn't depend on whether graphify-mcp
# happens to be installed on the test-runner's machine (this dev machine
# genuinely has one at ~/.local/bin/graphify-mcp.exe, which is exactly the
# false-hermeticity trap a mismatched stub name would silently paper over).
printf '{"mcpServers":{"graphify":{"command":"graphify-mcp"}}}' > "$targetB/.mcp.json"
graphifyBinDir="$work/graphify-bin"; mkdir -p "$graphifyBinDir"
: > "$graphifyBinDir/graphify-mcp"
chmod +x "$graphifyBinDir/graphify-mcp"
outB3=$(PATH="$graphifyBinDir:$PATH" runStatusB) || fail "case b: status run (graphify-mcp present) failed"
echo "$outB3" | jq -e '.items[0].severity == "green"' >/dev/null \
  || fail "case b: graphify-mcp registered in <targetB>/.mcp.json (project scope) with its registered command 'graphify-mcp' resolvable on PATH should read green (got: $outB3)"
echo "ok: case b — graphify-mcp registered (project-scope .mcp.json) + its registered command resolvable reads green, same as any other present desired item"

echo "PASS"
