#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains()/ends_with()/not_contains(), as in scripts/handover/test-headed-arm.sh
# scripts/handover/console-kit/test-headed-arm-leg.sh - suite for
# headed-arm-leg.sh (HIMMEL-2766/HIMMEL-2779): the versioned LEG launcher that
# pins the standard --autocompact 200000 ceiling. LEG_CONTEXT=1m is refused:
# absence of a [1m] suffix is not proof of the ceiling, because autocompact is
# the cost-driving argv lever.
#
# Asserts:
#   1-2. usage/arg-shape: too few args -> exit 2, with and without --dry-run.
#   3-6. --dry-run argv: default standard succeeds; LEG_CONTEXT=1m is refused
#        for ordinary and Fable-family models; off-values (e.g. "standard" or
#        a typo) stay on the cheaper, already-correct standard ceiling.
#   6c. HIMMEL-3133: --judge forces --profile console-judge, defaults MODEL to
#       claude-fable-5-1 on the native lane only, withholds IMPL_GUARD_OK/
#       INLINE_IMPL_OK, raises HIMMEL_READ_CLAMP_LINES, and switches the
#       preface source to docs/handover/judge-preface.md; conflicts with a
#       mismatched --profile or with --relay the same way --relay itself does.
#   7. --dry-run reports LEG_REPO folded into HEADED_ARM_REPO.
#   8-9. full (non-dry) launch via the same KONSOLE_CMD/PGREP_CMD/
#        HEADED_ARM_PROC seams headed-arm.sh's own suite uses (the wrapper
#        execs the real headed-arm.sh, so this proves the non-dry path carries
#        --autocompact 200000); LEG_CONTEXT=1m refuses before headed-arm runs.
#   10. IMPL_GUARD_OK=1, INLINE_IMPL_OK=1 and HIMMEL_CONSOLE_LEG=1 (HIMMEL-2919,
#       the marker merge-on-green's console-GO gate keys on) reach konsole's
#       own process environment (the leg-only env headed-arm.sh's child-env
#       block does not set).
#   11. LEG_REPO reaches headed-arm.sh's --workdir.
#   3b/10b (HIMMEL-3139): CONSOLE_CONTEXT is a console-only knob (the
#       CONSOLE_CONTEXT=1m 1M-context opt-in, console.sh:382) that must never
#       reach a leg - --dry-run reports the enumerated scrub set and the
#       resolved value as <unset> even with CONSOLE_CONTEXT=1m ambient in the
#       launching shell (3b); the real (non-dry) path proves it never reaches
#       the konsole child's own process environment either (10b).
#   12. RED control: a mutant headed-arm renderer with --autocompact removed is
#       refused on the full non-dry launch path before konsole runs.
#   13. HIMMEL-2765: bank-preflight.sh reporting SKIPPED-FLEET refuses the
#       launch (rc<>0, headed-arm.sh never invoked) - the launcher-side half
#       of the fleet-size cap; scripts/lib/test-bank-preflight.sh covers the
#       preflight's own fleet-counting logic.
#   24. HIMMEL-2774: FLEET_RESERVE_TTL is exported to the preflight call,
#       derived from this leg's own DEADLINE (positional $4) - a future
#       deadline reaches the preflight as (deadline - now); a past/near
#       deadline floors to 60.
#   25. HIMMEL-2774: on SKIPPED-BANK (reachable only AFTER bank-preflight.sh's
#       admission already created this leg's reservation), headed-arm-leg.sh
#       releases it. On SKIPPED-FLEET (never holds a reservation of its own -
#       see bank-preflight.sh's own refusal sub-paths), a same-name
#       reservation directory (belonging to a DIFFERENT still-pending arm in
#       the duplicate-name case) is left untouched.
#   26. HIMMEL-3155: when HANDOVER_DIR is unset, the wrapper resolves the
#       CONSOLE's own handover root (its own process/cwd, before any konsole
#       child exists) and exports it explicitly into the leg's launch env -
#       reaches konsole's own process environment (mirrors case 10's shape),
#       and an end-to-end check: a GO written by go.sh from that SAME
#       console-like cwd, then go_gate resolved from a DIFFERENT cwd
#       (simulating the leg's linked worktree) using ONLY the exported
#       HANDOVER_DIR, finds it.
#   28. HIMMEL-3270: a REAL launch (never --dry-run) appends one metadata line
#       to <himmelctl-cache>/launch-logs/<session>.log - profile / lane /
#       model / role / session / launched, no env values - and a write failure
#       or an unresolvable cache dir never blocks the launch.
#   29. HIMMEL-2534: every leg-process var this wrapper sets (LEG_PROFILE_*,
#       HIMMEL_CONSOLE_LEG, IMPL_GUARD_OK, INLINE_IMPL_OK, HIMMEL_LEAN_LEG, ...)
#       also lands in HEADED_ARM_LAUNCHER_ENV's token list - the only channel
#       that survives macOS `open -a`'s fresh-environment boundary, since a
#       plain `export` here never reaches the launched leg process on that
#       platform. A caller-preset HEADED_ARM_LAUNCHER_ENV is preserved
#       (appended to) and wins on a name clash; a leg-process value containing
#       whitespace is refused loudly (exit 12) rather than silently mis-split.
#   30. HIMMEL-2534 follow-up (console review of 7a23fcf): a caller-preset
#       HANDOVER_DIR (the normal case for a grouped console) reaches
#       launcher-env=, not only a HANDOVER_DIR this wrapper resolves itself
#       (case 26/29). The whitespace refusal from case 29c is Darwin-only
#       (HEADED_ARM_UNAME seam, mirroring headed-arm.sh's own): on Darwin it
#       still refuses with exit 12; on any other platform, the pre-HIMMEL-2534
#       behavior is restored exactly - plain `export` reaches the leg via
#       ordinary inheritance, no token is added for that one var, and a
#       stderr warning explains why.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only) - no .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/headed-arm-leg.sh"
HEADED_ARM="$HERE/../headed-arm.sh"
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh"
# The suite owns every launcher input; an ambient leg shell must not silently
# turn default-native cases into claudex cases.
unset LEG_LANE LEG_CONTEXT LEG_REPO LEG_EFFORT HEADED_ARM_LAUNCHER HEADED_ARM_LAUNCHER_ENV HEADED_ARM_RECORDER IMPL_GUARD_OK INLINE_IMPL_OK HIMMEL_CONSOLE_LEG HIMMEL_LEAN_LEG LEG_CLAUDE_BIN LEG_PROFILE LEG_PROFILE_SETTINGS LEG_PROFILE_PREFACE LEG_PROFILE_MCP_CONFIG LEG_SUPPRESS_CR_TRIGGER CR_TRIGGER_SUPPRESS HIMMEL_CONSOLE_NAME CLAUDE_PID SESSION_NAME_CMDLINE_FILE 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/headed-arm-leg-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
# HIMMEL-3186: pin every root this suite could resolve to its own temp dir, at
# SUITE level. A console-spawned leg exports the LIVE HANDOVER_DIR into this
# shell (headed-arm-leg.sh, HIMMEL-3155); the case-26 e2e below runs the real
# go.sh, which writes a GO file (merge authority, HIMMEL-2919) under whatever
# handover_root() resolves - so an inherited live root would get a fake GO for
# PR 26260 written into it. Same shield shape as the fleet-slots pin
# (bank-preflight.sh / headed-arm-leg.sh read HIMMEL_FLEET_SLOTS, then
# XDG_RUNTIME_DIR). Cases that need a different root (case 26) set their own.
export HANDOVER_DIR="$tmp/pinned-handover-root"
export HIMMEL_FLEET_SLOTS="$tmp/pinned-fleet-slots"
export XDG_RUNTIME_DIR="$tmp/pinned-xdg-runtime"
# HIMMEL-3270: every real launch appends a launch record under the himmelctl
# cache dir; pinned so this suite never writes into the operator's real
# ~/.claude/himmel (the HIMMEL-3260 lesson: a suite must not touch shared state).
export HIMMELCTL_CACHE_DIR="$tmp/pinned-himmelctl-cache"
mkdir -p "$HANDOVER_DIR" "$HIMMEL_FLEET_SLOTS" "$XDG_RUNTIME_DIR"
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
# HIMMEL-3456: only grep's rc 1 means "absent"; rc >1 is an execution error,
# which would otherwise pass every negative assertion vacuously (#1139).
not_contains() {
  local _rc=0
  grepq "$2" -F -e "$3" || _rc=$?
  case "$_rc" in
    0) echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)) ;;
    1) echo "ok - $1" ;;
    *) echo "FAIL - $1: grep itself failed (rc $_rc)"; fails=$((fails+1)) ;;
  esac
}
ends_with()    { grepq "$2" -E -e "$3\$" && echo "ok - $1" || { echo "FAIL - $1: [$2] does not end with [$3]"; fails=$((fails+1)); }; }

PAST=$(( $(date +%s) - 100 ))

# HIMMEL-2985: real (non-dry) native --profile launches now read DOC to build
# the per-leg preface, so the "some/doc.md" placeholder every other case uses
# (never opened before this ticket) must be a real, readable file wherever a
# --profile launch actually reaches that write.
some_doc="$tmp/some-doc.md"
printf '%s\n' '# fixture doc' > "$some_doc"

# mk_launch_stubs <dir> <name> - konsole/pgrep/proc stubs, same shape
# headed-arm.sh's own suite (test-headed-arm.sh) uses: konsole records its
# FULL argv AND, filtered to the three non-secret guard vars (codex-1 review
# finding: dumping the WHOLE inherited environment to disk would also write
# exported credentials into the fixture directory), whether they reached its
# own environment - the IMPL_GUARD_OK propagation case needs that, since
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
env | grep -E '^(IMPL_GUARD_OK|INLINE_IMPL_OK|HIMMEL_CONSOLE_LEG|HEADED_ARM_REQUIRED_AUTOCOMPACT|HIMMEL_LEAN_LEG|LEG_CLAUDE_BIN|LEG_PROFILE_SETTINGS|LEG_PROFILE_PREFACE|LEG_PROFILE_MCP_CONFIG|CONSOLE_CONTEXT|HANDOVER_DIR|HIMMEL_CONSOLE_NAME)=' > "$(dirname "$0")/env-record"
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
# HIMMEL-2774 codex-3 (this round): also write a `pid` file into the
# reservation it is standing in for, matching CADENCE_BANK_CALLER_PID - the
# real bank-preflight.sh now does the same, and headed-arm-leg.sh's release
# path on this refusal only deletes a reservation it can verify it owns.
SKIPPED_BANK_PREFLIGHT="$tmp/skipped-bank-preflight.sh"
# shellcheck disable=SC2016  # deliberately unexpanded: written literally, evaluated when the stub runs.
printf '%s\n' '#!/usr/bin/env bash' \
  'slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"' \
  'mkdir -p "$slots/$CADENCE_BANK_LEG" 2>/dev/null' \
  'printf "%s\n" "$CADENCE_BANK_CALLER_PID" > "$slots/$CADENCE_BANK_LEG/pid" 2>/dev/null' \
  'echo SKIPPED-BANK' > "$SKIPPED_BANK_PREFLIGHT"
chmod 755 "$SKIPPED_BANK_PREFLIGHT"

# RUN_LEG_ARGS (HIMMEL-3267): the leading profile flags. Default is a REAL
# profile - a launch that no longer exists unprofiled is the shape a console
# dispatches - and only a case whose subject IS the unprofiled path sets
# RUN_LEG_ARGS=--no-profile. Set-but-empty deliberately means "no flag at all"
# (case 27b, the refusal).
RUN_LEG_DEFAULT_ARGS="--profile leg-impl"
# shellcheck disable=SC2086  # deliberately word-split: zero, one or several flags.
run_leg() {
  local stubdir="$1" repo="$2" name="$3" model="${4:-}" preflight="${5:-$PROCEED_PREFLIGHT}"
  # codex-1 (round 7): clear any IMPL_GUARD_OK inherited from the launching
  # shell (e.g. running this suite from inside an already-armed leg) before
  # invoking the wrapper, so case 10's propagation assertion can only pass
  # because the wrapper's own `export IMPL_GUARD_OK=1` ran - not because the
  # value was already there. HIMMEL_CONSOLE_LEG likewise (HIMMEL-2919).
  IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' \
  HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
  HEADED_ARM_LEG_PREFLIGHT="$preflight" \
  KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" \
  LEG_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
    bash "$SCRIPT" ${RUN_LEG_ARGS-$RUN_LEG_DEFAULT_ARGS} "$name" "$some_doc" "$stubdir/signal-never" "$PAST" "$stubdir/log" "$model"
}

# --- 1-2. usage/arg-shape ---------------------------------------------------
rc=0; out="$(bash "$SCRIPT" 2>&1)" || rc=$?
check "usage: no args -> exit 2" "$rc" "2"
contains "usage: no args -> usage text" "$out" "usage:"

rc=0; out="$(bash "$SCRIPT" --dry-run HIMMEL-x doc 2>&1)" || rc=$?
check "usage: --dry-run with too few positionals -> exit 2" "$rc" "2"

# codex CR fix: `--lane` as the LAST arg (no value) must not hang. Bounded by
# `timeout` so a regression fails loudly (rc=124) instead of wedging the suite.
# Hang-guard: with no GNU timeout/gtimeout the row SKIPs rather than run unbounded.
if [ -n "$_TIMEOUT_BIN" ]; then
    rc=0; out="$("$_TIMEOUT_BIN" 5 bash "$SCRIPT" --lane 2>&1)" || rc=$?
    check "usage: --lane with no value -> exit 2 (not an infinite loop)" "$rc" "2"
    contains "usage: --lane with no value -> usage text" "$out" "usage:"
else
    echo "SKIP - usage: --lane with no value (hang-guard row needs GNU timeout/gtimeout)"
fi

# --- 3-6. --dry-run argv -----------------------------------------------------
# codex-1 review finding: default-context cases must not inherit an
# operator's own LEG_CONTEXT/LEG_REPO from the launching shell - explicitly
# clear both (empty is equivalent to unset for this wrapper's own checks)
# rather than relying on ambient env happening to be clean.
rc=0; out="$(LEG_CONTEXT='' LEG_REPO='' bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run default: exit 0" "$rc" "0"
ends_with "dry-run default: context=standard, no LEG_CONTEXT" "$out" "standard"
not_contains "dry-run default: no [1m] suffix in the would-exec line" "$out" "[1m]"
contains "dry-run default: reports IMPL_GUARD_OK=1" "$out" "IMPL_GUARD_OK=1"
contains "dry-run default: reports INLINE_IMPL_OK=1" "$out" "INLINE_IMPL_OK=1"
contains "dry-run default: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
not_contains "dry-run default: no HIMMEL_CONSOLE_RELAY without --relay" "$out" "HIMMEL_CONSOLE_RELAY"
contains "dry-run default: scrub list names CONSOLE_CONTEXT" "$out" "scrub=CONSOLE_CONTEXT"
contains "dry-run default: no console-name source -> HIMMEL_CONSOLE_NAME absent" "$out" "HIMMEL_CONSOLE_NAME=<unset>"

# HIMMEL-3139: a console armed with CONSOLE_CONTEXT=1m in its own environ (the
# mandatory opt-in for a 1M successor, console.sh:382) must not forward that
# console-only knob into a leg it arms. Ambient CONSOLE_CONTEXT=1m in THIS
# suite's own launching shell must not silently satisfy the assertion either -
# not_contains on a value the wrapper never receives proves nothing - so this
# sets it explicitly on the invocation, same shape as the LEG_CONTEXT=1m case
# below. Enumerates the expected scrub set explicitly (not merely "non-empty")
# so a future console-only knob added without a matching scrub here fails
# this exact assertion, not a vaguer one.
rc=0; out="$(CONSOLE_CONTEXT=1m LEG_CONTEXT='' LEG_REPO='' bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, ambient CONSOLE_CONTEXT=1m: exit 0 (a leg is unaffected by it)" "$rc" "0"
contains "dry-run, ambient CONSOLE_CONTEXT=1m: scrubbed to <unset> in the wrapper's own env" "$out" "scrub=CONSOLE_CONTEXT CONSOLE_CONTEXT=<unset>"
not_contains "dry-run, ambient CONSOLE_CONTEXT=1m: never reported as still set" "$out" "CONSOLE_CONTEXT=1m"

