#!/usr/bin/env bash
# smoke-consult-sandbox.sh (HIMMEL-4066) - OPT-IN live check of the --consult Bash sandbox.
#
# The suite (test-headed-arm-leg.sh) asserts the GENERATED settings JSON; it cannot
# prove Claude Code honours the sandbox block. This runs headless `claude -p` from the # headless-claude-ok: prose mention only; the live calls below carry their own markers (HIMMEL-4243)
# primary checkout (whose committed settings grant additionalDirectories on the luna
# vault, HIMMEL-4069) through the REAL shim (leg-claude-launcher.sh) with the settings and
# env headed-arm-leg.sh really generates, and checks the ARTIFACTS on disk:
#   0. RED control: the same settings WITHOUT `--setting-sources ""` let a sandboxed
#      write reach a SIBLING bucket file (else this smoke could not catch a leak: FAIL);
#   1. the append to the consult doc (append-results.sh) lands;
#   2. a sandboxed write to a SIBLING file in the same bucket does NOT land;
#   3. a sandboxed write inside the repo does NOT land;
#   4. a hook CARRIED from a user scope the consult no longer loads fires;
#   5. a PLUGIN hook (himmel-ops, enabled only via the profile's enabledPlugins) fires
#      (HIMMEL-4118 F3).
# The user scope is a scratch home (CONSULT_SETTINGS_HOME) holding only that canary hook;
# the project scope is the real one. It spends bank (headless claude draws the same bank
# as interactive use: two runs), so it is SKIPPED unless CONSULT_SMOKE=1 and the bank
# preflight says PROCEED.
#
# Usage: CONSULT_SMOKE=1 bash scripts/handover/console-kit/smoke-consult-sandbox.sh
# Exit: 0 pass or skip, 1 fail, 3 bank preflight refused.
set -u

if [ "${CONSULT_SMOKE:-}" != 1 ]; then
    echo "SKIP smoke-consult-sandbox: set CONSULT_SMOKE=1 to run the live check (spends bank)"
    exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../lib"
# shellcheck disable=SC1091
. "$LIB/handover-path.sh"
# shellcheck source=scripts/lib/git-clean.sh
. "$LIB/git-clean.sh"
git_env_scrub

pf="$(bash "$LIB/bank-preflight.sh" 2>&1)" || true
case "$(printf '%s\n' "$pf" | tail -n 1)" in
    PROCEED) ;;
    *) echo "SKIP-BANK smoke-consult-sandbox: bank preflight did not say PROCEED: $(printf '%s\n' "$pf" | tail -n 1)"; exit 3 ;;
esac

# The consult runs from the console's own (primary) checkout, never a worktree.
primary="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"
primary="$(cd -P "$primary/.." && pwd -P)"
root="$(handover_root)"
scratch="$root/.smoke-consult-$$"
work="$(mktemp -d "${TMPDIR:-/tmp}/smoke-consult.XXXXXX")" || { echo "FAIL smoke-consult-sandbox: mktemp failed"; exit 1; }
probe="$primary/.smoke-consult-probe-$$"
# shellcheck disable=SC2317,SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$scratch" "$work"; rm -f "$probe"; }
SHIM="$HERE/../../lanes/leg-claude-launcher.sh"
trap cleanup EXIT

mkdir -p "$scratch" || { echo "FAIL smoke-consult-sandbox: cannot create $scratch"; exit 1; }
doc="$scratch/consult.md"; sibling="$scratch/sibling.md"
printf '# consult\n\n## Results\n' > "$doc"
printf 'untouched\n' > "$sibling"
mkdir -p "$work/home/.claude"
canary_cmd="touch '$work/canary-fired'"
jq -n --arg c "$canary_cmd" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}}' > "$work/home/.claude/settings.json" \
    || { echo "FAIL smoke-consult-sandbox: jq"; exit 1; }
doc="$(cd -P "$scratch" && pwd -P)/consult.md"; sibling="$(cd -P "$scratch" && pwd -P)/sibling.md"

