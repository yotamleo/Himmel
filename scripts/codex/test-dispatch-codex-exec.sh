#!/usr/bin/env bash
# Hermetic tests for dispatch-codex-exec.sh (HIMMEL-781).
# No real codex install: CODEX_BIN + CODEX_ACL_NORMALIZE inject stubs that
# record their argv/cwd/order. Asserts the lane invariants: ACL preflight
# before codex + fail-closed, gpt-5.5 pin (unless caller-named), the
# --background refusal, the workspace-redirect/sandbox-widening deny-list,
# and the --reasoning-effort passthrough (HIMMEL-905).
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
JOBS_DIR="$TMP/jobs-dir"
mkdir -p "$JOBS_DIR"

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

# reap-mcp-fleet stub (HIMMEL-840): records invocation + argv, exits 0 - no
# real process table or pwsh is touched. Injected into every run_dispatch
# call below so a codex stub that actually runs (rc-0 or nonzero-rc paths)
# never shells out to the real reap-mcp-fleet.sh/.ps1.
REAP_STUB="$TMP/reap-stub.sh"
cat > "$REAP_STUB" <<EOF
#!/usr/bin/env bash
echo "reap" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/reap.args"
exit 0
EOF
chmod +x "$REAP_STUB"

# HIMMEL-2023: every dispatch now writes flow-run-ledger rows. Point the lib
# at a temp ledger so the suite never appends to the operator's real
# ~/.himmel/flow-runs.jsonl.
LEDGER="$TMP/flow-runs.jsonl"

run_dispatch() {  # run_dispatch <args...> ; sets $RC and $OUT
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
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

# --- 15: job registry (HIMMEL-840) - created during the run, removed after; --
# the composed EXIT trap invokes the reap primitive with the codex CHILD's
# own pid (never the dispatcher's own $$); rc propagation unchanged with the
# new always-a-child flow. A dedicated slow stub records its own pid and
# snapshots $CODEX_JOBS_DIR mid-run (the parent's registry write is racing
# the child's start, so the child sleeps briefly first).
: > "$LOG"; echo 0 > "$TMP/norm.rc"
rm -f "$TMP/jobs-during.txt" "$TMP/codex.pid" "$TMP/reap.args"
SLOW_CODEX_STUB="$TMP/codex-slow-stub"
cat > "$SLOW_CODEX_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
echo \$\$ > "$TMP/codex.pid"
sleep 0.3
ls "\$CODEX_JOBS_DIR" 2>/dev/null > "$TMP/jobs-during.txt"
exit 0
EOF
chmod +x "$SLOW_CODEX_STUB"
set +e
OUT="$(CODEX_BIN="$SLOW_CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 0 "registry-test dispatch exits 0" "registry rc=$RC out=$OUT"
# Line-wise, not a whole-string glob: HIMMEL-2023 adds a sibling failed/ dir
# that earlier nonzero-exit cases leave behind, and `ls` sorts it AFTER the
# digit-prefixed job file.
if grep -q '\.json$' "$TMP/jobs-during.txt" 2>/dev/null; then
  pass "job registry file present during the run"
else
  fail "job registry file missing during run: $(cat "$TMP/jobs-during.txt" 2>/dev/null)"
fi
# The SUCCESS path still removes its own entry; only failed/ survives, and it
# holds no live-job *.json (HIMMEL-2023 keeps evidence out of the live glob).
if [ -z "$(ls "$JOBS_DIR"/*.json 2>/dev/null)" ]; then
  pass "job registry file removed after the run (EXIT trap cleanup)"
else
  fail "job registry file(s) left behind: $(ls "$JOBS_DIR")"
fi
CODEX_CHILD_PID_SEEN="$(cat "$TMP/codex.pid" 2>/dev/null)"
case "$(cat "$TMP/reap.args" 2>/dev/null)" in
  "--root-pid $CODEX_CHILD_PID_SEEN --started-at "*" --kill")
    pass "reap primitive invoked with the codex child's own pid" ;;
  *)
    fail "reap.args: $(cat "$TMP/reap.args" 2>/dev/null) (expected root-pid=$CODEX_CHILD_PID_SEEN)" ;;
esac

# --- 16: --reasoning-effort passthrough (HIMMEL-905) --------------------------
# 16a: two-word form, valid value -> translated to -c model_reasoning_effort="<v>"
#      and stripped from the codex passthrough.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --reasoning-effort high do-it
assert_rc 0 "--reasoning-effort two-word form exits 0" "reff-two rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model gpt-5.5 --sandbox workspace-write -c model_reasoning_effort="high" do-it') pass "--reasoning-effort translated to -c override, stripped from passthrough" ;;
  *) fail "reff-two codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16b: --reasoning-effort=<value> equals form, valid value.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort=xhigh do-it