# --- HIMMEL-3435: HIMMEL_CONSOLE_NAME resolution (--console, launching
# shell's HIMMEL_CONSOLE_NAME, this process's own session name via
# session-name.sh), charset refusal, and precedence. -------------------------

# Source 1: --console flag.
rc=0; out="$(bash "$SCRIPT" --dry-run --console opsdesk --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run --console opsdesk: exit 0" "$rc" "0"
contains "dry-run --console opsdesk: reports HIMMEL_CONSOLE_NAME=opsdesk" "$out" "HIMMEL_CONSOLE_NAME=opsdesk"

# Source 2: the launching shell's own HIMMEL_CONSOLE_NAME, no --console.
rc=0; out="$(HIMMEL_CONSOLE_NAME=ambient-console bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, ambient HIMMEL_CONSOLE_NAME: exit 0" "$rc" "0"
contains "dry-run, ambient HIMMEL_CONSOLE_NAME: reports it" "$out" "HIMMEL_CONSOLE_NAME=ambient-console"

# --console wins over an ambient HIMMEL_CONSOLE_NAME (source 1 before source 2).
rc=0; out="$(HIMMEL_CONSOLE_NAME=ambient-console bash "$SCRIPT" --dry-run --console flag-console --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, --console + ambient HIMMEL_CONSOLE_NAME: exit 0" "$rc" "0"
contains "dry-run, --console + ambient HIMMEL_CONSOLE_NAME: flag wins" "$out" "HIMMEL_CONSOLE_NAME=flag-console"
not_contains "dry-run, --console + ambient HIMMEL_CONSOLE_NAME: ambient value dropped" "$out" "HIMMEL_CONSOLE_NAME=ambient-console"

# Source 3: this process's own Claude session name, via session-name.sh's
# CLAUDE_PID + SESSION_NAME_CMDLINE_FILE test seam - only consulted when
# neither --console nor the launching shell's HIMMEL_CONSOLE_NAME yielded one.
csn_fixture="$tmp/session-name-cmdline"
printf 'claude\0--model\0x\0-n\0detected-console\0load doc and continue\0' > "$csn_fixture"
rc=0; out="$(CLAUDE_PID=4242 SESSION_NAME_CMDLINE_FILE="$csn_fixture" bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, own session name via CLAUDE_PID/cmdline: exit 0" "$rc" "0"
contains "dry-run, own session name via CLAUDE_PID/cmdline: reports it" "$out" "HIMMEL_CONSOLE_NAME=detected-console"

# --console still wins over the auto-detected session name.
rc=0; out="$(CLAUDE_PID=4242 SESSION_NAME_CMDLINE_FILE="$csn_fixture" bash "$SCRIPT" --dry-run --console flag-console --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run, --console + own session name: flag wins" "$out" "HIMMEL_CONSOLE_NAME=flag-console"
not_contains "dry-run, --console + own session name: auto-detected value dropped" "$out" "HIMMEL_CONSOLE_NAME=detected-console"

# --console: a bad charset REFUSES the launch outright (explicit user input,
# same stance as --lane/--profile) - unlike sources 2/3 below.
rc=0; out="$(bash "$SCRIPT" --dry-run --console 'bad name' --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "--console with a bad charset: exit 2" "$rc" "2"
contains "--console with a bad charset: usage text" "$out" "usage:"
contains "--console with a bad charset: names the bad value" "$out" "bad name"

# Ambient HIMMEL_CONSOLE_NAME with a bad charset: NOT a hard refusal - treated
# as if that source yielded nothing (best-effort routing, not load-bearing),
# so the launch still succeeds and HIMMEL_CONSOLE_NAME is absent.
rc=0; out="$(HIMMEL_CONSOLE_NAME='bad/name' bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, ambient HIMMEL_CONSOLE_NAME with a bad charset: exit 0 (not refused)" "$rc" "0"
contains "dry-run, ambient HIMMEL_CONSOLE_NAME with a bad charset: treated as no source" "$out" "HIMMEL_CONSOLE_NAME=<unset>"

# The auto-detected session name is charset-checked too: session-name.sh's own
# validation would accept a colon (it only rejects '/', '..', whitespace and
# glob metacharacters), but this narrower charset must still reject it and
# fall through to "no source" rather than exporting an unsafe value.
csn_fixture_colon="$tmp/session-name-cmdline-colon"
printf 'claude\0--model\0x\0-n\0bad:name\0load doc and continue\0' > "$csn_fixture_colon"
rc=0; out="$(CLAUDE_PID=4242 SESSION_NAME_CMDLINE_FILE="$csn_fixture_colon" bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run, own session name with a bad charset: exit 0 (not refused)" "$rc" "0"
contains "dry-run, own session name with a bad charset: treated as no source" "$out" "HIMMEL_CONSOLE_NAME=<unset>"

# HIMMEL-3456: "." and ".." pass the charset but are path components once
# merge-block-alert.sh joins the name into the console inbox path. Both
# validation sites refuse them, each with its own stance (flag = exit 2,
# ambient = no source).
for dots in . ..; do
  rc=0; out="$(bash "$SCRIPT" --dry-run --console "$dots" --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
  check "--console [$dots]: exit 2" "$rc" "2"
  contains "--console [$dots]: names the bad value" "$out" "got: $dots"
  rc=0; out="$(HIMMEL_CONSOLE_NAME="$dots" bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
  check "dry-run, ambient HIMMEL_CONSOLE_NAME=[$dots]: exit 0 (not refused)" "$rc" "0"
  contains "dry-run, ambient HIMMEL_CONSOLE_NAME=[$dots]: treated as no source" "$out" "HIMMEL_CONSOLE_NAME=<unset>"
done

# HIMMEL-3456: a caller-preset HEADED_ARM_LAUNCHER_ENV is appended to, never
# replaced (leg_propagate_env), and headed-arm.sh hands its tokens to the leg
# on every lane - so a scrubbed var carried there would come back past the
# `unset`. The scrub strips it from the token list too; siblings survive.
for lane in native claudex; do
  out="$(HEADED_ARM_LAUNCHER_ENV="CONSOLE_CONTEXT=1m KEEP_ME=1" bash "$SCRIPT" --dry-run --lane "$lane" --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)"
  lenv="$(printf '%s\n' "$out" | grep '^headed-arm-leg: lane=')"
  contains "--lane $lane, caller-preset launcher-env: dry-run reached the lane line" "$lenv" "launcher-env="
  not_contains "--lane $lane, caller-preset launcher-env: scrubbed CONSOLE_CONTEXT stripped" "$lenv" "CONSOLE_CONTEXT="
  contains "--lane $lane, caller-preset launcher-env: sibling token kept" "$lenv" "KEEP_ME=1"
done

# HIMMEL-3456 (CodeRabbit on #1140): leg_propagate_env lets a caller-preset
# token win on a name clash, so a preset HIMMEL_CONSOLE_NAME=.. used to reach
# the leg unvalidated - past a valid --console, or with no source at all. The
# launcher drops the preset token and propagates only the name it resolved.
out="$(HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_NAME=.. KEEP_ME=1" bash "$SCRIPT" --dry-run --console good-console --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)"
lenv="$(printf '%s\n' "$out" | grep '^headed-arm-leg: lane=')"
contains "preset HIMMEL_CONSOLE_NAME token + --console: the validated name propagates" "$lenv" "HIMMEL_CONSOLE_NAME=good-console"
not_contains "preset HIMMEL_CONSOLE_NAME token + --console: the preset token is dropped" "$lenv" "HIMMEL_CONSOLE_NAME=.."
contains "preset HIMMEL_CONSOLE_NAME token + --console: sibling token kept" "$lenv" "KEEP_ME=1"
out="$(HEADED_ARM_LAUNCHER_ENV="HIMMEL_CONSOLE_NAME=.. KEEP_ME=1" bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)"
lenv="$(printf '%s\n' "$out" | grep '^headed-arm-leg: lane=')"
not_contains "preset HIMMEL_CONSOLE_NAME token, no source: nothing propagates" "$lenv" "HIMMEL_CONSOLE_NAME="
contains "preset HIMMEL_CONSOLE_NAME token, no source: sibling token kept" "$lenv" "KEEP_ME=1"

# HIMMEL-3456: only grep's rc 1 means "absent" - an rc >1 is an execution
# error and must fail the assertion, never pass it vacuously (#1139's fix to
# the same helper in test-headed-arm.sh).
# shellcheck disable=SC2317,SC2329  # grep() is invoked indirectly, through grepq
nc_probe=$( grep() { return 2; }; not_contains "probe" "x" "y" )
check "not_contains reports a grep error as a failure, not as absence" "$nc_probe" "FAIL - probe: grep itself failed (rc 2)"

rc=0; out="$(LEG_CONTEXT=1m bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run LEG_CONTEXT=1m: refused with exit 2" "$rc" "2"
contains "dry-run LEG_CONTEXT=1m: refusal names the required ceiling" "$out" "--autocompact 200000"
contains "dry-run LEG_CONTEXT=1m: refusal points to the standard leg setting" "$out" "unset LEG_CONTEXT"

rc=0; out="$(LEG_CONTEXT=1m bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-fable-5-1 2>&1)" || rc=$?
check "dry-run LEG_CONTEXT=1m, Fable model: refused with exit 2" "$rc" "2"
contains "dry-run LEG_CONTEXT=1m, Fable model: still checks autocompact, not the model suffix" "$out" "--autocompact 200000"

for off in "standard" "yes" "true" "1M" ""; do
  rc=0; out="$(LEG_CONTEXT="$off" bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
  ends_with "dry-run LEG_CONTEXT=[$off]: stays on standard (fail toward the cheaper default)" "$out" "standard"
done

# --- 6b (HIMMEL-2975). --relay: forces the console-relay profile + the
# HIMMEL_CONSOLE_RELAY env marker Guard C (inbox-send.sh) and the Task 26
# write-deny hook key off. No value; defaults MODEL to claude-sonnet-5 when
# omitted; an explicit --profile (flag or LEG_PROFILE) other than
# console-relay conflicts and refuses.
rc=0; out="$(bash "$SCRIPT" --dry-run --relay HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --relay: exit 0" "$rc" "0"
contains "dry-run --relay: reports HIMMEL_CONSOLE_RELAY=1" "$out" "HIMMEL_CONSOLE_RELAY=1"
contains "dry-run --relay: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
contains "dry-run --relay: forces profile=console-relay" "$out" "profile=console-relay"
contains "dry-run --relay: defaults the model to claude-sonnet-5" "$out" "claude-sonnet-5"

rc=0; out="$(bash "$SCRIPT" --dry-run --relay --profile leg-impl HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --relay --profile leg-impl: refused with exit 2" "$rc" "2"
contains "dry-run --relay --profile leg-impl: refusal names console-relay" "$out" "console-relay"

rc=0; out="$(LEG_PROFILE=leg-impl bash "$SCRIPT" --dry-run --relay HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --relay, LEG_PROFILE=leg-impl: refused with exit 2" "$rc" "2"
contains "dry-run --relay, LEG_PROFILE=leg-impl: refusal names console-relay" "$out" "console-relay"

# --relay with an explicit model: explicit wins over the sonnet default. The
# existing Opus tier gate then applies exactly as today; some/doc.md carries
# no Tier line, so this refuses with exit 2 - proving the model reached the
# tier gate unchanged rather than being silently downgraded to sonnet first.
rc=0; out="$(bash "$SCRIPT" --dry-run --relay HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "dry-run --relay, explicit opus model: tier gate still applies (exit 2)" "$rc" "2"
contains "dry-run --relay, explicit opus model: refusal is the tier gate" "$out" "Tier"

# --- 6c (HIMMEL-3133). --judge: forces the console-judge profile + the same
# HIMMEL_CONSOLE_LEG=1 marker every leg carries (design §3.2, "the judge is a
# leg" - Guard E refuses a judge's own GO identically, no separate marker).
# Defaults MODEL to claude-fable-5-1 on the native lane only; withholds
# IMPL_GUARD_OK/INLINE_IMPL_OK (a judge does not implement); raises
# HIMMEL_READ_CLAMP_LINES; and switches the preface source to
# docs/handover/judge-preface.md. The Fable default still has to clear the
# existing tier gate, so this uses a fixture doc carrying a Tier line rather
# than some/doc.md.
doc_tier_judge="$tmp/tier-doc-judge.md"
printf '%s\n' '# fixture brief' '> **Tier:** fable — design: judge adjudication' > "$doc_tier_judge"

rc=0; out="$(env -u IMPL_GUARD_OK -u INLINE_IMPL_OK bash "$SCRIPT" --dry-run --judge HIMMEL-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --judge: exit 0" "$rc" "0"
contains "dry-run --judge: reports HIMMEL_CONSOLE_LEG=1" "$out" "HIMMEL_CONSOLE_LEG=1"
contains "dry-run --judge: forces profile=console-judge" "$out" "profile=console-judge"
contains "dry-run --judge: defaults the model to claude-fable-5-1" "$out" "claude-fable-5-1"
contains "dry-run --judge: withholds IMPL_GUARD_OK" "$out" "IMPL_GUARD_OK=<unset>"
contains "dry-run --judge: withholds INLINE_IMPL_OK" "$out" "INLINE_IMPL_OK=<unset>"
contains "dry-run --judge: raises the read-clamp line limit" "$out" "read-clamp-lines=4000"
contains "dry-run --judge: preface source is judge-preface.md" "$out" "docs/handover/judge-preface.md"

# --judge --lane claudex: the Fable default is scoped to the native lane only
# (HIMMEL-3133 explicitly leaves composing --judge with claudex out of scope)
# - claudex keeps its own gpt-6-astra default untouched, and some/doc.md (no
# Tier line) proves that default never reached the Opus/Fable tier gate.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --judge --lane claudex: exit 0" "$rc" "0"
not_contains "dry-run --judge --lane claudex: does not force claude-fable-5-1" "$out" "claude-fable-5-1"
contains "dry-run --judge --lane claudex: still forces profile=console-judge" "$out" "profile=console-judge"

# --judge conflicts with an explicit non-matching --profile, same shape as --relay.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge --profile leg-impl HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --judge --profile leg-impl: refused with exit 2" "$rc" "2"
contains "dry-run --judge --profile leg-impl: refusal names console-judge" "$out" "console-judge"

# --judge --relay together: each flag's own conflict check refuses in turn
# (RELAY forces console-relay first; JUDGE then sees a mismatched non-empty
# PROFILE and refuses) - no dedicated mutual-exclusion guard needed.
rc=0; out="$(bash "$SCRIPT" --dry-run --judge --relay HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --judge --relay: refused with exit 2" "$rc" "2"
contains "dry-run --judge --relay: refusal names console-judge" "$out" "console-judge"

# --- 7. LEG_REPO folded into HEADED_ARM_REPO --------------------------------
rc=0; out="$(LEG_REPO=/some/other/repo bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: LEG_REPO folded into HEADED_ARM_REPO" "$out" "HEADED_ARM_REPO=/some/other/repo"

# --- 7b (HIMMEL-3141). LEG_SUPPRESS_CR_TRIGGER folded into CR_TRIGGER_SUPPRESS
rc=0; out="$(LEG_SUPPRESS_CR_TRIGGER=1 bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: LEG_SUPPRESS_CR_TRIGGER folded into CR_TRIGGER_SUPPRESS" "$out" "CR_TRIGGER_SUPPRESS=1"

# --- 7c (HIMMEL-3141). unset LEG_SUPPRESS_CR_TRIGGER -> stays <unset> (default ON)
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run: unset LEG_SUPPRESS_CR_TRIGGER leaves CR_TRIGGER_SUPPRESS unset (default ON)" "$out" "CR_TRIGGER_SUPPRESS=<unset>"

# --- 8-9, 11. full (non-dry) launch: proves the non-dry path builds the SAME
# argv --dry-run predicted, via the real headed-arm.sh and its own KONSOLE_CMD
# seam. ----------------------------------------------------------------------
d8="$tmp/c8"; mk_launch_stubs "$d8" "HIMMEL-9999-leg"; mkdir -p "$tmp/repo8"
rc=0
LEG_CONTEXT='' RUN_LEG_ARGS=--no-profile run_leg "$d8" "$tmp/repo8" "HIMMEL-9999-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
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
LEG_CONTEXT='' RUN_LEG_ARGS=--no-profile run_leg "$d8b" "$tmp/repo8b" "HIMMEL-7777-leg" "claude-sonnet-5[1m]" >/dev/null 2>&1 || rc=$?
wait_record "$d8b" || true
rec8b="$(cat "$d8b/record" 2>/dev/null || true)"
check "full launch, default context, pre-suffixed model: exit 0" "$rc" "0"
contains "full launch, default context, pre-suffixed model: --autocompact 200000" "$rec8b" "--autocompact 200000"
not_contains "full launch, default context, pre-suffixed model: suffix stripped (headed-arm.sh's own contract)" "$rec8b" "claude-sonnet-5[1m]"