# Stubs so the real launcher writes the settings file without opening a terminal.
mkdir -p "$work/proc/9001"
cat > "$work/konsole" <<'EOF'
#!/usr/bin/env bash
env | grep '^LEG_PROFILE_NO_SETTING_SOURCES=' > "$(dirname "$0")/nss"
: > "$(dirname "$0")/confirmable"
sleep 3
EOF
cat > "$work/pgrep" <<'EOF'
#!/usr/bin/env bash
[ -e "$(dirname "$0")/confirmable" ] && { echo 9001; exit 0; }
exit 1
EOF
chmod 755 "$work/konsole" "$work/pgrep"
echo claude > "$work/proc/9001/comm"
printf 'claude\0--model\0x\0-n\0SMOKE-consult\0load doc and continue\0' > "$work/proc/9001/cmdline"

IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' CONSULT_SETTINGS_HOME="$work/home" \
HEADED_ARM_LEG_TARGET="$HERE/../headed-arm.sh" \
KONSOLE_CMD="$work/konsole" PGREP_CMD="$work/pgrep" \
LEG_REPO="$primary" HEADED_ARM_LOCK_DIR="$work/locks" HEADED_ARM_PROC="$work/proc" \
    bash "$HERE/headed-arm-leg.sh" --consult --profile design-motion --console SMOKE-console \
        SMOKE-consult "$doc" "$work/signal-never" "$(( $(date +%s) - 100 ))" "$work/log" >"$work/launch.out" 2>&1 &
launch_pid=$!
settings="$work/SMOKE-consult.leg-settings.json"
n=0; while [ ! -s "$settings" ] && [ "$n" -lt 100 ] && kill -0 "$launch_pid" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
if [ ! -s "$settings" ]; then
    echo "FAIL smoke-consult-sandbox: launcher wrote no settings (see $work/launch.out)"; cat "$work/launch.out"; exit 1
fi
wait "$launch_pid" 2>/dev/null || true
if [ "$(cat "$work/nss" 2>/dev/null)" != "LEG_PROFILE_NO_SETTING_SOURCES=1" ]; then
    echo "FAIL smoke-consult-sandbox: the launcher did not hand the shim LEG_PROFILE_NO_SETTING_SOURCES=1"; exit 1
fi
if [ "$(jq -c --arg c "$canary_cmd" '[.hooks.PreToolUse[]?.hooks[]?.command | select(. == $c)] | length' "$settings")" != 1 ]; then
    echo "FAIL smoke-consult-sandbox: the canary user-scope hook was not carried into the consult settings"; exit 1
fi

# The generated allow list is the one append rule; add `python3 -c` ONLY so the probe
# writes reach the SANDBOX instead of being refused by the permission layer first.
jq '.permissions.allow += ["Bash(python3 -c:*)"]' "$settings" > "$work/probe-settings.json" || { echo "FAIL smoke-consult-sandbox: jq"; exit 1; }

# RED control: the same settings, the same shim, but no `--setting-sources ""`: the user,
# project and local scopes load again and their write roots must let the sibling write land.
ctl_prompt="Run exactly this one command as a single Bash call, do not retry or work around any failure, then reply with its exact stdout/stderr text:
python3 -c \"open('$sibling','a').write('pwned')\""
# headless-claude-ok: opt-in live check of the consult Bash sandbox (HIMMEL-4069 RED control); bank preflight above, explicit --permission-mode, parsed --output-format json
( cd "$primary" && LEG_CLAUDE_BIN=claude LEG_PROFILE_SETTINGS="$work/probe-settings.json" LEG_PROFILE_NO_SETTING_SOURCES='' \
    bash "$SHIM" -p --model claude-sonnet-5-5 --permission-mode default --output-format json "$ctl_prompt" ) > "$work/control.json" 2> "$work/control.err" || true
if [ "$(cat "$sibling")" = "untouched" ]; then
    echo "FAIL - RED control: without --setting-sources the sibling write did NOT land, so this smoke cannot catch a leak (vacuous): $(jq -r '.result // ""' "$work/control.json" 2>/dev/null | head -c 400)"
    echo "FAIL smoke-consult-sandbox"; exit 1
