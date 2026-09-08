#!/usr/bin/env bash
# Hermetic tests for dispatch-codex-exec.sh (HIMMEL-781).
# No real codex install: CODEX_BIN + CODEX_ACL_NORMALIZE inject stubs that
# record their argv/cwd/order. Asserts the lane invariants: ACL preflight
# before codex + fail-closed, critic-model default (unless caller-named), the
# --background refusal, the workspace-redirect/sandbox-widening deny-list,
# and the --reasoning-effort passthrough (HIMMEL-905).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/dispatch-codex-exec.sh"
LOCK_LIB="$SCRIPT_DIR/../lib/shared-branch-lock.sh"
CRITIC_MODEL="$(node -e 'process.stdout.write(require(process.argv[1]).panel.find(x => x.slug === "codex").model)' "$SCRIPT_DIR/../cr/critics.json")"
unset CODEX_CRITICS_FILE

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

# --- 4: default dispatch follows the critic and runs preflight first ---------
: > "$LOG"; echo 0 > "$TMP/norm.rc"
run_dispatch --worktree "$WT" do-the-task
assert_rc 0 "default dispatch exits 0" "default rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write do-the-task") pass "$CRITIC_MODEL pin + sandbox pin injected" ;;
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

# --- 6: caller-named --model overrides without a warning for plain IDs -------
: > "$LOG"
run_dispatch --worktree "$WT" --model qwen-plus do-it
assert_rc 0 "caller model dispatch exits 0" "caller-model rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --sandbox workspace-write --model qwen-plus do-it") pass "caller model preserved, sandbox still pinned" ;;
  *) fail "caller-model codex args: $(cat "$TMP/codex.args")" ;;
esac
case "$OUT" in *WARN*) fail "plain caller model unexpectedly warns: $OUT";; *) pass "plain caller model does not warn";; esac

# Each model flag spelling preserves the override and warns only on variants.
for model_args in '--model fixture-codex' '--model=fixture-codex' '-m fixture-codex' '-mfixture-codex'; do
  # shellcheck disable=SC2086 # deliberately exercise both one- and two-token forms
  run_dispatch --worktree "$WT" $model_args do-it
  assert_rc 0 "variant override accepted: $model_args" "variant rc=$RC out=$OUT"
  case "$OUT" in *"WARN"*"codex-variant"*) pass "variant warning: $model_args";; *) fail "missing variant warning: $OUT";; esac
done
run_dispatch --worktree "$WT" --model gpt-6-astra do-it
case "$OUT" in *WARN*) fail "explicit plain model warned: $OUT";; *) pass "explicit gpt-6-astra remains warning-free";; esac

# A different registry model must actually change the rendered codex argv.
printf '%s\n' '{"panel":[{"slug":"codex","model":"fixture-next","provider":"openai-codex","route_provider":"openai-codex","tier":"paid"}]}' > "$TMP/critics.json"
export CODEX_CRITICS_FILE="$TMP/critics.json"
run_dispatch --worktree "$WT" do-it
assert_rc 0 "alternate critic registry accepted" "critic drift rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model fixture-next --sandbox workspace-write do-it') pass "dispatch default follows changed critic model" ;;
  *) fail "critic drift argv: $(cat "$TMP/codex.args")" ;;
esac
run_dispatch --worktree "$WT" --model explicit-model do-it
case "$(cat "$TMP/codex.args")" in
  'exec --sandbox workspace-write --model explicit-model do-it') pass "explicit model wins over critic registry" ;;
  *) fail "override argv: $(cat "$TMP/codex.args")" ;;
esac
for invalid_registry in 'not json' '{"panel":[]}' '{"panel":[{"slug":"codex","model":""}]}' \
    '{"panel":[{"slug":"codex","model":"fixture --sandbox danger-full-access"}]}' \
    '{"panel":[{"slug":"codex","model":"*"}]}'; do
  printf '%s\n' "$invalid_registry" > "$TMP/critics.json"
  : > "$LOG"
  run_dispatch --worktree "$WT" do-it
  assert_rc 2 "invalid registry refuses rather than silently drifting" "invalid registry=$invalid_registry rc=$RC out=$OUT"
  if grep -q codex "$LOG"; then fail "codex invoked despite invalid model registry"; else pass "invalid registry never reaches codex"; fi