d9="$tmp/c9"; mk_launch_stubs "$d9" "HIMMEL-8888-leg"; mkdir -p "$tmp/repo9"
rc=0
LEG_CONTEXT=1m RUN_LEG_ARGS=--no-profile run_leg "$d9" "$tmp/repo9" "HIMMEL-8888-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
rec9="$(cat "$d9/record" 2>/dev/null || true)"
check "full launch, LEG_CONTEXT=1m: refused with exit 2" "$rc" "2"
check "full launch, LEG_CONTEXT=1m: headed-arm was never invoked" "$rec9" ""

# --- 10. IMPL_GUARD_OK reaches the konsole invocation's own environment ----
env8="$(cat "$d8/env-record" 2>/dev/null || true)"
contains "full launch: IMPL_GUARD_OK=1 in the konsole invocation's env" "$env8" "IMPL_GUARD_OK=1"
contains "full launch: INLINE_IMPL_OK=1 in the konsole invocation's env" "$env8" "INLINE_IMPL_OK=1"
contains "full launch: HIMMEL_CONSOLE_LEG=1 in the konsole invocation's env" "$env8" "HIMMEL_CONSOLE_LEG=1"
not_contains "full launch: internal autocompact requirement does not leak into the launched leg" "$env8" "HEADED_ARM_REQUIRED_AUTOCOMPACT="

# --- 10b (HIMMEL-3139). Asserted absence on the REAL (non-dry) path: a
# console armed with CONSOLE_CONTEXT=1m in its own environ must not forward
# it into the konsole child's own process environment when it arms a leg -
# the live symptom this ticket fixes. Mirrors case 10's shape (env-record,
# not argv - CONSOLE_CONTEXT never appears in argv either way, only in
# inherited env) so the control is on the same deterministic seam headed-arm's
# own suite already trusts, not a live /proc read.
d10b="$tmp/c10b"; mk_launch_stubs "$d10b" "HIMMEL-3139-leg"; mkdir -p "$tmp/repo10b"
rc=0
CONSOLE_CONTEXT=1m LEG_CONTEXT='' RUN_LEG_ARGS=--no-profile run_leg "$d10b" "$tmp/repo10b" "HIMMEL-3139-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d10b" || true
env10b="$(cat "$d10b/env-record" 2>/dev/null || true)"
check "full launch, ambient CONSOLE_CONTEXT=1m: exit 0 (a leg is unaffected by it)" "$rc" "0"
not_contains "full launch, ambient CONSOLE_CONTEXT=1m: absent from the konsole invocation's own env" "$env10b" "CONSOLE_CONTEXT="

# --- 12. RED control: mutate the ACTUAL headed-arm launch renderer to drop
# --autocompact, then drive the wrapper's full non-dry path. The shared argv
# guard must refuse with exit 2 before konsole runs; this proves the policy is
# enforced on resolved launch argv rather than only on the wrapper's dry-run
# context report.
mutantdir="$tmp/mutant-headed-arm"
mkdir -p "$mutantdir/scripts/handover" "$mutantdir/scripts/lib"
mutant="$mutantdir/scripts/handover/headed-arm.sh"
# shellcheck disable=SC2016  # literal source-text mutation, not shell expansion
sed 's/ --autocompact "$AUTOCOMPACT"//' "$HEADED_ARM" > "$mutant"
cp "$HERE/../../lib/console-context.sh" "$mutantdir/scripts/lib/console-context.sh"
chmod 755 "$mutant"
d12="$tmp/c12"; mk_launch_stubs "$d12" "HIMMEL-4444-leg"; mkdir -p "$tmp/repo12"
mrc=0
mout="$(IMPL_GUARD_OK='' HEADED_ARM_LEG_TARGET="$mutant" HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$d12/konsole" PGREP_CMD="$d12/pgrep" LEG_REPO="$tmp/repo12" \
  HEADED_ARM_LOCK_DIR="$d12/locks" HEADED_ARM_PROC="$d12/proc" \
  bash "$SCRIPT" --no-profile "HIMMEL-4444-leg" "some/doc.md" "$d12/signal-never" "$PAST" "$d12/log" "claude-sonnet-5" 2>&1)" || mrc=$?
check "RED control: renderer without --autocompact is refused on full launch path" "$mrc" "2"
contains "RED control: refusal names the missing resolved argv pair" "$mout" "resolved argv lacks --autocompact 200000"
check "RED control: konsole was never invoked" "$(cat "$d12/record" 2>/dev/null || true)" ""

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
HIMMEL_FLEET_SLOTS="$d13b/fleet-slots" run_leg "$d13b" "$tmp/repo13b" "HIMMEL-5555-leg" "claude-sonnet-5" "$SKIPPED_BANK_PREFLIGHT" >/dev/null 2>&1 || rc=$?
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
rc=0; out="$(LEG_LANE=native LEG_REPO='' bash "$SCRIPT" --dry-run --no-profile --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "dry-run --lane claudex: exit 0 (flag wins over LEG_LANE=native)" "$rc" "0"
contains "dry-run --lane claudex: reports lane=claudex" "$out" "lane=claudex"
contains "dry-run --lane claudex: resolved launcher names claude-codex" "$out" "claude-codex"
contains "dry-run --lane claudex: env carries CLAUDEX_LANE_OK=1" "$out" "CLAUDEX_LANE_OK=1"
contains "dry-run --lane claudex: env carries CLAUDE_CODE_EFFORT_LEVEL=medium default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=medium"
contains "dry-run --lane claudex: MODEL defaults to gpt-6-astra" "$out" "gpt-6-astra"

rc=0; out="$(LEG_EFFORT=high bash "$SCRIPT" --dry-run --no-profile --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
contains "dry-run --lane claudex: LEG_EFFORT overrides the medium default" "$out" "CLAUDE_CODE_EFFORT_LEVEL=high"

rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
contains "dry-run --lane claudex: an explicit model is NOT overridden" "$out" "claude-sonnet-5"
not_contains "dry-run --lane claudex: an explicit model is NOT overridden" "$out" "gpt-6-astra"

rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
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
  bash "$SCRIPT" --lane claudex --no-profile "HIMMEL-5555-leg" "some/doc.md" "$d16/signal-never" "$PAST" "$d16/log" >/dev/null 2>&1 || rc=$?
wait_record "$d16" || true
rec16="$(cat "$d16/record" 2>/dev/null || true)"
check "full launch, --lane claudex: exit 0" "$rc" "0"
contains "full launch, --lane claudex: wrapped in script(1) with the SAME log path, appending (-a)" "$rec16" "script -q -a -f $d16/log -c"
contains "full launch, --lane claudex: the preface shim reaches the recorded argv" "$rec16" "leg-claude-launcher.sh"
contains "full launch, --lane claudex: the shim retains the claudex backend" \
  "$(cat "$d16/env-record" 2>/dev/null || true)" "LEG_CLAUDE_BIN=$claudex_stub"
not_contains "full launch, --lane claudex: launcher not force-wrapped in bash (execs via its own shebang)" "$rec16" "bash $claudex_stub"
contains "full launch, --lane claudex: --model defaults to gpt-6-astra" "$rec16" "--model gpt-6-astra"
contains "full launch, --lane claudex: --autocompact 200000 (standard context ceiling)" "$rec16" "--autocompact 200000"
contains "full launch, --lane claudex: CLAUDEX_LANE_OK=1 reaches the konsole argv" "$rec16" "CLAUDEX_LANE_OK=1"
contains "full launch, --lane claudex: CLAUDE_CODE_EFFORT_LEVEL=medium reaches the konsole argv" "$rec16" "CLAUDE_CODE_EFFORT_LEVEL=medium"

# --- 17 (HIMMEL-2830). --profile <name>: a plugin profile + the standing leg
# preface, applied WITHOUT editing headed-arm.sh. headed-arm.sh builds a fixed
# claude argv with no pass-through for extra flags, so the only seam is its
# launcher binary: --profile points HEADED_ARM_LAUNCHER at
# scripts/lanes/leg-claude-launcher.sh, which prepends --settings and
# --append-system-prompt-file and execs the real claude. Three things must
# hold, and each is a separate case below: the child really does get both
# flags; omitting --profile changes nothing; and --profile on --lane claudex
# composes both launchers rather than silently losing one.

# 17a. The shim itself, driven directly: this is the only place the CHILD
# cmdline is observable (the konsole stub records the launch command but never
# execs it), so it is where "the child carries both flags" is actually proven.
SHIM="$HERE/../../lanes/leg-claude-launcher.sh"
shim_rec="$tmp/shim-claude"
# shellcheck disable=SC2016 # literal $* belongs to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$(dirname "$0")/shim-record"' > "$shim_rec"
chmod 755 "$shim_rec"
: > "$tmp/settings.json"
: > "$tmp/preface.md"
rc=0
LEG_CLAUDE_BIN="$shim_rec" LEG_PROFILE_SETTINGS="$tmp/settings.json" LEG_PROFILE_PREFACE="$tmp/preface.md" \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg "load doc" || rc=$?
shimout="$(cat "$tmp/shim-record" 2>/dev/null || true)"
check "shim: exit 0" "$rc" "0"
check "shim: prepends both flags and preserves the rest of argv in order" "$shimout" \
  "--settings $tmp/settings.json --append-system-prompt-file $tmp/preface.md --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg load doc"

# The transparency control: with no profile env set the shim must be a
# pass-through, byte for byte. A shim that reordered or dropped --model or
# --autocompact here would defeat the ceiling guard the rest of this suite
# exists to enforce.
rm -f "$tmp/shim-record"
rc=0
LEG_CLAUDE_BIN="$shim_rec" LEG_PROFILE_SETTINGS='' LEG_PROFILE_PREFACE='' \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg "load doc" || rc=$?
check "shim: no profile env -> argv byte-identical (transparent exec)" \
  "$(cat "$tmp/shim-record" 2>/dev/null || true)" \
  "--model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg load doc"

# Fail closed: a settings path that does not exist must refuse, not launch a
# leg with the full plugin roster while the log says it was profiled.
rc=0
out="$(LEG_CLAUDE_BIN="$shim_rec" LEG_PROFILE_SETTINGS="$tmp/no-such-settings.json" bash "$SHIM" --model x 2>&1)" || rc=$?
check "shim: a missing settings file refuses with exit 2" "$rc" "2"
contains "shim: refusal names the missing file" "$out" "$tmp/no-such-settings.json"

# 17b. Full (non-dry) launch with --profile: the shim is what headed-arm.sh
# renders as the launcher, the resolved settings JSON is written next to the
# launch log, and HIMMEL_LEAN_LEG=1 reaches the launched process's own
# environment (that is what silences the advisory SessionStart hooks).
d17="$tmp/c17"; mk_launch_stubs "$d17" "HIMMEL-3333-leg"; mkdir -p "$tmp/repo17"
rc=0
IMPL_GUARD_OK='' HIMMEL_LEAN_LEG='' \
HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17/konsole" PGREP_CMD="$d17/pgrep" \
LEG_REPO="$tmp/repo17" HEADED_ARM_LOCK_DIR="$d17/locks" HEADED_ARM_PROC="$d17/proc" \
  bash "$SCRIPT" --profile leg-impl "HIMMEL-3333-leg" "$some_doc" "$d17/signal-never" "$PAST" "$d17/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17" || true
rec17="$(cat "$d17/record" 2>/dev/null || true)"
env17="$(cat "$d17/env-record" 2>/dev/null || true)"
check "full launch --profile: exit 0" "$rc" "0"
contains "full launch --profile: the launcher is the profile shim" "$rec17" "leg-claude-launcher.sh"
contains "full launch --profile: the ceiling guard still holds" "$rec17" "--autocompact 200000"
contains "full launch --profile: HIMMEL_LEAN_LEG=1 reaches the launched environment" "$env17" "HIMMEL_LEAN_LEG=1"
contains "full launch --profile: the shim is told where the settings live" "$env17" "LEG_PROFILE_SETTINGS=$d17/HIMMEL-3333-leg.leg-settings.json"
if [ -s "$d17/HIMMEL-3333-leg.leg-settings.json" ]; then
  echo "ok - full launch --profile: settings JSON written next to the launch log"
else
  echo "FAIL - full launch --profile: no settings JSON next to the launch log"; fails=$((fails+1))
fi
contains "full launch --profile: the settings JSON is a real enabledPlugins map" \
  "$(cat "$d17/HIMMEL-3333-leg.leg-settings.json" 2>/dev/null || true)" "enabledPlugins"

# 17b-2 (HIMMEL-2985, superseded by HIMMEL-2990). A native-lane --profile
# launch's per-leg <name>.leg-preface.md is docs/handover/leg-preface.md
# only - the brief's own contract no longer rides it (2990 moved that to
# <name>.leg-contract.md, re-injected by the compact hook; see 17b-3 below).
# Real (non-dry) launch, same stub shape as 17b - this is the writer of the
# file, not the shim (the shim only fails closed if it is missing).
d17b="$tmp/c17b"; mk_launch_stubs "$d17b" "HIMMEL-9999-red"; mkdir -p "$tmp/repo17b"
fixture17b="$tmp/fixture-brief.md"
cat > "$fixture17b" <<'FIXTURE_EOF'
# HIMMEL-9999 - fixture brief

**Contract:**
1. Do the thing the ticket asks for.

## Results (newest at the bottom)

- 00:00 this bullet must never reach the system-prompt preface.
FIXTURE_EOF
rc=0
HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b/konsole" PGREP_CMD="$d17b/pgrep" \
LEG_REPO="$tmp/repo17b" HEADED_ARM_LOCK_DIR="$d17b/locks" HEADED_ARM_PROC="$d17b/proc" \
  bash "$SCRIPT" --profile leg-impl "HIMMEL-9999-red" "$fixture17b" "$d17b/signal-never" "$PAST" "$d17b/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b" || true
check "brief-preface: full launch exit 0" "$rc" "0"
preface17b="$d17b/HIMMEL-9999-red.leg-preface.md"
if [ -s "$preface17b" ]; then
  echo "ok - brief-preface: <name>.leg-preface.md written next to the launch log"
else
  echo "FAIL - brief-preface: no leg-preface.md next to the launch log"; fails=$((fails+1))
fi
prefacecontent17b="$(cat "$preface17b" 2>/dev/null || true)"
contains "brief-preface: carries the standing leg-preface heading" "$prefacecontent17b" \
  "$(head -1 "$HERE/../../../docs/handover/leg-preface.md")"
# HIMMEL-3097: a "system is running low on memory" background-task kill is not
# proof of memory pressure; the leg's system prompt tells it to read the
# pressure file and the cgroup's memory.events before believing one.
contains "brief-preface: names the low-memory kill (HIMMEL-3097)" "$prefacecontent17b" \
  "running low on memory"
contains "brief-preface: says to read /proc/pressure/memory before believing it (HIMMEL-3097)" \
  "$prefacecontent17b" "/proc/pressure/memory"
contains "brief-preface: says to read the cgroup memory.events before believing it (HIMMEL-3097)" \
  "$prefacecontent17b" "memory.events"
# HIMMEL-3479: the Opus 5.5 guide's standing "how turns end" instruction goes
# at the END of the system prompt, so it must be the preface's last section.
check "brief-preface: last section is the standing turn-ending instruction (HIMMEL-3479)" \
  "$(printf '%s\n' "$prefacecontent17b" | grep '^## ' | tail -1)" "## How your turns end"
contains "brief-preface: holding for GO stays a sanctioned stop (HIMMEL-3479)" \
  "$prefacecontent17b" "holding for the console's \`GO\` after \`READY\`"
not_contains "brief-preface: does NOT carry the fixture's Contract line (HIMMEL-2990)" \
  "$prefacecontent17b" "**Contract:**"