assert_rc 0 "--reasoning-effort= equals form exits 0" "reff-eq rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model gpt-5.5 --sandbox workspace-write -c model_reasoning_effort="xhigh" do-it') pass "--reasoning-effort= translated to -c override" ;;
  *) fail "reff-eq codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16c: every valid enum value accepted (none/low/medium/high/xhigh/max).
for v in none low medium high xhigh max; do
  : > "$LOG"
  run_dispatch --worktree "$WT" --reasoning-effort "$v" do-it
  assert_rc 0 "--reasoning-effort $v accepted" "reff-enum $v rc=$RC out=$OUT"
done

# 16d: invalid value refused (exit 2), codex never invoked.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort bogus do-it
assert_rc 2 "--reasoning-effort invalid value refused" "reff-bad rc=$RC out=$OUT"
case "$OUT" in *"not in none|low|medium|high|xhigh|max"*) pass "invalid --reasoning-effort names the allowed enum";; *) fail "reff-bad out: $OUT";; esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite invalid --reasoning-effort"; else pass "codex not invoked on invalid --reasoning-effort"; fi

# 16e: invalid value via equals form also refused.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort=bogus do-it
assert_rc 2 "--reasoning-effort=bogus refused" "reff-eq-bad rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite --reasoning-effort=bogus"; else pass "codex not invoked on --reasoning-effort=bogus"; fi

# 16f: no --reasoning-effort passed -> no -c override injected (default unchanged).
: > "$LOG"
run_dispatch --worktree "$WT" do-it
case "$(cat "$TMP/codex.args")" in
  "exec --model gpt-5.5 --sandbox workspace-write do-it") pass "no --reasoning-effort -> no -c override injected" ;;
  *) fail "no-reff codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16g: raw -c/--config still refused for callers even alongside a valid
# --reasoning-effort (the wrapper's own -c injection is internal, not a
# caller-facing allow).
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort high -c foo=bar do-it
assert_rc 2 "raw -c still refused even alongside --reasoning-effort" "reff-plus-c rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite raw -c alongside --reasoning-effort"; else pass "codex not invoked on raw -c alongside --reasoning-effort"; fi

# 16h: --reasoning-effort as the ONLY arg (no prompt word) - exercises the
# zero-element NEW_ARGS guard (set -u safe empty-array rebuild on pre-4.4 bash).
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" --reasoning-effort medium
assert_rc 0 "--reasoning-effort as sole arg exits 0 (empty positional rebuild)" "reff-only rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model gpt-5.5 --sandbox workspace-write -c model_reasoning_effort="medium"') pass "empty-args rebuild after stripping the only two tokens" ;;
  *) fail "reff-only codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16i: --reasoning-effort as the very LAST token with NO value - must be
# refused (rc=2), not silently stripped into a default-effort run (the
# value-validation branch only fires on the NEXT loop iteration, which never
# comes for a trailing flag - post-loop guard covers it).
: > "$LOG"
run_dispatch --worktree "$WT" do-it --reasoning-effort
assert_rc 2 "trailing --reasoning-effort with no value refused" "trailing-reff rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite trailing bare --reasoning-effort"; else pass "codex not invoked on trailing bare --reasoning-effort"; fi

# --- 17: watchdog + ledger + evidence (HIMMEL-2023 / HIMMEL-1788 inst. 5) ----
# 17a: the default budget must equal the codex-exec lane's own timeoutSeconds.
# The dispatcher keeps the number as a literal (no JSON reader on its hot
# path), so THIS assertion is what stops the two drifting apart.
LANE_TIMEOUT="$(node -e '
const l = require(process.argv[1]).lanes.find(x => x.id === "codex-exec");
process.stdout.write(String(l.dispatch.timeoutSeconds));
' "$SCRIPT_DIR/../lanes/lanes.json" 2>/dev/null)"
# shellcheck disable=SC2016 # the sed script is a literal match against the dispatcher's source text, not an expansion
SCRIPT_DEFAULT="$(sed -n 's/^EXEC_TIMEOUT="${CODEX_EXEC_TIMEOUT:-\([0-9]*\)}"$/\1/p' "$DISPATCH")"
if [ -n "$LANE_TIMEOUT" ] && [ "$LANE_TIMEOUT" = "$SCRIPT_DEFAULT" ]; then
  pass "default watchdog budget matches the codex-exec lane timeoutSeconds ($LANE_TIMEOUT)"
