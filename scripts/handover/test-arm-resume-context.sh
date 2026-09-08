#!/usr/bin/env bash
# test-arm-resume-context.sh — HIMMEL-2658 --context 1m|standard arm guard.
#
# Operator ruling: context window (the [1m] model-id suffix + the actual
# cost-driving --autocompact lever) is an ARMING-TIME choice per console/leg,
# never inherited from the operator's user-level `model` setting -- a stray
# [1m] there drove ~25-35% of the weekly token bank (see
# docs/internals/lane-calibration.md "Context mode -- an arming-time
# choice"). This suite exercises arm-resume.sh's --context resolution: value
# validation, the console-vs-non-console default, the [1m] suffix
# append/strip, and the Fable-family carve-out (the CLI silently strips
# [1m] there, so arm-resume.sh must never claim to have applied it).
#
# Uses --dry-run except for one stateful-at-stub case that exercises the real
# scheduling path without touching the host scheduler. Harness shields,
# helpers, and the scheduler stubs are copied from
# scripts/handover/test-arm-resume-tier.sh (do not invent a new hermetic
# pattern) — this suite is that one's --context sibling, not a replacement.
#
# Platform guard (gitbash-only): the SUITE ITSELF runs under any POSIX bash
# 3.2+, Git Bash on Windows included -- pure `case`/`[ ]`, mktemp, and
# PATH-stubbed schtasks/at/atq binaries it writes itself. But cases (c),
# (d), and (f)'s command-rendering assertions ('opus\[1m\]', '--autocompact
# auto', etc.) target arm-resume.sh's POSIX `at`/crontab emitter
# SPECIFICALLY -- the same scope test-arm-resume-tier.sh's own body
# comments document (its HIMMEL-2642 notes at cases a/c/c2/d2, e.g. ~line
# 225: "the POSIX `at`-heredoc branch (arm-resume.sh's `linux)` case), NOT
# the Windows .bat path"). On a real Windows host arm-resume.sh takes the
# schtasks/.bat branch instead, where `cadence_cmd_escape` double-quotes
# BOTH operands (`--model "opus[1m]"`, `--autocompact "auto"`) rather than
# %q-quoting them bare -- neither needle in this suite matches that
# rendering, so a failure THERE is an assertion-scope mismatch, not
# evidence arm-resume.sh is broken on Windows. No .ps1 twin (project
# convention: a documented platform guard suffices for a test harness).
set -uo pipefail

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-context.XXXXXX") || {
    echo "ERR test-arm-resume-context: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Hermetic shields — copied verbatim from test-arm-resume-tier.sh's own
# shield block (itself copied from test-arm-resume.sh) so this suite never
# touches the operator's real telemetry sink, trust config, flow-run ledger,
# worker census, or .env defaults.
# ---------------------------------------------------------------------------
export SKILL_TELEMETRY_DIR="$TMP/telemetry-default"
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
unset ARM_NAME_TEMPLATE 2>/dev/null || true
unset RESUME_SLOT_THRESHOLD 2>/dev/null || true
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK 2>/dev/null || true
export WORKER_BRIDGE_ROOT="$TMP/worker-bridge-shield"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
# Temp-target shield (HIMMEL-1365): every fixture here lives under $TMP,
# which is exactly the shape arm-resume refuses for a REAL scheduled task.
# This suite's scheduler is PATH-stubbed, so no real task is ever created;
# --dry-run is exempt from rc=12 anyway, but --time smart's resume-slot.sh
# hop can still read the work-dir before DRY_RUN is known, so keep the
# opt-out for parity with the sibling suite.
export ARM_TEMP_CWD_OK=1
# Dotenv-read shield (HIMMEL-2254): defeats a FILE read (not just an env
# var) so an operator .env carrying ARMAUTOMERGE=1 can't leak an unexpected
# assertion-breaking prefix into the emitted command.
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-shield"
mkdir -p "$ARM_RESUME_DOTENV_ROOT"
unset ARMAUTOMERGE CR_MERGE_GATE_OK 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers — same idiom as test-arm-resume-tier.sh
# ---------------------------------------------------------------------------
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0

# ---------------------------------------------------------------------------
# Fixtures — same shape as test-arm-resume-tier.sh
# ---------------------------------------------------------------------------
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