not_contains "brief-preface: does NOT carry the Results tail" "$prefacecontent17b" \
  "this bullet must never reach the system-prompt preface"

# --- 17b-3 (HIMMEL-2990). 2985's per-call preface concatenation is replaced:
# the brief's own contract now goes to its own per-leg <name>.leg-contract.md,
# re-injected only after a compaction via a SessionStart `compact`-matcher
# hook wired into the generated <name>.leg-settings.json - not ridden on every
# API call inside the system-prompt preface. Same fixture brief and stub shape
# as 17b.
d17b3="$tmp/c17b3"; mk_launch_stubs "$d17b3" "HIMMEL-9999-hook"; mkdir -p "$tmp/repo17b3"
rc=0
HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b3/konsole" PGREP_CMD="$d17b3/pgrep" \
LEG_REPO="$tmp/repo17b3" HEADED_ARM_LOCK_DIR="$d17b3/locks" HEADED_ARM_PROC="$d17b3/proc" \
  bash "$SCRIPT" --profile leg-impl "HIMMEL-9999-hook" "$fixture17b" "$d17b3/signal-never" "$PAST" "$d17b3/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b3" || true
check "compact-hook: full launch exit 0" "$rc" "0"

contract17b3="$d17b3/HIMMEL-9999-hook.leg-contract.md"
if [ -s "$contract17b3" ]; then
  echo "ok - compact-hook: <name>.leg-contract.md written next to the launch log"
else
  echo "FAIL - compact-hook: no leg-contract.md next to the launch log"; fails=$((fails+1))
fi
contractcontent17b3="$(cat "$contract17b3" 2>/dev/null || true)"
contains "compact-hook: contract carries the fixture's Contract line" "$contractcontent17b3" "**Contract:**"
not_contains "compact-hook: contract does NOT carry the Results tail" "$contractcontent17b3" \
  "this bullet must never reach the system-prompt preface"

prefacecontent17b3="$(cat "$d17b3/HIMMEL-9999-hook.leg-preface.md" 2>/dev/null || true)"
not_contains "compact-hook: the preface does NOT carry the contract" "$prefacecontent17b3" "**Contract:**"

rc=0
node --input-type=module - "$d17b3/HIMMEL-9999-hook.leg-settings.json" "$contract17b3" <<'NODE' || rc=$?
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const settings = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const contractPath = process.argv[3];
const starts = settings.hooks?.SessionStart ?? [];
const hit = starts.find((e) => e.matcher === 'compact');
assert.ok(hit, 'no SessionStart entry with matcher "compact"');
const cmd = hit.hooks?.[0]?.command ?? '';
assert.ok(cmd.includes(contractPath), `command does not name the contract file: ${cmd}`);
NODE
check "compact-hook: settings JSON carries a SessionStart compact hook naming the contract file" "$rc" "0"

# --- 17b-4 (HIMMEL-2990 CR round 1, codex-3). 17b-3 only checks that the
# generated command STRING names the contract path as a substring; it never
# actually runs the command, so it would not have caught an unescaped path
# breaking out of the re-parsed shell at hook-fire time. Log dir here carries
# a literal double quote - the exact character that breaks out of the OLD
# `cat "$PROFILE_CONTRACT"` double-quoting (a single quote does NOT: double
# quotes tolerate an embedded single quote) - so executing the generated
# command with an unescaped path would misparse rather than `cat` the file.
d17b4="$tmp/c17b4\"q"; mk_launch_stubs "$d17b4" "HIMMEL-9999-hookq"; mkdir -p "$tmp/repo17b4"
rc=0
HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
KONSOLE_CMD="$d17b4/konsole" PGREP_CMD="$d17b4/pgrep" \
LEG_REPO="$tmp/repo17b4" HEADED_ARM_LOCK_DIR="$d17b4/locks" HEADED_ARM_PROC="$d17b4/proc" \
  bash "$SCRIPT" --profile leg-impl "HIMMEL-9999-hookq" "$fixture17b" "$d17b4/signal-never" "$PAST" "$d17b4/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d17b4" || true
check "compact-hook exec: full launch exit 0 (log dir has a shell-special quote)" "$rc" "0"

contract17b4="$d17b4/HIMMEL-9999-hookq.leg-contract.md"
settings17b4="$d17b4/HIMMEL-9999-hookq.leg-settings.json"
contractcontent17b4="$(cat "$contract17b4" 2>/dev/null || true)"
contains "compact-hook exec: contract carries the fixture's Contract line" "$contractcontent17b4" "**Contract:**"

cmd17b4="$(node --input-type=module -e '
import { readFileSync } from "node:fs";
const settings = JSON.parse(readFileSync(process.argv[1], "utf8"));
const hit = (settings.hooks?.SessionStart ?? []).find((e) => e.matcher === "compact");
process.stdout.write(hit?.hooks?.[0]?.command ?? "");
' "$settings17b4")"
exec17b4="$(bash -c "$cmd17b4" 2>/dev/null || true)"
check "compact-hook exec: executing the generated command outputs the real contract content" "$exec17b4" "$contractcontent17b4"

# 17c. Omitting --profile changes nothing: no shim, no lean flag, and a
# dry-run report byte-identical to the pre-HIMMEL-2830 three-line form. This
# is the case that keeps every console that never passes --profile working.
env8b="$(cat "$d8/env-record" 2>/dev/null || true)"
not_contains "no --profile: launcher is unchanged (no shim)" "$rec8" "leg-claude-launcher.sh"
not_contains "no --profile: no HIMMEL_LEAN_LEG in the launched environment" "$env8b" "HIMMEL_LEAN_LEG=1"

noprof="$(LEG_PROFILE='' bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)"
noprof_lines="$(printf '%s\n' "$noprof" | wc -l | tr -d '[:space:]')"
check "no --profile: dry-run report is still exactly three lines" "$noprof_lines" "3"
not_contains "no --profile: dry-run report has no profile line" "$noprof" "profile="

prof="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/leg.log" claude-sonnet-5 2>&1)"
prof_lines="$(printf '%s\n' "$prof" | wc -l | tr -d '[:space:]')"
check "--profile: dry-run report adds exactly one line" "$prof_lines" "4"
contains "--profile: dry-run names the profile, the settings path and the lean flag" "$prof" \
  "profile=leg-impl settings=$tmp/HIMMEL-9999-leg.leg-settings.json"
contains "--profile: dry-run reports lean=1" "$prof" "lean=1"
if [ -e "$tmp/HIMMEL-9999-leg.leg-settings.json" ]; then
  echo "FAIL - --profile: --dry-run wrote the settings file (it must only report)"; fails=$((fails+1))
else
  echo "ok - --profile: --dry-run writes nothing"
fi

# HIMMEL-2959: inspect the real seeded settings and the same resolver used by
# --dry-run; checking only the profile= line would miss dropped permissions.
rc=0
node --input-type=module - "$d17/HIMMEL-3333-leg.leg-settings.json" <<'NODE' || rc=$?
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const settings = JSON.parse(readFileSync(process.argv[2], 'utf8'));
assert.ok(settings.permissions?.allow.includes('Bash(bash scripts/handover/merge-on-green.sh:*)'));
NODE
check "full launch --profile: seeded settings carry gate permissions" "$rc" "0"

rc=0
node "$HERE/../../lanes/plugin-profiles.mjs" leg-impl > "$tmp/resolved-leg.json" || rc=$?
check "--dry-run leg-impl: resolver succeeds" "$rc" "0"
rc=0
node -e 'const j=require(process.argv[1]); if (!j.permissions?.allow.includes("Bash(bash scripts/cr/ledger-append.sh:*)")) process.exit(1)' "$tmp/resolved-leg.json" || rc=$?
check "--dry-run leg-impl: resolved settings carry permissions.allow" "$rc" "0"

rc=0
bareprof="$(bash "$SCRIPT" --dry-run --profile bare HIMMEL-9999-bare some/doc.md /tmp/nosig 99999999999 "$tmp/bare.log" claude-sonnet-5 2>&1)" || rc=$?
check "--dry-run bare: exit 0" "$rc" "0"
contains "--dry-run bare: names profile and settings" "$bareprof" \
  "profile=bare settings=$tmp/HIMMEL-9999-bare.leg-settings.json"
rc=0
node "$HERE/../../lanes/plugin-profiles.mjs" bare > "$tmp/resolved-bare.json" || rc=$?
check "--dry-run bare: resolver succeeds" "$rc" "0"
rc=0
node -e 'const j=require(process.argv[1]); if (Object.hasOwn(j,"permissions")) process.exit(1)' "$tmp/resolved-bare.json" || rc=$?
check "--dry-run bare: resolved settings have no permissions" "$rc" "0"

# LEG_PROFILE is the env equivalent, and the flag wins over it.
envprof="$(LEG_PROFILE=leg-impl bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/leg.log" claude-sonnet-5 2>&1)"
contains "LEG_PROFILE=leg-impl is honoured like the flag" "$envprof" "profile=leg-impl"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile no-such-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/leg.log" claude-sonnet-5 2>&1)" || rc=$?
check "an unknown profile name is refused with exit 2" "$rc" "2"

if [ -n "$_TIMEOUT_BIN" ]; then
    rc=0; out="$("$_TIMEOUT_BIN" 5 bash "$SCRIPT" --profile 2>&1)" || rc=$?
    check "usage: --profile with no value -> exit 2 (not an infinite loop)" "$rc" "2"
else
    echo "SKIP - usage: --profile with no value (hang-guard row needs GNU timeout/gtimeout)"
fi

# 17d. HIMMEL-2962: composition must carry the profile through the claudex
# backend, not silently select one launcher. Execute the real wrapper + shim
# against recording endpoints (never launch Claude or a terminal).
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex --profile leg-impl HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "--profile with --lane claudex: exit 0" "$rc" "0"
contains "composed dry-run: profile settings reported" "$out" "profile=leg-impl settings="
contains "composed dry-run: claudex lane retained" "$out" "lane=claudex"
rc=0; out="$(LEG_LANE=claudex LEG_PROFILE=leg-impl bash "$SCRIPT" --dry-run HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "composition via the env equivalents: exit 0" "$rc" "0"

composed="$tmp/composed-launch"; mkdir -p "$composed"
cat > "$composed/headed" <<'HEADED_EOF'
#!/usr/bin/env bash
read -r -a lane_env <<< "${HEADED_ARM_LAUNCHER_ENV:-}"
exec env ${lane_env[@]+"${lane_env[@]}"} "$HEADED_ARM_LAUNCHER" --model "$6" --autocompact 200000 -n "$1" "load $2 and continue"
HEADED_EOF
cat > "$composed/claude-codex" <<'CLAUDEX_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/args"
printf '%s\n' "${CLAUDEX_LANE_OK:-}" "${CLAUDE_CODE_EFFORT_LEVEL:-}" > "$(dirname "$0")/lane-env"
CLAUDEX_EOF
cat > "$composed/profiles.mjs" <<'PROFILE_EOF'
switch (process.argv[3]) {
  case '--mcp-servers': console.log('["qmd"]'); break;
  case '--mcp-config': console.log('{"mcpServers":{"qmd":{"type":"http","url":"http://localhost:8181/mcp"}}}'); break;
  default: console.log('{"enabledPlugins":{},"permissions":{"allow":["Bash(bash scripts/handover/merge-on-green.sh:*)"]}}');
}
PROFILE_EOF
chmod 755 "$composed/headed" "$composed/claude-codex"
rc=0
HEADED_ARM_LEG_TARGET="$composed/headed" HEADED_ARM_LEG_CLAUDEX_BIN="$composed/claude-codex" \
HEADED_ARM_LEG_PROFILES="$composed/profiles.mjs" HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" LEG_EFFORT=high \
  bash "$SCRIPT" --lane claudex --profile leg-impl HIMMEL-composed "some/doc.md" "$composed/signal" "$PAST" "$composed/log" >/dev/null 2>&1 || rc=$?
check "composition: real wrapper + shim reaches claudex" "$rc" "0"
check "composition: lane env reaches the backend" "$(cat "$composed/lane-env" 2>/dev/null || true)" "$(printf '1\nhigh')"
rc=0
node - "$composed" "$HERE/../../../docs/handover/leg-preface.md" <<'NODE' || rc=$?
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [dir, profilePreface] = process.argv.slice(2);
const preface = `${dir}/HIMMEL-composed.leg-preface.md`;
const claudexPreface = profilePreface.replace('leg-preface.md', 'leg-preface-claudex.md');
assert.strictEqual(fs.readFileSync(preface, 'utf8'),
  fs.readFileSync(profilePreface, 'utf8') + fs.readFileSync(claudexPreface, 'utf8'));
assert.deepStrictEqual(fs.readFileSync(`${dir}/args`, 'utf8').trimEnd().split('\n'), [
  '--settings', `${dir}/HIMMEL-composed.leg-settings.json`,
  '--append-system-prompt-file', preface,
  '--mcp-config', `${dir}/HIMMEL-composed.leg-mcp.json`, '--strict-mcp-config',
  '--model', 'gpt-6-astra', '--autocompact', '200000', '-n', 'HIMMEL-composed', 'load some/doc.md and continue',
]);
const settings = JSON.parse(fs.readFileSync(`${dir}/HIMMEL-composed.leg-settings.json`, 'utf8'));
assert.ok(settings.permissions.allow.includes('Bash(bash scripts/handover/merge-on-green.sh:*)'));
assert.deepStrictEqual(JSON.parse(fs.readFileSync(`${dir}/HIMMEL-composed.leg-mcp.json`, 'utf8')),
  {mcpServers: {qmd: {type: 'http', url: 'http://localhost:8181/mcp'}}});
NODE
check "composition: both prefaces, all profile flags, argv order and gate settings survive" "$rc" "0"

# Without a profile, claudex gains exactly the coordination preface pair.
rc=0
HEADED_ARM_LEG_TARGET="$composed/headed" HEADED_ARM_LEG_CLAUDEX_BIN="$composed/claude-codex" \
HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
  bash "$SCRIPT" --lane claudex --no-profile HIMMEL-unprofiled "some/doc.md" "$composed/signal" "$PAST" "$composed/log" >/dev/null 2>&1 || rc=$?
check "unprofiled claudex: launcher succeeds" "$rc" "0"
rc=0
node - "$composed" "$HERE/../../../docs/handover/leg-preface-claudex.md" <<'NODE' || rc=$?
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [dir, preface] = process.argv.slice(2);
assert.deepStrictEqual(fs.readFileSync(`${dir}/args`, 'utf8').trimEnd().split('\n'), [
  '--append-system-prompt-file', preface,
  '--model', 'gpt-6-astra', '--autocompact', '200000', '-n', 'HIMMEL-unprofiled', 'load some/doc.md and continue',
]);
NODE
check "unprofiled claudex: exactly one added preface pair, other argv unchanged" "$rc" "0"

# --- 18 (HIMMEL-2935). --profile's mcpServers allowlist: --mcp-config +
# --strict-mcp-config narrow the leg's MCP surface to exactly the named
# servers, copied (never hand-written) from ~/.claude.json / a repo .mcp.json
# / the server's own marketplace plugin manifest. Two layers, same split as
# case 17 above: the SHIM (leg-claude-launcher.sh) is the only place the
# child cmdline is observable, so flag-propagation is proven there directly;
# headed-arm-leg.sh's own full-launch path is where the file gets resolved
# and written (or refused), proven via the written artifact, not the argv.

# 18-shim. The shim, driven directly: LEG_PROFILE_MCP_CONFIG set + file
# present -> both flags prepended, ahead of the rest of argv; unset -> no
# change; set but missing -> fail closed (the same shape as the settings/
# preface cases in 17a, now pinned for the third env var).
mcpfile="$tmp/leg-mcp.json"
printf '{"mcpServers":{"qmd":{"type":"http","url":"http://localhost:8181/mcp"}}}' > "$mcpfile"
rm -f "$tmp/shim-record"
rc=0
LEG_CLAUDE_BIN="$shim_rec" LEG_PROFILE_SETTINGS='' LEG_PROFILE_PREFACE='' LEG_PROFILE_MCP_CONFIG="$mcpfile" \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg "load doc" || rc=$?
check "shim: mcp-config exit 0" "$rc" "0"
check "shim: prepends --mcp-config + --strict-mcp-config, rest of argv preserved" \
  "$(cat "$tmp/shim-record" 2>/dev/null || true)" \
  "--mcp-config $mcpfile --strict-mcp-config --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg load doc"

