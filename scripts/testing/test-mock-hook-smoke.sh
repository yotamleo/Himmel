#!/usr/bin/env bash
# Mock-backed print-mode claude leg of scripts/codex/hook-smoke-demo.sh (HIMMEL-4412, epic HIMMEL-4409).
#
# MOCK-BACKED: the model is scripts/testing/mock-anthropic, so this proves only that a
# REAL claude session starts in a throwaway clone of this checkout, runs the scripted
# tool calls and stops with the project hook chain firing and ZERO hook failures. It is
# NOT evidence of real-model behaviour; hook-smoke-demo.sh is the live, bank-spending twin.
# headless-claude-ok: mock-backed — fake key, loopback-only netns, zero spend; the claude launch is fakekey-claude.sh (HIMMEL-4411)
#
# A hook that stops running fails OPEN and nothing in the transcript says so, which is why
# the smoke asserts a positive: the hook chain's own debug lines for the tool calls, not
# only the absence of a banner. Asserts are on the request log, the debug log and the
# stdout envelope, never the exit code alone:
#   P1 the run ended cleanly with the scripted final text (session started and stopped)
#   P2 request log: the Bash tool_result carries the clone's HEAD sha, and the Read
#      tool_result carries the runner-written token (the tools really ran)
#   P3 zero hook-failure banners in stdout, stderr and the --debug log
#   P4 positive control: the debug log shows PreToolUse hooks executing for the tool calls
# RED control (R1): the same run in a clone whose block-destructive-commands.sh hook was
# replaced with `exit 1` (a hook that fails): the banner assertion (P3) must fire.
#
# Not in the per-PR shell-unit shards (needs the pinned `claude` CLI and unshare -rn): the
# `claude-startup` CI job runs it; run-shell-tests.sh SKIP_LISTs it.
#
# Usage: bash scripts/testing/test-mock-hook-smoke.sh
# Exit: 0 all passed, 1 a case failed, 77 a prerequisite is missing (named).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/testing/fakekey-claude.sh
. "$HERE/fakekey-claude.sh"

for need in node jq git claude; do
  command -v "$need" >/dev/null 2>&1 || { echo "SKIP: no $need on PATH"; exit 77; }
