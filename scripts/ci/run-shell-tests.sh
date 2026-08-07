#!/usr/bin/env bash
# scripts/ci/run-shell-tests.sh — discover + run himmel's hermetic shell suites.
#
# Runs every `<scan-root>/**/test-*.sh` EXCEPT the suites listed in SKIP_LIST,
# which need the full agent stack (claude / hermes / docker), a live VM, or
# network / git-remote access — none of which exist on a bare CI runner. That
# SKIP_LIST is the ledger of "what we can't test here"; everything else is
# "what we can".
#
# Phased-CI intent (HIMMEL-494): the first runs are a discovery instrument. A
# suite that fails only because of a missing runner capability gets moved into
# SKIP_LIST (with a reason) until the job is green; a suite that fails for a
# real bug stays red. Keep SKIP_LIST minimal and justified.
#
# Usage:
#   scripts/ci/run-shell-tests.sh                        # run all non-skipped suites under scripts/
#   scripts/ci/run-shell-tests.sh [scan-root]            # run under a different root
#   scripts/ci/run-shell-tests.sh --list [scan-root]     # print run/skip plan, run nothing
#   scripts/ci/run-shell-tests.sh --skip-extra <relpath> # add an ad-hoc skip (repeatable)
#   scripts/ci/run-shell-tests.sh --changed-since <ref>  # additionally skip conditional suites
#                                                        # whose scope is unchanged since <ref>
#
#   Flags may appear before or after the scan-root.
#   scan-root defaults to "scripts" when omitted.
#
#   --changed-since <ref> (or env SUITE_CHANGED_SINCE) is OPT-IN: without it,
#   every suite runs exactly as today. With it, a suite listed in
#   SUITE_CONDITIONAL runs only if a changed path (git diff --name-only <ref>
#   plus untracked) matches its ERE; a non-matching conditional suite is SKIPped
#   with a reason. A default-on filter would silently drop a leak-barrier suite
#   from a clean CI checkout, and silently reduced coverage is worse than a slow
#   run. Not a git repo / unresolvable ref / failing diff -> fail-open: run all.
#
# Exit codes: 0 — one or more suites ran and all passed; 1 — at least one suite
#             failed, OR zero suites ran (a resolved-to-nothing scan root is a
#             misconfiguration, not a pass — HIMMEL-1128), OR the run budget
#             expired with suites still unrun; 2 — REFUSED, another full-suite
#             run already holds the machine lock (HIMMEL-1338).
#
# CONCURRENCY (HIMMEL-1338): on 2026-07-28 five sessions had this runner going
# at once on one workstation; the oldest had been at it for 150 minutes. The
# runs were not deadlocked — they were starving each other. Every concurrent
# run multiplies the process churn (~1000 processes / 200 live bash at the
# sample), each suite then takes 5-20x longer, and the per-suite cap starts
# firing on suites that are merely slow. The runs test the SAME TREE, so all
# but one of them is pure waste. Hence a machine-wide advisory lock: the
# second concurrent run REFUSES (rc 2) and says who holds it, rather than
# piling on. Knobs, all env:
#
#   SUITE_TIMEOUT      per-suite wall-clock cap, seconds (default 180)
#   SUITE_RUN_BUDGET   whole-run wall-clock cap, seconds (default 7200); the
#                      runner stops BETWEEN suites once it is spent and names
#                      what did not run, instead of running until morning
#   SUITE_LOCK         0 disables the machine lock entirely
#   SUITE_LOCK_DIR     override the lock path (tests use their own sandbox);
#                      by default the path is keyed by SCAN ROOT, so a scoped
#                      subtree run does not queue behind a full-tree one
#   SUITE_LOCK_TTL     seconds after which a held lock is presumed abandoned
#                      (default 14400 = 4h) even if its pid still answers
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

# REPO_ROOT is used only to source libs the runner itself needs; it is NOT
# used for discovery. Discovery uses $scan (the positional scan-root arg).
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT" || exit 1

# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/proc-tree.sh"

# Pin git fsync/template settings for the throwaway repos the suites build, so
# the exports flow to EVERY suite subprocess the loop below spawns. Sourced here
# (not in each suite) so a single pin covers the whole tree; idempotent via its
# own marker, so a suite that re-sources the lib inherits without duplicating.
# shellcheck source=../lib/git-test-env.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/git-test-env.sh"

# _suite_num <name> <value> <default> — a POSITIVE integer, or the default with
# a warning. Every knob below feeds arithmetic or `sleep`, where a bad value
# does not fail loudly: SUITE_TIMEOUT=abc makes `sleep abc` complain and return
# immediately (no cap at all), and SUITE_RUN_BUDGET=08 dies as an invalid octal
# constant. Both disable a guard while looking configured, which is the failure
# mode this file exists to remove. `10#` forces base 10 so a zero-padded value
# is read as decimal rather than octal — the same fix critic-panel.sh applies
# to its own timeout knob.
#
# Zero is rejected, not accepted as "no limit". Every one of these knobs reads
# a 0 as "already expired": SUITE_LOCK_TTL=0 makes `age -ge 0` true for a lock
# created microseconds ago, so EVERY live lock is instantly reclaimable and the
# concurrency guard silently ceases to exist; SUITE_TIMEOUT=0 kills every suite
# on sight. A knob whose zero value disables the thing it configures is a
# footgun, so the only way to turn a guard off is the explicit switch
# (SUITE_LOCK=0), never a quiet 0 in a duration.
_suite_num() {
  local _v
  case "$2" in
    ''|*[!0-9]*)
      printf 'WARN: %s="%s" is not a positive integer — using %s\n' "$1" "$2" "$3" >&2
      printf '%s' "$3"
      return 0
      ;;
  esac
  _v=$(( 10#$2 ))
  if [ "$_v" -lt 1 ]; then
    printf 'WARN: %s="%s" must be >= 1 (0 would disable the guard it configures) — using %s\n' \
      "$1" "$2" "$3" >&2
    printf '%s' "$3"
    return 0
  fi
  printf '%s' "$_v"
}

# Per-suite wall-clock cap so a hung suite can't stall the whole job. An
# explicit value remains a global override; otherwise the small table below
# gives only measured slow suites more room while the default stays tight.
# Explicit means SUPPLIED AND VALID, not merely present. `${SUITE_TIMEOUT+x}`
# marks presence, so an empty / zero / non-numeric value used to count as an
# explicit global override while _suite_num quietly fell back to 180 -- pinning
# every slow suite to 180s and recreating the exact rc=124 failures this table
# exists to prevent (the 1363s identity suite would get 180s, not 1800s). A
# malformed knob must fall back to the path-specific defaults, matching the
# malformed-knob invariant _suite_num already implements.
SUITE_TIMEOUT_EXPLICIT=''
case "${SUITE_TIMEOUT:-}" in
  ''|*[!0-9]*) ;;                                        # unset, empty, or non-numeric
  *) [ "$SUITE_TIMEOUT" -ge 1 ] && SUITE_TIMEOUT_EXPLICIT=x ;;
