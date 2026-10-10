#!/usr/bin/env bash
# selector: tree-scan
# E2E coverage for the HIMMEL-1666 rewrite-vector fix: a dispatched worker with
# Edit(<worktree>) can rewrite a project-local guard's ON-DISK content (not
# just delete it — the vector HIMMEL-1649 already closed). This proves
# run-hook-with-bash.js denies the tampered file instead of running it, once
# record-hook-integrity.sh has pinned the worktree at SessionStart — the
# worker-shaped session HIMMEL-1666 asks for.
#
# HIMMEL-2528 extends it with the RE-PIN path: a mismatch is no longer always
# tampering — a worktree brought up to date holds hook bytes the session-start
# pin never saw. Rows 1-28 below drive scripts/hooks/hook-integrity.js's
# three-check verification (tip / monotonic anchor / pinned blob on the anchor
# line), its record locking, and its fail-closed persistence, against real git
# fixtures with a real `origin` remote. The v2 records these rows use are built
# HERE with jq rather than by record-hook-integrity.sh, so the launcher's
# behaviour is under test independently of the recorder; only row 15 (the
# bootstrap exception) drives the real recorder.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"

# HIMMEL-3092: a console leg's shell exports guard overrides (INLINE_IMPL_OK,
# HIMMEL_CONSOLE_LEG, HIMMEL_HOOK_INTEGRITY_BYPASS_OK, ...) that reach the hook
# under test and flip every "override UNSET" case. Clear them before any case
# runs; a case that needs one still sets it explicitly on its own invocation.
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS_DIR/../lib/override-env.sh"
scrub_override_env
RECORDER="$HOOKS_DIR/record-hook-integrity.sh"
LAUNCHER="$HOOKS_DIR/run-hook-with-bash.js"
PLUGIN_LAUNCHER="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/run-hook-with-bash.js"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

# shellcheck source=scripts/lib/canon-path.sh
# shellcheck disable=SC1091
. "$HOOKS_DIR/../lib/canon-path.sh"

# HIMMEL-3179: canonicalise the fixture root so a path the rows BUILD compares
# equal to the one the hooks REPORT (macOS TMPDIR ends in "/" and lives behind
# the /var -> /private/var symlink).
T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-hook-rewrite-integrity.XXXXXX")"
T="$(canon_path "$T")" || { echo "setup: canon_path failed for the fixture root" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
OUT_DIR="$T/out"
mkdir -p "$PROJECT/scripts/hooks"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

GUARD="$PROJECT/scripts/hooks/fake-guard.sh"
cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
GUARD_EOF
chmod +x "$GUARD"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@t -c user.name=t add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q -m init

PAYLOAD='{"session_id":"worker-session-1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}'

# SessionStart pin, as it would happen before the worker's first tool call.
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$RECORDER" >/dev/null

run_launcher() {
  printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" \
    node "$LAUNCHER" --optional "$GUARD"
}

run_launcher >"$T/before.out" 2>"$T/before.err"
rc_before=$?
if [ "$rc_before" -eq 0 ] && grep -q 'permissionDecision' "$T/before.out"; then
  ok "unmodified guard runs normally before any tampering"
else
  bad "unmodified guard: rc=$rc_before out=$(cat "$T/before.out") err=$(cat "$T/before.err")"
fi

# The rewrite vector: a worker with Edit(<worktree>) overwrites the guard's
# content in place (not a delete — HIMMEL-1649 already covers that) to always
# allow.
cat > "$GUARD" <<'TAMPER_EOF'
#!/usr/bin/env bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
exit 0
# tampered: this guard used to deny; now it never does.
TAMPER_EOF

run_launcher >"$T/after.out" 2>"$T/after.err"
rc_after=$?
if [ "$rc_after" -eq 2 ] && grep -qi 'DENY' "$T/after.err"; then
  ok "tampered guard is denied at the launcher, before its content ever runs"
else
  bad "tampered guard: expected rc=2 with a DENY message, got rc=$rc_after err=$(cat "$T/after.err")"
fi

# HIMMEL-3384: the documented bypass is worktree-only and audited. In the
# PRIMARY checkout (cwd = $PROJECT) it is not honoured, so the tampered guard
# is still denied ...
BYPASS_OUT="$T/bypass.out"
BYPASS_ERR="$T/bypass.err"
(cd "$PROJECT" && printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 \
  node "$LAUNCHER" --optional "$GUARD" >"$BYPASS_OUT" 2>"$BYPASS_ERR")
rc_bypass=$?
if [ "$rc_bypass" -eq 2 ] && grep -q 'linked git worktree' "$BYPASS_ERR"; then
  ok "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 is NOT honoured in the primary checkout (and the deny names the scope)"
else
  bad "primary bypass: expected rc=2 naming the worktree scope, got rc=$rc_bypass err=$(cat "$BYPASS_ERR")"
fi

# ... a LEGACY record (no git_dir — this fixture has no origin remote, so the
# recorder wrote the pins-only shape) gives the bypass nothing to validate the
# worktree against, so it is refused even from a real linked worktree ...
WT="$T/wt"
git -C "$PROJECT" worktree add -q -b bypass-wt "$WT"
cp "$GUARD" "$WT/scripts/hooks/fake-guard.sh"
BYPASS_AUDIT="$PROJECT/.git/hook-integrity-bypass.jsonl"
(cd "$WT" && printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$WT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 \
  node "$LAUNCHER" --optional "$WT/scripts/hooks/fake-guard.sh" >"$BYPASS_OUT" 2>"$BYPASS_ERR")
rc_legacy=$?
if [ "$rc_legacy" -eq 2 ] && [ ! -e "$BYPASS_AUDIT" ]; then
  ok "a legacy record with no git_dir refuses the bypass, even in a linked worktree"
else
  bad "legacy record: expected rc=2 and no audit file, got rc=$rc_legacy err=$(cat "$BYPASS_ERR")"
fi

# ... while, once the record carries the recorded repo (git_dir, as the recorder
# writes it for a repo with an anchor), a LINKED worktree with the guard inside
# it gets the bypass and exactly one audit line.
jq --arg g "$PROJECT/.git" '. + {git_dir: $g}' "$OUT_DIR/worker-session-1.json" > "$OUT_DIR/worker-session-1.json.new" \
  && mv "$OUT_DIR/worker-session-1.json.new" "$OUT_DIR/worker-session-1.json"
(cd "$WT" && printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$WT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 \
  node "$LAUNCHER" --optional "$WT/scripts/hooks/fake-guard.sh" >"$BYPASS_OUT" 2>"$BYPASS_ERR")
rc_wt=$?
audit_lines=$(wc -l <"$BYPASS_AUDIT" 2>/dev/null || echo missing)
if [ "$rc_wt" -eq 0 ] && [ "$(printf '%s' "$audit_lines" | tr -d ' ')" = "1" ] && grep -q '"worktree"' "$BYPASS_AUDIT"; then
  ok "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 lets the tampered guard run in a linked worktree, with one audit line"
else
  bad "worktree bypass: expected rc=0 + 1 audit line, got rc=$rc_wt lines=$audit_lines err=$(cat "$BYPASS_ERR")"
fi

# HIMMEL-3384 (adversarial round): the worktree, "linked" and the audit sink come
# from CLAUDE_PROJECT_DIR and the session's RECORDED repo, never from `git
# rev-parse` in cwd (which follows a `.git` pointer FILE a worker can rewrite).
bypass_run() { # <cwd> <project dir> <guard>
  (cd "$1" && printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$2" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 \
    node "$LAUNCHER" --optional "$3" >"$BYPASS_OUT" 2>"$BYPASS_ERR")
}
audit_count() { wc -l <"$BYPASS_AUDIT" 2>/dev/null | tr -d ' '; }
expect_refused() { # <label> <rc>
  if [ "$2" -eq 2 ] && [ "$(audit_count)" = "1" ]; then
    ok "$1"
  else
    bad "$1: expected rc=2 and still 1 audit line, got rc=$2 lines=$(audit_count) err=$(cat "$BYPASS_ERR")"
  fi
}

# C1: a forged scripts/.git pointer must not turn the primary into a linked worktree.
printf 'gitdir: %s\n' "$PROJECT/.git/worktrees/wt" > "$PROJECT/scripts/.git"
bypass_run "$PROJECT/scripts" "$PROJECT" "$GUARD"
rc_c1=$?
rm -f "$PROJECT/scripts/.git"
expect_refused "C1: a forged scripts/.git pointer in the primary checkout is not a linked worktree" "$rc_c1"

# C3: a primary-session hook symlinked to a tampered worktree hook is not vouched for.
cp "$GUARD" "$T/guard.saved"
rm -f "$GUARD"
ln -s "$WT/scripts/hooks/fake-guard.sh" "$GUARD"
bypass_run "$WT" "$PROJECT" "$GUARD"
rc_c3=$?
rm -f "$GUARD"
cp "$T/guard.saved" "$GUARD"
chmod +x "$GUARD"
expect_refused "C3: a symlink from the primary hook to a worktree hook is not honoured" "$rc_c3"

# I1: a symlinked audit sink is refused; nothing is written through it.
: > "$T/scratch.log"
mv "$BYPASS_AUDIT" "$T/audit.saved"
ln -s "$T/scratch.log" "$BYPASS_AUDIT"
bypass_run "$WT" "$WT" "$WT/scripts/hooks/fake-guard.sh"
rc_i1=$?
rm -f "$BYPASS_AUDIT"
mv "$T/audit.saved" "$BYPASS_AUDIT"
if [ "$rc_i1" -eq 2 ] && [ ! -s "$T/scratch.log" ]; then
  ok "I1: a symlinked audit sink is refused and nothing is written through it"
else
  bad "I1: expected rc=2 and an empty scratch file, got rc=$rc_i1 scratch=$(cat "$T/scratch.log")"
fi

# Sibling: cwd in one worktree, CLAUDE_PROJECT_DIR the other, guard in the other.
WT2="$T/wt2"
git -C "$PROJECT" worktree add -q -b bypass-wt2 "$WT2"
cp "$GUARD" "$WT2/scripts/hooks/fake-guard.sh"
bypass_run "$WT" "$WT2" "$WT2/scripts/hooks/fake-guard.sh"
rc_sib=$?
expect_refused "a sibling worktree's cwd with CLAUDE_PROJECT_DIR set to the other worktree is refused" "$rc_sib"

# C2: a rewritten worktree .git pointer (into a decoy repo) is refused, and the
# decoy's common dir gets no audit line.
DECOY="$T/decoy"
mkdir -p "$DECOY"
git -C "$DECOY" init -q
git -C "$DECOY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$DECOY" worktree add -q -b dwt "$T/dwt"
cp "$WT/.git" "$T/wt-dotgit.saved"
printf 'gitdir: %s\n' "$DECOY/.git/worktrees/dwt" > "$WT/.git"
bypass_run "$WT" "$WT" "$WT/scripts/hooks/fake-guard.sh"
rc_c2=$?
cp "$T/wt-dotgit.saved" "$WT/.git"
if [ "$rc_c2" -eq 2 ] && [ "$(audit_count)" = "1" ] && [ ! -e "$DECOY/.git/hook-integrity-bypass.jsonl" ]; then
  ok "C2: a worktree whose .git pointer was rewritten to a decoy repo is refused, decoy log untouched"
else
  bad "C2: expected rc=2, 1 real audit line, no decoy log; got rc=$rc_c2 lines=$(audit_count) err=$(cat "$BYPASS_ERR")"
fi

# A session with no pin file at all (e.g. record-hook-integrity.sh never ran,
# or predates this checkout) must not regress to blocking every tool call.
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$T/no-such-dir" \
  node "$LAUNCHER" --optional "$GUARD" >"$T/nopins.out" 2>"$T/nopins.err"
rc_nopins=$?
if [ "$rc_nopins" -eq 0 ]; then
  ok "no pin file for the session fails open (no blast radius on unpinned sessions)"
else
  bad "no pin file: expected rc=0 (fail open), got rc=$rc_nopins err=$(cat "$T/nopins.err")"
fi

# HIMMEL-2588: "no record" is two states. The recorder leaves
# <session_id>.recorder beside the record, `started` before anything that can
# fail and `done` on exit; once it reads `done` (or `started` older than any
# recorder can live) a missing, empty or unparseable record DENIES.
SID='worker-session-1'
if [ "$(cat "$OUT_DIR/$SID.recorder" 2>/dev/null)" = "done" ]; then
  ok "HIMMEL-2588: the recorder marks itself done beside the record it wrote"
else
  bad "HIMMEL-2588: expected $OUT_DIR/$SID.recorder = done, got '$(cat "$OUT_DIR/$SID.recorder" 2>&1)'"
fi
gone_run() {   # <label> <out-dir>: run the launcher against a copied pin dir
  printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$2" \
    node "$LAUNCHER" --optional "$GUARD" >"$T/$1.out" 2>"$T/$1.err"
}
gone_dir() {   # <name>: a copy of the recorded pin dir, record mode restored
  rm -rf "${T:?}/$1"; cp -R "$OUT_DIR" "$T/$1"; chmod 600 "$T/$1/$SID.json"
}
gone_dir g1; rm -f "$T/g1/$SID.json"
gone_run g1 "$T/g1"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'record is missing' "$T/g1.err"; then
  ok "HIMMEL-2588: record deleted after the recorder ran is denied"
else
  bad "HIMMEL-2588 deleted record: expected rc=2 + 'record is missing', got rc=$rc err=$(cat "$T/g1.err")"
fi
gone_dir g2; : > "$T/g2/$SID.json"
gone_run g2 "$T/g2"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'record is missing' "$T/g2.err"; then
  ok "HIMMEL-2588: record truncated to 0 bytes is denied"
else
  bad "HIMMEL-2588 truncated record: expected rc=2, got rc=$rc err=$(cat "$T/g2.err")"
fi
gone_dir g3; printf '{"session_id":"%s"}\n' "$SID" > "$T/g3/$SID.json"
gone_run g3 "$T/g3"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "HIMMEL-2588: a parseable record with no pins is denied"
else
  bad "HIMMEL-2588 pinless record: expected rc=2, got rc=$rc err=$(cat "$T/g3.err")"
fi
gone_dir g4; rm -f "$T/g4/$SID.json" "$T/g4/$SID.recorder"
gone_run g4 "$T/g4"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "HIMMEL-2588: no recorder has run this session (no marker, no record) still fails open"
else
  bad "HIMMEL-2588 no recorder: expected rc=0, got rc=$rc err=$(cat "$T/g4.err")"
fi
gone_dir g5; rm -f "$T/g5/$SID.json"; printf 'started\n' > "$T/g5/$SID.recorder"
gone_run g5 "$T/g5"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "HIMMEL-2588: a recorder still running (fresh 'started' marker) fails open"
else
  bad "HIMMEL-2588 recorder running: expected rc=0, got rc=$rc err=$(cat "$T/g5.err")"
fi
gone_dir g7; rm -f "$T/g7/$SID.json"; : > "$T/g7/$SID.recorder"
gone_run g7 "$T/g7"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "HIMMEL-2588: a fresh empty marker (recorder caught mid-write) fails open"
else
  bad "HIMMEL-2588 empty marker: expected rc=0, got rc=$rc err=$(cat "$T/g7.err")"
fi
gone_dir g6; rm -f "$T/g6/$SID.json"; printf 'started\n' > "$T/g6/$SID.recorder"
touch -t 202001010000 "$T/g6/$SID.recorder"
gone_run g6 "$T/g6"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'HIMMEL-5171' "$T/g6.err"; then
  ok "HIMMEL-5171: a 'started' marker older than any recorder can live (killed recorder) fails open with a notice"
else
  bad "HIMMEL-5171 stale started: expected rc=0 + notice, got rc=$rc err=$(cat "$T/g6.err")"
fi
# The notice is once per session: a second hook call stays silent.
gone_run g6 "$T/g6"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'HIMMEL-5171' "$T/g6.err"; then
  ok "HIMMEL-5171: the fail-open notice is printed once per session"
else
  bad "HIMMEL-5171 notice once: expected rc=0 and no notice, got rc=$rc err=$(cat "$T/g6.err")"
fi
# The deny a deleted-after-verified-publish record earns names the recovery.
if grep -q 'record-hook-integrity.sh' "$T/g1.err" && grep -q "$SID.recorder" "$T/g1.err"; then
  ok "HIMMEL-5171: the missing-record deny names the manual recovery (marker + recorder)"
else
  bad "HIMMEL-5171 recovery text missing from deny: $(cat "$T/g1.err")"
fi

# ---------------------------------------------------------------------------
# HIMMEL-5171 — a recorder that did not publish a verified record must not
# leave the marker `done`. Each trigger runs the REAL recorder with one
# failure injected through a PATH stub, then the launcher against what it
# left. On the base every one of these is a deny for the rest of the session.
# ---------------------------------------------------------------------------
STUBS="$T/stubs"
mkdir -p "$STUBS"
REAL_JQ="$(command -v jq)"
printf '#!/bin/sh\nexit 1\n' > "$STUBS/mv.fail";     chmod +x "$STUBS/mv.fail"
printf '#!/bin/sh\nexit 1\n' > "$STUBS/mktemp.fail"; chmod +x "$STUBS/mktemp.fail"
# jq that rejects only the validation of the staged record ($out/.hook-integrity.*).
cat > "$STUBS/jq.badvalidate" <<JQ_EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in */.hook-integrity.*) exit 1 ;; esac; done
exec "$REAL_JQ" "\$@"
JQ_EOF
chmod +x "$STUBS/jq.badvalidate"

run_failing_recorder() {   # <name> <stub-name> <real-tool> <project> -> out dir $T/<name>
  local name="$1" stub="$2" tool="$3" project="$4"
  local dir="$T/$name" bin="$T/$name.bin"
  rm -rf "$dir" "$bin"; mkdir -p "$dir" "$bin"
  cp "$STUBS/$stub" "$bin/$tool"
  printf '%s' "$PAYLOAD" | PATH="$bin:$PATH" CLAUDE_PROJECT_DIR="$project" HIMMEL_HOOK_INTEGRITY_DIR="$dir" \
    bash "$RECORDER" >/dev/null 2>&1
}
expect_open() {   # <name> <label>: marker is not `done`, no record, launcher fails open
  local name="$1" label="$2" dir="$T/$1" state rc
  state="$(cat "$dir/$SID.recorder" 2>/dev/null)"
  gone_run "$name" "$dir"; rc=$?
  # The marker must be the state the injected failure leaves (`failed`, or
  # `started` for a kill): an absent or empty marker would fail open through the
  # launcher's no-marker path and pass without the failure ever being reached.
  if { [ "$state" = "failed" ] || [ "$state" = "started" ]; } && [ ! -s "$dir/$SID.json" ] && [ "$rc" -eq 0 ]; then
    ok "HIMMEL-5171: $label -> marker '$state', launcher fails open"
  else
    bad "HIMMEL-5171 $label: marker='$state' record=$([ -s "$dir/$SID.json" ] && echo present || echo none) launcher rc=$rc err=$(cat "$T/$name.err")"
  fi
}
run_failing_recorder t_mv mv.fail mv "$PROJECT"
expect_open t_mv "a failed mv publish"
run_failing_recorder t_mktemp mktemp.fail mktemp "$PROJECT"
expect_open t_mktemp "a failed mktemp"
run_failing_recorder t_jq jq.badvalidate jq "$PROJECT"
expect_open t_jq "a failed jq validate of the staged record"

# A lock lib that fails to source (verified against the anchor blob, so the
# recorder does source it): a fixture project whose lib is `return 1`.
LP="$T/lockfail"
mkdir -p "$LP/scripts/hooks"
cp "$RECORDER" "$LP/scripts/hooks/record-hook-integrity.sh"
printf 'return 1\n' > "$LP/scripts/hooks/hook-integrity-lock.sh"
git -C "$LP" init -q -b main
git -C "$LP" -c user.email=t@t -c user.name=t add -A
git -C "$LP" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$LP" update-ref refs/remotes/origin/main HEAD
rm -rf "$T/t_lock"; mkdir -p "$T/t_lock"
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$LP" HIMMEL_HOOK_INTEGRITY_DIR="$T/t_lock" \
  bash "$LP/scripts/hooks/record-hook-integrity.sh" >/dev/null 2>&1
expect_open t_lock "a lock lib that fails to source"

# A recorder killed after `started` (the 15 s hook timeout, SIGKILL): a git
# stub kills it mid pin computation; its trap never runs. The marker is then
# aged past any recorder's life, as the real 60 s would.
KB="$T/t_kill.bin"; rm -rf "$KB" "$T/t_kill"; mkdir -p "$KB" "$T/t_kill"
cat > "$KB/git" <<KILL_EOF
#!/bin/sh
case " \$* " in *" ls-tree "*) kill -9 "\$(cat "$T/t_kill.pid")" ;; esac
exec "$(command -v git)" "\$@"
KILL_EOF
chmod +x "$KB/git"
printf '%s' "$PAYLOAD" | PATH="$KB:$PATH" CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$T/t_kill" \
  bash -c 'echo $$ > "$1"; exec bash "$2"' _ "$T/t_kill.pid" "$RECORDER" >/dev/null 2>&1
