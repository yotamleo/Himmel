#!/usr/bin/env bash
# test-arm-resume-tier.sh — HIMMEL-2332 Fable-tier arm guard.
#
# Operator ruling 30: "we shouldn't arm fable unless theres a good reason" /
# "make sure this is STRUCTURAL otherwise it won't work". arm-resume.sh's
# --model passthrough (HIMMEL-2192) is opt-in, so an unpinned arm relaunches
# on the operator's default model (Fable) — expensive, and wrong outside the
# judgment lane. This suite exercises the guard: an unpinned non-console arm
# now defaults to opus; an explicit Fable-family --model on a non-console arm
# is refused (rc=20) unless paired with --fable-ok; a *-console.md handover
# (ruling 25 — the console lane is ALWAYS Fable) is exempt from both.
#
# Uses --dry-run throughout so no real scheduler job is ever created. Harness
# shields, helpers, and the scheduler stub are copied from
# scripts/handover/test-arm-resume.sh (do not invent a new hermetic pattern).
set -uo pipefail

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-tier.XXXXXX") || {
    echo "ERR test-arm-resume-tier: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Hermetic shields — copied verbatim from test-arm-resume.sh's own shield
# block so this suite never touches the operator's real telemetry sink,
# trust config, flow-run ledger, worker census, or .env defaults.
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
# var) so an operator .env carrying ARMAUTOMERGE=1 can't leak "--model
# opus" assertions into carrying an unexpected ARMAUTOMERGE prefix too.
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-shield"
mkdir -p "$ARM_RESUME_DOTENV_ROOT"
unset ARMAUTOMERGE CR_MERGE_GATE_OK 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers — same idiom as test-arm-resume.sh
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

# assert_not_matches <label> <ERE> <haystack> — like assert_not_contains, but
# for a token-boundary regex a fixed-string `case` needle can't express (CR
# finding on PR #2196: d1's negative control was `--model ` literal, so it
# passed on a regression that emitted `--model=opus` or a bare trailing
# `--model` with no space). `<<<"$haystack"` is a HERE-STRING, deliberately
# not a pipe: this file runs under `set -o pipefail` (line 16), and `grep -q`
# exits the instant it finds a match, SIGPIPEing a producer on the other end
# of a pipe and flipping the pipeline's reported exit status (HIMMEL-1430).
# There is no producer here, but a here-string keeps this helper safe to copy
# into a call site that has one.
#
# Panel finding on head adc611c3: `grep -Eq` returns 0 (match), 1 (no match),
# or 2+ (an execution/regex error -- a malformed ERE, an unreadable input, a
# non-GNU grep). An `if grep …; then FAIL; else PASS; fi` funnels status 2
# into the same branch as a genuine no-match, so a typo'd pattern makes this
# NEGATIVE control report PASS while testing nothing -- exactly the vacuity
# this control exists to catch, now in the control itself. Capture the exit
# status explicitly and give status >1 its OWN hard-FAIL branch naming the
# status, rather than folding it into either existing branch.
assert_not_matches() {
    local label="$1" pattern="$2" haystack="$3" status
    grep -Eq "$pattern" <<<"$haystack"
    status=$?
    case "$status" in
        0) echo "FAIL $label — output unexpectedly matches: $pattern"; FAILED=$((FAILED + 1)) ;;
        1) echo "PASS $label" ;;
        *) echo "FAIL $label — grep could not evaluate the pattern (exit $status): $pattern"; FAILED=$((FAILED + 1)) ;;
    esac
}

FAILED=0

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

