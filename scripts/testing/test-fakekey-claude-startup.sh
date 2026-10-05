#!/usr/bin/env bash
# Credential-free Claude startup suite (HIMMEL-4410, epic HIMMEL-4409).
#
# Drives a REAL `claude` CLI through scripts/testing/fakekey-claude.sh: fake key,
# scratch config dir, loopback-only network namespace, no model turn. Asserts
# from the --debug log and on-disk artifacts, never from the exit code:
#   S1 a profile's --mcp-config servers connect and expose tools (a FAKE local
#      MCP server stands in for qmd, so CI needs no qmd)
#   S2 a plugin's SessionStart hook runs (marker file) under a scrubbed env
#   S3 a profile's resolved plugin map and gate rules reach the session
#   S4 the first-turn network surface is sealed ([Bootstrap] never hits a host)
# RED controls prove the checks can fail: R1 the sandbox is what blocks the real
# host, R2 a broken MCP fixture fails S1's assertion, R3 a non-loopback base URL
# is refused.
#
# Not in the per-PR shell-unit shards (it needs the pinned `claude` CLI): the
# `claude-startup` CI job runs it, and run-shell-tests.sh SKIP_LISTs it.
#
# Usage: bash scripts/testing/test-fakekey-claude-startup.sh
# Exit: 0 all passed (a skipped case is named), 1 a case failed, 77 no claude CLI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/testing/fakekey-claude.sh
. "$HERE/fakekey-claude.sh"