touch -t 202001010000 "$T/t_kill/$SID.recorder"
if [ "$(cat "$T/t_kill/$SID.recorder" 2>/dev/null)" = "started" ]; then
  expect_open t_kill "a recorder killed after started"
else
  bad "HIMMEL-5171 killed recorder: expected marker 'started', got '$(cat "$T/t_kill/$SID.recorder" 2>&1)'"
fi

# Control: a record published and VERIFIED, then deleted, still denies.
if [ "$(cat "$OUT_DIR/$SID.recorder")" = "done" ]; then
  gone_dir c1; rm -f "$T/c1/$SID.json"
  gone_run c1 "$T/c1"; rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "HIMMEL-5171 control: a record deleted after a verified publish still denies"
  else
    bad "HIMMEL-5171 control: expected rc=2, got rc=$rc err=$(cat "$T/c1.err")"
  fi
else
  bad "HIMMEL-5171 control: the healthy recorder did not leave the marker done"
fi

# ===========================================================================
# HIMMEL-2528 — re-pin on a legitimately advanced checkout
# ===========================================================================

REL='scripts/hooks/g.sh'
REL2='scripts/hooks/sibling.sh'

# --- fixture helpers -------------------------------------------------------
# Each fixture is a real project repo with a real `origin` remote (a second,
# bare repo), so refs/remotes/origin/<branch> is a genuine remote-tracking ref
# rather than a hand-written one.
fixture() {   # <name> [branch]
  FX="$T/$1"
  FX_PROJ="$FX/project"
  FX_OUT="$FX/out"
  FX_BR="${2:-main}"
  FX_REF="refs/remotes/origin/$FX_BR"
  mkdir -p "$FX_PROJ/scripts/hooks" "$FX_OUT"
  git -C "$FX_PROJ" init -q -b "$FX_BR"
  git -C "$FX_PROJ" config user.email t@t
  git -C "$FX_PROJ" config user.name t
  git init -q --bare -b "$FX_BR" "$FX/origin.git"
  git -C "$FX_PROJ" remote add origin "$FX/origin.git"
  FX_GIT="$(git -C "$FX_PROJ" rev-parse --absolute-git-dir)"
}

guard_write() {   # <path> <marker>
  printf '#!/usr/bin/env bash\nexit 0\n# %s\n' "$2" > "$1"
  chmod +x "$1"
}

fx_commit() {   # <marker> <msg> -> prints the new commit sha
  guard_write "$FX_PROJ/$REL" "$1"
  git -C "$FX_PROJ" add -A
  git -C "$FX_PROJ" commit -q -m "$2"
  git -C "$FX_PROJ" rev-parse HEAD
}

fx_publish() {   # <committish> — advance (or rewind) origin, then refresh the tracking ref
  git -C "$FX_PROJ" push -q -f origin "$1:refs/heads/$FX_BR"
  git -C "$FX_PROJ" fetch -q --force origin
}

fx_blob() { git -C "$FX_PROJ" hash-object "$FX_PROJ/${1:-$REL}"; }

# write_record <outdir> <sid> <anchor|-> <ref|-> <gitdir|-> <rel> <blob> [<rel> <blob> ...]
# A "-" for anchor/ref/gitdir omits that field, producing a LEGACY record.
write_record() {
  local dir="$1" sid="$2" anchor="$3" ref="$4" gd="$5"
  shift 5
  local pins='{}'
  while [ "$#" -ge 2 ]; do
    pins="$(printf '%s' "$pins" | jq --arg k "$1" --arg v "$2" '. + {($k): $v}')"
    shift 2
  done
  mkdir -p "$dir"
  local out="$dir/$sid.json"
  chmod 600 "$out" 2>/dev/null || true
  jq -n --arg sid "$sid" --argjson pins "$pins" \
        --arg anchor "$anchor" --arg ref "$ref" --arg gd "$gd" \
    '{session_id:$sid, recorded_at:"2026-09-05T00:00:00Z", pins:$pins}
     + (if $ref    == "-" then {} else {anchor_ref:$ref} end)
     + (if $anchor == "-" then {} else {anchor:$anchor}  end)
     + (if $gd     == "-" then {} else {git_dir:$gd}     end)' > "$out"
  # Mode 0400 is what record-hook-integrity.sh publishes, so the re-pin's
  # chmod/rename dance is exercised for real.
  chmod 400 "$out"
}

record_pin()    { jq -r --arg k "$2" '.pins[$k] // ""' "$1"; }
record_anchor() { jq -r '.anchor // ""' "$1"; }

LAST_RC=0
# launch <projectdir> <recorddir> <session> <launcher> <args...>
launch() {
  local proj="$1" rec="$2" sid="$3" launcher="$4"
  shift 4
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' "$sid" \
    | CLAUDE_PROJECT_DIR="$proj" HIMMEL_HOOK_INTEGRITY_DIR="$rec" \
      node "$launcher" "$@" >"$T/last.out" 2>"$T/last.err"
  LAST_RC=$?
}

