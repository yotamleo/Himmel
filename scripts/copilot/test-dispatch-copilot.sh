#!/usr/bin/env bash
# Hermetic tests for dispatch-copilot.sh (HIMMEL-772).
# No real copilot install: COPILOT_BIN injects a stub that records its argv
# and cwd. Asserts the lane invariants: physical-path worktree containment,
# the allow-list (banned flags refused by name, unknown dash flags refused by
# the catch-all), the composed permission grants, the auto-model pin, the
# COPILOT_ALLOW_ALL_FALLBACK opt-in, and the per-lane ledger.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch-copilot.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
assert_rc() {  # assert_rc <expected> <ok-name> <fail-detail>
  if [ "$RC" -eq "$1" ]; then pass "$2"; else fail "$3"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WT="$TMP/.claude/worktrees/wt"
mkdir -p "$WT"
LOG="$TMP/calls.log"
LEDGER="$TMP/ledger.jsonl"

# copilot stub: records invocation, argv, and cwd; exits 0.
COPILOT_STUB="$TMP/copilot-stub"
cat > "$COPILOT_STUB" <<EOF
#!/usr/bin/env bash
echo "copilot" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/copilot.args"
pwd > "$TMP/copilot.cwd"
exit 0
EOF
chmod +x "$COPILOT_STUB"

run_dispatch() {  # run_dispatch <args...> ; sets $RC and $OUT
  set +e
  OUT="$(COPILOT_BIN="$COPILOT_STUB" COPILOT_LEDGER="$LEDGER" \
      bash "$DISPATCH" "$@" 2>&1)"
  RC=$?
  set -e
}

# --- 1: missing --worktree -> usage (exit 2) ---------------------------------
run_dispatch
assert_rc 2 "missing --worktree exits 2" "no-worktree rc=$RC out=$OUT"

# --- 2: nonexistent worktree -> exit 2 ---------------------------------------
run_dispatch --worktree "$TMP/does-not-exist"
assert_rc 2 "nonexistent worktree exits 2" "bad-worktree rc=$RC out=$OUT"

# --- 3: worktree outside .claude/worktrees -> exit 2 -------------------------
OUTSIDE="$TMP/not-a-worktree"
mkdir -p "$OUTSIDE"
run_dispatch --worktree "$OUTSIDE" -p do-it
assert_rc 2 "non-worktree directory refused" "outside rc=$RC out=$OUT"
case "$OUT" in *"outside .claude/worktrees"*) pass "outside refusal names the containment rule";; *) fail "outside out: $OUT";; esac

# --- 4: symlink escaping the physical path refused (pwd -P) ------------------
LINKED="$TMP/.claude/worktrees/linked-wt"
if ln -s "$OUTSIDE" "$LINKED" 2>/dev/null && [ -L "$LINKED" ]; then
  run_dispatch --worktree "$LINKED" -p do-it
  assert_rc 2 "symlinked worktree (physical target outside) refused" "symlink rc=$RC out=$OUT"
  rm -f "$LINKED"
else
  rm -rf "$LINKED"
  pass "symlink escape case skipped (no real symlinks on this platform)"
fi

# --- 5: each BANNED flag -> exit 2 with its named message --------------------
: > "$LOG"
run_dispatch --worktree "$WT" --allow-all-tools
assert_rc 2 "--allow-all-tools refused" "allow-all-tools rc=$RC out=$OUT"
case "$OUT" in *"--allow-all-tools refused"*) pass "--allow-all-tools message named";; *) fail "allow-all-tools out: $OUT";; esac

run_dispatch --worktree "$WT" --yolo
assert_rc 2 "--yolo refused" "yolo rc=$RC out=$OUT"
case "$OUT" in *"--yolo refused"*) pass "--yolo message named";; *) fail "yolo out: $OUT";; esac

