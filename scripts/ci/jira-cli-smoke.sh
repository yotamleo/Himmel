#!/usr/bin/env bash
# jira-cli-smoke.sh — offline, secret-free smoke of the BUILT jira CLI (HIMMEL-3813).
# Builds scripts/jira, checks `--help` and `--list-commands`, then runs one op
# (`get`) against a local mock HTTP server that returns the same issue shape the
# unit suite's request mock does. No network, no credentials: every JIRA_* value
# is a dummy. Exits non-zero on any step failing.
#
# Test seams (scripts/ci/test-jira-cli-smoke.sh): JIRA_SMOKE_DIR is the package
# dir (default scripts/jira), JIRA_SMOKE_BUILD the build command (default
# `npm run build`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${JIRA_SMOKE_DIR:-$ROOT/scripts/jira}"
BUILD="${JIRA_SMOKE_BUILD:-npm run build}"
DIST="$DIR/dist/index.js"

fail() { echo "jira-cli-smoke: FAIL - $1" >&2; exit 1; }

cd "$DIR"
$BUILD >/dev/null || fail "build failed"
[ -f "$DIST" ] || fail "no dist/index.js after build"

help_out="$(node "$DIST" --help)" || fail "--help exited non-zero"
grep -q 'Jira CLI' <<< "$help_out" || fail "--help output lacks the CLI banner"
cmds="$(node "$DIST" --list-commands)" || fail "--list-commands exited non-zero"
grep -qx 'get' <<< "$cmds" || fail "--list-commands does not list get"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/jira-smoke.XXXXXX")" || fail "mktemp -d failed"
srv=""
cleanup() { [ -z "$srv" ] || kill "$srv" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ponytail: a loopback mock returns one canned issue, so this proves the CLI's
# startup, arg parsing and `get` rendering only, not Jira API drift; upgrade =
# a live-Jira smoke once CI holds a sandbox credential (no ticket yet).
node -e '
const http = require("http"), fs = require("fs");
const s = http.createServer((q, r) => {
  r.setHeader("content-type", "application/json");
  r.end(JSON.stringify({ key: "SMOKE-1", fields: { summary: "smoke summary",
    status: { name: "To Do" }, issuetype: { name: "Task" }, description: null, labels: [] } }));
});
s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[1], String(s.address().port)));
' "$TMP/port" &
srv=$!

tries=0
until [ -s "$TMP/port" ]; do
  tries=$((tries + 1))
  [ "$tries" -le 50 ] || fail "mock server did not start"
  sleep 0.1
done

out="$(JIRA_BASE_URL="http://127.0.0.1:$(cat "$TMP/port")" JIRA_EMAIL=smoke@example.invalid \
  JIRA_API_TOKEN=smoke-not-a-secret JIRA_PROJECT_KEY=SMOKE node "$DIST" get SMOKE-1 --short)" \
  || fail "mocked get exited non-zero"
grep -q 'SMOKE-1.*smoke summary' <<< "$out" || fail "mocked get output unexpected: $out"

echo "jira-cli-smoke: OK"
