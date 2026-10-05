#!/usr/bin/env bash
# Mock-backed smoke of the --consult Bash sandbox (HIMMEL-4412, epic HIMMEL-4409).
#
# MOCK-BACKED: the model is scripts/testing/mock-anthropic, so this proves only that
# Claude Code HONOURS the consult sandbox block for the tool_use it is handed. It is
# NOT evidence of real-model behaviour (what a model chooses to run, or says after a
# refusal); smoke-consult-sandbox.sh is the live, bank-spending twin for that.
# headless-claude-ok: mock-backed — fake key, loopback-only netns, zero spend; the claude launch is fakekey-claude.sh (HIMMEL-4411)
#
# The consult settings are the ones headed-arm-leg.sh --consult really generates (same
# stubs as smoke-consult-sandbox.sh), run with `--setting-sources ""` like the shim does.
# The mock scripts three Bash tool_uses: the allowed append-results.sh, then a python3
# write to a SIBLING file in the bucket, then a python3 write inside the repo. Asserts
# are on disk artifacts and the transcript, never the exit code:
#   S1 the append to the consult doc landed
#   S2 the sibling file is untouched (the sandbox refused the write)
#   S3 nothing was written inside the repo
#   S4 the transcript holds a tool_result for each probe, i.e. both were really run
# RED control (R1): the same run with the sandbox switched OFF in the settings lets the
# sibling write land, so S2 can fail; without R1 S2 would be vacuous.
#
# Not in the per-PR shell-unit shards (needs the pinned `claude` CLI, bwrap, socat and
# unshare -rn): the `claude-startup` CI job runs it; run-shell-tests.sh SKIP_LISTs it.
#
# Usage: bash scripts/testing/test-mock-consult-sandbox.sh
# Exit: 0 all passed, 1 a case failed, 77 a prerequisite is missing (named).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=scripts/testing/fakekey-claude.sh
. "$HERE/fakekey-claude.sh"
# shellcheck source=scripts/lib/git-clean.sh
. "$REPO/scripts/lib/git-clean.sh"
git_env_scrub

for need in node jq claude bwrap socat; do
  command -v "$need" >/dev/null 2>&1 || { echo "SKIP: no $need on PATH"; exit 77; }