command -v claude >/dev/null 2>&1 || { echo "SKIP: no claude CLI on PATH"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: no node on PATH"; exit 77; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
# grepq <file> <ERE> — no pipeline (pipefail trap, HIMMEL-1430).
grepq() { grep -qE -- "$2" "$1" 2>/dev/null; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fakekey-startup.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

if ! fakekey_sandbox_available; then
  echo "FAIL: unshare -rn with loopback is unavailable here, and the harness refuses to run unsandboxed."
  echo "      (Ubuntu 24.04: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0)"
  exit 1
fi
echo "claude: $(claude --version 2>&1 | head -1)"

# mcp_config <file> <mode> <name>... — every named server is the fake fixture.
mcp_config() {
  local file="$1" mode="$2" name sep='' ; shift 2
  printf '{"mcpServers":{' >"$file"
  for name in "$@"; do
    printf '%s"%s":{"type":"stdio","command":"node","args":["%s"],"env":{"FAKE_MCP_MODE":"%s"}}' \
      "$sep" "$name" "$HERE/fixtures/fake-mcp-server.mjs" "$mode" >>"$file"
    sep=','
  done
  printf '}}\n' >>"$file"
}

# assert_mcp_connected <debuglog> <name>... — each server connected AND has tools.
assert_mcp_connected() {
  local log="$1" name; shift
  for name in "$@"; do
    grepq "$log" "MCP server \"$name\": Successfully connected" || return 1
    grepq "$log" "MCP server \"$name\": Connection established with capabilities: .*\"hasTools\":true" || return 1
  done
}

PROFILE=leg-impl
SERVERS=$(node "$REPO/scripts/lanes/plugin-profiles.mjs" "$PROFILE" --mcp-servers | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).join(" "))')
PROFILE_CFG="$WORK/profile.json"
node "$REPO/scripts/lanes/plugin-profiles.mjs" "$PROFILE" >"$PROFILE_CFG"
# shellcheck disable=SC2086  # SERVERS is a space-separated list of simple names
mcp_config "$WORK/mcp-good.json" ok $SERVERS
# shellcheck disable=SC2086
mcp_config "$WORK/mcp-broken.json" broken $SERVERS
echo "profile $PROFILE: mcp servers [$SERVERS]"

echo "== loopback guard (R3) =="
FAKEKEY_BASE_URL=https://api.anthropic.com fakekey_run "$WORK/r3" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$WORK/r3/rc" ]; then pass "R3 non-loopback ANTHROPIC_BASE_URL refused before claude ran"; else fail "R3 non-loopback URL not refused (rc=$rc)"; fi
FAKEKEY_SANDBOX=2 fakekey_run "$WORK/r3b" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$WORK/r3b/rc" ]; then pass "R3 FAKEKEY_SANDBOX other than 0/1 refused (fail closed)"; else fail "R3 bad FAKEKEY_SANDBOX not refused (rc=$rc)"; fi
FAKEKEY_BASE_URL='http://localhost:9@api.anthropic.com' fakekey_run "$WORK/r3c" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$WORK/r3c/rc" ]; then pass "R3 userinfo URL (real host after @) refused"; else fail "R3 userinfo URL not refused (rc=$rc)"; fi
FAKEKEY_EXTRA_ENV='ANTHROPIC_BASE_URL=https://api.anthropic.com' fakekey_run "$WORK/r3d" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$WORK/r3d/rc" ]; then pass "R3 FAKEKEY_EXTRA_ENV cannot override a reserved variable"; else fail "R3 reserved override not refused (rc=$rc)"; fi
(cd "$WORK" && fakekey_run rel-out --mcp-config "$WORK/mcp-good.json" --strict-mcp-config)
if [ -s "$WORK/rel-out/rc" ] && [ -n "$(fakekey_debuglog "$WORK/rel-out")" ]; then pass "R3 relative outdir resolves to absolute (artifacts land under it)"; else fail "R3 relative outdir broke the run's artifacts"; fi

echo "== startup run (leg-impl config, fixture plugin, scrubbed env) =="
MARK="$WORK/marker"; mkdir -p "$MARK"
LEAK_CANARY="canary-$$-must-not-leak"
ANTHROPIC_AUTH_TOKEN="$LEAK_CANARY" CLAUDE_CODE_OAUTH_TOKEN="$LEAK_CANARY" \
  FAKEKEY_EXTRA_ENV="FAKEKEY_MARKER_DIR=$MARK" \
  fakekey_run "$WORK/main" --mcp-config "$WORK/mcp-good.json" --strict-mcp-config \
  --settings "$PROFILE_CFG" --plugin-dir "$HERE/fixtures/startup-plugin"
LOG=$(fakekey_debuglog "$WORK/main")
if [ -z "$LOG" ]; then fail "main run left no debug log (cat $WORK/main/err.txt)"; head -5 "$WORK/main/err.txt" 2>/dev/null; fi

echo "== S1 mcp servers connect with tools =="
# shellcheck disable=SC2086
if [ -n "$LOG" ] && assert_mcp_connected "$LOG" $SERVERS; then pass "S1 [$SERVERS] connected, hasTools"; else fail "S1 mcp servers did not connect"; fi

echo "== S2 plugin + hook =="
if [ -f "$MARK/session-start-hook-ran" ]; then pass "S2 fixture plugin SessionStart hook ran (marker on disk)"; else fail "S2 hook marker absent"; fi
# Literal compares (-F): $HOME may hold regex metacharacters; rc 1 = no match, rc 2 = grep error.
grep -qF -- "$LEAK_CANARY" "$MARK/hook-env.txt" 2>/dev/null; canary_rc=$?
grep -qxF -- "HOME=$HOME" "$MARK/hook-env.txt" 2>/dev/null; home_rc=$?
if [ -f "$MARK/hook-env.txt" ] && [ "$canary_rc" = 1 ] && [ "$home_rc" = 1 ]; then
  pass "S2 hook env carries no operator token and a scratch HOME"
else fail "S2 operator env leaked into the session"; fi
if [ -f "$MARK/hook-env.txt" ] && grepq "$MARK/hook-env.txt" "^ANTHROPIC_API_KEY=$FAKEKEY_KEY\$" \
  && grepq "$MARK/hook-env.txt" "^CLAUDE_CONFIG_DIR=$WORK/main/cfg\$"; then
  pass "S2 hook sees the fake key and the scratch CLAUDE_CONFIG_DIR"
else fail "S2 hook env lacks the fake key / scratch config dir"; fi
# shellcheck disable=SC2015
[ -n "$LOG" ] && grepq "$LOG" 'Registered [1-9][0-9]* hooks from' && pass "S2 debug log: plugin hooks registered" || fail "S2 no 'Registered N hooks' line"

echo "== S3 profile resolution =="
off=$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).enabledPlugins;for(const[k,v]of Object.entries(m))if(v===false)console.log(k)' "$PROFILE_CFG")
missing=0; n=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  n=$((n + 1))
  grepq "$LOG" "disabled plugin $id" || { missing=$((missing + 1)); echo "    not seen disabled: $id"; }
