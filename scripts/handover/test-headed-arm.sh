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
# Case 36's "unset" rows assert the default (no launcher override) path; a
# claudex-launched leg exports these ambiently, which would silently flip
# those rows green-from-default to green-from-override. Clear them so the
# suite's own per-case overrides are the only source, same as
# console-kit/test-headed-arm-leg.sh:40.
unset HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_RECORDER 2>/dev/null || true
# r2-codex-4: this mktemp used to be unchecked. A failed mktemp leaves $tmp
# EMPTY, and every fixture path built on it below ("$tmp/..." -> "/...")
# then targets an unintended location instead of a throwaway one - abort
# loudly rather than let that happen.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/headed-arm-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# HIMMEL-3299: marker for the end-of-suite check that no case left a launch
# record in the operator's real launch-record dir (see case 40).
: > "$tmp/suite-start-marker"
# headed-arm.sh writes a console arm's launch row to
# ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs. Pin it under $tmp for
# the whole suite, as console-kit/test-headed-arm-leg.sh does, so a --role console
# case that forgets its own dir (38a-38l did) lands here, not in production data.
# Cases 1e-1h still pass a per-case dir, which overrides this.
export HIMMELCTL_CACHE_DIR="$tmp/pinned-himmelctl-cache"
# HIMMEL-3182: headed-arm.sh mkdirs its claim-lock root `-m 0700` and then
# validates it (owner, group/world-writable bits), and most cases below (fresh
# lock root, 0700 readback, chmod 777 refusal) assert exactly that. On a host
# where a mode does not stick (Git Bash / NTFS) the fresh root is refused (exit
# 5) before any case's own assertion runs, so the suite SKIPs there -- measured
# by host_modes_stick, not uname; a Linux host still runs every case.
# shellcheck source=../lib/host-caps.sh
. "$HERE/../lib/host-caps.sh"
if ! host_modes_stick; then
  host_skip "headed-arm.sh's claim-lock root needs a chmod/mkdir -m 0700 that sticks; this host's modes do not"
  exit 0
fi
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