esac
SUITE_TIMEOUT=$(_suite_num SUITE_TIMEOUT "${SUITE_TIMEOUT:-180}" 180)
_suite_timeout_for() {
  if [ -n "$SUITE_TIMEOUT_EXPLICIT" ]; then
    printf '%s' "$SUITE_TIMEOUT"
    return 0
  fi

  case "${1#./}" in
    scripts/handover/test-arm-resume-identity.sh|*/scripts/handover/test-arm-resume-identity.sh)
      printf '1800' ;; # measured 1363s after the original HIMMEL-1542 ticket
    scripts/cr/test-clear-cr-marker.sh|*/scripts/cr/test-clear-cr-marker.sh)
      printf '900' ;;  # measured 554s
    scripts/guardrails/test-graphify-fence.sh|*/scripts/guardrails/test-graphify-fence.sh)
      printf '600' ;;  # measured 344s
    scripts/guardrails/test-lesson-write-fence.sh|*/scripts/guardrails/test-lesson-write-fence.sh)
      printf '600' ;;  # measured 304s
    scripts/cr/test-critic-panel.sh|*/scripts/cr/test-critic-panel.sh)
      printf '450' ;;  # measured 251s
    *)
      printf '%s' "$SUITE_TIMEOUT" ;;
  esac
}
# Whole-run cap. A run that overruns this stops cleanly and reports, so an
# unattended session cannot leave one grinding for hours.
#
# Deliberately generous. This is a backstop against a runaway run, not a
# performance target: the nightly matrix runs this on a windows-latest runner
# where MSYS forks are slow and the job has no timeout-minutes of its own, so a
# tight default would turn a merely slow CI leg red. Two hours still bounds the
# case this ticket came from (the observed run was at 150 minutes and climbing)
# while being implausible for a healthy run on any platform. Lower it per-run
# when you want a tighter leash.
SUITE_RUN_BUDGET=$(_suite_num SUITE_RUN_BUDGET "${SUITE_RUN_BUDGET:-7200}" 7200)

# Machine-wide lock over full-suite runs. A DIRECTORY, because mkdir is atomic
# on NTFS/Git-Bash without relying on O_EXCL semantics -- the same primitive
# scripts/handover/queue-lock.sh uses, and for the same reason.
#
# KEYED BY SCAN ROOT, so the refusal message's advice ("scope this run to the
# subtree you changed") is actually actionable — with one global lock it was
# not: a scoped run took the same lock and got the same refusal, which would
# have pushed people to SUITE_LOCK=0 and defeated the whole thing.
#
# The key is the scan root AS GIVEN — deliberately NOT its absolute path. The
# runs this bounds come from sessions in DIFFERENT worktrees, so keying on an
# absolute path would hand each worktree its own lock and bound nothing at
# all. Every default full-suite run resolves to "scripts" wherever it is
# launched from, which is exactly the set that must serialise.
SUITE_LOCK="${SUITE_LOCK:-1}"
SUITE_LOCK_TTL=$(_suite_num SUITE_LOCK_TTL "${SUITE_LOCK_TTL:-14400}" 14400)
# Resolved after arg parsing (it depends on $scan); an explicit env value is
# honoured verbatim, which is how the tests get their own sandboxed lock.
SUITE_LOCK_DIR="${SUITE_LOCK_DIR:-}"

# Suites that cannot run on a bare runner. One SCAN-ROOT-RELATIVE path per
# entry. Each: "<relpath>   # <reason>". Keep the reason — it documents the gap.
#
# CI policy (HIMMEL-594): CI runs UNIT tests only — no API keys, no secrets, no
# 3rd-party/network (claude / hermes / codex-OAuth / Jira-API). Suites needing
# those are INTEGRATION tests and belong on the VM e2e (host .env keys copied in,
# codex via OAuth), not here. The VM-e2e-with-keys harness + per-skill/plugin
# test reorg are tracked as a follow-up epic; until then these are skipped on CI.
#
# Paths are relative to $scan (default: scripts), so the entry
# "test-install-symmetry-vm.sh" matches scripts/test-install-symmetry-vm.sh
# when the default scan root is used.
SKIP_LIST="
test-install-symmetry-vm.sh          # drives a real VM over SSH
test-luna-upgrade-vm.sh              # drives a real (Ubuntu or Windows) VM over SSH
test-himmel-update.sh                # live git pull + marketplace re-sync
test-himmel-update-hermes.sh         # needs the hermes runtime
hermes/test-invoke.sh                # needs the hermes runtime
gemini/test-invoke.sh                # needs the gemini-cli binary
cr/test-hermes-critic.sh             # integration: needs the hermes runtime (no keys on CI) — VM e2e covers it
handover/test-hop.sh                 # integration: needs a live 'claude' (--print relaunch) — VM e2e covers it
handover/test-resume-armed.sh        # integration: needs the bun runtime + armed-resume flow — VM e2e covers it
handover/test-arm-resume.sh          # timing-heavy Windows scheduler lifecycle suite exceeds the 180s hermetic runner cap; runnable individually, no VM e2e coverage
luna/test-pipeline-cadence.sh        # integration: drives a live 'claude' (--settings fragment) — VM e2e covers it
test-plugin-test.sh                  # integration: self-bootstraps a plugin's deps over npm/network — VM e2e covers it
test-adopt.sh                        # timing-heavy full adoption matrix exceeds the 180s hermetic runner cap on Windows; runnable individually, no VM e2e coverage
"

