#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in scripts/test-context-fill.sh
# scripts/handover/test-headed-arm.sh - suite for headed-arm.sh (HIMMEL-2545).
#
# headed-arm.sh launches a headed successor session (a konsole window with a
# real TTY). The point of HIMMEL-2545 is that the launch line clears
# CLAUDE_CODE_CHILD_SESSION and CLAUDE_PID and forces
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 - without that, the launched session
# inherits a throwaway-child marker, claude saves no transcript for it, and
# scripts/context-fill.sh reads it blind. This suite asserts:
#   1-3. the generated konsole argv carries the env -u clears, the force flag,
#        the session name, the model (explicit and default), and the
#        handover doc inside the prompt.
#   4-5. the pgrep dedup guard genuinely skips a relaunch (4), and the happy
#        path genuinely DOES invoke konsole (5, the positive control that
#        makes 4 meaningful).
#   6. the usage/arg-shape contract: too few args -> exit 2, a non-numeric
#      deadline -> exit 2, konsole missing from PATH -> exit 3.
#   7. the signal-file path (not just the deadline) also triggers a launch.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm.sh
# itself - no .ps1 twin (the script under test has none either; the Windows
# station arms through arm-resume.sh's schtasks backend instead).
#
# Seams used (see headed-arm.sh's own header): KONSOLE_CMD / PGREP_CMD point
# at stub binaries this suite writes per case; HEADED_ARM_REPO points at a
# throwaway repo dir so `cd "$REPO"` never touches the real checkout.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/headed-arm.sh"
# r2-codex-4: this mktemp used to be unchecked. A failed mktemp leaves $tmp
# EMPTY, and every fixture path built on it below ("$tmp/..." -> "/...")
# then targets an unintended location instead of a throwaway one - abort
# loudly rather than let that happen.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/headed-arm-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# _fake_claude_proc <dir> <name> [pid] - r7-codex-1 test infra: headed-arm.sh's
# session_confirmed() walks each pgrep-matched pid's OWN /proc/<pid>/comm
# before believing a match (a launcher whose argv quotes the claude command
# is not a claude session), so a stub that wants to report "a session IS
# running" must hand back a pid whose comm genuinely says claude, not just
# a bare exit 0. HEADED_ARM_PROC then points headed-arm.sh at this fixture
# instead of the real /proc.
#
# r9-codex-3: session_confirmed() now ALSO requires a POSITIONAL, EXACT
# "-n <name>" pair in that pid's real argv (_argv_has_n_name reads
# /proc/<pid>/cmdline, NUL-separated) - a comm match alone is no longer
# enough. <name> is now REQUIRED (no default) so every caller states
# explicitly which session this fixture claims to be, and the cmdline is
# written with genuine NUL separators via `printf '...\0...'` - a
# space-joined string would make a case pass for the wrong reason (it
# would never exercise the NUL-splitting the real fix depends on).
_fake_claude_proc() {
  local dir="$1" name="$2" pid="${3:-9001}"
  mkdir -p "$dir/proc/$pid"
  echo claude > "$dir/proc/$pid/comm"
  printf 'claude\0--model\0claude-fable-5-1\0-n\0%s\0load doc and continue\0' "$name" > "$dir/proc/$pid/cmdline"
}

# mk_stub <dir> <pgrep-exit-code> [konsole-behavior] [name] - writes a
# konsole stub that records its full argv (one invocation per line,
# space-joined) to <dir>/record, and a pgrep stub whose exit status is
# fixed at <pgrep-exit-code>. <konsole-behavior> defaults to "alive" (the
# stub sleeps briefly after recording, so it is still running when
# headed-arm.sh's own codex-1 aliveness check looks at it a moment later -
# a REAL konsole window stays open, so this is the realistic default for
# every case that expects a launch to succeed); "dying" makes the stub
# exit immediately after recording, simulating a konsole that dies on
# arrival (no DISPLAY, a bad invocation) - the exact case codex-1 exists to
# catch.
#
# r8-codex-4: the "alive" stub also touches a SEPARATE <dir>/confirmable
# marker, distinct from <dir>/record - the pgrep stub below now reports a
# match on THAT, not on record's mere existence. Before this, "dying" ALSO
# left record populated (the write happens before its early exit), so once
# headed-arm.sh's post-launch poll started running regardless of pid
# liveness (see r8-codex-4 in headed-arm.sh itself), a dying konsole would
# have been wrongly CONFIRMED by this fixture even though no real session
# was ever running - record only proves konsole was invoked, never that a
# session is actually up.
#
# r9-codex-3: [name] is OPTIONAL here (unlike _fake_claude_proc's own
# required parameter) because plenty of callers below never reach a
# "match" branch at all (an error exit before dedup, or a pgrep stub that
# always reports no match) - the fake pid fixture would just be unused.
# Pass it only for a case that actually expects session_confirmed() to
# succeed; when omitted, no /proc fixture is created at all.
mk_stub() {
  local dir="$1" pgrep_rc="$2" behavior="${3:-alive}" name="${4:-}"
  mkdir -p "$dir"
  [ -n "$name" ] && _fake_claude_proc "$dir" "$name"
  if [ "$behavior" = dying ]; then
    cat > "$dir/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
exit 1
KONSOLE_EOF
  else
    cat > "$dir/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
: > "$(dirname "$0")/confirmable"
sleep 5
KONSOLE_EOF
  fi
  chmod 755 "$dir/konsole"
  # r3-codex-2: headed-arm.sh now polls pgrep AFTER a successful launch too
  # (to confirm the session is visible before releasing the lock). A pgrep
  # stub whose exit code never reflects reality would make every happy-path
  # launch stall for the full post-launch budget - so once the konsole stub
  # has actually recorded a launch AND touched confirmable (never for the
  # "dying" behavior - see the note above), this stub reports a match
  # immediately; before that, it still respects <pgrep-exit-code> for the
  # PRE-launch dedup decisions the case is actually testing. r7-codex-1: a
  # "match" now also has to survive headed-arm.sh's own comm check, so both
  # branches print the fake claude pid _fake_claude_proc set up above, not
  # just a bare exit 0.
  cat > "$dir/pgrep" <<PGREP_EOF
#!/usr/bin/env bash
if [ -e "$dir/confirmable" ]; then echo 9001; exit 0; fi
if [ "$pgrep_rc" -eq 0 ]; then echo 9001; exit 0; fi
exit $pgrep_rc
PGREP_EOF
  chmod 755 "$dir/pgrep"
}

# mk_matcher_pgrep <dir> <candidate-cmdline> <name> - a pgrep stub that does
# NOT just return a fixed code: it tests the -f pattern it actually
# receives against one fixed fake process line, via a REAL `grep -E`, and
# exits with grep's own verdict. This lets a case assert exactly what
# pattern reaches pgrep (via ere_escape's effect) without needing a
# genuinely running process - the whole point of the codex-3 cases below.
#
# r9-codex-3: <name> is the arm's OWN -n value, embedded in pid 9001's real
# /proc cmdline fixture via _fake_claude_proc - session_confirmed() now
# walks that positionally regardless of which pgrep branch produced the
# candidate, so a genuine dedup (case 10b, where <candidate> already equals
# the arm's own literal name) needs the SAME pid's cmdline to positionally
# carry "-n <name>" too, not just satisfy the flattened `grep -Eq` test.
mk_matcher_pgrep() {
  local dir="$1" candidate="$2" name="$3"
  mkdir -p "$dir"
  _fake_claude_proc "$dir" "$name"
  printf '%s\n' "$candidate" > "$dir/candidate"
  # r3-codex-2: same record-aware short-circuit as mk_stub's pgrep - once
  # THIS case's own konsole stub has recorded a launch, the post-launch
  # visibility poll resolves instantly instead of running out the full
  # budget against a candidate line that was never meant to match itself.
  # r7-codex-1: either branch that decides "match" now also has to print a
  # pid whose comm survives headed-arm.sh's own comm check.
  cat > "$dir/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
if [ -s "$(dirname "$0")/record" ]; then echo 9001; exit 0; fi
pattern="$2"
printf '%s\n' "$pattern" >> "$(dirname "$0")/pattern-seen"
candidate="$(cat "$(dirname "$0")/candidate" 2>/dev/null)"
if grep -Eq -- "$pattern" <<< "$candidate"; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
  chmod 755 "$dir/pgrep"
}

# wait_record <dir> - the launch is backgrounded (&) inside headed-arm.sh, so
# the stub may not have written yet the instant the script under test
# returns. Bounded poll (at most 2s), never an open-ended wait.
wait_record() {
  local dir="$1" n=0
  while [ "$n" -lt 40 ]; do
    [ -s "$dir/record" ] && return 0
    sleep 0.05
    n=$((n+1))
  done
  return 1
}

