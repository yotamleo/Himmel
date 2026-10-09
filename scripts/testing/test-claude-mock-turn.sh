#!/usr/bin/env bash
# Zero-cost full Claude turn against a scripted local API (HIMMEL-4411, epic HIMMEL-4409).
#
# headless-claude-ok: mock-backed — fake key, loopback-only netns, zero spend; the claude launch itself is in fakekey-claude.sh (HIMMEL-4411)
# Drives a REAL headless claude turn through scripts/testing/fakekey-claude.sh with
# FAKEKEY_MOCK_FIXTURE: the harness starts scripts/testing/mock-anthropic/ INSIDE
# the loopback-only network namespace and points ANTHROPIC_BASE_URL at it. The
# fixture scripts a text reply plus a Bash tool_use, then a final text after the
# tool_result. Asserts from the mock's request log, the transcript JSONL and the
# --debug log, never from the exit code:
#   M1 the final scripted text reaches the stdout envelope
#   M2 request log: the tool_result (with the command's real output) came back in
#      the SECOND /v1/messages request, and each scripted turn was served once
#   M3 transcript JSONL: assistant tool_use Bash + user tool_result round trip
#   M4 no request left the mock's own surface, and the run took no real host
#   U1-U4 the mock alone (no claude): SSE shape, count_tokens, 404 + log, ephemeral port
#   N1 the ANTHROPIC_* strip seam in native-auth-pin.sh (loopback-only keep)
# RED controls: R1 a fixture whose second turn never matches fails M1/M2; R2 the
# mock refuses to run without the sandbox; R3 the seam does NOT keep a
# non-loopback base URL.
#
# Not in the per-PR shell-unit shards (needs the pinned `claude` CLI and unshare
# -rn): the `claude-startup` CI job runs it, and run-shell-tests.sh SKIP_LISTs it.
# It lives beside 4410's suite under scripts/testing/, off the scripts/lib trust path.
#
# Usage: bash scripts/testing/test-claude-mock-turn.sh
# Exit: 0 all passed (a skipped case is named), 1 a case failed, 77 no claude CLI.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MOCK="$HERE/mock-anthropic/mock-anthropic.mjs"
FIX="$HERE/mock-anthropic/fixtures"
# shellcheck source=scripts/testing/fakekey-claude.sh
. "$HERE/fakekey-claude.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: no node on PATH"; exit 77; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
grepq() { grep -qE -- "$2" "$1" 2>/dev/null; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-mock-turn.XXXXXX") || exit 1
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

# jsq <file> <js-expression over `d`> — print the expression's value; no pipeline.
jsq() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=eval(process.argv[2]);process.stdout.write(String(v))' "$1" "$2" 2>/dev/null; }
# jsonl_q <file> <js-expression over `rows`>
jsonl_q() { node -e 'const rows=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>JSON.parse(l));const v=eval(process.argv[2]);process.stdout.write(String(v))' "$1" "$2" 2>/dev/null; }

# ---- U: the mock alone, on the host loopback (it binds 127.0.0.1 only) ----
echo "== U mock-anthropic alone =="
UPORT="$WORK/u.port"; ULOG="$WORK/u.log"
node "$MOCK" --fixture "$FIX/bash-roundtrip.json" --port-file "$UPORT" --log "$ULOG" &
MOCK_PID=$!
i=0; while [ ! -s "$UPORT" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ -s "$UPORT" ] && [[ "$(cat "$UPORT")" =~ ^[0-9]+$ ]]; then pass "U4 ephemeral port written to the port file ($(cat "$UPORT"))"; else fail "U4 no port file"; fi
BASE="http://127.0.0.1:$(cat "$UPORT" 2>/dev/null)"
node -e '
const base=process.argv[1];
(async()=>{
  const r=await fetch(base+"/v1/messages?beta=true",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({model:"m",stream:true,messages:[{role:"user",content:"hi"}]})});
  const t=await r.text();
  const ev=[...t.matchAll(/^event: (.+)$/gm)].map(m=>m[1]);
  process.stdout.write(JSON.stringify({ct:r.headers.get("content-type"),ev,tool:t.includes("input_json_delta"),stop:t.includes("\"stop_reason\":\"tool_use\"")}));
})()' "$BASE" >"$WORK/u-sse.json" 2>/dev/null
want='["message_start","content_block_start","content_block_delta","content_block_stop","content_block_start","content_block_delta","content_block_stop","message_delta","message_stop"]'
if [ "$(jsq "$WORK/u-sse.json" 'JSON.stringify(d.ev)')" = "$want" ] && [ "$(jsq "$WORK/u-sse.json" 'd.tool&&d.stop')" = true ] && grepq "$WORK/u-sse.json" 'text/event-stream'; then
  pass "U1 /v1/messages streams message_start..message_stop with tool_use + input_json_delta + stop_reason"
