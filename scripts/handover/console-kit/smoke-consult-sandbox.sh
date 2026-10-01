#!/usr/bin/env bash
# smoke-consult-sandbox.sh (HIMMEL-4066) - OPT-IN live check of the --consult Bash sandbox.
#
# The suite (test-headed-arm-leg.sh) asserts the GENERATED settings JSON; it cannot
# prove Claude Code honours the sandbox block. This runs ONE headless `claude -p` under
# the REAL project settings (cwd = the primary checkout) with the settings
# headed-arm-leg.sh really generates, and checks the ARTIFACTS on disk:
#   1. the append to the consult doc (append-results.sh) lands;
#   2. a sandboxed write to a SIBLING file in the same bucket does NOT land;
#   3. a sandboxed write inside the repo does NOT land.
# It spends bank (headless claude draws the same bank as interactive use), so it is
# SKIPPED unless CONSULT_SMOKE=1 and the bank preflight says PROCEED.
#
# While a settings scope carries permissions.additionalDirectories (himmel's own project
# settings do) the launcher refuses every consult (HIMMEL-4069), so this prints SKIP.
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
work="$(mktemp -d "${TMPDIR:-/tmp}/smoke-consult.XXXXXX")"
probe="$primary/.smoke-consult-probe-$$"
cleanup() { rm -rf "$scratch" "$work"; rm -f "$probe"; }
trap cleanup EXIT

mkdir -p "$scratch" || { echo "FAIL smoke-consult-sandbox: cannot create $scratch"; exit 1; }
doc="$scratch/consult.md"; sibling="$scratch/sibling.md"
printf '# consult\n\n## Results\n' > "$doc"
printf 'untouched\n' > "$sibling"
doc="$(cd -P "$scratch" && pwd -P)/consult.md"; sibling="$(cd -P "$scratch" && pwd -P)/sibling.md"

# Stubs so the real launcher writes the settings file without opening a terminal.
mkdir -p "$work/proc/9001"
cat > "$work/konsole" <<'EOF'
#!/usr/bin/env bash
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

IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' \
HEADED_ARM_LEG_TARGET="$HERE/../headed-arm.sh" \
KONSOLE_CMD="$work/konsole" PGREP_CMD="$work/pgrep" \
LEG_REPO="$primary" HEADED_ARM_LOCK_DIR="$work/locks" HEADED_ARM_PROC="$work/proc" \
    bash "$HERE/headed-arm-leg.sh" --consult --profile design-motion --console SMOKE-console \
        SMOKE-consult "$doc" "$work/signal-never" "$(( $(date +%s) - 100 ))" "$work/log" >"$work/launch.out" 2>&1 &
launch_pid=$!
settings="$work/SMOKE-consult.leg-settings.json"
n=0; while [ ! -s "$settings" ] && [ "$n" -lt 100 ] && kill -0 "$launch_pid" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
if [ ! -s "$settings" ]; then
    if grep -q 'HIMMEL-4069' "$work/launch.out" 2>/dev/null; then
        echo "SKIP smoke-consult-sandbox: the launcher refuses this consult while a settings scope carries permissions.additionalDirectories (HIMMEL-4069)"; exit 0
    fi
    echo "FAIL smoke-consult-sandbox: launcher wrote no settings (see $work/launch.out)"; cat "$work/launch.out"; exit 1
fi

# The generated allow list is the one append rule; add `python3 -c` ONLY so the probe
# writes reach the SANDBOX instead of being refused by the permission layer first.
jq '.permissions.allow += ["Bash(python3 -c:*)"]' "$settings" > "$work/probe-settings.json" || { echo "FAIL smoke-consult-sandbox: jq"; exit 1; }

prompt="Run exactly these three commands, each as its own separate Bash call, in this order, and do not retry or work around any failure. Then reply with the exact stdout/stderr text of each.
1. bash scripts/handover/console-kit/append-results.sh $doc \"LIVE smoke-ok\"
2. python3 -c \"open('$sibling','a').write('pwned')\"
3. python3 -c \"open('$probe','w').write('pwned')\""
# (python3 -c, not a shell redirect: the project's block-write-into-main-checkout hook
# refuses redirect-shaped writes before the sandbox is ever reached - the control run showed it.)

# headless-claude-ok: opt-in live check of the consult Bash sandbox (HIMMEL-4066); bank preflight above, explicit --permission-mode, parsed --output-format json
( cd "$primary" && claude -p --model claude-sonnet-5-5 --permission-mode default --output-format json \
    --settings "$work/probe-settings.json" "$prompt" ) > "$work/claude.json" 2> "$work/claude.err" || true

fail=0
if grep -q 'LIVE smoke-ok' "$doc"; then echo "ok - the append to the consult doc landed"; else echo "FAIL - the append to the consult doc did NOT land"; fail=1; fi
if [ "$(cat "$sibling")" = "untouched" ]; then echo "ok - the sibling file in the bucket is untouched"; else echo "FAIL - a sandboxed write reached a SIBLING file in the bucket"; fail=1; fi
if [ ! -e "$probe" ]; then echo "ok - no file was written inside the repo"; else echo "FAIL - a sandboxed write reached the repo"; fail=1; fi
# Not vacuous: the model must have ATTEMPTED the probes and seen the sandbox refuse them.
if jq -r '.result // ""' "$work/claude.json" 2>/dev/null | grep -qiE 'read-only file system|operation not permitted|permission denied'; then
    echo "ok - the probes were attempted and refused by the sandbox"
else
    echo "FAIL - no sandbox refusal text in the result (probes may not have run): $(jq -r '.result // "no result"' "$work/claude.json" 2>/dev/null | head -c 400)"; fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS smoke-consult-sandbox" || echo "FAIL smoke-consult-sandbox"
exit "$fail"