rm -f "$tmp/shim-record"
rc=0
LEG_CLAUDE_BIN="$shim_rec" LEG_PROFILE_SETTINGS='' LEG_PROFILE_PREFACE='' LEG_PROFILE_MCP_CONFIG='' \
  bash "$SHIM" --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg "load doc" || rc=$?
check "shim: no LEG_PROFILE_MCP_CONFIG -> argv byte-identical (no mcp flags)" \
  "$(cat "$tmp/shim-record" 2>/dev/null || true)" \
  "--model claude-sonnet-5 --autocompact 200000 -n HIMMEL-9999-leg load doc"

rc=0
out="$(LEG_CLAUDE_BIN="$shim_rec" LEG_PROFILE_MCP_CONFIG="$tmp/no-such-mcp.json" bash "$SHIM" --model x 2>&1)" || rc=$?
check "shim: a missing mcp-config file refuses with exit 2" "$rc" "2"
contains "shim: refusal names the missing mcp file" "$out" "$tmp/no-such-mcp.json"

# 18-resolve. A tiny fixture registry exercises all four allowlist shapes
# (empty/named/unknown/absent) without touching the shipped leg-impl entry.
# floor+catalog carry one dummy id purely to satisfy validateRegistry's
# non-empty-array checks; none of these profiles enable it.
mcpreg="$tmp/mcp-registry.json"
cat > "$mcpreg" <<'MCPREG_EOF'
{
  "floor": ["dummy@marketplace"],
  "catalog": ["dummy@marketplace"],
  "profiles": {
    "operator": null,
    "mcp-empty": { "enable": [], "mcpServers": [], "contextBudget": 1000 },
    "mcp-qmd": { "enable": [], "mcpServers": ["qmd"], "contextBudget": 1000 },
    "mcp-missing": { "enable": [], "mcpServers": ["no-such-server"], "contextBudget": 1000 },
    "mcp-none": { "enable": [], "contextBudget": 1000 }
  }
}
MCPREG_EOF
mcphome="$tmp/mcp-home"; mkdir -p "$mcphome"
cat > "$mcphome/.claude.json" <<'HOME_EOF'
{"mcpServers": {"qmd": {"type": "http", "url": "http://localhost:8181/mcp"}, "graphify": {"type": "stdio", "command": "graphify-mcp"}, "context7": {"type": "http", "url": "http://context7.example/mcp"}}}
HOME_EOF

full_launch_mcp() {
  # full_launch_mcp <dir-suffix> <name> <profile> [homedir, default: ambient $HOME]
  local suf="$1" name="$2" prof="$3" homedir="${4:-$HOME}"
  local d="$tmp/c18$suf"; mk_launch_stubs "$d" "$name"; mkdir -p "$tmp/repo18$suf"
  rc=0
  PLUGIN_PROFILES_REGISTRY="$mcpreg" HOME="$homedir" \
  HEADED_ARM_LEG_TARGET="$HEADED_ARM" HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$d/konsole" PGREP_CMD="$d/pgrep" \
  LEG_REPO="$tmp/repo18$suf" HEADED_ARM_LOCK_DIR="$d/locks" HEADED_ARM_PROC="$d/proc" \
    bash "$SCRIPT" --profile "$prof" "$name" "$some_doc" "$d/signal-never" "$PAST" "$d/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
  wait_record "$d" || true
}

# (a) mcpServers: [] -> the written file is exactly {"mcpServers":{}} - "strip
# everything" is a real, distinct allowlist value from "field absent".
full_launch_mcp a "HIMMEL-4441-leg" mcp-empty
check "mcpServers=[]: full launch exit 0" "$rc" "0"
check "mcpServers=[]: mcp config file is exactly {\"mcpServers\":{}}" \
  "$(cat "$tmp/c18a/HIMMEL-4441-leg.leg-mcp.json" 2>/dev/null || true)" '{"mcpServers":{}}'
env18a="$(cat "$tmp/c18a/env-record" 2>/dev/null || true)"
contains "mcpServers=[]: LEG_PROFILE_MCP_CONFIG reaches the launched environment" "$env18a" "LEG_PROFILE_MCP_CONFIG=$tmp/c18a/HIMMEL-4441-leg.leg-mcp.json"

# (b) mcpServers: ["qmd"] against a fixture home carrying qmd+graphify+
# context7 -> the written file holds ONLY qmd's definition, byte-copied
# (deny-by-default: graphify/context7 never appear despite being right there
# in the source file).
full_launch_mcp b "HIMMEL-4442-leg" mcp-qmd "$mcphome"
check "mcpServers=[qmd]: full launch exit 0" "$rc" "0"
mcpout_b="$(cat "$tmp/c18b/HIMMEL-4442-leg.leg-mcp.json" 2>/dev/null || true)"
contains "mcpServers=[qmd]: file carries qmd's definition byte-copied" "$mcpout_b" '"qmd":{"type":"http","url":"http://localhost:8181/mcp"}'
not_contains "mcpServers=[qmd]: graphify is NOT copied despite being in the source file" "$mcpout_b" "graphify"
not_contains "mcpServers=[qmd]: context7 is NOT copied despite being in the source file" "$mcpout_b" "context7"

# (c) an allowlisted name absent from every source -> exit 2, no file
# written at all (not an empty one - the refusal must precede the write).
full_launch_mcp c "HIMMEL-4443-leg" mcp-missing "$mcphome"
check "mcpServers=[no-such-server]: refused with exit 2" "$rc" "2"
if [ -e "$tmp/c18c/HIMMEL-4443-leg.leg-mcp.json" ]; then
  echo "FAIL - mcpServers=[no-such-server]: a config file must not exist"; fails=$((fails+1))
else
  echo "ok - mcpServers=[no-such-server]: no config file written"
fi

# (d) no mcpServers field -> byte-identical to pre-HIMMEL-2935: no file, no
# LEG_PROFILE_MCP_CONFIG in the launched environment.
full_launch_mcp d "HIMMEL-4444-leg" mcp-none
check "no mcpServers field: full launch exit 0" "$rc" "0"
if [ -e "$tmp/c18d/HIMMEL-4444-leg.leg-mcp.json" ]; then
  echo "FAIL - no mcpServers field: a config file must not exist"; fails=$((fails+1))
else
  echo "ok - no mcpServers field: no config file written"
fi
env18d="$(cat "$tmp/c18d/env-record" 2>/dev/null || true)"
not_contains "no mcpServers field: no LEG_PROFILE_MCP_CONFIG in the launched environment" "$env18d" "LEG_PROFILE_MCP_CONFIG="

# dry-run mirrors the same four shapes without writing anything, and an
# unresolvable name is refused the same way under --dry-run too (typo'd
# names must fail identically whether or not the launch is real).
rc=0; out="$(PLUGIN_PROFILES_REGISTRY="$mcpreg" HOME="$mcphome" bash "$SCRIPT" --dry-run --profile mcp-missing HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "dry-run: an unresolvable mcpServers name is refused with exit 2" "$rc" "2"

dryempty="$(PLUGIN_PROFILES_REGISTRY="$mcpreg" HOME="$mcphome" bash "$SCRIPT" --dry-run --profile mcp-empty HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/leg.log" claude-sonnet-5 2>&1)"
contains "dry-run mcpServers=[]: reports mcp=[] and the would-be mcp-config path" "$dryempty" "mcp=[] mcp-config=$tmp/HIMMEL-9999-leg.leg-mcp.json"

drynone="$(PLUGIN_PROFILES_REGISTRY="$mcpreg" bash "$SCRIPT" --dry-run --profile mcp-none HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 "$tmp/leg.log" claude-sonnet-5 2>&1)"
contains "dry-run: no mcpServers field reports mcp=null mcp-config=<none>" "$drynone" "mcp=null mcp-config=<none>"

# --- 19-23 (HIMMEL-2976) + HIMMEL-2997: Opus/Fable legs need a named Tier
# reason that opens with one of three closed category tags --------------
# CLAUDE.md: "raise effort before tier" - an Opus or Fable leg costs
# materially more per turn than the Sonnet default, so it launches only when
# its brief names a Tier line whose reason opens with one of the three
# sanctioned category tags (HIMMEL-2997: a closed tag + free text, so the
# free text after the tag is never validated). Matched by MODEL PREFIX so a
# [1m] suffix cannot dodge it (codex-2 pattern above).
doc_no_tier="$tmp/tier-doc-none.md"
printf '%s\n' '# fixture brief' '> no tier line here' > "$doc_no_tier"
doc_tier_opus="$tmp/tier-doc-opus.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — design: multi-step design' > "$doc_tier_opus"
doc_tier_fable="$tmp/tier-doc-fable.md"
printf '%s\n' '# fixture brief' '> **Tier:** fable — tier-return: a Sonnet leg returned the work as above its tier' > "$doc_tier_fable"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate: opus without a Tier line is refused with exit 2" "$rc" "2"
contains "tier gate: refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"
contains "tier gate: refusal names reason 1 (multi-step design)" "$out" "multi-step design"
contains "tier gate: refusal names reason 2 (unverifiable FINDING)" "$out" "a FINDING the console could not verify at Sonnet"
contains "tier gate: refusal names reason 3 (above-tier return)" "$out" "a Sonnet leg returned the work as above its tier"
contains "tier gate: refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/leg.log "claude-opus-5[1m]" 2>&1)" || rc=$?
check "tier gate: a [1m] suffix does not dodge the opus match" "$rc" "2"
contains "tier gate: [1m]-suffixed refusal still names the sentence" "$out" "raise effort before tier"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/leg.log claude-fable-5-1 2>&1)" || rc=$?
check "tier gate: fable without a Tier line is refused with exit 2" "$rc" "2"
contains "tier gate: fable refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate: opus with a design: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate: dry-run report carries tier-category=design for opus" "$out" "tier-category=design"
contains "tier gate: dry-run report carries tier-reason= for opus" "$out" "tier-reason=multi-step design"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_fable" /tmp/nosig 99999999999 /tmp/leg.log claude-fable-5-1 2>&1)" || rc=$?
check "tier gate: fable with a tier-return: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate: dry-run report carries tier-category=tier-return for fable" "$out" "tier-category=tier-return"
contains "tier gate: dry-run report carries tier-reason= for fable" "$out" "tier-reason=a Sonnet leg returned the work as above its tier"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "tier gate: sonnet without a Tier line is unaffected (dry-run exit 0)" "$rc" "0"
not_contains "tier gate: sonnet dry-run report carries no tier-reason=" "$out" "tier-reason="

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl --lane claudex HIMMEL-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "tier gate: --lane claudex is unaffected (dry-run exit 0)" "$rc" "0"

# codex-1 (HIMMEL-2976 round 1 CR): a Tier line whose reason is whitespace-only
# must be refused exactly like a missing line - `-z` alone treats a
# whitespace-only string as non-empty and would incorrectly let the launch
# proceed.
doc_tier_opus_blank="$tmp/tier-doc-opus-blank.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus —    ' > "$doc_tier_opus_blank"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_blank" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate: a whitespace-only Tier reason is refused with exit 2" "$rc" "2"
contains "tier gate: whitespace-only refusal names the CLAUDE.md sentence" "$out" "raise effort before tier"

# --- HIMMEL-2997 (a)-(f): the reason must open with a closed category tag --
doc_tier_opus_bare="$tmp/tier-doc-opus-bare.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — because I prefer it' > "$doc_tier_opus_bare"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_bare" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (a): bare free text with no category tag is refused with exit 2" "$rc" "2"
contains "tier gate (a): refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

doc_tier_opus_finding="$tmp/tier-doc-opus-finding.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — unverified-finding: a memory leak the console could not repro at Sonnet' > "$doc_tier_opus_finding"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_finding" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (c): unverified-finding: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (c): dry-run report carries tier-category=unverified-finding" "$out" "tier-category=unverified-finding"

doc_tier_opus_return="$tmp/tier-doc-opus-return.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — tier-return: a Sonnet leg returned the work as above its tier' > "$doc_tier_opus_return"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_return" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (d): tier-return: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (d): dry-run report carries tier-category=tier-return" "$out" "tier-category=tier-return"

doc_tier_opus_wrongcase="$tmp/tier-doc-opus-wrongcase.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — Design: multi-step design' > "$doc_tier_opus_wrongcase"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_wrongcase" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (e): wrong-case category tag (Design:) is refused with exit 2" "$rc" "2"
contains "tier gate (e): refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

doc_tier_opus_emptytext="$tmp/tier-doc-opus-emptytext.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — design:' > "$doc_tier_opus_emptytext"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_emptytext" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (f): a category tag with empty free text is refused with exit 2" "$rc" "2"
contains "tier gate (f): refusal names the empty-text problem" "$out" "no free text after"

# codex CR (round 1): a bare sanctioned tag with no ':' at all must not slip
# through as category=<tag> reason=<tag> — the split is a no-op without a
# literal colon present, so this must be refused explicitly.
doc_tier_opus_notag_colon="$tmp/tier-doc-opus-notag-colon.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — design' > "$doc_tier_opus_notag_colon"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_notag_colon" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5 2>&1)" || rc=$?
check "tier gate (g): a bare sanctioned tag with no colon is refused with exit 2" "$rc" "2"
contains "tier gate (g): refusal names the three category tags" "$out" "design|unverified-finding|tier-return"

# --- HIMMEL-3480 (bundled in HIMMEL-3479): a fourth closed tag, operator-ruling,
# for a standing operator ruling on model choice (2026-09-22: run only Opus
# 5.5). Same shape as the other three: exact lowercase, non-blank free text.
doc_tier_opus_ruling="$tmp/tier-doc-opus-ruling.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — operator-ruling: run only Opus 5.5 (operator 2026-09-22, console A)' > "$doc_tier_opus_ruling"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_ruling" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (h): operator-ruling: Tier line proceeds (dry-run exit 0)" "$rc" "0"
contains "tier gate (h): dry-run report carries tier-category=operator-ruling" "$out" "tier-category=operator-ruling"
contains "tier gate (h): dry-run report carries the ruling as tier-reason=" "$out" "tier-reason=run only Opus 5.5 (operator 2026-09-22, console A)"

doc_tier_opus_ruling_blank="$tmp/tier-doc-opus-ruling-blank.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — operator-ruling:   ' > "$doc_tier_opus_ruling_blank"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_ruling_blank" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (i): operator-ruling: with blank free text is refused with exit 2" "$rc" "2"
contains "tier gate (i): refusal names the empty-text problem" "$out" "no free text after"

doc_tier_opus_ruling_case="$tmp/tier-doc-opus-ruling-case.md"
printf '%s\n' '# fixture brief' '> **Tier:** opus — Operator-ruling: run only Opus 5.5' > "$doc_tier_opus_ruling_case"
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_tier_opus_ruling_case" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (j): wrong-case Operator-ruling: is refused with exit 2" "$rc" "2"
contains "tier gate (j): refusal lists the four category tags" "$out" "design|unverified-finding|tier-return|operator-ruling"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg "$doc_no_tier" /tmp/nosig 99999999999 /tmp/leg.log claude-opus-5-5 2>&1)" || rc=$?
check "tier gate (k): opus-5-5 without a Tier line is still refused with exit 2" "$rc" "2"
contains "tier gate (k): missing-line refusal lists the four category tags" "$out" "design|unverified-finding|tier-return|operator-ruling"
contains "tier gate (k): missing-line refusal names the operator-ruling reason" "$out" "a standing operator ruling on model choice"

# --- 24 (HIMMEL-2774). FLEET_RESERVE_TTL is exported, derived from DEADLINE -
# TTL_RECORD_PREFLIGHT stands in for bank-preflight.sh and records the TTL it
# was called with instead of consulting the real fleet/bank state, mirroring
# how PROCEED_PREFLIGHT/SKIPPED_FLEET_PREFLIGHT stand in above.
TTL_RECORD_PREFLIGHT="$tmp/ttl-record-preflight.sh"
# shellcheck disable=SC2016  # deliberately unexpanded: written literally, evaluated when the stub runs.
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$FLEET_RESERVE_TTL" > "$TTL_RECORD_OUT"' 'echo PROCEED' > "$TTL_RECORD_PREFLIGHT"
chmod 755 "$TTL_RECORD_PREFLIGHT"