else fail "U1 SSE shape wrong: $(cat "$WORK/u-sse.json" 2>/dev/null)"; fi
CT=$(node -e 'fetch(process.argv[1]+"/v1/messages/count_tokens",{method:"POST",body:"{}"}).then(async r=>process.stdout.write(r.status+" "+await r.text()))' "$BASE" 2>/dev/null)
if [ "$CT" = '200 {"input_tokens":1}' ]; then pass "U2 count_tokens answers"; else fail "U2 count_tokens: $CT"; fi
NF=$(node -e 'fetch(process.argv[1]+"/v1/nope",{method:"GET"}).then(r=>process.stdout.write(String(r.status)))' "$BASE" 2>/dev/null)
if [ "$NF" = 404 ] && [ "$(jsonl_q "$ULOG" 'rows.some(r=>r.path==="/v1/nope"&&r.status===404)')" = true ]; then pass "U3 unknown path: 404 and logged"; else fail "U3 404/log (status=$NF)"; fi
kill "$MOCK_PID" 2>/dev/null; MOCK_PID=""

# ---- N: the ANTHROPIC_* strip seam ----
echo "== N native-auth-pin test seam =="
# shellcheck source=scripts/lib/native-auth-pin.sh
# shellcheck disable=SC2030,SC2031  # each case runs in its own subshell on purpose
n_run() { # n_run <base-url> [iso] — what survives native_auth_pin_env with the seam on; iso = inside a loopback-only netns
  local pre=()
  [ "${2:-}" = iso ] && pre=(unshare -rn)
  # shellcheck disable=SC2016  # $1/${…} expand in the inner shell on purpose
  ANTHROPIC_BASE_URL="$1" ANTHROPIC_API_KEY=k ANTHROPIC_MODEL=m CLAUDE_CODE_USE_BEDROCK=1 NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK=1 \
    "${pre[@]}" bash -c '. "$1/scripts/lib/native-auth-pin.sh"
    native_auth_pin_env
    printf "url=%s key=%s model=%s bedrock=%s\n" "${ANTHROPIC_BASE_URL-unset}" "${ANTHROPIC_API_KEY-unset}" "${ANTHROPIC_MODEL-unset}" "${CLAUDE_CODE_USE_BEDROCK-unset}"' _ "$REPO"
}
if fakekey_sandbox_available; then
  if [ "$(n_run http://127.0.0.1:4242 iso)" = "url=http://127.0.0.1:4242 key=k model=unset bedrock=unset" ]; then
    pass "N1 seam keeps ONLY base URL + key, only for a loopback URL, only in a loopback-only netns; every other ANTHROPIC_*/USE_ var still stripped"
  else fail "N1 seam result: $(n_run http://127.0.0.1:4242 iso)"; fi
  if [ "$(n_run https://api.anthropic.com iso)" = "url=unset key=unset model=unset bedrock=unset" ]; then
    pass "R3 seam does not keep a non-loopback base URL"
  else fail "R3 seam kept a real host: $(n_run https://api.anthropic.com iso)"; fi
else skip "N1/R3 need unshare -rn (the seam is honoured only in a loopback-only netns)"; fi
# R4 (F1): the seam variable alone must not keep the key. With any real NIC present it is ignored.
if [ "$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | grep -vc '^lo$')" -gt 0 ]; then
  if [ "$(n_run http://127.0.0.1:4242)" = "url=unset key=unset model=unset bedrock=unset" ]; then
    pass "R4 seam ignored when a non-loopback interface exists (base URL and key still stripped)"
  else fail "R4 seam honoured on a networked host: $(n_run http://127.0.0.1:4242)"; fi