# settle - a bounded wait (0.5s) used where we must confirm something never
# happens (e.g. konsole never gets invoked): unlike wait_record, which
# returns the instant it sees the file, this always waits out the full
# window so a late-arriving background write is not missed.
settle() {
  local n=0
  while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
}

# run_headed_arm <stubdir> <repo> <name> <doc> <signal> <deadline> [model] -
# invokes the script under test with the seams wired to <stubdir>. The log
# lands at <stubdir>/log.
# HEADED_ARM_LOCK_DIR defaults to a subdir OF the stub dir, so every case's
# claim locks are isolated from every other case's by construction (no case
# has to clean up after another, and the real /tmp lock root is never
# touched). A case that wants to test lock contention pre-seeds
# "$stubdir/locks" before calling run_headed_arm.
run_headed_arm() {
  local stubdir="$1" repo="$2" name="$3" doc="$4" signal="$5" deadline="$6" model="${7:-}"
  local log="$stubdir/log"
  if [ -n "$model" ]; then
    KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" HEADED_ARM_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
      bash "$SCRIPT" "$name" "$doc" "$signal" "$deadline" "$log" "$model"
  else
    KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" HEADED_ARM_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
      bash "$SCRIPT" "$name" "$doc" "$signal" "$deadline" "$log"
  fi
}

REPO="$tmp/repo"; mkdir -p "$REPO"
PAST=$(( $(date +%s) - 100 ))
FUTURE=$(( $(date +%s) + 100000 ))

# --- 1-3, 5. happy path (default model): the env -u clears, the force flag,
# the session name, the default model, and the doc inside the prompt. This
# is also the POSITIVE CONTROL for case 4 - it proves konsole IS invoked when
# nothing dedups it, so case 4's "konsole not invoked" means something.
d1="$tmp/c1"; mk_stub "$d1" 1 alive "HIMMEL-9999-leg"
rc=0
run_headed_arm "$d1" "$REPO" "HIMMEL-9999-leg" "some/handover-doc.md" "$d1/signal-never" "$PAST" >/dev/null 2>&1 || rc=$?
wait_record "$d1" || true
rec1="$(cat "$d1/record" 2>/dev/null || true)"
check "happy path: exit 0" "$rc" "0"
if [ -s "$d1/record" ]; then echo "ok - happy path: konsole IS invoked (positive control)"
else echo "FAIL - happy path: konsole IS invoked (positive control)"; fails=$((fails+1)); fi
contains "happy path: clears CLAUDE_CODE_CHILD_SESSION" "$rec1" "-u CLAUDE_CODE_CHILD_SESSION"
contains "happy path: clears CLAUDE_PID"                "$rec1" "-u CLAUDE_PID"
contains "happy path: clears CLAUDE_CODE_SESSION_ID"    "$rec1" "-u CLAUDE_CODE_SESSION_ID"
contains "happy path: passes --separate (own process, not a hand-off)" "$rec1" "--separate"
contains "happy path: forces session persistence"       "$rec1" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"
contains "happy path: carries the session name via -n"  "$rec1" "-n HIMMEL-9999-leg"
contains "happy path: carries the default model"        "$rec1" "claude-fable-5-1"
contains "happy path: doc reaches the prompt"            "$rec1" "load some/handover-doc.md and continue"

# --- 2. explicit model overrides the default -----------------------------
d2="$tmp/c2"; mk_stub "$d2" 1 alive "HIMMEL-leg2"
run_headed_arm "$d2" "$REPO" "HIMMEL-leg2" "doc2.md" "$d2/signal-never" "$PAST" "claude-opus-5" >/dev/null 2>&1
wait_record "$d2" || true
rec2="$(cat "$d2/record" 2>/dev/null || true)"
contains     "explicit model: carries the given model" "$rec2" "claude-opus-5"
not_contains "explicit model: does not fall back to the default" "$rec2" "claude-fable-5-1"

# --- 4. dedup refusal: pgrep hits -> konsole is NEVER invoked, exit 0 ------
d4="$tmp/c4"; mk_stub "$d4" 0 alive "HIMMEL-dedup"
rc4=0
run_headed_arm "$d4" "$REPO" "HIMMEL-dedup" "doc4.md" "$d4/signal-never" "$PAST" >/dev/null 2>&1 || rc4=$?
check "dedup: exit 0" "$rc4" "0"
settle  # bounded wait so a late background launch is not missed (see mk_stub note above)
if [ -s "$d4/record" ]; then echo "FAIL - dedup: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - dedup: konsole not invoked"; fi
log4="$(cat "$d4/log" 2>/dev/null || true)"
contains "dedup: log names it already running" "$log4" "already running"

# --- 6. usage / arg-shape contract -----------------------------------------
outu="$(bash "$SCRIPT" only one two three 2>&1)"; rcu=$?
check    "too few args: exit 2"     "$rcu" "2"
contains "too few args: usage text" "$outu" "usage: headed-arm.sh"

d6="$tmp/c6"; mk_stub "$d6" 1
rcd=0
KONSOLE_CMD="$d6/konsole" PGREP_CMD="$d6/pgrep" HEADED_ARM_REPO="$REPO" \
  bash "$SCRIPT" "HIMMEL-x" "doc.md" "$d6/signal-never" "not-a-number" "$d6/log" >/dev/null 2>&1 || rcd=$?
check "non-numeric deadline: exit 2" "$rcd" "2"

rck=0
PGREP_CMD="$d6/pgrep" KONSOLE_CMD="$tmp/does-not-exist/konsole" HEADED_ARM_REPO="$REPO" \
  bash "$SCRIPT" "HIMMEL-x" "doc.md" "$d6/signal-never" "$PAST" "$d6/log2" >/dev/null 2>&1 || rck=$?
check "missing konsole on PATH: exit 3" "$rck" "3"

# --- 7. the signal file ALSO triggers a launch (not just the deadline) ----
d7="$tmp/c7"; mk_stub "$d7" 1 alive "HIMMEL-sig"
sig7="$d7/signal"; : > "$sig7"
run_headed_arm "$d7" "$REPO" "HIMMEL-sig" "doc7.md" "$sig7" "$FUTURE" >/dev/null 2>&1
wait_record "$d7" || true
if [ -s "$d7/record" ]; then echo "ok - signal file: triggers a launch"
else echo "FAIL - signal file: triggers a launch"; fails=$((fails+1)); fi
log7="$(cat "$d7/log" 2>/dev/null || true)"
contains "signal file: log records the signal seen" "$log7" "signal seen"

# --- 8 (codex-1). a konsole that dies on arrival is a LOUD failure, never a
# false "launched" success -------------------------------------------------
d8="$tmp/c8"; mk_stub "$d8" 1 dying
rc8=0
run_headed_arm "$d8" "$REPO" "HIMMEL-dying" "doc8.md" "$d8/signal-never" "$PAST" >/dev/null 2>&1 || rc8=$?
if [ "$rc8" -ne 0 ]; then echo "ok - dying konsole: exit non-zero, never 0"
else echo "FAIL - dying konsole: exit non-zero, never 0 (got rc=$rc8)"; fails=$((fails+1)); fi
log8="$(cat "$d8/log" 2>/dev/null || true)"
contains     "dying konsole: log says FAILED"           "$log8" "FAILED"
not_contains "dying konsole: log NEVER claims launched" "$log8" "konsole launched"

# --- 9 (codex-2). a held lock blocks a second arm from launching ----------
# (r2-codex-3 changed WHAT the eventual log message says: this lock never
# clears for the whole retry budget, so the second arm exhausts its ~2s of
# retries and gives up - "still claimed after waiting", not the old
# immediate "already claimed". r3-codex-1 changed the EXIT CODE: exhausting
# the retry without ever confirming a real session is UNRESOLVED, not a
# dedup - exit 6, not the old 0. This lock never clears at all, so this
# case now pins that outcome instead of the round-2 "deferred, harmless"
# framing.)
d9="$tmp/c9"; mkdir -p "$d9/locks/HIMMEL-locked.lock"
date +%s > "$d9/locks/HIMMEL-locked.lock/acquired"
mk_stub "$d9" 1
rc9=0
KONSOLE_CMD="$d9/konsole" PGREP_CMD="$d9/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d9/locks" \
  bash "$SCRIPT" "HIMMEL-locked" "doc9.md" "$d9/signal-never" "$PAST" "$d9/log" >/dev/null 2>&1 || rc9=$?
check "held lock: exit 6 (unresolved, not a confirmed dedup)" "$rc9" "6"
settle
if [ -s "$d9/record" ]; then echo "FAIL - held lock: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - held lock: konsole not invoked"; fi
log9="$(cat "$d9/log" 2>/dev/null || true)"
contains "held lock: log names the claim" "$log9" "still claimed after waiting"