done
fakekey_sandbox_available || { echo "FAIL: unshare -rn with loopback unavailable; refusing to run unsandboxed"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mock-hook-smoke.XXXXXX") || exit 1
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap
cleanup() { # a hook child can still be writing as the run ends, so retry once
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK" 2>/dev/null || { sleep 1; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
}
trap cleanup EXIT
WORK=$(cd -P "$WORK" && pwd -P)

# Same banner shape hook-smoke-demo.sh scans for.
BANNER_RE='hook (\(failed\)|failed|error|timed out)|hook timed out|hook exited with code|non-blocking status code|Hook [A-Za-z:]+ \([A-Za-z]+\) (error|failed|timed out)'

jsonl_q() { node -e 'const rows=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>JSON.parse(l));process.stdout.write(String(eval(process.argv[2])))' "$1" "$2" 2>/dev/null; }
jsq() { node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(eval(process.argv[2])))' "$1" "$2" 2>/dev/null; }

# make_demo <dir> — a disposable clone of HEAD, instruction files removed, runner-written token file.
make_demo() {
  git clone --local --no-hardlinks --quiet "$REPO" "$1" || { echo "FAIL: clone failed"; exit 1; }
  find "$1" \( -name 'CLAUDE.md' -o -name 'CLAUDE.local.md' -o -name 'AGENTS.md' -o -name 'AGENTS.local.md' \) -type f -delete 2>/dev/null
  rm -rf "$1/.claude/rules"
  printf '# DEMO PROJECT\n\nSMOKE-TOKEN: %s\n' "$TOKEN" >"$1/DEMO-PROJECT.md"
}
TOKEN="smk-mock-$$-${RANDOM}${RANDOM}"

# run_demo <demo-dir> — the scripted session, run IN the clone (fakekey_run's cwd is its outdir).
run_demo() {
  local d=$1 sha
  sha=$(git -C "$d" rev-parse --short HEAD)
  node -e '
const [fx,sha,tok,doc]=process.argv.slice(1);
require("fs").writeFileSync(fx,JSON.stringify({turns:[
 {reply:[{type:"text",text:"MOCK-HOOK-1"},{type:"tool_use",name:"Bash",input:{command:"git -C . rev-parse --short HEAD",description:"read-only smoke"}}]},
 {match:"tool_result",reply:{type:"tool_use",name:"Read",input:{file_path:doc}}},
 {match:"tool_result",reply:{type:"text",text:"DONE "+sha+" "+tok}}]}))' "$d.fixture.json" "$sha" "$TOKEN" "$d/DEMO-PROJECT.md"
  FAKEKEY_MOCK_FIXTURE="$d.fixture.json" FAKEKEY_TIMEOUT_S=120 fakekey_run "$d" --permission-mode default
}

banners() { # banners <demo-dir> — hook-failure banner lines across stdout, stderr and the debug log
  local n=0 f c
  for f in "$1/out.json" "$1/err.txt" "$(fakekey_debuglog "$1")"; do
    [ -f "$f" ] || continue
    c=$(grep -ciE "$BANNER_RE" "$f" 2>/dev/null || true); n=$((n + ${c:-0}))
  done
  printf '%s' "$n"
}

echo "== P clean clone: scripted session, hook chain =="
D="$WORK/demo"; make_demo "$D"; SHA=$(git -C "$D" rev-parse --short HEAD)
run_demo "$D"
RL="$D/mock.log"
if [ "$(jsq "$D/out.json" 'd.is_error===false && String(d.result).includes("DONE '"$SHA"' '"$TOKEN"'")')" = true ]; then pass "P1 the session started and stopped with the scripted final text"; else fail "P1 result: $(head -c 300 "$D/out.json" 2>/dev/null) err: $(head -c 300 "$D/err.txt" 2>/dev/null)"; fi
if [ -s "$RL" ] && [ "$(jsonl_q "$RL" 'JSON.stringify(rows.map(r=>r.body).filter(Boolean)).includes("tool_result")&&rows.some(r=>r.turn===1&&JSON.stringify(r.body).includes("'"$SHA"'"))&&rows.some(r=>r.turn===2&&JSON.stringify(r.body).includes("'"$TOKEN"'"))')" = true ]; then
  pass "P2 the Bash tool_result carried the HEAD sha and the Read tool_result carried the token"
else fail "P2 tool round trips not in the request log ($RL)"; fi
NB=$(banners "$D")
if [ "$NB" = 0 ]; then pass "P3 zero hook-failure banners"; else
  fail "P3 $NB hook-failure banner line(s)"
  for f in "$D/out.json" "$D/err.txt" "$(fakekey_debuglog "$D")"; do [ -f "$f" ] && grep -iE "$BANNER_RE" "$f" 2>/dev/null | head -c 600 | sed 's/^/    banner: /'; done
fi
DBG=$(fakekey_debuglog "$D")
HOOKRUNS=$(grep -cE 'Hook PreToolUse:[A-Za-z]+ \(PreToolUse\) success' "${DBG:-/dev/null}" 2>/dev/null || true)
if [ "${HOOKRUNS:-0}" -gt 0 ]; then pass "P4 the debug log shows PreToolUse hooks completing successfully ($HOOKRUNS)"; else fail "P4 no PreToolUse hook activity in the debug log (a hook set that never fires would pass P3 vacuously)"; fi

echo "== R1 RED control: a failing hook in a scratch clone is caught =="
R="$WORK/red"; make_demo "$R"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/scripts/hooks/block-destructive-commands.sh"
run_demo "$R"
RB=$(banners "$R")
if [ "$RB" -gt 0 ]; then pass "R1 the failing hook raised $RB banner line(s): the P3 assertion can fail"; else fail "R1 a failing hook raised NO banner: P3 would be vacuous"; fi

echo
echo "NOTE: mock-backed result - proves the hook chain starts, fires and stays quiet, not real-model behaviour."
if [ "$failures" = 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: $failures"
exit 1