# future_time — same near-future HH:MM cache as test-arm-resume.sh (HIMMEL-1579)
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
# Scheduler stub — same empty-scheduler shape as test-arm-resume.sh's
# SCHED_STUB_T17 (HIMMEL-1879): /query reports back what /create registered,
# /delete removes it, at/atq/powershell are no-ops. Keeps every arm below
# from touching (or dedup-blocking against) a real HIMMEL-Resume job on this
# machine.
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
# (a) unpinned NON-console arm -> defaults to opus, no fable token.
# ---------------------------------------------------------------------------
HO_A=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_A" --dry-run 2>&1)
rc=$?
assert_rc "a: unpinned non-console arm exits 0" 0 "$rc"
assert_contains "a: guard line reports opus default" "arm-resume: model=opus (no --model given; non-console arms default to opus -- ruling 30)" "$out"
# HIMMEL-2642: this suite's PATH-stubbed `at` (SCHED_STUB, above) is found on
# this Linux station, so schedule_arm renders the model passthrough via the
# POSIX `at`-heredoc branch (arm-resume.sh's `linux)` case, ~5140-5152), NOT
# the Windows .bat path -- and only the .bat renderer wraps --model's value
# in literal double quotes. The POSIX branch renders it through
# `printf '%q'`, which leaves an already-shell-safe token (opus, sonnet,
# fable, claude-fable-5) bare and unquoted. Match the REAL rendering: the
# literal "--model " prefix pins the flag and the left edge of its value
# (so this still fails if --model were dropped, or if e.g. "opus" were
# matched by a value that merely ENDS in "opus"), and the trailing-space
# right boundary q_model always appends (arm-resume.sh ~5152) pins the
# right edge (so a value that merely STARTS with the expected one, e.g. a
# future "fable-turbo" against case c2's bare "fable", can't false-match).
assert_contains "a: relaunch command carries --model opus" '--model opus ' "$out"
assert_not_contains "a: relaunch command carries no fable token" 'fable' "$out"

# ---------------------------------------------------------------------------
# (b) Fable-family --model on a non-console arm, no --fable-ok -> rc=20,
#     refused before anything is armed. Two sub-cases prove FAMILY match
#     (substring), not a literal string: "claude-fable-5" and bare "fable".
# ---------------------------------------------------------------------------
HO_B1=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_B1" --model claude-fable-5 --dry-run 2>&1)
rc=$?
assert_rc "b1: claude-fable-5 pin refused" 20 "$rc"
assert_contains "b1: stderr names --fable-ok" '--fable-ok' "$out"
assert_not_contains "b1: nothing armed (no dry-run completion line)" "dry-run complete" "$out"

HO_B2=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_B2" --model fable --dry-run 2>&1)
rc=$?
assert_rc "b2: bare 'fable' pin refused (family match, not literal)" 20 "$rc"
assert_contains "b2: stderr names --fable-ok" '--fable-ok' "$out"

# Case-insensitive family match, HIMMEL-2332's stated shape.
HO_B3=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_B3" --model Claude-Fable-5 --dry-run 2>&1)
rc=$?
assert_rc "b3: Claude-Fable-5 (mixed case) pin refused" 20 "$rc"

# ---------------------------------------------------------------------------
# (c) same pin WITH --fable-ok -> allowed, reason echoed, model passed through.
# ---------------------------------------------------------------------------
HO_C=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_C" --model claude-fable-5 --fable-ok "operator ruling: judgment lane" --dry-run 2>&1)
rc=$?
assert_rc "c: justified fable pin exits 0" 0 "$rc"
assert_contains "c: guard line echoes the reason" "arm-resume: model=claude-fable-5 (fable pinned; reason: operator ruling: judgment lane)" "$out"
# HIMMEL-2642: bare/unquoted POSIX %q rendering, trailing-space boundary --
# see case (a)'s comment above.
assert_contains "c: relaunch command carries the fable model" '--model claude-fable-5 ' "$out"

# --fable-ok= spelling
HO_C2=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_C2" --model=fable --fable-ok="judgment lane" --dry-run 2>&1)
rc=$?
assert_rc "c2: --fable-ok= spelling exits 0" 0 "$rc"
# HIMMEL-2642: bare/unquoted POSIX %q rendering -- see case (a) above. The
# trailing-space right boundary keeps "--model fable" from also being
# satisfied by a longer value that merely STARTS with "fable" (e.g. a future
# "fable-turbo") -- case (a)'s literal "--model " left boundary is what
# already keeps this from matching inside "--model claude-fable-5 ".
assert_contains "c2: relaunch command carries the fable model" '--model fable ' "$out"