# future_time — same near-future HH:MM cache as the sibling suites (HIMMEL-1579)
# so a slow box doesn't roll the target to tomorrow mid-suite and trip the
# unrelated HIMMEL-1475 long-gap guard (rc=9).
_FT_FILE="$TMP/future-time.cache"
future_time() {
    local _now _target _value
    _now=$(date +%s)
    _target=0; _value=""
    [ -s "$_FT_FILE" ] && read -r _target _value < "$_FT_FILE"
    if [ -z "$_value" ] || [ "$(( _target - _now ))" -lt 600 ]; then
        _target=$(( _now + 1800 ))
        _value=$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%H:%M'))" "$_target")
        printf '%s %s\n' "$_target" "$_value" > "$_FT_FILE"
    fi
    printf '%s' "$_value"
}

# make_handover [basename] — writes a minimal valid handover file. Default
# basename is randomized (non-console); pass an explicit basename ending in
# -console.md (any case) to fabricate a console arm.
make_handover() {
    local base="${1:-handover-$RANDOM.md}"
    local path="$HANDOVER_DIR/$base"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        printf -- '---\n'
        printf '# Test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Scheduler stub — same empty-scheduler shape as test-arm-resume-tier.sh's
# (itself HIMMEL-1879's SCHED_STUB_T17): /query reports back what /create
# registered, /delete removes it, at/atq/powershell are no-ops. Keeps every
# arm below from touching (or dedup-blocking against) a real HIMMEL-Resume
# job on this machine.
# ---------------------------------------------------------------------------
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
cat > "$SCHED_STUB/schtasks" <<EOF
#!/usr/bin/env bash
db="$TMP/sched-stub.tasks"
cmd="\${1:-}"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create|/delete)
        if [ -f "\$db" ]; then
            grep -vFx "\$tn" "\$db" > "\$db.tmp" 2>/dev/null || : > "\$db.tmp"
            mv "\$db.tmp" "\$db"
        fi
        [ "\$cmd" = /create ] && printf '%s\\n' "\$tn" >> "\$db"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$SCHED_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/powershell" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SCHED_STUB/schtasks" "$SCHED_STUB/atq" "$SCHED_STUB/at" "$SCHED_STUB/powershell"

run_arm() {
    SCHTASKS_CMD="$SCHED_STUB/schtasks" PATH="$SCHED_STUB:$PATH" bash "$ARM" "$@"
}

# ---------------------------------------------------------------------------
# (a) --context validation: a bogus value refuses (rc=2), a missing value
#     refuses whether it's the LAST arg or immediately followed by another
#     option (the same missing/option-looking-value trap --model guards
#     against — a swallowed --dry-run would otherwise arm for real).
# ---------------------------------------------------------------------------
HO_A1=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_A1" --context bogus --dry-run 2>&1)
rc=$?
assert_rc "a1: --context bogus refused" 2 "$rc"
assert_contains "a1: ERR line names the bad value" 'ERR arm-resume: --context must be 1m or standard, got: bogus' "$out"

HO_A2=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_A2" --context --dry-run 2>&1)
rc=$?
assert_rc "a2: --context immediately followed by another option refused" 2 "$rc"
assert_contains "a2: ERR names the non-option-value rule" 'ERR arm-resume: --context requires a non-empty, non-option value' "$out"

HO_A3=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_A3" --dry-run --context 2>&1)
rc=$?
assert_rc "a3: --context with no value at end of argv refused" 2 "$rc"
assert_contains "a3: ERR names the non-option-value rule" 'ERR arm-resume: --context requires a non-empty, non-option value' "$out"

# --context= spelling, same two failure shapes.
HO_A4=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_A4" --context=bogus --dry-run 2>&1)
rc=$?
assert_rc "a4: --context=bogus refused" 2 "$rc"
assert_contains "a4: ERR line names the bad value" 'ERR arm-resume: --context must be 1m or standard, got: bogus' "$out"

# ---------------------------------------------------------------------------
# (b) `standard` on a non-console arm: the emitted command carries
#     --autocompact 200000 and NO [1m] suffix anywhere.
# ---------------------------------------------------------------------------
HO_B=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_B" --context standard --dry-run 2>&1)
rc=$?
assert_rc "b: standard non-console arm exits 0" 0 "$rc"
assert_contains "b: guard line reports standard, explicit source" 'context=standard (explicit --context)' "$out"
assert_contains "b: relaunch command carries --autocompact 200000" '--autocompact 200000' "$out"
assert_not_contains "b: no [1m] suffix anywhere in output" '[1m]' "$out"

