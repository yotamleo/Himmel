#!/usr/bin/env bash
# Hermetic tests for dispatch-codex-exec.sh (HIMMEL-781).
# No real codex install: CODEX_BIN + CODEX_ACL_NORMALIZE inject stubs that
# record their argv/cwd/order. Asserts the lane invariants: ACL preflight
# before codex + fail-closed, gpt-5.5 pin (unless caller-named), the
# --background refusal, and the workspace-redirect/sandbox-widening deny-list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch-codex-exec.sh"

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

# codex stub: records invocation order, argv, and cwd; exits 0.
CODEX_STUB="$TMP/codex-stub"
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
pwd > "$TMP/codex.cwd"
exit 0
EOF
chmod +x "$CODEX_STUB"

# preflight stub: records invocation order + its worktree arg; exit code via file.
NORM_STUB="$TMP/norm-stub.sh"
cat > "$NORM_STUB" <<EOF
#!/usr/bin/env bash
echo "normalize" >> "$LOG"
printf '%s\n' "\$1" > "$TMP/norm.arg"
exit \$(cat "$TMP/norm.rc")
EOF
chmod +x "$NORM_STUB"
echo 0 > "$TMP/norm.rc"

run_dispatch() {  # run_dispatch <args...> ; sets $RC and $OUT
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
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

# --- 2.5: directory OUTSIDE .claude/worktrees refused (codex-adv r5) ----------
OUTSIDE="$TMP/not-a-worktree"
mkdir -p "$OUTSIDE"
run_dispatch --worktree "$OUTSIDE" do-it
assert_rc 2 "non-worktree directory refused" "outside rc=$RC out=$OUT"
case "$OUT" in *"outside .claude/worktrees"*) pass "outside refusal names the containment rule";; *) fail "outside out: $OUT";; esac

# --- 2.6: resume / review subcommands refused, ANY position (codex-adv r5/r6) -
for subargs in "resume --all" "review x" "--json resume --all" "--sandbox workspace-write review"; do
  : > "$LOG"
  # shellcheck disable=SC2086  # word-splitting the fixture is the point
  run_dispatch --worktree "$WT" $subargs
  assert_rc 2 "subcommand refused: $subargs" "sub [$subargs] rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite: $subargs"; else pass "codex not invoked on: $subargs"; fi
done

# --- 2.7: --json passes the allow-list; symlinked worktree refused (final rd) -
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --json do-it
assert_rc 0 "--json allowed through the allow-list" "json rc=$RC out=$OUT"
LINKED="$TMP/.claude/worktrees/linked-wt"
if ln -s "$TMP/not-a-worktree" "$LINKED" 2>/dev/null && [ -L "$LINKED" ]; then
  run_dispatch --worktree "$LINKED" do-it
  assert_rc 2 "symlinked worktree (physical target outside) refused" "symlink rc=$RC out=$OUT"
  rm -f "$LINKED"
else
  rm -rf "$LINKED"
  pass "symlink escape case skipped (no real symlinks on this platform)"
fi

# --- 3: --background refused (exit 2), codex never invoked -------------------
: > "$LOG"
run_dispatch --worktree "$WT" some-prompt --background
assert_rc 2 "--background refused with exit 2" "background rc=$RC out=$OUT"
case "$OUT" in *"--background refused"*) pass "--background refusal names the rule";; *) fail "background out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite --background"; else pass "codex not invoked on --background"; fi

# --- 4: default dispatch pins gpt-5.5 and runs preflight first ----------------
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" do-the-task
assert_rc 0 "default dispatch exits 0" "default rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model gpt-5.5 --sandbox workspace-write do-the-task") pass "gpt-5.5 pin + sandbox pin injected" ;;
  *) fail "codex args: $(cat "$TMP/codex.args")" ;;
esac
case "$(tr '\n' ' ' < "$LOG")" in
  "normalize codex "*) pass "preflight runs before codex" ;;
  *) fail "call order: $(tr '\n' ' ' < "$LOG")" ;;
esac
case "$(cat "$TMP/norm.arg")" in
  "$WT") pass "preflight got the worktree path" ;;
  *) fail "norm arg: $(cat "$TMP/norm.arg")" ;;
esac

# --- 5: codex runs with cwd = the worktree -----------------------------------
# (compare basenames: mktemp paths differ across /tmp vs C:/... spellings on MSYS)
case "$(basename "$(cat "$TMP/codex.cwd")")" in
  "$(basename "$WT")") pass "codex cwd is the worktree" ;;
  *) fail "codex cwd: $(cat "$TMP/codex.cwd")" ;;
esac

# --- 6: caller-named --model overrides the pin (with WARN) --------------------
: > "$LOG"
run_dispatch --worktree "$WT" --model qwen-plus do-it
assert_rc 0 "caller model dispatch exits 0" "caller-model rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write --model qwen-plus do-it") pass "caller model preserved, sandbox still pinned" ;;
  *) fail "caller-model codex args: $(cat "$TMP/codex.args")" ;;
esac
case "$OUT" in *"WARN caller-named model"*) pass "caller model warns";; *) fail "caller-model out: $OUT";; esac

