#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains()/ends_with()/not_contains(), as in scripts/handover/test-headed-arm.sh
# scripts/handover/console-kit/test-headed-arm-leg.sh - suite for
# headed-arm-leg.sh (HIMMEL-2766): the versioned LEG launcher that pins the
# standard 200k context window unless the launching shell set LEG_CONTEXT=1m.
#
# Asserts:
#   1-2. usage/arg-shape: too few args -> exit 2, with and without --dry-run.
#   3-6. --dry-run argv: default (standard, no LEG_CONTEXT), LEG_CONTEXT=1m,
#        LEG_CONTEXT=1m with a Fable-family model (the wrapper does not
#        special-case Fable - documented only, headed-arm.sh's own suite
#        already covers the no-op strip), and an off-value LEG_CONTEXT
#        (e.g. "standard" or a typo) staying on standard - fail toward the
#        cheaper, already-correct default.
#   7. --dry-run reports LEG_REPO folded into HEADED_ARM_REPO.
#   8-9. full (non-dry) launch via the same KONSOLE_CMD/PGREP_CMD/
#        HEADED_ARM_PROC seams headed-arm.sh's own suite uses (the wrapper
#        execs the real headed-arm.sh, so this proves the non-dry path
#        builds the SAME argv --dry-run predicted): default -> --autocompact
#        200000, no [1m] suffix; LEG_CONTEXT=1m -> --autocompact auto, [1m]
#        suffix.
#   10. IMPL_GUARD_OK=1 reaches the konsole invocation's own process
#       environment (the leg-only env headed-arm.sh's child-env block does
#       not set).
#   11. LEG_REPO reaches headed-arm.sh's --workdir.
#   12. RED control: a mutant copy with the LEG_CONTEXT branch disabled must
#       fail case 4's assertion - proves that assertion is not vacuous.
#   13. HIMMEL-2765: bank-preflight.sh reporting SKIPPED-FLEET refuses the
#       launch (rc<>0, headed-arm.sh never invoked) - the launcher-side half
#       of the fleet-size cap; scripts/lib/test-bank-preflight.sh covers the
#       preflight's own fleet-counting logic.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only) - no .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/headed-arm-leg.sh"
HEADED_ARM="$HERE/../headed-arm.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/headed-arm-leg-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }
ends_with()    { grepq "$2" -E -e "$3\$" && echo "ok - $1" || { echo "FAIL - $1: [$2] does not end with [$3]"; fails=$((fails+1)); }; }

PAST=$(( $(date +%s) - 100 ))

# mk_launch_stubs <dir> <name> - konsole/pgrep/proc stubs, same shape
# headed-arm.sh's own suite (test-headed-arm.sh) uses: konsole records its
# FULL argv AND, filtered to just IMPL_GUARD_OK (codex-1 review finding:
# dumping the WHOLE inherited environment to disk would also write any
# exported credentials into the fixture directory), whether it was set in
# its own environment - the IMPL_GUARD_OK propagation case needs that, since
# argv alone never carries an inherited env var - touches a confirmable
# marker, then stays alive; pgrep reports a match once
# that marker exists (so the post-launch visibility poll resolves
# immediately) and "no match" before that (so the pre-launch dedup layers
# pass through). session_confirmed() also walks the matched pid's real
# /proc/<pid>/cmdline for a POSITIONAL "-n <name>" pair (r9-codex-3 in
# headed-arm.sh), so the fixture cmdline must carry it NUL-separated, not
# just a comm of "claude".
mk_launch_stubs() {
  local dir="$1" name="$2"
  mkdir -p "$dir"
  cat > "$dir/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
env | grep '^IMPL_GUARD_OK=' > "$(dirname "$0")/env-record"
: > "$(dirname "$0")/confirmable"
sleep 5
KONSOLE_EOF
  chmod 755 "$dir/konsole"
  cat > "$dir/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
[ -e "$(dirname "$0")/confirmable" ] && { echo 9001; exit 0; }
exit 1
PGREP_EOF
  chmod 755 "$dir/pgrep"
  mkdir -p "$dir/proc/9001"
  echo claude > "$dir/proc/9001/comm"
  printf 'claude\0--model\0x\0-n\0%s\0load doc and continue\0' "$name" > "$dir/proc/9001/cmdline"
}