# A genuinely future deadline (500s, clearly above the 60s floor so 24b's
# floor case is distinguishable) WITHOUT paying for headed-arm.sh's own
# wait loop: that loop breaks immediately once its SIGNAL file exists
# (headed-arm.sh tests `[ -e "$SIGNAL" ]` before ever comparing to DEADLINE),
# so pre-touching a real signal file here gets an immediate launch while
# still exercising the TTL computation against a real future DEADLINE value.
d24a="$tmp/c24a"; mk_launch_stubs "$d24a" "HIMMEL-1111-ttl"; mkdir -p "$tmp/repo24a"
future24=$(( $(date +%s) + 500 ))
touch "$d24a/signal-now"
ttl_out24a="$tmp/ttl24a-seen"
rc=0
TTL_RECORD_OUT="$ttl_out24a" IMPL_GUARD_OK='' \
HEADED_ARM_LEG_TARGET="$HEADED_ARM" HEADED_ARM_LEG_PREFLIGHT="$TTL_RECORD_PREFLIGHT" \
KONSOLE_CMD="$d24a/konsole" PGREP_CMD="$d24a/pgrep" \
LEG_REPO="$tmp/repo24a" HEADED_ARM_LOCK_DIR="$d24a/locks" HEADED_ARM_PROC="$d24a/proc" \
  bash "$SCRIPT" --profile leg-impl "HIMMEL-1111-ttl" "$some_doc" "$d24a/signal-now" "$future24" "$d24a/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d24a" || true
ttl_seen24a="$(cat "$ttl_out24a" 2>/dev/null || echo NONE)"
check "TTL export: full launch, future deadline: exit 0" "$rc" "0"
# a few seconds of scheduling slop around (deadline - now + 60) is expected;
# the exact value depends on how long the test harness itself took to reach
# the preflight call, not on anything this suite controls. codex-5 (HIMMEL-2774,
# CR round 1): the TTL now carries a fixed +60s grace past (deadline - now) so
# a reservation outlives the actual process spawn - see headed-arm-leg.sh.
if [ "$ttl_seen24a" != NONE ] && [ "$ttl_seen24a" -ge 550 ] 2>/dev/null && [ "$ttl_seen24a" -le 560 ] 2>/dev/null; then
  echo "ok - TTL export: future deadline -> FLEET_RESERVE_TTL ~= deadline - now + 60 ($ttl_seen24a)"
else
  echo "FAIL - TTL export: future deadline -> expected 550-560, got [$ttl_seen24a]"
  fails=$((fails+1))
fi

d24b="$tmp/c24b"; mk_launch_stubs "$d24b" "HIMMEL-2222-ttlfloor"; mkdir -p "$tmp/repo24b"
ttl_out24b="$tmp/ttl24b-seen"
rc=0
TTL_RECORD_OUT="$ttl_out24b" IMPL_GUARD_OK='' \
HEADED_ARM_LEG_TARGET="$HEADED_ARM" HEADED_ARM_LEG_PREFLIGHT="$TTL_RECORD_PREFLIGHT" \
KONSOLE_CMD="$d24b/konsole" PGREP_CMD="$d24b/pgrep" \
LEG_REPO="$tmp/repo24b" HEADED_ARM_LOCK_DIR="$d24b/locks" HEADED_ARM_PROC="$d24b/proc" \
  bash "$SCRIPT" --profile leg-impl "HIMMEL-2222-ttlfloor" "$some_doc" "$d24b/signal-never" "$PAST" "$d24b/log" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d24b" || true
check "TTL export: past deadline floors to 60" "$(cat "$ttl_out24b" 2>/dev/null || echo NONE)" "60"

# --- 25 (HIMMEL-2774). Reservation release on abort, SKIPPED-BANK vs
# SKIPPED-FLEET -------------------------------------------------------------
slots25a="$tmp/slots25a"; mkdir -p "$slots25a/HIMMEL-3333-release"
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$slots25a/HIMMEL-3333-release/expires"
d25a="$tmp/c25a"; mk_launch_stubs "$d25a" "HIMMEL-3333-release"; mkdir -p "$tmp/repo25a"
rc=0
HIMMEL_FLEET_SLOTS="$slots25a" run_leg "$d25a" "$tmp/repo25a" "HIMMEL-3333-release" "claude-sonnet-5" "$SKIPPED_BANK_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ -d "$slots25a/HIMMEL-3333-release" ]; then
  echo "FAIL - SKIPPED-BANK: reservation not released after refusal"
  fails=$((fails+1))
else
  echo "ok - SKIPPED-BANK: reservation released after refusal (this call's own, created by admission before the bank check ran)"
fi

slots25b="$tmp/slots25b"; mkdir -p "$slots25b/HIMMEL-4444-noown"
printf '%s\n' "$(( $(date +%s) + 1800 ))" > "$slots25b/HIMMEL-4444-noown/expires"
d25b="$tmp/c25b"; mk_launch_stubs "$d25b" "HIMMEL-4444-noown"; mkdir -p "$tmp/repo25b"
rc=0
HIMMEL_FLEET_SLOTS="$slots25b" run_leg "$d25b" "$tmp/repo25b" "HIMMEL-4444-noown" "claude-sonnet-5" "$SKIPPED_FLEET_PREFLIGHT" >/dev/null 2>&1 || rc=$?
n=0; while [ "$n" -lt 10 ]; do sleep 0.05; n=$((n+1)); done
if [ -d "$slots25b/HIMMEL-4444-noown" ]; then
  echo "ok - SKIPPED-FLEET: a same-name reservation is left untouched (never held one of its own to release)"
else
  echo "FAIL - SKIPPED-FLEET: a same-name reservation was removed - would delete a DIFFERENT pending arm's duplicate-refused slot"
  fails=$((fails+1))
fi

# --- 26 (HIMMEL-3155). GO gate reachable from a leg worktree: the wrapper
# resolves the CONSOLE's own handover root (its own process/cwd, before ANY
# konsole child exists) and exports it explicitly as HANDOVER_DIR into the
# leg's launch env - so a leg's later handover_root() call (run from a
# linked worktree, whose `git rev-parse --show-toplevel` resolves to the
# WORKTREE, not the console's checkout) binds to the SAME root the console
# used to write its GO (console-kit/go.sh), instead of silently re-deriving
# (and missing) a different one. RED on today's code: no HANDOVER_DIR export
# exists at all, so every assertion below fails.
primary26="$tmp/primary26"
mkdir -p "$primary26/handovers" && git -C "$primary26" init -q
d26="$tmp/c26"; mk_launch_stubs "$d26" "HIMMEL-3155-leg"; mkdir -p "$tmp/repo26"
rc=0
( cd "$primary26" && \
  IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' HANDOVER_DIR='' \
  HEADED_ARM_LEG_TARGET="$HEADED_ARM" HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$d26/konsole" PGREP_CMD="$d26/pgrep" \
  LEG_REPO="$tmp/repo26" HEADED_ARM_LOCK_DIR="$d26/locks" HEADED_ARM_PROC="$d26/proc" \
    bash "$SCRIPT" --profile leg-impl "HIMMEL-3155-leg" "$some_doc" "$d26/signal-never" "$PAST" "$d26/log" "claude-sonnet-5" \
) >/dev/null 2>&1 || rc=$?
wait_record "$d26" || true
env26="$(cat "$d26/env-record" 2>/dev/null || true)"
check "HANDOVER_DIR e2e: full launch, console cwd has inline handovers/: exit 0" "$rc" "0"
contains "HANDOVER_DIR e2e: leg env carries the console's resolved root verbatim" "$env26" "HANDOVER_DIR=$primary26/handovers"

# End-to-end: a GO written by go.sh from the SAME primary-like cwd (the
# console's own resolution), then go_gate resolved from a DIFFERENT cwd
# (simulating the leg's linked worktree) using ONLY the HANDOVER_DIR VALUE
# ACTUALLY CAPTURED FROM THE LEG'S OWN ENV ABOVE (env26, not a hardcoded
# primary26/handovers - a hardcoded value would pass vacuously even if the
# wrapper never exported anything), must find it.
sha26="$(printf 'a%.0s' $(seq 1 40))"
# HIMMEL-3186: fail closed BEFORE go.sh runs. The GO root this e2e is about to
# write into is resolved by the exact call go.sh makes (handover_root, from the
# primary-like cwd, HANDOVER_DIR cleared like the launch above) and must sit
# inside this suite's own temp dir; anything else (a live root leaking in)
# skips the write and fails loudly instead of minting a fake GO there.
go_root26="$(cd "$primary26" && HANDOVER_DIR='' bash -c '. "$1/../../lib/handover-path.sh" && handover_root' _ "$HERE" 2>/dev/null)" || go_root26=""
case "$go_root26" in
  "$tmp"/?*) echo "ok - HANDOVER_DIR e2e: resolved GO root [$go_root26] is inside the suite's temp dir"; go_root26_ok=1 ;;
  *) echo "FAIL - HANDOVER_DIR e2e: resolved GO root [$go_root26] is not inside the suite's temp dir [$tmp] - refusing to write a GO"; fails=$((fails+1)); go_root26_ok=0 ;;
esac
if [ "$go_root26_ok" -eq 1 ]; then
  go_out26="$(cd "$primary26" && HANDOVER_DIR='' bash "$HERE/go.sh" 26260 "$sha26" 2>&1)"
else
  go_out26="SKIPPED: unsafe GO root"
fi
leg_handover_dir26="$(printf '%s\n' "$env26" | sed -n 's/^HANDOVER_DIR=//p')"
worktree26="$tmp/worktree26"; mkdir -p "$worktree26"
gate_script26="$tmp/gate26.sh"
cat > "$gate_script26" <<EOF
#!/usr/bin/env bash
set -u
. "$HERE/../../lib/handover-path.sh"
. "$HERE/../../lib/go-gate.sh"
root="\$(handover_root)" || exit 9
go_gate 26260 "$sha26" "\$root"
EOF
chmod 755 "$gate_script26"
rc2=0
( cd "$worktree26" && HANDOVER_DIR="$leg_handover_dir26" bash "$gate_script26" ) >/dev/null 2>&1 || rc2=$?
check "HANDOVER_DIR e2e: go.sh wrote the GO from the console cwd" "$go_out26" "$primary26/handovers/.locks/go/26260.$sha26"
check "HANDOVER_DIR e2e: go_gate resolved from a linked worktree (HANDOVER_DIR only) finds the GO" "$rc2" "0"

# --- 27 (HIMMEL-3267). An unprofiled launch is REFUSED, not silently launched
# preface-less. Both the dry-run seam AND the real (non-dry) stubbed path are
# driven: the refusal sits before the --dry-run exit, so the dry-run cases
# exercise the decision itself, and the real-path case proves nothing reaches
# konsole. Every shape that supplies a profile (flag, LEG_PROFILE, --relay,
# --judge) or opts out (--no-profile) must still launch.
args27=(HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5)
rc=0; out="$(bash "$SCRIPT" --dry-run "${args27[@]}" 2>&1)" || rc=$?
check "27a no profile, no opt-out (dry-run): refused with exit 2" "$rc" "2"
contains "27a refusal names --profile" "$out" "--profile"
contains "27a refusal names the --no-profile opt-out" "$out" "--no-profile"
not_contains "27a nothing would exec" "$out" "would exec"

d27="$tmp/c27"; mk_launch_stubs "$d27" "HIMMEL-2727-leg"; mkdir -p "$tmp/repo27"
rc=0
RUN_LEG_ARGS='' run_leg "$d27" "$tmp/repo27" "HIMMEL-2727-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
check "27b no profile, no opt-out (real launch): refused with exit 2" "$rc" "2"
sleep 0.3
check "27b refused launch never reached konsole" "$([ -e "$d27/record" ] && echo launched || echo none)" "none"
check "27b refused launch wrote no settings file" "$([ -e "$d27/HIMMEL-2727-leg.leg-settings.json" ] && echo wrote || echo none)" "none"

# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile "${args27[@]}" 2>&1)" || rc=$?
check "27c --no-profile: launches (dry-run exit 0)" "$rc" "0"
check "27c --no-profile: dry-run report is exactly three lines" "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" "3"
not_contains "27c --no-profile: no profile line" "$out" "profile="

d27c="$tmp/c27c"; mk_launch_stubs "$d27c" "HIMMEL-2728-leg"; mkdir -p "$tmp/repo27c"
rc=0
RUN_LEG_ARGS='--no-profile' run_leg "$d27c" "$tmp/repo27c" "HIMMEL-2728-leg" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d27c" || true
check "27d --no-profile (real launch): exit 0" "$rc" "0"
contains "27d --no-profile records the deliberate opt-out in the launch log" "$(cat "$d27c/log" 2>/dev/null || true)" "--no-profile"
not_contains "27d --no-profile: no preface flag reached claude" "$(cat "$d27c/record" 2>/dev/null || true)" "--append-system-prompt-file"

# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --profile leg-impl "${args27[@]}" 2>&1)" || rc=$?
check "27e --no-profile with --profile: refused with exit 2" "$rc" "2"
# shellcheck disable=SC2086
rc=0; out="$(LEG_PROFILE=leg-impl bash "$SCRIPT" --dry-run --no-profile "${args27[@]}" 2>&1)" || rc=$?
check "27e --no-profile with LEG_PROFILE: refused with exit 2" "$rc" "2"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --relay HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "27e --no-profile with --relay: refused with exit 2" "$rc" "2"
rc=0; out="$(bash "$SCRIPT" --dry-run --no-profile --judge HIMMEL-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "27e --no-profile with --judge: refused with exit 2" "$rc" "2"
contains "27e --no-profile with --judge: the refusal names --no-profile (not the Tier gate)" "$out" "--no-profile"

# Every profile-supplying shape must NOT trip the refusal.
# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl "${args27[@]}" 2>&1)" || rc=$?
check "27f --profile leg-impl: launches" "$rc" "0"
# shellcheck disable=SC2086
rc=0; out="$(LEG_PROFILE=leg-impl bash "$SCRIPT" --dry-run "${args27[@]}" 2>&1)" || rc=$?
check "27f LEG_PROFILE=leg-impl (env seam, no flag): launches" "$rc" "0"
contains "27f LEG_PROFILE=leg-impl: profile applied" "$out" "profile=leg-impl"
# shellcheck disable=SC2086
rc=0; out="$(LEG_PROFILE=leg-impl bash "$SCRIPT" --dry-run --profile bare "${args27[@]}" 2>&1)" || rc=$?
contains "27f flag wins over LEG_PROFILE" "$out" "profile=bare"
rc=0; out="$(bash "$SCRIPT" --dry-run --relay HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "27f --relay alone (forces console-relay): launches" "$rc" "0"
contains "27f --relay: forced profile applied" "$out" "profile=console-relay"
rc=0; out="$(bash "$SCRIPT" --dry-run --judge HIMMEL-9999-leg "$doc_tier_judge" /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "27f --judge alone (forces console-judge): launches" "$rc" "0"
contains "27f --judge: forced profile applied" "$out" "profile=console-judge"

# Empty values are not a profile.
# shellcheck disable=SC2086
rc=0; out="$(LEG_PROFILE='' bash "$SCRIPT" --dry-run "${args27[@]}" 2>&1)" || rc=$?
check "27g empty LEG_PROFILE is not a profile: refused with exit 2" "$rc" "2"
# shellcheck disable=SC2086
rc=0; out="$(bash "$SCRIPT" --dry-run --profile '' "${args27[@]}" 2>&1)" || rc=$?
check "27g --profile '' is not a profile: refused with exit 2" "$rc" "2"

# claudex lane: the coordination preface alone is not the standing preface.
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "27h --lane claudex, no profile, no opt-out: refused with exit 2" "$rc" "2"
rc=0; out="$(bash "$SCRIPT" --dry-run --lane claudex --no-profile HIMMEL-9999-leg some/doc.md /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "27h --lane claudex --no-profile: launches" "$rc" "0"

# --- 28. HIMMEL-3270: the launch record ---------------------------------------
# The cost program's cohort metric identifies `leg-impl` sessions from a launch
# record; nothing wrote one. Every REAL launch appends one line to
# $HIMMELCTL_CACHE_DIR/launch-logs/<session>.log (the dir uninstall already
# removes wholesale); --dry-run writes nothing.
LL_DIR="$HIMMELCTL_CACHE_DIR/launch-logs"
ll_line() { cat "$LL_DIR/$1.log" 2>/dev/null || true; }