expect_allow() {   # <label>
  if [ "$LAST_RC" -eq 0 ] && ! grep -q 'DENY' "$T/last.err"; then
    ok "$1"
  else
    bad "$1 — expected allow, got rc=$LAST_RC err=$(cat "$T/last.err")"
  fi
}

expect_deny() {   # <label> [reason substring]
  if [ "$LAST_RC" -ne 2 ] || ! grep -q 'DENY' "$T/last.err"; then
    bad "$1 — expected rc=2 + DENY, got rc=$LAST_RC err=$(cat "$T/last.err")"
    return
  fi
  if [ "$#" -ge 2 ] && ! grep -qF "$2" "$T/last.err"; then
    bad "$1 — DENY did not name '$2': $(cat "$T/last.err")"
    return
  fi
  ok "$1"
}

expect_pin() {   # <recordfile> <rel> <blob> <label>
  local got; got="$(record_pin "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "$4"; else bad "$4 — pin is '$got', expected '$3'"; fi
}

expect_anchor() {   # <recordfile> <sha> <label>
  local got; got="$(record_anchor "$1")"
  if [ "$got" = "$2" ]; then ok "$3"; else bad "$3 — anchor is '$got', expected '$2'"; fi
}

# --- rows 1-3: advance, refuse garbage, refuse a rollback ------------------
fixture r1
A1="$(fx_commit A c1)"; fx_publish "$A1"; BLOB_A1="$(fx_blob)"
B1="$(fx_commit B c2)"; fx_publish "$B1"; BLOB_B1="$(fx_blob)"
R1="$FX_OUT/s1.json"
write_record "$FX_OUT" s1 "$A1" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A1"
launch "$FX_PROJ" "$FX_OUT" s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 1: a behind pin whose disk bytes are the anchor tip is allowed"
expect_pin "$R1" "$REL" "$BLOB_B1" "row 1: the pin was advanced on disk"
expect_anchor "$R1" "$B1" "row 1: the anchor was advanced on disk"

printf 'not a hook at all\n' > "$FX_PROJ/$REL"
write_record "$FX_OUT" s2 "$A1" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A1"
launch "$FX_PROJ" "$FX_OUT" s2 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 2: arbitrary on-disk bytes are denied" 'not the anchor tip'

guard_write "$FX_PROJ/$REL" A
launch "$FX_PROJ" "$FX_OUT" s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 3: after the advancement, the OLD content is denied" 'not the anchor tip'

# --- rows 4-5: the anchor line is monotonic --------------------------------
fixture r4
A4="$(fx_commit A c1)"; fx_publish "$A4"
B4="$(fx_commit B c2)"; fx_publish "$B4"; BLOB_B4="$(fx_blob)"
fx_publish "$A4"                      # origin force-rewound to an ancestor
guard_write "$FX_PROJ/$REL" A         # disk matches the rewound tip, so (a) passes
write_record "$FX_OUT" s4 "$B4" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_B4"
launch "$FX_PROJ" "$FX_OUT" s4 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 4: an origin rewound below the anchor is denied" 'anchor rewind'

fixture r5
A5="$(fx_commit A c1)"; fx_publish "$A5"
B5="$(fx_commit B c2)"; fx_publish "$B5"
C5="$(fx_commit C c3)"; fx_publish "$C5"; BLOB_C5="$(fx_blob)"
fx_publish "$B5"
guard_write "$FX_PROJ/$REL" B
write_record "$FX_OUT" s5 "$C5" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_C5"
launch "$FX_PROJ" "$FX_OUT" s5 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 5: A-B-C then a rewind to B is denied" 'anchor rewind'

# --- row 6: a plainly behind pin -------------------------------------------
fixture r6
fx_commit X c0 >/dev/null; fx_publish HEAD
A6="$(fx_commit A c1)"; fx_publish "$A6"; BLOB_A6="$(fx_blob)"
B6="$(fx_commit B c2)"; fx_publish "$B6"; BLOB_B6="$(fx_blob)"
R6="$FX_OUT/s6.json"
write_record "$FX_OUT" s6 "$A6" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A6"
launch "$FX_PROJ" "$FX_OUT" s6 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 6: a feature-behind pin on a linear history is allowed"
expect_pin "$R6" "$REL" "$BLOB_B6" "row 6: the behind pin was advanced"

# --- row 7: behind pin under a --no-ff merge TREESAME to the feature parent -
# This is the shape --full-history exists for: default history simplification
# follows only the TREESAME parent (the feature side) and prunes the main-line
# parent that actually introduced the pinned blob.
fixture r7
C07="$(fx_commit X c0)"; fx_publish "$C07"
C17="$(fx_commit A c1)"; BLOB_A7="$(fx_blob)"
git -C "$FX_PROJ" checkout -q -b feat "$C07"
guard_write "$FX_PROJ/$REL" B
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m f1
git -C "$FX_PROJ" checkout -q "$FX_BR"
git -C "$FX_PROJ" merge -q --no-ff -X theirs feat -m 'merge feat' >/dev/null 2>&1
M7="$(git -C "$FX_PROJ" rev-parse HEAD)"
fx_publish "$M7"
BLOB_B7="$(fx_blob)"
R7="$FX_OUT/s7.json"
write_record "$FX_OUT" s7 "$C17" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A7"
launch "$FX_PROJ" "$FX_OUT" s7 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 7: a behind pin under a --no-ff TREESAME merge is allowed"
expect_pin "$R7" "$REL" "$BLOB_B7" "row 7: the pin was advanced across the merge"

# --- rows 8-9: an AHEAD pin never advances ---------------------------------
# Row 8 is the local/unmerged EDIT: origin moved on without touching the hook,
# so the on-disk bytes are not the tip's bytes — check (a) refuses.
fixture r8
A8="$(fx_commit A c1)"; fx_publish "$A8"; BLOB_A8="$(fx_blob)"
printf 'unrelated\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m d1
D8="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$D8"
guard_write "$FX_PROJ/$REL" F
R8="$FX_OUT/s8.json"
write_record "$FX_OUT" s8 "$A8" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A8"
launch "$FX_PROJ" "$FX_OUT" s8 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 8: an unmerged change F on this branch is denied" 'not the anchor tip'
expect_pin "$R8" "$REL" "$BLOB_A8" "row 8: the record is unchanged after the deny"
expect_anchor "$R8" "$A8" "row 8: the anchor is unchanged after the deny"

# Row 9 is the AHEAD pin proper: the session pinned an unmerged blob F, and the
# checkout is then rolled back to the tip's bytes. (a) and (b) both pass; only
# (c) — the pinned blob is nowhere in the anchor line — refuses.
fixture r9
A9="$(fx_commit A c1)"; fx_publish "$A9"
git -C "$FX_PROJ" checkout -q -b feat
guard_write "$FX_PROJ/$REL" F
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m f1
BLOB_F9="$(fx_blob)"
git -C "$FX_PROJ" checkout -q "$FX_BR"
printf 'unrelated\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m d1
D9="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$D9"
guard_write "$FX_PROJ/$REL" A
R9="$FX_OUT/s9.json"
write_record "$FX_OUT" s9 "$A9" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_F9"
launch "$FX_PROJ" "$FX_OUT" s9 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 9: an ahead pin restored to older bytes is denied" 'pinned blob is not on the anchor line'
expect_pin "$R9" "$REL" "$BLOB_F9" "row 9: the ahead pin is not advanced"

# --- row 10: refs/replace must not be able to forge the tip ----------------
fixture r10
guard_write "$FX_PROJ/$REL" A
printf 'x\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c0
printf 'y\n' > "$FX_PROJ/other.txt"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c1
C110="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$C110"
BLOB_A10="$(fx_blob)"
TREE10="$(git -C "$FX_PROJ" rev-parse "$C110^{tree}")"
git -C "$FX_PROJ" checkout -q -b tamper
guard_write "$FX_PROJ/$REL" TAMPERED
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m ct
TREE10T="$(git -C "$FX_PROJ" rev-parse "HEAD^{tree}")"
BLOB_T10="$(fx_blob)"
git -C "$FX_PROJ" checkout -q "$FX_BR"
guard_write "$FX_PROJ/$REL" TAMPERED     # the tampered bytes on disk
git -C "$FX_PROJ" replace "$TREE10" "$TREE10T"
# Positive control: without the env var, git resolves the FORGED tree, so all
# three checks would pass and the tampered file would be allowed.
forged="$(cd /tmp && git --git-dir="$FX_GIT" rev-parse --verify --quiet "$C110:$REL")"
fenced="$(cd /tmp && GIT_NO_REPLACE_OBJECTS=1 git --git-dir="$FX_GIT" rev-parse --verify --quiet "$C110:$REL")"
if [ "$forged" = "$BLOB_T10" ] && [ "$fenced" = "$BLOB_A10" ]; then
  ok "row 10: control — refs/replace really would forge the tip without the fence"
else
  bad "row 10: control — replace fixture is not exercising the fence (forged=$forged fenced=$fenced)"
fi
write_record "$FX_OUT" s10 "$C110" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A10"
launch "$FX_PROJ" "$FX_OUT" s10 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 10: a refs/replace-forged tip is denied (GIT_NO_REPLACE_OBJECTS=1)" 'not the anchor tip'

# --- row 11: the record's git_dir wins over the project's .git pointer -----
# A worktree's .git is a one-line pointer FILE, writable by the same Edit grant
# this whole check exists to survive. Verification must never follow it.
R11D="$T/r11"
mkdir -p "$R11D/real/scripts/hooks" "$R11D/project/scripts/hooks" "$R11D/out"
git -C "$R11D/real" init -q -b main
git -C "$R11D/real" config user.email t@t
git -C "$R11D/real" config user.name t
guard_write "$R11D/real/$REL" A
git -C "$R11D/real" add -A
git -C "$R11D/real" commit -q -m c1
A11="$(git -C "$R11D/real" rev-parse HEAD)"
BLOB_A11="$(git -C "$R11D/real" hash-object "$R11D/real/$REL")"
git -C "$R11D/real" update-ref refs/remotes/origin/main "$A11"
REAL_GIT="$(git -C "$R11D/real" rev-parse --absolute-git-dir)"
# The decoy: a clone whose origin/main tip DOES contain the tampered blob, with
# the real anchor as an ancestor — i.e. a repo that would satisfy all three
# checks if verification followed the pointer file.
git clone -q "$R11D/real" "$R11D/decoy"
git -C "$R11D/decoy" config user.email t@t
git -C "$R11D/decoy" config user.name t
guard_write "$R11D/decoy/$REL" TAMPERED
git -C "$R11D/decoy" add -A
git -C "$R11D/decoy" commit -q -m tampered
DECOY_TIP="$(git -C "$R11D/decoy" rev-parse HEAD)"
git -C "$R11D/decoy" update-ref refs/remotes/origin/main "$DECOY_TIP"
DECOY_GIT="$(git -C "$R11D/decoy" rev-parse --absolute-git-dir)"
guard_write "$R11D/project/$REL" TAMPERED
printf 'gitdir: %s\n' "$DECOY_GIT" > "$R11D/project/.git"
write_record "$R11D/out" s11 "$A11" refs/remotes/origin/main "$REAL_GIT" "$REL" "$BLOB_A11"
launch "$R11D/project" "$R11D/out" s11 "$LAUNCHER" --optional "$R11D/project/$REL"
expect_deny "row 11: a rewritten .git pointer cannot redirect verification" 'not the anchor tip'
write_record "$R11D/out" s11c "$A11" refs/remotes/origin/main "$DECOY_GIT" "$REL" "$BLOB_A11"
launch "$R11D/project" "$R11D/out" s11c "$LAUNCHER" --optional "$R11D/project/$REL"
expect_allow "row 11: control — the decoy repo really would have allowed the tampered blob"

# --- rows 12-13: records this path cannot use ------------------------------
fixture r12
A12="$(fx_commit A c1)"; fx_publish "$A12"; BLOB_A12="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
R12="$FX_OUT/s12.json"
write_record "$FX_OUT" s12 - - - "$REL" "$BLOB_A12"
launch "$FX_PROJ" "$FX_OUT" s12 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 12: a legacy record still denies an ordinary mismatched hook"
if grep -qE '^[[:space:]]+at |node:internal' "$T/last.err"; then
  bad "row 12: a stack trace leaked to stderr: $(cat "$T/last.err")"
else
  ok "row 12: the legacy deny carries no stack trace"
fi
expect_pin "$R12" "$REL" "$BLOB_A12" "row 12: the legacy record is unchanged"

write_record "$FX_OUT" s13 "$A12" refs/remotes/origin/nope "$FX_GIT" "$REL" "$BLOB_A12"
launch "$FX_PROJ" "$FX_OUT" s13 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 13: an unresolvable anchor_ref is denied" 'could not be resolved'

# --- row 14: an unwritable pin directory must deny, never allow ------------
# shellcheck source=../lib/host-caps.sh
. "$REPO_ROOT/scripts/lib/host-caps.sh"
if ! host_can_deny_write; then
  # root, or NTFS/MSYS: chmod 500 does not stop a write there (HIMMEL-3182)
  host_skip "row 14: a read-only directory does not stop a write on this host"