done <<<"$off"
if [ "$n" -gt 0 ] && [ "$missing" = 0 ]; then pass "S3 all $n plugins the $PROFILE profile turns off were seen disabled"; else fail "S3 $missing of $n disabled plugins unseen"; fi
if grepq "$LOG" "Adding [1-9][0-9]* allow rule\(s\) to destination 'flagSettings'"; then pass "S3 profile gate allow rules applied via --settings"; else fail "S3 no flagSettings allow-rule line"; fi

echo "== S4 sealed network surface =="
if grepq "$LOG" '\[Bootstrap\] Skipped: Nonessential traffic disabled' && ! grepq "$LOG" 'Bootstrap\] Fetch'; then
  pass "S4 no [Bootstrap] fetch attempted"
else fail "S4 [Bootstrap] was not skipped"; fi
if grepq "$LOG" 'API error \(attempt 1/1\)'; then pass "S4 doomed API call capped at one attempt (MAX_RETRIES=0)"; else fail "S4 retry cap not visible"; fi
main_rc=$(cat "$WORK/main/rc" 2>/dev/null)
if [[ "$main_rc" =~ ^[0-9]+$ ]] && [ "$main_rc" != 124 ]; then pass "S4 run ended before the timeout"; else fail "S4 run hit the timeout"; fi

echo "== R2 broken MCP fixture fails the S1 assertion =="
fakekey_run "$WORK/r2" --mcp-config "$WORK/mcp-broken.json" --strict-mcp-config --settings "$PROFILE_CFG"
LOG2=$(fakekey_debuglog "$WORK/r2")
# shellcheck disable=SC2086
if [ -n "$LOG2" ] && ! assert_mcp_connected "$LOG2" $SERVERS; then pass "R2 broken fixture: assertion fails as it must"; else fail "R2 assertion passed against a broken server"; fi

echo "== R4 a run without the profile fails the S3 and S2 assertions =="
mkdir -p "$WORK/marker4"
FAKEKEY_EXTRA_ENV="FAKEKEY_MARKER_DIR=$WORK/marker4" fakekey_run "$WORK/r4" --mcp-config "$WORK/mcp-good.json" --strict-mcp-config
LOG5=$(fakekey_debuglog "$WORK/r4")
first_off=$(printf '%s\n' "$off" | sed -n 1p)
if [ -n "$LOG5" ] && ! grepq "$LOG5" "disabled plugin $first_off" && ! grepq "$LOG5" "to destination 'flagSettings'" && [ ! -e "$WORK/marker4/session-start-hook-ran" ]; then
  pass "R4 no --settings / --plugin-dir: no disabled-plugin line, no gate rules, no hook marker"
else fail "R4 the S2/S3 evidence appeared without its cause"; fi

echo "== R1 the sandbox is what blocks the real host =="
FAKEKEY_NONESSENTIAL=0 fakekey_run "$WORK/r1s" --mcp-config "$WORK/mcp-good.json" --strict-mcp-config
LOG3=$(fakekey_debuglog "$WORK/r1s")
if [ -n "$LOG3" ] && grepq "$LOG3" 'Bootstrap\] Fetch failed: (EADDRNOTAVAIL|ENETUNREACH|ECONNREFUSED)' && ! grepq "$LOG3" 'Fetch failed: 401'; then
  pass "R1 sandboxed: [Bootstrap] cannot connect (no 401 from a real host)"
else fail "R1 sandboxed run did not show a blocked [Bootstrap]"; fi
FAKEKEY_SANDBOX=0 FAKEKEY_NONESSENTIAL=0 fakekey_run "$WORK/r1u" --mcp-config "$WORK/mcp-good.json" --strict-mcp-config
LOG4=$(fakekey_debuglog "$WORK/r1u")
if [ -n "$LOG4" ] && grepq "$LOG4" 'Bootstrap\] Fetch failed: 401'; then
  pass "R1 control: unsandboxed, the same run reaches a real host (401)"
else skip "R1 control inconclusive (no route to a real host from this machine; the sandboxed half above still stands)"; fi

echo
if [ "$failures" = 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: $failures"
exit 1