else skip "R4 host has only lo (nothing to refuse on)"; fi
# shellcheck disable=SC2031
n_default() { # the pin with NO seam variable, loopback URL exported (a prefix assignment would revert after the call and prove nothing)
  ( . "$REPO/scripts/lib/native-auth-pin.sh"
    export ANTHROPIC_BASE_URL=http://127.0.0.1:1 ANTHROPIC_API_KEY=k
    native_auth_pin_env
    printf '%s/%s' "${ANTHROPIC_BASE_URL-unset}" "${ANTHROPIC_API_KEY-unset}" )
}
if [ "$(n_default)" = unset/unset ]; then
  pass "N1 without the seam variable the pin strips everything (unchanged default)"
else fail "N1 default strip regressed"; fi

# ---- the real turn ----
command -v claude >/dev/null 2>&1 || { echo "SKIP: no claude CLI on PATH (turn cases not run)"; [ "$failures" = 0 ] && exit 77; exit 1; }
if ! fakekey_sandbox_available; then
  echo "FAIL: unshare -rn with loopback is unavailable here, and the harness refuses to run unsandboxed."
  echo "      (Ubuntu 24.04: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0)"
  exit 1
fi
CLAUDE_VER=$(claude --version 2>&1 | head -1)
echo "claude: $CLAUDE_VER"
PIN=$(sed -n "s/^ *CLAUDE_CLI_VERSION: '\([0-9][0-9.]*\)'.*/\1/p" "$REPO/.github/workflows/ci.yml" | sed -n 1p)
if [ -z "$PIN" ]; then fail "no pinned claude-code version found in ci.yml (the wire-format guard would be vacuous)"
elif [[ "$CLAUDE_VER" == "$PIN "* ]]; then pass "pin: claude $PIN matches the ci.yml pin"
elif [ -n "${CI:-}" ]; then fail "pin: claude '$CLAUDE_VER' != ci.yml pin $PIN (a wire-format change must fail loudly in CI)"
else skip "pin: local claude '$CLAUDE_VER' differs from the ci.yml pin $PIN (enforced in CI)"; fi

TURN_ARGS=(--allowedTools "Bash(echo:*)")

echo "== turn: text + Bash tool_use + tool_result round trip =="
FAKEKEY_MOCK_FIXTURE="$FIX/bash-roundtrip.json" fakekey_run "$WORK/turn" "${TURN_ARGS[@]}"
RLOG="$WORK/turn/mock.log"
OUT="$WORK/turn/out.json"
if [ "$(jsq "$OUT" 'd.is_error===false && String(d.result).includes("MOCK-TURN-2 done.")')" = true ]; then pass "M1 final scripted text is the run's result"; else fail "M1 result: $(head -c 400 "$OUT" 2>/dev/null) err: $(head -c 300 "$WORK/turn/err.txt" 2>/dev/null)"; fi
if [ -s "$RLOG" ] && [ "$(jsonl_q "$RLOG" 'rows.filter(r=>r.path==="/v1/messages"&&r.turn===0).length===1&&rows.filter(r=>r.path==="/v1/messages"&&r.turn===1).length===1')" = true ]; then
  pass "M2 each scripted turn served exactly once"
else fail "M2 turn counts in $RLOG"; fi
if [ -s "$RLOG" ] && [ "$(jsonl_q "$RLOG" 'const t=rows.find(r=>r.turn===1);t.body.messages.some(m=>m.role==="user"&&Array.isArray(m.content)&&m.content.some(c=>c.type==="tool_result"&&JSON.stringify(c.content).includes("mock-tool-output-4411")))')" = true ]; then
  pass "M2 second request carried the tool_result with the command's real output"