run_dispatch --worktree "$WT" --allow-tool 'x'
assert_rc 2 "--allow-tool refused" "allow-tool rc=$RC out=$OUT"
case "$OUT" in *"--allow-tool refused"*) pass "--allow-tool message named";; *) fail "allow-tool out: $OUT";; esac

run_dispatch --worktree "$WT" --deny-url y
assert_rc 2 "--deny-url refused" "deny-url rc=$RC out=$OUT"
case "$OUT" in *"refused - the caller must not pass permission args"*) pass "--deny-url message named";; *) fail "deny-url out: $OUT";; esac

run_dispatch --worktree "$WT" --add-dir z
assert_rc 2 "--add-dir refused" "add-dir rc=$RC out=$OUT"
case "$OUT" in *"--add-dir refused"*) pass "--add-dir message named";; *) fail "add-dir out: $OUT";; esac

run_dispatch --worktree "$WT" -c 'k=v'
assert_rc 2 "-c refused" "dash-c rc=$RC out=$OUT"
case "$OUT" in *"refused - config overrides"*) pass "-c message named";; *) fail "dash-c out: $OUT";; esac

run_dispatch --worktree "$WT" --allow-all-paths
assert_rc 2 "--allow-all-paths refused" "allow-all-paths rc=$RC out=$OUT"
case "$OUT" in *"--allow-all-paths refused"*) pass "--allow-all-paths message named";; *) fail "allow-all-paths out: $OUT";; esac

# additional banned-flag coverage beyond the brief's minimum list
for bad in "--allow-all" "--allow-all-urls" "--no-ask-user" "--deny-tool" "--config" "--allow-frobnicate" "--deny-frobnicate"; do
  run_dispatch --worktree "$WT" "$bad"
  assert_rc 2 "refused: $bad" "flag $bad rc=$RC out=$OUT"
done
if grep -q copilot "$LOG" 2>/dev/null; then fail "copilot invoked despite a banned flag"; else pass "copilot never invoked on any banned flag"; fi

# --- 6: unknown dash flag -> exit 2 (catch-all) -------------------------------
run_dispatch --worktree "$WT" --no-such-flag
assert_rc 2 "unknown dash flag refused" "unknown rc=$RC out=$OUT"
case "$OUT" in *"not in the lane allow-list"*) pass "catch-all names the allow-list";; *) fail "unknown out: $OUT";; esac

# --- 7: happy path - composed flags present + positional prompt passes -------
: > "$LOG"; rm -f "$LEDGER"
run_dispatch --worktree "$WT" "do the task"
assert_rc 0 "happy path exits 0" "happy rc=$RC out=$OUT"
ARGS="$(cat "$TMP/copilot.args")"
case "$ARGS" in
  *"--add-dir $WT"*) pass "composed --add-dir present" ;;
  *) fail "missing --add-dir in: $ARGS" ;;
esac
case "$ARGS" in
  *"--deny-url *"*) pass "composed --deny-url '*' present" ;;
  *) fail "missing --deny-url in: $ARGS" ;;
esac
case "$ARGS" in
  *"--allow-tool shell(git:*)"*) pass "composed --allow-tool shell(git:*) present" ;;
  *) fail "missing shell(git:*) grant in: $ARGS" ;;
esac
case "$ARGS" in
  *"--allow-tool write"*) pass "composed --allow-tool write present" ;;
  *) fail "missing write grant in: $ARGS" ;;
esac
case "$ARGS" in
  *"--model auto"*) pass "--model auto pin present" ;;
  *) fail "missing --model auto in: $ARGS" ;;
esac
case "$ARGS" in
  *"do the task"*) pass "positional prompt passed through" ;;
  *) fail "positional prompt missing in: $ARGS" ;;
esac
case "$(basename "$(cat "$TMP/copilot.cwd")")" in
  "$(basename "$WT")") pass "copilot cwd is the worktree" ;;
  *) fail "copilot cwd: $(cat "$TMP/copilot.cwd")" ;;
esac