check "28a no launch record exists for a session that was never launched" "$([ -e "$LL_DIR/HIMMEL-3270-N1-dry.log" ] && echo present || echo none)" "none"

rc=0; out="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-3270-N1-dry "$some_doc" /tmp/nosig 99999999999 /tmp/leg.log 2>&1)" || rc=$?
check "28b --dry-run exits 0" "$rc" "0"
check "28b --dry-run writes no launch record" "$([ -e "$LL_DIR/HIMMEL-3270-N1-dry.log" ] && echo present || echo none)" "none"

d28="$tmp/c28"; mk_launch_stubs "$d28" "HIMMEL-3270-N2-real"; mkdir -p "$tmp/repo28"
rc=0
CANARY_SECRET=hunter2-canary ANTHROPIC_API_KEY=sk-canary-not-real \
  run_leg "$d28" "$tmp/repo28" "HIMMEL-3270-N2-real" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28" || true
check "28c real --profile leg-impl launch: exit 0" "$rc" "0"
rec28="$(ll_line HIMMEL-3270-N2-real)"
check "28c launch record is exactly one line" "$(ll_line HIMMEL-3270-N2-real | wc -l | tr -d '[:space:]')" "1"
# The reader (agg-postpin.sh cohort_ok) matches a whitespace-delimited field
# exactly equal to profile=<name>, so the field must stand alone.
check "28c record carries the profile field the cohort reader matches" "$(printf '%s\n' "$rec28" | awk '{for(i=1;i<=NF;i++) if($i=="profile=leg-impl"){f=1}} END{print f+0}')" "1"
contains "28c record names the session" "$rec28" " session=HIMMEL-3270-N2-real "
contains "28c record names the role" "$rec28" " role=leg "
contains "28c record names the lane" "$rec28" " lane=native "
contains "28c record names the model" "$rec28" " model=claude-sonnet-5 "
check "28c record ends with an ISO-8601 UTC launch time" "$(printf '%s\n' "$rec28" | grep -Ec ' launched=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1"
# No secrets: launch metadata only - never an env value.
not_contains "28c record holds no env value (canary secret)" "$rec28" "hunter2-canary"
not_contains "28c record holds no env value (canary key)" "$rec28" "sk-canary-not-real"
check "28c record carries only the fixed launch-metadata keys" "$(printf '%s\n' "$rec28" | tr ' ' '\n' | sed 1d | cut -d= -f1 | paste -sd, -)" "profile,lane,model,role,session,launched"

d28b="$tmp/c28b"; mk_launch_stubs "$d28b" "HIMMEL-3270-N3-noprof"; mkdir -p "$tmp/repo28b"
RUN_LEG_ARGS='--no-profile' run_leg "$d28b" "$tmp/repo28b" "HIMMEL-3270-N3-noprof" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d28b" || true
rec28b="$(ll_line HIMMEL-3270-N3-noprof)"
contains "28d --no-profile launch is recorded as profile=none" "$rec28b" " profile=none "
contains "28d --no-profile launch is still role=leg" "$rec28b" " role=leg "

d28c="$tmp/c28c"; mk_launch_stubs "$d28c" "HIMMEL-3270-N4-relay"; mkdir -p "$tmp/repo28c"
RUN_LEG_ARGS='--relay' run_leg "$d28c" "$tmp/repo28c" "HIMMEL-3270-N4-relay" >/dev/null 2>&1 || true
wait_record "$d28c" || true
rec28c="$(ll_line HIMMEL-3270-N4-relay)"
contains "28e --relay launch is recorded with its forced profile" "$rec28c" " profile=console-relay "
contains "28e --relay launch is recorded role=relay" "$rec28c" " role=relay "

d28d="$tmp/c28d"; mk_launch_stubs "$d28d" "HIMMEL-3270-N5-judge"; mkdir -p "$tmp/repo28d"
RUN_LEG_ARGS='--judge' run_leg "$d28d" "$tmp/repo28d" "HIMMEL-3270-N5-judge" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d28d" || true
rec28d="$(ll_line HIMMEL-3270-N5-judge)"
contains "28f --judge launch is recorded with its forced profile" "$rec28d" " profile=console-judge "
contains "28f --judge launch is recorded role=judge" "$rec28d" " role=judge "

# A relaunch of the same session name appends, never replaces: the record is
# history, and a replaced line would erase what the first launch really was.
d28e="$tmp/c28e"; mk_launch_stubs "$d28e" "HIMMEL-3270-N2-real"; mkdir -p "$tmp/repo28e"
run_leg "$d28e" "$tmp/repo28e" "HIMMEL-3270-N2-real" "claude-sonnet-5" >/dev/null 2>&1 || true
wait_record "$d28e" || true
check "28g a relaunch of the same session appends a second line" "$(ll_line HIMMEL-3270-N2-real | wc -l | tr -d '[:space:]')" "2"

# Best-effort: a record that cannot be written must not stop the launch, and
# must say so in the launch log rather than fail silently.
d28f="$tmp/c28f"; mk_launch_stubs "$d28f" "HIMMEL-3270-N6-blocked"; mkdir -p "$tmp/repo28f"
: > "$tmp/not-a-dir"
rc=0
HIMMELCTL_CACHE_DIR="$tmp/not-a-dir" run_leg "$d28f" "$tmp/repo28f" "HIMMEL-3270-N6-blocked" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28f" || true
check "28h an unwritable record dir does not stop the launch (exit 0)" "$rc" "0"
check "28h ... and the launch still reached konsole" "$([ -s "$d28f/record" ] && echo launched || echo none)" "launched"
contains "28h ... and the launch log says the record was not written" "$(cat "$d28f/log" 2>/dev/null || true)" "launch record NOT written"

# With no resolvable cache dir (HOME empty, no HIMMELCTL_CACHE_DIR) nothing is
# written at all: falling back to /tmp would leave residue uninstall cannot find
# (the accepted HIMMEL-3260 HOME-unset divergence, not repeated here).
d28g="$tmp/c28g"; mk_launch_stubs "$d28g" "HIMMEL-3270-N7-nohome"; mkdir -p "$tmp/repo28g"
rc=0
HOME='' HIMMELCTL_CACHE_DIR='' run_leg "$d28g" "$tmp/repo28g" "HIMMEL-3270-N7-nohome" "claude-sonnet-5" >/dev/null 2>&1 || rc=$?
wait_record "$d28g" || true
check "28i no resolvable cache dir: launch still exits 0" "$rc" "0"
check "28i no resolvable cache dir: nothing written under /tmp/.claude" "$([ -e /tmp/.claude/himmel/launch-logs/HIMMEL-3270-N7-nohome.log ] && echo wrote || echo none)" "none"

# --- 29 (HIMMEL-3403). --headless: the leg runs as a Claude Code background
# session instead of in a konsole window. Stubs: the claude binary the shim
# execs (LEG_CLAUDE_BIN) doubles as the CLI headed-arm.sh asks for the
# session census (HEADED_ARM_CLAUDE_CLI). Its launch call writes its argv to
# `record`, touches `confirmable` and prints the backgrounded line. After that,
# `agents --json` lists the session. pgrep answers only the daemon scan: pid
# 7777, whose environ carries stale vars that some other shell spawned the
# daemon with. The session inherits the daemon's env, not the caller's, and
# the launcher must override that env through the settings file.
mk_headless_stubs() {
  local dir="$1" name="$2"
  mkdir -p "$dir/proc/7777"
  cat > "$dir/claude" <<CLAUDE_EOF
#!/usr/bin/env bash
d="\$(dirname "\$0")"
if [ "\${1:-}" = agents ]; then
  [ -e "\$d/agents-fail" ] && exit 3
  [ -e "\$d/agents-object" ] && { echo '{}'; exit 0; }
  if [ -e "\$d/confirmable" ]; then
    printf '[{"pid":4242,"id":"abc12345","sessionId":"11111111-2222-3333-4444-555555555555","name":"%s","kind":"background","status":"idle"}]\n' "$name"
  else
    echo '[]'
  fi
  exit 0
fi
printf '%s\n' "\$*" >> "\$d/record"
: > "\$d/confirmable"
printf 'backgrounded · abc12345 · %s\n' "$name"
exit 0
CLAUDE_EOF
  chmod 755 "$dir/claude"
  cat > "$dir/pgrep" <<'PGREP_EOF'
#!/usr/bin/env bash
case "$*" in *'[c]laude daemon run'*) echo 7777; exit 0 ;; esac
exit 1
PGREP_EOF
  chmod 755 "$dir/pgrep"
  cat > "$dir/konsole" <<'KONSOLE_EOF'
#!/usr/bin/env bash
printf 'KONSOLE %s\n' "$*" >> "$(dirname "$0")/konsole-called"
KONSOLE_EOF
  chmod 755 "$dir/konsole"
  echo claude > "$dir/proc/7777/comm"
  printf 'claude\0daemon\0run\0--origin\0transient\0' > "$dir/proc/7777/cmdline"
  printf '%s\0' HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 HIMMEL_CONSOLE_DOC=/stale/console.md \
    LEG_STALE_MARK=stale HIMMEL_STALE_TOKEN=s3cret PATH=/usr/bin > "$dir/proc/7777/environ"
}
run_headless() {
  local stubdir="$1" repo="$2" name="$3"; shift 3
  IMPL_GUARD_OK='' HIMMEL_CONSOLE_LEG='' \
  HEADED_ARM_LEG_TARGET="$HEADED_ARM" \
  HEADED_ARM_LEG_PREFLIGHT="$PROCEED_PREFLIGHT" \
  KONSOLE_CMD="$stubdir/konsole" PGREP_CMD="$stubdir/pgrep" \
  LEG_CLAUDE_BIN="$stubdir/claude" HEADED_ARM_CLAUDE_CLI="$stubdir/claude" \
  LEG_REPO="$repo" HEADED_ARM_LOCK_DIR="$stubdir/locks" HEADED_ARM_PROC="$stubdir/proc" \
    bash "$SCRIPT" "$@" "$name" "$some_doc" "$stubdir/signal-never" "$PAST" "$stubdir/log" claude-sonnet-5
}

d29="$tmp/c29"; mk_headless_stubs "$d29" "HIMMEL-3403-hl"; mkdir -p "$tmp/repo29"
rc=0
HIMMEL_HOOK_INTEGRITY_BYPASS_OK='' HIMMEL_API_TOKEN=abc HIMMEL_MQTT_PASS=p1 HIMMEL_GITHUB_PAT=p2 \
  HIMMEL_PAT_RO=p3 HIMMEL_X_AUTH=p4 HIMMEL_SSH_KEY=p5 HIMMEL_DB_URL=p6 HIMMEL_EXAMPLE_BYPASS_OK=1 JIRA_PROJECT_KEY=HIMMEL \
  run_headless "$d29" "$tmp/repo29" "HIMMEL-3403-hl" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
rec29="$(cat "$d29/record" 2>/dev/null || true)"
log29="$(cat "$d29/log" 2>/dev/null || true)"
set29="$tmp/c29/HIMMEL-3403-hl.leg-settings.json"
check "29a --headless: exit 0" "$rc" "0"
contains "29b --headless: argv carries --bg" "$rec29" "--bg"
contains "29c --headless: argv declares --permission-mode auto" "$rec29" "--permission-mode auto"
contains "29d --headless: autocompact pin kept" "$rec29" "--autocompact 200000"
contains "29e --headless: session name kept" "$rec29" "-n HIMMEL-3403-hl"
contains "29f --headless: profile settings still injected" "$rec29" "--settings $set29"
check "29g --headless: konsole never called" "$([ -e "$d29/konsole-called" ] && echo called || echo none)" "none"
contains "29h launch log: headless=1" "$log29" "headless=1"
contains "29i launch log: claude pid" "$log29" "pid=4242"
contains "29j launch log: session id" "$log29" "session-id=11111111-2222-3333-4444-555555555555"
contains "29k launch log: short id" "$log29" "short-id=abc12345"
contains "29l launch log: exact argv" "$log29" "argv="
contains "29m launch log: output path" "$log29" "out=$d29/log"
dur29="$(cat "$HIMMELCTL_CACHE_DIR/launch-logs/HIMMEL-3403-hl.log" 2>/dev/null || true)"
contains "29n durable launch record: headless=1 pid=4242" "$dur29" "headless=1 pid=4242"
env29() { jq -r --arg k "$1" '.env[$k] // "<absent>"' "$set29" 2>/dev/null || echo "<nojson>"; }
check "29o settings env: HIMMEL_CONSOLE_LEG=1 (Guard E marker, set explicitly)" "$(env29 HIMMEL_CONSOLE_LEG)" "1"
check "29p settings env: HANDOVER_DIR mirrored" "$(env29 HANDOVER_DIR)" "$HANDOVER_DIR"
check "29q settings env: HIMMEL_INITIATIVE set" "$(env29 HIMMEL_INITIATIVE)" "execute,prcheck,pr,ticket,merge,public,handover"
check "29r settings env: daemon-injected hook-integrity bypass blanked" "$(env29 HIMMEL_HOOK_INTEGRITY_BYPASS_OK)" ""
check "29s settings env: stale console doc from the daemon blanked" "$(env29 HIMMEL_CONSOLE_DOC)" ""
check "29t settings env: stale LEG_* from the daemon blanked" "$(env29 LEG_STALE_MARK)" ""
check "29u settings env: secret-named daemon var blanked, never copied" "$(env29 HIMMEL_STALE_TOKEN)" ""
check "29v settings env: secret-named launcher var never copied" "$(env29 HIMMEL_API_TOKEN)" "<absent>"
check "29w settings env: non-pattern daemon var untouched" "$(env29 PATH)" "<absent>"
# 29v2: the stop-queue.mjs secret shapes, plus PASS and PAT as name tokens
# (HIMMEL_MQTT_PASS is the recorded trap there). BYPASS is not a PASS token,
# and JIRA_PROJECT_KEY is a key name, not a secret.
for v in HIMMEL_MQTT_PASS HIMMEL_GITHUB_PAT HIMMEL_PAT_RO HIMMEL_X_AUTH HIMMEL_SSH_KEY HIMMEL_DB_URL; do
  check "29v2 settings env: secret-shaped launcher var $v never copied" "$(env29 "$v")" "<absent>"
done
check "29v2 settings env: a *_BYPASS_OK gate is still mirrored" "$(env29 HIMMEL_EXAMPLE_BYPASS_OK)" "1"
check "29v2 settings env: JIRA_PROJECT_KEY is still mirrored" "$(env29 JIRA_PROJECT_KEY)" "HIMMEL"
check "29x settings file: mode 600 kept" "$(stat -c %a "$set29" 2>/dev/null || stat -f %Lp "$set29")" "600"  # gnu-ok: BSD stat -f fallback on the same line
check "29y settings file: profile keys preserved" "$(jq -r 'keys | length > 1' "$set29" 2>/dev/null)" "true"

# 29z: a launcher invoked WITH the bypass (an operator-approved hook-edit leg)
# hands the leg "1". Every other launch writes "" (29r above).
d29z="$tmp/c29z"; mk_headless_stubs "$d29z" "HIMMEL-3403-hlz"; mkdir -p "$tmp/repo29z"
rc=0
HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 run_headless "$d29z" "$tmp/repo29z" "HIMMEL-3403-hlz" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29z bypass-launched headless: exit 0" "$rc" "0"
check "29z bypass-launched headless: bypass written as 1" "$(jq -r '.env.HIMMEL_HOOK_INTEGRITY_BYPASS_OK' "$tmp/c29z/HIMMEL-3403-hlz.leg-settings.json" 2>/dev/null)" "1"

# 29-env: LEG_HEADLESS=1 in the launching shell does the same as the flag.
d29e="$tmp/c29e"; mk_headless_stubs "$d29e" "HIMMEL-3403-hle"; mkdir -p "$tmp/repo29e"
rc=0
LEG_HEADLESS=1 run_headless "$d29e" "$tmp/repo29e" "HIMMEL-3403-hle" --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29-env LEG_HEADLESS=1: exit 0" "$rc" "0"
contains "29-env LEG_HEADLESS=1: argv carries --bg" "$(cat "$d29e/record" 2>/dev/null)" "--bg"