# Conditional suites (HIMMEL-1589). Unlike SKIP_LIST (always skipped), a
# conditional suite runs by default and is only held back when --changed-since
# is active AND no changed path matches its ERE. One entry per line:
#   <scan-root-relative suite path>  <ERE over repo-relative changed paths>  # <reason>
# The ERE is matched (grep -E, unanchored unless you anchor it) against each
# repo-relative changed path from `git diff --name-only <ref>` + untracked.
# test-propagate-public.sh is a LEAK-BARRIER suite: it must NOT move into
# SKIP_LIST (that would drop it from every full run); it is conditional instead,
# so a change unrelated to the propagation path skips it under --changed-since
# while a full run still always exercises it.
SUITE_CONDITIONAL="
test-propagate-public.sh  ^scripts/(propagate-public|lib/public-clone-paths|test-propagate-public)\.sh$  # leak-barrier suite; only the propagation path can break it
"

# extra_skips accumulates paths added via --skip-extra flags.
# Each entry is a newline-terminated scan-root-relative path.
extra_skips=""

# --------------------------------------------------------------------------
# is_skipped <relpath>
# Returns 0 (true = skip) and prints the reason; returns 1 (false = run).
# Checks SKIP_LIST first, then extra_skips.
# --------------------------------------------------------------------------
is_skipped() {
  local needle="$1"
  local _line _path
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _path=${_line%%#*}
    _path=$(printf '%s' "$_path" | tr -d '[:space:]')
    [ -n "$_path" ] || continue
    if [ "$_path" = "$needle" ]; then
      printf '%s' "${_line#*# }"
      return 0
    fi
  done <<EOF
$SKIP_LIST
EOF
  # Also check extra_skips (no inline reason; just the path).
  if [ -n "$extra_skips" ]; then
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if [ "$_path" = "$needle" ]; then
        printf '%s' "skipped via --skip-extra"
        return 0
      fi
    done <<EOF2
$extra_skips
EOF2
  fi
  return 1
}

# --------------------------------------------------------------------------
# Conditional-suite helpers (HIMMEL-1589). See SUITE_CONDITIONAL above. These
# are inert unless --changed-since resolved a changed set (conditional_filter_active=1).
# --------------------------------------------------------------------------

# conditional_ere <relpath> -> echoes the ERE for that suite and returns 0;
# returns 1 when the suite is not in SUITE_CONDITIONAL. Parses one table line
# "<relpath>  <ERE>  # <reason>" via `read` (bash 3.2-safe; collapses the
# whitespace between the fields and strips the trailing comment).
conditional_ere() {
  local needle="$1" _line _path _ere
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _line=${_line%%#*}                 # drop trailing "# reason" -> "<relpath>  <ERE>"
    read -r _path _ere <<< "$_line"    # first token = relpath, rest = ERE
    [ -n "$_path" ] || continue
    if [ "$_path" = "$needle" ]; then
      printf '%s' "$_ere"
      return 0
    fi
  done <<EOF
$SUITE_CONDITIONAL
EOF
  return 1
}

# conditional_matches <ERE> -> 0 if any path in the global $changed_set matches
# the ERE, 1 otherwise. Here-string (not a pipeline) so a grep -q match can't
# take SIGPIPE under `set -o pipefail` — the same trap grepq elsewhere documents.
conditional_matches() {
  local ere="$1" _p
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    if grep -Eq "$ere" <<< "$_p"; then
      return 0
    fi
  done <<EOF
$changed_set
EOF
  return 1
}

# --------------------------------------------------------------------------
# Machine-wide lock over full-suite runs (HIMMEL-1338).
#
# Only the EXECUTION path takes it: `--list` reads the tree and runs nothing,
# so making it queue behind a live run would be friction with no payoff.
#
# RE-ENTRANCY is not optional. scripts/ci/test-run-shell-tests.sh invokes this
# runner fifteen times, and the full suite runs that test — so a lock that did
# not recognise its own descendants would deadlock the very suite it protects.
# The holder exports HIMMEL_SUITE_LOCK_HELD with the lock path it owns; a
# nested invocation targeting that same path passes through. Comparing the
# PATH rather than a bare "am I nested" flag keeps a nested run that was
# pointed at a DIFFERENT lock (the regression test does exactly this) honest —
# it still has to acquire.
# --------------------------------------------------------------------------
suite_lock_owned=0

# bash already knows the hostname; shelling out for it costs a fork and, on
# Windows, can stall on a name lookup. `hostname` stays as the last resort for
# a shell that set neither variable.
_suite_lock_host() {
  printf '%s' "${HOSTNAME:-${COMPUTERNAME:-$(hostname 2>/dev/null || echo unknown)}}"
}

# _suite_lock_drop — remove a lock directory, deleting NOTHING until the
# directory has been proven to be one.
#
# SUITE_LOCK_DIR is env-overridable, so every delete here is aimed by a
# variable a typo can point anywhere. Leaning on `rmdir` to refuse a non-empty
# directory is not enough on its own: the `owner` file is unlinked FIRST, so a
# mis-set path at a real directory that happens to contain a file of that name
# loses it before rmdir ever gets a say — the guard fires after the damage.
#
# The invariant is checked up front instead: a lock this script created holds
# exactly one entry, named `owner`. A directory holding anything else is not
# ours, so nothing in it is touched and the caller refuses. Returns non-zero
# when the directory was not dropped, for either reason.
_suite_lock_drop() {
  local _f
  # A symlink is never a lock this script made. Globbing through one inspects
  # the TARGET while `rm` writes through it, so every content check above would
  # be answered by one directory and acted on in another.
  [ -L "$1" ] && return 1
  for _f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      case "$_f" in
        "$1"/owner) ;;
        *) return 1 ;;
      esac
    fi
  done
  rm -f "$1/owner" 2>/dev/null
  rmdir "$1" 2>/dev/null
}

