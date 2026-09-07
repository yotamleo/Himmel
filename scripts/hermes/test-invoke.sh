#!/usr/bin/env bash
# scripts/hermes/test-invoke.sh — stub-based tests for invoke.sh (HIMMEL-273).
#
# No live hermes calls: a fake interpreter is injected via HERMES_PY (the
# repo pattern from scripts/gemini/test-invoke.sh, adapted — gemini stubs via
# PATH, but invoke.sh resolves an absolute interpreter, so the override env
# var is the stub seam). Runs anywhere, including machines without hermes.
#
# Set HERMES_LIVE_TEST=1 to additionally run one real one-shot through the
# installed hermes (costs one NIM free-tier call).
#
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/invoke.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$INVOKE" ] || fail "invoke.sh not found at $INVOKE"

# ── stub interpreter ────────────────────────────────────────────────────────
# Records its argv + the HERMES_* env contract to a file, then prints a canned
# response. invoke.sh treats it exactly like the hermes venv python.
stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-test.XXXXXX")"
trap 'rm -rf "$stub_dir"' EXIT
stub="$stub_dir/fake-python"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
{
  echo "argv:$*"
  echo "model:${HERMES_ONESHOT_MODEL:-}"
  echo "profile:${HERMES_ONESHOT_PROFILE:-}"
  echo "toolsets:${HERMES_ONESHOT_TOOLSETS:-}"
  echo "promptfile:${HERMES_PROMPT_FILE:-}"
  echo "state_dir:${PARITY_GUARD_STATE_DIR:-}"
  if [ -n "${HERMES_PROMPT_FILE:-}" ]; then
    pf="${HERMES_PROMPT_FILE}"
    command -v cygpath >/dev/null 2>&1 && pf="$(cygpath -u "$pf")"
    echo "prompt:$(cat "$pf")"
  fi
} > "${STUB_CAPTURE:?}"
printf '%s' "${STUB_RESPONSE:-stub-ok}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub"
export HERMES_PY="$stub"

# HIMMEL-2241: invoke.sh appends a flow-run start row BEFORE it spawns the
# interpreter and an end row on every exit path, so HERMES_PY (a MODEL stub)
# does not keep these tests out of the ledger. Tests 1-7b below and the opt-in
# live-smoke block carried no redirect and wrote the PRODUCTION ledger --
# test 6 (STUB_RC=7) as an outcome=error row, the shape that pages
# HimmelFlowRunError. A deliberately SEPARATE path from $LEDGER below, so the
# ledger-asserting tests keep their own clean file and their explicit
# per-invocation overrides still win.
export HIMMEL_FLOW_RUNS_LEDGER="$stub_dir/flow-runs-scratch.jsonl"

# 1. Positional prompt reaches the interpreter via the prompt file.
echo "test: positional prompt" >&2
export STUB_CAPTURE="$stub_dir/cap1"
out="$(bash "$INVOKE" "hello critic")" || fail "positional prompt: non-zero exit"
[ "$out" = "stub-ok" ] || fail "positional prompt: unexpected stdout: $out"
grep -q "^prompt:hello critic$" "$STUB_CAPTURE" || fail "positional prompt: prompt not delivered via file"
grep -q "^toolsets:todo$" "$STUB_CAPTURE" || fail "positional prompt: default toolsets is not todo"
echo "  ok" >&2

# 2. Stdin prompt.
echo "test: stdin prompt" >&2
export STUB_CAPTURE="$stub_dir/cap2"
out="$(printf 'from stdin' | bash "$INVOKE" -)" || fail "stdin prompt: non-zero exit"
grep -q "^prompt:from stdin$" "$STUB_CAPTURE" || fail "stdin prompt: prompt not delivered"
echo "  ok" >&2

# 3. --prompt-file pass-through (no copy through argv).
echo "test: --prompt-file" >&2
export STUB_CAPTURE="$stub_dir/cap3"
printf 'big pack payload' > "$stub_dir/pack.txt"
bash "$INVOKE" --prompt-file "$stub_dir/pack.txt" >/dev/null || fail "--prompt-file: non-zero exit"
grep -q "^prompt:big pack payload$" "$STUB_CAPTURE" || fail "--prompt-file: payload not delivered"
echo "  ok" >&2

# 4. --model + --toolsets reach the env contract.
echo "test: --model/--toolsets passthrough" >&2
export STUB_CAPTURE="$stub_dir/cap4"
bash "$INVOKE" --model some/model --toolsets coding "x" >/dev/null || fail "passthrough: non-zero exit"
grep -q "^model:some/model$" "$STUB_CAPTURE" || fail "passthrough: model missing"
grep -q "^toolsets:coding$" "$STUB_CAPTURE" || fail "passthrough: toolsets missing"
echo "  ok" >&2

# 5. Empty prompt errors out (exit 2), interpreter never invoked.
echo "test: empty prompt rejected" >&2
export STUB_CAPTURE="$stub_dir/cap5"
printf '' | bash "$INVOKE" - >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "empty prompt: expected exit 2, got $rc"
[ ! -f "$STUB_CAPTURE" ] || fail "empty prompt: interpreter was invoked"
echo "  ok" >&2