# --- 10 (codex-3). NAME's regex metacharacters are ERE-escaped, so the
# pgrep match is on the LITERAL name in both directions -------------------
# (a) must NOT false-match: an unescaped '.' in "HIMMEL-2545.leg" would match
# ANY character, so a real session named "HIMMEL-2545Xleg" (a genuinely
# different name) would wrongly look like a dedup hit and block the launch.
d10a="$tmp/c10a"
mk_stub "$d10a" 0  # konsole stub + a placeholder pgrep; overwritten below by the real matcher
mk_matcher_pgrep "$d10a" "claude --model x -n HIMMEL-2545Xleg load foo and continue" "HIMMEL-2545.leg"
rc10a=0
run_headed_arm "$d10a" "$REPO" "HIMMEL-2545.leg" "doc10a.md" "$d10a/signal-never" "$PAST" >/dev/null 2>&1 || rc10a=$?
check "regex metachar: exit 0 (a launch, not a dedup)" "$rc10a" "0"
wait_record "$d10a" || true
if [ -s "$d10a/record" ]; then echo "ok - regex metachar: literal '.' does NOT false-match a different session"
else echo "FAIL - regex metachar: literal '.' does NOT false-match a different session"; fails=$((fails+1)); fi
# (b) must STILL match itself: the exact same literal name, dot and all.
d10b="$tmp/c10b"
mk_stub "$d10b" 0
mk_matcher_pgrep "$d10b" "claude --model x -n HIMMEL-2545.leg load foo and continue" "HIMMEL-2545.leg"
rc10b=0
run_headed_arm "$d10b" "$REPO" "HIMMEL-2545.leg" "doc10b.md" "$d10b/signal-never" "$PAST" >/dev/null 2>&1 || rc10b=$?
check "regex metachar: still dedups its own literal name" "$rc10b" "0"
settle
if [ -s "$d10b/record" ]; then echo "FAIL - regex metachar: konsole must NOT be invoked (self-match)"; fails=$((fails+1))
else echo "ok - regex metachar: konsole not invoked (self-match)"; fi

# --- 11 (codex-4). a missing pgrep refuses closed, never silently disables
# dedup ---------------------------------------------------------------------
d11="$tmp/c11"; mk_stub "$d11" 1
rc11=0
KONSOLE_CMD="$d11/konsole" PGREP_CMD="$tmp/does-not-exist/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d11/locks" \
  bash "$SCRIPT" "HIMMEL-nopgrep" "doc11.md" "$d11/signal-never" "$PAST" "$d11/log" >/dev/null 2>&1 || rc11=$?
check "missing pgrep: exit 4" "$rc11" "4"
settle
if [ -s "$d11/record" ]; then echo "FAIL - missing pgrep: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - missing pgrep: konsole not invoked"; fi

# --- 12 (r2-codex-2). an unwritable/unavailable lock root is a LOUD exit 5,
# never a silent "already claimed" dedup -----------------------------------
# A regular FILE where the lock root's parent path component needs to be a
# directory makes `mkdir -p` fail for a genuine filesystem reason, not
# contention.
d12="$tmp/c12"; mk_stub "$d12" 1
: > "$d12/blocker"  # a plain file, not a directory
rc12=0
KONSOLE_CMD="$d12/konsole" PGREP_CMD="$d12/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d12/blocker/locks" \
  bash "$SCRIPT" "HIMMEL-nolockroot" "doc12.md" "$d12/signal-never" "$PAST" "$d12/log" >/dev/null 2>&1 || rc12=$?
check "unwritable lock root: exit 5, distinct from a dedup" "$rc12" "5"
settle
if [ -s "$d12/record" ]; then echo "FAIL - unwritable lock root: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - unwritable lock root: konsole not invoked"; fi

# --- 13 (r2-codex-3). the retry actually recovers a failed holder's launch -
# A lock is pre-seeded FRESH (held, not stale) and a background releaser
# clears it well inside the ~2s retry budget while NO session is running
# (the pgrep stub always says "no match") - the old immediate-exit-0
# behavior would have wrongly skipped this launch; the retry must now take
# over and actually launch.
d13="$tmp/c13"; mk_stub "$d13" 1 alive "HIMMEL-recover"
mkdir -p "$d13/locks/HIMMEL-recover.lock"
date +%s > "$d13/locks/HIMMEL-recover.lock/acquired"
( sleep 0.3; rm -rf "$d13/locks/HIMMEL-recover.lock" ) &
rc13=0
KONSOLE_CMD="$d13/konsole" PGREP_CMD="$d13/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d13/locks" HEADED_ARM_PROC="$d13/proc" \
  bash "$SCRIPT" "HIMMEL-recover" "doc13.md" "$d13/signal-never" "$PAST" "$d13/log" >/dev/null 2>&1 || rc13=$?
check "retry recovers a failed holder: exit 0" "$rc13" "0"
wait_record "$d13" || true
if [ -s "$d13/record" ]; then echo "ok - retry recovers a failed holder: konsole IS invoked"
else echo "FAIL - retry recovers a failed holder: konsole IS invoked"; fails=$((fails+1)); fi
log13="$(cat "$d13/log" 2>/dev/null || true)"
contains "retry recovers a failed holder: log says launched" "$log13" "konsole launched"

# --- 14 (r2-codex-3). the retry correctly backs off when the lock clears
# because the HOLDER SUCCEEDED (a real session is now running) -------------
# Same shape as case 13, but this time the "releaser" also makes pgrep
# report a match once it fires, simulating the holder's own successful
# launch. A genuine dedup, not a recovery - konsole must stay uninvoked.
d14="$tmp/c14"; mk_stub "$d14" 1  # konsole stub unused either way; the real assertion is on pgrep's late flip
mkdir -p "$d14/locks/HIMMEL-donedeal.lock"
date +%s > "$d14/locks/HIMMEL-donedeal.lock/acquired"
_fake_claude_proc "$d14" "HIMMEL-donedeal"
cat > "$d14/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
if [ -e "$(dirname "$0")/session-now-running" ]; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
chmod 755 "$d14/pgrep"
( sleep 0.3; rm -rf "$d14/locks/HIMMEL-donedeal.lock"; : > "$d14/session-now-running" ) &
rc14=0
KONSOLE_CMD="$d14/konsole" PGREP_CMD="$d14/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d14/locks" HEADED_ARM_PROC="$d14/proc" \
  bash "$SCRIPT" "HIMMEL-donedeal" "doc14.md" "$d14/signal-never" "$PAST" "$d14/log" >/dev/null 2>&1 || rc14=$?
check "retry backs off on a genuine dedup: exit 0" "$rc14" "0"
settle
if [ -s "$d14/record" ]; then echo "FAIL - retry backs off on a genuine dedup: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - retry backs off on a genuine dedup: konsole not invoked"; fi
log14="$(cat "$d14/log" 2>/dev/null || true)"
contains "retry backs off on a genuine dedup: log says already running" "$log14" "already running"

