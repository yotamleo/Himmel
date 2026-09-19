#!/usr/bin/env bash
# Unit test for scripts/upstream/run-target-tests.sh (HIMMEL-3053). Exit 0 if all pass.
#
# Stub-only: the "target" is a fake `pytest` on PATH that records the env it
# received. Nothing here starts hermes or touches a real ~/.hermes — the "live
# home" is a fixture dir under a per-run temp root.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAP="$SCRIPT_DIR/run-target-tests.sh"

_fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s: %s\n' "$1" "$2"; _fail=$((_fail+1)); }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/run-target-tests-test.XXXXXX") || { echo "cannot create temporary directory" >&2; exit 1; }
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT

LIVE="$TMP_ROOT/live-home"          # stands in for the operator's live ~/.hermes
FAKE_HOME="$TMP_ROOT/fakehome"
SANDBOX_TMP="$TMP_ROOT/tmp"         # where the wrapper's mktemp lands
BIN="$TMP_ROOT/bin"
REC="$TMP_ROOT/rec"                 # the stub's record dir
mkdir -p "$LIVE" "$FAKE_HOME" "$SANDBOX_TMP" "$BIN" "$REC"

# The stub target: records the env + args + cwd it was handed, and whether the
# HERMES_HOME it saw existed at run time. STUB_RC / STUB_TERM steer it.
cat > "$BIN/pytest" <<'STUB'
#!/usr/bin/env bash
: "${REC:?stub needs REC}"
{ env; } > "$REC/env"
{ printf '%s\n' "$@"; } > "$REC/args"
pwd -P > "$REC/cwd"
if [ -d "${HERMES_HOME:-/nonexistent}" ]; then echo yes > "$REC/home-existed"; else echo no > "$REC/home-existed"; fi
[ -n "${STUB_TERM:-}" ] && kill -TERM "$PPID"
exit "${STUB_RC:-0}"
STUB
chmod +x "$BIN/pytest"