# run_headed_arm <stubdir> <repo> <name> <doc> <signal> <deadline> [model] \
#                 [context] - invokes the script under test with the seams
# wired to <stubdir>. The log lands at <stubdir>/log.
# HEADED_ARM_LOCK_DIR defaults to a subdir OF the stub dir, so every case's
# claim locks are isolated from every other case's by construction (no case
# has to clean up after another, and the real /tmp lock root is never
# touched). A case that wants to test lock contention pre-seeds
# "$stubdir/locks" before calling run_headed_arm.
# [context] (HIMMEL-2658) is the 8th positional; since headed-arm.sh reads it
# by POSITION, a case that wants an explicit [context] with the default
# model has to pass that default model explicitly too (there is no way to
# skip position 6 while filling position 7).
run_headed_arm() {
  local stubdir="$1" repo="$2" name="$3" doc="$4" signal="$5" deadline="$6" model="${7:-}" context="${8:-}"
  local log="$stubdir/log"
  if [ -n "$context" ]; then
    KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" HEADED_ARM_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
      bash "$SCRIPT" "$name" "$doc" "$signal" "$deadline" "$log" "$model" "$context"
  elif [ -n "$model" ]; then
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
contains     "happy path: carries the default model (Opus parent, HIMMEL-3079)" "$rec1" "claude-opus-5-5"
not_contains "happy path: default model is not Fable"   "$rec1" "claude-fable-5-1"
contains "happy path: doc reaches the prompt"            "$rec1" "load some/handover-doc.md and continue"
# HIMMEL-2973: default [context] is now `standard` (--autocompact 200000) --
# the console arm path is the biggest cache-read cost driver on the fleet
# (2026-09-12 cost audit), and 1m context is now an explicit opt-in via
# CONSOLE_CONTEXT=1m in the launching shell, never the bare default.
contains     "happy path: default context passes autocompact 200000" "$rec1" "--autocompact 200000"
not_contains "happy path: default context has no autocompact auto"   "$rec1" "--autocompact auto"
not_contains "happy path: default model carries no [1m] suffix" "$rec1" "[1m]"
log1="$(cat "$d1/log" 2>/dev/null || true)"
contains "happy path: log records the default context (standard)" "$log1" "context=standard (default)"

# --- 1b (HIMMEL-2973). CONSOLE_CONTEXT=1m opts into 1m without a positional -
d1b="$tmp/c1b"; mk_stub "$d1b" 1 alive "HIMMEL-9999b-leg"
rc1b=0
CONSOLE_CONTEXT=1m run_headed_arm "$d1b" "$REPO" "HIMMEL-9999b-leg" "some/handover-doc.md" "$d1b/signal-never" "$PAST" >/dev/null 2>&1 || rc1b=$?
wait_record "$d1b" || true
rec1b="$(cat "$d1b/record" 2>/dev/null || true)"
check "CONSOLE_CONTEXT=1m: exit 0" "$rc1b" "0"
contains     "CONSOLE_CONTEXT=1m: passes autocompact auto"   "$rec1b" "--autocompact auto"
not_contains "CONSOLE_CONTEXT=1m: no autocompact 200000"     "$rec1b" "--autocompact 200000"
log1b="$(cat "$d1b/log" 2>/dev/null || true)"
# HIMMEL-3279: spec §2.4 keys on `context=1m (explicit)`; the emitter used to
# say `(CONSOLE_CONTEXT=1m)`. One spelling, the spec's.
contains     "CONSOLE_CONTEXT=1m: log spells the source (explicit)" "$log1b" "context=1m (explicit)"
not_contains "CONSOLE_CONTEXT=1m: log no longer spells the mechanism as the source" "$log1b" "(CONSOLE_CONTEXT=1m)"

# --- 1c (HIMMEL-2973). positional 1m WITHOUT the env is refused up front ----
d1c="$tmp/c1c"; mk_stub "$d1c" 1 alive "HIMMEL-9999c-leg"
outc1c=$(env -u CONSOLE_CONTEXT KONSOLE_CMD="$d1c/konsole" PGREP_CMD="$d1c/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d1c/locks" HEADED_ARM_PROC="$d1c/proc" \
    bash "$SCRIPT" "HIMMEL-9999c-leg" "some/handover-doc.md" "$d1c/signal-never" "$PAST" "$d1c/log" claude-opus-5 1m 2>&1)
rcc1c=$?
check    "positional 1m without env: exit 2" "$rcc1c" "2"
contains "positional 1m without env: names CONSOLE_CONTEXT=1m" "$outc1c" "CONSOLE_CONTEXT=1m"
if [ -e "$d1c/record" ]; then echo "FAIL - positional 1m without env: no konsole record"; fails=$((fails+1))
else echo "ok - positional 1m without env: no konsole record"; fi
if [ -e "$d1c/locks" ]; then echo "FAIL - positional 1m without env: no lock dir created"; fails=$((fails+1))
else echo "ok - positional 1m without env: no lock dir created"; fi

# --- 1d (HIMMEL-2973). positional 1m WITH the env is accepted ---------------
d1d="$tmp/c1d"; mk_stub "$d1d" 1 alive "HIMMEL-9999d-leg"
rc1d=0
CONSOLE_CONTEXT=1m run_headed_arm "$d1d" "$REPO" "HIMMEL-9999d-leg" "some/handover-doc.md" "$d1d/signal-never" "$PAST" claude-opus-5 1m >/dev/null 2>&1 || rc1d=$?
wait_record "$d1d" || true
rec1d="$(cat "$d1d/record" 2>/dev/null || true)"
check "positional 1m with env: exit 0" "$rc1d" "0"
contains "positional 1m with env: passes autocompact auto" "$rec1d" "--autocompact auto"

# --- 1e (HIMMEL-3279). a console arm records its launch context DURABLY, at
# launch, in the HIMMEL-3270 launch-logs dir (btrfs) - the tmpfs arm log
# ($LOG) is cleared at every reboot. A non-console arm writes nothing here
# (headed-arm-leg.sh owns a leg's own one-line record in the same file).
run_console_arm() {
  local stubdir="$1" name="$2"; shift 2
  env "$@" KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" HIMMELCTL_CACHE_DIR="$stubdir/cache" \
    bash "$SCRIPT" --role console "$name" "some/handover-doc.md" "$stubdir/signal-never" "$PAST" "$stubdir/log"
}
d1e="$tmp/c1e"; mk_stub "$d1e" 1 alive "HIMMEL-9999e-console"; mkdir -p "$d1e/cache"
rc1e=0
run_console_arm "$d1e" "HIMMEL-9999e-console" -u CONSOLE_CONTEXT >/dev/null 2>&1 || rc1e=$?
wait_record "$d1e" || true
check "durable record, default: exit 0 (precondition: the launch happened)" "$rc1e" "0"
if [ -s "$d1e/record" ]; then echo "ok - durable record, default: konsole IS invoked (precondition)"
else echo "FAIL - durable record, default: konsole IS invoked (precondition)"; fails=$((fails+1)); fi
rec1e="$(cat "$d1e/cache/launch-logs/HIMMEL-9999e-console.log" 2>/dev/null || true)"
contains "durable record, default: names the role"    "$rec1e" "headed-arm: role=console session=HIMMEL-9999e-console "
contains "durable record, default: records the mode"  "$rec1e" " context=standard "
contains "durable record, default: records the source" "$rec1e" " source=default "
contains "durable record, default: records autocompact" "$rec1e" " autocompact=200000 "

d1f="$tmp/c1f"; mk_stub "$d1f" 1 alive "HIMMEL-9999f-console"; mkdir -p "$d1f/cache"
rc1f=0
run_console_arm "$d1f" "HIMMEL-9999f-console" CONSOLE_CONTEXT=1m >/dev/null 2>&1 || rc1f=$?
wait_record "$d1f" || true
check "durable record, 1m opt-in: exit 0 (precondition: the launch happened)" "$rc1f" "0"
rec1f="$(cat "$d1f/cache/launch-logs/HIMMEL-9999f-console.log" 2>/dev/null || true)"
contains "durable record, 1m opt-in: records the mode"   "$rec1f" " context=1m "
contains "durable record, 1m opt-in: records the source" "$rec1f" " source=explicit "
contains "durable record, 1m opt-in: records autocompact" "$rec1f" " autocompact=auto "

# a non-console arm (no --role) writes no durable context record
d1g="$tmp/c1g"; mk_stub "$d1g" 1 alive "HIMMEL-9999g-leg"; mkdir -p "$d1g/cache"
rc1g=0
env -u CONSOLE_CONTEXT KONSOLE_CMD="$d1g/konsole" PGREP_CMD="$d1g/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d1g/locks" HEADED_ARM_PROC="$d1g/proc" HIMMELCTL_CACHE_DIR="$d1g/cache" \
    bash "$SCRIPT" "HIMMEL-9999g-leg" "some/handover-doc.md" "$d1g/signal-never" "$PAST" "$d1g/log" >/dev/null 2>&1 || rc1g=$?
wait_record "$d1g" || true
check "no --role: exit 0 (precondition: the launch happened)" "$rc1g" "0"
if [ -e "$d1g/cache/launch-logs/HIMMEL-9999g-leg.log" ]; then echo "FAIL - no --role: a non-console arm wrote a durable context record"; fails=$((fails+1))
else echo "ok - no --role: a non-console arm writes no durable context record"; fi

# a launch record that cannot be written never stops the launch, and says so
d1h="$tmp/c1h"; mk_stub "$d1h" 1 alive "HIMMEL-9999h-console"; : > "$d1h/cache"
rc1h=0
run_console_arm "$d1h" "HIMMEL-9999h-console" -u CONSOLE_CONTEXT >/dev/null 2>&1 || rc1h=$?
wait_record "$d1h" || true
check "unwritable launch-logs: launch still exits 0" "$rc1h" "0"
contains "unwritable launch-logs: WARN names the gap in the arm log" "$(cat "$d1h/log" 2>/dev/null || true)" "WARN context record NOT written"

# --- 2. explicit model overrides the default -----------------------------
d2="$tmp/c2"; mk_stub "$d2" 1 alive "HIMMEL-leg2"
run_headed_arm "$d2" "$REPO" "HIMMEL-leg2" "doc2.md" "$d2/signal-never" "$PAST" "claude-fable-5-1" >/dev/null 2>&1
wait_record "$d2" || true
rec2="$(cat "$d2/record" 2>/dev/null || true)"
contains     "explicit model: carries the given model (Fable stays reachable)" "$rec2" "claude-fable-5-1"
not_contains "explicit model: does not fall back to the default" "$rec2" "claude-opus-5"

# --- 2b (HIMMEL-2658). explicit [context] positional, non-default value ---
# claude-opus-5 is not Fable-family, so `standard` here also proves the
# [1m]-strip-then-DON'T-reapply path never fires when unsuffixed to begin
# with (nothing to strip, nothing appended).
d2b="$tmp/c2b"; mk_stub "$d2b" 1 alive "HIMMEL-leg2b"
run_headed_arm "$d2b" "$REPO" "HIMMEL-leg2b" "doc2b.md" "$d2b/signal-never" "$PAST" "claude-opus-5" "standard" >/dev/null 2>&1
wait_record "$d2b" || true
rec2b="$(cat "$d2b/record" 2>/dev/null || true)"
contains     "explicit standard context: passes autocompact 200000" "$rec2b" "--autocompact 200000"
not_contains "explicit standard context: no autocompact auto"       "$rec2b" "--autocompact auto"
not_contains "explicit standard context: no [1m] suffix"            "$rec2b" "[1m]"
log2b="$(cat "$d2b/log" 2>/dev/null || true)"
contains "explicit standard context: log records context=standard" "$log2b" "context=standard"

# --- 2c (HIMMEL-2658). a bad [context] value refuses before any launch ----
outc=$(bash "$SCRIPT" HIMMEL-leg2c doc2c.md "$tmp/signal-never-2c" "$PAST" "$tmp/log2c" claude-opus-5 bogus 2>&1)
rcc=$?
check    "bad context value: exit 2"      "$rcc" "2"
contains "bad context value: names the bad value" "$outc" "context must be 1m or standard, got: bogus"

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
# HIMMEL-2877 (panel round 1, codex-1): a SEPARATE background releaser that
# reacts to a sync file still races the very check it exists to
# synchronize with - whichever session_confirmed() call the releaser
# reacted to necessarily observed "no match" (that observation is what
# triggered the reaction, in a different process), so a claim_lock()
# attempted in that SAME iteration can still win before the releaser's own
# writes land. No fixed delay, sync file or write-order can close that:
# the releaser is fundamentally a second process reacting after the fact.
#
# The only way to make the flip and the lock-release indivisible is to do
# both from the SAME statement in the SAME process as the check itself -
# so the pgrep stub counts its own invocations and, once a chosen call
# arrives, releases the lock and reports the match synchronously, before
# returning. Nothing else can run in between because there is no "in
# between": it is one shell script, no backgrounding. Calls 1-2 are the
# pre-loop dedup check (line ~575) and the retry loop's first genuine
# no-match/claim-fails iteration (lock still real); call 3 is the retry
# loop's second iteration, where THIS SAME invocation removes the lock and
# reports the match - the loop's if/exit-0 branch returns immediately on a
# match, so claim_lock() is never even reached on that iteration.
cat > "$d14/pgrep" <<PGREP_EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$d14/pgrep-calls" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" > "$d14/pgrep-calls"
if [ "\$n" -ge 3 ]; then
    rm -rf "$d14/locks/HIMMEL-donedeal.lock"
    echo 9001
    exit 0
fi
exit 1
PGREP_EOF
chmod 755 "$d14/pgrep"
rc14=0
KONSOLE_CMD="$d14/konsole" PGREP_CMD="$d14/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d14/locks" HEADED_ARM_PROC="$d14/proc" \
  bash "$SCRIPT" "HIMMEL-donedeal" "doc14.md" "$d14/signal-never" "$PAST" "$d14/log" >/dev/null 2>&1 || rc14=$?
check "retry backs off on a genuine dedup: exit 0" "$rc14" "0"
settle
if [ -s "$d14/record" ]; then echo "FAIL - retry backs off on a genuine dedup: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - retry backs off on a genuine dedup: konsole not invoked"; fi
log14="$(cat "$d14/log" 2>/dev/null || true)"
contains "retry backs off on a genuine dedup: log names the claim-retry loop's dedup line" "$log14" "a session named HIMMEL-donedeal is already running - not launching"

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
# HIMMEL-3182: the lock was mkdir'd mode 000 (umask 0777); headed-arm.sh
# restores owner access before its `rm -rf`, so a BSD/macOS rm (which cannot
# remove a mode-000 directory) removes it too - case 20b emulates that rm.
if [ -d "$LOCK20" ]; then
  chmod 700 "$LOCK20" 2>/dev/null; rm -rf "$LOCK20"
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

# --- 20b (HIMMEL-3182). same unstampable-claim path, but under a BSD-rm
# emulation: macOS rm -rf cannot remove a mode-000 directory (EACCES), so
# stamp_or_fail_loudly must restore owner permissions on the lock it created
# before removing it, and must touch nothing else. macOS itself is NOT run
# here (the scheduled nightly is that proof) - the stub below is a PATH `rm`
# that refuses any directory whose owner bits are all clear, judged from
# `ls -ld` (not `[ -r ]`, which root would defeat), and otherwise defers to
# the real rm.
d20b="$tmp/c20b"; mkdir -p "$d20b/dA" "$d20b/repo" "$d20b/locks" "$d20b/bin"
chmod 755 "$d20b/locks"
LOCK20B="$d20b/locks/HIMMEL-stampfail-bsd.lock"
SIBLING20B="$d20b/locks/HIMMEL-stampfail-bsd.lock.keep"
mkdir -p "$SIBLING20B"; : > "$SIBLING20B/acquired"
REAL_RM="$(command -v rm)"
cat > "$d20b/bin/rm" <<RM_EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  if [ -d "\$a" ]; then
    case "\$(ls -ld "\$a")" in d---*) echo "rm: \$a: Permission denied" >&2; exit 1 ;; esac
  fi