else
  fail "watchdog budget drift: lanes.json=$LANE_TIMEOUT dispatcher=$SCRIPT_DEFAULT"
fi

# 17b: a malformed budget REFUSES rather than degrading to an unbounded wait.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
set +e
OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=nope \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 2 "non-numeric CODEX_EXEC_TIMEOUT refused" "bad-timeout rc=$RC out=$OUT"
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite a malformed budget"; else pass "codex not invoked on a malformed budget"; fi

# 17b1: an OVER-CEILING budget is refused too. A digit string `sleep` cannot
# parse exits immediately, which the watchdog would read as its budget having
# elapsed and kill a run that had just started (panel r3, dropped citation).
# The 20-digit case also pins the length guard: bash's own `[ -gt ]` errors on
# it, and reading that error as "not too large" would let it straight through.
for bad_to in 86401 99999999999999999999; do
  : > "$LOG"
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT="$bad_to" \
      bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
  RC=$?
  set -e
  assert_rc 2 "over-ceiling CODEX_EXEC_TIMEOUT=$bad_to refused" "big-timeout $bad_to rc=$RC out=$OUT"
  if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite CODEX_EXEC_TIMEOUT=$bad_to"; else pass "codex not invoked on CODEX_EXEC_TIMEOUT=$bad_to"; fi
done
# ...and the ceiling itself is still accepted.
: > "$LOG"
run_dispatch_to() {
  set +e
  OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT="$1" \
      bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
  RC=$?
  set -e
}
run_dispatch_to 86400
assert_rc 0 "CODEX_EXEC_TIMEOUT at the 86400 ceiling accepted" "ceiling rc=$RC out=$OUT"

# 17b2: an unusable watchdog REFUSES before codex starts (panel r2 codex-1).
# Without its flag file the watchdog would still kill the tree but this shell
# could not tell that it had — the run would report the child's bare 143, keep
# no evidence, and cancel the watchdog mid-escalation. TMPDIR pointed at a
# non-directory makes mktemp fail without touching the real temp root.
: > "$LOG"; echo 0 > "$TMP/norm.rc"
printf 'not-a-dir\n' > "$TMP/notdir"
set +e
OUT="$(CODEX_BIN="$CODEX_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" TMPDIR="$TMP/notdir" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 2 "unusable watchdog flag file refuses the dispatch" "no-flagfile rc=$RC out=$OUT"
case "$OUT" in
  *"refusing to run codex with an unreadable watchdog verdict"*) pass "watchdog-flag refusal names the cause" ;;
  *) fail "no-flagfile message missing: $OUT" ;;
esac
if grep -q codex "$LOG" 2>/dev/null; then fail "codex invoked despite an unusable watchdog flag file"; else pass "codex not invoked when the watchdog cannot report"; fi

# 17c: a wedged run is TIMEBOXED, killed as a TREE, reported 124 + loudly, and
# leaves evidence. The stub backgrounds a grandchild the way the real codex
# CLI leaks its MCP fleet: signalling the child alone would leave it alive.
: > "$LOG"; : > "$LEDGER"; rm -f "$TMP/grandchild.pid"
HANG_STUB="$TMP/codex-hang-stub"
cat > "$HANG_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
sleep 120 &
echo \$! > "$TMP/grandchild.pid"
sleep 120
EOF
chmod +x "$HANG_STUB"
set +e
OUT="$(CODEX_BIN="$HANG_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=2 \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 124 "watchdog timeout exits 124" "timeout rc=$RC out=$OUT"
case "$OUT" in
  *"codex-exec: TIMEOUT after 2s - killed tree"*) pass "timeout is reported LOUDLY on stderr" ;;
  *) fail "timeout message missing: $OUT" ;;
esac
GCHILD="$(cat "$TMP/grandchild.pid" 2>/dev/null)"
if [ -z "$GCHILD" ]; then
  fail "hang stub never recorded a grandchild pid"
elif kill -0 "$GCHILD" 2>/dev/null; then
  fail "grandchild $GCHILD survived the timeout kill (tree not killed)"
  kill -9 "$GCHILD" 2>/dev/null
else
  pass "grandchild reaped by the timeout tree kill"
fi
if grep -q '"ev":"start".*"flow":"codex-exec"' "$LEDGER" 2>/dev/null \
   || grep -q '"flow":"codex-exec".*"ev":"start"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger carries a codex-exec start row"