else
  fixture r14
  A14="$(fx_commit A c1)"; fx_publish "$A14"; BLOB_A14="$(fx_blob)"
  B14="$(fx_commit B c2)"; fx_publish "$B14"
  R14="$FX_OUT/s14.json"
  write_record "$FX_OUT" s14 "$A14" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A14"
  before14="$(cat "$R14")"
  chmod 500 "$FX_OUT"
  launch "$FX_PROJ" "$FX_OUT" s14 "$LAUNCHER" --optional "$FX_PROJ/$REL"
  # Either fail-closed reason is correct here: the same read-only directory that
  # would refuse the re-pin's rename also refuses the lock's mkdir, and which
  # one is reached first is an implementation detail. What must never happen is
  # an allow on an advancement that was never persisted.
  expect_deny "row 14: an unwritable pin directory denies rather than allowing"
  if grep -qE 'could not persist the re-pin under|could not take the record lock at' "$T/last.err"; then
    ok "row 14: the deny names the pin directory or the lock it could not take"
  else
    bad "row 14: the deny named neither the pin dir nor the lock: $(cat "$T/last.err")"
  fi
  chmod 700 "$FX_OUT"
  if [ "$before14" = "$(cat "$R14")" ]; then
    ok "row 14: the record content is unchanged"
  else
    bad "row 14: the record was modified despite the deny"
  fi
fi

# --- rows 15-16: the bounded bootstrap exception (HIMMEL-2528 §4) ----------
# record-hook-integrity.sh pins ITSELF and the plugin's SessionStart chain runs
# it through this launcher, so a live session holding a LEGACY record would deny
# the changed recorder before it could ever write a v2 record. The exception is
# tip-equality on the recorder's own path only.
fixture r15
cp "$RECORDER" "$FX_PROJ/scripts/hooks/record-hook-integrity.sh"
chmod +x "$FX_PROJ/scripts/hooks/record-hook-integrity.sh"
# The recorder verifies-then-sources <its own dir>/hook-integrity-lock.sh, and
# the copy under test is the one in the FIXTURE, so the fixture has to carry
# that lib or the recorder publishes on its degraded lock-free path instead of
# the locked one these rows are meant to exercise. That is now the only thing it
# needs: the recorder no longer sources $CLAUDE_PROJECT_DIR/scripts/guardrails/
# lib.sh for default_branch — it carries an inlined resolve_default_branch(),
# precisely so the hook that ESTABLISHES the pins never executes project-local
# code before any pin exists to vouch for it.
# Unconditional, deliberately: this used to be guarded by a `[ -f <src> ]` test,
# which turned into a silent no-op the moment the lib moved out of scripts/lib/
# and quietly downgraded the fixture instead of failing.
cp "$REPO_ROOT/scripts/hooks/hook-integrity-lock.sh" "$FX_PROJ/scripts/hooks/hook-integrity-lock.sh" \
  || bad "row 15 fixture: could not stage the lock lib the recorder verifies-then-sources"
guard_write "$FX_PROJ/$REL" A
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c1
A15="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$A15"
REC_REL='scripts/hooks/record-hook-integrity.sh'
STALE='0000000000000000000000000000000000000000'
R15="$FX_OUT/s15.json"
write_record "$FX_OUT" s15 - - - "$REC_REL" "$STALE"
launch "$FX_PROJ" "$FX_OUT" s15 "$LAUNCHER" --optional "$FX_PROJ/$REC_REL"
expect_allow "row 15a: bootstrap — a legacy record lets the tip-matching recorder run"
if jq -e 'has("anchor_ref") and has("anchor") and has("git_dir")' "$R15" >/dev/null 2>&1; then
  ok "row 15b: the recorder replaced the legacy record with a v2 one"
else
  bad "row 15b: the published record is still legacy (expected until record-hook-integrity.sh emits schema v2): $(cat "$R15")"
fi
# The staged lock lib is load-bearing but was invisible in the pass/fail signal:
# the recorder still PUBLISHES without it, on its degraded lock-free path, and
# only stamps lock_unverified to say so. Assert the healthy shape, so a fixture
# that silently loses the lib (as the `[ -f ]`-guarded cp above once did) shows
# up here instead of being absorbed.
if jq -e '(.lock_unverified // false) | not' "$R15" >/dev/null 2>&1; then
  ok "row 15c: the recorder vouched for the fixture's lock lib and published under the lock"
else
  bad "row 15c: the recorder fell back to its lock-free path — the fixture lost the lock lib: $(cat "$R15")"
fi

printf '\n# locally modified, never committed\n' >> "$FX_PROJ/$REC_REL"
write_record "$FX_OUT" s16 - - - "$REC_REL" "$STALE"
launch "$FX_PROJ" "$FX_OUT" s16 "$LAUNCHER" --optional "$FX_PROJ/$REC_REL"
expect_deny "row 16: bootstrap is tip-equality, not a blanket pass for the recorder"

# --- rows 17-18: the fast path spawns nothing; the slow path needs git -----
fixture r17
A17="$(fx_commit A c1)"; fx_publish "$A17"; BLOB_A17="$(fx_blob)"
STUB="$T/stub-bin"
MARKER="$T/git-was-called"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$MARKER" > "$STUB/git"
chmod +x "$STUB/git"
write_record "$FX_OUT" s17 "$A17" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A17"
printf '{"session_id":"s17","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" PATH="$STUB:$PATH" \
    node "$LAUNCHER" --optional "$FX_PROJ/$REL" >"$T/last.out" 2>"$T/last.err"
LAST_RC=$?
expect_allow "row 17: a correctly-pinned guard runs with a failing git stub first on PATH"
if [ -e "$MARKER" ]; then
  bad "row 17: the fast path spawned git: $(cat "$MARKER")"
else
  ok "row 17: the fast path spawned no git at all (stub marker never written)"
fi

fixture r18
A18="$(fx_commit A c1)"; fx_publish "$A18"; BLOB_A18="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
EMPTY_BIN="$T/empty-bin"
mkdir -p "$EMPTY_BIN"
# node by ABSOLUTE path, because the point of this row is a PATH with no git on
# it at all — the launcher's own interpreter must survive that.
NODE_BIN="$(command -v node)"
write_record "$FX_OUT" s18 "$A18" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A18"
printf '{"session_id":"s18","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" PATH="$EMPTY_BIN" \
    "$NODE_BIN" "$LAUNCHER" --optional "$FX_PROJ/$REL" >"$T/last.out" 2>"$T/last.err"
LAST_RC=$?
expect_deny "row 18: git absent on the mismatch path denies without crashing" 'git is unavailable'

# --- row 19: a master-default project -------------------------------------
fixture r19 master
A19="$(fx_commit A c1)"; fx_publish "$A19"; BLOB_A19="$(fx_blob)"
B19="$(fx_commit B c2)"; fx_publish "$B19"; BLOB_B19="$(fx_blob)"
R19="$FX_OUT/s19.json"
write_record "$FX_OUT" s19 "$A19" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A19"
launch "$FX_PROJ" "$FX_OUT" s19 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 19: a master-default project advances the same way"
expect_pin "$R19" "$REL" "$BLOB_B19" "row 19: the master-default pin was advanced"

# --- rows 20-22: the chain paths re-pin too -------------------------------
fixture r20
A20="$(fx_commit A c1)"; fx_publish "$A20"; BLOB_A20="$(fx_blob)"
B20="$(fx_commit B c2)"; fx_publish "$B20"; BLOB_B20="$(fx_blob)"
R20="$FX_OUT/s20.json"
write_record "$FX_OUT" s20 "$A20" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A20"
launch "$FX_PROJ" "$FX_OUT" s20 "$LAUNCHER" --chain --lifecycle "$FX_PROJ/$REL"
expect_pin "$R20" "$REL" "$BLOB_B20" "row 20: the --lifecycle chain re-pins synchronously"
expect_anchor "$R20" "$B20" "row 20: the --lifecycle chain advanced the anchor"

fixture r21
guard_write "$FX_PROJ/$REL" A
guard_write "$FX_PROJ/$REL2" A
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c1
A21="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$A21"
BLOB1_A21="$(fx_blob "$REL")"; BLOB2_A21="$(fx_blob "$REL2")"
guard_write "$FX_PROJ/$REL" B
guard_write "$FX_PROJ/$REL2" B
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m c2
B21="$(git -C "$FX_PROJ" rev-parse HEAD)"; fx_publish "$B21"
BLOB1_B21="$(fx_blob "$REL")"; BLOB2_B21="$(fx_blob "$REL2")"
R21="$FX_OUT/s21.json"
write_record "$FX_OUT" s21 "$A21" "$FX_REF" "$FX_GIT" "$REL" "$BLOB1_A21" "$REL2" "$BLOB2_A21"
launch "$FX_PROJ" "$FX_OUT" s21 "$LAUNCHER" --chain "$FX_PROJ/$REL" "$FX_PROJ/$REL2"
expect_allow "row 21: a chain advances every pinned member it runs"
expect_pin "$R21" "$REL"  "$BLOB1_B21" "row 21: the first chain member's pin advanced"
expect_pin "$R21" "$REL2" "$BLOB2_B21" "row 21: the second chain member's pin advanced"
expect_anchor "$R21" "$B21" "row 21: the anchor settled on the tip"
if jq -e . "$R21" >/dev/null 2>&1; then
  ok "row 21: the record is still valid JSON after two advancements"
else
  bad "row 21: the record is not valid JSON after two advancements"
fi

fixture r22
A22="$(fx_commit A c1)"; fx_publish "$A22"; BLOB_A22="$(fx_blob)"
B22="$(fx_commit B c2)"; fx_publish "$B22"; BLOB_B22="$(fx_blob)"
SIBLING='1111111111111111111111111111111111111111'
R22="$FX_OUT/s22.json"
write_record "$FX_OUT" s22 "$A22" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A22" "$REL2" "$SIBLING"
launch "$FX_PROJ" "$FX_OUT" s22 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 22: advancing one pin with a sibling pin present"
expect_pin "$R22" "$REL"  "$BLOB_B22" "row 22: our pin advanced"
expect_pin "$R22" "$REL2" "$SIBLING"  "row 22: the sibling pin survived the merge"

# --- rows 23-26: the record lock ------------------------------------------
# Field 22 of /proc/<pid>/stat (starttime). comm can contain spaces and parens,
# so everything up to the last ") " goes first; field 3 is then field 1.
proc_start() { awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }

# A pid that is definitively gone: started and reaped right here.
dead_pid() {
  local p
  bash -c 'exit 0' &
  p=$!
  wait "$p" 2>/dev/null
  printf '%s' "$p"
}

fixture r23
A23="$(fx_commit A c1)"; fx_publish "$A23"; BLOB_A23="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
R23="$FX_OUT/s23.json"
write_record "$FX_OUT" s23 "$A23" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A23"
before23="$(cat "$R23")"
LOCK23="$R23.lock"
mkdir -p "$LOCK23"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK23/owner"
touch -d '2020-01-01' "$LOCK23" 2>/dev/null || true
launch "$FX_PROJ" "$FX_OUT" s23 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 23: a LIVE lock owner is never reclaimed, however old the lock" "could not take the record lock at $LOCK23"
if [ "$before23" = "$(cat "$R23")" ]; then
  ok "row 23: the record is unchanged while another owner holds the lock"
else
  bad "row 23: the record changed under a held lock"
fi
rm -rf "$LOCK23"

fixture r24
A24="$(fx_commit A c1)"; fx_publish "$A24"; BLOB_A24="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
R24="$FX_OUT/s24.json"
write_record "$FX_OUT" s24 "$A24" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A24"
LOCK24="$R24.lock"
mkdir -p "$LOCK24"
# An MSYS pid from a Git-Bash sibling: a different pid namespace, so its number
# means nothing here. The pid is one that IS dead in OUR namespace, so the
# namespace check is the only thing standing between this lock and a reclaim.
printf 'pid=%s\npid_namespace=msys\nstart_time=\n' "$(dead_pid)" > "$LOCK24/owner"
launch "$FX_PROJ" "$FX_OUT" s24 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 24: a foreign pid_namespace lock is denied, not reclaimed" 'could not take the record lock at'
if [ -d "$LOCK24" ]; then
  ok "row 24: the foreign-namespace lock is still held"
else
  bad "row 24: the foreign-namespace lock was reclaimed"
fi
rm -rf "$LOCK24"

# pid 1 exists but belongs to another user, so process.kill(pid, 0) throws
# EPERM rather than ESRCH — "exists under another user" is LIVE, not dead.
mkdir -p "$LOCK24"
printf 'pid=1\npid_namespace=posix\nstart_time=\n' > "$LOCK24/owner"
launch "$FX_PROJ" "$FX_OUT" s24 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 24b: a lock owned by another user's live pid is not reclaimed" 'could not take the record lock at'
if [ -d "$LOCK24" ]; then
  ok "row 24b: the EPERM lock is still held"
else
  bad "row 24b: the EPERM lock was reclaimed"
fi
rm -rf "$LOCK24"

