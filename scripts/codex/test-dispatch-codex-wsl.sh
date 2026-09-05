#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181,SC2012,SC2016 # test harness intentionally uses compact status assertions and literal grep patterns.
# Hermetic tests for dispatch-codex-wsl.sh (HIMMEL-999). No real WSL: a stub
# wsl.exe records argv/stdin and plays scripted verification/quota outputs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch-codex-wsl.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
assert_rc() { if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$3 (rc=$RC)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOCKS="$TMP/locks"
LEDGER="$TMP/flow-runs.jsonl"

# wsl.exe stub. Protocol keyed on ARGV shape: the verification round trip
# is `-d <distro> -- bash -s -- <clone> <root>` (the verify script arrives
# on stdin - drain it) -> answer $STUB_VERIFY_OUT + rc $STUB_VERIFY_RC; the
# quota preflight is a `bash -lc` script containing "rollout" ->
# $STUB_QUOTA_OUT + rc $STUB_QUOTA_RC; the dispatch contains "codex exec"
# -> record stdin to codex.stdin, argv to codex.args, exit $STUB_CODEX_RC.
WSL_STUB="$TMP/wsl-stub"
cat > "$WSL_STUB" <<EOF
#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181,SC2012,SC2016 # test harness intentionally uses compact status assertions and literal grep patterns.
printf '%s\n' "\$*" >> "$TMP/wsl.calls"
case "\$*" in
  *"bash -s --"*) cat >/dev/null; printf '%s\n' "\${STUB_VERIFY_OUT:-}"; exit "\${STUB_VERIFY_RC:-0}" ;;
  *rollout*)      printf '%s\n' "\${STUB_QUOTA_OUT:-}";  exit "\${STUB_QUOTA_RC:-0}" ;;
  *"codex exec"*) cat > "$TMP/codex.stdin"; printf '%s\n' "\$*" > "$TMP/codex.args"; exit "\${STUB_CODEX_RC:-0}" ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$WSL_STUB"

run_dispatch() {  # run_dispatch <args...>
  rm -f "$TMP/wsl.calls" "$TMP/codex.stdin" "$TMP/codex.args"
  # </dev/null: the no-brief path hands the dispatcher's OWN stdin to the
  # backgrounded child (<&0) and the stub's dispatch branch cat-reads it -
  # an open terminal stdin would hang every no-brief test forever.
  CODEX_WSL_BIN="$WSL_STUB" CODEX_WSL_LOCKS_DIR="$LOCKS" \
  HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
  bash "$DISPATCH" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null
  RC=$?
}

echo "test: missing args -> usage"
run_dispatch; assert_rc 2 "no args usage" "no-args accepted"
run_dispatch --distro Ubuntu; assert_rc 2 "missing --clone usage" "missing clone accepted"

echo "test: /mnt/* clone refused"
run_dispatch --distro Ubuntu --clone /mnt/c/work/himmel "hi"
assert_rc 2 "/mnt clone refused" "/mnt clone accepted"
grep -q "refusing clone under /mnt/" "$TMP/err" || fail "/mnt message missing"

echo "test: relative clone refused"
run_dispatch --distro Ubuntu --clone work/himmel "hi"
assert_rc 2 "relative clone refused" "relative clone accepted"

echo "test: clone path with spaces/quotes refused"
run_dispatch --distro Ubuntu --clone "/home/u/w x" "hi"
assert_rc 2 "whitespace clone refused" "whitespace clone accepted"

echo "test: clone path with shell metacharacters refused (codex-adv: cd \"\$CLONE\" re-eval)"
run_dispatch --distro Ubuntu --clone '/home/u/work/$(id)' "hi"
assert_rc 2 "command-substitution clone refused" "command-substitution clone accepted"
grep -q "shell metacharacter" "$TMP/err" || fail "metachar refusal message missing"
run_dispatch --distro Ubuntu --clone '/home/u/work/`id`' "hi"
assert_rc 2 "backtick clone refused" "backtick clone accepted"

echo "test: refused passthrough flag (via shared filter, WSL hints)"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel --cd /tmp "hi"
assert_rc 2 "--cd refused" "--cd accepted"
grep -q "^dispatch-codex-wsl.sh: workspace-redirect flag '--cd' refused - the wrapper owns the clone (pass it via --clone)$" "$TMP/err" \
  || fail "WSL-parameterized message wrong: $(cat "$TMP/err")"

echo "test: verification failure -> exit 2"
STUB_VERIFY_RC=3 run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 2 "verify fail exits 2" "verify fail accepted"