# 6. Stub failure rc propagates.
echo "test: interpreter rc propagates" >&2
export STUB_CAPTURE="$stub_dir/cap6"
STUB_RC=7 bash "$INVOKE" "x" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 7 ] || fail "rc propagation: expected 7, got $rc"
echo "  ok" >&2

# 7a. --profile forwarded when the profile directory exists (HIMMEL-558).
echo "test: --profile forwarded when profile exists" >&2
export STUB_CAPTURE="$stub_dir/cap7a"
mkdir -p "$stub_dir/profiles/himmel_agent"
HERMES_HOME="$stub_dir" bash "$INVOKE" --profile himmel_agent "x" >/dev/null 2>&1 \
    || fail "profile-exists: non-zero exit"
grep -q "^profile:himmel_agent$" "$STUB_CAPTURE" \
    || fail "profile-exists: HERMES_ONESHOT_PROFILE not set to himmel_agent"
echo "  ok" >&2

# 7b. --profile with a MISSING profile → warn + fall back to default (empty).
echo "test: --profile missing profile warns + falls back" >&2
export STUB_CAPTURE="$stub_dir/cap7b"
prof_err="$stub_dir/cap7b.err"
HERMES_HOME="$stub_dir" bash "$INVOKE" --profile no_such_profile "x" >/dev/null 2>"$prof_err" \
    || fail "profile-missing: non-zero exit (must fail-open, not error)"
grep -q "^profile:$" "$STUB_CAPTURE" \
    || fail "profile-missing: expected empty profile env (fallback to default)"
grep -q "not found" "$prof_err" \
    || fail "profile-missing: expected 'not found' warning on stderr"
echo "  ok" >&2

# 8. Watchdog + deny-escalation (HIMMEL-2025).
echo "test: default HERMES_INVOKE_TIMEOUT matches lanes.json hermes-oneshot" >&2
if command -v node >/dev/null 2>&1; then
    LANE_TIMEOUT="$(node -e '
const l = require(process.argv[1]).lanes.find(x => x.id === "hermes-oneshot");
process.stdout.write(String(l.dispatch.timeoutSeconds));
' "$SCRIPT_DIR/../lanes/lanes.json" 2>/dev/null)"
    # shellcheck disable=SC2016 # the sed script is a literal match against invoke.sh's source text, not an expansion
    SCRIPT_DEFAULT="$(sed -n 's/^invoke_timeout="\${HERMES_INVOKE_TIMEOUT:-\([0-9]*\)}"$/\1/p' "$INVOKE")"
    if [ -n "$LANE_TIMEOUT" ] && [ "$LANE_TIMEOUT" = "$SCRIPT_DEFAULT" ]; then
        echo "  ok" >&2
    else
        fail "watchdog budget drift: lanes.json=$LANE_TIMEOUT invoke.sh=$SCRIPT_DEFAULT"
    fi
else
    echo "  SKIP (no node)" >&2
fi

echo "test: malformed HERMES_INVOKE_TIMEOUT refused" >&2
export STUB_CAPTURE="$stub_dir/cap8a"
HERMES_INVOKE_TIMEOUT=nope bash "$INVOKE" "x" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "malformed timeout: expected exit 2, got $rc"
[ ! -f "$STUB_CAPTURE" ] || fail "malformed timeout: interpreter was invoked"
echo "  ok" >&2

echo "test: over-ceiling HERMES_INVOKE_TIMEOUT refused" >&2
export STUB_CAPTURE="$stub_dir/cap8b"
HERMES_INVOKE_TIMEOUT=86401 bash "$INVOKE" "x" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "over-ceiling timeout: expected exit 2, got $rc"
[ ! -f "$STUB_CAPTURE" ] || fail "over-ceiling timeout: interpreter was invoked"
echo "  ok" >&2

echo "test: PARITY_GUARD_STATE_DIR exported to the interpreter env" >&2
export STUB_CAPTURE="$stub_dir/cap8c"
bash "$INVOKE" "hello" >/dev/null || fail "state-dir export: non-zero exit"
grep -q "^state_dir:" "$STUB_CAPTURE" || fail "state-dir export: line missing"
val="$(grep "^state_dir:" "$STUB_CAPTURE" | cut -d: -f2-)"
[ -n "$val" ] || fail "state-dir export: PARITY_GUARD_STATE_DIR was empty"
echo "  ok" >&2

LEDGER="$stub_dir/flow-runs.jsonl"

