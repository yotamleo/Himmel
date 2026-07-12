#!/usr/bin/env bash
# test-wizard-status-cmd.sh — hermetic tests for the himmelctl `status`
# subcommand (HIMMEL-756 T1.5/T1.6): the severity-grouped diff between
# desired (state.js-derived) and actual (probes.js) per manifest item, plus
# its stable --json mode. Mirrors sibling test-wizard-*.sh conventions: a
# fake HOME + HIMMELCTL_CACHE_DIR + HIMMELCTL_REPO_ROOT fixture, node
# launched by absolute path, winpath for node.exe's MSYS-path blindness.
# `status` never prompts (no readline anywhere in its code path) and never
# shells out to a stub-able installer, so — unlike test-wizard-derive.sh —
# there is no install/uninstall script stub to fake; the fixture only needs
# a real copy of scripts/install/manifest.json plus the handful of files
# the chosen probe set reads.
#
# Covers:
#   a. `status --help` / bare `--help` both list the status subcommand.
#   b. a fixture with a known-missing enabled item (pre-commit-hooks: no
#      .pre-commit-config.yaml in the target) reads severity red, exit 0,
#      and its detail plainly names the missing file (review carry-forward
#      #3) rather than implying a broken install.
#   c. --items scoping: only the listed ids appear in the output; an
#      unknown id exits 2 naming it.
#   d. no install-profile cache -> exit 2 with the exact "run himmelctl
#      install first" message, and no state.json is created.
#   e. --json: valid JSON, byte-identical across two consecutive runs,
#      summary.red equals the count of severity=="red" items, items sorted
#      by id.
#   f. no-prompt guard: stdin closed (</dev/null) does not hang or error.
#   g. purity: beyond ensureTarget's ONE sanctioned first-derive write to
#      state.json, a second run leaves the whole fixture tree (repo fixture,
#      target, cache) byte-identical.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum required" >&2; exit 1; }

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
#             (same shape test-wizard-derive.sh's write_cache writes).
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"alwaysOn":false}
JSON
}

# snapshot_dir <dir> — sorted "relpath sha256" pairs, for a before/after
# byte-identity check that doesn't depend on tar's metadata quirks.
snapshot_dir() {
  ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum )
}

# ── shared fixture repo root (HIMMELCTL_REPO_ROOT) ──────────────────────────
# A real copy of manifest.json plus the handful of repoRoot-relative files
# the chosen probe set reads: jira/bitbucket dist builds (file-exists),
# doc-guard-map.sh (file-exists, REPO_ROOT_FILE_EXISTS_IDS), .env (settings-
# key, jira-env-keys — always repoRoot-relative per both scopes).
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/jira/dist" \
  "$fixtureRepo/scripts/bitbucket/dist" "$fixtureRepo/scripts/lib"
cp "$manifest_path" "$fixtureRepo/scripts/install/manifest.json"
: > "$fixtureRepo/scripts/jira/dist/index.js"
: > "$fixtureRepo/scripts/bitbucket/dist/index.js"
: > "$fixtureRepo/scripts/lib/doc-guard-map.sh"
cat > "$fixtureRepo/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_API_TOKEN=tok123
JIRA_PROJECT_KEY=HIMMEL
ENV

# ── case a: --help / status --help both list the status subcommand ────────
outHelp1=$("$node_bin" "$wizard" --help)
echo "$outHelp1" | grep -q 'status' || fail "case a: bare --help should list the status subcommand (got: $outHelp1)"
outHelp2=$("$node_bin" "$wizard" status --help)
echo "$outHelp2" | grep -q 'status' || fail "case a: 'status --help' should list the status subcommand (got: $outHelp2)"
echo "ok: case a — --help / status --help list the status subcommand"

# ── shared target + cache for cases b/e/f/g (one target, sequential runs) ──
targetBE="$work/target-be"
mkdir -p "$targetBE/.claude" "$targetBE/scripts/guardrails"
: > "$targetBE/scripts/guardrails/lib.sh"
# Deliberately NO .pre-commit-config.yaml — the known-missing enabled item
# for case b. settings.json carries wiring-statusline + claude-plugins-
# pluginSet green, but no hooks.PreToolUse markers (wiring-pretooluse red).
cat > "$targetBE/.claude/settings.json" <<'JSON'
{"statusLine":{"command":"bash foo.sh"},"enabledPlugins":{"foo@bar":true}}
JSON
cacheBE="$work/cache-be"; mkdir -p "$cacheBE"
write_cache "$cacheBE/install-profile.json" adopter project none "" inline "" lean

runStatusBE() {
  ( cd "$targetBE" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheBE")" HOME="$work/home" \
      "$node_bin" "$wizard" status "$@" )
}

# ── case b: known-missing enabled item -> red, exit 0, plain detail ────────
set +e
outB=$(runStatusBE --json); rcB=$?
set -e
[ "$rcB" -eq 0 ] || fail "case b: status should exit 0 regardless of reds (got rc=$rcB)"
echo "$outB" | jq -e '.items[] | select(.id=="pre-commit-hooks") | .severity == "red"' >/dev/null \
  || fail "case b: pre-commit-hooks should be red when .pre-commit-config.yaml is absent (got: $outB)"
echo "$outB" | jq -e '.items[] | select(.id=="pre-commit-hooks") | .detail == "no .pre-commit-config.yaml in this project"' >/dev/null \
  || fail "case b: pre-commit-hooks detail should plainly name the missing file, not imply a broken install (got: $outB)"