# _suite_lock_dir_empty <dir> — 0 when the directory holds nothing at all.
# Globs, not `ls`: parsing ls output is unsafe, and this needs no forks.
_suite_lock_dir_empty() {
  local _f
  for _f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    # Spelled out rather than `[ … ] || [ … ] && return 1`: that parses
    # correctly by left-associativity, but it reads as a conditional-return and
    # is a well-known way to introduce a bug during a later edit.
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      return 1
    fi
  done
  return 0
}

# _suite_lock_owner_raw <dir> — the whole owner file, or "" when absent. The
# CAS token for a takeover: comparing the full generation catches a lock that
# changed hands between judging it and acting on that judgement.
_suite_lock_owner_raw() {
  cat "$1/owner" 2>/dev/null || printf ''
}

# _suite_lock_reclaim <expected-owner-raw> — take over a lock judged abandoned.
#
# Dropping-then-claiming is NOT safe on its own, and the comment that used to
# sit here ("exactly one mkdir wins the reopened race") was wrong. Two runs
# that both judge the same lock stale interleave like this:
#
#   A: drop → mkdir → brand          B: (already decided stale) drop
#
# B's drop removes A's FRESH brand and then rmdir's A's now-empty directory,
# so B claims too and both believe they hold the lock — the lock admitting
# exactly the concurrency it exists to prevent.
#
# So the right to take over is itself an exclusive resource, claimed with the
# one primitive that is atomic here: mkdir. This mirrors the takeover protocol
# in scripts/handover/queue-lock.sh, which arrived at the same design after
# the same class of race (and after finding `mv` unreliable on MSYS).
#
#   1. mkdir <lock>.claim — exactly one contender wins the right to take over.
#   2. CAS re-verify UNDER the claim: the lock's owner must still be the
#      generation we judged. Anything else means it changed hands while we
#      deliberated — it is LIVE, so abort rather than destroy it.
#   3. Only then drop and re-acquire.
#
# Returns 0 when this process now holds the lock, 1 otherwise (every failure
# is an ordinary refusal — someone else got there first).
_suite_lock_reclaim() {
  local expected="$1" claim="${SUITE_LOCK_DIR}.claim" rc=1 c_started c_age

  if ! mkdir "$claim" 2>/dev/null; then
    # A crashed taker must not wedge takeovers forever. The claim is branded
    # immediately after its mkdir, so give that a moment before judging —
    # otherwise a legitimate taker gets clobbered inside its own brand window.
    local _cs=0
    while [ ! -f "$claim/owner" ] && [ "$_cs" -lt 20 ]; do
      sleep 0.05
      _cs=$((_cs + 1))
    done
    c_started=$(_suite_lock_owner_field "$claim/owner" started)
    c_age=-1
    case "$c_started" in
      ''|*[!0-9]*) ;;
      *) c_age=$(( $(date +%s) - 10#$c_started )) ;;
    esac
    # A claim is only honoured when it can be shown to be FRESH. Anything else
    # — no owner file at all, an unparseable timestamp, or simply old — is
    # abandoned and gets cleared.
    #
    # "Cannot be dated, so treat it as live" is the wrong default HERE, and
    # this is the same mistake the lock directory already had fixed one level
    # up: an unbranded husk left by a crash in the microsecond window between
    # mkdir and brand would otherwise block every future takeover of this lock
    # forever, with no path back except a human deleting a directory in /tmp.
    # A claim is held for milliseconds by construction, so failing open here
    # costs a rare double-takeover; failing closed costs the guard entirely.
    if [ "$c_age" -ge 0 ] && [ "$c_age" -lt 120 ]; then
      return 1
    fi
    printf 'NOTE: clearing a stranded takeover claim (age %ss) at %s\n' "$c_age" "$claim" >&2
    _suite_lock_drop "$claim" || return 1
    mkdir "$claim" 2>/dev/null || return 1
  fi
  # Brand the claim so its age is readable and a co-winner of a non-atomic
  # mkdir (uutils, HIMMEL-966) loses here instead.
  if ! ( set -C; printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$claim/owner" ) 2>/dev/null; then
    [ -e "$claim/owner" ] || rmdir "$claim" 2>/dev/null
    return 1
  fi

  if [ "$(_suite_lock_owner_raw "$SUITE_LOCK_DIR")" = "$expected" ]; then
    if _suite_lock_drop "$SUITE_LOCK_DIR"; then
      _suite_lock_claim && rc=0
    fi
  fi

  _suite_lock_drop "$claim"
  return "$rc"
}

_suite_lock_owner_field() {
  # $1 file, $2 key -> value (empty when absent). No forks: read builtin.
  local _k _v
  while IFS='=' read -r _k _v; do
    if [ "$_k" = "$2" ]; then
      printf '%s' "$_v"
      return 0
    fi
  done < "$1" 2>/dev/null
  return 0
}

# _suite_lock_claim — mkdir the lock dir and brand it. Prints nothing.
# Returns 0 only when THIS process is the branded owner.
_suite_lock_claim() {
  mkdir "$SUITE_LOCK_DIR" 2>/dev/null || return 1
  # mkdir is not a reliable mutex everywhere: uutils coreutils 0.8.0 resolves
  # two concurrent mkdir of the same path to BOTH rc=0 (HIMMEL-966). So the
  # owner-file create is the real arbiter — `set -C` makes it a single
  # open(O_CREAT|O_EXCL) performed by bash itself, atomic on every POSIX fs.
  if ! ( set -C; printf 'pid=%s\nhost=%s\nstarted=%s\nscan=%s\n' \
      "$$" "$(_suite_lock_host)" "$(date +%s)" "$scan" \
      > "$SUITE_LOCK_DIR/owner" ) 2>/dev/null; then
    # No winner branded at all = an IO/permission failure, not a lost race;
    # rmdir (never rm -rf) is race-safe — it refuses a dir a racer has since
    # branded — so a genuine loser leaves the winner's lock intact.
    [ -e "$SUITE_LOCK_DIR/owner" ] || rmdir "$SUITE_LOCK_DIR" 2>/dev/null
    return 1
  fi
  suite_lock_owned=1
  export HIMMEL_SUITE_LOCK_HELD="$SUITE_LOCK_DIR"
  return 0
}

# suite_lock_acquire — 0 to proceed, 1 to refuse (caller exits 2).
suite_lock_acquire() {
  [ "$SUITE_LOCK" = "0" ] && return 0
  [ "${HIMMEL_SUITE_LOCK_HELD:-}" = "$SUITE_LOCK_DIR" ] && return 0

  # Validate the path ONCE, here, before any code path below can delete inside
  # it. Successive reviews kept finding new shapes of the same bug — a lock
  # path that is not a lock, reached through a different branch — so the class
  # is closed at the entrance rather than patched per branch. A symlink is the
  # sharpest case: every content check inspects the TARGET while every write
  # goes through the link, so the thing examined and the thing modified are
  # different directories. This script only ever creates real directories, so
  # a symlink here is always a mis-set override.
  if [ -L "$SUITE_LOCK_DIR" ]; then
    {
      printf 'REFUSED: %s is a symlink — the suite lock must be a real directory.\n' \
        "$SUITE_LOCK_DIR"
      printf '  Refusing to touch it, because what gets checked and what gets written would differ. Check SUITE_LOCK_DIR.\n'
    } >&2
    return 1
  fi

  mkdir -p "$(dirname "$SUITE_LOCK_DIR")" 2>/dev/null
  _suite_lock_claim && return 0

  # Lost the mkdir — but the winner brands the dir in a separate step, so a
  # loser arriving inside that window sees a lock with no owner yet. Give it a
  # moment before concluding anything.
  local _spin=0
  while [ ! -f "$SUITE_LOCK_DIR/owner" ] && [ "$_spin" -lt 20 ]; do
    sleep 0.05
    _spin=$((_spin + 1))
  done
  # Still nothing: a crash between the mkdir and the brand left a husk. This
  # is an ADVISORY lock over test scheduling, not a data-integrity lock, so it
  # fails OPEN with a loud trail — refusing every future run until a human
  # notices a stray directory in /tmp would be a worse outage than the
  # contention it exists to prevent.
  if [ ! -f "$SUITE_LOCK_DIR/owner" ]; then
    # A non-empty directory with no owner file is not a lock husk — it is
    # whatever SUITE_LOCK_DIR was mis-pointed at. Say so before going near it.
    if ! _suite_lock_dir_empty "$SUITE_LOCK_DIR"; then
      {
        printf 'REFUSED: %s exists, has no owner file, and is NOT empty — this does not look like a suite lock.\n' \
          "$SUITE_LOCK_DIR"
        printf '  Refusing to touch it. Check SUITE_LOCK_DIR; remove the directory yourself if it really is a stale lock.\n'
      } >&2
      return 1
    fi
    # Expected generation is "no owner file" — the CAS re-check inside
    # _suite_lock_reclaim fails if anyone branded it while we spun above.
    if _suite_lock_reclaim ""; then
      printf 'NOTE: cleared an unbranded suite lock (no owner file) at %s\n' \
        "$SUITE_LOCK_DIR" >&2
      return 0
    fi
  fi

  # ONE raw read; every field below AND the takeover's CAS check derive from
  # this single generation, so the staleness judgement and the act on it can
  # never straddle a concurrent rewrite.
  local o_raw o_pid o_host o_started now age=-1 dated=0
  o_raw=$(_suite_lock_owner_raw "$SUITE_LOCK_DIR")
  o_pid=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" pid)
  o_host=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" host)
  o_started=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" started)
  now=$(date +%s)
  case "$o_started" in
    ''|*[!0-9]*) ;;
    *) age=$(( now - 10#$o_started )); dated=1 ;;
  esac

  # Two independent staleness signals, because neither alone is sound. A pid
  # that no longer answers is a crashed run — but pids get recycled, so an
  # answering pid is not proof of life; the TTL is the backstop for that and
  # for a lock left by a host that is not this one.
  local stale=0 this_host; this_host=$(_suite_lock_host)
  if [ -n "$o_pid" ] && [ "$o_host" = "$this_host" ]; then
    kill -0 "$o_pid" 2>/dev/null || stale=1
  fi
  [ "$age" -ge "$SUITE_LOCK_TTL" ] && stale=1
  # A lock we could neither date nor probe is abandoned, not held: a foreign
  # host whose `started` is missing or corrupt, or any owner carrying no pid at
  # all. Neither signal above can show it fresh, so — same policy as the
  # takeover claim a level up, where an undated owner is treated as abandoned —
  # it gets cleared. Without this, a foreign-hosted lock with an unparseable
  # timestamp is unreclaimable forever: the pid probe is skipped by design on a
  # foreign host, and age=-1 can never exceed the TTL. A genuinely held lock is
  # safe here — a live pid on this host, or a datable timestamp inside the TTL,
  # already cleared the bar above.
  if [ "$dated" -eq 0 ]; then
    [ -z "$o_pid" ] && stale=1
    [ "$o_host" != "$this_host" ] && stale=1
  fi

  if [ "$stale" -eq 1 ]; then
    # Guarded by the takeover claim + a CAS on the generation we just judged.
    # Losing either is an ordinary refusal, not an error — someone else got
    # the freed slot, or the lock turned out to be live after all.
    if _suite_lock_reclaim "$o_raw"; then
      printf 'NOTE: cleared an abandoned suite lock (pid=%s host=%s age=%ss) at %s\n' \
        "${o_pid:-?}" "${o_host:-?}" "$age" "$SUITE_LOCK_DIR" >&2
      return 0
    fi
  fi

  {
    printf 'REFUSED: another run of scan root "%s" holds the machine lock (pid=%s host=%s age=%ss).\n' \
      "$scan" "${o_pid:-unknown}" "${o_host:-unknown}" "$age"
    printf '  lock: %s\n' "$SUITE_LOCK_DIR"
    printf '  Concurrent runs test the same tree and starve each other (HIMMEL-1338).\n'
    printf '  Wait for it, or scope this run to the subtree you changed — the lock is\n'
    printf '  keyed by scan root, so e.g. "%s/<subdir>" takes a different lock and runs\n' "$scan"
    printf '  now. SUITE_LOCK=0 opts out entirely.\n'
  } >&2
  return 1
}

# COMPARE, then delete. "I acquired this once" is not the same claim as "I hold
# it now": a run that overruns the TTL gets reclaimed by another run, which
# rm -rf's this dir and creates its OWN. An unconditional release would then
# delete the successor's live lock on our way out and let a third run in
# alongside it — the exact concurrency this file exists to prevent, caused by
# the lock's own cleanup. queue-lock.sh refuses a token-less release for the
# same reason. Re-read the owner and only remove a lock still branded with our
# pid on this host.
#
# Residual (accepted, microseconds): a reclaim landing between the read and
# the rm. An owner file we cannot read leaves the dir alone — the next
# acquire treats an unbranded lock as abandoned and clears it immediately, so
# nothing wedges.
# Invoked from the EXIT trap, which shellcheck cannot see as a call site.
# shellcheck disable=SC2317
suite_lock_release() {
  [ "$suite_lock_owned" -eq 1 ] || return 0
  [ -f "$SUITE_LOCK_DIR/owner" ] || return 0
  local r_pid r_host
  r_pid=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" pid)
  r_host=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" host)
  if [ "$r_pid" != "$$" ] || [ "$r_host" != "$(_suite_lock_host)" ]; then
    printf 'NOTE: not releasing %s — it was taken over (now pid=%s host=%s); leaving the current holder alone\n' \
      "$SUITE_LOCK_DIR" "${r_pid:-?}" "${r_host:-?}" >&2
    return 0
  fi
  _suite_lock_drop "$SUITE_LOCK_DIR"
}

# --------------------------------------------------------------------------
# Arg parsing — single-pass, position-independent:
#   --list               set list-mode
#   --skip-extra <val>   append to extra_skips
#   --changed-since <ref> enable the conditional-suite filter against <ref>
#   first non-flag       scan-root (default: scripts)
# --------------------------------------------------------------------------
list_only=0
scan=""
# OPT-IN conditional filter (HIMMEL-1589). Env is the default; the flag overrides.
changed_since="${SUITE_CHANGED_SINCE:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)
      list_only=1
      shift
      ;;
    --skip-extra)
      if [ "$#" -lt 2 ]; then
        echo "run-shell-tests.sh: --skip-extra requires an argument" >&2
        exit 1
      fi
      extra_skips="${extra_skips}${2}
"
      shift 2
      ;;
    --changed-since)
      if [ "$#" -lt 2 ]; then
        echo "run-shell-tests.sh: --changed-since requires an argument" >&2
        exit 1
      fi
      changed_since="$2"
      shift 2
      ;;
    -*)
      echo "run-shell-tests.sh: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$scan" ]; then
        scan="$1"
      else
        echo "run-shell-tests.sh: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Apply default scan root after parsing so a leading --list doesn't collide.