fixture r25
A25="$(fx_commit A c1)"; fx_publish "$A25"; BLOB_A25="$(fx_blob)"
B25="$(fx_commit B c2)"; fx_publish "$B25"; BLOB_B25="$(fx_blob)"
R25="$FX_OUT/s25.json"
write_record "$FX_OUT" s25 "$A25" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A25"
DEAD_PID="$(dead_pid)"
LOCK25="$R25.lock"
mkdir -p "$LOCK25"
printf 'pid=%s\npid_namespace=posix\nstart_time=\n' "$DEAD_PID" > "$LOCK25/owner"
launch "$FX_PROJ" "$FX_OUT" s25 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 25: a lock whose owner is provably dead is reclaimed"
expect_pin "$R25" "$REL" "$BLOB_B25" "row 25: the advancement completed after the reclaim"

fixture r26
A26="$(fx_commit A c1)"; fx_publish "$A26"; BLOB_A26="$(fx_blob)"
B26="$(fx_commit B c2)"; fx_publish "$B26"; BLOB_B26="$(fx_blob)"
R26="$FX_OUT/s26.json"
write_record "$FX_OUT" s26 "$A26" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A26"
LOCK26="$R26.lock"
mkdir -p "$LOCK26"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK26/owner"
# The sibling that holds the lock publishes the very advancement we want, inside
# our bounded 200 ms wait: the launcher must re-read and take the fast path
# rather than deny.
R26_OUT="$FX_OUT" R26_ANCHOR="$B26" R26_REF="$FX_REF" R26_GIT="$FX_GIT" R26_BLOB="$BLOB_B26" \
  bash -c 'sleep 0.1; chmod 600 "$R26_OUT/s26.json"; jq --arg k "'"$REL"'" --arg v "$R26_BLOB" --arg a "$R26_ANCHOR" ".pins[\$k]=\$v | .anchor=\$a" "$R26_OUT/s26.json" > "$R26_OUT/s26.next" && mv -f "$R26_OUT/s26.next" "$R26_OUT/s26.json"' &
SIBLING_PID=$!
launch "$FX_PROJ" "$FX_OUT" s26 "$LAUNCHER" --optional "$FX_PROJ/$REL"
wait "$SIBLING_PID" 2>/dev/null
expect_allow "row 26: a lock timeout re-reads and honours a sibling's published advancement"
rm -rf "$LOCK26"

# --- row 27: the HIMMEL-2526 must-run entry -------------------------------
if node -e 'const m = require(process.argv[1]); process.exit(m.MUST_RUN_CHAIN_MEMBERS.has("block-write-into-main-checkout.sh") ? 0 : 1);' "$LAUNCHER"; then
  ok "row 27: MUST_RUN_CHAIN_MEMBERS carries block-write-into-main-checkout.sh"
else
  bad "row 27: MUST_RUN_CHAIN_MEMBERS is missing block-write-into-main-checkout.sh"
fi

# --- row 28: the vendored plugin launcher behaves identically -------------
fixture r28
A28="$(fx_commit A c1)"; fx_publish "$A28"; BLOB_A28="$(fx_blob)"
B28="$(fx_commit B c2)"; fx_publish "$B28"; BLOB_B28="$(fx_blob)"
R28="$FX_OUT/s28.json"
write_record "$FX_OUT" s28 "$A28" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A28"
launch "$FX_PROJ" "$FX_OUT" s28 "$PLUGIN_LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 28: the vendored plugin launcher performs the same advancement"
expect_pin "$R28" "$REL" "$BLOB_B28" "row 28: the plugin launcher advanced the pin"

# --- row 29: the dead-owner steal picks exactly one winner ----------------
# Two launchers can read the SAME dead owner and both conclude "reclaim", so the
# steal has to pick a winner. This row drives the LOSER against a winner spliced
# into its timeline at the point the race actually happens: after the loser has
# inspected the dead owner, before its own steal. In-process because that is the
# only place the interleaving can be staged — the loser has to be interrupted
# between reading the owner and renaming the directory.
#
# The splice performs a real reclaim and NOTHING ELSE; the loser's rename is its
# own, executed for real against whatever the winner left at the path. An
# earlier version of this row threw a synthetic ENOENT there instead, which
# manufactured the refusal it claimed to pin: in the interleaving it named, the
# loser's rename SUCCEEDS against the lock the winner has re-taken, and the old
# stub hid exactly that.
#
# Two winner timings, both real:
#   gone      — the winner has stolen and deleted the dead lock but not yet
#               re-taken the path, so the loser's rename hits a genuinely absent
#               directory and fails on its own;
#   recreated — the winner has already re-taken the lock under its own LIVE pid,
#               so the loser's rename succeeds and must be UNDONE rather than
#               followed by a delete.
R29D="$T/r29"
mkdir -p "$R29D"
cat > "$R29D/drive.js" <<'DRV29'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const lockDir = process.argv[3];
const deadPid = process.argv[4];
const mode = process.argv[5];   // 'gone' | 'recreated'
const liveOwner = `pid=${process.pid}\npid_namespace=posix\nstart_time=\n`;

fs.mkdirSync(lockDir);
fs.writeFileSync(path.join(lockDir, 'owner'), `pid=${deadPid}\npid_namespace=posix\nstart_time=\n`);

const realRename = fs.renameSync;
let raced = false;
fs.renameSync = (from, to) => {
  if (!raced && String(from) === lockDir) {
    raced = true;
    // The concurrent WINNER's full steal, and in 'recreated' mode its re-take.
    const won = `${lockDir}.winner-graveyard`;
    realRename(from, won);
    fs.rmSync(won, { recursive: true, force: true });
    if (mode === 'recreated') {
      fs.mkdirSync(lockDir);
      fs.writeFileSync(path.join(lockDir, 'owner'), liveOwner);
    }
  }
  // The LOSER's own rename. Not stubbed, not short-circuited.
  return realRename(from, to);
};

const reclaimed = mod.reclaimIfDead(lockDir);
fs.renameSync = realRename;
let owner = '';
try {
  owner = fs.readFileSync(path.join(lockDir, 'owner'), 'utf8');
} catch (_e) { /* nothing at the lock path */ }
console.log(JSON.stringify({
  reclaimed,
  raced,                                   // proof the splice ran at all
  lockPresent: fs.existsSync(lockDir),
  winnerLockIntact: owner === liveOwner,   // only the winner ever writes this pid
}));
DRV29
OUT29G="$(node "$R29D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R29D/gone.json.lock" "$(dead_pid)" gone)"
if [ "$(printf '%s' "$OUT29G" | jq -r '.raced')" = "true" ]; then
  ok "row 29a: the winner really was spliced into the loser's steal (gone)"
else
  bad "row 29a: the splice never fired, so nothing was raced: $OUT29G"
fi
if [ "$(printf '%s' "$OUT29G" | jq -r '.reclaimed')" = "false" ] \
  && [ "$(printf '%s' "$OUT29G" | jq -r '.lockPresent')" = "false" ]; then
  ok "row 29a: a loser whose rename genuinely fails refuses and resurrects nothing"
else
  bad "row 29a: the losing reclaimer did not refuse cleanly: $OUT29G"
fi

OUT29R="$(node "$R29D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R29D/recreated.json.lock" "$(dead_pid)" recreated)"
if [ "$(printf '%s' "$OUT29R" | jq -r '.raced')" = "true" ]; then
  ok "row 29b: the winner really was spliced in and re-took the lock"
else
  bad "row 29b: the splice never fired, so nothing was raced: $OUT29R"
fi
if [ "$(printf '%s' "$OUT29R" | jq -r '.reclaimed')" = "false" ]; then
  ok "row 29b: a loser whose rename SUCCEEDS against the re-taken lock still refuses"
else
  bad "row 29b: the loser claimed a lock it stole from the live winner: $OUT29R"
fi
if [ "$(printf '%s' "$OUT29R" | jq -r '.winnerLockIntact')" = "true" ]; then
  ok "row 29b: the winner's live lock is put back, not carted off to the graveyard"
else
  bad "row 29b: the loser destroyed the winner's live lock: $OUT29R"
fi

# --- row 30: an owner file that will not write leaves no lock behind -------
# mkdir can succeed and the owner write fail on its own (a full disk, a
# directory that turned unwritable between the two). An owner-LESS lock is the
# worst residue there is: reclaimIfDead refuses an unreadable owner forever, so
# the directory would wedge the re-pin path for every future session.
R30D="$T/r30"
mkdir -p "$R30D"
cat > "$R30D/drive.js" <<'DRV30'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];
const lockDir = `${recordPath}.lock`;

const realWrite = fs.writeFileSync;
fs.writeFileSync = (file, ...rest) => {
  if (String(file) === path.join(lockDir, 'owner')) {
    const err = new Error('ENOSPC: no space left on device');
    err.code = 'ENOSPC';
    throw err;
  }
  return realWrite(file, ...rest);
};
const first = mod.acquireRecordLock(recordPath);
fs.writeFileSync = realWrite;
const leftover = fs.existsSync(lockDir);
// The harm an owner-less lock does is permanent, so the recovery is the real
// assertion: the very next acquire, with nothing wrong any more, must work.
const second = mod.acquireRecordLock(recordPath);
if (second) mod.releaseRecordLock(second);
console.log(JSON.stringify({ acquired: first !== null, leftover, recovered: second !== null }));
DRV30
OUT30="$(node "$R30D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R30D/rec.json")"
if [ "$(printf '%s' "$OUT30" | jq -r '.acquired')" = "false" ] && [ "$(printf '%s' "$OUT30" | jq -r '.leftover')" = "false" ]; then
  ok "row 30: an owner-write failure reports failure and leaves no lock directory"
else
  bad "row 30: the failed acquire did not clean up: $OUT30"
fi
if [ "$(printf '%s' "$OUT30" | jq -r '.recovered')" = "true" ]; then
  ok "row 30: the next acquire is not wedged by the failed one"
else
  bad "row 30: the record lock is permanently wedged after an owner-write failure: $OUT30"
fi

# --- row 31: a failed win32 publish never leaves the record absent ---------
# On win32 the rename over an existing record can fail, and the fallback used to
# unlink the incumbent first. Lock-free fast-path readers fail OPEN on a missing
# record, so a second rename that also fails disabled verification for the rest
# of the session. Both the platform and the failing rename are supplied here;
# the assertion is that the record survives.
R31D="$T/r31"
mkdir -p "$R31D"
printf '{"pins":{},"anchor":"before"}\n' > "$R31D/rec.json"
chmod 400 "$R31D/rec.json"
cat > "$R31D/drive.js" <<'DRV31'
const fs = require('node:fs');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];
Object.defineProperty(process, 'platform', { value: 'win32' });
const original = fs.readFileSync(recordPath, 'utf8');

// Every rename of the temp file ONTO the record fails; renames of the record
// aside are left alone, so the fallback runs and then fails its second rename.
const realRename = fs.renameSync;
fs.renameSync = (from, to) => {
  if (String(to) === recordPath && String(from).indexOf(`${recordPath}.tmp-`) === 0) {
    const err = new Error('EPERM: operation not permitted');
    err.code = 'EPERM';
    throw err;
  }
  return realRename(from, to);
};
let threw = false;
try {
  mod.persistIntegrityRecord(recordPath, { pins: { 'scripts/hooks/g.sh': 'deadbeef' }, anchor: 'after' });
} catch (_e) {
  threw = true;
}
fs.renameSync = realRename;
const exists = fs.existsSync(recordPath);
console.log(JSON.stringify({
  threw,
  exists,
  unchanged: exists && fs.readFileSync(recordPath, 'utf8') === original,
}));
DRV31
OUT31="$(node "$R31D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R31D/rec.json")"
if [ "$(printf '%s' "$OUT31" | jq -r '.threw')" = "true" ] && [ "$(printf '%s' "$OUT31" | jq -r '.exists')" = "true" ]; then
  ok "row 31: a failed win32 publish still leaves a record on disk"
else
  bad "row 31: the win32 publish left no record (readers would fail open): $OUT31"
fi
if [ "$(printf '%s' "$OUT31" | jq -r '.unchanged')" = "true" ]; then
  ok "row 31: the restored record is the incumbent one, byte for byte"
else
  bad "row 31: the record on disk is not the incumbent: $OUT31"
fi

# --- row 32: a hung git is a bounded deny, not a wedged lock ---------------
# The mismatch path shells out to git while HOLDING the record lock, so a git
# that never returns (a .git on a dead mount) would wedge every other launcher
# in the session. The budget is env-overridable so this row can use 400 ms
# instead of the 5 s production bound; the stub hangs for 30 s, so an unbounded
# git is unmistakable.
fixture r32
A32="$(fx_commit A c1)"; fx_publish "$A32"; BLOB_A32="$(fx_blob)"
fx_commit B c2 >/dev/null; fx_publish HEAD
SLOW_BIN="$T/slow-bin"
mkdir -p "$SLOW_BIN"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$SLOW_BIN/git"
chmod +x "$SLOW_BIN/git"
write_record "$FX_OUT" s32 "$A32" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A32"
start32="$(date +%s)"
printf '{"session_id":"s32","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" PATH="$SLOW_BIN:$PATH" \
    HIMMEL_HOOK_INTEGRITY_GIT_TIMEOUT_MS=400 \
    node "$LAUNCHER" --optional "$FX_PROJ/$REL" >"$T/last.out" 2>"$T/last.err"