# --- 15 (r2-codex-4). the suite's OWN mktemp failure must abort loudly,
# never silently continue with an empty $tmp --------------------------------
# SAFETY: this extracts and runs ONLY this file's own lines up to and
# including the `tmp=...mktemp...` statement (never the whole suite) - the
# unfixed shape leaves $tmp EMPTY, and every fixture path built on it below
# ("$tmp/repo", "$tmp/c1", ...) collapses to a filesystem-ROOT path
# ("/repo", "/c1", ...). Actually letting the rest of the suite run under
# that condition would mean the pre-fix mutant tries to mkdir/write at "/" -
# genuinely destructive, not just a test artifact. Stopping right after the
# mktemp line (a snippet echoes a marker on the next line instead of
# continuing into the real fixtures) proves the same abort-or-not behaviour
# with zero risk.
d15="$tmp/c15"; mkdir -p "$d15"
FAKEMKTEMP="$d15/fakemktemp"; mkdir -p "$FAKEMKTEMP"
for _t in bash cat chmod date dirname env grep kill mkdir mv printf rm rmdir sed sleep true; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$FAKEMKTEMP/$_t" 2>/dev/null
done
cat > "$FAKEMKTEMP/mktemp" <<'MKTEMP_EOF'
#!/usr/bin/env bash
exit 1
MKTEMP_EOF
chmod 755 "$FAKEMKTEMP/mktemp"
# Both single-quoted strings below are LOAD-BEARING: the grep pattern needs
# a literal $ (searching for the source text, not expanding a variable),
# and the echoed line is being WRITTEN into a script file to be evaluated
# later by a DIFFERENT bash invocation, not expanded now.
# shellcheck disable=SC2016
mktemp_line_no="$(grep -n 'tmp="\$(mktemp -d' "$HERE/test-headed-arm.sh" | head -1 | cut -d: -f1)"
snippet_file="$d15/snippet.sh"
{
  sed -n "1,${mktemp_line_no}p" "$HERE/test-headed-arm.sh"
  # shellcheck disable=SC2016
  echo 'echo "REACHED-AFTER-MKTEMP: tmp=[$tmp]"'
} > "$snippet_file"
out15="$(PATH="$FAKEMKTEMP" bash "$snippet_file" 2>&1)"; rc15=$?
if [ "$rc15" -ne 0 ]; then echo "ok - suite's own mktemp failure: aborts non-zero"
else echo "FAIL - suite's own mktemp failure: aborts non-zero (got rc=0)"; fails=$((fails+1)); fi
not_contains "suite's own mktemp failure: never reaches past the check" "$out15" "REACHED-AFTER-MKTEMP"

# --- 16 (r2-codex-1). the stale-lock steal is genuinely ATOMIC: two real
# contenders forced to the exact same race window never BOTH believe they
# hold the lock -----------------------------------------------------------
# DETERMINISTIC INTERLEAVING, not a timing guess: HEADED_ARM_STALE_HOOK (a
# no-op by default - see headed-arm.sh's own header) is pointed at a barrier
# script per contender. Each contender signals "ready" the INSTANT it has
# independently classified the SAME pre-seeded lock stale (proving the
# precondition genuinely holds for both, not simulated) and then blocks;
# this driver waits for BOTH ready signals before releasing both "go" files
# back to back, forcing the two real headed-arm.sh processes into the exact
# race window the panel finding describes, every run - not "eventually,
# probably". Both konsole/pgrep stubs share ONE marker file so the ordinary
# pgrep dedup layers behave like a REAL pgrep would (seeing whichever
# contender's session actually launches) - without this, the round-2
# retry-loop fix alone could produce a "second, later, legitimate launch"
# that looks like the atomicity bug but isn't.
race_run() { # race_run <root> - one full race; sets race_a, race_b to 0/1
  local root="$1"
  mkdir -p "$root/dA" "$root/dB" "$root/repo" "$root/barrier" "$root/locks/HIMMEL-race.lock" "$root/shared"
  echo $(( $(date +%s) - 999 )) > "$root/locks/HIMMEL-race.lock/acquired"
  local d
  for d in dA dB; do
    cat > "$root/$d/konsole" <<KONSOLE_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$(dirname "\$0")/record"
: > "$root/shared/session-marker"
sleep 2
KONSOLE_EOF
    chmod 755 "$root/$d/konsole"
    _fake_claude_proc "$root/$d" "HIMMEL-race"
    cat > "$root/$d/pgrep" <<PGREP_EOF
#!/usr/bin/env bash
if [ -e "$root/shared/session-marker" ]; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
    chmod 755 "$root/$d/pgrep"
  done
  local id
  for id in A B; do
    cat > "$root/barrier/hook$id" <<HOOK_EOF
#!/usr/bin/env bash
: > "$root/barrier/ready-$id"
n=0
while [ ! -e "$root/barrier/go-$id" ]; do sleep 0.01; n=\$((n+1)); [ "\$n" -lt 500 ] || break; done
HOOK_EOF
    chmod 755 "$root/barrier/hook$id"
  done
  local past; past=$(( $(date +%s) - 100 ))
  HEADED_ARM_LOCK_DIR="$root/locks" HEADED_ARM_STALE_HOOK="$root/barrier/hookA" \
    KONSOLE_CMD="$root/dA/konsole" PGREP_CMD="$root/dA/pgrep" HEADED_ARM_REPO="$root/repo" HEADED_ARM_PROC="$root/dA/proc" \
    bash "$SCRIPT" "HIMMEL-race" "docA.md" "$root/dA/signal-never" "$past" "$root/dA/log" >/dev/null 2>&1 &
  local pida=$!
  HEADED_ARM_LOCK_DIR="$root/locks" HEADED_ARM_STALE_HOOK="$root/barrier/hookB" \
    KONSOLE_CMD="$root/dB/konsole" PGREP_CMD="$root/dB/pgrep" HEADED_ARM_REPO="$root/repo" HEADED_ARM_PROC="$root/dB/proc" \
    bash "$SCRIPT" "HIMMEL-race" "docB.md" "$root/dB/signal-never" "$past" "$root/dB/log" >/dev/null 2>&1 &
  local pidb=$!
  local n=0
  while [ ! -e "$root/barrier/ready-A" ] || [ ! -e "$root/barrier/ready-B" ]; do
    sleep 0.02; n=$((n+1)); [ "$n" -lt 500 ] || break
  done
  # r12-codex-3: record whether each contender ACTUALLY reached the
  # barrier, rather than assuming the wait loop above succeeded just
  # because it returned - a timeout break (n hit its cap) exits this same
  # loop with one or both ready-files still missing. If only one arm ever
  # got there, this iteration was never a real race in the first place,
  # regardless of what race_a/race_b/rc_a/rc_b end up reporting - the
  # caller must discard it rather than count it toward any outcome.
  race_a_ready=0; race_b_ready=0
  [ -e "$root/barrier/ready-A" ] && race_a_ready=1
  [ -e "$root/barrier/ready-B" ] && race_b_ready=1
  : > "$root/barrier/go-A"
  : > "$root/barrier/go-B"
  wait "$pida" 2>/dev/null; rc_a=$?
  wait "$pidb" 2>/dev/null; rc_b=$?
  race_a=0; race_b=0
  [ -s "$root/dA/record" ] && race_a=1
  [ -s "$root/dB/record" ] && race_b=1
}
# r3-codex-3: the original assertion only checked race_a==1 && race_b==1,
# so it read as PASS whenever ZERO contenders launched too - a fixture
# break, or a regression that suppresses both launches (e.g. a lock that
# can never be claimed), would look identical to "the atomic steal worked".
# This repo's rule is to verify the ARTIFACT, not the absence of a
# complaint (see MEMORY.md).
#
# Round-9 follow-up: EXACTLY ONE winner every iteration was too strong an
# invariant - the design never promised that. Two contenders race for the
# SAME pre-seeded stale lock; either can genuinely LOSE the atomic mv steal,
# retry for its bounded budget (~2s: CLAIM_RETRY_ITERS * CLAIM_RETRY_SLEEP),
# and exit 6 UNRESOLVED. If BOTH lose (the winner's own launch or the
# loser's dedup-catch is slow enough that the loser's retry budget expires
# first), zero launches is CORRECT behaviour, loudly reported by both arms -
# not a stuck lock, not a broken fixture. Observed live once (0/5 iterations
# in a round-8 run) and, on a live run of a 40-iteration isolated probe plus
# 465 further iterations total (see HIMMEL-2545 round-9 evidence log),
# never reproduced again - genuinely rare, not routine. Traced in the code
# rather than merely assumed: every "exit 0" in headed-arm.sh is gated
# behind session_confirmed() returning confirmed, and in THIS fixture pgrep
# only ever returns the candidate pid once $root/shared/session-marker
# exists - a file ONLY the konsole stub itself creates, i.e. only after a
# REAL launch. So under a genuine NEITHER (both records empty), neither
# contender's session_confirmed() can ever return 0 at any of its four call
# sites; the only reachable exits are the loud non-zero ones (1/5/6/7/8/9).
# r12-codex-3: round 9 stopped one step short. Removing "exactly one
# winner" fixed the false-flake, but left NOTHING in its place proving a
# successful steal ever happens - a broken fixture, or a regression that
# prevents stale-lock reclamation entirely, would satisfy "never both,
# never silent" on EVERY iteration being a loud double-loss, and pass
# green having tested nothing. That is the same vacuity r3-codex-3 flagged
# originally, reintroduced from the other direction. So the invariant
# actually worth protecting is FOUR things, not two:
#   1. BOTH launching is ALWAYS a hard failure (the duplicate window).
#   2. NEITHER launching is acceptable ONLY if BOTH arms said so loudly -
#      every non-launching contender's own exit code must be a distinct
#      non-zero, never 0. A zero-launch iteration where either arm exited 0
#      is the exact vacuous-green bug r3-codex-3 exists to catch, and must
#      still FAIL, naming which arm claimed success without launching.
#   3. NEITHER launching WITH both arms loud is acceptable for an
#      INDIVIDUAL iteration - a genuine double-loss is legitimate under
#      contention, not a stuck lock.
#   4. NEW - across the WHOLE set of iterations, at least ONE must be a
#      real exactly-one-winner reclamation. Zero successful reclamations
#      across every iteration means the harness never exercised the thing
#      it exists to test; that is a FAIL saying the run proved nothing,
#      never a pass reading it as "the lock worked".
# Also required per-iteration: BOTH contenders must have actually reached
# the HEADED_ARM_STALE_HOOK barrier (see race_a_ready/race_b_ready in
# race_run above) - if only one arm ever got there, that iteration was
# never a real race and its outcome is discarded rather than counted
# toward any of the four properties above.
#
# WHY 5 ITERATIONS REMAINS SAFE for property 4 (evidence, not a guess):
# property 4 is itself a probabilistic claim - if EVERY iteration happens
# to double-lose, it fails even though nothing is actually broken. Round
# 9's evidence (465 further iterations, isolated and inside the full
# suite, chasing the one historical 1/5 observation) put the double-loss
# rate at roughly <=20% even under the WORST contention actually observed,
# and far below 1% in isolation. At p<=0.20, the chance every one of 5
# iterations double-loses is at most 0.2^5 = 0.00032% - the same order of
# magnitude of "does not happen" this suite already accepts elsewhere. If
# contention ever became common enough that double-losses approached, say,
# p=0.5, this would rise to 1/32 (~3%) at 5 iterations - genuinely flaky -
# and the fix at THAT point is to raise race_iters (each added iteration
# divides the failure probability by another 1/p), never to weaken
# property 4 back toward round 9's vacuous shape. Kept at 5 here since the
# evidence does not currently support paying for more.
race_both=0
race_neither_silent=0
race_neither_loud=0
race_one_winner=0
race_barrier_missed=0
race_iters=5
race_i=0
while [ "$race_i" -lt "$race_iters" ]; do
  race_i=$((race_i+1))
  rroot="$tmp/race$race_i"
  race_run "$rroot"
  if [ "$race_a_ready" -ne 1 ] || [ "$race_b_ready" -ne 1 ]; then
    race_barrier_missed=$((race_barrier_missed+1))
    echo "  race iteration $race_i: BARRIER NOT REACHED by both contenders (ready_a=$race_a_ready ready_b=$race_b_ready) - not a real race, result discarded"
    continue
  fi
  race_total=$((race_a + race_b))
  if [ "$race_total" -eq 2 ]; then
    race_both=$((race_both+1))
    echo "  race iteration $race_i: BOTH contenders launched (would be a duplicate window) - rc_a=$rc_a rc_b=$rc_b"
  elif [ "$race_total" -eq 0 ]; then
    if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ]; then
      race_neither_silent=$((race_neither_silent+1))
      echo "  race iteration $race_i: NEITHER contender launched, but BOTH A and B exited 0 without launching - vacuous success (rc_a=$rc_a rc_b=$rc_b)"
    elif [ "$rc_a" -eq 0 ]; then
      race_neither_silent=$((race_neither_silent+1))
      echo "  race iteration $race_i: NEITHER contender launched, but A exited 0 without launching - vacuous success (rc_a=$rc_a rc_b=$rc_b)"
    elif [ "$rc_b" -eq 0 ]; then
      race_neither_silent=$((race_neither_silent+1))
      echo "  race iteration $race_i: NEITHER contender launched, but B exited 0 without launching - vacuous success (rc_a=$rc_a rc_b=$rc_b)"
    else
      race_neither_loud=$((race_neither_loud+1))
      echo "  race iteration $race_i: NEITHER contender launched, but both said so loudly - a legitimate double-loss, not a stuck lock (rc_a=$rc_a rc_b=$rc_b)"
    fi
  else
    race_one_winner=$((race_one_winner+1))
  fi