# --- 6.5: workspace-redirect + sandbox-widening flags refused (codex-adv r2) --
for bad in "-C" "--cd" "--cd=/tmp/elsewhere" "--add-dir" "--add-dir=/tmp/x" \
           "--dangerously-bypass-approvals-and-sandbox" "--yolo" \
           "--sandbox=danger-full-access" "-s=danger-full-access" \
           "-c" "--config" "-c=sandbox_permissions=full" "--config=x=y" \
           "-p" "--profile" "--profile=wide" "-o" "--output-last-message" "--output-last-message=/tmp/x" \
           "--dangerously-bypass-hook-trust" "--ignore-rules" \
           "-C/tmp/outside" "-csandbox_permissions=x" "-pwide" "-o/tmp/out" "-sdanger-full-access" \
           "--disable" "--disable=hooks" "--enable" "--enable=x" "--full-auto" "--no-such-flag"; do
  : > "$LOG"
  run_dispatch --worktree "$WT" "$bad" /tmp/elsewhere do-it
  assert_rc 2 "refused: $bad" "flag $bad rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite $bad"; else pass "codex not invoked on $bad"; fi
done
# two-arg forms: --sandbox danger-full-access and -s danger-full-access
for sflag in "--sandbox" "-s"; do
  : > "$LOG"
  run_dispatch --worktree "$WT" "$sflag" danger-full-access do-it
  assert_rc 2 "refused: $sflag danger-full-access (two-arg)" "sandbox-pair $sflag rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite $sflag pair"; else pass "codex not invoked on $sflag pair"; fi
done
# non-widening sandbox value passes through
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --sandbox workspace-write do-it
assert_rc 0 "--sandbox workspace-write allowed" "sandbox-ok rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model gpt-5.5 --sandbox workspace-write do-it") pass "workspace-write passed through with pin" ;;
  *) fail "sandbox-ok codex args: $(cat "$TMP/codex.args")" ;;
esac
# attached short forms of the ALLOWED values still register (no double pin)
: > "$LOG"
run_dispatch --worktree "$WT" -sworkspace-write do-it
assert_rc 0 "-sworkspace-write (attached) allowed" "s-attach rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model gpt-5.5 -sworkspace-write do-it") pass "-s attached registers have_sandbox (no injected --sandbox)" ;;
  *) fail "s-attach codex args: $(cat "$TMP/codex.args")" ;;
esac
: > "$LOG"
run_dispatch --worktree "$WT" -mqwen-plus do-it
assert_rc 0 "-mqwen-plus (attached) allowed" "m-attach rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write -mqwen-plus do-it") pass "-m attached registers have_model (no injected pin)" ;;
  *) fail "m-attach codex args: $(cat "$TMP/codex.args")" ;;
esac

# --- 7: preflight failure aborts the dispatch (fail-closed, exit 1) ----------
: > "$LOG"; echo 1 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" do-the-task
assert_rc 1 "preflight failure exits 1" "preflight-fail rc=$RC out=$OUT"
case "$OUT" in *"ACL preflight failed"*) pass "preflight failure is named";; *) fail "preflight-fail out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite preflight failure"; else pass "codex not invoked on preflight failure"; fi

# --- 8: --model=<value> equals form and -m short form detected --------------
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --model=qwen-plus do-it
assert_rc 0 "--model= equals form exits 0" "model-eq rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write --model=qwen-plus do-it") pass "--model= form preserved, sandbox still pinned" ;;
  *) fail "model-eq codex args: $(cat "$TMP/codex.args")" ;;
esac
: > "$LOG"
run_dispatch --worktree "$WT" -m qwen-plus do-it
assert_rc 0 "-m short form exits 0" "m-short rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write -m qwen-plus do-it") pass "-m form preserved, sandbox still pinned" ;;
  *) fail "m-short codex args: $(cat "$TMP/codex.args")" ;;
esac

# --- 9: --background=value form refused ---------------------------------------
: > "$LOG"
run_dispatch --worktree "$WT" --background=true do-it
assert_rc 2 "--background= equals form refused" "background-eq rc=$RC out=$OUT"

# --- 10: --worktree present but not first -> usage (exit 2) -------------------
run_dispatch do-the-task --worktree "$WT"
assert_rc 2 "--worktree not-first exits 2 (positional contract)" "positional rc=$RC out=$OUT"

# --- 11: codex exit code propagates through the exec tail --------------------
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exit 3
EOF
run_dispatch --worktree "$WT" do-it
assert_rc 3 "codex nonzero exit propagates (rc=3)" "propagate rc=$RC out=$OUT"
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
pwd > "$TMP/codex.cwd"
exit 0
EOF

# --- 12: codex CLI missing -> exit 127 with the CODEX_BIN hint ----------------
set +e
OUT="$(CODEX_BIN="$TMP/definitely-not-a-binary" CODEX_ACL_NORMALIZE="$NORM_STUB" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 127 "missing codex CLI exits 127" "no-codex rc=$RC out=$OUT"
case "$OUT" in *"set CODEX_BIN"*) pass "missing-codex message names CODEX_BIN";; *) fail "no-codex out: $OUT";; esac

# --- 13: worktree vanishing after the preflight is named distinctly ----------
VANISH_WT="$TMP/.claude/worktrees/vanish-wt"
mkdir -p "$VANISH_WT"
VANISH_NORM="$TMP/vanish-norm.sh"
cat > "$VANISH_NORM" <<EOF
#!/usr/bin/env bash
rmdir "\$1"
exit 0
EOF
chmod +x "$VANISH_NORM"
set +e
OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$VANISH_NORM" \
    bash "$DISPATCH" --worktree "$VANISH_WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 1 "vanished worktree exits 1" "vanish rc=$RC out=$OUT"
case "$OUT" in *"worktree vanished before dispatch"*) pass "vanish failure is named";; *) fail "vanish out: $OUT";; esac

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