LAST_RC=$?
elapsed32=$(( $(date +%s) - start32 ))
expect_deny "row 32: a git that hangs denies and names the budget it blew" '400 ms verification budget'
if [ "$elapsed32" -le 10 ]; then
  ok "row 32: the deny arrived in ${elapsed32}s, nowhere near the stub's 30 s hang"
else
  bad "row 32: the hung git was not bounded (${elapsed32}s)"
fi
if [ -e "$FX_OUT/s32.json.lock" ]; then
  bad "row 32: the record lock was left held after the timeout"
else
  ok "row 32: the record lock is released after the timeout"
fi

# --- rows 33-36: reading across the win32 publish window -------------------
# persistIntegrityRecord's win32 fallback has no atomic replace: it moves the
# incumbent ASIDE and renames the replacement in, and between the two there is
# no record on disk. Readers take the fast path WITHOUT the lock and an absent
# record reads as "no opinion" → allow, so a reader in that window skipped
# verification entirely — permanently, if the publisher was killed inside it.
# These rows stage the on-disk state that window leaves (record gone, an
# `<record>.old-…` aside beside it, the lock held) and drive the real launcher.
ASIDE_SUFFIX='.old-4242-a1b2c3'

fixture r33
A33="$(fx_commit A c1)"; fx_publish "$A33"; BLOB_A33="$(fx_blob)"
R33="$FX_OUT/s33.json"
write_record "$FX_OUT" s33 "$A33" "$FX_REF" "$FX_GIT" "$REL" "$BLOB_A33"
# The pin MATCHES the disk, so a reader that finds the record allows on the fast
# path and a reader that fails open allows too — only a reader that notices the
# publication in flight behaves differently.
LOCK33="$R33.lock"
mkdir -p "$LOCK33"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK33/owner"
chmod 600 "$R33"
mv "$R33" "$R33$ASIDE_SUFFIX"
launch "$FX_PROJ" "$FX_OUT" s33 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 33: a reader inside a LIVE publisher's window does not fail open" 'is still in flight'
if [ -f "$R33$ASIDE_SUFFIX" ] && [ ! -f "$R33" ]; then
  ok "row 33: a live publisher's window is waited out, never stolen"
else
  bad "row 33: the reader touched a live publisher's aside"
fi
rm -rf "$LOCK33"

fixture r34
A34="$(fx_commit A c1)"; fx_publish "$A34"
R34="$FX_OUT/s34.json"
# LEGACY record pinning a blob the disk does not carry: once the reader gets the
# record back it must DENY. Failing open (the pre-fix behaviour) allows, so the
# two outcomes are not merely different reasons for the same verdict.
write_record "$FX_OUT" s34 - - - "$REL" "$STALE"
LOCK34="$R34.lock"
mkdir -p "$LOCK34"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK34/owner"
chmod 600 "$R34"
mv "$R34" "$R34$ASIDE_SUFFIX"
# The publisher finishes inside the reader's bounded wait, exactly as a healthy
# win32 publish does — one rename later the record is back.
R34_SRC="$R34$ASIDE_SUFFIX" R34_DST="$R34" R34_LOCK="$LOCK34" \
  bash -c 'sleep 0.05; mv -f "$R34_SRC" "$R34_DST"; rm -rf "$R34_LOCK"' &
PUB34=$!
launch "$FX_PROJ" "$FX_OUT" s34 "$LAUNCHER" --optional "$FX_PROJ/$REL"
wait "$PUB34" 2>/dev/null
expect_deny "row 34: the reader waits the window out and verifies against the record that lands"
if grep -q 'in flight' "$T/last.err"; then
  bad "row 34: the deny came from the in-flight branch, not from the landed record: $(cat "$T/last.err")"
else
  ok "row 34: the deny is the landed record's verdict, not the in-flight refusal"
fi
rm -rf "$LOCK34"

fixture r35
A35="$(fx_commit A c1)"; fx_publish "$A35"
R35="$FX_OUT/s35.json"
write_record "$FX_OUT" s35 - - - "$REL" "$STALE"
INCUMBENT35="$(cat "$R35")"
LOCK35="$R35.lock"
mkdir -p "$LOCK35"
printf 'pid=%s\npid_namespace=posix\nstart_time=\n' "$(dead_pid)" > "$LOCK35/owner"
chmod 600 "$R35"
mv "$R35" "$R35$ASIDE_SUFFIX"
launch "$FX_PROJ" "$FX_OUT" s35 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 35: a publisher killed mid-window does not leave verification silently off"
if [ -f "$R35" ] && [ "$(cat "$R35")" = "$INCUMBENT35" ]; then
  ok "row 35: the incumbent record is put back, so the deny is not a wedge either"
else
  bad "row 35: the incumbent was not restored — the session stays without a record"
fi
if [ -e "$LOCK35" ]; then
  bad "row 35: the dead publisher's lock is still held"
else
  ok "row 35: the dead publisher's stale lock was reclaimed on the way through"
fi

# The control that keeps the discriminator honest. record-hook-integrity.sh
# holds this same lock while it builds a session's FIRST record, and there is
# legitimately no record on disk then — so the LOCK alone must never mean
# "publication in flight". Without an aside beside it, this stays fail-open.
fixture r36
guard_write "$FX_PROJ/$REL" A
LOCK36="$FX_OUT/s36.json.lock"
mkdir -p "$LOCK36"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK36/owner"
launch "$FX_PROJ" "$FX_OUT" s36 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 36: a held lock with no aside (the recorder's first record) still fails open"
rm -rf "$LOCK36"

# --- rows 37a/37b: the publisher finishes WHILE the reader inspects --------
# The two markers rows 33-36 rely on are the DEBRIS of a publication in flight,
# and a publisher that finishes takes them away. So "no lock" and "no aside" are
# also exactly what a publication that completed one instant ago looks like, and
# both used to return fail-open WITHOUT re-reading the now-published record —
# the function gave up in the very window it exists to close.
#
# Determinism comes from WHERE the publisher's last two acts are scheduled, not
# from faking their effect: the driver hooks the syscall the reader uses to
# inspect each marker, performs the real completion (rename the aside back,
# drop the lock) and then calls through to the real syscall. The module reads a
# real filesystem and returns its own verdict; the assertions are that the
# trigger fired and that the verdict is the RESTORED record's.
R37D="$T/r37"
mkdir -p "$R37D"
cat > "$R37D/drive.js" <<'DRV37'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];
const aside = process.argv[4];
const trigger = process.argv[5];
const scriptPath = process.argv[6];
const sessionId = process.argv[7];
const lockDir = `${recordPath}.lock`;

let finished = false;
const finish = (dropLock) => {
  if (finished) return;
  finished = true;
  fs.renameSync(aside, recordPath);          // the publish lands
  if (dropLock) fs.rmSync(lockDir, { recursive: true, force: true });
};

const realExists = fs.existsSync;
const realReaddir = fs.readdirSync;
if (trigger === 'lock') {
  // The publisher is entirely done by the time the reader looks for the lock.
  fs.existsSync = (p) => {
    if (String(p) === lockDir) finish(true);
    return realExists(p);
  };
} else {
  // persistIntegrityRecord unlinks the aside before its caller releases the
  // lock, so the aside can be gone while the lock is still held.
  fs.readdirSync = (p, ...rest) => {
    if (String(p) === path.dirname(recordPath)) finish(false);
    return realReaddir(p, ...rest);
  };
}
let result;
try {
  result = mod.verifyProjectHookIntegrity(scriptPath, sessionId);
} finally {
  fs.existsSync = realExists;
  fs.readdirSync = realReaddir;
}
console.log(JSON.stringify({
  finished,
  ok: result.ok === true,
  reason: result.reason || '',
  recordBack: realExists(recordPath),
}));
DRV37

# <session> <trigger> <label>
drive_r37() {
  fixture "r37$2"
  fx_commit A c1 >/dev/null; fx_publish HEAD
  # A LEGACY record pinning a blob the disk does not carry: honouring it DENIES,
  # while the pre-fix fail-open allows. The two outcomes are opposite verdicts,
  # not two spellings of one.
  write_record "$FX_OUT" "$1" - - - "$REL" "$STALE"
  local rec="$FX_OUT/$1.json"
  mkdir -p "$rec.lock"
  printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$rec.lock/owner"
  chmod 600 "$rec"
  mv "$rec" "$rec$ASIDE_SUFFIX"
  local out
  out="$(CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" \
    node "$R37D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$rec" "$rec$ASIDE_SUFFIX" "$2" \
      "$FX_PROJ/$REL" "$1")"
  if [ "$(printf '%s' "$out" | jq -r '.finished')" != "true" ] \
    || [ "$(printf '%s' "$out" | jq -r '.recordBack')" != "true" ]; then
    bad "$3 — the staged publisher never completed, so the row proved nothing: $out"
    return
  fi
  if [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ]; then
    ok "$3"
  else
    bad "$3 — the reader failed open past a record that was on disk: $out"
  fi
  # Both halves, or the row passes on a fail-open allow (which also carries no
  # reason) and says nothing.
  if [ "$(printf '%s' "$out" | jq -r '.ok')" = "false" ] \
    && [ "$(printf '%s' "$out" | jq -r '.reason')" = "" ]; then
    ok "$3 (the verdict is the restored record's, not an in-flight refusal)"
  else
    bad "$3 — expected the record's own deny, got: $out"
  fi
  rm -rf "$rec.lock"
}
drive_r37 s37a lock  "row 37a: a lock that vanished because the publish LANDED re-reads before failing open"
drive_r37 s37b aside "row 37b: an aside that vanished because the publish LANDED re-reads before failing open"

# --- row 38: an ambiguous window denies; it does not read as absence -------
# publishAsidePath answered null both for "no aside" and for "several", and the
# caller reads null as no evidence → fail open. So ONE leftover aside from an
# earlier failed cleanup put every later window of that session back on the
# fail-open path. Several asides is strictly more evidence than none.
fixture r38
fx_commit A c1 >/dev/null; fx_publish HEAD
R38="$FX_OUT/s38.json"
write_record "$FX_OUT" s38 - - - "$REL" "$STALE"
LOCK38="$R38.lock"
mkdir -p "$LOCK38"
printf 'pid=%s\npid_namespace=posix\nstart_time=%s\n' "$$" "$(proc_start $$)" > "$LOCK38/owner"
chmod 600 "$R38"
mv "$R38" "$R38$ASIDE_SUFFIX"
printf 'an aside an earlier window never cleaned up\n' > "$R38.old-1111-c0ffee"
launch "$FX_PROJ" "$FX_OUT" s38 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 38: a leftover second aside makes the window ambiguous, and ambiguous denies" \
  'more than one unresolved publication aside'
# The deny is part of this assertion too: a fail-open reader also leaves both
# asides in place, so "untouched" alone would be green with the fix reverted.
if [ "$LAST_RC" -eq 2 ] && [ -f "$R38$ASIDE_SUFFIX" ] \
  && [ -f "$R38.old-1111-c0ffee" ] && [ ! -f "$R38" ]; then
  ok "row 38: neither aside is guessed at — the reader refuses instead of restoring one"
else
  bad "row 38: the reader picked an incumbent out of an ambiguous window"
fi
rm -rf "$LOCK38"

# --- row 39: release removes only a lock this process still owns -----------
# reclaimIfDead's restore can fail (its RESIDUAL), leaving a former holder with
# a path string a SUCCESSOR now owns. An unconditional rm -rf on the way out
# deleted that successor's live lock — the bash twin's hil_lock_release has
# always checked the owner first, and this is where the two diverged.
R39D="$T/r39"
mkdir -p "$R39D"
cat > "$R39D/drive.js" <<'DRV39'
const fs = require('node:fs');
const path = require('node:path');
const mod = require(process.argv[2]);
const recordPath = process.argv[3];

const mine = mod.acquireRecordLock(recordPath);
// The residual state, built with the real operations in the real order: a
// reclaimer renames our live lock aside, then a successor mkdirs the vacated
// path and stamps its OWN owner file.
fs.renameSync(mine, `${mine}.dead.stolen`);
fs.mkdirSync(mine);
fs.writeFileSync(path.join(mine, 'owner'), 'pid=1\npid_namespace=posix\nstart_time=\n');
const successor = fs.readFileSync(path.join(mine, 'owner'), 'utf8');
mod.releaseRecordLock(mine);   // our critical section ends; we release what we think we hold
const survived = fs.existsSync(mine)
  && fs.readFileSync(path.join(mine, 'owner'), 'utf8') === successor;

// Control: "never release" would pass the assertion above and wedge every
// future acquire, so a lock we DO own must still come down.
fs.rmSync(mine, { recursive: true, force: true });
const own = mod.acquireRecordLock(recordPath);
if (own) mod.releaseRecordLock(own);
console.log(JSON.stringify({
  acquired: mine !== null,
  survived,
  released: own !== null && !fs.existsSync(mine),
}));
DRV39
OUT39="$(node "$R39D/drive.js" "$HOOKS_DIR/hook-integrity.js" "$R39D/rec.json")"
if [ "$(printf '%s' "$OUT39" | jq -r '.acquired')" != "true" ]; then
  bad "row 39: the driver never took a lock, so the row proved nothing: $OUT39"