# wait_record <dir> - the launch runs backgrounded, so the stub may not have
# written yet the instant the wrapper returns. Bounded poll, never open-ended.
wait_record() {
  local dir="$1" n=0
  while [ "$n" -lt 60 ]; do
    [ -s "$dir/record" ] && return 0
    sleep 0.05
    n=$((n+1))
  done
  return 1
}

# run_leg <stubdir> <repo> <name> [model] - invokes the wrapper for real
# (non-dry), wired at the SAME seams headed-arm.sh's own suite exposes -
# HEADED_ARM_LEG_TARGET is our own wrapper's only seam; everything else
# flows through to the real headed-arm.sh because the wrapper execs it.
# <repo> is passed as LEG_REPO (the wrapper's OWN contract), never as
# HEADED_ARM_REPO directly - codex-1 review finding: setting
# HEADED_ARM_REPO here would exercise headed-arm.sh's seam without ever
# proving the wrapper's own LEG_REPO->HEADED_ARM_REPO fold runs on the real
# (non-dry) path, which --dry-run's own report string (case 7) cannot prove
# on its own.
# PROCEED_PREFLIGHT / SKIPPED_FLEET_PREFLIGHT (HIMMEL-2765): stub
# scripts/lib/bank-preflight.sh invocations for HEADED_ARM_LEG_PREFLIGHT.
# Without this, every full-launch case below would call the REAL
# bank-preflight.sh against THIS machine's own ambient process table -
# spuriously refusing on a host that genuinely has >= HIMMEL_FLEET_CAP
# `-n HIMMEL-*` sessions running (this suite is routinely run from inside
# one). run_leg defaults to the PROCEED stub so every pre-existing case
# keeps testing what it tests; the one SKIPPED-FLEET case below points at
# the other stub explicitly.
PROCEED_PREFLIGHT="$tmp/proceed-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo PROCEED' > "$PROCEED_PREFLIGHT"
chmod 755 "$PROCEED_PREFLIGHT"
SKIPPED_FLEET_PREFLIGHT="$tmp/skipped-fleet-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo SKIPPED-FLEET' > "$SKIPPED_FLEET_PREFLIGHT"
chmod 755 "$SKIPPED_FLEET_PREFLIGHT"
# SKIPPED_BANK_PREFLIGHT (HIMMEL-2782 codex-1 CR fix): stub a bank-exhausted
# verdict so case 13b can assert headed-arm-leg.sh actually consults the
# SKIPPED-BANK token it computes (CADENCE_BANK_LANE="$LANE") instead of
# discarding it, same rationale as SKIPPED_FLEET_PREFLIGHT above.
SKIPPED_BANK_PREFLIGHT="$tmp/skipped-bank-preflight.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo SKIPPED-BANK' > "$SKIPPED_BANK_PREFLIGHT"
chmod 755 "$SKIPPED_BANK_PREFLIGHT"

run_leg() {
  local stubdir="$1" repo="$2" name="$3" model="${4:-}" preflight="${5:-$PROCEED_PREFLIGHT}"
  # codex-1 (round 7): clear any IMPL_GUARD_OK inherited from the launching
  # shell (e.g. running this suite from inside an already-armed leg) before
  # invoking the wrapper, so case 10's propagation assertion can only pass
  # because the wrapper's own `export IMPL_GUARD_OK=1` ran - not because the
  # value was already there.
  IMPL_GUARD_OK='' \
  HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
  HEADED_ARM_LEG_PREFLIGHT="$preflight" \
  KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" \
  LEG_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
    bash "$SCRIPT" "$name" "some/doc.md" "$stubdir/signal-never" "$PAST" "$stubdir/log" "$model"
}