done
exec "$REAL_RM" "\$@"
RM_EOF
chmod 755 "$d20b/bin/rm"
# The emulation must itself behave as BSD rm on a mode-000 directory, or the
# case below proves nothing.
mkdir -p "$d20b/probe"; chmod 000 "$d20b/probe"
PATH="$d20b/bin:$PATH" rm -rf "$d20b/probe" 2>/dev/null
if [ -d "$d20b/probe" ]; then
  echo "ok - bsd-rm emulation: refuses a mode-000 directory"
else
  echo "FAIL - bsd-rm emulation: stub removed a mode-000 directory, so the case below is vacuous"
  fails=$((fails+1))
fi
chmod 700 "$d20b/probe"; "$REAL_RM" -rf "$d20b/probe"
cp "$d20/dA/konsole" "$d20b/dA/konsole"; cp "$d20/dA/pgrep" "$d20b/dA/pgrep"
: > "$d20b/dA/log"; : > "$d20b/stderr"
rc20b=0
( umask 0777
  PATH="$d20b/bin:$PATH" HEADED_ARM_LOCK_DIR="$d20b/locks" KONSOLE_CMD="$d20b/dA/konsole" PGREP_CMD="$d20b/dA/pgrep" HEADED_ARM_REPO="$d20b/repo" \
    bash "$SCRIPT" "HIMMEL-stampfail-bsd" "doc20b.md" "$d20b/dA/signal-never" "$PAST" "$d20b/dA/log" >/dev/null 2>"$d20b/stderr"
) || rc20b=$?
check "unstampable lock under bsd rm: still exit 8" "$rc20b" "8"
if [ -d "$LOCK20B" ]; then
  chmod 700 "$LOCK20B" 2>/dev/null; "$REAL_RM" -rf "$LOCK20B"
  echo "FAIL - unstampable lock under bsd rm: mode-000 lock left behind (a silent wedge)"
  fails=$((fails+1))
else
  echo "ok - unstampable lock under bsd rm: removed"
fi
if [ -f "$SIBLING20B/acquired" ]; then
  echo "ok - unstampable lock under bsd rm: sibling lock dir untouched"
else
  echo "FAIL - unstampable lock under bsd rm: cleanup reached a sibling path"
  fails=$((fails+1))
fi
if [ -s "$d20b/dA/record" ]; then
  echo "FAIL - unstampable lock under bsd rm: konsole must NEVER be invoked"
  fails=$((fails+1))
else
  echo "ok - unstampable lock under bsd rm: konsole never invoked"
fi

# --- 20c (HIMMEL-3182). the owner-permission restore must not follow a
# symlink found inside the lock: a `mkdir` stub, right after creating the
# lock, plants a symlink inside it to a mode-000 directory OUTSIDE it and
# re-closes the lock to 000 (as umask 0777 would), so the stamp write fails
# with a symlink present. (A `date` stub cannot do this: the failing
# `date +%s > "$LOCK/acquired"` redirect is refused before date ever runs.)
# After the cleanup the lock is gone but the outside directory still has
# mode 000 - the restore reached only what the lock itself contained.
d20c="$tmp/c20c"; mkdir -p "$d20c/dA" "$d20c/repo" "$d20c/locks" "$d20c/bin" "$d20c/outside"
chmod 755 "$d20c/locks"
LOCK20C="$d20c/locks/HIMMEL-stampfail-link.lock"
chmod 000 "$d20c/outside"
cat > "$d20c/bin/mkdir" <<MKDIR_EOF
#!/usr/bin/env bash
"$(command -v mkdir)" "\$@" || exit \$?
case "\${!#}" in
  */HIMMEL-stampfail-link.lock)
    chmod 700 "\${!#}"; ln -s "$d20c/outside" "\${!#}/link" && : > "$d20c/planted"; chmod 000 "\${!#}" ;;
esac
MKDIR_EOF
chmod 755 "$d20c/bin/mkdir"
cp "$d20b/bin/rm" "$d20c/bin/rm"
cp "$d20/dA/konsole" "$d20c/dA/konsole"; cp "$d20/dA/pgrep" "$d20c/dA/pgrep"
: > "$d20c/dA/log"; : > "$d20c/stderr"
rc20c=0
( umask 0777
  PATH="$d20c/bin:$PATH" HEADED_ARM_LOCK_DIR="$d20c/locks" KONSOLE_CMD="$d20c/dA/konsole" PGREP_CMD="$d20c/dA/pgrep" HEADED_ARM_REPO="$d20c/repo" \
    bash "$SCRIPT" "HIMMEL-stampfail-link" "doc20c.md" "$d20c/dA/signal-never" "$PAST" "$d20c/dA/log" >/dev/null 2>"$d20c/stderr"
) || rc20c=$?
check "unstampable lock holding a symlink: still exit 8" "$rc20c" "8"
# precondition: the stub really did plant the symlink inside the lock
check "unstampable lock holding a symlink: symlink was planted inside the lock" "$([ -e "$d20c/planted" ] && echo yes || echo no)" "yes"
if [ -d "$LOCK20C" ]; then
  chmod -R 700 "$LOCK20C" 2>/dev/null; "$REAL_RM" -rf "$LOCK20C"
  echo "FAIL - unstampable lock holding a symlink: lock left behind"
  fails=$((fails+1))
else
  echo "ok - unstampable lock holding a symlink: removed"
fi
case "$(ls -ld "$d20c/outside")" in
  d---------*) echo "ok - unstampable lock holding a symlink: outside dir keeps mode 000 (chmod did not follow)" ;;
  *) echo "FAIL - unstampable lock holding a symlink: outside dir mode changed - chmod followed the link"
     fails=$((fails+1)) ;;
esac
chmod 700 "$d20c/outside" 2>/dev/null

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

# --- 36 (HIMMEL-2782). HEADED_ARM_LAUNCHER + HEADED_ARM_LAUNCHER_ENV: a
# non-default launcher and extra env tokens reach the konsole argv, and the
# default (unset) case is unchanged - the plain `claude ...` exec, no
# `script` wrapper, no extra env tokens. ------------------------------------
d36="$tmp/c36"; mk_stub "$d36" 1 alive "HIMMEL-launcher"
rc36=0
KONSOLE_CMD="$d36/konsole" PGREP_CMD="$d36/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_PROC="$d36/proc" \
  HEADED_ARM_LOCK_DIR="$d36/locks" \
  bash "$SCRIPT" "HIMMEL-launcher" "doc36.md" "$d36/signal-never" "$PAST" "$d36/log" >/dev/null 2>&1 || rc36=$?
wait_record "$d36" || true
rec36="$(cat "$d36/record" 2>/dev/null || true)"
check "HEADED_ARM_LAUNCHER unset: exit 0" "$rc36" "0"
contains "HEADED_ARM_LAUNCHER unset: still execs claude directly" "$rec36" "claude --model"
not_contains "HEADED_ARM_LAUNCHER unset: no script(1) tty wrapper" "$rec36" "script -q -a -f"