echo "ok: case b — known-missing enabled item (pre-commit-hooks) reads red, exit 0, plain detail"

# ── case f: no-prompt guard — stdin closed must not hang or error ──────────
set +e
( cd "$targetBE" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheBE")" HOME="$work/home" \
      "$node_bin" "$wizard" status < /dev/null ) >/dev/null; rcF=$?
set -e
[ "$rcF" -eq 0 ] || fail "case f: status with closed stdin should exit 0, not hang/error (got rc=$rcF)"
echo "ok: case f — closed stdin does not hang or error"

# ── case e: --json determinism ──────────────────────────────────────────────
outE1=$(runStatusBE --json)
outE2=$(runStatusBE --json)
[ "$outE1" = "$outE2" ] || fail "case e: two consecutive --json runs should be byte-identical"
echo "$outE1" | jq -e . >/dev/null || fail "case e: --json output should be valid JSON"
redCount=$(echo "$outE1" | jq '[.items[] | select(.severity=="red")] | length')
summaryRed=$(echo "$outE1" | jq '.summary.red')
[ "$redCount" -eq "$summaryRed" ] || fail "case e: summary.red ($summaryRed) should equal the count of severity==red items ($redCount)"
[ "$redCount" -gt 0 ] || fail "case e: fixture should contain at least one red item (got 0 — fixture drifted)"
idsActual=$(echo "$outE1" | jq -c '[.items[].id]')
idsSorted=$(echo "$outE1" | jq -c '[.items[].id] | sort')
[ "$idsActual" = "$idsSorted" ] || fail "case e: items should be sorted by id (got: $idsActual, sorted: $idsSorted)"
echo "ok: case e — --json byte-identical across runs, summary.red consistent, items sorted by id"

# ── case g: purity — beyond the one sanctioned first-derive write ─────────
# The runs above already exercised this target/cache pair repeatedly, so a
# state.json entry for it already exists (sanctioned first write already
# happened). Snapshot now, run once more, and confirm nothing changed.
snapBefore=$(snapshot_dir "$work")
runStatusBE --json >/dev/null
snapAfter=$(snapshot_dir "$work")
[ "$snapBefore" = "$snapAfter" ] || fail "case g: a run against an already-derived target should leave the fixture tree byte-identical"
echo "ok: case g — purity: a run against an already-derived target performs zero writes"

# ── case c: --items scoping + unknown id ───────────────────────────────────
targetC="$work/target-c"; mkdir -p "$targetC/.claude" "$targetC/scripts/guardrails"
: > "$targetC/scripts/guardrails/lib.sh"
cat > "$targetC/.claude/settings.json" <<'JSON'
{"statusLine":{"command":"bash foo.sh"},"enabledPlugins":{"foo@bar":true}}
JSON
cacheC="$work/cache-c"; mkdir -p "$cacheC"
write_cache "$cacheC/install-profile.json" adopter project none "" inline "" lean

outC=$( cd "$targetC" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HOME="$work/home" \
      "$node_bin" "$wizard" status --items pre-commit-hooks,jira-cli-dist-build --json )
count=$(echo "$outC" | jq '.items | length')
[ "$count" -eq 2 ] || fail "case c: --items should scope the run to exactly 2 items (got $count): $outC"
echo "$outC" | jq -e '[.items[].id] == ["jira-cli-dist-build","pre-commit-hooks"]' >/dev/null \
  || fail "case c: --items should scope the run to exactly the listed ids (got: $outC)"

set +e
errC=$( cd "$targetC" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HOME="$work/home" \
      "$node_bin" "$wizard" status --items bogus-unknown-id 2>&1 )
rcC=$?
set -e
[ "$rcC" -eq 2 ] || fail "case c: an unknown --items id should exit 2 (got rc=$rcC): $errC"
echo "$errC" | grep -q 'bogus-unknown-id' || fail "case c: the unknown-id error should name it (got: $errC)"
echo "ok: case c — --items scoping + unknown id exits 2 naming it"

set +e
errC2=$( cd "$targetC" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HOME="$work/home" \
      "$node_bin" "$wizard" status --items "," 2>&1 )
rcC2=$?
set -e
[ "$rcC2" -eq 2 ] || fail "case c: --items with no non-whitespace ids should exit 2 (got rc=$rcC2): $errC2"
echo "$errC2" | grep -qF 'requires at least one non-empty id' || fail "case c: the empty-items error should name the requirement (got: $errC2)"
echo "ok: case c — --items with only commas/whitespace exits 2"

# ── case d: missing install-profile cache -> exit 2, no state.json ────────
targetD="$work/target-d"; mkdir -p "$targetD"
cacheD="$work/cache-d-empty"; mkdir -p "$cacheD"

set +e
errD=$( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HOME="$work/home" \
      "$node_bin" "$wizard" status 2>&1 )
rcD=$?
set -e
[ "$rcD" -eq 2 ] || fail "case d: missing install-profile cache should exit 2 (got rc=$rcD): $errD"
echo "$errD" | grep -qF 'no himmelctl install profile found' || fail "case d: expected the 'no himmelctl install profile found' message (got: $errD)"
echo "$errD" | grep -qF 'run himmelctl install first' || fail "case d: expected the 'run himmelctl install first' message (got: $errD)"
[ ! -f "$cacheD/state.json" ] || fail "case d: state.json must NOT be created when the install-profile cache is missing"
echo "ok: case d — missing install-profile cache exits 2 with the exact message, no state.json created"

echo "PASS"