done
run_dispatch --worktree "$WT" --model explicit-model do-it
assert_rc 0 "explicit override does not depend on registry parsing" "override with malformed registry rc=$RC out=$OUT"
export CODEX_CRITICS_FILE="$TMP/missing-critics.json"
run_dispatch --worktree "$WT" do-it
assert_rc 0 "unreadable registry uses fallback" "missing registry rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  'exec --model gpt-6-astra --sandbox workspace-write do-it') pass "unreadable registry uses named fallback model" ;;
  *) fail "fallback argv: $(cat "$TMP/codex.args")" ;;
esac
unset CODEX_CRITICS_FILE

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
  "exec --model $CRITIC_MODEL --sandbox workspace-write do-it") pass "workspace-write passed through with pin" ;;
  *) fail "sandbox-ok codex args: $(cat "$TMP/codex.args")" ;;
esac
# attached short forms of the ALLOWED values still register (no double pin)
: > "$LOG"
run_dispatch --worktree "$WT" -sworkspace-write do-it
assert_rc 0 "-sworkspace-write (attached) allowed" "s-attach rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL -sworkspace-write do-it") pass "-s attached registers have_sandbox (no injected --sandbox)" ;;
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
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_reasoning_effort=\"high\" do-it") pass "--reasoning-effort translated to -c override, stripped from passthrough" ;;
  *) fail "reff-two codex args: $(cat "$TMP/codex.args")" ;;
esac

# 16b: --reasoning-effort=<value> equals form, valid value.
: > "$LOG"
run_dispatch --worktree "$WT" --reasoning-effort=xhigh do-it
assert_rc 0 "--reasoning-effort= equals form exits 0" "reff-eq rc=$RC out=$OUT"
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_reasoning_effort=\"xhigh\" do-it") pass "--reasoning-effort= translated to -c override" ;;
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
  "exec --model $CRITIC_MODEL --sandbox workspace-write do-it") pass "no --reasoning-effort -> no -c override injected" ;;
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
  "exec --model $CRITIC_MODEL --sandbox workspace-write -c model_reasoning_effort=\"medium\"") pass "empty-args rebuild after stripping the only two tokens" ;;
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

# --- 18: explicit stdin + timeout diagnosis (HIMMEL-2786) ---------------------
# A stub that reads to EOF catches the non-tty empty-pipe hang. Keep a FIFO
# open for reading AND writing: no data and no EOF until the fixture closes
# fd 9. The dispatch's short watchdog bounds the regression, not the producer.
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
STDIN_STUB="$TMP/codex-stdin-stub"
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
echo "codex" >> "$LOG"
printf '%s\n' "\$*" > "$TMP/codex.args"
cat > "$TMP/codex.stdin"
exit 0
EOF
chmod +x "$STDIN_STUB"
run_stdin_dispatch() {  # run_stdin_dispatch <redirect-source> [wrapper/codex args...]
  local source="$1"
  shift
  set +e
  OUT="$(CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" SBL_HELPER="$LOCK_LIB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=2 \
      bash "$DISPATCH" --worktree "$WT" "$@" do-it < "$source" 2>&1)"
  RC=$?
  set -e
}
assert_timeout_reason() {
  if node - "$JOBS_DIR/failed" "$1" <<'NODE'
const fs = require('fs');
const [dir, reason] = process.argv.slice(2);
if (!fs.existsSync(dir)) process.exit(1);
const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));
if (files.length !== 1) process.exit(1);
const job = JSON.parse(fs.readFileSync(`${dir}/${files[0]}`, 'utf8'));
if (job.reason !== reason || !job.codex_pid || !job.dispatch_pid ||
    !job.worktree || !job.started_at) process.exit(1);
NODE
  then pass "timeout evidence: $1"; else fail "missing/incorrect timeout reason: $1"; fi
}
mkfifo "$TMP/empty-pipe"
exec 9<> "$TMP/empty-pipe"
run_stdin_dispatch "$TMP/empty-pipe"
assert_rc 0 "non-tty empty pipe defaults to EOF without timing out" "stdin-open-pipe rc=$RC out=$OUT"
exec 9>&-

printf 'the brief\nsecond line\n' > "$TMP/brief.txt"
: > "$TMP/codex.stdin"; : > "$TMP/codex.args"
run_stdin_dispatch "$TMP/brief.txt" --stdin-brief
assert_rc 0 "explicit stdin-brief dispatch exits 0" "stdin-brief rc=$RC out=$OUT"
if cmp -s "$TMP/brief.txt" "$TMP/codex.stdin"; then
  pass "--stdin-brief delivers the complete brief"