scan="${scan%/}"      # strip any trailing slash so the relpath prefix-strip works
scan="${scan:-scripts}"

# Derive the scan-keyed lock path now that $scan is known (an explicit
# SUITE_LOCK_DIR wins). "./scripts" and "scripts" are the same tree, so
# normalise the leading "./" before slugging or they would take two different
# locks and neither would serialise against the other.
if [ -z "$SUITE_LOCK_DIR" ]; then
  _lock_key="${scan#./}"
  # Fold "/" to "__" BEFORE collapsing the rest to "-", so the common case —
  # two different subtree paths — cannot slug alike: without it "a/b" and "a-b"
  # both became "a-b" and two unrelated scoped runs would share a lock.
  #
  # Residual, accepted: "a/b" still collides with a literal "a__b", the same
  # theoretical-only caveat scripts/handover/queue-lock.sh documents for its
  # own slug. It is also the SAFE direction — a collision over-serialises two
  # runs, it never lets two runs both hold the lock.
  _lock_key=$(printf '%s' "$_lock_key" | sed 's#/#__#g' | tr -c 'A-Za-z0-9_-' '-')
  SUITE_LOCK_DIR="${TMPDIR:-/tmp}/himmel-shell-suite-${_lock_key}.lock"
fi

# --------------------------------------------------------------------------
# Discover suites via a temp file so counters survive the read-loop
# (piping into while would run in a subshell on some shells).
# --------------------------------------------------------------------------
suites_file=$(mktemp)
suites_raw=$(mktemp)
trap 'rm -f "$suites_file" "$suites_raw"; suite_lock_release' EXIT