done
if [ "$race_both" -eq 0 ] && [ "$race_neither_silent" -eq 0 ] && [ "$race_barrier_missed" -eq 0 ] && [ "$race_one_winner" -ge 1 ]; then
  echo "ok - atomic steal: $race_iters/$race_iters race iterations, never both launched, every zero-launch iteration ($race_neither_loud) was reported loudly by both arms, and $race_one_winner genuine one-winner reclamation(s) actually happened"
elif [ "$race_both" -eq 0 ] && [ "$race_neither_silent" -eq 0 ] && [ "$race_barrier_missed" -eq 0 ] && [ "$race_one_winner" -eq 0 ]; then
  echo "FAIL - atomic steal: every iteration was a double-loss - this run PROVED NOTHING about whether the lock can actually be reclaimed, not that it works"
  fails=$((fails+1))
else
  echo "FAIL - atomic steal: $race_both/$race_iters had BOTH launch, $race_neither_silent/$race_iters had a SILENT (exit 0) zero-launch, $race_barrier_missed/$race_iters never reached the race barrier (not a real race), $race_one_winner genuine winner(s)"
  fails=$((fails+1))
fi

# --- 17 (r3-codex-1). exhausting the retry without ever confirming a
# running session is UNRESOLVED, not a dedup - a distinct non-zero exit,
# never the same code as a genuine dedup's exit 0 -----------------------
d17="$tmp/c17"; mkdir -p "$d17/locks/HIMMEL-unresolved.lock"
date +%s > "$d17/locks/HIMMEL-unresolved.lock/acquired"   # fresh - never clears
mk_stub "$d17" 1
rc17=0
KONSOLE_CMD="$d17/konsole" PGREP_CMD="$d17/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d17/locks" \
  bash "$SCRIPT" "HIMMEL-unresolved" "doc17.md" "$d17/signal-never" "$PAST" "$d17/log" >/dev/null 2>&1 || rc17=$?
check "unresolved arm: exit 6, distinct from dedup's exit 0" "$rc17" "6"
log17="$(cat "$d17/log" 2>/dev/null || true)"
contains "unresolved arm: log says UNRESOLVED" "$log17" "UNRESOLVED"

# --- 18 (r3-codex-2). the lock is held until the session is CONFIRMED
# visible to pgrep, not released the instant konsole survives its settle -
# deterministic slow-startup fixture: pgrep reports "not yet visible" for
# the first several post-launch calls, then reports a match ---------------
d18="$tmp/c18"; mkdir -p "$d18"
LOCK18="$d18/locks/HIMMEL-slow.lock"
cat > "$d18/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
sleep 5
KONSOLE_EOF
chmod 755 "$d18/konsole"
_fake_claude_proc "$d18" "HIMMEL-slow"
cat > "$d18/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
[ -s "$dir/record" ] || exit 1
count_file="$dir/post-launch-calls"
n=0
[ -f "$count_file" ] && n="$(cat "$count_file")"
n=$((n+1))
echo "$n" > "$count_file"
if [ "$n" -ge 20 ]; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
chmod 755 "$d18/pgrep"
KONSOLE_CMD="$d18/konsole" PGREP_CMD="$d18/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d18/locks" HEADED_ARM_PROC="$d18/proc" \
  bash "$SCRIPT" "HIMMEL-slow" "doc18.md" "$d18/signal-never" "$PAST" "$d18/log" >/dev/null 2>&1 &
pid18=$!
sleep 0.5
if [ -d "$LOCK18" ]; then
  echo "ok - slow startup: lock still held at 0.5s (not released before confirmation)"
else
  echo "FAIL - slow startup: lock already released at 0.5s, before the session could be confirmed"
  fails=$((fails+1))
fi
wait "$pid18" 2>/dev/null; rc18=$?
check "slow startup: exit 0 once confirmed" "$rc18" "0"
log18="$(cat "$d18/log" 2>/dev/null || true)"
not_contains "slow startup: no UNCONFIRMED (it confirmed within budget)" "$log18" "UNCONFIRMED"

# --- 19 (r4-codex-1). the budget expiring must still release the lock
# (never hold forever) but is now a DISTINCT non-zero exit (7), never the
# same code as a confirmed launch - r3-codex-2's "still exit 0, just log a
# WARNING" was itself the bug r4-codex-1 fixed: an outcome we could not
# CONFIRM must not share an exit code with one we did -----------------------
d19="$tmp/c19"; mk_stub "$d19" 1
# mk_stub's pgrep is record-aware (case 18's whole point) - it would
# confirm the session on the FIRST post-launch check, defeating THIS
# case's point (pgrep must NEVER confirm it, e.g. a genuine procps/cmdline
# mismatch). Override with a plain always-miss pgrep instead.
cat > "$d19/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
exit 1
PGREP_EOF
chmod 755 "$d19/pgrep"
LOCK19="$d19/locks/HIMMEL-neverseen.lock"
rc19=0
KONSOLE_CMD="$d19/konsole" PGREP_CMD="$d19/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d19/locks" \
  bash "$SCRIPT" "HIMMEL-neverseen" "doc19.md" "$d19/signal-never" "$PAST" "$d19/log" >/dev/null 2>&1 || rc19=$?
check "budget exhausted: exit 7, distinct from a confirmed launch's exit 0" "$rc19" "7"
if [ -d "$LOCK19" ]; then
  echo "FAIL - budget exhausted: lock must be released, not held forever"
  fails=$((fails+1))
else
  echo "ok - budget exhausted: lock released anyway"
fi
log19="$(cat "$d19/log" 2>/dev/null || true)"
contains "budget exhausted: log names it plainly" "$log19" "UNCONFIRMED"