# ---------------------------------------------------------------------------
# (c) `1m` + --model opus: the emitted command carries opus[1m] and
#     --autocompact auto. The relaunch command itself renders the model
#     through printf '%q' on this Linux station's POSIX `at` branch, which
#     backslash-escapes the brackets (opus\[1m\]) -- verified against a real
#     dry-run (HIMMEL-2658 manual check). The guard-line echo above it is
#     the unescaped, human-readable report; assert both.
# ---------------------------------------------------------------------------
HO_C=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_C" --model opus --context 1m --dry-run 2>&1)
rc=$?
assert_rc "c: 1m + --model opus exits 0" 0 "$rc"
assert_contains "c: guard line reports the suffixed model" 'context=1m (explicit --context); model=opus[1m]' "$out"
assert_contains "c: relaunch command carries --autocompact auto" '--autocompact auto' "$out"
assert_contains "c: relaunch command carries the suffixed model (escaped)" 'opus\[1m\]' "$out"
assert_not_contains "c: relaunch command carries no --autocompact 200000" '--autocompact 200000' "$out"

# ---------------------------------------------------------------------------
# (d) RED CONTROL: 1m + a Fable-family model -> the CLI silently strips
#     [1m] on Fable, so arm-resume.sh must NOT append it and must say why.
#     --autocompact auto is still passed (the actual cost-driving lever).
#     This assertion is the one that must fail if a future "fix" appends
#     the suffix blindly -- assert the ABSENCE of [1m], not just the
#     presence of the explanatory log line.
# ---------------------------------------------------------------------------
HO_D=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_D" --model claude-fable-5-1 --fable-ok "judgment lane" --context 1m --dry-run 2>&1)
rc=$?
assert_rc "d: 1m + Fable-family model exits 0" 0 "$rc"
assert_contains "d: guard line explains the Fable no-op" 'model=claude-fable-5-1 is Fable-family -- the CLI silently strips a [1m] suffix there, so it is NOT applied' "$out"
assert_contains "d: relaunch command still carries --autocompact auto" '--autocompact auto' "$out"
# RED CONTROL: no spelling of the model WITH a [1m] suffix attached anywhere
# in the output, escaped or not -- this is the assertion that catches a
# future blind-append regression. (A blanket "no literal [1m] anywhere"
# check would false-FAIL here: the guard line's own explanatory prose
# legitimately says "...strips a [1m] suffix...", so the needle has to be
# the SUFFIXED MODEL, not the bare token.)
assert_not_contains "d: RED CONTROL — model not suffixed (unescaped)" 'claude-fable-5-1[1m]' "$out"
assert_not_contains "d: RED CONTROL — model not suffixed (escaped)" 'claude-fable-5-1\[1m\]' "$out"

# ---------------------------------------------------------------------------
# (e) defaults by handover name: a *-console.md handover with no --context
#     defaults to 1m; any other name defaults to standard.
# ---------------------------------------------------------------------------
HO_E1=$(make_handover "arm-context-console.md")
out=$(run_arm --time "$(future_time)" --handover "$HO_E1" --dry-run 2>&1)
rc=$?
assert_rc "e1: console handover, no --context, exits 0" 0 "$rc"
assert_contains "e1: guard line defaults console to 1m" 'context=1m (no --context given; console arms default to 1m -- HIMMEL-2658)' "$out"
assert_contains "e1: relaunch command carries --autocompact auto" '--autocompact auto' "$out"

HO_E2=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_E2" --dry-run 2>&1)
rc=$?
assert_rc "e2: non-console handover, no --context, exits 0" 0 "$rc"
assert_contains "e2: guard line defaults non-console to standard" 'context=standard (no --context given; non-console arms default to standard -- HIMMEL-2658)' "$out"
assert_contains "e2: relaunch command carries --autocompact 200000" '--autocompact 200000' "$out"

# ---------------------------------------------------------------------------
# (f) --context standard strips an operator-typed [1m] suffix from --model.
# ---------------------------------------------------------------------------
HO_F=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_F" --model 'opus[1m]' --context standard --dry-run 2>&1)
rc=$?
assert_rc "f: --context standard with a pre-suffixed --model exits 0" 0 "$rc"
assert_contains "f: guard line names the stripped suffix" 'stripped an operator-typed [1m] suffix from --model' "$out"
# HIMMEL-2642-style rendering note (see case c): the plain model on this
# Linux station's POSIX `at` branch renders bare/unquoted via printf '%q',
# with a trailing space as its right boundary (same shape test-arm-resume-
# tier.sh's case (a) asserts on --model opus).
assert_contains "f: relaunch command carries the plain model" '--model opus ' "$out"
# Same reasoning as case (d)'s RED CONTROL: --model's OWN pre-resolution
# MODEL_REASON guard line legitimately echoes the operator-typed value
# verbatim ("model=opus[1m] (explicitly pinned)"), so a blanket
# "opus[1m] never appears" needle would false-FAIL on that line. Anchor the
# needle on the "--model " flag prefix instead, which only the actual
# relaunch-command rendering carries.
assert_not_contains "f: relaunch command does not carry --model opus[1m] (unescaped)" '--model opus[1m]' "$out"
assert_not_contains "f: relaunch command does not carry --model opus[1m] (escaped)" '--model opus\[1m\]' "$out"