# Check EVERY discovery stage so a partial-output-then-fail can't mask an
# incomplete scan (ran>0 with the guard below passing → green on a scan that
# never finished — the same false-green class HIMMEL-1128 closes). The two
# stages are `find` and `sort`; the earlier `grep -v /node_modules/` was
# redundant (find's `-path '*/node_modules' -prune` already excludes those
# subtrees) so it is dropped rather than status-checked.
find "$scan" -path '*/node_modules' -prune -o -name 'test-*.sh' -print > "$suites_raw" 2>/dev/null
find_rc=$?
if [ "$find_rc" -ne 0 ]; then
  printf 'ERROR: suite discovery failed under scan root "%s" (find rc=%s) — refusing to report green.\n' "$scan" "$find_rc" >&2
  exit 1
fi
sort "$suites_raw" > "$suites_file"
sort_rc=$?
if [ "$sort_rc" -ne 0 ]; then
  printf 'ERROR: suite discovery sort failed (rc=%s) — refusing to report green.\n' "$sort_rc" >&2
  exit 1
fi

# Zero DISCOVERED suites = a resolved-to-nothing scan root (typo, empty dir, a
# file-valued root). Fail BEFORE the mode split so --list is guarded too: a
# --list of a bad root printing an empty plan and exiting 0 is the same
# false-green footgun as the execution path (HIMMEL-1128). (--list of a root
# whose suites are all SKIPPED is NOT failed here — listing a skip plan is the
# mode's purpose; only the execution path enforces run>0, at the ran==0 guard.)
# Test the completed discovery file directly with the `-s` builtin (non-empty)
# — no external `grep`/`wc` whose own failure could let an empty file slip past
# the guard and re-open the false-green.
if [ ! -s "$suites_file" ]; then
  printf 'ERROR: no test suites discovered under scan root "%s" — refusing to report green.\n' "$scan" >&2
  exit 1