# codex CR fix: HEADED_ARM_LAUNCHER_ENV must reach the konsole argv even
# WITHOUT HEADED_ARM_RECORDER=1 - the non-recorder (default-exec) branch had
# silently dropped it, an asymmetry with no basis in the documented contract.
d36c="$tmp/c36c"; mk_stub "$d36c" 1 alive "HIMMEL-launcher3"
rc36c=0
KONSOLE_CMD="$d36c/konsole" PGREP_CMD="$d36c/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_PROC="$d36c/proc" \
  HEADED_ARM_LOCK_DIR="$d36c/locks" \
  HEADED_ARM_LAUNCHER_ENV="CLAUDEX_LANE_OK=1 CLAUDE_CODE_EFFORT_LEVEL=medium" \
  bash "$SCRIPT" "HIMMEL-launcher3" "doc36c.md" "$d36c/signal-never" "$PAST" "$d36c/log" >/dev/null 2>&1 || rc36c=$?
wait_record "$d36c" || true
rec36c="$(cat "$d36c/record" 2>/dev/null || true)"
check "HEADED_ARM_LAUNCHER_ENV without RECORDER: exit 0" "$rc36c" "0"
not_contains "HEADED_ARM_LAUNCHER_ENV without RECORDER: no script(1) tty wrapper" "$rec36c" "script -q -a -f"
contains "HEADED_ARM_LAUNCHER_ENV without RECORDER: env tokens still reach the konsole argv" "$rec36c" "CLAUDEX_LANE_OK=1 CLAUDE_CODE_EFFORT_LEVEL=medium"

# 36d (HIMMEL-2534, PR 1129 console review): HEADED_ARM_LAUNCHER_ENV is read
# into LAUNCHER_ENV and must then be unset, like HEADED_ARM_HEADLESS. konsole
# inherits headed-arm.sh's environment and hands it to the leg's claude, so a
# leaked list would make any arm spawned from that leg prepend the PARENT's
# profile tokens - first token wins - ahead of its own.
d36d="$tmp/c36d"; mk_stub "$d36d" 1 alive "HIMMEL-launcher4"
cat > "$d36d/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
printf '%s' "${HEADED_ARM_LAUNCHER_ENV-UNSET}" > "$(dirname "$0")/launcher-env"
: > "$(dirname "$0")/confirmable"
sleep 5
KONSOLE_EOF
chmod 755 "$d36d/konsole"
rc36d=0
KONSOLE_CMD="$d36d/konsole" PGREP_CMD="$d36d/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_PROC="$d36d/proc" \
  HEADED_ARM_LOCK_DIR="$d36d/locks" \
  HEADED_ARM_LAUNCHER_ENV="LEG_PROFILE_SETTINGS=/parent/settings.json" \
  bash "$SCRIPT" "HIMMEL-launcher4" "doc36d.md" "$d36d/signal-never" "$PAST" "$d36d/log" >/dev/null 2>&1 || rc36d=$?
wait_record "$d36d" || true
check "36d LAUNCHER_ENV: exit 0" "$rc36d" "0"
contains "36d LAUNCHER_ENV: the tokens still reach the konsole argv" "$(cat "$d36d/record" 2>/dev/null || true)" "LEG_PROFILE_SETTINGS=/parent/settings.json"
check "36d LAUNCHER_ENV: konsole (and so the leg) does not inherit HEADED_ARM_LAUNCHER_ENV" "$(cat "$d36d/launcher-env" 2>/dev/null || echo MISSING)" "UNSET"

d36b="$tmp/c36b"; mk_stub "$d36b" 1 alive "HIMMEL-launcher2"
rc36b=0
KONSOLE_CMD="$d36b/konsole" PGREP_CMD="$d36b/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_PROC="$d36b/proc" \
  HEADED_ARM_LOCK_DIR="$d36b/locks" \
  HEADED_ARM_LAUNCHER="/some/repo/scripts/claude-codex" \
  HEADED_ARM_LAUNCHER_ENV="CLAUDEX_LANE_OK=1 CLAUDE_CODE_EFFORT_LEVEL=medium" \
  HEADED_ARM_RECORDER=1 HEADED_ARM_UNAME=Linux \
  bash "$SCRIPT" "HIMMEL-launcher2" "doc36b.md" "$d36b/signal-never" "$PAST" "$d36b/log" "gpt-6-astra" >/dev/null 2>&1 || rc36b=$?
wait_record "$d36b" || true
rec36b="$(cat "$d36b/record" 2>/dev/null || true)"
check "HEADED_ARM_LAUNCHER=claude-codex + RECORDER=1: exit 0" "$rc36b" "0"
contains "resolved launcher: extra env tokens reach the konsole argv" "$rec36b" "CLAUDEX_LANE_OK=1 CLAUDE_CODE_EFFORT_LEVEL=medium"
contains "resolved launcher: wrapped in script(1) with the SAME log path, appending (-a)" "$rec36b" "script -q -a -f $d36b/log -c"
contains "resolved launcher: the launcher path reaches the recorded argv" "$rec36b" "/some/repo/scripts/claude-codex"
not_contains "resolved launcher: not force-wrapped in bash (execs via its own shebang)" "$rec36b" "bash /some/repo/scripts/claude-codex"
contains "resolved launcher: still carries --model gpt-6-astra" "$rec36b" "--model gpt-6-astra"
contains "resolved launcher: still carries -n NAME" "$rec36b" "-n HIMMEL-launcher2"
# codex-2 (HIMMEL-2782 CR fix): `script -c` interprets $LAUNCH_CMD (bash %q
# quoting) with the shell named by ITS OWN $SHELL, not necessarily bash -
# force it via an explicit SHELL=<bash> token ahead of `script` in the
# konsole argv, so the interpreting shell always matches the shell that
# quoted the command, regardless of the launching station's own $SHELL.
contains "resolved launcher: SHELL forced to bash ahead of script(1), independent of the launching shell" "$rec36b" "SHELL=/"

# --- 37. RED control: a mutant that always takes the RECORDER=1 branch
# must fail case 36's "no script(1) wrapper" assertion for the DEFAULT
# (unset) launcher - proves that assertion is not vacuous. -----------------
# HIMMEL-2975 T6: the mutant must keep the same scripts/handover + ../lib
# layout as the real tree -- headed-arm.sh now sources
# scripts/lib/console-context.sh relative to its OWN path ($0), and a bare
# copy dropped straight into $tmp has no sibling ../lib to find.
mutant36dir="$tmp/mutant-headed-arm-recorder"
mkdir -p "$mutant36dir/scripts/handover" "$mutant36dir/scripts/lib"
mutant36="$mutant36dir/scripts/handover/headed-arm.sh"
# shellcheck disable=SC2016 # single-quoted sed script; $RECORDER must stay literal
sed 's/if \[ "\$RECORDER" = "1" \]; then/if true; then/' "$SCRIPT" > "$mutant36"
cp "$HERE/../lib/console-context.sh" "$mutant36dir/scripts/lib/console-context.sh"
chmod 755 "$mutant36"
d37="$tmp/c37"; mk_stub "$d37" 1 alive "HIMMEL-red36"
mrc36=0
KONSOLE_CMD="$d37/konsole" PGREP_CMD="$d37/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_PROC="$d37/proc" \
  HEADED_ARM_LOCK_DIR="$d37/locks" HEADED_ARM_UNAME=Linux \
  bash "$mutant36" "HIMMEL-red36" "doc37.md" "$d37/signal-never" "$PAST" "$d37/log" >/dev/null 2>&1 || mrc36=$?
wait_record "$d37" || true
mrec36="$(cat "$d37/record" 2>/dev/null || true)"
if [ "$mrc36" -eq 0 ] && grepq "$mrec36" -F -e "script -q -a -f"; then
  echo "ok - RED control: mutant forcing the RECORDER branch wraps the default launcher too, proving case 36's assertion is not vacuous"
else
  echo "FAIL - RED control: mutant (RECORDER branch forced) did not wrap the default launcher (rc=$mrc36, out=[$mrec36]) -- case 36's assertion would not catch a real regression"
  fails=$((fails+1))
fi

# --- 38 (HIMMEL-2975, renamed HIMMEL-3133; HIMMEL-3136 R1). --role console (the
# only accepted value) on the console arm path --------------------------------
# 38a. --role console unsets HIMMEL_CONSOLE_RELAY in the child env and stamps
# role=console on the armed: log line.
d38a="$tmp/c38a"; mk_stub "$d38a" 1 alive "HIMMEL-role38a"
rc38a=0
KONSOLE_CMD="$d38a/konsole" PGREP_CMD="$d38a/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38a/locks" HEADED_ARM_PROC="$d38a/proc" \
  bash "$SCRIPT" --role console "HIMMEL-role38a" "doc38a.md" "$d38a/signal-never" "$PAST" "$d38a/log" >/dev/null 2>&1 || rc38a=$?