# --- 20 (r4-codex-3). a claim whose "acquired" stamp cannot be written must
# be refused loudly, never held as a silently-unstampable (and therefore
# permanently unreclaimable) lock -------------------------------------------
# Deterministic seam, no root, no timing: LOCKDIR is pre-created normally
# (0755) so `mkdir -p "$LOCKDIR"` inside the script is a no-op that leaves
# it traversable; headed-arm.sh then runs under `umask 0777`. Under that
# umask, `mkdir "$LOCK"` (a NEW directory under the already-writable
# LOCKDIR) still succeeds - creating an entry only needs write+exec on the
# PARENT - but $LOCK itself is created with mode 000, so the immediately
# following stamp write inside it fails deterministically: the exact
# "mkdir succeeded, the stamp write failed" sequence, with no filesystem
# quirks or race timing required. The LOG file is pre-created with normal
# permissions BEFORE the umask takes effect (umask only affects newly
# created inodes), so this isolates the umask's effect to exactly the
# lock's own mkdir/file-creation calls, not every unrelated log write too.
d20="$tmp/c20"; mkdir -p "$d20/dA" "$d20/repo" "$d20/locks"
chmod 755 "$d20/locks"
LOCK20="$d20/locks/HIMMEL-stampfail.lock"
cat > "$d20/dA/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
sleep 2
KONSOLE_EOF
chmod 755 "$d20/dA/konsole"
cat > "$d20/dA/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
exit 1
PGREP_EOF
chmod 755 "$d20/dA/pgrep"
: > "$d20/dA/log"
# Pre-create the stderr-capture file too, with normal permissions, BEFORE
# entering the umask 0777 subshell below - otherwise the redirect target
# itself is created UNDER that umask and ends up mode 000, unreadable by
# this suite's own subsequent `cat` (a different process, normal umask).
: > "$d20/stderr"
rc20=0
( umask 0777
  HEADED_ARM_LOCK_DIR="$d20/locks" KONSOLE_CMD="$d20/dA/konsole" PGREP_CMD="$d20/dA/pgrep" HEADED_ARM_REPO="$d20/repo" \
    bash "$SCRIPT" "HIMMEL-stampfail" "doc20.md" "$d20/dA/signal-never" "$PAST" "$d20/dA/log" >/dev/null 2>"$d20/stderr"
) || rc20=$?
stderr20="$(cat "$d20/stderr" 2>/dev/null || true)"
check "unstampable lock: exit 8, distinct from every other outcome" "$rc20" "8"
if [ -d "$LOCK20" ]; then
  echo "FAIL - unstampable lock: must be removed, never held as a silent wedge"
  fails=$((fails+1))
else
  echo "ok - unstampable lock: removed rather than wedged"
fi
if [ -s "$d20/dA/record" ]; then
  echo "FAIL - unstampable lock: konsole must NEVER be invoked (refused before launch)"
  fails=$((fails+1))
else
  echo "ok - unstampable lock: konsole never invoked (refused before launch)"
fi
contains "unstampable lock: stderr names the cause" "$stderr20" "acquired stamp"

# --- 21 (r5-codex-3). a HARD deadline wakes the wait loop near the
# deadline, not up to 30s late - a flat `sleep 30` used to let a deadline
# only 2s out sit unnoticed for the whole 30s, since the loop checked the
# deadline once, well before it was due, then slept the full 30s regardless
# ----------------------------------------------------------------------
d21="$tmp/c21"; mk_stub "$d21" 1 alive "HIMMEL-neardeadline"
NEAR_FUTURE=$(( $(date +%s) + 2 ))
rc21=0
KONSOLE_CMD="$d21/konsole" PGREP_CMD="$d21/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d21/locks" HEADED_ARM_PROC="$d21/proc" \
  bash "$SCRIPT" "HIMMEL-neardeadline" "doc21.md" "$d21/signal-never" "$NEAR_FUTURE" "$d21/log" >/dev/null 2>&1 &
pid21=$!
# A generous but still-fast tolerance: comfortably past the 2s deadline,
# nowhere near the pre-fix bug's ~30s overshoot - if the loop woke on time
# the launch is already well underway by 4s; if it did not, "deadline
# reached" will still be absent from the log at this point.
sleep 4
log21_early="$(cat "$d21/log" 2>/dev/null || true)"
wait "$pid21" 2>/dev/null; rc21=$?
contains "near deadline: fires within a small tolerance, not up to 30s late" "$log21_early" "deadline reached"
check "near deadline: exit 0 (a launch, not a dedup)" "$rc21" "0"

# --- 22 (self-caught while fixing r5-codex-3). a DEADLINE carrying a
# leading zero must not crash the wait loop's remaining-time arithmetic -
# `[ ]` compares DEADLINE as decimal (fine, always was), but `$(( ))` is an
# octal context for a leading-zero operand, and 8/9 are not valid octal
# digits; DEADLINE's own validation (digits-only) does not reject a
# leading zero, so this is reachable with a legitimately-formatted value ---
d22="$tmp/c22"; mk_stub "$d22" 1 alive "HIMMEL-leadingzero"
NEAR_FUTURE22=$(( $(date +%s) + 2 ))
DEADLINE_LZ="0${NEAR_FUTURE22}"
rc22=0
: > "$d22/stderr"
KONSOLE_CMD="$d22/konsole" PGREP_CMD="$d22/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d22/locks" HEADED_ARM_PROC="$d22/proc" \
  bash "$SCRIPT" "HIMMEL-leadingzero" "doc22.md" "$d22/signal-never" "$DEADLINE_LZ" "$d22/log" >/dev/null 2>"$d22/stderr" || rc22=$?
log22="$(cat "$d22/log" 2>/dev/null || true)"
stderr22="$(cat "$d22/stderr" 2>/dev/null || true)"
contains     "leading-zero deadline: still fires 'deadline reached'" "$log22" "deadline reached"
not_contains "leading-zero deadline: no bash arithmetic error on stderr" "$stderr22" "value too great for base"
if [ -s "$d22/record" ]; then echo "ok - leading-zero deadline: konsole IS invoked"
else echo "FAIL - leading-zero deadline: konsole IS invoked"; fails=$((fails+1)); fi
check "leading-zero deadline: exit 0 (a clean launch, confirmed)" "$rc22" "0"

# --- 23 (r6-codex-2). a SYMLINKED lock root must be refused loudly, never
# silently used - another local user could symlink the predictable default
# path elsewhere before this script ever runs -----------------------------
d23="$tmp/c23"; mk_stub "$d23" 1
mkdir -p "$d23/real-elsewhere"
ln -s "$d23/real-elsewhere" "$d23/locks-symlink"
rc23=0
: > "$d23/stderr"
KONSOLE_CMD="$d23/konsole" PGREP_CMD="$d23/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d23/locks-symlink" \
  bash "$SCRIPT" "HIMMEL-symlink" "doc23.md" "$d23/signal-never" "$PAST" "$d23/log" >/dev/null 2>"$d23/stderr" || rc23=$?
stderr23="$(cat "$d23/stderr" 2>/dev/null || true)"
check "symlinked lock root: exit 5, distinct from a dedup" "$rc23" "5"
contains "symlinked lock root: stderr names the cause" "$stderr23" "SYMLINK"
if [ -s "$d23/record" ]; then echo "FAIL - symlinked lock root: konsole must NEVER be invoked"; fails=$((fails+1))
else echo "ok - symlinked lock root: konsole never invoked"; fi

# --- 24 (r6-codex-2). a group- or world-writable lock root must be refused
# loudly too - a directory another local user could write into (even one
# THIS user happens to own) is not a directory this process controls -----
d24="$tmp/c24"; mk_stub "$d24" 1
mkdir -p "$d24/locks-open"
chmod 777 "$d24/locks-open"
rc24=0
: > "$d24/stderr"
KONSOLE_CMD="$d24/konsole" PGREP_CMD="$d24/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d24/locks-open" \
  bash "$SCRIPT" "HIMMEL-writable" "doc24.md" "$d24/signal-never" "$PAST" "$d24/log" >/dev/null 2>"$d24/stderr" || rc24=$?
stderr24="$(cat "$d24/stderr" 2>/dev/null || true)"
check "group/world-writable lock root: exit 5, distinct from a dedup" "$rc24" "5"
contains "group/world-writable lock root: stderr names the cause" "$stderr24" "writable"
if [ -s "$d24/record" ]; then echo "FAIL - group/world-writable lock root: konsole must NEVER be invoked"; fails=$((fails+1))
else echo "ok - group/world-writable lock root: konsole never invoked"; fi
chmod 700 "$d24/locks-open" 2>/dev/null