# --- 8: caller --model overrides the pin, with WARN ---------------------------
: > "$LOG"
run_dispatch --worktree "$WT" --model foo -p "do it"
assert_rc 0 "caller-model dispatch exits 0" "caller-model rc=$RC out=$OUT"
case "$OUT" in *"WARN caller-named model"*) pass "caller model warns";; *) fail "caller-model out: $OUT";; esac
ARGS="$(cat "$TMP/copilot.args")"
case "$ARGS" in
  *"--model foo"*) pass "caller model foo present in argv" ;;
  *) fail "caller-model args: $ARGS" ;;
esac
case "$ARGS" in
  *"--model auto"*) fail "auto pin still injected alongside caller model: $ARGS" ;;
  *) pass "auto pin NOT double-injected" ;;
esac

# --- 9: COPILOT_ALLOW_ALL_FALLBACK=1 swaps to --allow-all-tools ---------------
: > "$LOG"
set +e
OUT="$(COPILOT_BIN="$COPILOT_STUB" COPILOT_LEDGER="$LEDGER" COPILOT_ALLOW_ALL_FALLBACK=1 \
    bash "$DISPATCH" --worktree "$WT" -p do-it 2>&1)"
RC=$?
set -e
assert_rc 0 "fallback dispatch exits 0" "fallback rc=$RC out=$OUT"
case "$OUT" in *"WARN COPILOT_ALLOW_ALL_FALLBACK=1"*) pass "fallback WARN emitted";; *) fail "fallback out: $OUT";; esac
ARGS="$(cat "$TMP/copilot.args")"
case "$ARGS" in
  *"--allow-all-tools"*) pass "--allow-all-tools present under fallback" ;;
  *) fail "fallback args missing --allow-all-tools: $ARGS" ;;
esac
case "$ARGS" in
  *"--add-dir $WT"*) pass "--add-dir still present under fallback (containment kept)" ;;
  *) fail "fallback args missing --add-dir: $ARGS" ;;
esac
case "$ARGS" in
  *"--allow-all-paths"*) fail "fallback args must NOT include --allow-all-paths: $ARGS" ;;
  *) pass "no --allow-all-paths under fallback" ;;
esac
case "$ARGS" in
  *"shell(git:*)"*) fail "granular grant leaked under fallback: $ARGS" ;;
  *) pass "granular grants absent under fallback" ;;
esac

# --- 10: ledger writes one JSONL line with the expected keys -----------------
rm -f "$LEDGER"
run_dispatch --worktree "$WT" -p do-it
assert_rc 0 "ledger dispatch exits 0" "ledger-dispatch rc=$RC out=$OUT"
[ -f "$LEDGER" ] || fail "ledger file not created: $LEDGER"
LINES="$(wc -l < "$LEDGER" | tr -d ' ')"
if [ "$LINES" = "1" ]; then pass "ledger has exactly one line"; else fail "ledger line count: $LINES"; fi
LINE="$(cat "$LEDGER")"
for key in '"ts"' '"worktree"' '"model"' '"allow_all_fallback"'; do
  case "$LINE" in
    *"$key"*) pass "ledger line has key $key" ;;
    *) fail "ledger line missing key $key: $LINE" ;;
  esac
done

# --- 10.5: unwritable ledger dir -> dispatch still succeeds (WARN only) ------
BLOCKER="$TMP/blocker-file"
: > "$BLOCKER"
BAD_LEDGER="$BLOCKER/sub/ledger.jsonl"
set +e
OUT="$(COPILOT_BIN="$COPILOT_STUB" COPILOT_LEDGER="$BAD_LEDGER" \
    bash "$DISPATCH" --worktree "$WT" -p do-it 2>&1)"
RC=$?
set -e
assert_rc 0 "dispatch succeeds despite unwritable ledger dir" "bad-ledger rc=$RC out=$OUT"
case "$OUT" in *"WARN cannot create ledger dir"*) pass "unwritable ledger dir WARNs";; *) fail "bad-ledger out: $OUT";; esac