wait_record "$d38a" || true
rec38a="$(cat "$d38a/record" 2>/dev/null || true)"
log38a="$(cat "$d38a/log" 2>/dev/null || true)"
check "38a --role console: exit 0" "$rc38a" "0"
contains "38a --role console: armed log line stamps role=console" "$log38a" "role=console"
contains "38a --role console: konsole record clears HIMMEL_CONSOLE_RELAY" "$rec38a" "-u HIMMEL_CONSOLE_RELAY"

# 38b. the console clear is UNCONDITIONAL: an inherited HIMMEL_CONSOLE_RELAY=1
# in the arming shell's own env never reaches the child.
d38b="$tmp/c38b"; mk_stub "$d38b" 1 alive "HIMMEL-role38b"
rc38b=0
HIMMEL_CONSOLE_RELAY=1 \
  KONSOLE_CMD="$d38b/konsole" PGREP_CMD="$d38b/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38b/locks" HEADED_ARM_PROC="$d38b/proc" \
  bash "$SCRIPT" --role console "HIMMEL-role38b" "doc38b.md" "$d38b/signal-never" "$PAST" "$d38b/log" >/dev/null 2>&1 || rc38b=$?
wait_record "$d38b" || true
rec38b="$(cat "$d38b/record" 2>/dev/null || true)"
check "38b --role console with inherited HIMMEL_CONSOLE_RELAY=1: exit 0" "$rc38b" "0"
contains "38b --role console with inherited HIMMEL_CONSOLE_RELAY=1: still cleared in the child argv" "$rec38b" "-u HIMMEL_CONSOLE_RELAY"

# 38c. --role relay is no longer a value at all (HIMMEL-3136 R1): it is refused
# by the same "must be console" branch as any other unknown value, and neither
# the error nor the usage line advertises relay as valid.
outc38c=$(bash "$SCRIPT" --role relay "HIMMEL-role38c" "doc38c.md" "$tmp/signal-never-38c" "$PAST" "$tmp/log38c" 2>&1)
rc38c=$?
check "38c --role relay: exit 2" "$rc38c" "2"
contains "38c --role relay: error names 'console' as the only valid role" "$outc38c" "--role must be console, got: relay"
not_contains "38c --role relay: usage does not advertise relay as a valid role" "$outc38c" "relay|console"

# 38d. --role bogus: exit 2 + usage. The unknown-role message must name the
# new spelling (HIMMEL-3133) -- a passing exit code alone doesn't prove the
# renamed error text shipped.
outd38d=$(bash "$SCRIPT" --role bogus "HIMMEL-role38d" "doc38d.md" "$tmp/signal-never-38d" "$PAST" "$tmp/log38d" 2>&1)
rc38d=$?
check "38d --role bogus: exit 2" "$rc38d" "2"
contains "38d --role bogus: usage text" "$outd38d" "usage: headed-arm.sh"
contains "38d --role bogus: error names 'console' as the valid role" "$outd38d" "--role must be console, got: bogus"
not_contains "38d --role bogus: error does not advertise relay as valid" "$outd38d" "relay or console"

# 38e. --role with no value: exit 2.
oute38e=$(bash "$SCRIPT" --role 2>&1)
rc38e=$?
check "38e --role with no value: exit 2" "$rc38e" "2"
contains "38e --role with no value: usage text" "$oute38e" "usage: headed-arm.sh"

# 38f. no --role: today's shape stays byte-identical -- role=unsplit on the
# armed: line, and the konsole record carries no HIMMEL_CONSOLE_RELAY clear.
d38f="$tmp/c38f"; mk_stub "$d38f" 1 alive "HIMMEL-role38f"
rc38f=0
run_headed_arm "$d38f" "$REPO" "HIMMEL-role38f" "doc38f.md" "$d38f/signal-never" "$PAST" >/dev/null 2>&1 || rc38f=$?
wait_record "$d38f" || true
rec38f="$(cat "$d38f/record" 2>/dev/null || true)"
log38f="$(cat "$d38f/log" 2>/dev/null || true)"
check "38f no --role: exit 0" "$rc38f" "0"
contains "38f no --role: armed log line stamps role=unsplit" "$log38f" "role=unsplit"
not_contains "38f no --role: konsole record carries no HIMMEL_CONSOLE_RELAY clear" "$rec38f" "HIMMEL_CONSOLE_RELAY"
not_contains "38f no --role: konsole record exports no HIMMEL_CONSOLE_DOC (HIMMEL-2973)" "$rec38f" "HIMMEL_CONSOLE_DOC"

# 38g (HIMMEL-2973 S3). --role console exports HIMMEL_CONSOLE_DOC (the console
# doc) and HIMMEL_CONSOLE_WORKDIR (dirname of the signal file = the console's
# chain dir) into the launched session, so the PreCompact hook can snapshot;
# a session that is not a console gets neither (38f).
d38g="$tmp/c38g"; mk_stub "$d38g" 1 alive "HIMMEL-role38g"
rc38g=0
KONSOLE_CMD="$d38g/konsole" PGREP_CMD="$d38g/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38g/locks" HEADED_ARM_PROC="$d38g/proc" \
  bash "$SCRIPT" --role console "HIMMEL-role38g" "doc38g.md" "$d38g/chain/sig-HIMMEL-role38g" "$PAST" "$d38g/log" >/dev/null 2>&1 || rc38g=$?
wait_record "$d38g" || true
rec38g="$(cat "$d38g/record" 2>/dev/null || true)"
check "38g --role console: exit 0" "$rc38g" "0"
contains "38g --role console: a repo-relative DOC is exported ABSOLUTE (against REPO, where the session runs)" "$rec38g" "HIMMEL_CONSOLE_DOC=$REPO/doc38g.md"
contains "38g --role console: konsole record exports HIMMEL_CONSOLE_WORKDIR=dirname(signal)" "$rec38g" "HIMMEL_CONSOLE_WORKDIR=$d38g/chain"
d38h="$tmp/c38h"; mk_stub "$d38h" 1 alive "HIMMEL-role38h"
rc38h=0
KONSOLE_CMD="$d38h/konsole" PGREP_CMD="$d38h/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38h/locks" HEADED_ARM_PROC="$d38h/proc" \
  bash "$SCRIPT" --role console "HIMMEL-role38h" "/abs/doc38h.md" "$d38h/chain/sig-HIMMEL-role38h" "$PAST" "$d38h/log" >/dev/null 2>&1 || rc38h=$?
wait_record "$d38h" || true
rec38h="$(cat "$d38h/record" 2>/dev/null || true)"
check "38h --role console (absolute DOC): exit 0" "$rc38h" "0"
contains "38h --role console: an absolute DOC is exported unchanged" "$rec38h" "HIMMEL_CONSOLE_DOC=/abs/doc38h.md"

# 38i/38j (HIMMEL-3035). The console clear survives HEADED_ARM_LAUNCHER_ENV:
# `env -u FOO FOO=1` ends with FOO=1, so a HIMMEL_CONSOLE_RELAY=<v> token carried
# in the launcher env must be stripped for --role console, in BOTH konsole
# branches (38i default exec, 38j RECORDER=1), while the sibling tokens still
# reach the argv and the -u clear stays.
d38i="$tmp/c38i"; mk_stub "$d38i" 1 alive "HIMMEL-role38i"
rc38i=0
KONSOLE_CMD="$d38i/konsole" PGREP_CMD="$d38i/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38i/locks" HEADED_ARM_PROC="$d38i/proc" \
  HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_RELAY=1 CLAUDEX_LANE_OK=1 HIMMEL_CONSOLE_RELAY=2" \
  bash "$SCRIPT" --role console "HIMMEL-role38i" "doc38i.md" "$d38i/signal-never" "$PAST" "$d38i/log" >/dev/null 2>&1 || rc38i=$?
wait_record "$d38i" || true
rec38i="$(cat "$d38i/record" 2>/dev/null || true)"
check "38i --role console + LAUNCHER_ENV HIMMEL_CONSOLE_RELAY=1: exit 0" "$rc38i" "0"
contains "38i --role console: the -u HIMMEL_CONSOLE_RELAY clear stays" "$rec38i" "-u HIMMEL_CONSOLE_RELAY"
not_contains "38i --role console: no HIMMEL_CONSOLE_RELAY=<v> re-set after the clear (default branch)" "$rec38i" "HIMMEL_CONSOLE_RELAY="
contains "38i --role console: the sibling LAUNCHER_ENV token still reaches the argv" "$rec38i" "CLAUDEX_LANE_OK=1"