done
fakekey_sandbox_available || { echo "FAIL: unshare -rn with loopback unavailable; refusing to run unsandboxed"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mock-consult.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
WORK=$(cd -P "$WORK" && pwd -P)

BUCKET="$WORK/bucket"; mkdir -p "$BUCKET"
DOC="$BUCKET/consult.md"; SIBLING="$BUCKET/sibling.md"
# A consult launches from the console's own (primary) checkout, never a worktree (headed-arm-leg.sh refuses one).
PRIMARY="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)"; PRIMARY="$(cd -P "$PRIMARY/.." && pwd -P)"
REPO_PROBE="$PRIMARY/.mock-consult-probe-$$" # inside the repo: the sandbox always write-denies it
printf '# consult\n\n## Results\n' >"$DOC"
printf 'untouched\n' >"$SIBLING"
trap 'rm -rf "$WORK"; rm -f "$REPO_PROBE"' EXIT

# --- the consult settings headed-arm-leg.sh really generates (stubbed terminal) ---
mkdir -p "$WORK/proc/9001" "$WORK/home/.claude"
cat >"$WORK/konsole" <<'EOF'
#!/usr/bin/env bash
: > "$(dirname "$0")/confirmable"
sleep 3
EOF
cat >"$WORK/pgrep" <<'EOF'
#!/usr/bin/env bash
[ -e "$(dirname "$0")/confirmable" ] && { echo 9001; exit 0; }
exit 1
EOF
chmod 755 "$WORK/konsole" "$WORK/pgrep"
echo claude >"$WORK/proc/9001/comm"
printf 'claude\0--model\0x\0-n\0MOCK-consult\0load doc and continue\0' >"$WORK/proc/9001/cmdline"
printf '{}' >"$WORK/home/.claude/settings.json"

IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' CONSULT_SETTINGS_HOME="$WORK/home" \
HEADED_ARM_LEG_TARGET="$REPO/scripts/handover/headed-arm.sh" \
KONSOLE_CMD="$WORK/konsole" PGREP_CMD="$WORK/pgrep" \
LEG_REPO="$PRIMARY" HEADED_ARM_LOCK_DIR="$WORK/locks" HEADED_ARM_PROC="$WORK/proc" \
  bash "$REPO/scripts/handover/console-kit/headed-arm-leg.sh" --consult --profile design-motion --console MOCK-console \
    MOCK-consult "$DOC" "$WORK/signal-never" "$(( $(date +%s) - 100 ))" "$WORK/log" >"$WORK/launch.out" 2>&1 &
lp=$!
SETTINGS="$WORK/MOCK-consult.leg-settings.json"
n=0; while [ ! -s "$SETTINGS" ] && [ "$n" -lt 100 ] && kill -0 "$lp" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
if [ ! -s "$SETTINGS" ]; then echo "FAIL: the launcher wrote no consult settings"; cat "$WORK/launch.out"; exit 1; fi
wait "$lp" 2>/dev/null || true

# `python3 -c` is allowed ONLY so the probe writes reach the sandbox instead of the permission layer.
# The test cwd is a scratch dir, so the append rule's relative script path is made absolute for the mock's command.
jq '.permissions.allow += ["Bash(python3 -c:*)"] | .hooks = {} | .enabledPlugins = {}' "$SETTINGS" >"$WORK/on.json" || { echo "FAIL: jq"; exit 1; }
# RED control settings: the identical envelope with the sandbox switched off (a guard that fails open).
jq '.sandbox.enabled = false | .sandbox.failIfUnavailable = false' "$WORK/on.json" >"$WORK/off.json" || { echo "FAIL: jq"; exit 1; }
if [ "$(jq -r '.sandbox.enabled' "$WORK/on.json")" != true ] || [ "$(jq -r '.sandbox.enabled' "$WORK/off.json")" != false ]; then
  echo "FAIL: the consult settings did not carry the sandbox block (nothing to test)"; exit 1
fi
APPEND_RULE=$(jq -r '.permissions.allow[0]' "$SETTINGS")
APPEND_CMD=${APPEND_RULE#Bash(}; APPEND_CMD=${APPEND_CMD%:\*)}

# --- the scripted turns: append (allowed), sibling probe, repo probe, final text ---
# shellcheck disable=SC2016  # the JS is single-quoted on purpose
node -e '
const [fx,append,sib,probe]=process.argv.slice(1);
const py=(p)=>({type:"tool_use",name:"Bash",input:{command:`python3 -c "open(\x27${p}\x27,\x27a\x27).write(\x27pwned\x27)"`,description:"probe"}});
require("fs").writeFileSync(fx,JSON.stringify({turns:[
 {reply:[{type:"text",text:"MOCK-SANDBOX-1"},{type:"tool_use",name:"Bash",input:{command:append+" \"FINDING smoke-ok\"",description:"append"}}]},
 {match:"tool_result",reply:py(sib)},
 {match:"tool_result",reply:py(probe)},
 {match:"tool_result",reply:{type:"text",text:"MOCK-SANDBOX-DONE"}}]}))' \
  "$WORK/fixture.json" "$APPEND_CMD" "$SIBLING" "$REPO_PROBE"

run_probe() { # run_probe <outdir> <settings> — one scripted turn run; claude's cwd is <outdir>, so scripts/ is linked in for the relative append rule
  mkdir -p "$1" && ln -sfn "$REPO/scripts" "$1/scripts"
  FAKEKEY_MOCK_FIXTURE="$WORK/fixture.json" FAKEKEY_TIMEOUT_S=90 fakekey_run "$1" \
    --settings "$2" --setting-sources "" --permission-mode default
}
jsonl_q() { node -e 'const rows=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean).map(l=>JSON.parse(l));process.stdout.write(String(eval(process.argv[2])))' "$1" "$2" 2>/dev/null; }

echo "== R1 RED control: sandbox OFF => the sibling write lands (the smoke can catch a leak) =="
run_probe "$WORK/off" "$WORK/off.json"
if [ "$(cat "$SIBLING")" != untouched ]; then pass "R1 with the sandbox off the sibling write landed"; else fail "R1 the sibling write did NOT land with the sandbox off: S2 would be vacuous ($(head -c 300 "$WORK/off/err.txt"))"; fi
printf 'untouched\n' >"$SIBLING"; rm -f "$REPO_PROBE"; printf '# consult\n\n## Results\n' >"$DOC"

echo "== S sandbox ON: the same scripted probes =="
run_probe "$WORK/on" "$WORK/on.json"
if grep -q 'FINDING smoke-ok' "$DOC"; then pass "S1 the append to the consult doc landed"; else fail "S1 the append did not land"; fi
if [ "$(cat "$SIBLING")" = untouched ]; then pass "S2 the sibling file is untouched"; else fail "S2 a sandboxed write reached the sibling file"; fi
if [ ! -e "$REPO_PROBE" ]; then pass "S3 nothing was written inside the repo"; else fail "S3 a sandboxed write reached the repo"; fi
RL="$WORK/on/mock.log"
if [ -s "$RL" ] && [ "$(jsonl_q "$RL" 'rows.filter(r=>r.path==="/v1/messages"&&r.turn!==null).length')" = 4 ]; then
  pass "S4 all four scripted turns were served, so both probes were really attempted"
else fail "S4 not every scripted turn ran (turns: $(jsonl_q "$RL" 'rows.map(r=>r.turn).join(",")'); err: $(head -c 300 "$WORK/on/err.txt"))"; fi

echo
echo "NOTE: mock-backed result - proves Claude Code enforces the consult sandbox, not real-model behaviour."
if [ "$failures" = 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: $failures"
exit 1