# ---------------------------------------------------------------------------
# (g) HIMMEL-2658 RETASK follow-up: a [1m]-suffixed Fable-family --model on
#     a NON-console handover is still classified Fable-family by the
#     ruling-30 guard (arm-resume.sh's *fable* case glob, ~line 794) --
#     proving the suffix cannot smuggle a Fable pin past that guard. Refused
#     rc=20 exactly like the unsuffixed form, unless --fable-ok is passed.
#     This is arm-resume.sh's PRE-EXISTING fable guard, not the --context
#     resolution itself -- no production code change was made for this case.
# ---------------------------------------------------------------------------
HO_G=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_G" --model 'claude-fable-5-1[1m]' --dry-run 2>&1)
rc=$?
assert_rc "g: [1m]-suffixed Fable model, no --fable-ok, still refused" 20 "$rc"
assert_contains "g: stderr names --fable-ok" '--fable-ok' "$out"

# ---------------------------------------------------------------------------
# (h) HIMMEL-2779: --tier leg makes the standard autocompact ceiling
#     structural. The exact argv pair matters; absence of [1m] is not enough.
# ---------------------------------------------------------------------------
HO_H1=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_H1" --tier leg --context standard --dry-run 2>&1)
rc=$?
assert_rc "h1: --tier leg + standard exits 0" 0 "$rc"
assert_contains "h1: leg argv carries the exact ceiling" '--autocompact 200000' "$out"

HO_H2=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_H2" --tier leg --context 1m --dry-run 2>&1)
rc=$?
assert_rc "h2: --tier leg + 1m refuses with exit 2" 2 "$rc"
assert_contains "h2: refusal names the required argv pair" '--autocompact 200000' "$out"
assert_contains "h2: refusal points to the standard context choice" '--context standard' "$out"

HO_H3=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_H3" --tier --dry-run 2>&1)
rc=$?
assert_rc "h3: --tier missing a value refuses with exit 2" 2 "$rc"
assert_contains "h3: missing-value refusal is actionable" '--tier requires leg' "$out"

HO_H4=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_H4" --tier console --dry-run 2>&1)
rc=$?
assert_rc "h4: unknown --tier value refuses with exit 2" 2 "$rc"
assert_contains "h4: unknown tier names the accepted value" '--tier must be leg' "$out"

# (i) Real non-dry-run path through a stateful at/atq stub. The stub records the
# actual job body and makes it queryable so arm-resume's post-create verify is
# earned; no host scheduler is touched.
REAL_SCHED="$TMP/real-sched-stub"
mkdir -p "$REAL_SCHED"
cat > "$REAL_SCHED/at" <<'EOF'
#!/usr/bin/env bash
state="$(dirname "$0")/job.body"
case "${1:-}" in
  -c) [ -f "$state" ] && cat "$state" ;;
  -r) rm -f "$state" ;;
  *) cat > "$state" ;;
esac
EOF
cat > "$REAL_SCHED/atq" <<'EOF'
#!/usr/bin/env bash
[ -s "$(dirname "$0")/job.body" ] && printf '1\t2099-01-01 00:00 a test\n'
exit 0
EOF
cat > "$REAL_SCHED/powershell" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$REAL_SCHED/at" "$REAL_SCHED/atq" "$REAL_SCHED/powershell"

HO_I=$(make_handover)
out=$(FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 SCHTASKS_CMD="$REAL_SCHED/schtasks" PATH="$REAL_SCHED:$PATH" \
  bash "$ARM" --time "$(future_time)" --handover "$HO_I" --tier leg --context standard 2>&1)
rc=$?
assert_rc "i: --tier leg real non-dry arm succeeds through scheduler stubs" 0 "$rc"
job_body="$(cat "$REAL_SCHED/job.body" 2>/dev/null || true)"
assert_contains "i: scheduled job body carries exact leg ceiling" '--autocompact 200000' "$job_body"
assert_contains "i: success is post-verify earned" 'RESUME ARMED for' "$out"

echo "---"
echo "Run scripts/handover/test-arm-resume-tier.sh separately for the --model/"
echo "--fable-ok tier-guard coverage this suite does not duplicate."

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