# --- 1-2. usage/arg-shape ---------------------------------------------------
rc=0; out="$(bash "$SCRIPT" 2>&1)" || rc=$?
check "usage: no args -> exit 2" "$rc" "2"
contains "usage: no args -> usage text" "$out" "usage:"

rc=0; out="$(bash "$SCRIPT" --dry-run HIMMEL-x doc 2>&1)" || rc=$?
check "usage: --dry-run with too few positionals -> exit 2" "$rc" "2"

# codex CR fix: `--lane` as the LAST arg (no value) must not hang. Bounded by
# `timeout` so a regression fails loudly (rc=124) instead of wedging the suite.
rc=0; out="$(timeout 5 bash "$SCRIPT" --lane 2>&1)" || rc=$?
check "usage: --lane with no value -> exit 2 (not an infinite loop)" "$rc" "2"
contains "usage: --lane with no value -> usage text" "$out" "usage:"

# --- 3-6. --dry-run argv -----------------------------------------------------
# codex-1 review finding: default-context cases must not inherit an
# operator's own LEG_CONTEXT/LEG_REPO from the launching shell - explicitly
# clear both (empty is equivalent to unset for this wrapper's own checks)
# rather than relying on ambient env happening to be clean.
rc=0; out="$(LEG_CONTEXT='' LEG_REPO='' bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run default: exit 0" "$rc" "0"
ends_with "dry-run default: context=standard, no LEG_CONTEXT" "$out" "standard"
not_contains "dry-run default: no [1m] suffix in the would-exec line" "$out" "[1m]"
contains "dry-run default: reports IMPL_GUARD_OK=1" "$out" "IMPL_GUARD_OK=1"

rc=0; out="$(LEG_CONTEXT=1m bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run LEG_CONTEXT=1m: exit 0" "$rc" "0"
ends_with "dry-run LEG_CONTEXT=1m: context=1m" "$out" "1m"

rc=0; out="$(LEG_CONTEXT=1m bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-fable-5-1 2>&1)" || rc=$?
check "dry-run LEG_CONTEXT=1m, Fable model: exit 0" "$rc" "0"
ends_with "dry-run LEG_CONTEXT=1m, Fable model: wrapper still resolves context=1m (no special-case - headed-arm.sh strips the suffix, not this wrapper)" "$out" "1m"

for off in "standard" "yes" "true" "1M" ""; do
  rc=0; out="$(LEG_CONTEXT="$off" bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
  ends_with "dry-run LEG_CONTEXT=[$off]: stays on standard (fail toward the cheaper default)" "$out" "standard"
done

# --- 7. LEG_REPO folded into HEADED_ARM_REPO --------------------------------
rc=0; out="$(LEG_REPO=/some/other/repo bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: LEG_REPO folded into HEADED_ARM_REPO" "$out" "HEADED_ARM_REPO=/some/other/repo"

# --- 8-9, 11. full (non-dry) launch: proves the non-dry path builds the SAME
# argv --dry-run predicted, via the real headed-arm.sh and its own KONSOLE_CMD
# seam. ----------------------------------------------------------------------
d8="$tmp/c8"; mk_launch_stubs "$d8" "HIMMEL-9999-leg"; mkdir -p "$tmp/repo8"
rc=0
LEG_CONTEXT='' run_leg "$d8" "$tmp/repo8" "HIMMEL-9999-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d8" || true
rec8="$(cat "$d8/record" 2>/dev/null || true)"
check "full launch, default context: exit 0" "$rc" "0"
contains "full launch, default context: --autocompact 200000" "$rec8" "--autocompact 200000"
not_contains "full launch, default context: no [1m] suffix on the model" "$rec8" "claude-sonnet-5[1m]"
# HIMMEL-2782: native (no --lane) stays exactly as before - claude execed
# directly, no script(1) tty wrapper.
contains "full launch, native lane (default): execs claude directly" "$rec8" "claude --model"
not_contains "full launch, native lane (default): no script(1) tty wrapper" "$rec8" "script -q -a -f"
# codex-1/codex-2: run_leg sets LEG_REPO (never HEADED_ARM_REPO directly), so
# this now genuinely exercises the wrapper's own LEG_REPO->HEADED_ARM_REPO
# fold on the real (non-dry) path, not just headed-arm.sh's own seam.
contains "full launch: LEG_REPO folds into HEADED_ARM_REPO, reaches --workdir" "$rec8" "--workdir $tmp/repo8"

