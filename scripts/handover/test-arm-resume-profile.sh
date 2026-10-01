#!/usr/bin/env bash
# test-arm-resume-profile.sh -- HIMMEL-4013: arm-resume.sh's relaunched claude
# runs under a role-matched plugin profile (--settings <file>), never the
# operator's full plugin set. Dry-run only: no real scheduler, no network.
# Covers: role inferred from the handover doc, the explicit --profile override,
# the console doc -> console rule, the fail-closed refusal (rc 2) on an unknown
# profile, and the --settings arg in the at / crontab launch body.
# Usage: bash scripts/handover/test-arm-resume-profile.sh   (bash 3.2-safe)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
. "$SCRIPT_DIR/../lib/fleet-slots-shield.sh"
fleet_slots_shield "$TMP" || exit 1
export ARM_RESUME_LOG_DIR="$TMP/arm-logs"
export CADENCE_BANK_CACHE="$TMP/bank-cache.json" CLAUDE_USAGE_CACHE="$TMP/bank-cache.json"
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
export HIMMEL_PROFILE_SETTINGS_DIR="$TMP/profiles"
unset HIMMEL_HEADROOM_PROXY HEADROOM_BIN 2>/dev/null || true

FAILED=0
assert_rc() {
    if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1 -- expected rc=$2, got rc=$3"; FAILED=$((FAILED + 1)); fi
}
assert_contains() {
    case "$3" in
        *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 -- output missing: $2"; printf '%s\n' "$3" | head -8 | sed 's/^/    got: /'; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    case "$3" in
        *"$2"*) echo "FAIL $1 -- output unexpectedly contains: $2"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $1" ;;
    esac
}

WORK_REPO="$TMP/work-repo"; mkdir -p "$WORK_REPO"; git init -q "$WORK_REPO"
HANDOVER_DIR="$TMP/statedocs/handovers"; mkdir -p "$HANDOVER_DIR"; git init -q "$TMP/statedocs"
export HANDOVER_DIR
future_time() { python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=30)).strftime("%H:%M"))'; }

# make_doc <name> <body-line...>: a handover doc with the given body lines.
make_doc() {
    local path="$HANDOVER_DIR/$1"; shift
    { printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n' "$WORK_REPO"; printf '%s\n' "$@"; } > "$path"
    printf '%s' "$path"
}

STUB="$TMP/stub"; mkdir -p "$STUB"
for t in schtasks atq at claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/$t"; done
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/powershell"
chmod +x "$STUB"/*

arm() { PATH="$STUB:$PATH" bash "$ARM" --time "$(future_time)" --dry-run "$@" 2>&1; }

# T1: a leg doc (carries a RETASK token) resumes under leg-impl.
LEG=$(make_doc handover-leg.md '# leg doc' 'Your RETASK token is `M-X-1`.')
out=$(arm --handover "$LEG"); rc=$?
assert_rc "T1 leg doc dry-run" 0 "$rc"
assert_contains "T1 relaunch carries --settings" "--settings " "$out"
assert_contains "T1 leg doc -> leg-impl profile file" "/leg-impl.json" "$out"

# T2: a console doc resumes under console.
CON=$(make_doc handover-console.md '# CONSOLE handover' 'body')
out=$(arm --handover "$CON"); rc=$?
assert_rc "T2 console doc dry-run" 0 "$rc"
assert_contains "T2 console doc -> console profile file" "/console.json" "$out"

# T3: an explicit `profile:` line in the doc wins over the inferred role.
EXP=$(make_doc handover-explicit.md '# leg doc' 'profile: design' 'Your RETASK token is `M-X-2`.')
out=$(arm --handover "$EXP"); rc=$?
assert_rc "T3 explicit-profile doc dry-run" 0 "$rc"
assert_contains "T3 doc profile line selects design" "/design.json" "$out"
assert_not_contains "T3 not the inferred leg-impl" "/leg-impl.json" "$out"

# T4: --profile on the command line wins over the doc.
out=$(arm --handover "$EXP" --profile bare); rc=$?
assert_rc "T4 --profile override dry-run" 0 "$rc"
assert_contains "T4 --profile selects bare" "/bare.json" "$out"
assert_not_contains "T4 doc profile line overridden" "/design.json" "$out"

# T5: an unknown profile fails closed -- the arm is refused, nothing is emitted.
out=$(arm --handover "$LEG" --profile no-such-profile); rc=$?
assert_rc "T5 unknown profile refuses the arm" 2 "$rc"
assert_contains "T5 refusal names the profile" "no-such-profile" "$out"

# T6: a doc that is neither console nor leg falls back to the user profile.
PLAIN=$(make_doc handover-plain.md '# plain notes')
out=$(arm --handover "$PLAIN"); rc=$?
assert_rc "T6 plain doc dry-run" 0 "$rc"
assert_contains "T6 plain doc -> user profile file" "/user.json" "$out"

# T7: the resolved settings file is real and is a complete enabledPlugins map.
[ -f "$TMP/profiles/leg-impl.json" ] && grep -q '"enabledPlugins"' "$TMP/profiles/leg-impl.json" \
    && echo "PASS T7 resolved settings file written" \
    || { echo "FAIL T7 resolved settings file missing or malformed"; FAILED=$((FAILED + 1)); }

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "ALL PASS"