echo "test: verification round trip ships codex-wsl-verify.sh via bash -s with clone arg"
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="" run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "happy path rc 0" "happy path failed: $(cat "$TMP/err")"
head -1 "$TMP/wsl.calls" | grep -q -- "bash -s -- /home/u/work/himmel" || fail "verify call shape wrong"
head -1 "$TMP/wsl.calls" | grep -q -- "-d Ubuntu" || fail "distro not passed to wsl"

echo "test: codex-wsl-verify.sh unit - containment decisions run locally"
VERIFY="$SCRIPT_DIR/codex-wsl-verify.sh"
FAKE_ROOT="$TMP/fakehome/work"
mkdir -p "$FAKE_ROOT/goodclone" "$TMP/outside/badclone"
git -C "$FAKE_ROOT/goodclone" init -q
bash "$VERIFY" "$FAKE_ROOT/goodclone" "$FAKE_ROOT" >"$TMP/v.out" 2>/dev/null
[ $? -eq 0 ] && pass "in-root git clone verifies" || fail "in-root clone refused"
grep -q "goodclone" "$TMP/v.out" || fail "verify does not print the physical path"
bash "$VERIFY" "$TMP/outside/badclone" "$FAKE_ROOT" >/dev/null 2>&1
[ $? -eq 4 ] && pass "out-of-root clone rc 4" || fail "out-of-root clone not refused"
mkdir -p "$FAKE_ROOT/notgit"
bash "$VERIFY" "$FAKE_ROOT/notgit" "$FAKE_ROOT" >/dev/null 2>&1
[ $? -eq 5 ] && pass "non-git dir rc 5" || fail "non-git dir not refused"
bash "$VERIFY" "$FAKE_ROOT/absent" "$FAKE_ROOT" >/dev/null 2>&1
[ $? -eq 3 ] && pass "missing dir rc 3" || fail "missing dir wrong rc"
# Symlink escape: a link under root resolving outside it must rc 4.
# Skip-guarded: MSYS ln -s may copy instead of link.
if ln -s "$TMP/outside/badclone" "$FAKE_ROOT/sneaky" 2>/dev/null && [ -L "$FAKE_ROOT/sneaky" ]; then
  bash "$VERIFY" "$FAKE_ROOT/sneaky" "$FAKE_ROOT" >/dev/null 2>&1
  [ $? -eq 4 ] && pass "symlink escape rc 4" || fail "symlink escape not caught"
else
  pass "symlink escape SKIPPED (no symlink support in this shell)"
fi
# /mnt arm is not fabricable locally - assert the case arm textually.
grep -q '/mnt/\*' "$VERIFY" || fail "/mnt case arm missing from verify script"

echo "test: wsl.exe missing -> 127"
CODEX_WSL_BIN="$TMP/definitely-absent" CODEX_WSL_LOCKS_DIR="$LOCKS" bash "$DISPATCH" --distro U --clone /home/u/work/x "hi" 2>"$TMP/err"
RC=$?; assert_rc 127 "wsl missing 127" "wsl missing wrong rc"

echo "test: lock held -> exit 4; keyed on RESOLVED physical path"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"  # derive lock name
LOCK_DIR="$(ls -d "$LOCKS"/* 2>/dev/null | head -1)"
[ -n "$LOCK_DIR" ] && fail "lock left behind after clean exit" || pass "lock released on exit"
# Lock key = printf '%s_%s' Ubuntu /home/u/work/himmel | tr '/:| .' '_____'
# = "Ubuntu__home_u_work_himmel" (separator underscore + leading-slash
# underscore = TWO consecutive underscores; do not hand-count to three).
LOCK_KEY_DIR="$LOCKS/Ubuntu__home_u_work_himmel"
mkdir -p "$LOCK_KEY_DIR"
echo 999999 > "$LOCK_KEY_DIR/pid"
# holder pid 999999 is (almost surely) dead -> stale auto-break, dispatch proceeds
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel/ "hi"
assert_rc 0 "stale lock auto-broken + trailing-slash alias same lock" "stale lock blocked"
grep -q "stale lock" "$TMP/err" || fail "stale-break note missing"
mkdir -p "$LOCK_KEY_DIR"
echo $$ > "$LOCK_KEY_DIR/pid"   # OUR live pid -> genuinely held
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 4 "live lock -> exit 4" "live lock not honored"
rm -rf "$LOCK_KEY_DIR"
# codex-adv HIMMEL-999: a lock dir with NO pid file (winner mkdir'd but has
# not yet written its pid) is a live acquisition in progress, NOT stale - it
# must NOT be broken. Deterministic stand-in for the mkdir/echo race window.
echo "test: empty-pid lock -> acquisition-in-progress, exit 4 (not stale-broken)"
mkdir -p "$LOCK_KEY_DIR"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 4 "empty-pid lock not stale-broken" "empty-pid lock wrongly broken (race window)"
grep -q "no pid after a grace window" "$TMP/err" || fail "empty-pid in-progress note missing"
rm -rf "$LOCK_KEY_DIR"

