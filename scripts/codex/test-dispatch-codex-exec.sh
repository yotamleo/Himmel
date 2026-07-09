#!/usr/bin/env bash
# Hermetic tests for dispatch-codex-exec.sh (HIMMEL-781).
# No real codex install: CODEX_BIN + CODEX_ACL_NORMALIZE inject stubs that
# record their argv/cwd/order. Asserts the lane invariants: ACL preflight
# before codex + fail-closed, gpt-5.5 pin (unless caller-named), the
# --background refusal, and the workspace-redirect/sandbox-widening deny-list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch-codex-exec.sh"
LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"

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
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
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

# --- 14: --shared-branch mode (HIMMEL-800) ------------------------------------
# Real git repo + real worktree under .claude/worktrees (so the containment
# check passes) and the REAL shared-branch-lock.sh (not a stub) - this
# section tests the integration between dispatch-codex-exec.sh and the
# frozen lock primitive, not the primitive's own internals (that is
# scripts/lib/test-shared-branch-lock.sh's job).
SB_REPO="$TMP/sb-repo"
mkdir -p "$SB_REPO"
git -C "$SB_REPO" init -q
git -C "$SB_REPO" config user.email "test@example.com"
git -C "$SB_REPO" config user.name "Test User"
: > "$SB_REPO/README.md"
git -C "$SB_REPO" add README.md
git -C "$SB_REPO" commit -q -m init
SB_WT="$TMP/.claude/worktrees/sb-wt"
git -C "$SB_REPO" worktree add -q "$SB_WT" -b "feat/shared" >/dev/null 2>&1

# 14a: happy path - matching branch, clean tree -> codex runs, lock released after.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 0 "shared-branch happy path exits 0" "sb-happy rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then pass "codex invoked in shared-branch happy path"; else fail "codex not invoked in shared-branch happy path: $OUT"; fi
sb_status="$(bash "$LOCK_LIB" status "$SB_WT" "feat/shared" 2>&1)" || true
case "$sb_status" in
  free) pass "shared-branch lock released after happy path" ;;
  *) fail "shared-branch lock not released after happy path: $sb_status" ;;
esac

# 14b: branch mismatch -> exit 2, codex not invoked.
: > "$LOG"
run_dispatch --worktree "$SB_WT" --shared-branch "feat/other" do-it
assert_rc 2 "shared-branch mismatch refused" "sb-mismatch rc=$RC out=$OUT"
case "$OUT" in *"does not match"*) pass "mismatch refusal names both branches";; *) fail "sb-mismatch out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite branch mismatch"; else pass "codex not invoked on branch mismatch"; fi

# 14c: main refused -> exit 2, codex not invoked (checked before branch match).
: > "$LOG"
run_dispatch --worktree "$SB_WT" --shared-branch main do-it
assert_rc 2 "shared-branch main refused" "sb-main rc=$RC out=$OUT"
case "$OUT" in *"refuses trunk branch"*) pass "main refusal names the trunk rule";; *) fail "sb-main out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite main refusal"; else pass "codex not invoked on main refusal"; fi

# 14d: dirty tree -> exit 2, codex not invoked.
: > "$LOG"
echo "dirty" > "$SB_WT/dirty-file.txt"
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 2 "shared-branch dirty tree refused" "sb-dirty rc=$RC out=$OUT"
case "$OUT" in *"uncommitted changes"*) pass "dirty-tree refusal names the rule";; *) fail "sb-dirty out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite dirty tree"; else pass "codex not invoked on dirty tree"; fi
rm -f "$SB_WT/dirty-file.txt"

# 14e: lock already held -> exit 4, codex not invoked, pre-existing lock intact.
: > "$LOG"
bash "$LOCK_LIB" acquire "$SB_WT" "feat/shared" "external-holder" >/dev/null 2>&1
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 4 "shared-branch lock-held refused with exit 4" "sb-lock-held rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite lock held"; else pass "codex not invoked when lock held"; fi
sb_status="$(bash "$LOCK_LIB" status "$SB_WT" "feat/shared" 2>&1)" || true
case "$sb_status" in
  *"external-holder"*) pass "pre-existing lock not clobbered by dispatch's own trap" ;;
  *) fail "pre-existing lock was clobbered: $sb_status" ;;
esac
bash "$LOCK_LIB" release "$SB_WT" "feat/shared" >/dev/null 2>&1

# 14f: codex nonzero exit propagates AND the lock is released (trap fires).
: > "$LOG"
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exit 7
EOF
run_dispatch --worktree "$SB_WT" --shared-branch "feat/shared" do-it
assert_rc 7 "shared-branch codex nonzero exit propagates" "sb-codex-rc7 rc=$RC out=$OUT"
sb_status="$(bash "$LOCK_LIB" status "$SB_WT" "feat/shared" 2>&1)" || true
case "$sb_status" in
  free) pass "shared-branch lock released after codex nonzero exit" ;;
  *) fail "shared-branch lock not released after nonzero exit: $sb_status" ;;
esac
cat > "$CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
pwd > "$TMP/codex.cwd"
exit 0
EOF

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