recorded() { grep "^$1=" "$REC/env" 2>/dev/null | sed "s/^$1=//"; }
reset_rec() { rm -f "$REC"/*; }

# Common env for the wrapper runs: a live-looking home plus extra HERMES_* state.
run_wrapped() {
    env HERMES_HOME="$LIVE" HERMES_PROFILE=coder HERMES_KANBAN_DB="$LIVE/kanban.db" \
        HOME="$FAKE_HOME" TMPDIR="$SANDBOX_TMP" REC="$REC" PATH="$BIN:$PATH" KEEP_ME=kept \
        "$@"
}

echo "TEST: RED control — WITHOUT the wrapper the stub inherits the live HERMES_HOME"
reset_rec
env HERMES_HOME="$LIVE" HERMES_PROFILE=coder REC="$REC" PATH="$BIN:$PATH" pytest tests/ >/dev/null 2>&1
seen=$(recorded HERMES_HOME)
if [ "$seen" = "$LIVE" ]; then
    pass "bare run: stub saw the live home ($seen) — the problem this wrapper exists for"
else
    fail "bare run baseline" "expected stub to inherit '$LIVE', saw '$seen'"
fi

echo "TEST: wrapper hands the target a fresh temp HERMES_HOME, never the live one"
reset_rec
run_wrapped bash "$WRAP" pytest tests/ >/dev/null 2>"$TMP_ROOT/err"; rc=$?
seen=$(recorded HERMES_HOME)
case "$seen" in "$SANDBOX_TMP"/hermes-test-home.*) under_tmp=1 ;; *) under_tmp=0 ;; esac
if [ "$rc" -eq 0 ] && [ -n "$seen" ] && [ "$seen" != "$LIVE" ] && [ "$under_tmp" -eq 1 ]; then
    pass "stub saw '$seen' (rc=$rc), not '$LIVE'"
else
    fail "sandbox home" "rc=$rc seen='$seen' live='$LIVE' err=$(cat "$TMP_ROOT/err")"
fi

echo "TEST: the sandbox existed during the run and is removed afterwards"
existed=$(cat "$REC/home-existed" 2>/dev/null || true)
if [ "$existed" = "yes" ] && [ ! -e "$seen" ]; then
    pass "existed during run, gone after"
else
    fail "sandbox lifecycle" "home-existed='$existed' still-present=$([ -e "$seen" ] && echo yes || echo no)"
fi

echo "TEST: every other HERMES_* var is scrubbed; unrelated vars pass through"
p=$(recorded HERMES_PROFILE); k=$(recorded HERMES_KANBAN_DB); keep=$(recorded KEEP_ME)
if [ -z "$p" ] && [ -z "$k" ] && [ "$keep" = "kept" ]; then
    pass "HERMES_PROFILE/HERMES_KANBAN_DB unset, KEEP_ME kept"
else
    fail "env scrub" "HERMES_PROFILE='$p' HERMES_KANBAN_DB='$k' KEEP_ME='$keep'"
fi

echo "TEST: live home is untouched (still empty) after the run"
if [ -z "$(ls -A "$LIVE")" ]; then
    pass "live home has no entries"
else
    fail "live home" "wrapper left entries: $(ls -A "$LIVE")"
fi

echo "TEST: args pass through verbatim (spaces intact) and --cwd is honoured"
reset_rec
mkdir -p "$TMP_ROOT/clone"
run_wrapped bash "$WRAP" --cwd "$TMP_ROOT/clone" -- pytest -k "a b" "x y" >/dev/null 2>&1
got_args=$(tr '\n' '|' < "$REC/args" 2>/dev/null)
got_cwd=$(cat "$REC/cwd" 2>/dev/null)
want_cwd=$(cd "$TMP_ROOT/clone" && pwd -P)
if [ "$got_args" = "-k|a b|x y|" ] && [ "$got_cwd" = "$want_cwd" ]; then
    pass "args='$got_args' cwd ok"
else
    fail "args/cwd" "args='$got_args' cwd='$got_cwd' want cwd='$want_cwd'"
fi

echo "TEST: the target's exit status is propagated"
reset_rec
run_wrapped STUB_RC=7 bash "$WRAP" pytest >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 7 ]; then pass "rc=7 propagated"; else fail "rc propagation" "rc=$rc want 7"; fi
if [ -z "$(ls -A "$SANDBOX_TMP")" ]; then pass "sandbox removed after a failing target"; else fail "cleanup on failure" "left: $(ls -A "$SANDBOX_TMP")"; fi

echo "TEST: the sandbox is removed when the wrapper is TERMed mid-run"
reset_rec
run_wrapped STUB_TERM=1 bash "$WRAP" pytest >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 143 ] && [ -z "$(ls -A "$SANDBOX_TMP")" ]; then
    pass "rc=143, no leftover sandbox"
else
    fail "TERM cleanup" "rc=$rc left='$(ls -A "$SANDBOX_TMP")'"
fi

echo "TEST: REFUSES when the sandbox would land inside the caller's live HERMES_HOME"
reset_rec
run_wrapped TMPDIR="$LIVE" bash "$WRAP" pytest >/dev/null 2>"$TMP_ROOT/err"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$REC/env" ] && [ -z "$(ls -A "$LIVE")" ] && grep -q 'REFUS' "$TMP_ROOT/err"; then
    pass "rc=2, stub never ran, live home left clean, loud stderr"
else
    fail "refusal (HERMES_HOME)" "rc=$rc stub-ran=$([ -e "$REC/env" ] && echo yes || echo no) live='$(ls -A "$LIVE")' err=$(cat "$TMP_ROOT/err")"
fi

echo "TEST: REFUSES when HERMES_HOME is unset and the sandbox would land in the default ~/.hermes"
reset_rec
mkdir -p "$FAKE_HOME/.hermes"
env -u HERMES_HOME HOME="$FAKE_HOME" TMPDIR="$FAKE_HOME/.hermes" REC="$REC" PATH="$BIN:$PATH" \
    bash "$WRAP" pytest >/dev/null 2>"$TMP_ROOT/err"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$REC/env" ] && [ -z "$(ls -A "$FAKE_HOME/.hermes")" ] && grep -q 'REFUS' "$TMP_ROOT/err"; then
    pass "rc=2 against the default home"
else
    fail "refusal (default home)" "rc=$rc stub-ran=$([ -e "$REC/env" ] && echo yes || echo no) err=$(cat "$TMP_ROOT/err")"
fi

echo "TEST: no command → usage error, rc=2"
run_wrapped bash "$WRAP" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "rc=2"; else fail "usage" "rc=$rc"; fi

echo
if [ "$_fail" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "FAILURES: $_fail"
exit 1