else
  fail "explicit stdin brief lost or changed"
fi
case "$(cat "$TMP/codex.args")" in
  "exec --model $CRITIC_MODEL --sandbox workspace-write do-it") pass "wrapper strips --stdin-brief from codex argv" ;;
  *) fail "stdin-brief codex args: $(cat "$TMP/codex.args")" ;;
esac
run_stdin_dispatch "$TMP/brief.txt"
assert_rc 0 "redirected file without opt-in exits 0" "stdin-file-default rc=$RC out=$OUT"
if [ ! -s "$TMP/codex.stdin" ]; then pass "redirected file is ignored without --stdin-brief"; else fail "implicit stdin brief passed through"; fi
run_stdin_dispatch /dev/null
assert_rc 0 "closed-stdin dispatch exits 0 without blocking" "stdin-null rc=$RC out=$OUT"
if [ ! -s "$TMP/codex.stdin" ]; then pass "closed stdin reaches codex as immediate EOF"; else fail "closed stdin delivered content"; fi

# Opting into a never-closing pipe still times out, with a useful diagnosis.
# A stderr startup message is NOT an event; the stdout event stream is empty.
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
printf 'Reading additional input from stdin...\n' >&2
cat > "$TMP/codex.stdin"
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
exec 9<> "$TMP/empty-pipe"
run_stdin_dispatch "$TMP/empty-pipe" --stdin-brief --json
exec 9>&-
assert_rc 124 "explicit open pipe is still bounded by the watchdog" "stdin-optin-timeout rc=$RC out=$OUT"
assert_timeout_reason 'no events before timeout — stdin pass-through?'

# The same diagnosis applies without opt-in if codex emits no stdout at all.
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'starting up\n' >&2
sleep 120
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_stdin_dispatch /dev/null --json
assert_rc 124 "stderr-only timeout exits 124" "stderr-timeout rc=$RC out=$OUT"
assert_timeout_reason 'no events before timeout — stdin pass-through?'

# Once stdout events arrive, preserve the ordinary timeout reason instead.
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"thread.started","thread_id":"fixture"}\n'
sleep 120
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_stdin_dispatch /dev/null --json
assert_rc 124 "timeout after events still exits 124" "events-timeout rc=$RC out=$OUT"
assert_timeout_reason 'timeout after 2s'
case "$OUT" in
  *'{"type":"thread.started","thread_id":"fixture"}'*) pass "stdout events still reach the caller" ;;
  *) fail "stdout event was swallowed: $OUT" ;;
esac

# 18f: dispatch completion must include the stdout relay, not just codex.
# Delay the forwarding cat after draining stdin to make the race deterministic;
# invoke directly (command substitution would wait on its pipe). Only the
# relay's two-argument invocation is intercepted, not library uses of cat.
REAL_CAT="$(command -v cat)"
mkdir -p "$TMP/slow-relay-bin"
cat > "$TMP/slow-relay-bin/cat" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ne 2 ] || [ "\$2" != - ]; then exec "$REAL_CAT" "\$@"; fi
payload=\$("$REAL_CAT" "\$@")
sleep 1
printf '%s\n' "\$payload"
printf done > "$TMP/relay.done"
EOF
chmod +x "$TMP/slow-relay-bin/cat"
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'final output\n'
EOF
set +e
PATH="$TMP/slow-relay-bin:$PATH" CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=5 \
    bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/relay.stdout" 2> "$TMP/relay.stderr"
RC=$?
set -e
assert_rc 0 "slow stdout relay preserves codex exit status" "relay rc=$RC"
if [ -f "$TMP/relay.done" ] && [ "$(cat "$TMP/relay.stdout")" = 'final output' ]; then
  pass "dispatch waits for stdout forwarding to finish"
else
  fail "dispatch exited before stdout forwarding finished"
fi
# Let the deliberately delayed fixture finish even on RED before temp cleanup.
sleep 2

# 18g: a failed relay must not turn a successful codex into false success.
# Drain stdin first so codex can exit normally, then fail without forwarding.
cat > "$TMP/slow-relay-bin/cat" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ne 2 ] || [ "\$2" != - ]; then exec "$REAL_CAT" "\$@"; fi
"$REAL_CAT" "\$@" > /dev/null
exit 23
EOF
for child_rc in 0 7; do
  cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