elif [ "$(printf '%s' "$OUT39" | jq -r '.survived')" = "true" ]; then
  ok "row 39: releasing a lock a successor now owns is a no-op, not a deletion"
else
  bad "row 39: the release deleted the successor's live lock: $OUT39"
fi
if [ "$(printf '%s' "$OUT39" | jq -r '.released')" = "true" ]; then
  ok "row 39: a lock this process really owns is still released"
else
  bad "row 39: release refused a lock we own — the next acquire is wedged: $OUT39"
fi

# ===========================================================================
# HIMMEL-4575 — the sourced-lib closure is verified, not only the member
# ===========================================================================
# A guard that sources a lib runs that lib's bytes as guard code, so a lib
# edited mid-session is as tampered as an edited member. The member below
# reaches each lib by one of the spellings real hooks use: a
# `$(dirname "${BASH_SOURCE[0]}")`-relative path, a `../guardrails` hop, a
# variable assigned the path, and a lib that sources a sibling of its own.
fixture lib-closure
mkdir -p "$FX_PROJ/scripts/hooks/lib" "$FX_PROJ/scripts/guardrails" "$FX_PROJ/scripts/lib"
cat > "$FX_PROJ/$REL" <<'LIBG_EOF'
#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/helper.sh"
if ! { [ -r "$(dirname "${BASH_SOURCE[0]}")/../guardrails/lib.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/../guardrails/lib.sh"; } 2>/dev/null; then exit 2; fi
_armor="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/armor.sh"
. "$_armor"
exit 0
LIBG_EOF
# shellcheck disable=SC2016 # literal shell/JS text for the fixture, expanded by its reader
printf '#!/usr/bin/env bash\n. "${BASH_SOURCE[0]%%/*}/nested.sh"\n' > "$FX_PROJ/scripts/hooks/lib/helper.sh"
for lib in scripts/hooks/lib/nested.sh scripts/guardrails/lib.sh scripts/lib/armor.sh; do
  printf '#!/usr/bin/env bash\n: lib\n' > "$FX_PROJ/$lib"
done
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m libs
fx_publish HEAD
printf '{"session_id":"lib-s1","hook_event_name":"SessionStart"}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" bash "$RECORDER" >/dev/null 2>&1
LIB_REC="$FX_OUT/lib-s1.json"
if [ -n "$(record_pin "$LIB_REC" scripts/lib/armor.sh)" ] && [ -n "$(jq -r '.anchor_ref // ""' "$LIB_REC")" ]; then
  ok "row 40: the recorder pins scripts/lib/*.sh too (a v2 record with the lib pin)"
else
  bad "row 40: no v2 record with a scripts/lib pin: $(cat "$LIB_REC" 2>/dev/null)"
fi

launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 41: a member whose whole sourced closure matches its pins runs"

for lib in scripts/hooks/lib/nested.sh scripts/guardrails/lib.sh scripts/lib/armor.sh scripts/hooks/lib/helper.sh; do
  cp "$FX_PROJ/$lib" "$T/lib.orig"
  printf '# tampered\n' >> "$FX_PROJ/$lib"
  launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
  expect_deny "row 42: an edited sourced lib ($lib) denies the member that sources it" "$lib"
  cp "$T/lib.orig" "$FX_PROJ/$lib"
done
launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --chain "$FX_PROJ/$REL"
expect_allow "row 42 control: restored libs run again (the denies above were the edits)"

# The re-pin path covers a lib exactly as it covers a member: a lib advanced
# to the anchor tip by a legitimate update is accepted and its pin advanced.
printf '# advanced\n' >> "$FX_PROJ/scripts/lib/armor.sh"
git -C "$FX_PROJ" commit -q -am 'advance armor'
fx_publish HEAD
launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 43: a lib advanced to the anchor tip re-pins instead of denying"
expect_pin "$LIB_REC" scripts/lib/armor.sh "$(fx_blob scripts/lib/armor.sh)" "row 43: the lib's pin advanced to the tip blob"

# A closure lib nobody pinned is not vouched for: the member names it, it now
# exists on disk, and no session-start pin says what its bytes should be.
# shellcheck disable=SC2016 # literal shell/JS text for the fixture, expanded by its reader
printf '. "$(dirname "${BASH_SOURCE[0]}")/late.sh"\n' >> "$FX_PROJ/scripts/hooks/lib/helper.sh"
git -C "$FX_PROJ" commit -q -am 'helper sources late.sh'
fx_publish HEAD
printf '#!/usr/bin/env bash\n: late\n' > "$FX_PROJ/scripts/hooks/lib/late.sh"
launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 44: a sourced lib with no session pin denies" "scripts/hooks/lib/late.sh"
rm -f "$FX_PROJ/scripts/hooks/lib/late.sh"
launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 44: a sourced lib that is absent everywhere the walk looks denies too" "unresolved"
git -C "$FX_PROJ" revert --no-edit HEAD >/dev/null
fx_publish HEAD
launch "$FX_PROJ" "$FX_OUT" lib-s1 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 44 control: with the late.sh source line reverted (and re-pinned to the tip) the member runs"

# A source statement the closure walk cannot resolve to a file leaves part of
# the guard's code unknown, so it fails closed rather than skipping it.
REL_U='scripts/hooks/unresolved.sh'
# shellcheck disable=SC2016 # literal shell/JS text for the fixture, expanded by its reader
printf '#!/usr/bin/env bash\n. "$SOME_LIB_FROM_NOWHERE"\nexit 0\n' > "$FX_PROJ/$REL_U"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m unresolved
fx_publish HEAD
printf '{"session_id":"lib-s2","hook_event_name":"SessionStart"}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" bash "$RECORDER" >/dev/null 2>&1
launch "$FX_PROJ" "$FX_OUT" lib-s2 "$LAUNCHER" --optional "$FX_PROJ/$REL_U"
expect_deny "row 45: a source statement that resolves to no file denies" "unresolved"

# A literal source of an existing file the recorder does not pin (no .sh
# suffix) is code no pin covers, so it denies too.
REL_N='scripts/hooks/nonsh.sh'
printf 'exit 0\n' > "$FX_PROJ/scripts/lib/payload"
printf '#!/usr/bin/env bash\n. scripts/lib/payload\nexit 0\n' > "$FX_PROJ/$REL_N"
git -C "$FX_PROJ" add -A
git -C "$FX_PROJ" commit -q -m nonsh
fx_publish HEAD
printf '{"session_id":"lib-s3","hook_event_name":"SessionStart"}' \
  | CLAUDE_PROJECT_DIR="$FX_PROJ" HIMMEL_HOOK_INTEGRITY_DIR="$FX_OUT" bash "$RECORDER" >/dev/null 2>&1
launch "$FX_PROJ" "$FX_OUT" lib-s3 "$LAUNCHER" --optional "$FX_PROJ/$REL_N"
expect_deny "row 45b: a literal source of an unpinnable non-.sh file denies" "unresolved"

# A record written before the lib dirs were pinned (every session live when
# this lands) has no pin for a lib: one whose bytes are the anchor tip's is
# adopted and its pin persisted; one with other bytes still denies.
LIB2_REC="$FX_OUT/lib-s2.json"
# The recorder publishes 0400 records; open it before rewriting, as
# write_record does, or the cp fails and nothing is unpinned (J1927 T1).
unpin_armor() {
  jq 'del(.pins["scripts/lib/armor.sh"])' "$LIB2_REC" >"$T/lib-s2.json" &&
    chmod 600 "$LIB2_REC" && cp "$T/lib-s2.json" "$LIB2_REC"
  if [ -n "$(record_pin "$LIB2_REC" scripts/lib/armor.sh)" ]; then
    bad "row 47 setup: the armor.sh pin is still in the record"
  fi
}
unpin_armor
launch "$FX_PROJ" "$FX_OUT" lib-s2 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 47: an unpinned lib at the anchor tip's bytes is adopted"
expect_pin "$LIB2_REC" scripts/lib/armor.sh "$(fx_blob scripts/lib/armor.sh)" "row 47: the adopted lib's pin was persisted"
unpin_armor
printf '# off-tip\n' >> "$FX_PROJ/scripts/lib/armor.sh"
launch "$FX_PROJ" "$FX_OUT" lib-s2 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_deny "row 47: an unpinned lib whose bytes are on no anchor-line commit denies" "anchor line"
git -C "$FX_PROJ" checkout -q -- scripts/lib/armor.sh

# J1927 B1: a record from before the lib dirs were pinned, in a worktree
# that main has since moved past. The lib is untouched (its bytes are the
# worktree's own committed version, which is on the anchor line), so it is
# adopted; judging it against the moved tip alone denied every hook it sat
# under.
unpin_armor
OLD_ARMOR="$(fx_blob scripts/lib/armor.sh)"
printf '# main moved\n' >> "$FX_PROJ/scripts/lib/armor.sh"
git -C "$FX_PROJ" commit -q -am 'main moves armor'
MOVED="$(git -C "$FX_PROJ" rev-parse HEAD)"
fx_publish HEAD
git -C "$FX_PROJ" reset -q --hard HEAD~1
launch "$FX_PROJ" "$FX_OUT" lib-s2 "$LAUNCHER" --optional "$FX_PROJ/$REL"
expect_allow "row 48: an unpinned lib behind a moved anchor tip, on the anchor line, is adopted"
expect_pin "$LIB2_REC" scripts/lib/armor.sh "$OLD_ARMOR" "row 48: the adopted lib's pin is its own on-disk blob"
git -C "$FX_PROJ" reset -q --hard "$MOVED"

# Every member the live settings and the plugin dispatch must have a closure
# the walk resolves completely, under directories the recorder pins — else
# row 45's fail-closed denies a real guard on every call.
# shellcheck disable=SC2016 # literal shell/JS text for the fixture, expanded by its reader
node -e '
const m = require(process.argv[1]);
const fs = require("fs"); const path = require("path");
const root = process.argv[2];
const members = new Set();
for (const f of [".claude/settings.json", "marketplace/plugins/himmel-ops/hooks/hooks.json"]) {
  for (const x of fs.readFileSync(path.join(root, f), "utf8").matchAll(/scripts\/hooks\/[A-Za-z0-9_.-]+\.sh/g)) members.add(x[0]);
}
const bad = [];
const seen = new Set();
const queue = [...members];
while (queue.length) {
  const rel = queue.shift();
  if (seen.has(rel)) continue;
  seen.add(rel);
  const r = m.sourcedClosure(path.join(root, rel), root);
  for (const u of r.unresolved) bad.push(`${rel}: unresolved ${u}`);
  for (const lib of r.libs) {
    const k = path.relative(root, lib);
    if (!m.PIN_DIRS.some((d) => k.startsWith(`${d}/`))) bad.push(`${rel}: ${k} is outside the pinned dirs`);
    else queue.push(k);
  }
}
console.log(bad.length ? bad.join("\n") : `ok ${members.size} members, ${seen.size} files`);
' "$HOOKS_DIR/hook-integrity.js" "$REPO_ROOT" >"$T/closure.out" 2>&1
if grep -q '^ok [0-9]' "$T/closure.out"; then
  ok "row 46: every dispatched member's sourced closure resolves under the pinned dirs ($(cat "$T/closure.out"))"
else
  bad "row 46: dispatched closure gaps: $(cat "$T/closure.out")"
fi

# HIMMEL-4584 — a sourced path resolves only through the ref's real value.
# HIMMEL-4585 ships only the fail-closed half: the source scan reads quoted
# spans and heredoc bodies as code, exactly as before, so a `source` inside
# them still denies (judge j2149c: a text mask for "this is data" fails open by
# construction — HIMMEL-4998 owns solving the false denies at a non-text
# layer). Unit rows against sourcedClosure: a throwaway root with one pinnable
# lib, one member file per case.
SC="$T/sc"
mkdir -p "$SC/scripts/hooks" "$SC/scripts/lib"
printf '#!/usr/bin/env bash\n: lib\n' > "$SC/scripts/lib/armor.sh"
sc_case() {   # <label> <want libs> <want unresolved> — the member text is on stdin
  cat > "$SC/scripts/hooks/m.sh"
  local got
  got="$(node -e '
const m = require(process.argv[1]);
const r = m.sourcedClosure(process.argv[2] + "/scripts/hooks/m.sh", process.argv[2]);
console.log(r.libs.length + " " + r.unresolved.length);
' "$HOOKS_DIR/hook-integrity.js" "$SC" 2>&1)"
  if [ "$got" = "$2 $3" ]; then ok "$1"; else bad "$1: want libs/unresolved '$2 $3', got '$got'"; fi
}
# shellcheck disable=SC2016 # literal shell text for the fixtures, expanded by their reader
{
# Row 49 on origin/main denied these (quoted text is scanned). An earlier
# revision of this PR masked them as data; that mask was fail-open (j2149c), so
# the rows now pin the deny.
sc_case "row 49: a source inside a single-quoted string still denies (scanned as code, as on main)" 0 1 <<'E'
echo 'if source "$MISSING"'
E
sc_case "row 49: a source inside a double-quoted string still denies" 0 1 <<'E'
echo "then source $MISSING_LIB"
E
sc_case "row 49: a source inside a quoted heredoc body still denies (both lines)" 0 2 <<'E'
cat <<'EOT'
source "$MISSING"
. "$ALSO_MISSING"
EOT
E
sc_case "row 49: a source in plain text of an unquoted heredoc body still denies" 0 1 <<'E'
cat <<-EOT
	source "$MISSING"
	EOT
E
sc_case "row 49 control: a real command-position source of an unresolvable ref denies" 0 1 <<'E'
source "$MISSING"
E
sc_case "row 49 control: a source after a heredoc ends is a real statement" 0 1 <<'E'
cat <<'EOT'
text
EOT
source "$MISSING"
E
sc_case "row 49 control: a source inside a command substitution in a double-quoted string denies" 0 1 <<'E'
x="$(. "$MISSING")"
E
sc_case "row 49 control: a source inside a command substitution in an unquoted heredoc body denies" 0 1 <<'E'
cat <<EOT
$(. "$MISSING")
EOT
E
sc_case "row 49 control: an unterminated quote scans as before and denies" 0 1 <<'E'
echo 'oops
source "$MISSING"
E
sc_case "row 50: a command-substitution prefix that is not a self-dir form denies" 0 1 <<'E'
source "$(printf /outside)/scripts/lib/armor.sh"
E
sc_case "row 50: a ref neither assigned in-file nor a known self-dir form denies" 0 1 <<'E'
source "$NOWHERE_REF/scripts/lib/armor.sh"
E
sc_case "row 50: a ref assigned a non-self-dir command substitution denies" 0 1 <<'E'
X="$(printf /outside)"
source "$X/scripts/lib/armor.sh"
E
sc_case "row 50: an assigned ref resolves only through its assignment (no file-dir or root fallback)" 0 1 <<'E'
X="$(dirname "$0")/nowhere"
source "$X/scripts/lib/armor.sh"
E
sc_case "row 50 control: a ref assigned a self-dir form resolves" 1 0 <<'E'
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$D/../lib/armor.sh"
E
sc_case "row 50 control: a dirname-of-zero prefix resolves" 1 0 <<'E'
source "$(dirname "$0")/../lib/armor.sh"
E
sc_case "row 50 control: CLAUDE_PROJECT_DIR resolves" 1 0 <<'E'
source "${CLAUDE_PROJECT_DIR}/scripts/lib/armor.sh"
E
sc_case "row 51: comment-looking lines inside a quoted string do not hide a later real source" 0 1 <<'E'
echo 'x
# '
source "$MISSING"
echo 'y
# '
E
sc_case "row 52: a self-dir subst over a ref assigned an absolute path denies (cd resolves outside the checkout)" 0 1 <<'E'
X=/outside; source "$(cd $X && pwd)/scripts/lib/armor.sh"
E
sc_case "row 52 control: a self-dir subst over a ref assigned a self-dir form resolves" 1 0 <<'E'
X="$(dirname "$0")"; source "$(cd "$X" && pwd)/../lib/armor.sh"
E
sc_case "row 53: a parameter-expansion operator on CLAUDE_PROJECT_DIR is not the plain value" 0 1 <<'E'
source "${CLAUDE_PROJECT_DIR:+/outside}/scripts/lib/armor.sh"
E
sc_case "row 53: a parameter-expansion operator on BASH_SOURCE inside a self-dir subst denies" 0 1 <<'E'
source "$(dirname ${BASH_SOURCE:+/outside})/../lib/armor.sh"
E
sc_case "row 53 control: an empty-default CLAUDE_PROJECT_DIR resolves" 1 0 <<'E'
source "${CLAUDE_PROJECT_DIR:-}/scripts/lib/armor.sh"
E
sc_case "row 53 control: a source inside bash -c quotes still joins the closure (the any-position pass reads quoted text on purpose)" 1 0 <<'E'
bash -c '. ../lib/armor.sh'
E
sc_case "row 54: a self-dir subst whose cd target is a literal absolute path denies" 0 1 <<'E'
source "$(cd / && pwd)/scripts/lib/armor.sh"
E
sc_case "row 54: a self-dir subst whose cd target is a cwd-relative path denies" 0 1 <<'E'
source "$(cd ../../.. && pwd)/scripts/lib/armor.sh"
E
sc_case "row 54: a suffix strip on CLAUDE_PROJECT_DIR names its parent, not the checkout" 0 1 <<'E'
source "${CLAUDE_PROJECT_DIR%/*}/scripts/lib/armor.sh"
E
sc_case "row 54 control: BASH_SOURCE suffix strip is the file's own dirname" 1 0 <<'E'
source "${BASH_SOURCE[0]%/*}/../lib/armor.sh"
E
sc_case "row 55: a dirname subst with no self reference denies" 0 1 <<'E'
source "$(dirname /)/scripts/lib/armor.sh"
E
sc_case "row 55: a bare cd subst with no self reference denies" 0 1 <<'E'
source "$(cd && pwd)/scripts/lib/armor.sh"
E
sc_case "row 55 control: a nested-quote dirname of $0 resolves" 1 0 <<'E'
source "$(cd "$(dirname "$0")" && pwd)/../lib/armor.sh"
E
sc_case "row 56: an apostrophe in a comment after a case-arm paren does not hide a later real source" 0 1 <<'E'
case $x in
x)# don't
source "$MISSING" ;;
y)# won't
esac
E
sc_case "row 56: the same with a command-substitution operand outside the checkout" 0 1 <<'E'
case $x in
x)# don't
source "$(printf /outside)/scripts/lib/armor.sh" ;;
y)# won't
esac
E
sc_case "row 56: a comment after a redirection operator is a comment" 0 1 <<'E'
true >/dev/null <# don't
source "$MISSING"
true >/dev/null <# won't
E
sc_case "row 57: a left shift inside (( )) does not hide a later real source" 0 1 <<'E'
(( n = 1 << b ))
source "$MISSING"
b
E
sc_case "row 57: a left shift inside an arithmetic substitution does not hide a later real source" 0 1 <<'E'
x=$(( 1 << b ))
source "$MISSING"
b
E
# Row 58/62: every way to run quoted text as code (the j2149 and j2149b shapes).
sc_case "row 58: eval of a double-quoted string runs its source" 0 1 <<'E'
eval "true; source \"$MISSING\""
E
sc_case "row 58: bash -c of a single-quoted string runs its source" 0 1 <<'E'
bash -c 'true; source "$MISSING"'
E
sc_case "row 58: sh -lc of a double-quoted string runs its source" 0 1 <<'E'
sh -lc "true; source $MISSING"
E
sc_case "row 58: a path-qualified shell -c runs its source" 0 1 <<'E'
/bin/bash -c 'true; source "$MISSING"'
E
sc_case "row 58: a flag cluster after c still runs its source" 0 1 <<'E'
bash -cl 'true; source "$MISSING"'
E
sc_case "row 58: eval after -- runs its source" 0 1 <<'E'
eval -- 'true; source "$MISSING"'
E
sc_case "row 62: a shell option with an argument before -c runs its source" 0 1 <<'E'
bash -o pipefail -c 'true; source "$MISSING"'
E
sc_case "row 62: bash -O extglob -c runs its source" 0 1 <<'E'
bash -O extglob -c 'true; source "$MISSING"'
E
sc_case "row 62: a line continuation before the string still runs its source" 0 1 <<'E'
bash -c \
  'true; source "$MISSING"'