# --- 11: COPILOT_BIN missing -> exit 127 naming the override -----------------
set +e
OUT="$(COPILOT_BIN="$TMP/definitely-not-a-binary" COPILOT_LEDGER="$LEDGER" \
    bash "$DISPATCH" --worktree "$WT" -p do-it 2>&1)"
RC=$?
set -e
assert_rc 127 "missing copilot CLI exits 127" "no-copilot rc=$RC out=$OUT"
case "$OUT" in *"set COPILOT_BIN"*) pass "missing-copilot message names COPILOT_BIN";; *) fail "no-copilot out: $OUT";; esac

# --- 12: bash 3.2 empty-array safety - no bare "${arr[@]}" on the exec line --
# On bash < 4.4 (macOS ships 3.2.57) referencing an empty array as
# "${arr[@]}" under `set -u` raises "unbound variable". model_args is empty
# whenever the caller names a model (test 8 above already proves that path
# exits 0 on this bash 5.x harness, where the bug is latent) - the only real
# static guarantee against the 3.2 regression is that every array expansion
# on the exec line uses the empty-safe `${arr[@]+"${arr[@]}"}` idiom.
# shellcheck disable=SC2016  # the $ and [@] below are literal grep/case patterns, not expansions we want the shell to expand
EXEC_LINE="$(grep -n '^exec "\$COPILOT"' "$DISPATCH")"
# Strip the guarded idiom `${arr[@]+"${arr[@]}"}` out first - it legitimately
# contains the bare "${arr[@]}" substring - then anything left matching
# "${...[@]}" is an unguarded (bug-prone) expansion.
STRIPPED="$(printf '%s' "$EXEC_LINE" | sed -E 's/\$\{[a-zA-Z_]+\[@\]\+"\$\{[a-zA-Z_]+\[@\]\}"\}//g')"
case "$STRIPPED" in
  *'[@]'*) fail "exec line has a bare (unguarded) array expansion after stripping guarded ones: $STRIPPED" ;;
  *) pass "exec line has no bare array expansion" ;;
esac
# shellcheck disable=SC2016  # literal pattern text, not an expansion
case "$EXEC_LINE" in
  *'${grant_args[@]+"${grant_args[@]}"}'*) pass "grant_args uses the empty-safe expansion" ;;
  *) fail "grant_args missing empty-safe expansion: $EXEC_LINE" ;;
esac
# shellcheck disable=SC2016  # literal pattern text, not an expansion
case "$EXEC_LINE" in
  *'${model_args[@]+"${model_args[@]}"}'*) pass "model_args uses the empty-safe expansion" ;;
  *) fail "model_args missing empty-safe expansion: $EXEC_LINE" ;;
esac

# --- 13: caller-named model dispatch under set -u still reaches argv --------
: > "$LOG"
run_dispatch --worktree "$WT" --model my-model -p "do it"
assert_rc 0 "caller-named model exits 0 under set -u (empty model_args path)" "empty-model-args rc=$RC out=$OUT"
ARGS="$(cat "$TMP/copilot.args")"
case "$ARGS" in
  *"--model my-model"*) pass "caller model reaches copilot argv" ;;
  *) fail "caller model missing from argv: $ARGS" ;;
esac

# --- 14: ledger JSON-escapes a caller model containing a double-quote -------
rm -f "$LEDGER"
run_dispatch --worktree "$WT" --model 'a"b' -p "do it"
assert_rc 0 "quoted-model dispatch exits 0" "quoted-model rc=$RC out=$OUT"
LINE="$(cat "$LEDGER")"
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$LINE" | jq . >/dev/null 2>&1; then
    pass "ledger line with quoted model is valid JSON (jq)"
  else
    fail "ledger line is not valid JSON: $LINE"
  fi
else
  case "$LINE" in
    *'"model":"a\"b"'*) pass "ledger line escapes the embedded quote (jq unavailable, string check)" ;;
    *) fail "ledger line does not escape embedded quote: $LINE" ;;
  esac
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