echo "test: ledger start+end rows with task_name audit line"
rm -f "$LEDGER"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "ledger run ok" "ledger run failed"
grep -q '"ev":"start"' "$LEDGER" || fail "start row missing"
grep -q '"ev":"end"' "$LEDGER" || fail "end row missing"
grep -q '"flow":"codex-wsl"' "$LEDGER" || fail "flow name wrong"
grep -q '"task_name":"Ubuntu:/home/u/work/himmel"' "$LEDGER" || fail "task_name audit line wrong"

echo "test: brief file crosses as the backgrounded child's stdin, materialized positionally"
BRIEF="$TMP/brief.md"; printf 'do the thing\nline two\n' > "$BRIEF"
rm -f "$LEDGER"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel --brief-file "$BRIEF"
assert_rc 0 "brief run ok" "brief run failed"
diff -q "$BRIEF" "$TMP/codex.stdin" >/dev/null 2>&1 || fail "stub wsl did not receive the brief bytes on stdin"
grep -q 'codex exec .*"\$(cat)"' "$TMP/codex.args" || fail "in-distro command does not materialize the brief positionally"
grep -q ':brief=brief.md' "$LEDGER" || fail "brief name missing from task_name"

echo "test: quota - live hard reading refuses with exit 3"
NOW=$(date +%s); FUTURE=$((NOW + 3600))
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="90 $FUTURE $NOW" \
  run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 3 "quota hard refuses" "quota hard did not refuse"
grep -q "CODEX_WSL_QUOTA_OK=1" "$TMP/err" || fail "quota message misses override"

echo "test: quota - CODEX_WSL_QUOTA_OK=1 bypasses hard"
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="90 $FUTURE $NOW" CODEX_WSL_QUOTA_OK=1 \
  run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "quota bypass works" "quota bypass failed"

echo "test: quota - warn passes through with stderr note"
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="70 $FUTURE $NOW" \
  run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "quota warn proceeds" "quota warn blocked"
grep -q "WARN" "$TMP/err" || fail "quota warn note missing"

echo "test: quota - EXPIRED resets_at never hard-denies (stale -> warn+proceed)"
PAST=$((NOW - 3600))
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="90 $PAST $NOW" \
  run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "expired window proceeds" "expired window hard-denied"
grep -qi "stale" "$TMP/err" || fail "stale note missing (expired resets_at)"

echo "test: quota - over-age rollout mtime never hard-denies"
OLD=$((NOW - 200000))
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="90 $FUTURE $OLD" \
  run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "over-age proceeds" "over-age hard-denied"
grep -qi "stale" "$TMP/err" || fail "stale note missing (over-age mtime)"

echo "test: quota - missing telemetry fail-open"
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_QUOTA_OUT="" STUB_QUOTA_RC=9 \
  run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 0 "no telemetry proceeds" "no telemetry blocked"
echo "test: pins present in the composed in-distro command"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
grep -q -- "--model gpt-5.5" "$TMP/codex.args" || fail "model pin missing"
grep -q -- "--sandbox workspace-write" "$TMP/codex.args" || fail "sandbox pin missing"

echo "test: caller-named model overrides the pin with a WARN"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel --model gpt-5.5-codex "hi"
assert_rc 0 "caller model ok" "caller model failed"
grep -q "WARN caller-named model" "$TMP/err" || fail "model-override WARN missing"
# Passthrough words are single-quoted individually in the composed in-distro
# command (wrapper safety), so the caller model appears as '--model' 'gpt-5.5-codex'.
grep -q -- "'--model' 'gpt-5.5-codex'" "$TMP/codex.args" || fail "caller model not passed through"

echo "test: --reasoning-effort becomes the trusted -c override"
STUB_VERIFY_OUT="/home/u/work/himmel" run_dispatch --distro Ubuntu --clone /home/u/work/himmel --reasoning-effort xhigh "hi"
grep -q 'model_reasoning_effort' "$TMP/codex.args" || fail "effort -c override missing"

echo "test: exit-code propagation"
STUB_VERIFY_OUT="/home/u/work/himmel" STUB_CODEX_RC=7 run_dispatch --distro Ubuntu --clone /home/u/work/himmel "hi"
assert_rc 7 "codex rc propagated" "codex rc not propagated"
grep -q '"outcome":"error"' "$LEDGER" || fail "error outcome missing on nonzero rc"
echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)" >&2; exit 1; fi
echo "all tests passed"