d38j="$tmp/c38j"; mk_stub "$d38j" 1 alive "HIMMEL-role38j"
rc38j=0
KONSOLE_CMD="$d38j/konsole" PGREP_CMD="$d38j/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38j/locks" HEADED_ARM_PROC="$d38j/proc" \
  HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_RELAY=1 CLAUDEX_LANE_OK=1" \
  HEADED_ARM_RECORDER=1 HEADED_ARM_UNAME=Linux \
  bash "$SCRIPT" --role console "HIMMEL-role38j" "doc38j.md" "$d38j/signal-never" "$PAST" "$d38j/log" >/dev/null 2>&1 || rc38j=$?
wait_record "$d38j" || true
rec38j="$(cat "$d38j/record" 2>/dev/null || true)"
check "38j --role console + LAUNCHER_ENV HIMMEL_CONSOLE_RELAY=1 + RECORDER=1: exit 0" "$rc38j" "0"
contains "38j RECORDER branch reached (script(1) wrapper present)" "$rec38j" "script -q -a -f"
contains "38j --role console: the -u HIMMEL_CONSOLE_RELAY clear stays (recorder branch)" "$rec38j" "-u HIMMEL_CONSOLE_RELAY"
not_contains "38j --role console: no HIMMEL_CONSOLE_RELAY=<v> re-set after the clear (recorder branch)" "$rec38j" "HIMMEL_CONSOLE_RELAY="
contains "38j --role console: the sibling LAUNCHER_ENV token still reaches the argv (recorder branch)" "$rec38j" "CLAUDEX_LANE_OK=1"

# 38k. control: with NO --role the launcher env is passed through untouched --
# the strip is console-only (a relay LEG legitimately carries the marker).
d38k="$tmp/c38k"; mk_stub "$d38k" 1 alive "HIMMEL-role38k"
rc38k=0
KONSOLE_CMD="$d38k/konsole" PGREP_CMD="$d38k/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38k/locks" HEADED_ARM_PROC="$d38k/proc" \
  HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_RELAY=1 CLAUDEX_LANE_OK=1" \
  bash "$SCRIPT" "HIMMEL-role38k" "doc38k.md" "$d38k/signal-never" "$PAST" "$d38k/log" >/dev/null 2>&1 || rc38k=$?
wait_record "$d38k" || true
rec38k="$(cat "$d38k/record" 2>/dev/null || true)"
check "38k no --role + LAUNCHER_ENV HIMMEL_CONSOLE_RELAY=1: exit 0" "$rc38k" "0"
contains "38k no --role: HIMMEL_CONSOLE_RELAY=1 in LAUNCHER_ENV is passed through unchanged" "$rec38k" "HIMMEL_CONSOLE_RELAY=1"

# 38l. control: the strip matches the exact name only -- a prefix-sharing token
# (HIMMEL_CONSOLE_RELAY_X=1) survives while HIMMEL_CONSOLE_RELAY=1 beside it goes.
d38l="$tmp/c38l"; mk_stub "$d38l" 1 alive "HIMMEL-role38l"
rc38l=0
KONSOLE_CMD="$d38l/konsole" PGREP_CMD="$d38l/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d38l/locks" HEADED_ARM_PROC="$d38l/proc" \
  HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_RELAY_X=1 HIMMEL_CONSOLE_RELAY=1" \
  bash "$SCRIPT" --role console "HIMMEL-role38l" "doc38l.md" "$d38l/signal-never" "$PAST" "$d38l/log" >/dev/null 2>&1 || rc38l=$?
wait_record "$d38l" || true
rec38l="$(cat "$d38l/record" 2>/dev/null || true)"
check "38l --role console + prefix-sharing token: exit 0" "$rc38l" "0"
contains "38l --role console: HIMMEL_CONSOLE_RELAY_X=1 (prefix-sharing) is NOT stripped" "$rec38l" "HIMMEL_CONSOLE_RELAY_X=1"
not_contains "38l --role console: the exact HIMMEL_CONSOLE_RELAY=1 beside it IS stripped" "$rec38l" "HIMMEL_CONSOLE_RELAY="

# --- 39. --dry-run (HIMMEL-3140): prints the resolved argv + exits 0 BEFORE
# the signal/deadline wait loop, the claim lock, or konsole/pgrep are ever
# touched -- proving a flag is accepted must never cost a real billed launch
# (N279, N13-of-3133). Both stubs below record every invocation to their own
# counter file (distinct from mk_stub's launch-record file, which only proves
# a REAL launch happened); asserting those counters stay absent is what
# proves dry-run never reached the dedup pgrep scan or the konsole exec, not
# merely that it exited 0.
d39="$tmp/c39"
mkdir -p "$d39"
cat > "$d39/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/konsole-calls"
KONSOLE_EOF
chmod 755 "$d39/konsole"
cat > "$d39/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/pgrep-calls"
exit 1
PGREP_EOF
chmod 755 "$d39/pgrep"
out39=$(KONSOLE_CMD="$d39/konsole" PGREP_CMD="$d39/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d39/locks" \
    bash "$SCRIPT" --dry-run --role console "HIMMEL-dry39" "doc39.md" "$d39/signal-never" "$PAST" "$d39/log" 2>&1)
rc39=$?
check "39 --dry-run: exit 0" "$rc39" "0"
contains "39 --dry-run: reports the session name" "$out39" "HIMMEL-dry39"
contains "39 --dry-run: reports the doc" "$out39" "doc39.md"
contains "39 --dry-run: reports role=console" "$out39" "console"
if [ -e "$d39/konsole-calls" ]; then echo "FAIL - 39 --dry-run: konsole must NOT be invoked"; fails=$((fails+1))
else echo "ok - 39 --dry-run: konsole must NOT be invoked"; fi
if [ -e "$d39/pgrep-calls" ]; then echo "FAIL - 39 --dry-run: pgrep must NOT be invoked"; fails=$((fails+1))
else echo "ok - 39 --dry-run: pgrep must NOT be invoked"; fi
if [ -d "$d39/locks" ] && [ -n "$(ls -A "$d39/locks" 2>/dev/null)" ]; then
    echo "FAIL - 39 --dry-run: no claim lock left behind"; fails=$((fails+1))
else echo "ok - 39 --dry-run: no claim lock left behind"; fi

# --- 39b. --dry-run with a placeholder name copy-pasted from the usage
# string: refused loudly (exit 2) rather than silently "succeeding" a dry-run
# on args nobody meant to pass.
bash "$SCRIPT" --dry-run "<session-name>" "doc.md" "$tmp/signal-never" "$PAST" "$tmp/log39b" >/dev/null 2>&1
rcb39b=$?
check "39b --dry-run placeholder name '<session-name>': exit 2" "$rcb39b" "2"
bash "$SCRIPT" --dry-run "session" "doc.md" "$tmp/signal-never" "$PAST" "$tmp/log39b" >/dev/null 2>&1
rcc39b=$?
check "39b --dry-run placeholder name 'session': exit 2" "$rcc39b" "2"

# --- 40 (HIMMEL-3299). the --role console cases must not write into the
# operator's real launch-record dir. headed-arm.sh records every console arm in
# ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs, and the 38a-38l
# cases pass no HIMMELCTL_CACHE_DIR, so each run left HIMMEL-role38* rows there:
# role=console lines with a plausible context=standard autocompact=200000 that
# no real console wrote -- the only console rows in the production dataset.
# The read is of the default dir ($HOME-derived, HIMMELCTL_CACHE_DIR ignored) and
# is limited to the session-name families this suite uses, so a real leg
# launching meanwhile cannot trip it.
real_ll="${HOME:-}/.claude/himmel/launch-logs"
polluted=""
if [ -n "${HOME:-}" ] && [ -d "$real_ll" ]; then
  for f in "$real_ll"/HIMMEL-role*.log "$real_ll"/HIMMEL-9999*.log "$real_ll"/HIMMEL-red*.log; do
    [ -e "$f" ] && [ "$f" -nt "$tmp/suite-start-marker" ] && polluted="$polluted$f "
  done
fi
check "40a no HIMMEL-role*/9999*/red* launch record was written into the real launch-record dir" "$polluted" ""
# The rows did land somewhere: the suite's pinned dir. Without this a suite that
# stopped writing them at all would pass 40a.
check "40b the --role console rows landed in the suite's pinned record dir" \
  "$(grep -c '^headed-arm: role=console session=HIMMEL-role38a ' "${HIMMELCTL_CACHE_DIR:-/nonexistent}/launch-logs/HIMMEL-role38a.log" 2>/dev/null || true)" "1"