# --- 25 (r6-codex-2). a lock root owned by a DIFFERENT uid must be refused
# too - skipped cleanly (never faked) if this host offers no way to arrange
# one without privileges we do not have -------------------------------------
if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
  echo "ok - SKIPPED: lock root owned by another uid (no passwordless privilege escalation on this host to arrange one - sudo -n true failed)"
else
  d25="$tmp/c25"; mk_stub "$d25" 1
  mkdir -p "$d25/locks-otheruid"
  if sudo -n chown nobody:nobody "$d25/locks-otheruid" >/dev/null 2>&1; then
    rc25=0
    : > "$d25/stderr"
    KONSOLE_CMD="$d25/konsole" PGREP_CMD="$d25/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d25/locks-otheruid" \
      bash "$SCRIPT" "HIMMEL-otheruid" "doc25.md" "$d25/signal-never" "$PAST" "$d25/log" >/dev/null 2>"$d25/stderr" || rc25=$?
    stderr25="$(cat "$d25/stderr" 2>/dev/null || true)"
    check "lock root owned by another uid: exit 5, distinct from a dedup" "$rc25" "5"
    contains "lock root owned by another uid: stderr names the cause" "$stderr25" "owned"
    if [ -s "$d25/record" ]; then echo "FAIL - lock root owned by another uid: konsole must NEVER be invoked"; fails=$((fails+1))
    else echo "ok - lock root owned by another uid: konsole never invoked"; fi
    sudo -n chown "$(id -u):$(id -g)" "$d25/locks-otheruid" >/dev/null 2>&1
  else
    echo "ok - SKIPPED: lock root owned by another uid (sudo -n chown to nobody:nobody failed - no usable privilege on this host)"
  fi
fi

# --- 26 (r6-codex-2). the happy path is unaffected: a fresh lock root is
# still created mode 0700, and the launch still proceeds -------------------
d26="$tmp/c26"; mk_stub "$d26" 1 alive "HIMMEL-freshroot"
rc26=0
KONSOLE_CMD="$d26/konsole" PGREP_CMD="$d26/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d26/locks-fresh" HEADED_ARM_PROC="$d26/proc" \
  bash "$SCRIPT" "HIMMEL-freshroot" "doc26.md" "$d26/signal-never" "$PAST" "$d26/log" >/dev/null 2>&1 || rc26=$?
check "fresh lock root: exit 0 (happy path unaffected)" "$rc26" "0"
root_mode="$(stat -c '%a' "$d26/locks-fresh" 2>/dev/null || stat -f '%Lp' "$d26/locks-fresh" 2>/dev/null || true)"  # gnu-ok: GNU stat -c is paired with the BSD stat -f fallback on this same line
check "fresh lock root: created mode 0700" "$root_mode" "700"
if [ -s "$d26/record" ]; then echo "ok - fresh lock root: konsole IS invoked"
else echo "FAIL - fresh lock root: konsole IS invoked"; fails=$((fails+1)); fi

# --- 27 (r7-codex-1). `pgrep -f` matches the FULL command line, and
# konsole's OWN argv literally quotes the whole claude invocation it was
# told to run - so a REALISTIC recorded argv line (below, shaped exactly
# like what pgrep would actually see for a live konsole launch) matches the
# same "[c]laude .*-n NAME " pattern the dedup/visibility checks use, even
# though no claude process exists at all. Without the comm check, this
# would read as a CONFIRMED session; the fixture's only pid has comm
# "konsole", never "claude", so it must never be believed. -----------------
d27="$tmp/c27"
mkdir -p "$d27"
cat > "$d27/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
sleep 5
KONSOLE_EOF
chmod 755 "$d27/konsole"
mkdir -p "$d27/proc/9001"; echo konsole > "$d27/proc/9001/comm"
cat > "$d27/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
[ -s "$dir/record" ] || exit 1
pattern="$2"
line="konsole --workdir /repo -p tabtitle=HIMMEL-argvtest -e env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 HIMMEL_INITIATIVE=x ARMAUTOMERGE=1 claude --model claude-fable-5-1 -n HIMMEL-argvtest load doc27.md and continue"
if grep -Eq -- "$pattern" <<< "$line"; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
chmod 755 "$d27/pgrep"
rc27=0
KONSOLE_CMD="$d27/konsole" PGREP_CMD="$d27/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d27/locks" HEADED_ARM_PROC="$d27/proc" \
  bash "$SCRIPT" "HIMMEL-argvtest" "doc27.md" "$d27/signal-never" "$PAST" "$d27/log" >/dev/null 2>&1 || rc27=$?
check "konsole-argv false match: exit 7, never confirmed via the launcher's own pid" "$rc27" "7"
log27="$(cat "$d27/log" 2>/dev/null || true)"
contains "konsole-argv false match: log says UNCONFIRMED" "$log27" "UNCONFIRMED"

# --- 28 (r7-codex-2). pgrep was only checked BEFORE acquiring the lock - a
# contender that saw "no session" right before the lock frees up (because
# the ORIGINAL holder just launched and released) must not blindly launch a
# duplicate just because ITS OWN pre-lock check was clean. A call-counting
# pgrep stub flips the answer AFTER the first two calls: call 1 is dedup
# layer 1 (before the lock is ever touched), call 2 is the retry loop's own
# pre-claim check on its first iteration - BOTH must stay "no match" so the
# lock is actually claimed via mkdir, exercising the NEW post-claim recheck
# (call 3 onward) rather than short-circuiting through either of the
# EXISTING pre-lock checks, which would prove nothing about this fix -------
d28="$tmp/c28"; mk_stub "$d28" 1 alive "HIMMEL-postlockrace"
cat > "$d28/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
dir="$(dirname "$0")"
count_file="$dir/call-count"
n=0
[ -f "$count_file" ] && n="$(cat "$count_file")"
n=$((n+1))
echo "$n" > "$count_file"
if [ "$n" -le 2 ]; then exit 1; fi
echo 9001
exit 0
PGREP_EOF
chmod 755 "$d28/pgrep"
rc28=0
KONSOLE_CMD="$d28/konsole" PGREP_CMD="$d28/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d28/locks" HEADED_ARM_PROC="$d28/proc" \
  bash "$SCRIPT" "HIMMEL-postlockrace" "doc28.md" "$d28/signal-never" "$PAST" "$d28/log" >/dev/null 2>&1 || rc28=$?
check "post-lock recheck: exit 0 (defers to the session that appeared)" "$rc28" "0"
if [ -s "$d28/record" ]; then echo "FAIL - post-lock recheck: konsole must NEVER be invoked"; fails=$((fails+1))
else echo "ok - post-lock recheck: konsole never invoked"; fi
if [ -d "$d28/locks/HIMMEL-postlockrace.lock" ]; then
  echo "FAIL - post-lock recheck: lock must be released, not held"
  fails=$((fails+1))
else
  echo "ok - post-lock recheck: lock released"
fi
log28="$(cat "$d28/log" 2>/dev/null || true)"
contains "post-lock recheck: log names the appeared-after-claim race" "$log28" "appeared after this arm claimed the lock"

# --- 29 (r8-codex-4). konsole can hand off to an already-running instance
# and let the backgrounded pid exit immediately - a dead pid must NOT be
# treated as failure on its own if a real claude session IS confirmable.
# This konsole stub exits right away (like the "dying" behavior) but ALSO
# touches confirmable (simulating a genuine hand-off: the launch itself
# succeeded, only the terminal PID this script happened to background did
# not survive) -----------------------------------------------------------
d29="$tmp/c29"
mkdir -p "$d29"
_fake_claude_proc "$d29" "HIMMEL-handoff"
cat > "$d29/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
: > "$(dirname "$0")/confirmable"
exit 0
KONSOLE_EOF
chmod 755 "$d29/konsole"
cat > "$d29/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
if [ -e "$(dirname "$0")/confirmable" ]; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
chmod 755 "$d29/pgrep"
rc29=0
KONSOLE_CMD="$d29/konsole" PGREP_CMD="$d29/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d29/locks" HEADED_ARM_PROC="$d29/proc" \
  bash "$SCRIPT" "HIMMEL-handoff" "doc29.md" "$d29/signal-never" "$PAST" "$d29/log" >/dev/null 2>&1 || rc29=$?
check "konsole hand-off (dead pid, confirmed session): exit 0, a success" "$rc29" "0"
log29="$(cat "$d29/log" 2>/dev/null || true)"
not_contains "konsole hand-off: log never says FAILED" "$log29" "FAILED"

# --- 30 (r8-codex-3). a pgrep SCAN failure (rc=2, a usage/fatal error, not
# a genuine no-match) must refuse rather than launch - conflating it with
# "nothing running" would bypass dedup on a broken scan ---------------------
d30="$tmp/c30"; mk_stub "$d30" 1
cat > "$d30/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
exit 2
PGREP_EOF
chmod 755 "$d30/pgrep"
rc30=0
KONSOLE_CMD="$d30/konsole" PGREP_CMD="$d30/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d30/locks" HEADED_ARM_PROC="$d30/proc" \
  bash "$SCRIPT" "HIMMEL-scanfail" "doc30.md" "$d30/signal-never" "$PAST" "$d30/log" >/dev/null 2>&1 || rc30=$?