echo "test: watchdog timeout kills a wedged run + ledger row" >&2
HANG_STUB="$stub_dir/fake-python-hang"
cat > "$HANG_STUB" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 1; done
EOF
chmod +x "$HANG_STUB"
: > "$LEDGER"
start_ts=$(date +%s)
HERMES_PY="$HANG_STUB" HERMES_INVOKE_TIMEOUT=2 HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$INVOKE" "x" >/dev/null 2>"$stub_dir/timeout.err"
rc=$?
elapsed=$(( $(date +%s) - start_ts ))
[ "$rc" -eq 124 ] || fail "watchdog timeout: expected rc 124, got $rc"
grep -q "TIMEOUT after 2s" "$stub_dir/timeout.err" || fail "watchdog timeout: message missing ($(cat "$stub_dir/timeout.err"))"
grep -q '"outcome":"timeout"' "$LEDGER" || fail "watchdog timeout: no ledger end row"
[ "$elapsed" -lt 30 ] || fail "watchdog timeout: took too long (${elapsed}s) — kill-tree may not have worked"
echo "  ok" >&2

echo "test: deny-escalation marker aborts the run + ledger row" >&2
DENY_STUB="$stub_dir/fake-python-deny"
cat > "$DENY_STUB" <<'EOF'
#!/usr/bin/env bash
# Simulates parity_guard.py's Nth-identical-deny marker landing mid-run, then
# hangs like an unbounded deny-retry loop — only invoke.sh's marker poll ends
# this, not the (long) wall-clock timeout set below.
if [ -n "${PARITY_GUARD_STATE_DIR:-}" ]; then
    mkdir -p "$PARITY_GUARD_STATE_DIR"
    sleep 1
    printf 'test-deny-reason' > "$PARITY_GUARD_STATE_DIR/abort"
fi
while :; do sleep 1; done
EOF
chmod +x "$DENY_STUB"
: > "$LEDGER"
HERMES_PY="$DENY_STUB" HERMES_INVOKE_TIMEOUT=30 HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$INVOKE" "x" >/dev/null 2>"$stub_dir/deny.err"
rc=$?
[ "$rc" -eq 125 ] || fail "deny-escalation: expected rc 125, got $rc"
grep -q "test-deny-reason" "$stub_dir/deny.err" || fail "deny-escalation: reason not surfaced on stderr ($(cat "$stub_dir/deny.err"))"
grep -q '"outcome":"denied"' "$LEDGER" || fail "deny-escalation: no ledger end row"
echo "  ok" >&2

echo "test: hermes iteration-budget banner marks the run truncated (HIMMEL-2049)" >&2
export STUB_CAPTURE="$stub_dir/cap9"
: > "$LEDGER"
STUB_RESPONSE="some partial answer
⚠ Iteration budget reached (150/150) — response may be incomplete" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$INVOKE" "x" >/dev/null 2>"$stub_dir/budget.err"
rc=$?
[ "$rc" -eq 126 ] || fail "iteration-budget: expected rc 126, got $rc"
grep -q "TRUNCATED" "$stub_dir/budget.err" || fail "iteration-budget: advisory missing on stderr ($(cat "$stub_dir/budget.err"))"
grep -q "150/150" "$stub_dir/budget.err" || fail "iteration-budget: banner numbers not surfaced on stderr"
grep -q '"outcome":"truncated"' "$LEDGER" || fail "iteration-budget: no ledger end row with outcome=truncated"
echo "  ok" >&2

echo "test: an unwritable --log path refuses instead of silently losing capture (HIMMEL-2049 CR)" >&2
export STUB_CAPTURE="$stub_dir/cap10b"
bash "$INVOKE" --log "$stub_dir/no-such-dir/run.log" "x" >/dev/null 2>"$stub_dir/badlog.err"
rc=$?
[ "$rc" -eq 2 ] || fail "unwritable --log: expected exit 2, got $rc"
grep -q "cannot write a capture file" "$stub_dir/badlog.err" || fail "unwritable --log: expected message missing ($(cat "$stub_dir/badlog.err"))"
[ ! -f "$STUB_CAPTURE" ] || fail "unwritable --log: interpreter was invoked"
echo "  ok" >&2

echo "test: a normal response with no banner is unaffected" >&2
export STUB_CAPTURE="$stub_dir/cap10"
: > "$LEDGER"
STUB_RESPONSE="ordinary hermes output, no budget banner here" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$INVOKE" "x" >/dev/null 2>"$stub_dir/normal.err"
rc=$?
[ "$rc" -eq 0 ] || fail "normal response: expected rc 0, got $rc"
grep -q '"outcome":"complete"' "$LEDGER" || fail "normal response: expected outcome=complete in ledger"
echo "  ok" >&2

# 7. Optional live smoke (one NIM free-tier call) — opt-in only.
if [ "${HERMES_LIVE_TEST:-0}" = "1" ]; then
    echo "test: LIVE one-shot (nemotron nano)" >&2
    unset HERMES_PY
    out="$(bash "$INVOKE" --model nvidia/nemotron-3-nano-30b-a3b "Reply with exactly the single word PONG and nothing else.")" \
        || fail "live: non-zero exit"
    case "$out" in
        *PONG*) echo "  ok: live response contained PONG" >&2 ;;
        *) fail "live: response did not contain PONG (got: $out)" ;;
    esac
fi

echo "PASS: all invoke.sh tests passed." >&2
exit 0