printf 'final output\n'
exit $child_rc
EOF
  set +e
  PATH="$TMP/slow-relay-bin:$PATH" CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=5 \
      bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/relay.stdout" 2> "$TMP/relay.stderr"
  RC=$?
  set -e
  if [ "$child_rc" -eq 0 ]; then
    assert_rc 23 "relay failure makes successful codex dispatch fail" "failed relay rc=$RC (expected 23)"
  else
    assert_rc 7 "codex failure takes precedence over relay failure" "failed codex and relay rc=$RC (expected 7)"
  fi
done

# A finished codex does not disarm the watchdog while the relay is stalled.
cat > "$TMP/slow-relay-bin/cat" <<EOF
#!/usr/bin/env bash
if [ "\$#" -ne 2 ] || [ "\$2" != - ]; then exec "$REAL_CAT" "\$@"; fi
"$REAL_CAT" "\$@" > /dev/null
sleep 120
EOF
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
printf 'final output\n'
exit 0
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
set +e
PATH="$TMP/slow-relay-bin:$PATH" CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
    CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
    HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=2 \
    bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/relay.stdout" 2> "$TMP/relay.stderr"
RC=$?
set -e
assert_rc 124 "watchdog bounds stalled relay after codex exits" "stalled relay rc=$RC"
assert_timeout_reason 'timeout after 2s'

# --- 19: large binary stdout stays byte-exact with bounded presence storage ---
# A full-retention tee fails the size assertion; dropped/reordered/NUL-stripped
# output fails the SHA-256 comparison. Snapshot before the dispatch EXIT cleanup.
mkdir -p "$TMP/presence-tmp"
node -e 'const fs = require("fs"); const b = Buffer.alloc(6 * 1024 * 1024); for (let i = 0; i < b.length; i++) b[i] = i % 256; fs.writeFileSync(process.argv[1], b)' "$TMP/payload.bin"
cat > "$STDIN_STUB" <<EOF
#!/usr/bin/env bash
cat "$TMP/payload.bin"
for ((i=0; i<100; i++)); do
  [ "\$(wc -c < "$TMP/large.stdout")" -eq 6291456 ] && break
  sleep 0.05
done
wc -c "\$TMPDIR"/* > "$TMP/presence-sizes"
exit \${LARGE_CHILD_RC:-0}
EOF
for child_rc in 0 7; do
  set +e
  TMPDIR="$TMP/presence-tmp" LARGE_CHILD_RC="$child_rc" \
      CODEX_BIN="$STDIN_STUB" CODEX_ACL_NORMALIZE="$NORM_STUB" \
      CODEX_JOBS_DIR="$JOBS_DIR" CODEX_REAP_HELPER="$REAP_STUB" \
      HIMMEL_FLOW_RUNS_LEDGER="$LEDGER" CODEX_EXEC_TIMEOUT=15 \
      bash "$DISPATCH" --worktree "$WT" do-it > "$TMP/large.stdout" 2> "$TMP/large.stderr"
  RC=$?
  set -e
  assert_rc "$child_rc" "large stdout preserves child rc=$child_rc" "large output rc=$RC"
  if node - "$TMP/payload.bin" "$TMP/large.stdout" "$TMP/presence-sizes" <<'NODE'
const fs = require('fs'), crypto = require('crypto');
const [input, output, sizes] = process.argv.slice(2);
const hash = f => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');
if (hash(input) !== hash(output)) { console.error('stdout SHA-256 mismatch'); process.exit(1); }
const rows = fs.readFileSync(sizes, 'utf8').trim().split('\n');
const total = Number(rows[rows.length - 1].trim().split(/\s+/)[0]);
if (total !== 1) { console.error(`presence storage=${total} bytes, expected 1`); process.exit(1); }
NODE
  then pass "6 MiB binary stdout hash matches; presence storage is one byte (rc=$child_rc)"
  else fail "large stdout forwarding or bounded presence tracking (rc=$child_rc)"; fi
done

# Timeout must win over a late nonzero child exit after stdout was observed.
cat > "$STDIN_STUB" <<'EOF'
#!/usr/bin/env bash
trap 'exit 7' TERM
printf 'event\n'
while :; do sleep 0.1; done
EOF
rm -rf "$JOBS_DIR"; mkdir -p "$JOBS_DIR"
run_stdin_dispatch /dev/null
assert_rc 124 "timeout wins over late child rc=7" "late child rc=$RC out=$OUT"
assert_timeout_reason 'timeout after 2s'

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