# ---------------------------------------------------------------------------
# (d) *-console.md handover: unpinned -> NO --model flag at all (operator
#     default stands, ruling 25). Fable-pinned + no --fable-ok -> exempt, rc=0.
# ---------------------------------------------------------------------------
HO_D1=$(make_handover "arm-guard-console.md")
out=$(run_arm --time "$(future_time)" --handover "$HO_D1" --dry-run 2>&1)
rc=$?
assert_rc "d1: unpinned console arm exits 0" 0 "$rc"
assert_contains "d1: guard line reports operator default kept" "arm-resume: model=<operator default> (console arm, unpinned -- ruling 25 keeps the fable default)" "$out"
# Negative control for the bare/unquoted rendering above (see case a's
# comment): with MODEL unset, q_model is never built at all, so NO spelling
# of --model appears here -- this proves the case-a/c/c2/d2/e1/e2 assertions
# above can still fail (they would, if --model were emitted unconditionally
# regardless of whether a model was pinned). A fixed-string `--model ` needle
# only caught the space-separated form; a regression emitting `--model=...`
# or a bare trailing `--model` (no following space) would have slipped past
# it (CR finding on PR #2196) -- match on the TOKEN boundary instead: --model
# preceded by start-of-line or whitespace, followed by whitespace, `=`, or
# end-of-line, so an unrelated flag like --model-agnostic still can't
# false-positive.
assert_not_matches "d1: relaunch command carries no --model flag" '(^|[[:space:]])--model([[:space:]=]|$)' "$out"

HO_D2=$(make_handover "arm-guard-CONSOLE.MD")
out=$(run_arm --time "$(future_time)" --handover "$HO_D2" --model claude-fable-5 --dry-run 2>&1)
rc=$?
assert_rc "d2: console arm with fable pin, no --fable-ok, is exempt" 0 "$rc"
assert_contains "d2: guard line names the ruling-25 exemption" "arm-resume: model=claude-fable-5 (fable pinned; console arm -- ruling 25, exempt)" "$out"
# HIMMEL-2642: bare/unquoted POSIX %q rendering -- see case (a) above.
assert_contains "d2: relaunch command carries the fable model" '--model claude-fable-5 ' "$out"

# ---------------------------------------------------------------------------
# (e) unregressed existing behavior.
# ---------------------------------------------------------------------------
HO_E1=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_E1" --model opus --dry-run 2>&1)
rc=$?
assert_rc "e1: explicit non-fable --model opus still passes through" 0 "$rc"
# HIMMEL-2642: bare/unquoted POSIX %q rendering -- see case (a) above.
assert_contains "e1: relaunch command carries --model opus" '--model opus ' "$out"
assert_contains "e1: guard line reports an explicit pin" "arm-resume: model=opus (explicitly pinned)" "$out"

HO_E2=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_E2" --model sonnet --dry-run 2>&1)
rc=$?
assert_rc "e2: explicit non-fable --model sonnet still passes through" 0 "$rc"
# HIMMEL-2642: bare/unquoted POSIX %q rendering -- see case (a) above.
assert_contains "e2: relaunch command carries --model sonnet" '--model sonnet ' "$out"

HO_E3=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_E3" --model --dry-run 2>&1)
rc=$?
assert_rc "e3: --model with a missing/option-looking value still exits 2" 2 "$rc"
assert_contains "e3: rejects the option-looking value" '--model requires a non-empty, non-option value' "$out"

# e4 (panel [codex-3]): the --fable-ok reason is ECHOED into the guard line and
# the closing banner, so a newline in it could forge a banner line an operator
# reads as ours. Both spellings must refuse it. Free prose still permits
# SPACES ([:print:] includes them) — asserted by case (c) above, which passes a
# multi-word reason.
HO_E4=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_E4" --model claude-fable-5 \
      --fable-ok "$(printf 'forged\nRESUME ARMED for 00:00')" --dry-run 2>&1)
rc=$?
assert_rc "e4: --fable-ok carrying a newline exits 2" 2 "$rc"
assert_contains "e4: refusal names the single-printable-line rule" 'must be a single printable line' "$out"

HO_E5=$(make_handover)
out=$(run_arm --time "$(future_time)" --handover "$HO_E5" --model claude-fable-5 \
      --fable-ok="$(printf 'forged\nRESUME ARMED for 00:00')" --dry-run 2>&1)
rc=$?
assert_rc "e5: --fable-ok=<value> spelling refuses a newline too" 2 "$rc"
assert_contains "e5: refusal names the single-printable-line rule" 'must be a single printable line' "$out"

echo "---"
echo "Run scripts/handover/test-arm-resume.sh and scripts/handover/test-arm-resume-identity.sh"
echo "separately for the dedupe/collision/self-cleaning regression coverage this suite does"
echo "not duplicate (per HIMMEL-2332 scope)."

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