fi

# Take the machine lock before executing anything (list mode runs nothing, so
# it does not contend). Discovery already happened — a refusal here has cost
# nothing but a directory scan.
if [ "$list_only" -eq 0 ]; then
  suite_lock_acquire || exit 2
fi

pass=0 fail=0 skip=0 ran=0
failed_suites=""
timed_out=0
unrun_suites=""
budget_expired=0
# $SECONDS is a bash builtin — no fork. `date +%s` twice per suite plus once
# per budget check is four processes a suite on a box where a fork costs a
# quarter-second, which is real money across ninety suites and an odd tax for
# a change whose point is that these runs take too long.
run_start=$SECONDS

# Pin git fsync/template settings for the throwaway repos the suites build.
# Called once here so the exports flow to every suite subprocess the loop below
# spawns; idempotent via its marker, so a suite that re-sources the lib inherits
# without appending a duplicate. (HIMMEL-1589.)
git_test_env_pin_perf

# Resolve the conditional-suite filter (HIMMEL-1589). FAIL-OPEN: if this is not
# a git repo, the ref does not resolve, or either git command fails, run EVERY
# suite and say why. Silently filtering on a broken diff would be the same
# false-green class the discovery guards above close one level up.
conditional_filter_active=0
changed_set=""
if [ -n "$changed_since" ]; then
  # Resolve the ref to a concrete commit BEFORE handing it to `git diff`. A raw
  # --changed-since value is interpolated straight into `git diff`, where git
  # parses an OPTION-shaped value as an OPTION, not a ref: `git diff --name-only
  # --exit-code` on a clean tree SUCCEEDS with EMPTY output, so this block would
  # set conditional_filter_active=1 over an empty changed_set and SILENTLY skip
  # every conditional suite — a false green, the exact inverse of the fail-open
  # contract this else-branch exists to enforce. --end-of-options makes git treat
  # the value as a ref literal; ^{commit} forces a commit-ish. Anything that does
  # not resolve still falls through to fail-open below, unchanged. (HIMMEL-1589.)
  if resolved=$(git rev-parse --verify --quiet --end-of-options "${changed_since}^{commit}" 2>/dev/null) && \
     changed_tracked=$(git diff --name-only "$resolved" 2>/dev/null) && \
     changed_untracked=$(git ls-files --others --exclude-standard 2>/dev/null); then
    changed_set="${changed_tracked}
${changed_untracked}"
    conditional_filter_active=1
  else
    printf 'NOTE: --changed-since "%s" did not resolve (not a git repo, bad ref, or git failed) — running every suite.\n' \
      "$changed_since" >&2
  fi
fi

# fd 3, not stdin. With `done < "$suites_file"` the loop BODY inherits the
# suite list as its stdin, so any suite that read from stdin consumed the
# remaining suite paths — the runner then reported OK over a list it had
# silently eaten. Suites now get /dev/null (below), which also means an
# unattended run can never block on a prompt.
while IFS= read -r suite <&3; do
  [ -n "$suite" ] || continue

  # Derive the scan-root-relative path for skip matching.
  # Strip the leading "$scan/" prefix.
  relpath="${suite#"${scan}"/}"

  if reason=$(is_skipped "$relpath"); then
    skip=$((skip + 1))
    printf '[SKIP] %s — %s\n' "$suite" "$reason"
    continue
  fi

  # Conditional suites (HIMMEL-1589): when --changed-since is active, a suite in
  # SUITE_CONDITIONAL runs only if a changed path matches its ERE. Inert without
  # the flag (conditional_filter_active=0), so a full run behaves exactly as
  # before. Runs through --list too, so the skip plan reflects the filter.
  if [ "$conditional_filter_active" -eq 1 ] && ere=$(conditional_ere "$relpath"); then
    if ! conditional_matches "$ere"; then
      skip=$((skip + 1))
      printf '[SKIP] %s — conditional: no changed path matches %s\n' "$suite" "$ere"
      continue
    fi
  fi

  if [ "$list_only" -eq 1 ]; then
    printf '[RUN ] %s\n' "$suite"
    continue
  fi

  # Whole-run budget, checked BETWEEN suites so a cap can never truncate a
  # suite mid-assertion. Everything still on the list is named as unrun —
  # stopping quietly here would be the same false green the discovery guards
  # above exist to prevent.
  if [ "$budget_expired" -eq 1 ] || \
     [ $(( SECONDS - run_start )) -ge "$SUITE_RUN_BUDGET" ]; then
    budget_expired=1
    unrun_suites="${unrun_suites}  ${suite}