# codex-1 (round 3): a caller passing an ALREADY-SUFFIXED model
# (claude-sonnet-5[1m]) under the DEFAULT (standard) context must still end
# up unsuffixed with --autocompact 200000 - the wrapper forwards the model
# unchanged, and it is headed-arm.sh's own contract (not this wrapper's)
# that strips a literal [1m] suffix regardless of --context; assert it
# holds end-to-end through the wrapper, not just inside headed-arm.sh's own
# suite.
d8b="$tmp/c8b"; mk_launch_stubs "$d8b" "HIMMEL-7777-leg"; mkdir -p "$tmp/repo8b"
rc=0
LEG_CONTEXT='' run_leg "$d8b" "$tmp/repo8b" "HIMMEL-7777-leg" "claude-sonnet-5[1m]" >/dev/null 2>&1 || rc=$?
wait_record "$d8b" || true
rec8b="$(cat "$d8b/record" 2>/dev/null || true)"
check "full launch, default context, pre-suffixed model: exit 0" "$rc" "0"
contains "full launch, default context, pre-suffixed model: --autocompact 200000" "$rec8b" "--autocompact 200000"
not_contains "full launch, default context, pre-suffixed model: suffix stripped (headed-arm.sh's own contract)" "$rec8b" "claude-sonnet-5[1m]"

d9="$tmp/c9"; mk_launch_stubs "$d9" "HIMMEL-8888-leg"; mkdir -p "$tmp/repo9"
rc=0
LEG_CONTEXT=1m run_leg "$d9" "$tmp/repo9" "HIMMEL-8888-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d9" || true
rec9="$(cat "$d9/record" 2>/dev/null || true)"
check "full launch, LEG_CONTEXT=1m: exit 0" "$rc" "0"
contains "full launch, LEG_CONTEXT=1m: --autocompact auto" "$rec9" "--autocompact auto"
contains "full launch, LEG_CONTEXT=1m: [1m] suffix on the model" "$rec9" "claude-sonnet-5[1m]"

# --- 10. IMPL_GUARD_OK reaches the konsole invocation's own environment ----
env9="$(cat "$d9/env-record" 2>/dev/null || true)"
contains "full launch: IMPL_GUARD_OK=1 in the konsole invocation's env" "$env9" "IMPL_GUARD_OK=1"

# --- 12. RED control: disable the LEG_CONTEXT branch and confirm case 4's
# assertion (ends with "1m") now correctly fails against the mutant - proves
# it is not a vacuous check.
mutant="$tmp/mutant-headed-arm-leg.sh"
# shellcheck disable=SC2016  # single-quoted on purpose: this is a literal
# source-text match against $SCRIPT's own LEG_CONTEXT branch, not a shell
# expansion.
sed 's/if \[ "\${LEG_CONTEXT:-}" = "1m" \]; then/if false; then/' "$SCRIPT" > "$mutant"
chmod 755 "$mutant"
mrc=0
mout="$(LEG_CONTEXT=1m bash "$mutant" --dry-run HIMMEL-x some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || mrc=$?
# codex-1 (round 2) review finding: a mutant that crashed outright (empty
# output, non-zero exit) would ALSO pass a bare "does not end with 1m"
# check - that proves nothing about the LEG_CONTEXT branch. Require the
# mutant to run cleanly AND positively report "standard", not merely the
# absence of "1m".
if [ "$mrc" -eq 0 ] && grepq "$mout" -E -e 'standard$'; then
  echo "ok - RED control: mutant with the LEG_CONTEXT branch disabled runs cleanly and stays on standard, proving case 4's assertion is not vacuous"
else
  echo "FAIL - RED control: mutant (LEG_CONTEXT branch disabled) did not cleanly report standard (rc=$mrc, out=[$mout]) -- case 4's assertion would not catch a real regression"
  fails=$((fails+1))