# 29-dedup: a background session with this name is already listed, so the
# launcher does not start a second one.
d29d="$tmp/c29d"; mk_headless_stubs "$d29d" "HIMMEL-3403-hld"; mkdir -p "$tmp/repo29d"; : > "$d29d/confirmable"
rc=0
run_headless "$d29d" "$tmp/repo29d" "HIMMEL-3403-hld" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29-dedup already running: exit 0" "$rc" "0"
check "29-dedup already running: no second launch" "$([ -e "$d29d/record" ] && echo launched || echo none)" "none"

# 29-indet: if the census itself fails, the result is indeterminate (exit 9),
# never read as "not running".
d29i="$tmp/c29i"; mk_headless_stubs "$d29i" "HIMMEL-3403-hli"; mkdir -p "$tmp/repo29i"; : > "$d29i/agents-fail"
rc=0
run_headless "$d29i" "$tmp/repo29i" "HIMMEL-3403-hli" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29-indet census failed: exit 9" "$rc" "9"
check "29-indet census failed: nothing launched" "$([ -e "$d29i/record" ] && echo launched || echo none)" "none"
# 29-shape: a census that answers with something other than a JSON array is
# just as indeterminate as one that fails outright.
d29s="$tmp/c29s"; mk_headless_stubs "$d29s" "HIMMEL-3403-hls"; mkdir -p "$tmp/repo29s"; : > "$d29s/agents-object"
rc=0
run_headless "$d29s" "$tmp/repo29s" "HIMMEL-3403-hls" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29-shape non-array census: exit 9" "$rc" "9"
check "29-shape non-array census: nothing launched" "$([ -e "$d29s/record" ] && echo launched || echo none)" "none"
# 29-qual: the service is qualified on its cmdline, not its comm (a bg
# process's comm can be the CLI version string), so its env is still read.
d29q="$tmp/c29q"; mk_headless_stubs "$d29q" "HIMMEL-3403-hlq"; mkdir -p "$tmp/repo29q"
echo 2.1.300 > "$d29q/proc/7777/comm"
rc=0
run_headless "$d29q" "$tmp/repo29q" "HIMMEL-3403-hlq" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29-qual version-string comm: exit 0" "$rc" "0"
check "29-qual version-string comm: service env still read (stale doc blanked)" "$(jq -r '.env.HIMMEL_CONSOLE_DOC // "<absent>"' "$d29q/HIMMEL-3403-hlq.leg-settings.json" 2>/dev/null)" ""
# 29-noqual: pgrep matched a process that is not the service (the pattern sits
# inside another command's argv). No qualifying pid = refuse, never launch blind.
d29n="$tmp/c29n"; mk_headless_stubs "$d29n" "HIMMEL-3403-hln"; mkdir -p "$tmp/repo29n"
echo bash > "$d29n/proc/7777/comm"
printf 'bash\0-c\0echo claude daemon run\0' > "$d29n/proc/7777/cmdline"
rc=0
run_headless "$d29n" "$tmp/repo29n" "HIMMEL-3403-hln" --headless --profile leg-impl >/dev/null 2>&1 || rc=$?
check "29-noqual no qualifying service pid: exit 9" "$rc" "9"
check "29-noqual no qualifying service pid: nothing launched" "$([ -e "$d29n/record" ] && echo launched || echo none)" "none"
# 29-role: a headless console launch (headed-arm.sh --role console) drops the
# relay marker from the settings env, the same `env -u` a konsole launch gets.
d29r="$tmp/c29r"; mk_headless_stubs "$d29r" "HIMMEL-3403-hlr"; mkdir -p "$tmp/repo29r" "$d29r/chain"
echo '{"permissions":{}}' > "$d29r/settings.json"
rc=0
HIMMEL_CONSOLE_RELAY=1 HEADED_ARM_HEADLESS=1 LEG_PROFILE_SETTINGS="$d29r/settings.json" \
  HEADED_ARM_LAUNCHER="$d29r/claude" HEADED_ARM_CLAUDE_CLI="$d29r/claude" \
  PGREP_CMD="$d29r/pgrep" KONSOLE_CMD="$d29r/konsole" HEADED_ARM_PROC="$d29r/proc" \
  HEADED_ARM_LOCK_DIR="$d29r/locks" HEADED_ARM_REPO="$tmp/repo29r" \
  bash "$HEADED_ARM" --role console "HIMMEL-3403-hlr" "$some_doc" "$d29r/chain/signal-never" "$PAST" "$d29r/log" claude-sonnet-5 >/dev/null 2>&1 || rc=$?
check "29-role headless console: exit 0" "$rc" "0"
check "29-role headless console: relay marker blanked in settings env" "$(jq -r '.env.HIMMEL_CONSOLE_RELAY // "<absent>"' "$d29r/settings.json" 2>/dev/null)" ""

# 29-refusals: --headless relies on the settings file for the leg's env, so an
# unprofiled launch refuses. The claudex lane's script(1) wrapper has no bg form.
rc=0; out="$(bash "$SCRIPT" --dry-run --headless --no-profile HIMMEL-3403-x some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "29-refuse --headless --no-profile: exit 2" "$rc" "2"
contains "29-refuse --headless --no-profile: names the reason" "$out" "--headless needs a profile"
rc=0; out="$(bash "$SCRIPT" --dry-run --headless --lane claudex --profile leg-impl HIMMEL-3403-x some/doc.md /tmp/nosig 99999999999 /tmp/leg.log claude-sonnet-5 2>&1)" || rc=$?
check "29-refuse --headless --lane claudex: exit 2" "$rc" "2"

# 29-dry: a --headless dry-run says so. The no-flag dry-run never mentions it
# (the headed report is unchanged).
rc=0; out="$(LEG_CONTEXT='' LEG_REPO='' bash "$SCRIPT" --dry-run --headless --profile leg-impl HIMMEL-3403-x "$some_doc" /tmp/nosig 99999999999 "$tmp/dry29.log" claude-sonnet-5 2>&1)" || rc=$?
check "29-dry --headless: exit 0" "$rc" "0"
contains "29-dry --headless: reports headless=1" "$out" "headless=1"
contains "29-dry --headless: would-exec argv carries --bg" "$out" "--bg"
rc=0; out="$(LEG_HEADLESS='' LEG_CONTEXT='' LEG_REPO='' bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-3403-x "$some_doc" /tmp/nosig 99999999999 "$tmp/dry29b.log" claude-sonnet-5 2>&1)" || rc=$?
not_contains "29-dry no flag: headed report never mentions headless=" "$out" "headless="
not_contains "29-dry no flag: headed argv has no --bg" "$out" "--bg"
# 31. HIMMEL-2534: macOS `open -a` starts a leg from a FRESH environment (only
# PATH is re-injected, konsole-macos.sh's own policy, untouched by this fix) -
# a plain `export` in this wrapper never reaches the launched leg process on
# that platform. leg_propagate_env folds every leg-process var this wrapper
# sets into HEADED_ARM_LAUNCHER_ENV's explicit token list instead, since those
# tokens are baked into headed-arm.sh's own exec argv (the `env NAME=VALUE...`
# line), which DOES cross the boundary. These cases pin the propagated set,
# the caller-preset-wins contract, and the whitespace refusal.

# 31a. --profile leg-impl: launcher-env= carries every leg-process var this
# profile launch sets - the shim's own contract vars (LEG_PROFILE_SETTINGS,
# LEG_PROFILE_PREFACE, and LEG_PROFILE_MCP_CONFIG since leg-impl declares
# mcpServers, HIMMEL-2935) plus the always-on leg markers (HIMMEL_CONSOLE_LEG,
# IMPL_GUARD_OK, INLINE_IMPL_OK, HIMMEL_LEAN_LEG).
out31a="$(bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg-31a some/doc.md /tmp/nosig 99999999999 "$tmp/leg31a.log" claude-sonnet-5 2>&1)"
lenv29a="$(printf '%s\n' "$out31a" | grep '^headed-arm-leg: lane=')"
contains "31a launcher-env carries LEG_PROFILE_SETTINGS=" "$lenv29a" "LEG_PROFILE_SETTINGS=$tmp/HIMMEL-9999-leg-31a.leg-settings.json"
contains "31a launcher-env carries LEG_PROFILE_PREFACE=" "$lenv29a" "LEG_PROFILE_PREFACE=$tmp/HIMMEL-9999-leg-31a.leg-preface.md"
contains "31a launcher-env carries LEG_PROFILE_MCP_CONFIG=" "$lenv29a" "LEG_PROFILE_MCP_CONFIG=$tmp/HIMMEL-9999-leg-31a.leg-mcp.json"
contains "31a launcher-env carries HIMMEL_CONSOLE_LEG=1" "$lenv29a" "HIMMEL_CONSOLE_LEG=1"
contains "31a launcher-env carries IMPL_GUARD_OK=1" "$lenv29a" "IMPL_GUARD_OK=1"
contains "31a launcher-env carries INLINE_IMPL_OK=1" "$lenv29a" "INLINE_IMPL_OK=1"
contains "31a launcher-env carries HIMMEL_LEAN_LEG=1" "$lenv29a" "HIMMEL_LEAN_LEG=1"

# 31b. A caller-preset HEADED_ARM_LAUNCHER_ENV is preserved (appended to, not
# replaced) and wins on a name clash - leg_propagate_env only ever adds a NAME
# not already present as a token.
out31b="$(HEADED_ARM_LAUNCHER_ENV='HIMMEL_CONSOLE_LEG=caller-preset SOME_OTHER_TOKEN=x' bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg-31b some/doc.md /tmp/nosig 99999999999 "$tmp/leg31b.log" claude-sonnet-5 2>&1)"
lenv29b="$(printf '%s\n' "$out31b" | grep '^headed-arm-leg: lane=')"
contains "31b caller-preset HEADED_ARM_LAUNCHER_ENV token is preserved" "$lenv29b" "SOME_OTHER_TOKEN=x"
contains "31b caller-preset value wins on a name clash (HIMMEL_CONSOLE_LEG)" "$lenv29b" "HIMMEL_CONSOLE_LEG=caller-preset"
not_contains "31b the wrapper's own HIMMEL_CONSOLE_LEG=1 is not also added" "$lenv29b" "HIMMEL_CONSOLE_LEG=1"
contains "31b the wrapper still appends its own vars after the caller's" "$lenv29b" "IMPL_GUARD_OK=1"

# 31c. A leg-process value containing whitespace is refused loudly (exit 12)
# rather than silently mis-split into extra bogus HEADED_ARM_LAUNCHER_ENV
# tokens - the var is a whitespace-split token list with no quoting scheme
# (same contract as CODEX_BANK_PROBE_CMD). HIMMEL-2534 follow-up (case 32):
# this refusal is Darwin-only, so pin the seam explicitly rather than rely on
# the test runner's real platform (this box happens to be Darwin too, but
# case 32c below proves the non-Darwin branch takes a different path).
mkdir -p "$tmp/space dir"
rc=0
err29c="$(HEADED_ARM_UNAME=Darwin bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg-31c some/doc.md /tmp/nosig 99999999999 "$tmp/space dir/leg.log" claude-sonnet-5 2>&1)" || rc=$?
check "31c a whitespace-carrying leg-process value is refused with exit 12" "$rc" "12"
contains "31c the refusal names the offending var" "$err29c" "LEG_PROFILE_SETTINGS"
contains "31c the refusal explains why (HEADED_ARM_LAUNCHER_ENV cannot carry a spacey value)" "$err29c" "cannot carry"

# 32a. HIMMEL-2534 follow-up (GAP): a caller-preset HANDOVER_DIR - the normal
# case for a grouped console, which sets it before this wrapper ever runs -
# must reach launcher-env= exactly like the wrapper-resolved case (26/31)
# does. Before this fix, the resolve-if-unset block was skipped entirely
# for a caller-preset value, so nothing propagated it.
out32a="$(HANDOVER_DIR="$tmp/preset-hd-32a" bash "$SCRIPT" --dry-run --no-profile HIMMEL-9999-leg-32a some/doc.md /tmp/nosig 99999999999 "$tmp/leg32a.log" claude-sonnet-5 2>&1)"
lenv30a="$(printf '%s\n' "$out32a" | grep '^headed-arm-leg: lane=')"
contains "32a a caller-preset HANDOVER_DIR reaches launcher-env=" "$lenv30a" "HANDOVER_DIR=$tmp/preset-hd-32a"

# 32b. Darwin: the whitespace refusal is unchanged (regression guard for the
# restructured leg_propagate_env - same outcome as 31c, pinned explicitly).
rc=0
err30b="$(HEADED_ARM_UNAME=Darwin bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg-32b some/doc.md /tmp/nosig 99999999999 "$tmp/space dir/leg32b.log" claude-sonnet-5 2>&1)" || rc=$?
check "32b Darwin still refuses a whitespace-carrying value with exit 12" "$rc" "12"
contains "32b the refusal still names the offending var" "$err30b" "LEG_PROFILE_SETTINGS"

# 32c. HIMMEL-2534 follow-up (REGRESSION RISK): on any platform other than
# Darwin, plain-export inheritance already carried a whitespace-carrying
# leg-process value to the leg BEFORE HIMMEL-2534 (e.g. a Linux leg). That
# must stay literally true - the launch still succeeds, no token is added
# for that one var (it would corrupt HEADED_ARM_LAUNCHER_ENV's token list),
# and a warning on stderr explains why.
rc=0
out32c="$(HEADED_ARM_UNAME=Linux bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg-32c some/doc.md /tmp/nosig 99999999999 "$tmp/space dir/leg32c.log" claude-sonnet-5 2>&1)" || rc=$?
check "32c non-Darwin: a whitespace-carrying value still launches (dry-run exit 0)" "$rc" "0"
lenv30c="$(printf '%s\n' "$out32c" | grep '^headed-arm-leg: lane=')"
not_contains "32c non-Darwin: no LEG_PROFILE_SETTINGS token is added" "$lenv30c" "LEG_PROFILE_SETTINGS="
contains "32c non-Darwin: the wrapper still appends its other, non-spacey vars" "$lenv30c" "HIMMEL_CONSOLE_LEG=1"
contains "32c non-Darwin: a stderr warning explains the value was left to inheritance" "$out32c" "leaving it to plain-export inheritance"
contains "32c non-Darwin: the warning names the platform" "$out32c" "harmless on Linux"

# 33. HIMMEL-2534 (#1122 CR fix): HIMMEL_CONSOLE_NAME (HIMMEL-3435) is a
# leg-process var too - #1121 routed a leg's merge-block alert to the owning
# console's inbox via this env var, and on macOS a plain `export` never
# crosses `open -a`'s fresh-environment boundary any more than the other
# leg-process vars above do. A naive main-merge resolution that keeps BOTH
# sides (HIMMEL_CONSOLE_LEG via leg_propagate_env, HIMMEL_CONSOLE_NAME via a
# bare export) passes every other case in this file - only these two rows
# distinguish it, by asserting the token reaches launcher-env=, not just the
# --dry-run report string cases 3-6/HIMMEL-3435 above already cover.

# 33a. --console <name>: the flag-sourced name reaches launcher-env=.
out33a="$(bash "$SCRIPT" --dry-run --console opsdesk --profile leg-impl HIMMEL-9999-leg-33a some/doc.md /tmp/nosig 99999999999 "$tmp/leg33a.log" claude-sonnet-5 2>&1)"
lenv33a="$(printf '%s\n' "$out33a" | grep '^headed-arm-leg: lane=')"
contains "33a launcher-env carries HIMMEL_CONSOLE_NAME=opsdesk (--console)" "$lenv33a" "HIMMEL_CONSOLE_NAME=opsdesk"

# 33b. Inherited (no --console): the launching shell's own HIMMEL_CONSOLE_NAME
# reaches launcher-env= the same way.
out33b="$(HIMMEL_CONSOLE_NAME=ambient-console bash "$SCRIPT" --dry-run --profile leg-impl HIMMEL-9999-leg-33b some/doc.md /tmp/nosig 99999999999 "$tmp/leg33b.log" claude-sonnet-5 2>&1)"
lenv33b="$(printf '%s\n' "$out33b" | grep '^headed-arm-leg: lane=')"
contains "33b launcher-env carries HIMMEL_CONSOLE_NAME=ambient-console (inherited)" "$lenv33b" "HIMMEL_CONSOLE_NAME=ambient-console"

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASS - test-headed-arm-leg.sh"
  exit 0
else
  echo "FAIL - test-headed-arm-leg.sh ($fails failure(s))"
  exit 1
fi