"
    continue
  fi

  log=$(mktemp)
  # Derived, not a second mktemp: same directory, same lifetime, one less fork.
  rcfile="$log.rc"
  start=$SECONDS

  # Run the suite as a background job in its OWN process group (`set -m`), and
  # arm a watchdog beside it. `timeout` did the timing before, and it group-
  # signals too — but it has no --kill-after here, so a suite that ignores
  # TERM (any suite with a cleanup trap) ran to completion with the cap
  # silently doing nothing: measured 41s against a 5s cap. It is also guarded
  # by `command -v timeout`, so on a box without it there was no cap at all.
  #
  # The watchdog owns the whole escalation. The parent just `wait`s — no
  # polling, so a fast suite is not taxed for the privilege of being capped,
  # and one `sleep` per suite replaces one per second.
  #
  # The rc file, not the exit status, is the arbiter of what happened: a
  # watchdog that fires as the suite completes finds the file already written
  # and stands down, so that race resolves in favour of the real result.
  : > "$rcfile"
  suite_timeout=$(_suite_timeout_for "$suite")
  set -m
  { bash "$suite" >"$log" 2>&1 </dev/null; printf '%s\n' "$?" > "$rcfile"; } &
  suite_pid=$!
  # Its own group as well, so cancelling it below takes its `sleep` too —
  # a watchdog that leaked one sleeper per suite would be its own churn bug.
  ( sleep "$suite_timeout"
    [ -s "$rcfile" ] && exit 0
    if proc_tree_terminate "$suite_pid"; then
      printf '[TIME] %s — exceeded %ss; suite and its descendants terminated\n' \
        "$suite" "$suite_timeout"
    else
      printf '[TIME] %s — exceeded %ss; WARNING: descendants survived termination\n' \
        "$suite" "$suite_timeout"
    fi ) &
  watch_pid=$!
  set +m

  wait "$suite_pid" 2>/dev/null

  if [ -s "$rcfile" ]; then
    read -r rc < "$rcfile"
    # Finished on its own: stand the watchdog down. Only in this branch — if
    # the watchdog is the reason the suite is gone, it may still be mid-
    # escalation, and cancelling it there could strand the survivor it was
    # about to deal with.
    kill -TERM -"$watch_pid" 2>/dev/null || kill -TERM "$watch_pid" 2>/dev/null
  else
    # 124 is the code `timeout` reported, so downstream readers of this log
    # keep the meaning they already had.
    rc=124
    timed_out=$((timed_out + 1))
  fi
  wait "$watch_pid" 2>/dev/null
  rm -f "$rcfile"

  dur=$(( SECONDS - start ))
  ran=$((ran + 1))

  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf '[PASS] %s (%ss)\n' "$suite" "$dur"
  else
    fail=$((fail + 1))
    failed_suites="${failed_suites}  ${suite} (rc=${rc})
"
    printf '[FAIL] %s (rc=%s, %ss)\n' "$suite" "$rc" "$dur"
    echo '----- last 100 lines -----'
    tail -n 100 "$log" | sed 's/^/    /'
    echo '--------------------------'
    # Preserve the FULL failed-suite log when FAIL_LOG_DIR is set (CI uploads
    # it as an artifact — HIMMEL-963: tail-only + rm made the failing
    # assertion unrecoverable from Actions logs). Injective escape (_ -> _u,
    # / -> _s) so distinct relpaths like a/b and a_b can't collide.
    if [ -n "${FAIL_LOG_DIR:-}" ]; then
      mkdir -p "$FAIL_LOG_DIR"
      safe_relpath=$(printf '%s' "$relpath" | sed 's/_/_u/g; s#/#_s#g')
      cp "$log" "$FAIL_LOG_DIR/$safe_relpath.log"
    fi
  fi
  rm -f "$log"
done 3< "$suites_file"

echo
echo '== Summary =='
if [ "$list_only" -eq 1 ]; then
  echo "(--list: nothing executed)"
  exit 0
fi
printf ' PASS: %s\n SKIP: %s\n FAIL: %s\n' "$pass" "$skip" "$fail"
if [ "$timed_out" -gt 0 ]; then
  printf ' TIMED OUT: %s (counted in FAIL)\n' "$timed_out"
fi
if [ "$budget_expired" -eq 1 ]; then
  printf 'ERROR: run budget of %ss expired — these suites never ran:\n%s' \
    "$SUITE_RUN_BUDGET" "$unrun_suites" >&2
fi
if [ "$fail" -gt 0 ]; then
  printf 'Failed suites:\n%s' "$failed_suites"
  exit 1
fi
# A budget-truncated run is not a pass, however green the suites that did run
# were — the ones that never ran are exactly the ones nobody has evidence for.
if [ "$budget_expired" -eq 1 ]; then
  exit 1
fi
# Suites were discovered (the discovered==0 guard above already passed) but
# every one was skipped, so nothing actually ran — not a pass. Reporting it
# green is a false green on a process-integrity gate (HIMMEL-1128).
if [ "$ran" -eq 0 ]; then
  printf 'ERROR: no suites ran under scan root "%s" (all discovered suites were skipped) — refusing to report green.\n' "$scan" >&2
  exit 1
fi
echo "OK: all $ran run suites passed ($skip skipped)"
exit 0