else fail "M2 no tool_result round trip in the request log"; fi
TJ=$(find "$WORK/turn/cfg/projects" -name '*.jsonl' 2>/dev/null | sed -n 1p)
if [ -n "$TJ" ] && [ "$(jsonl_q "$TJ" 'const s=JSON.stringify(rows);s.includes("\"type\":\"tool_use\"")&&s.includes("\"name\":\"Bash\"")&&s.includes("\"type\":\"tool_result\"")&&s.includes("mock-tool-output-4411")')" = true ]; then
  pass "M3 transcript JSONL holds the Bash tool_use and its tool_result"
else fail "M3 transcript missing (found: ${TJ:-none})"; fi
if [ -s "$RLOG" ] && [ "$(jsonl_q "$RLOG" 'rows.every(r=>r.path==="/v1/messages"||r.path==="/v1/messages/count_tokens"||r.status===404)')" = true ]; then
  pass "M4 every request hit the mock (paths logged: $(jsonl_q "$RLOG" '[...new Set(rows.map(r=>r.path))].join(",")'))"
else fail "M4 request log odd"; fi
mrc=$(cat "$WORK/turn/rc" 2>/dev/null)
if [[ "$mrc" =~ ^[0-9]+$ ]] && [ "$mrc" != 124 ]; then pass "M4 run ended before the timeout"; else fail "M4 timeout/no rc ($mrc)"; fi

echo "== H claude-headless.sh end to end: seam + fake bank, zero spend =="
# The real chokepoint wrapper runs claude against the mock. bank-preflight is NOT
# edited or stubbed: its own cache/ledger/fleet seams are pointed at hermetic
# files (a PROCEED cache for a synthetic account), the same way
# scripts/lib/test-claude-headless.sh does. ANTHROPIC_DEFAULT_SONNET_MODEL is a canary the pin
# must still strip; the base URL + key survive only through the loopback seam.
if command -v jq >/dev/null 2>&1; then
  H="$WORK/h"; mkdir -p "$H/home" "$H/cfg" "$H/wt" "$H/reg" "$H/slots"
  printf '%s' '{"oauthAccount":{"accountUuid":"uuid-mock-turn-test"}}' >"$H/home/.claude.json"
  printf '#!/usr/bin/env bash\ntrue\n' >"$H/no-fleet-ps.sh"; chmod +x "$H/no-fleet-ps.sh"
  # CLAUDE_CODE_* in the process env is a Claude Code marker: with a seam set and no claude ancestor
  # (CI), bank-preflight's guard refuses (HIMMEL-3914). Claude reads these from its own settings env.
  printf '%s' '{"env":{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","CLAUDE_CODE_MAX_RETRIES":"0"}}' >"$H/cfg/settings.json"
  node -e '
const art=process.argv[1];
require("fs").writeFileSync(process.argv[2],JSON.stringify({turns:[
 {reply:[{type:"text",text:"H-TURN-1"},{type:"tool_use",name:"Bash",input:{command:"echo headless-ok > "+art,description:"write the artifact"}}]},
 {match:"tool_result",reply:{type:"text",text:"H-TURN-2 done."}}]}))' "$H/wt/artifact.txt" "$H/fixture.json"
  cat >"$H/run.sh" <<'HEOF'
#!/bin/sh
# inside the netns: bank cache for the synthetic account, mock, then the wrapper
. "$REPO/scripts/lib/usage-cache-identity.sh"
printf '{"account":"%s","five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' \
  "$(current_account_hash)" "$(date +%s)" >"$H/bank-cache.json"
ip link set lo up || exit 1
node "$MOCK" --fixture "$H/fixture.json" --port-file "$H/port" --log "$H/mock.log" & m=$!
i=0; while [ ! -s "$H/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$H/port" ] || { kill "$m" 2>/dev/null; exit 97; }
ANTHROPIC_BASE_URL="http://127.0.0.1:$(cat "$H/port")"; export ANTHROPIC_BASE_URL
printf 'say hi' | bash "$REPO/scripts/lib/claude-headless.sh" --role mock-turn --model sonnet --ticket HIMMEL-4411 \
  --worktree "$H/wt" --artifact "$H/wt/artifact.txt" --permission-mode default --max-turns 4 \
  --allowed-tools 'Bash' >"$H/headless.out" 2>"$H/headless.err"