check "pgrep scan failure (rc=2): refuses with its own distinct exit" "$rc30" "9"
if [ -s "$d30/record" ]; then echo "FAIL - pgrep scan failure: konsole must NEVER be invoked"; fails=$((fails+1))
else echo "ok - pgrep scan failure: konsole never invoked"; fi
log30="$(cat "$d30/log" 2>/dev/null || true)"
contains "pgrep scan failure: log names it INDETERMINATE" "$log30" "INDETERMINATE"

# mk_positional_pgrep <dir> <cmdline-fields...> - r9-codex-3 test infra: a
# pgrep stub that reports pid 9001 as a candidate once <dir>/confirmable
# exists, with 9001's REAL /proc cmdline set to the given fields (each
# written with a genuine NUL separator, never space-joined - a
# space-joined fixture would let a case pass without ever exercising the
# NUL-splitting the fix depends on).
mk_positional_pgrep() {
  local dir="$1"; shift
  mkdir -p "$dir/proc/9001"
  echo claude > "$dir/proc/9001/comm"
  printf '%s\0' "$@" > "$dir/proc/9001/cmdline"
  cat > "$dir/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
if [ -e "$(dirname "$0")/confirmable" ]; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
  chmod 755 "$dir/pgrep"
}
mk_alive_konsole() { # mk_alive_konsole <dir> - matches mk_stub's "alive"
                      # konsole behavior standalone, for a case building
                      # its own bespoke pgrep instead of using mk_stub's.
  cat > "$1/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
: > "$(dirname "$0")/confirmable"
sleep 5
KONSOLE_EOF
  chmod 755 "$1/konsole"
}

# --- 31 (r9-codex-3). the name appears ONLY inside a PROMPT text element -
# a flattened-string match would see "-n HIMMEL-promptonly " sitting right
# there, but the REAL argv never has "-n" as a SEPARATE element immediately
# before it (it is all one quoted prompt argument) - must NOT confirm ------
d31="$tmp/c31"; mkdir -p "$d31"
mk_alive_konsole "$d31"
mk_positional_pgrep "$d31" claude --model claude-fable-5-1 -n HIMMEL-someone-else \
  "load ... -n HIMMEL-promptonly ... and continue"
rc31=0
KONSOLE_CMD="$d31/konsole" PGREP_CMD="$d31/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d31/locks" HEADED_ARM_PROC="$d31/proc" \
  bash "$SCRIPT" "HIMMEL-promptonly" "doc31.md" "$d31/signal-never" "$PAST" "$d31/log" >/dev/null 2>&1 || rc31=$?
check "name only inside a PROMPT element: exit 7, never confirmed" "$rc31" "7"
log31="$(cat "$d31/log" 2>/dev/null || true)"
contains "name only inside a PROMPT element: log says UNCONFIRMED" "$log31" "UNCONFIRMED"

# --- 32 (r9-codex-3). a genuine positional "-n <name>" pair MUST still
# confirm - the fix must not overcorrect into never confirming anything ---
d32="$tmp/c32"; mkdir -p "$d32"
mk_alive_konsole "$d32"
mk_positional_pgrep "$d32" claude --model claude-fable-5-1 -n HIMMEL-genuine \
  "load doc32.md and continue"
rc32=0
KONSOLE_CMD="$d32/konsole" PGREP_CMD="$d32/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d32/locks" HEADED_ARM_PROC="$d32/proc" \
  bash "$SCRIPT" "HIMMEL-genuine" "doc32.md" "$d32/signal-never" "$PAST" "$d32/log" >/dev/null 2>&1 || rc32=$?
check "genuine positional -n match: exit 0, confirmed" "$rc32" "0"

# --- 33 (r9-codex-3). a session whose name merely has ours as a PREFIX
# (HIMMEL-2545-x when this arm is HIMMEL-2545) must NOT satisfy an exact
# positional match --------------------------------------------------------
d33="$tmp/c33"; mkdir -p "$d33"
mk_alive_konsole "$d33"
mk_positional_pgrep "$d33" claude --model claude-fable-5-1 -n HIMMEL-2545-x \
  "load other.md and continue"
rc33=0
KONSOLE_CMD="$d33/konsole" PGREP_CMD="$d33/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d33/locks" HEADED_ARM_PROC="$d33/proc" \
  bash "$SCRIPT" "HIMMEL-2545" "doc33.md" "$d33/signal-never" "$PAST" "$d33/log" >/dev/null 2>&1 || rc33=$?
check "name-prefix near-miss: exit 7, never confirmed" "$rc33" "7"
log33="$(cat "$d33/log" 2>/dev/null || true)"
contains "name-prefix near-miss: log says UNCONFIRMED" "$log33" "UNCONFIRMED"

# --- 34 (r10-codex-3). a RELATIVE $LOG and a RELATIVE HEADED_ARM_LOCK_DIR
# override, invoked from a cwd that is NOT $REPO, must resolve against the
# CALLER's cwd - not silently start writing under $REPO (or leave the
# cleanup targeting a path that never existed there) once this script cd's
# into $REPO. $REPO here is the suite's own throwaway repo fixture, a
# DIFFERENT directory from the caller's cwd below, so a fix that merely
# happened to resolve against $REPO would still fail this case ----------
d34="$tmp/c34"; mkdir -p "$d34/callerhome"
mk_stub "$d34" 1 alive "HIMMEL-relpath"
rc34=0
( cd "$d34/callerhome" && \
  KONSOLE_CMD="$d34/konsole" PGREP_CMD="$d34/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_PROC="$d34/proc" \
    HEADED_ARM_LOCK_DIR="rel-locks" \
    bash "$SCRIPT" "HIMMEL-relpath" "doc34.md" "signal-never" "$PAST" "rel.log" >/dev/null 2>&1 ) || rc34=$?
check "relative log/lock root: exit 0 (happy path unaffected)" "$rc34" "0"
rellog34="$(cat "$d34/callerhome/rel.log" 2>/dev/null || true)"
# Checks a line written AFTER the cd (not just the first "armed:" line,
# which is written before cd even on the unfixed code and would pass
# either way) - proving every later write still targets the caller's file,
# not one split across two locations once the cwd changes mid-run.
contains "relative log path: post-cd status line lands in the CALLER's log" "$rellog34" "konsole launched"
if [ -d "$d34/callerhome/rel-locks/HIMMEL-relpath.lock" ]; then
  echo "FAIL - relative lock root: lock left behind under the caller's cwd (cleanup targeted the wrong, post-cd-relative path)"
  fails=$((fails+1))
else
  echo "ok - relative lock root: lock actually removed from where it was created"
fi

# --- 35 (r10-codex-4). a candidate whose argv ENDS at the name (no
# trailing prompt argument) must still be recognized as a genuine dedup -
# the old pattern's trailing-space requirement would filter this candidate
# out of pgrep's own results before the exact argv check ever got a look,
# so this arm would launch a real duplicate instead of deferring ---------
d35="$tmp/c35"; mkdir -p "$d35"
mkdir -p "$d35/proc/9001"
echo claude > "$d35/proc/9001/comm"
printf 'claude\0--model\0claude-fable-5-1\0-n\0HIMMEL-endname\0' > "$d35/proc/9001/cmdline"
cat > "$d35/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
sleep 5
KONSOLE_EOF
chmod 755 "$d35/konsole"
cat > "$d35/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
pattern="$2"
candidate="claude --model x -n HIMMEL-endname"
if grep -Eq -- "$pattern" <<< "$candidate"; then echo 9001; exit 0; fi
exit 1
PGREP_EOF
chmod 755 "$d35/pgrep"
rc35=0
KONSOLE_CMD="$d35/konsole" PGREP_CMD="$d35/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d35/locks" HEADED_ARM_PROC="$d35/proc" \
  bash "$SCRIPT" "HIMMEL-endname" "doc35.md" "$d35/signal-never" "$PAST" "$d35/log" >/dev/null 2>&1 || rc35=$?
check "candidate argv ends at the name: exit 0 (a genuine dedup)" "$rc35" "0"
if [ -s "$d35/record" ]; then
  echo "FAIL - candidate argv ends at the name: konsole must NOT be invoked (would be a duplicate)"
  fails=$((fails+1))
else
  echo "ok - candidate argv ends at the name: konsole not invoked (correctly deduped)"
fi
log35="$(cat "$d35/log" 2>/dev/null || true)"
contains "candidate argv ends at the name: log names it already running" "$log35" "already running"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