E
sc_case "row 62: a quoted \$BASH -c runs its source" 0 1 <<'E'
"$BASH" -c 'true; source "$MISSING"'
E
sc_case "row 62: mksh -c runs its source" 0 1 <<'E'
mksh -c 'true; source "$MISSING"'
E
sc_case "row 62: a trap string runs its source" 0 1 <<'E'
trap 'true; source "$MISSING"' EXIT
E
sc_case "row 62: a variable later eval-ed runs its source" 0 1 <<'E'
cmd='true; source "$MISSING"'
eval "$cmd"
E
sc_case "row 62: a heredoc fed to bash runs its source" 0 1 <<'E'
bash <<EOT
source "$MISSING"
EOT
E
sc_case "row 62: echo piped into bash runs its source" 0 1 <<'E'
echo 'true; source "$MISSING"' | bash
E
sc_case "row 62: a plain assignment of source text still denies (cannot prove it is never run)" 0 1 <<'E'
msg='true; source "$MISSING"'
echo "$msg"
E
sc_case "row 62: cat of a heredoc into a file still denies" 0 1 <<'E'
cat > out.txt <<EOT
true; source "$MISSING"
EOT
E
sc_case "row 58: echo of the same string still denies" 0 1 <<'E'
echo "true; source \"$MISSING\""
E
sc_case "row 59: a heredoc with a double-quoted delimiter still denies" 0 1 <<'E'
cat <<"EOT"
source "$MISSING"
EOT
E
sc_case "row 59: a heredoc with a backslash delimiter still denies" 0 1 <<'E'
cat <<\EOT
source "$MISSING"
EOT
E
sc_case "row 60: a source in a backtick span inside double quotes runs" 0 1 <<'E'
x="`true; source $MISSING`"
E
sc_case "row 60: a source in a backtick span in an unquoted heredoc body runs" 0 1 <<'E'
cat <<EOT
`true; source $MISSING`
EOT
E
sc_case "row 61 control: a real assignment after a quoted word on the same line is one" 1 0 <<'E'
echo 'x'; D="$(dirname "$0")"
source "$D/../lib/armor.sh"
E
# Row 63 — judge j2149c: 13 ways a text mask passed a quoted `source` as data
# while Bash ran it. With no mask each one denies.
sc_case "row 63 a01: a brace group piped into bash" 0 1 <<'E'
{ echo '
source $X/y.sh'
} | bash
E
sc_case "row 63 a02: a backtick span that echoes the text, then eval" 0 1 <<'E'
x=`:;echo '; source $X/y.sh'`
eval "$x"
E
sc_case "row 63 a03: printf -v into a variable, then eval" 0 1 <<'E'
cmd='; source $X/y.sh'
printf -v run '%s' "$cmd"
eval "$run"
E
sc_case "row 63 a04: echo into a file, then bash the file" 0 1 <<'E'
echo '; source $X/y.sh' > /tmp/zz.sh
bash /tmp/zz.sh
E
sc_case "row 63 a05: cat a heredoc into a file, then bash the file" 0 1 <<'E'
cat > /tmp/zz.sh <<'EOF'
source $X/y.sh
EOF
bash /tmp/zz.sh
E
sc_case "row 63 a06: echo into a bash process substitution on fd 3" 0 1 <<'E'
exec 3> >(bash)
echo '; source $X/y.sh' >&3
E
sc_case "row 63 a07: a colon default assigns the text, then eval" 0 1 <<'E'
: "${x:=; source $X/y.sh}"
eval "$x"
E
sc_case "row 63 a08: a function shadows echo with eval" 0 1 <<'E'
echo() { eval "$*"; }
echo '; source $X/y.sh'
E
sc_case "row 63 a09: PS4 with set -x runs a command substitution" 0 1 <<'E'
PS4='$(source $X/y.sh)'
set -x
:
E
sc_case "row 63 a10: an arithmetic test subscript runs a command substitution" 0 1 <<'E'
x='a[$(source $X/y.sh)]'
[[ "$x" -eq 0 ]]
E
sc_case "row 63 a11: the prompt-expansion operator runs a command substitution" 0 1 <<'E'
x='$(source $X/y.sh)'
echo "${x@P}"
E
sc_case "row 63 a12: an exported variable consumed by another script" 0 1 <<'E'
export CMD='; source $X/y.sh'
bash ./other.sh
E
sc_case "row 63 a13: cat a heredoc into a bash process substitution on fd 3" 0 1 <<'E'
exec 3> >(bash)
cat >&3 <<'EOF'
source $X/y.sh
EOF
E
sc_case "row 63 control: a bare source of the same unresolvable ref denies" 0 1 <<'E'
source $X/y.sh
E
sc_case "row 64: a self-dir cd that climbs out of the checkout denies (HIMMEL-4993)" 0 1 <<'E'
source "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lib/armor.sh"
E
sc_case "row 64: a cd - after the self cd denies" 0 1 <<'E'
source "$(cd "$(dirname "$0")" && cd - && pwd)/scripts/lib/armor.sh"
E
sc_case "row 64: a bare cd after the self cd denies" 0 1 <<'E'
source "$(cd "$(dirname "$0")" && cd && pwd)/scripts/lib/armor.sh"
E
sc_case "row 64: a second assignment on a line is recorded (CLAUDE_PROJECT_DIR outside)" 0 1 <<'E'
A=1; CLAUDE_PROJECT_DIR=/outside
source "${CLAUDE_PROJECT_DIR}/scripts/lib/armor.sh"
E
sc_case "row 64 control: a self-dir cd that stays inside the checkout resolves" 1 0 <<'E'
source "$(cd "$(dirname "$0")/../.." && pwd)/scripts/lib/armor.sh"
E
sc_case "row 64 control: a harmless first assignment does not hide a self-dir second one" 1 0 <<'E'
A=1; D="$(dirname "$0")"
source "$D/../lib/armor.sh"
E
}

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