echo $? >"$H/headless.rc"
kill "$m" 2>/dev/null; wait "$m" 2>/dev/null
HEOF
  # headless-claude-ok: mock-backed — fake key, loopback-only netns, zero spend; bank-preflight faked through its own cache seams (HIMMEL-4411)
  env -i PATH="$(dirname "$(command -v claude)"):$(dirname "$(command -v node)"):/usr/local/bin:/usr/bin:/bin" \
    HOME="$H/home" CLAUDE_CONFIG_DIR="$H/cfg" REPO="$REPO" MOCK="$MOCK" H="$H" \
    ANTHROPIC_API_KEY="$FAKEKEY_KEY" ANTHROPIC_DEFAULT_SONNET_MODEL=canary-model-must-be-stripped \
    NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK=1 \
    HIMMEL_REGISTRY_DIR="$H/reg" HIMMEL_FLEET_SLOTS="$H/slots" HIMMEL_FLEET_CAP=4 CADENCE_BANK_LANE=native \
    CADENCE_BANK_CACHE="$H/bank-cache.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$H/bank-ledger.jsonl" \
    FLEET_PS_CMD="$H/no-fleet-ps.sh" \
    unshare -rn timeout 60 sh "$H/run.sh" >"$H/outer.out" 2>&1 # gnu-ok: unshare -rn is Linux-only, so this whole case is
  if grepq "$H/outer.out" "cannot read the claude session's cwd" || grepq "$H/headless.err" "cannot read the claude session's cwd"; then
    # Run from inside a Claude Code session, bank-preflight's seam guard (HIMMEL-3914) walks to
    # the session and cannot read its cwd across the user namespace. CI has no claude ancestor.
    skip "H run from inside a Claude Code session: bank-preflight's seam guard refuses across the netns (runs in CI, or detached from the session)"
  else
  if [ "$(cat "$H/wt/artifact.txt" 2>/dev/null)" = headless-ok ]; then pass "H1 wrapper run on the mock completed the Bash tool call (artifact written)"; else fail "H1 no artifact ($(head -c 300 "$H/headless.err" 2>/dev/null) $(head -c 300 "$H/outer.out" 2>/dev/null))"; fi
  if [ -s "$H/mock.log" ] && [ "$(jsonl_q "$H/mock.log" 'rows.filter(r=>r.path==="/v1/messages").length>=2&&rows.filter(r=>r.path==="/v1/messages").every(r=>r.body&&r.body.model&&r.body.model!=="canary-model-must-be-stripped")')" = true ]; then
    pass "H2 the pin stripped the ANTHROPIC_DEFAULT_SONNET_MODEL canary (--model sonnet resolved to a real model) while the seam kept the loopback base URL (mock saw the turns)"
  else fail "H2 request log missing or the canary model leaked"; fi
  fi
else
  skip "H no jq on PATH (claude-headless.sh needs it)"
fi

echo "== R1 a fixture whose second turn never matches fails the M1/M2 checks =="
FAKEKEY_MOCK_FIXTURE="$FIX/bash-roundtrip-broken.json" fakekey_run "$WORK/r1" "${TURN_ARGS[@]}"
if [ "$(jsq "$WORK/r1/out.json" 'String(d.result).includes("MOCK-TURN-2 done.")')" = false ] \
  && [ "$(jsonl_q "$WORK/r1/mock.log" 'rows.filter(r=>r.turn===0).length===1')" = true ] \
  && [ "$(jsonl_q "$WORK/r1/mock.log" 'rows.filter(r=>r.turn===1).length===1')" = false ]; then
  pass "R1 broken fixture: the assertions that passed above fail here"
else fail "R1 the checks passed against a broken fixture (vacuous)"; fi

echo "== R2 the mock never runs unsandboxed =="
FAKEKEY_SANDBOX=0 FAKEKEY_MOCK_FIXTURE="$FIX/bash-roundtrip.json" fakekey_run "$WORK/r2" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$WORK/r2/rc" ]; then pass "R2 FAKEKEY_MOCK_FIXTURE with FAKEKEY_SANDBOX=0 refused"; else fail "R2 not refused (rc=$rc)"; fi

echo
if [ "$failures" = 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: $failures"
exit 1