# --- 43. HIMMEL-2534: with KONSOLE_CMD unset, the konsole default resolves
# per-platform. On macOS it must point at the konsole-macos.sh shim BESIDE
# this script (not a bare "konsole", which does not exist there and would
# make every arm exit 3). Proved by running a copy of the script from a dir
# with NO shim next to it: the refusal must then name konsole-macos.sh, which
# is only possible if the default resolved to it. Not a Darwin station ->
# nothing to assert, the Linux default is unchanged and case 6 covers it.
# codex-review S11: driven through the HEADED_ARM_UNAME seam rather than a
# real `uname`, so this runs on the Linux CI runner too instead of printing a
# passing-looking skip there.
d43="$tmp/c43"; mkdir -p "$d43/bare" "$d43/lib"
cp "$SCRIPT" "$d43/bare/headed-arm.sh"
# HIMMEL-2975 made headed-arm.sh source $HERE/../lib/console-context.sh, so the
# lone copy needs that sibling to reach the konsole-default resolution at all.
# konsole-macos.sh is still deliberately absent -- that is what this case proves.
cp "$HERE/../lib/console-context.sh" "$d43/lib/console-context.sh"
mk_stub "$d43" 1 alive
out43=$(HEADED_ARM_UNAME=Darwin PGREP_CMD="$d43/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d43/locks" \
  bash "$d43/bare/headed-arm.sh" "HIMMEL-mac43" "doc43.md" "$d43/signal-never" "$PAST" "$d43/log" 2>&1)
rc43=$?
check "43 macOS default: exit 3 when the shim is absent" "$rc43" "3"
contains "43 macOS default resolves to the konsole-macos.sh shim" "$out43" "konsole-macos.sh"
not_contains "43 macOS default is never a bare 'konsole'" "$out43" "no 'konsole' on PATH"