fi

# --- 13. HIMMEL-2765: SKIPPED-FLEET refuses the launch --------------------
# Points HEADED_ARM_LEG_PREFLIGHT at the SKIPPED-FLEET stub instead of the
# PROCEED default every other full-launch case above uses. headed-arm.sh
# must never be invoked - no record file, no confirmable marker - so this
# does NOT use wait_record (which would poll out its full budget waiting for
# a write that should never happen); a bounded settle instead.
d13="$tmp/c13"; mk_launch_stubs "$d13" "HIMMEL-6666-leg"; mkdir -p "$tmp/repo13"
rc=0
run_leg "$d13" "$tmp/repo13" "HIMMEL-6666-leg" "claude-sonnet-5" "$SKIPPED_FLEET_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ "$rc" -ne 0 ]; then
  echo "ok - SKIPPED-FLEET: refuses the launch (exit $rc <> 0)"
else
  echo "FAIL - SKIPPED-FLEET: exit 0, expected a non-zero refusal"
  fails=$((fails+1))
fi
if [ -s "$d13/record" ]; then
  echo "FAIL - SKIPPED-FLEET: headed-arm.sh was invoked anyway (record file exists)"
  fails=$((fails+1))
else
  echo "ok - SKIPPED-FLEET: headed-arm.sh was never invoked (no record file)"
fi
contains "SKIPPED-FLEET: log names the fleet cap and the bypass" \
  "$(cat "$d13/log" 2>/dev/null || true)" "FLEET_CAP_OK=1"

# --- 13b (HIMMEL-2782 codex-1 CR fix): SKIPPED-BANK refuses the launch ----
# Same shape as case 13, but points HEADED_ARM_LEG_PREFLIGHT at the
# SKIPPED-BANK stub. Before the fix, headed-arm-leg.sh discarded every
# preflight_token other than SKIPPED-FLEET, so a bank-exhausted lane would
# fall through and launch anyway.
d13b="$tmp/c13b"; mk_launch_stubs "$d13b" "HIMMEL-5555-leg"; mkdir -p "$tmp/repo13b"
rc=0
run_leg "$d13b" "$tmp/repo13b" "HIMMEL-5555-leg" "claude-sonnet-5" "$SKIPPED_BANK_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ "$rc" -ne 0 ]; then
  echo "ok - SKIPPED-BANK: refuses the launch (exit $rc <> 0)"
else
  echo "FAIL - SKIPPED-BANK: exit 0, expected a non-zero refusal"
  fails=$((fails+1))
fi
if [ -s "$d13b/record" ]; then
  echo "FAIL - SKIPPED-BANK: headed-arm.sh was invoked anyway (record file exists)"
  fails=$((fails+1))
else
  echo "ok - SKIPPED-BANK: headed-arm.sh was never invoked (no record file)"
fi
contains "SKIPPED-BANK: log names the bank exhaustion" \
  "$(cat "$d13b/log" 2>/dev/null || true)" "bank exhausted"

# --- 14 (HIMMEL-2782). unknown --lane -> usage error, exit 2 ---------------
rc=0; out="$(bash "$SCRIPT" --lane bogus HIMMEL-x some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "unknown lane: exit 2" "$rc" "2"
contains "unknown lane: names the bad value" "$out" "unknown lane: bogus"

rc=0; out="$(LEG_LANE=bogus bash "$SCRIPT" HIMMEL-x some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "unknown lane via LEG_LANE: exit 2" "$rc" "2"

# --- 15 (HIMMEL-2782). --dry-run --lane claudex: resolved launcher + env,
# default model gpt-6-astra, --lane wins over LEG_LANE. ---------------------
rc=0; out="$(LEG_LANE=native LEG_REPO='' bash "$SCRIPT" --dry-run --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --lane claudex: exit 0 (flag wins over LEG_LANE=native)" "$rc" "0"
contains "dry-run --lane claudex: reports lane=claudex" "$out" "lane=claudex"
contains "dry-run --lane claudex: resolved launcher names claude-codex" "$out" "claude-codex"
contains "dry-run --lane claudex: env carries CLAUDEX_LANE_OK=1" "$out" "CLAUDEX_LANE_OK=1"
contains "dry-run --lane claudex: env carries CLAUDE_CODE_EFFORT_LEVEL=medium default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=medium"
contains "dry-run --lane claudex: MODEL defaults to gpt-6-astra" "$out" "gpt-6-astra"

