#!/usr/bin/env bash
# test-jira-cli-smoke.sh — jira-cli-smoke.sh must FAIL on a broken build or a
# broken dist and PASS on a working CLI (HIMMEL-3813). Hermetic: fixture dirs
# stand in for scripts/jira; the real-CLI case runs only when its deps exist.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="$ROOT/scripts/ci/jira-cli-smoke.sh"
fails=0
ok() { echo "PASS - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

[ -f "$SMOKE" ] || { echo "FAIL - $SMOKE missing (the fail-cases below would pass vacuously)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/jira-smoke-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ponytail: fixture dists stand in for the real CLI (the fail-cases prove only the
# script's own exit paths), upgrade = the real-CLI case below, which CI runs via
# the jira-cli-smoke job against an actual build.
mkfix() {  # mkfix <name> <index.js body> -> fixture dir with dist/index.js
  mkdir -p "$TMP/$1/dist"
  printf '%s\n' "$2" > "$TMP/$1/dist/index.js"
}

# A build that fails must fail the smoke (a broken tsc build never ships green).
mkfix badbuild 'process.exit(0)'
if JIRA_SMOKE_DIR="$TMP/badbuild" JIRA_SMOKE_BUILD='false' bash "$SMOKE" >/dev/null 2>&1; then
  bad "failing build command passed the smoke"
else ok "failing build command fails the smoke"; fi

# A dist that builds but crashes on --help must fail.
mkfix crashes 'process.exit(1)'
if JIRA_SMOKE_DIR="$TMP/crashes" JIRA_SMOKE_BUILD=':' bash "$SMOKE" >/dev/null 2>&1; then
  bad "crashing dist passed the smoke"
else ok "crashing dist fails the smoke"; fi

# A dist that answers --help but cannot run the mocked op must fail.
mkfix nohelpop 'if (process.argv.includes("--help")) { console.log("Jira CLI"); process.exit(0); } process.exit(1);'
if JIRA_SMOKE_DIR="$TMP/nohelpop" JIRA_SMOKE_BUILD=':' bash "$SMOKE" >/dev/null 2>&1; then
  bad "dist failing the mocked op passed the smoke"
else ok "dist failing the mocked op fails the smoke"; fi

# The real CLI passes (needs scripts/jira deps installed; CI installs them first).
if [ -d "$ROOT/scripts/jira/node_modules" ]; then
  if bash "$SMOKE" >/dev/null 2>&1; then ok "real jira CLI passes the smoke"; else bad "real jira CLI failed the smoke"; fi
else
  echo "SKIP - real jira CLI case (scripts/jira/node_modules absent)"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