# 43b. The Linux default is unchanged by the per-platform resolution. HIMMEL-2534
# CR fix (N346, #1122): this row used to leave KONSOLE_CMD unset and rely on
# `command -v konsole` failing, the only case in this suite to do so (every
# other konsole case pins KONSOLE_CMD explicitly). On a station that actually
# has konsole on PATH - this one - the refusal never fires and the row falls
# through into launching a REAL konsole + REAL claude session instead of
# testing anything. Pin KONSOLE_CMD at a path that cannot exist so the refusal
# is deterministic regardless of the running station, same seam every other
# konsole case already uses.
d43b="$tmp/c43b"; mkdir -p "$d43b/bare" "$d43b/lib"
cp "$SCRIPT" "$d43b/bare/headed-arm.sh"
# HIMMEL-2975 made headed-arm.sh source $HERE/../lib/console-context.sh, so the
# lone copy needs that sibling to reach the konsole-default resolution at all.
# konsole-macos.sh is still deliberately absent -- that is what this case proves.
cp "$HERE/../lib/console-context.sh" "$d43b/lib/console-context.sh"
mk_stub "$d43b" 1 alive
missing_konsole43b="$d43b/no-such-bin/konsole"
out43b=$(HEADED_ARM_UNAME=Linux KONSOLE_CMD="$missing_konsole43b" PGREP_CMD="$d43b/pgrep" HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d43b/locks" \
  bash "$d43b/bare/headed-arm.sh" "HIMMEL-mac43b" "doc43b.md" "$d43b/signal-never" "$PAST" "$d43b/log" 2>&1)
contains "43b Linux, konsole unavailable: refused, names it 'on PATH'" "$out43b" "no '$missing_konsole43b' on PATH"
not_contains "43b Linux, konsole unavailable: never mentions the macOS shim" "$out43b" "konsole-macos.sh"

# --- 41. HIMMEL-2534 (codex-review C1, CRITICAL): the post-launch visibility
# budget was 5s, sized for konsole. The macOS launcher has to bring an app up
# first (~16s cold), so a cold arm used to release the lock and report
# UNCONFIRMED while a REAL session was still on its way up - the duplicate
# -window failure the lock exists to prevent. Both budgets now derive from the
# same KONSOLE_MACOS_STARTUP_TICKS, so they cannot drift apart.
d41="$tmp/c41"; mk_stub "$d41" 1 alive "HIMMEL-budget41"
KONSOLE_MACOS_STARTUP_TICKS=250 HEADED_ARM_UNAME=Darwin KONSOLE_CMD="$d41/konsole" PGREP_CMD="$d41/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d41/locks" HEADED_ARM_PROC="$d41/proc" \
  bash "$SCRIPT" "HIMMEL-budget41" "doc41.md" "$d41/signal-never" "$PAST" "$d41/log" >/dev/null 2>&1
wait_record "$d41" || true
log41="$(cat "$d41/log" 2>/dev/null || true)"
# 250 ticks x 0.1s = 25s of launcher startup, + the standard 100 iters x 0.05s.
contains "41 macOS budget covers the launcher startup, not konsole's 5s" "$log41" "session-visibility budget 600 iters"
contains "41 macOS budget names the launcher budget it was derived from" "$log41" "250 ticks"

# 41b. A Linux arm keeps today's budget exactly - no line, no inflation.
d41b="$tmp/c41b"; mk_stub "$d41b" 1 alive "HIMMEL-budget41b"
HEADED_ARM_UNAME=Linux KONSOLE_CMD="$d41b/konsole" PGREP_CMD="$d41b/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d41b/locks" HEADED_ARM_PROC="$d41b/proc" \
  bash "$SCRIPT" "HIMMEL-budget41b" "doc41b.md" "$d41b/signal-never" "$PAST" "$d41b/log" >/dev/null 2>&1
wait_record "$d41b" || true
not_contains "41b Linux arm keeps the 5s budget (no macOS budget line)" "$(cat "$d41b/log" 2>/dev/null || true)" "session-visibility budget"

# 41c. The shim reads the SAME var in a `[ ]` test, which is always decimal,
# while the budget above is an arithmetic context, where a leading zero is
# octal. Unnormalised, 0200 gives 0200*2+100 = 356 iters here while the shim
# still waits 200 ticks - the drift the shared var exists to prevent. 10#
# makes it 200*2+100 = 500, matching the shim.
d41c="$tmp/c41c"; mk_stub "$d41c" 1 alive "HIMMEL-budget41c"
KONSOLE_MACOS_STARTUP_TICKS=0200 HEADED_ARM_UNAME=Darwin KONSOLE_CMD="$d41c/konsole" PGREP_CMD="$d41c/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d41c/locks" HEADED_ARM_PROC="$d41c/proc" \
  bash "$SCRIPT" "HIMMEL-budget41c" "doc41c.md" "$d41c/signal-never" "$PAST" "$d41c/log" >/dev/null 2>&1
wait_record "$d41c" || true
log41c="$(cat "$d41c/log" 2>/dev/null || true)"
contains "41c a leading-zero tick count is read as decimal, not octal" "$log41c" "session-visibility budget 500 iters"
not_contains "41c the octal reading (356 iters) is gone" "$log41c" "session-visibility budget 356 iters"

# 41d. 08/09 are not merely misread in an arithmetic context - they abort with
# "value too great for base", killing the arm. 10# keeps them decimal.
d41d="$tmp/c41d"; mk_stub "$d41d" 1 alive "HIMMEL-budget41d"
KONSOLE_MACOS_STARTUP_TICKS=08 HEADED_ARM_UNAME=Darwin KONSOLE_CMD="$d41d/konsole" PGREP_CMD="$d41d/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d41d/locks" HEADED_ARM_PROC="$d41d/proc" \
  bash "$SCRIPT" "HIMMEL-budget41d" "doc41d.md" "$d41d/signal-never" "$PAST" "$d41d/log" >/dev/null 2>&1
wait_record "$d41d" || true
log41d="$(cat "$d41d/log" 2>/dev/null || true)"
contains "41d an 08 tick count does not abort the arm (8*2+100 iters)" "$log41d" "session-visibility budget 116 iters"

# --- 44. HIMMEL-2534: where $PROC is absent (macOS), session_confirmed()
# must fall back to a `ps`-based comm check instead of silently answering
# "not running" for every pid. Without this the /proc walk skips every
# candidate, dedup fails OPEN into duplicate windows, and every launch lands
# UNCONFIRMED. 44a is the real dedup; 44b is its negative control, proving
# the fallback still CHECKS comm rather than believing any pid pgrep hands it.
d44="$tmp/c44"; mk_stub "$d44" 0 alive
cat > "$d44/ps" <<'PS_EOF'
#!/usr/bin/env bash
# stands in for macOS `ps -o comm= -p <pid>`, which emits the FULL executable
# path (verified on a real Mac: `ps -o comm= -p $$` -> /bin/zsh). codex-review
# I7: this stub used to echo a bare "claude", so the ${comm##*/} basename
# strip -- the one macOS-specific adaptation in the fallback -- was never
# exercised and the case passed with or without it. A full path only matches
# once the strip is applied.
echo /Users/x/.local/bin/claude
PS_EOF
chmod 755 "$d44/ps"
out44=$(PATH="$d44:$PATH" KONSOLE_CMD="$d44/konsole" PGREP_CMD="$d44/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d44/locks" HEADED_ARM_PROC="$d44/no-such-proc" \
  bash "$SCRIPT" "HIMMEL-mac44" "doc44.md" "$d44/signal-never" "$PAST" "$d44/log" 2>&1)
rc44=$?
check "44a no /proc: dedups on a real claude pid (exit 0)" "$rc44" "0"
contains "44a no /proc: announces the lossy read rather than degrading silently" "$out44" "lossy flattened pgrep scan"
[ -e "$d44/record" ] && { echo "FAIL - 44a no /proc: deduped arm must not have launched konsole"; fails=$((fails+1)); } \
  || echo "ok - 44a no /proc: konsole was never invoked"

d44b="$tmp/c44b"; mk_stub "$d44b" 0 alive
cat > "$d44b/ps" <<'PS_EOF'
#!/usr/bin/env bash
# a pgrep-matched pid whose comm is NOT claude (a launcher quoting the
# claude command, r7-codex-1's original finding) must not confirm.
echo node
PS_EOF
chmod 755 "$d44b/ps"
PATH="$d44b:$PATH" KONSOLE_CMD="$d44b/konsole" PGREP_CMD="$d44b/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d44b/locks" HEADED_ARM_PROC="$d44b/no-such-proc" \
  bash "$SCRIPT" "HIMMEL-mac44b" "doc44b.md" "$d44b/signal-never" "$PAST" "$d44b/log" >/dev/null 2>&1
wait_record "$d44b" || true
[ -e "$d44b/record" ] && echo "ok - 44b no /proc: a non-claude comm does NOT dedup (konsole launched)" \
  || { echo "FAIL - 44b no /proc: a non-claude comm wrongly deduped the arm"; fails=$((fails+1)); }

# 44c. codex-review I7: a `ps` that FAILS outright (the `|| continue` guard)
# must read as "this pid told us nothing", never as a confirmation -- so the
# arm still launches rather than being silently deduped away.
d44c="$tmp/c44c"; mk_stub "$d44c" 0 alive
cat > "$d44c/ps" <<'PS_EOF'
#!/usr/bin/env bash
exit 1
PS_EOF
chmod 755 "$d44c/ps"
PATH="$d44c:$PATH" KONSOLE_CMD="$d44c/konsole" PGREP_CMD="$d44c/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d44c/locks" HEADED_ARM_PROC="$d44c/no-such-proc" \
  bash "$SCRIPT" "HIMMEL-mac44c" "doc44c.md" "$d44c/signal-never" "$PAST" "$d44c/log" >/dev/null 2>&1
wait_record "$d44c" || true
[ -e "$d44c/record" ] && echo "ok - 44c no /proc: a failing ps does NOT confirm (konsole launched)" \
  || { echo "FAIL - 44c no /proc: a failing ps was wrongly read as a confirmation"; fails=$((fails+1)); }

# 44d. N357 (codex-2): a `ps` failing with anything other than rc 1 (pid gone)
# -- a missing or broken ps -- is a failed SCAN, not "not running": the arm
# must refuse as indeterminate (exit 9) rather than launch a possible duplicate.
d44d="$tmp/c44d"; mk_stub "$d44d" 0 alive
cat > "$d44d/ps" <<'PS_EOF'
#!/usr/bin/env bash
exit 127
PS_EOF
chmod 755 "$d44d/ps"
PATH="$d44d:$PATH" KONSOLE_CMD="$d44d/konsole" PGREP_CMD="$d44d/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d44d/locks" HEADED_ARM_PROC="$d44d/no-such-proc" \
  bash "$SCRIPT" "HIMMEL-mac44d" "doc44d.md" "$d44d/signal-never" "$PAST" "$d44d/log" >/dev/null 2>&1
rc44d=$?
check "44d no /proc: a broken ps is indeterminate (exit 9)" "$rc44d" "9"
[ -e "$d44d/record" ] && { echo "FAIL - 44d no /proc: a broken ps must not launch konsole"; fails=$((fails+1)); } \
  || echo "ok - 44d no /proc: konsole was never invoked"

# --- 42. HIMMEL-2534 (codex-review I6): the recorder branch uses util-linux
# `script -f/-c`, which BSD script rejects ("illegal option -- f"). Since
# console-kit/headed-arm-leg.sh exports HEADED_ARM_RECORDER=1 unconditionally
# for --lane claudex, a Mac must refuse with the real reason rather than fail
# as a mystery FAILED after the window is already open.
#
# The refusal is gated on having RESOLVED the shim ourselves, not on the
# platform: it speaks for the launch this script is about to build, and with
# an explicit KONSOLE_CMD the argv goes to a launcher of the caller's choosing
# (42b). Driven through a copied script with a shim stub beside it, which is
# the only way to reach the resolved-shim branch with KONSOLE_CMD unset.
d42="$tmp/c42"; mkdir -p "$d42/bare" "$d42/lib"
cp "$SCRIPT" "$d42/bare/headed-arm.sh"
# HIMMEL-2975: the lone copy needs its ../lib sibling to get this far at all.
cp "$HERE/../lib/console-context.sh" "$d42/lib/console-context.sh"
mk_stub "$d42" 1 alive
# A shim that WOULD record a launch, so "nothing was launched" is a real
# assertion rather than a missing-file tautology.
cp "$d42/konsole" "$d42/bare/konsole-macos.sh"
rc42=0
out42=$(HEADED_ARM_RECORDER=1 HEADED_ARM_UNAME=Darwin PGREP_CMD="$d42/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d42/locks" HEADED_ARM_PROC="$d42/proc" \
  bash "$d42/bare/headed-arm.sh" "HIMMEL-rec42" "doc42.md" "$d42/signal-never" "$PAST" "$d42/log" 2>&1) || rc42=$?
check "42 macOS + RECORDER=1: exit 2" "$rc42" "2"
contains "42 macOS + RECORDER=1: names BSD script as the reason" "$out42" "BSD script rejects"
[ -e "$d42/bare/record" ] && { echo "FAIL - 42 macOS + RECORDER=1: refused arm must not have launched"; fails=$((fails+1)); } \
  || echo "ok - 42 macOS + RECORDER=1: nothing was launched"
# 42c. The refusal happens AFTER the claim, and this script has no EXIT trap,
# so it must release the lock by hand like every other post-claim refusal. It
# did not: the lock survived for STALE_LOCK_SECS, and since --lane claudex
# refuses every time on a Mac, the very next arm died in the claim-retry loop
# as exit 6 "the armed successor may be lost" instead of this real reason.
[ -e "$d42/locks/HIMMEL-rec42.lock" ] && { echo "FAIL - 42c macOS + RECORDER=1: refusal must release the claim lock it holds"; fails=$((fails+1)); } \
  || echo "ok - 42c macOS + RECORDER=1: the refusal released its claim lock"

# 42b. The other half of that gate, and the one every existing --lane claudex
# case depends on: an explicit KONSOLE_CMD on a Mac is NOT refused. Those
# cases hand the `script ...` argv to a recording stub that never executes it,
# so refusing on the platform alone would turn a working launch into exit 2
# (it did: 8 cases in console-kit/test-headed-arm-leg.sh).
d42b="$tmp/c42b"; mk_stub "$d42b" 1 alive "HIMMEL-rec42b"
rc42b=0
HEADED_ARM_RECORDER=1 HEADED_ARM_UNAME=Darwin KONSOLE_CMD="$d42b/konsole" PGREP_CMD="$d42b/pgrep" \
  HEADED_ARM_REPO="$REPO" HEADED_ARM_LOCK_DIR="$d42b/locks" HEADED_ARM_PROC="$d42b/proc" \
  bash "$SCRIPT" "HIMMEL-rec42b" "doc42b.md" "$d42b/signal-never" "$PAST" "$d42b/log" >/dev/null 2>&1 || rc42b=$?
wait_record "$d42b" || true
rec42b="$(cat "$d42b/record" 2>/dev/null || true)"
check "42b macOS + RECORDER=1 + explicit KONSOLE_CMD: exit 0, not the refusal" "$rc42b" "0"
contains "42b explicit KONSOLE_CMD: the util-linux script(1) wrapper still reaches the argv" "$rec42b" "script -q -a -f $d42b/log -c"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