rc=0; out="$(LEG_EFFORT=high bash "$SCRIPT" --dry-run --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
contains "dry-run --lane claudex: LEG_EFFORT overrides the medium default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=high"

rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run --lane claudex: an explicit model is NOT overridden" "$out" "claude-sonnet-5"
not_contains "dry-run --lane claudex: an explicit model is NOT overridden" "$out" "gpt-6-astra"

rc=0; out="$(bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run, no --lane: reports lane=native" "$out" "lane=native"
not_contains "dry-run, no --lane: no claude-codex launcher" "$out" "claude-codex"

# --- 16 (HIMMEL-2782). full (non-dry) launch, --lane claudex: proves the
# non-dry path builds the argv --dry-run predicted, via headed-arm.sh's real
# HEADED_ARM_LAUNCHER/HEADED_ARM_LAUNCHER_ENV/HEADED_ARM_RECORDER seams. A
# stub claude-codex binary on the HEADED_ARM_LEG_CLAUDEX_BIN seam stands in
# for the real scripts/claude-codex (the konsole stub never actually execs
# the recorded command, so the stub need not run - only its path needs to
# reach the recorded argv, same reasoning as headed-arm.sh's own suite).
claudex_stub="$tmp/claude-codex-stub"
# shellcheck disable=SC2016 # literal $* belongs to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$(dirname "$0")/claudex-record"' > "$claudex_stub"
chmod 755 "$claudex_stub"

d16="$tmp/c16"; mk_launch_stubs "$d16" "HIMMEL-5555-leg"; mkdir -p "$tmp/repo16"
rc=0
IMPL_GUARD_OK='' \
HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
HEADED_ARM_LEG_CLAUDEX_BIN="$claudex_stub" \
KONSOLE_CMD="$d16/konsole" PGREP_CMD="$d16/pgrep" \
LEG_REPO="$tmp/repo16" HEADED_ARM_LOCK_DIR="$d16/locks" HEADED_ARM_PROC="$d16/proc" \
  bash "$SCRIPT" --lane claudex "HIMMEL-5555-leg" "some/doc.md" "$d16/signal-never" "$PAST" "$d16/log" >/dev/null 2>&1 || rc=$?
wait_record "$d16" || true
rec16="$(cat "$d16/record" 2>/dev/null || true)"
check "full launch, --lane claudex: exit 0" "$rc" "0"
contains "full launch, --lane claudex: wrapped in script(1) with the SAME log path, appending (-a)" "$rec16" "script -q -a -f $d16/log -c"
contains "full launch, --lane claudex: the claude-codex stub path reaches the recorded argv" "$rec16" "$claudex_stub"
not_contains "full launch, --lane claudex: launcher not force-wrapped in bash (execs via its own shebang)" "$rec16" "bash $claudex_stub"
contains "full launch, --lane claudex: --model defaults to gpt-6-astra" "$rec16" "--model gpt-6-astra"
contains "full launch, --lane claudex: --autocompact 200000 (standard context ceiling)" "$rec16" "--autocompact 200000"
contains "full launch, --lane claudex: CLAUDEX_LANE_OK=1 reaches the konsole argv" "$rec16" "CLAUDEX_LANE_OK=1"
contains "full launch, --lane claudex: CLAUDE_CODE_EFFORT_LEVEL=medium reaches the konsole argv" "$rec16" "CLAUDE_CODE_EFFORT_LEVEL=medium"

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-headed-arm-leg.sh"
  exit 0
else
  echo "FAIL - test-headed-arm-leg.sh ($fails failure(s))"
  exit 1
fi