else
  fail "no codex-exec start row in the ledger: $(cat "$LEDGER" 2>/dev/null)"
fi
if grep -q '"outcome":"timeout"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger end row carries outcome=timeout"
else
  fail "no outcome=timeout end row: $(cat "$LEDGER" 2>/dev/null)"
fi
if [ -n "$(ls "$JOBS_DIR"/failed/*.json 2>/dev/null)" ]; then
  pass "job registry entry preserved under failed/ on timeout"
else
  fail "timeout deleted the job registry evidence: $(ls -R "$JOBS_DIR" 2>/dev/null)"
fi

# 17d: a clean run writes outcome=complete and removes its own entry.
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"; : > "$LEDGER"
run_dispatch --worktree "$WT" do-it
assert_rc 0 "clean run after the timeout case exits 0" "post-timeout rc=$RC out=$OUT"
if grep -q '"outcome":"complete"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger end row carries outcome=complete on success"
else
  fail "no outcome=complete end row: $(cat "$LEDGER" 2>/dev/null)"
fi
if [ -z "$(ls -A "$JOBS_DIR" 2>/dev/null)" ]; then
  pass "clean run leaves no registry evidence behind"
else
  fail "clean run left registry entries: $(ls -R "$JOBS_DIR")"
fi

# 17e: a nonzero codex exit is outcome=error and ALSO preserves the evidence.
: > "$LEDGER"
cat > "$TMP/codex-fail-stub" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
exit 9
EOF
chmod +x "$TMP/codex-fail-stub"
set +e
OUT="$(CODEX_BIN="$TMP/codex-fail-stub" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" \
    bash "$DISPATCH" --worktree "$WT" do-it 2>&1)"
RC=$?
set -e
assert_rc 9 "codex nonzero exit still propagates verbatim" "fail-stub rc=$RC out=$OUT"
if grep -q '"outcome":"error"' "$LEDGER" 2>/dev/null; then
  pass "flow-run-ledger end row carries outcome=error"
else
  fail "no outcome=error end row: $(cat "$LEDGER" 2>/dev/null)"
fi
if [ -n "$(ls "$JOBS_DIR"/failed/*.json 2>/dev/null)" ]; then
  pass "job registry entry preserved under failed/ on a nonzero exit"
else
  fail "nonzero exit deleted the job registry evidence"
fi

# --- 18: stdin (HIMMEL-2023 B) ------------------------------------------------
# `codex exec` reads stdin to EOF even with an argv prompt, so a never-closing
# stdin is a hang before a token is spent. Two arms:
#   18a a genuinely PIPED brief must still reach codex (the <&0 contract the
#       lane's briefDelivery:"stdin" depends on - a blanket </dev/null here
#       would silently no-op every brief);
#   18b closed/empty stdin must read EOF and finish, never block.
# The `[ -t 0 ] -> </dev/null` arm cannot be exercised hermetically (this
# suite has no pty; Git Bash ships no `script`), and by construction it puts
# the child in exactly the state 18b pins.
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
STDIN_STUB="$TMP/codex-stdin-stub"
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
cat > "$TMP/codex.stdin"
exit 0
EOF
chmod +x "$STDIN_STUB"
run_stdin_dispatch() {  # run_stdin_dispatch <redirect-source>
  set +e
  OUT="$(CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=20 \
      bash "$DISPATCH" --worktree "$WT" do-it < "$1" 2>&1)"
  RC=$?
  set -e
}
printf 'the brief\n' > "$TMP/brief.txt"
: > "$TMP/codex.stdin"
run_stdin_dispatch "$TMP/brief.txt"
assert_rc 0 "piped-brief dispatch exits 0" "stdin-brief rc=$RC out=$OUT"
if [ "$(cat "$TMP/codex.stdin" 2>/dev/null)" = "the brief" ]; then
  pass "a piped brief still crosses to codex on stdin"
else
  fail "piped brief lost: '$(cat "$TMP/codex.stdin" 2>/dev/null)'"
fi
: > "$TMP/codex.stdin"
run_stdin_dispatch /dev/null
assert_rc 0 "closed-stdin dispatch exits 0 without blocking" "stdin-null rc=$RC out=$OUT"
if [ ! -s "$TMP/codex.stdin" ]; then
  pass "closed stdin reaches codex as immediate EOF"
else
  fail "closed stdin delivered content: '$(cat "$TMP/codex.stdin")'"
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