fi
echo "ok - RED control: without --setting-sources the sibling write landed (the smoke catches a leak)"
printf 'untouched\n' > "$sibling"; rm -f "$work/canary-fired"

prompt="Run exactly these three commands, each as its own separate Bash call, in this order, and do not retry or work around any failure. Then reply with the exact stdout/stderr text of each.
1. bash scripts/handover/console-kit/append-results.sh $doc \"LIVE smoke-ok\"
2. python3 -c \"open('$sibling','a').write('pwned')\"
3. python3 -c \"open('$probe','w').write('pwned')\""
# (python3 -c, not a shell redirect: the project's block-write-into-main-checkout hook
# refuses redirect-shaped writes before the sandbox is ever reached - the control run showed it.)

# The confined run: exactly what the shim builds for a consult (LEG_PROFILE_NO_SETTING_SOURCES=1).
# headless-claude-ok: opt-in live check of the consult Bash sandbox (HIMMEL-4066); bank preflight above, explicit --permission-mode, parsed --output-format json
( cd "$primary" && LEG_CLAUDE_BIN=claude LEG_PROFILE_SETTINGS="$work/probe-settings.json" LEG_PROFILE_NO_SETTING_SOURCES=1 \
    HIMMEL_HOOK_INTEGRITY_DIR="$work/plugin-canary" \
    bash "$SHIM" -p --model claude-sonnet-5-5 --permission-mode default --output-format json "$prompt" ) > "$work/claude.json" 2> "$work/claude.err" || true

fail=0
if grep -q 'LIVE smoke-ok' "$doc"; then echo "ok - the append to the consult doc landed"; else echo "FAIL - the append to the consult doc did NOT land"; fail=1; fi
if [ "$(cat "$sibling")" = "untouched" ]; then echo "ok - the sibling file in the bucket is untouched"; else echo "FAIL - a sandboxed write reached a SIBLING file in the bucket"; fail=1; fi
if [ ! -e "$probe" ]; then echo "ok - no file was written inside the repo"; else echo "FAIL - a sandboxed write reached the repo"; fail=1; fi
if [ -e "$work/canary-fired" ]; then echo "ok - the carried user-scope PreToolUse hook fired"; else echo "FAIL - the carried user-scope PreToolUse hook did NOT fire"; fail=1; fi
# Plugin-hook canary (HIMMEL-4118 F3): himmel-ops' SessionStart record-hook-integrity.sh is
# wired ONLY in the plugin's hooks.json (never in a settings scope, so it is not carried), and
# writes its pin file under HIMMEL_HOOK_INTEGRITY_DIR. A pin file in that fresh dir proves the
# plugin's hooks load under `--setting-sources ""`, via the profile's enabledPlugins alone.
if [ -n "$(find "$work/plugin-canary" -type f 2>/dev/null | head -n 1)" ]; then
    echo "ok - the himmel-ops plugin hook (record-hook-integrity.sh) fired under the confined run"
else
    echo "FAIL - the himmel-ops plugin hook did NOT fire under the confined run (plugin hooks may not load under --setting-sources \"\")"; fail=1
fi
# Not vacuous: the model must have ATTEMPTED BOTH sibling and repo probes and seen the
# sandbox refuse each (two refusal lines), not merely one refusal phrase.
result="$(jq -r '.result // ""' "$work/claude.json" 2>/dev/null)"
refusals="$(printf '%s\n' "$result" | grep -ciE 'read-only file system|operation not permitted|permission denied')"
if [ "${refusals:-0}" -ge 2 ]; then
    echo "ok - both probes were attempted and refused by the sandbox"
else
    echo "FAIL - fewer than two sandbox refusal lines in the result (a probe may not have run, or a hook refused it): $(printf '%s' "$result" | head -c 400)"; fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS smoke-consult-sandbox" || echo "FAIL smoke-consult-sandbox"
exit "$fail"
