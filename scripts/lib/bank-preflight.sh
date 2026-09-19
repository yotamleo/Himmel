#!/usr/bin/env bash
# bank-preflight.sh — HIMMEL-1841 (bank guard); HIMMEL-2765 (fleet-size cap).
# Pre-run guard for scheduled legs.
#
# Prints ONE verdict token to stdout; diagnostics to stderr; a row to the
# ledger; ALWAYS exits 0. Callers branch on the TOKEN, never the exit code
# — a non-zero exit is indistinguishable from a crash to the schtasks/cron
# wrapper, and the fail-open verdicts must not look like failures. Tokens:
# PROCEED, SKIPPED-BANK, SKIPPED-FLEET, BANK-STALE, BANK-UNKNOWN.
#
# extra_usage is NOT thresholded: it is paid overflow that engages when a
# primary is exhausted, so high extra_usage with low primaries means the
# bank is HEALTHY. Diagnostics only.
#
# HIMMEL-2765: the fleet-size cap runs FIRST, ahead of any bank fetch —
# concurrency, not bank exhaustion, burned the fleet on 2026-09-07
# (HIMMEL-2750). See the FLEET_CAP block below for the count/bypass
# contract.
#
# HIMMEL-2789: the fleet cap's REFUSAL (SKIPPED-FLEET) only fires when the
# caller sets CADENCE_BANK_LAUNCH=1, declaring an actual arm/launch intent
# (arm-resume.sh, headed-arm-leg.sh). A plain bank READ — hermes-critic.sh's
# /pr-check pass, bank-monitor, the statusline/hook-smoke test suites — gets
# the same bank verdict and the same informational FLEET line (printed
# unconditionally either way), but is never itself refused by the fleet cap:
# it never launches anything, so cap-driven concurrency has nothing to do
# with it.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PRODUCER="${CADENCE_BANK_PRODUCER:-$REPO/scripts/statusline/usage-cache-producer.sh}"
MAX_PCT="${CADENCE_BANK_MAX_PCT:-85}"
MAX_AGE="${CADENCE_BANK_MAX_AGE:-600}"
# MUST match the producer + every shipped consumer. CLAUDE_USAGE_CACHE is the
# producer's own knob; USAGE_CACHE_FILE does not exist.
CACHE="${CADENCE_BANK_CACHE:-${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}}"
# Home dir, NOT the checkout: $REPO/.himmel/cadence-ledger.jsonl is not
# gitignored, so nightly runs would grow an untracked file inside the primary
# checkout on main. $HOME/.himmel is where flow-run-ledger.sh already writes.
LEDGER="${CADENCE_BANK_LEDGER:-${HOME:-/tmp}/.himmel/cadence-ledger.jsonl}"
case "$LEDGER" in
  */*) LEDGER_DIR=${LEDGER%/*}; [ -n "$LEDGER_DIR" ] || LEDGER_DIR=/ ;;
  *) LEDGER_DIR=. ;;
esac
LEG="${CADENCE_BANK_LEG:-unknown}"
# HIMMEL-2789: whether THIS call declares an actual arm/launch intent. The
# fleet-size cap below exists to refuse a NEW arm when the fleet is already
# at CAP (HIMMEL-2765) — it has no business refusing a plain bank READ (a
# `/pr-check` critic pass, a statusline probe, a hook-smoke test) that never
# launches anything. Only a caller that is about to actually spawn a leg
# (arm-resume.sh, headed-arm-leg.sh) sets this. The informational FLEET line
# below still prints unconditionally either way — only the refusal is gated.
LAUNCH_INTENT="${CADENCE_BANK_LAUNCH:-}"
# HIMMEL-2782: which bank this leg parks on. native (default) is the
# existing Claude five_hour/seven_day check below; claudex parks on the
# codex weekly bank instead (scripts/lanes/bank-status.ts's "claudex" row) —
# a claudex leg must never be refused by the Claude subscription bank, a
# different bucket entirely.
LANE="${CADENCE_BANK_LANE:-native}"

is_num() { case "$1" in ''|*[!0-9.]*) return 1 ;; *.*.*) return 1 ;; *[0-9]*) return 0 ;; *) return 1 ;; esac; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

emit() {
  [ -d "$LEDGER_DIR" ] || mkdir -p "$LEDGER_DIR" 2>/dev/null
  degraded=false; [ "$usable" -eq 1 ] && degraded=true
  printf '{"ts":"%s","leg":"%s","verdict":"%s","five_hour":"%s","seven_day":"%s","age":"%s","degraded":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LEG" "$1" "${fh:-}" "${sd:-}" "${age:-}" "$degraded" \
    >> "$LEDGER" 2>/dev/null
  printf '%s\n' "$1"
  exit 0
}
fh=""; sd=""; age=""; usable=0

# HIMMEL-2765: fleet-size cap. Concurrency, not bank exhaustion, burned the
# fleet on 2026-09-07 (HIMMEL-2750: 9-11 legs exhausted a week's bucket in
# under 48h) — this refuses a new arm when the fleet is already at CAP,
# structurally, ahead of any bank fetch. Printed on EVERY call regardless of
# outcome, so the console tick always shows FLEET n/CAP.
#
# CAP resolves from the environment first; falling back to the primary
# checkout's .env (HIMMEL_FLEET_CAP), default 4 — a PROVISIONAL cap well
# under the 9-11 that burned a week's usage bucket in under 48h
# (HIMMEL-2750), not a derived sustainable figure (no per-session burn
# rate has been measured; see docs/internals/lane-calibration.md).
FLEET_CAP="${HIMMEL_FLEET_CAP:-}"
if [ -z "$FLEET_CAP" ]; then
  # shellcheck source=scripts/lib/load-dotenv.sh
  # shellcheck disable=SC1091
  . "$REPO/scripts/lib/load-dotenv.sh"
  load_dotenv HIMMEL_FLEET_CAP
  FLEET_CAP="${HIMMEL_FLEET_CAP:-4}"
fi
is_int "$FLEET_CAP" || FLEET_CAP=4

# FLEET_PS_CMD (test seam, default: ps -eo pid=,args=) — headerless PID +
# full argv per process, so each CANDIDATE pid's own comm can be confirmed
# below. FLEET_PROC (test seam, default: /proc) — procfs root the comm
# check reads from. When set, FLEET_PS_CMD is invoked QUOTED as a single
# executable path (codex-2, 5th panel round: an unquoted override
# word-splits a stub path containing a space, e.g. a $TMPDIR with one) —
# only the built-in default's own flags need word-splitting.
#
# CR review findings fixed together here (all apply to what counts as a
# "candidate" line, or to what happens when the census itself is
# unavailable — one coherent rewrite closes all four):
#   codex-1 (round 1): the old `claude .* -n (HIMMEL|LUNA)-` pattern
#     required TWO separate whitespace runs between "claude" and "-n", so
#     a session launched with no other argument (`claude -n HIMMEL-x
#     ...`) was never counted — an undercount that lets the fleet exceed
#     the cap silently.
#   codex-3 (round 1): an argv-text match alone also matches a WRAPPER
#     process (e.g. konsole, whose own argv literally embeds the full
#     `claude ... -n NAME ...` command it launched as text — the exact
#     shape headed-arm.sh uses) — double-counting one real leg as two and
#     refusing launches prematurely.
#   codex-2 (round 2): an up-front "does the procfs ROOT exist" check
#     still silently drops EVERY candidate on a host where the directory
#     exists but INDIVIDUAL comm files are not (a partial/unsupported
#     procfs, e.g. some Git Bash configurations) — the exact same
#     silent-zero mistake it was meant to fix, just triggered a different
#     way.
#   codex-3 (round 2, Suggestion): the FLEET_CAP_OK bypass check is fixed
#     separately, below.
#   codex-2 (round 3): decide PER CANDIDATE, not once for the whole host —
#     see the per-candidate fallback in the loop below.
#   codex-3 (round 3): a FAILED process-enumeration command (ps missing,
#     an unsupported FLEET_PS_CMD) is indistinguishable from "genuinely
#     zero matching processes" unless the exit code is captured
#     explicitly — both otherwise produce empty output, so a broken
#     census silently read as an EMPTY fleet and permitted every launch.
#
# The fix drops the "claude" text requirement from the argv pattern
# entirely (comm confirmation makes it redundant, closing codex-1/round-1
# and codex-3/round-1 together), captures the census command's own exit
# code BEFORE ever filtering its output (closing codex-3/round-3), and
# falls back to trusting the argv match — never to silently discarding a
# candidate — whenever an individual comm read is inconclusive (closing
# codex-2/round-2 and round-3 together). This mirrors headed-arm.sh's own
# session_confirmed(): a launcher whose argv quotes the claude command is
# not itself a claude session, and an indeterminate answer must never be
# reported as a clean, confirmed one.
# codex-2 (CR review, 5th panel round, Suggestion): unquoted expansion of
# FLEET_PS_CMD word-splits an override path that contains a space (e.g. a
# $TMPDIR with one). The DEFAULT genuinely needs word-splitting (it is a
# command plus flags); an override is a single executable path and must
# be quoted. Branch on which one this run has instead of disabling
# SC2086 for both.
# _fleet_lane_of <pid> (HIMMEL-2782): names the lane a fleet candidate
# belongs to, for the FLEET line only — never gates the cap itself (that
# stays total-count, below). Reads the candidate's own /proc/<pid>/environ
# (NUL-separated) for the claudex launch env's CLAUDEX_LANE_OK=1 marker
# (headed-arm-leg.sh --lane claudex exports it via HEADED_ARM_LAUNCHER_ENV,
# which reaches the launched process's real environment through konsole's
# `-e env ... NAME=VALUE ...`). An unreadable/missing environ (permissions,
# a process that already exited) falls back to "native" — the safe default,
# since misnaming one line's lane label is cosmetic, unlike misjudging the
# cap.
_fleet_lane_of() {
  if tr '\0' '\n' < "${FLEET_PROC:-/proc}/$1/environ" 2>/dev/null | grep -qx 'CLAUDEX_LANE_OK=1'; then
    echo claudex
  else
    echo native
  fi
}

# HIMMEL-2774: atomic admission + reservation, closing the TOCTOU race where
# two arms (or one arm racing another) both observe the fleet under-cap and
# both proceed. Mirrors headed-arm.sh's own claim-lock DISCIPLINE (not its
# code): claim the admission critical section by atomic `mkdir` (this repo's
# convention — claim by atomic mkdir, never scan-then-create); a stale
# holder is reclaimed by mv-then-verify (rename to a private victim path,
# then check its stamp still matches what was observed before the rename),
# never a naive rm+mkdir — two reclaimers racing on the same stale lock must
# never let the second one delete the first one's brand-new claim (the
# r2-codex-1 CRITICAL in headed-arm.sh's own CR history).
_fleet_admit_stamp_or_fail() { # _fleet_admit_stamp_or_fail <admit-dir>
  date +%s > "$1/acquired" 2>/dev/null
}
# HIMMEL-3019: a rename displaces WHATEVER currently occupies "$admit", not the
# stale entry the reclaimer observed, so mv-then-verify alone leaves `.admit`
# absent between a mismatched reclaimer's rename and its restore — a fourth
# party's ordinary `mkdir` claim wins that window and two callers hold the lock
# at once. Every actor that can DISPLACE an existing "$admit" (a steal, or a
# release) therefore serialises on a gate, "$admit.reclaim" (an atomic-mkdir
# mutex, this file's one primitive), and the stamp check runs UNDER the gate
# BEFORE any rename: a mismatched reclaimer returns without touching "$admit".
# Fresh claims never take the gate — they only ever succeed on an ABSENT admit.
# The gate is dot-prefixed on purpose: the reservation census/prune pass below
# globs "$SLOTS"/*/ with no dotglob, and that is the ONLY thing keeping a gate
# (or any `.admit.*` debris) from being counted as a fleet reservation.
# FLEET_ADMIT_TEST_HOOK (test seam, default unset = off): a single command word
# invoked as `<hook> <point> <path>` at named interleaving points, so a suite
# can force the exact race deterministically; production never sets it.
_fleet_admit_hook() { # _fleet_admit_hook <point> <path>
  [ -n "${FLEET_ADMIT_TEST_HOOK:-}" ] && "$FLEET_ADMIT_TEST_HOOK" "$1" "$2"
  return 0
}
# _fleet_gate_take <gate> -> 0 held (stamped + pid recorded), 1 busy/refused.
# The gate is held for milliseconds, so it is breakable by AGE alone
# (FLEET_ADMIT_GATE_STALE_SECS, default 5) — deliberately NOT by `kill -0` on
# its pid: a reused pid must not wedge every reclaim and every release. An
# unreadable stamp (a crash between the mkdir and the stamp write) is stamped
# in place and reported busy once so it ages out. A break follows the same
# rename-then-verify discipline as the steal below: rename the orphan to a
# private path, then re-read ITS stamp — if a concurrent breaker already
# replaced it with a fresh gate, our rename just displaced THAT live gate, so
# put it back (create-based, never a nesting mv) and lose.
# ponytail: this closes the 4-party race for every actor that runs THIS code,
# but a gate break is still a rename-then-verify, not a compare-and-swap: with
# >=3 actors racing one CRASHED gate, a slow breaker's rename can displace a
# faster breaker's fresh gate, and the create-based restore is best-effort — so
# two gate holders can briefly coexist (only ever for one gate-hold's few
# milliseconds, and only after a gate holder died mid-hold). The same
# age-lease has NO fencing for a live holder PAUSED past the age (SIGSTOP, VM
# suspend) between its stamp check and its rename: it can resume after the gate
# was broken and rename a successor's admit away. No CAS primitive
# (link/renameat2) is portable across bash 3.2 / macOS / Git-Bash; the
# defence-in-depth restore in the steal keeps a displaced live claim alive, but
# `.admit` is absent for that instant (HIMMEL-3210 tracks both residuals).
_fleet_gate_take() {
  local gate="$1" held_at victim seen
  if ! mkdir "$gate" 2>/dev/null; then
    held_at="$(cat "$gate/acquired" 2>/dev/null)" || held_at=""
    case "$held_at" in
      ''|*[!0-9]*) date +%s > "$gate/acquired" 2>/dev/null; return 1 ;;
    esac
    [ $(( $(date +%s) - held_at )) -ge "${FLEET_ADMIT_GATE_STALE_SECS:-5}" ] || return 1
    _fleet_admit_hook gate-break "$gate"
    victim="$gate.broken.$$.$RANDOM"
    mv "$gate" "$victim" 2>/dev/null || return 1
    seen="$(cat "$victim/acquired" 2>/dev/null)" || seen=""
    if [ "$seen" != "$held_at" ]; then
      if mkdir "$gate" 2>/dev/null; then
        cp -p "$victim/acquired" "$gate/acquired" 2>/dev/null
        cp -p "$victim/pid" "$gate/pid" 2>/dev/null
      fi
      rm -rf "$victim" 2>/dev/null
      return 1
    fi
    rm -rf "$victim" 2>/dev/null
    mkdir "$gate" 2>/dev/null || return 1
  fi
  if _fleet_admit_stamp_or_fail "$gate" && printf '%s\n' "$$" > "$gate/pid" 2>/dev/null; then
    return 0
  fi
  rm -rf "$gate" 2>/dev/null
  return 1
}
# Drop only a gate this process still holds (its pid reads back as ours): a
# gate aged out from under a very slow holder now belongs to someone else.
_fleet_gate_drop() { # _fleet_gate_drop <gate>
  [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] && rm -rf "$1" 2>/dev/null
  return 0
}
# _fleet_release_admit <admit-dir>: the ONE way this script gives up its own
# admission lock (HIMMEL-3019). Gated, so it cannot land between a reclaimer's
# verification and its rename; pid-verified, so a caller whose lock was
# legitimately reclaimed (a holder only PRESUMED dead) never deletes its
# successor's live one. Waits a bounded few dozen retries for the gate; if it
# cannot get it, the lock is left to age out (a REFUSED launch — SKIPPED-FLEET —
# for up to FLEET_ADMIT_STALE_SECS) and that is logged, never silent.
_fleet_release_admit() {
  local admit="$1" gate="$1.reclaim" iters=0
  while ! _fleet_gate_take "$gate"; do
    iters=$((iters + 1))
    # The retry window (ITERS x RETRY_SLEEP = 160 x 0.05 = 8s) must exceed
    # FLEET_ADMIT_GATE_STALE_SECS (5s): an orphaned gate younger than that is
    # only breakable once it ages, so a shorter window gives up on a gate that
    # would have become breakable. test-bank-preflight-admit-gate.sh (j) asserts
    # the relation over these defaults.
    if [ "$iters" -ge "${FLEET_ADMIT_RELEASE_ITERS:-160}" ]; then
      echo "bank-preflight: could not take the admit-lock gate ($gate) to release $admit after $iters tries — leaving it to age out (launches are refused for up to ${FLEET_ADMIT_STALE_SECS:-60}s)" >&2
      return 1
    fi
    _fleet_admit_hook release-retry "$gate"
    sleep "${FLEET_ADMIT_RETRY_SLEEP:-0.05}"
  done
  [ "$(cat "$admit/pid" 2>/dev/null)" = "$$" ] && rm -rf "$admit" 2>/dev/null
  _fleet_gate_drop "$gate"
  return 0
}
_fleet_steal_stale_admit_gated() { # runs UNDER the gate — see _fleet_steal_stale_admit below
  local admit="$1" expected_at="$2" victim stolen_at
  # The verification the rename below cannot do for itself: is what occupies
  # "$admit" NOW still the stale entry the caller observed? Nothing can change
  # that between here and the rename (fresh claims need an absent admit,
  # steals/releases need the gate we hold), so a mismatch is a clean refusal —
  # no rename, no restore, no empty window.
  stolen_at="$(cat "$admit/acquired" 2>/dev/null)" || stolen_at=""
  [ "$stolen_at" = "$expected_at" ] || return 1
  _fleet_admit_hook post-verify "$admit"
  victim="$admit.stale.$$.$RANDOM"
  mv "$admit" "$victim" 2>/dev/null || return 1
  _fleet_admit_hook post-rename "$admit"
  stolen_at="$(cat "$victim/acquired" 2>/dev/null)" || stolen_at=""
  if [ "$stolen_at" != "$expected_at" ]; then
    # Defence in depth, unreachable while every displacer holds the gate:
    # arm-resume.sh resolves the preflight relative to ITSELF, so an arm
    # launched from a worktree runs an OLDER, ungated copy against the same
    # slot dir, and such an actor can still swap a fresh claim in after our
    # check above. If our rename displaced one, put it back rather than
    # clobber it — but only if the slot is still empty. codex-1 (this round):
    # if a THIRD party has since claimed "$admit" (because our own mv vacated
    # it for the instant between here and the check), `mv victim admit` onto an
    # existing directory nests the displaced fresh claim inside it (POSIX
    # mv-into-directory semantics) instead of restoring it — corrupting both.
    # Leaving the victim as an orphaned `.admit.stale.*` dir is harmless to
    # exclusion (it holds no lock), but it is NOT pruned: the reservation
    # prune pass globs "$SLOTS"/*/, which skips dot-dirs, so such victims
    # accumulate in tmpfs until reboot (follow-up on HIMMEL-3019).
    # codex-2 (HIMMEL-2774, 2nd panel round): a plain `[ -e ] || mv` here is
    # itself a check-then-act race — a FOURTH party's `mkdir "$admit"` can
    # land in the instant between the `[ -e ]` test and the `mv`, and `mv`
    # onto an existing directory would then silently NEST the fourth party's
    # fresh claim inside the restored victim (POSIX mv-into-directory
    # semantics) rather than fail, corrupting both. `mkdir` itself is the
    # only atomic "claim iff absent" primitive available here, so restore by
    # attempting to atomically CLAIM `$admit` fresh, and only copy the
    # displaced claim's own metadata IN once that succeeds — a plain `mkdir`
    # can never nest or clobber; it either wins the empty slot outright or
    # fails closed, leaving the fourth party's claim exactly as it was.
    # Reproducing the displaced claim's exact original stamp is best-effort
    # only (advisory, like the `pid` write in _fleet_claim_admit below): the
    # atomic mkdir above is what protects exclusion, not the stamp contents —
    # a failed copy here just makes the restored claim look freshly taken,
    # which is safe (it only delays, never breaks, a future staleness check).
    if mkdir "$admit" 2>/dev/null; then
      cp -p "$victim/acquired" "$admit/acquired" 2>/dev/null
      cp -p "$victim/pid" "$admit/pid" 2>/dev/null
    fi
    return 1
  fi
  rm -rf "$victim" 2>/dev/null
  if mkdir "$admit" 2>/dev/null; then
    # codex-4 (HIMMEL-2774, 2nd panel round): same bug class as codex-2's
    # fix in _fleet_claim_admit below — an unchecked stamp write here can
    # fail (disk full, permissions) and still `return 0`, handing the caller
    # an unstamped claim that can never age out. Fail the reclaim and give
    # up the empty dir instead of proceeding on an unprotected slot.
    if _fleet_admit_stamp_or_fail "$admit"; then
      # codex-1 (HIMMEL-2774, 4th panel round): this steal DID claim
      # ownership, so record OUR OWN pid here too — same as the fresh-claim
      # path in _fleet_claim_admit below — so a subsequent staleness check
      # against a holder that is still genuinely inside the critical section
      # can find a live pid to protect. codex-5 (same round): `rm -rf`, not
      # `rmdir`, on the fallback below — redirection into "$admit/acquired"
      # creates that file before `date` runs, so a `date` failure can leave
      # a non-empty (if zero-byte) directory that a bare `rmdir` cannot remove,
      # wedging this reclaim attempt's own cleanup. HIMMEL-3019: the pid write
      # fails CLOSED too — every release is now pid-verified, so a pid-less
      # claim could never be released by its owner and would wedge admission
      # until it aged out.
      if printf '%s\n' "$$" > "$admit/pid" 2>/dev/null; then
        return 0
      fi
    fi
    rm -rf "$admit" 2>/dev/null
  fi
  return 1
}
_fleet_steal_stale_admit() { # _fleet_steal_stale_admit <admit-dir> <expected-acquired-stamp>
  local gate="$1.reclaim" rc
  _fleet_gate_take "$gate" || return 1
  _fleet_steal_stale_admit_gated "$@"
  rc=$?
  _fleet_gate_drop "$gate"
  return "$rc"
}
_fleet_claim_admit() { # _fleet_claim_admit <admit-dir>
  local admit="$1" held_at age
  if mkdir "$admit" 2>/dev/null; then
    if _fleet_admit_stamp_or_fail "$admit"; then
      # codex-1 (HIMMEL-2774, 4th panel round): a fresh claim never wrote a
      # `pid` file, so the live-owner check below (kill -0 on $admit/pid)
      # always read empty/missing and could never protect an actively held
      # lock — a census lasting beyond FLEET_ADMIT_STALE_SECS let a
      # concurrent caller reclaim it and admit alongside the real holder.
      # $$ is this preflight subshell's own pid: the critical section is
      # this subshell's body, so that is the pid whose liveness actually
      # answers "is the holder still in here" (a slow filesystem, a GC
      # pause) -- not the launcher's pid, which is what the RESERVATION's
      # own pid file (below) tracks for a different purpose (whether the
      # launcher that created it is still around to own a release).
      # HIMMEL-3019: fails CLOSED like the stamp below — releases are
      # pid-verified now, so a claim whose pid write failed could never be
      # released by its owner and would wedge admission until it aged out.
      if printf '%s\n' "$$" > "$admit/pid" 2>/dev/null; then
        return 0
      fi
    fi
    # codex-2 (this round): the stamp (or pid) write itself failed (disk full,
    # permissions) — don't return success over an unstamped claim nobody can
    # ever age out. codex-5 (4th panel round): NOT still empty — `>` opens
    # and creates "$admit/acquired" before `date` runs, so a `date` failure
    # leaves that zero-byte file behind; `rmdir` refuses a non-empty
    # directory, so `rm -rf` is required to actually remove the failed claim.
    rm -rf "$admit" 2>/dev/null
    return 1
  fi
  held_at="$(cat "$admit/acquired" 2>/dev/null)" || held_at=""
  case "$held_at" in
    # No readable stamp yet: a fresh claim racing the stamp write, or a crash
    # between mkdir and the stamp write. codex-2 (this round): the crash case
    # used to `return 1` forever with no time reference to ever age out —
    # wedging admission permanently for anyone who has to fall through this
    # branch. Stamp it now instead: idempotent against a genuine concurrent
    # owner (who has already written, or is about to, the same "now"), and it
    # turns an unreclaimable orphan into one reclaimable
    # FLEET_ADMIT_STALE_SECS from THIS observation.
    ''|*[!0-9]*) _fleet_admit_stamp_or_fail "$admit"; return 1 ;;
  esac
  age=$(( $(date +%s) - held_at ))
  [ "$age" -ge "${FLEET_ADMIT_STALE_SECS:-60}" ] || return 1
  # codex-1/codex-2 (HIMMEL-2774, 3rd panel round): age alone cannot tell a
  # crashed holder from one still legitimately inside the critical section
  # (a slow filesystem, a GC pause) — reclaiming out from under a still-live
  # holder loses mutual exclusion outright, and restoring its metadata on a
  # lost race above cannot undo that. The recorded pid is always same-host
  # (this slot dir is per-user tmpfs), so a live pid we own is authoritative:
  # refuse to reclaim while it is still running, no matter how stale the
  # timestamp looks. An unreadable/corrupt pid (crash before the pid write)
  # cannot be verified either way, so it falls through to the existing
  # age-only reclaim rather than wedging forever on an unverifiable holder.
  _fleet_held_pid="$(cat "$admit/pid" 2>/dev/null)"
  case "$_fleet_held_pid" in
    ''|*[!0-9]*) : ;;
    *) kill -0 "$_fleet_held_pid" 2>/dev/null && return 1 ;;
  esac
  _fleet_steal_stale_admit "$admit" "$held_at"
}

fleet_n=0
fleet_native=0
fleet_claudex=0
_fleet_live_names=""
_fleet_procfs_warned=0

# _fleet_census (HIMMEL-2774 codex-1, 2nd panel round): captures the process
# table fresh and (re)sets fleet_n/fleet_native/fleet_claudex/_fleet_live_names
# from it. Factored into a function so it can be called a SECOND time, while
# holding the admission lock below, instead of once up front — a snapshot
# taken before the lock is stale by the time the cap decision runs inside the
# critical section (a session can start or exit in that gap under real
# contention), so the pre-lock call below is only a fail-fast sanity check;
# the decision that actually gates admission uses the in-lock re-census.
# Sets _fleet_ps_cmd/_fleet_ps_rc as a side effect so callers can report a
# failed census; returns 1 without touching the counters on failure so a
# caller can fall back to the last-known-good snapshot instead of zeroing it.
_fleet_census() {
  local _fc_n=0 _fc_native=0 _fc_claudex=0 _fc_names="" _fc_raw
  # Plain (non-IFS=) `read` here is deliberate: a real `ps -eo pid=,args=`
  # right-justifies the PID column with LEADING spaces for every row
  # narrower than the widest pid in the table, and default `read` field
  # splitting trims that leading whitespace before assigning $_fleet_pid —
  # an explicit `IFS= read -r` whole-line capture followed by `${line%% *}`
  # does NOT, and silently produces an EMPTY pid (failing is_int, and so
  # silently dropping the row) for every line except the one with the
  # widest pid in the table.
  if [ -n "${FLEET_PS_CMD:-}" ]; then
    _fleet_ps_cmd="$FLEET_PS_CMD"
    _fc_raw="$("$FLEET_PS_CMD" 2>&1)"
  else
    _fleet_ps_cmd="ps -eo pid=,args="
    _fc_raw="$(ps -eo pid=,args= 2>&1)"
  fi
  _fleet_ps_rc=$?
  [ "$_fleet_ps_rc" -eq 0 ] || return 1
  while read -r _fleet_pid _fleet_rest; do
    is_int "$_fleet_pid" || continue
    _fleet_comm="$(cat "${FLEET_PROC:-/proc}/$_fleet_pid/comm" 2>/dev/null)"
    if [ -n "$_fleet_comm" ]; then
      [ "$_fleet_comm" = claude ] || continue
    elif [ "$_fleet_procfs_warned" -eq 0 ]; then
      echo "bank-preflight: comm unreadable for at least one fleet candidate (pid $_fleet_pid) — falling back to argv-only matching for it (less precise: may double-count a launcher/child pair)" >&2
      _fleet_procfs_warned=1
    fi
    _fc_n=$((_fc_n + 1))
    if [ "$(_fleet_lane_of "$_fleet_pid")" = claudex ]; then
      _fc_claudex=$((_fc_claudex + 1))
    else
      _fc_native=$((_fc_native + 1))
    fi
    # HIMMEL-2774: a live session with this name CONSUMES its reservation
    # (below) — same match shape as the FLEET_CANDIDATES filter itself, so a
    # session counted here is recognized consistently there.
    _fleet_name="$(printf '%s\n' "$_fleet_rest" | grep -oE -- '-n[[:space:]]+(HIMMEL|LUNA)-[^[:space:]]*' | head -1 | awk '{print $2}')"
    [ -n "$_fleet_name" ] && _fc_names="$_fc_names
$_fleet_name"
  done <<FLEET_CANDIDATES
$(printf '%s\n' "$_fc_raw" \
  | grep -E -- '-n[[:space:]]+(HIMMEL|LUNA)-' \
  | grep -vE -- '-n[[:space:]]+(HIMMEL|LUNA)-[^[:space:]]*-console')
FLEET_CANDIDATES
  fleet_n=$_fc_n
  fleet_native=$_fc_native
  fleet_claudex=$_fc_claudex
  _fleet_live_names=$_fc_names
  return 0
}

if ! _fleet_census; then
  echo "bank-preflight: fleet process census failed ('$_fleet_ps_cmd' exited $_fleet_ps_rc) — cannot verify the fleet is under cap; refusing rather than silently permitting an unbounded launch" >&2
  echo "bank-preflight: FLEET ?/$FLEET_CAP" >&2
  # codex-2 (CR review, 4th panel round, Suggestion): the documented
  # FLEET_CAP_OK=1 override must apply here too - a broken/unsupported
  # census is exactly the situation where the operator most needs the
  # bypass to recover a launch, and it must not be reachable only on the
  # ordinary at/over-cap path below.
  if [ "${FLEET_CAP_OK:-}" = "1" ]; then
    echo "bank-preflight: FLEET_CAP_OK bypass in effect (launching shell only) — proceeding despite the failed census" >&2
  elif [ "$LAUNCH_INTENT" = "1" ]; then
    emit SKIPPED-FLEET
  else
    echo "bank-preflight: not a declared launch (CADENCE_BANK_LAUNCH unset) — reporting only, not refusing" >&2
  fi
fi

# HIMMEL-2774: slot dir is per-user tmpfs, never inside the repo or the
# handover root — reservations must not survive a reboot or leak into
# anything git-tracked.
SLOTS="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"
mkdir -p "$SLOTS" 2>/dev/null

fleet_reserved=0
_fleet_admitted=0
_fleet_admit_iters=0
while [ "$_fleet_admit_iters" -lt "${FLEET_ADMIT_RETRY_ITERS:-100}" ]; do
  _fleet_claim_admit "$SLOTS/.admit" && { _fleet_admitted=1; break; }
  sleep "${FLEET_ADMIT_RETRY_SLEEP:-0.05}"
  _fleet_admit_iters=$((_fleet_admit_iters + 1))
done

if [ "$_fleet_admitted" -eq 1 ]; then
  # codex-1 (HIMMEL-2774, 2nd panel round): re-census now, while holding
  # the admission lock, so the count feeding the cap decision below cannot
  # go stale between the pre-lock snapshot above and here — a session can
  # start or exit in that gap under real contention. codex-5 (HIMMEL-2774,
  # 3rd panel round): a transient failure of this second census used to fall
  # back to the pre-lock snapshot silently (_fleet_census leaves the counters
  # untouched on failure) and admit on it — the same "cannot verify the
  # fleet is under cap" situation as the pre-lock census failure above, just
  # reached from inside the lock instead of before it, so it gets the same
  # refuse-unless-bypassed treatment rather than a silent pass-through.
  if ! _fleet_census; then
    echo "bank-preflight: in-lock fleet census failed ('$_fleet_ps_cmd' exited $_fleet_ps_rc) — cannot verify the fleet is under cap; refusing rather than admit on a stale pre-lock snapshot" >&2
    # codex-2 (HIMMEL-2774, 4th panel round): once the release SUCCEEDS the flag
    # must drop — on the bypass/informational branches below (the
    # LAUNCH_INTENT=1 refusal branch `emit`s and exits, so it never reaches
    # this), execution falls through to the final
    # `[ "$_fleet_admitted" -eq 1 ] && _fleet_release_admit` cleanup, which would
    # then delete whatever a DIFFERENT caller has legitimately claimed in the
    # meantime. CodeRabbit (HIMMEL-3019): the gated release can now FAIL (gate
    # busy past its retries, lock left to age out), so the flag drops only on
    # success. A failed release keeps it set: the prune pass stays gated on
    # still holding the lock and the final cleanup retries — safe, since every
    # release is pid-verified and cannot remove a successor's lock.
    if _fleet_release_admit "$SLOTS/.admit"; then _fleet_admitted=0; fi
    if [ "${FLEET_CAP_OK:-}" = "1" ]; then
      echo "bank-preflight: FLEET_CAP_OK bypass in effect (launching shell only) — proceeding despite the failed in-lock census" >&2
    elif [ "$LAUNCH_INTENT" = "1" ]; then
      emit SKIPPED-FLEET
    else
      echo "bank-preflight: not a declared launch (CADENCE_BANK_LAUNCH unset) — reporting only, not refusing" >&2
    fi
  fi
  # codex-2 (HIMMEL-2774, 5th panel round): this whole prune pass must stay
  # gated on STILL holding the lock — the in-lock-census-failure branch above
  # can reset _fleet_admitted to 0 and `rm -rf` .admit early (the bypass and
  # informational sub-branches there don't exit), and this `if` only tested
  # the ORIGINAL claim result once, at the top: without re-checking here, the
  # loop below ran UNLOCKED. An unlocked prune reading another caller's
  # `expires` file in the gap between ITS `mkdir` and its `expires` write
  # (both above, in `_fleet_reserve`) sees the case-statement's
  # unreadable/corrupt branch and deletes that brand-new reservation before
  # its owner ever finishes creating it.
  if [ "$_fleet_admitted" -eq 1 ]; then
    _fleet_now=$(date +%s)
    for _fleet_resv in "$SLOTS"/*/; do
      [ -d "$_fleet_resv" ] || continue
      _fleet_resv_name="$(basename "$_fleet_resv")"
      [ "$_fleet_resv_name" = .admit ] && continue
      _fleet_resv_expires="$(cat "${_fleet_resv}expires" 2>/dev/null)"
      case "$_fleet_resv_expires" in
        # Unreadable/corrupt metadata is not a valid reservation — prune it
        # the same as an expired one rather than counting it forever.
        ''|*[!0-9]*) rm -rf "$_fleet_resv" 2>/dev/null; continue ;;
      esac
      if [ "$_fleet_now" -ge "$_fleet_resv_expires" ]; then
        rm -rf "$_fleet_resv" 2>/dev/null
        continue
      fi
      # A live session with this name already counted in fleet_n above
      # CONSUMES the reservation — do not double-count the same slot.
      # codex-4 (round 4): consuming must DELETE the reservation, not just
      # skip it in the count — left on disk, it keeps refusing a same-name
      # relaunch as a duplicate (line ~356) for up to the full TTL after the
      # session that consumed it has already exited, with no live session left
      # to justify the refusal.
      #
      # HIMMEL-3012: matched on the directory name (every reservation, incl.
      # ones written by an older copy of this script that has no `name` file)
      # OR the first whitespace token of the raw leg name in `name` — the same
      # tokenization the census applies to a live `-n` value — so a name with
      # a space, or one hashed into its directory key ('/', a leading '.',
      # over NAME_MAX), is consumed instead of double-counted until its TTL.
      # BY DESIGN not matched: arm-resume.sh reserves under the flattened
      # handover path but launches under `-n <TICKET> <name> s<N>`, so its
      # reservation never matches a live session — it is released by that
      # script's EXIT trap (_arm_fleet_release_pending) on every exit instead.
      # A live session consumes ONE reservation: the matched name is dropped
      # from the live list once used, so two reservations sharing one first
      # token ("HIMMEL-1 a" and "HIMMEL-1 b") against a single live "HIMMEL-1"
      # session leave one still counted (live + pending = 2), never both
      # deleted (which would let an extra admission past the cap).
      _fleet_resv_sname=""
      [ -f "${_fleet_resv}name" ] && read -r _fleet_resv_sname _fleet_resv_rest <"${_fleet_resv}name" 2>/dev/null
      _fleet_resv_hit=""
      if printf '%s\n' "$_fleet_live_names" | grep -qxF "$_fleet_resv_name"; then
        _fleet_resv_hit="$_fleet_resv_name"
      elif [ -n "$_fleet_resv_sname" ] && printf '%s\n' "$_fleet_live_names" | grep -qxF "$_fleet_resv_sname"; then
        _fleet_resv_hit="$_fleet_resv_sname"
      fi
      if [ -n "$_fleet_resv_hit" ]; then
        _fleet_live_names="$(printf '%s\n' "$_fleet_live_names" | _FLEET_DROP="$_fleet_resv_hit" awk '!d && $0 == ENVIRON["_FLEET_DROP"] {d=1; next} {print}')"
        rm -rf "$_fleet_resv" 2>/dev/null
        continue
      fi
      fleet_reserved=$((fleet_reserved + 1))
    done
    fleet_n=$((fleet_n + fleet_reserved))
  fi
fi

echo "bank-preflight: FLEET native=$fleet_native claudex=$fleet_claudex reserved=$fleet_reserved total=$fleet_n/$FLEET_CAP" >&2

if [ "$_fleet_admitted" -eq 0 ]; then
  echo "bank-preflight: could not acquire the fleet admission lock ($SLOTS/.admit) after $_fleet_admit_iters retries — cannot verify the fleet is under cap" >&2
  if [ "${FLEET_CAP_OK:-}" = "1" ]; then
    echo "bank-preflight: FLEET_CAP_OK bypass in effect (launching shell only) — proceeding despite the admission-lock failure" >&2
  elif [ "$LAUNCH_INTENT" = "1" ]; then
    emit SKIPPED-FLEET
  else
    echo "bank-preflight: not a declared launch (CADENCE_BANK_LAUNCH unset) — reporting only, not refusing" >&2
  fi
elif [ "$fleet_n" -ge "$FLEET_CAP" ]; then
  # codex-3 (CR review, 2nd panel round, Suggestion): the documented
  # contract is FLEET_CAP_OK=1 specifically; a bare `-n` (non-empty) test
  # would also treat FLEET_CAP_OK=0 or FLEET_CAP_OK=false as an enabled
  # bypass. Compare exactly.
  if [ "${FLEET_CAP_OK:-}" = "1" ]; then
    echo "bank-preflight: fleet at/over cap ($fleet_n/$FLEET_CAP) — FLEET_CAP_OK bypass in effect (launching shell only), proceeding" >&2
  elif [ "$LAUNCH_INTENT" = "1" ]; then
    echo "bank-preflight: fleet at/over cap ($fleet_n/$FLEET_CAP) — skipping leg=$LEG (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >&2
    _fleet_release_admit "$SLOTS/.admit"
    emit SKIPPED-FLEET
  else
    echo "bank-preflight: fleet at/over cap ($fleet_n/$FLEET_CAP) — not a declared launch (CADENCE_BANK_LAUNCH unset), reporting only" >&2
  fi
elif [ "$LAUNCH_INTENT" = "1" ] && [ -n "$LEG" ] && [ "$LEG" != unknown ]; then
  # codex-3 (HIMMEL-2774, 4th panel round): '/', a leading '.', and
  # ENAMETOOLONG used to all "proceed without a reservation" — restoring,
  # for exactly those names, the concurrent over-admission race this whole
  # mechanism exists to close. A deterministic, bounded hash of $LEG is
  # always a valid mkdir target: two callers with the identical (unusable)
  # $LEG hash to the identical key, so mkdir's own EEXIST still catches a
  # genuine duplicate declared launch. Such a reservation is never
  # name-matched by a live session's census entry (its directory name isn't
  # the leg name) — it just counts against the cap and expires by TTL, the
  # same fallback arm-resume.sh's own flattened-path reservation already
  # relies on.
  #
  # HIMMEL-3014/3017: the key derivation lives in fleet-reservation-key.sh so
  # arm-resume.sh's exit-trap release resolves the SAME key this reserves under
  # (it used to look up the raw name and miss a hashed reservation). Names over
  # NAME_MAX are now hashed BEFORE the mkdir instead of only after it fails;
  # the resulting key is the one the old retry produced, so a reservation made
  # by an older copy of this script is still found by the new release.
  # codex-6 (this round, kept): a failed `expires` write left a reservation
  # with no readable expiry, which the very next admission's prune pass
  # (unreadable/corrupt metadata) removes immediately — silently reusing the
  # capacity this reservation existed to hold. Refuse and clean up instead
  # of proceeding on an unprotected slot. `pid` (the CALLER's pid, passed
  # through by launchers that set CADENCE_BANK_CALLER_PID, not this
  # subshell's own $$ — so a release can verify it owns the slot before
  # deleting it) is what arm-resume.sh's release checks ownership against, so
  # a reservation without it could never be released by its owner and would
  # linger to its TTL: its write is gated the same way (CodeRabbit, PR #858).
  _fleet_reserve() { # _fleet_reserve <reservation-dir> -- 0 created, 1 mkdir
    local dir="$1"   # failed (not a dup — e.g. ENAMETOOLONG), 2 duplicate,
    if mkdir "$dir" 2>/dev/null; then    # 3 metadata write failed
      if printf '%s\n' "$(( $(date +%s) + ${FLEET_RESERVE_TTL:-1800} ))" > "$dir/expires" 2>/dev/null &&
         printf '%s\n' "${CADENCE_BANK_CALLER_PID:-$$}" > "$dir/pid" 2>/dev/null; then
        # HIMMEL-3012: the raw leg name, for the consume check in the prune
        # pass — the directory name is a hash whenever $LEG cannot be one
        # directory component, and the census only ever sees the FIRST
        # whitespace token of a live `-n` value. Best-effort by design: it
        # only WIDENS what consumes the reservation, so a failed write falls
        # back to today's dir-name match rather than refusing the launch.
        printf '%s\n' "$LEG" > "$dir/name" 2>/dev/null || true
        return 0
      fi
      rm -rf "$dir" 2>/dev/null
      return 3
    fi
    [ -e "$dir" ] && return 2
    return 1
  }
  # Sourced here, not at the top: only a declared launch needs a key, and a
  # plain bank READ must never be refused over it. Fail closed like the
  # siblings below — a launch this script cannot key is one it cannot count.
  # Sibling of this script (not $REPO/scripts/lib): suites copy the lib dir
  # into an isolated tree whose layout is not the repo's.
  # shellcheck source=scripts/lib/fleet-reservation-key.sh
  . "$(dirname "$0")/fleet-reservation-key.sh" 2>/dev/null || {
    echo "bank-preflight: cannot source $(dirname "$0")/fleet-reservation-key.sh — refusing rather than launch without a countable reservation" >&2
    _fleet_release_admit "$SLOTS/.admit"
    emit SKIPPED-FLEET
  }
  _fleet_resv_key="$(fleet_reservation_key "$LEG")"
  _fleet_reserve "$SLOTS/$_fleet_resv_key"
  _fleet_reserve_rc=$?
  if [ "$_fleet_reserve_rc" -eq 1 ]; then
    # codex-5 (HIMMEL-2774, 2nd panel round): `mkdir` failing does NOT mean
    # "already exists" — a LEG name flattened from a long path can exceed
    # the filesystem's per-component name limit (ENAMETOOLONG), which reads
    # here identically to EEXIST unless distinguished. Retry once with the
    # hashed key, which is always short and always a valid mkdir target. Still
    # reachable on a filesystem whose limit is below 255 bytes (e.g. 143 on
    # ecryptfs) — arm-resume.sh's release tries this key too.
    _fleet_resv_key="$(fleet_hash_key "$LEG")"
    _fleet_reserve "$SLOTS/$_fleet_resv_key"
    _fleet_reserve_rc=$?
  fi
  case "$_fleet_reserve_rc" in
    0) : ;;
    2)
      echo "bank-preflight: a fleet reservation for leg=$LEG already exists — refusing as a duplicate declared launch" >&2
      _fleet_release_admit "$SLOTS/.admit"
      emit SKIPPED-FLEET
      ;;
    3)
      echo "bank-preflight: failed to write reservation metadata (expires/pid) for leg=$LEG — refusing admission rather than proceed with an unprotected slot" >&2
      _fleet_release_admit "$SLOTS/.admit"
      emit SKIPPED-FLEET
      ;;
    *)
      # codex-3 (HIMMEL-2774, 5th panel round): proceeding here left the
      # launch unprotected exactly the same way a duplicate (case 2) or a
      # failed metadata write (case 3) would — this process's own reservation
      # never lands, so it cannot count against a concurrent caller's cap
      # decision until its live process shows up in the census, reopening
      # the over-admission race this mechanism exists to close. Refuse like
      # its siblings instead of silently proceeding on filesystem/permission
      # failures that mkdir cannot otherwise distinguish from "already taken".
      echo "bank-preflight: could not create a fleet reservation directory for leg=$LEG even under a hashed key — refusing rather than proceed without a reservation" >&2
      _fleet_release_admit "$SLOTS/.admit"
      emit SKIPPED-FLEET
      ;;
  esac
fi
# codex-1 (HIMMEL-2774, 5th panel round): unconditional release here can
# delete a DIFFERENT owner's lock. If the original holder is only PRESUMED
# dead (its pid file was unreadable/corrupt, so the liveness check above could
# not confirm either way) and is in fact still alive and working, it reaches
# this same release line later never knowing it was stolen from — and a bare
# unconditional rm -rf would then delete whatever a THIRD party has since
# legitimately claimed. Every claim path ($$-stamped at
# _fleet_claim_admit/_fleet_steal_stale_admit, both above) writes ITS OWN pid
# into "$admit/pid" the moment it wins the slot, so verifying that pid still
# reads back as $$ before deleting is the same ownership check
# arm-resume.sh's own _arm_fleet_release_pending already uses for its
# reservation release, applied here to the admission lock itself: a mismatch
# means someone else now legitimately owns .admit, and this process has
# nothing left to release. HIMMEL-3019: that check now lives in
# _fleet_release_admit (gated, so it cannot land between a reclaimer's
# verification and its rename) and EVERY release site — the early-exit
# refusals above as well as this final one — goes through it.
if [ "$_fleet_admitted" -eq 1 ]; then
  _fleet_release_admit "$SLOTS/.admit"
fi

# HIMMEL-2782: claudex lane parks on the codex weekly bank instead of the
# Claude five_hour/seven_day check below — that check governs a different
# bucket entirely, and a claudex leg must never be refused by it. Reads
# scripts/lanes/bank-status.ts's "claudex" row (lane id "claudex", bank
# "codex" in lanes.json) rather than spawning scripts/lanes/codex-bank-probe.ts
# itself (bank-status.ts's own documented contract: the probe is a leaky
# per-call spawn, never called from a preflight). funded -> PROCEED, spent ->
# SKIPPED-BANK (the codex bank equivalent of the Claude over() park below),
# unknown/unreadable -> WARN naming the probe failure and PROCEED (never
# refuse a launch over an unmeasurable claudex bank).
if [ "$LANE" = claudex ]; then
  # codex-3 (HIMMEL-2782 CR fix): same bug class as FLEET_PS_CMD above —
  # an unquoted override word-splits a path containing a space. The
  # DEFAULT genuinely needs word-splitting (it is a command plus flags);
  # an override is a single executable path and must be quoted.
  if [ -n "${CADENCE_BANK_STATUS_CMD:-}" ]; then
    _claudex_status_line="$("$CADENCE_BANK_STATUS_CMD" 2>/dev/null | grep -E '^claudex ' | head -1)"
  else
    _claudex_status_line="$(bun "$REPO/scripts/lanes/bank-status.ts" 2>/dev/null | grep -E '^claudex ' | head -1)"
  fi
  _claudex_state="$(printf '%s\n' "$_claudex_status_line" | awk '{print $2}')"
  case "$_claudex_state" in
    funded)
      echo "bank-preflight: claudex lane funded ($_claudex_status_line) — leg=$LEG proceeding on the codex bank" >&2
      emit PROCEED
      ;;
    spent)
      echo "bank-preflight: claudex lane spent ($_claudex_status_line) — skipping leg=$LEG" >&2
      emit SKIPPED-BANK
      ;;
    *)
      echo "bank-preflight: claudex lane state unmeasurable/unknown (codex-bank-probe failure or stale cache: run bun $REPO/scripts/lanes/codex-bank-probe.ts) — WARN, proceeding leg=$LEG" >&2
      emit PROCEED
      ;;
  esac
fi

is_num "$MAX_PCT" || { echo "bank-preflight: invalid CADENCE_BANK_MAX_PCT '$MAX_PCT'" >&2; emit BANK-UNKNOWN; }
is_int "$MAX_AGE" || { echo "bank-preflight: invalid CADENCE_BANK_MAX_AGE '$MAX_AGE'" >&2; emit BANK-UNKNOWN; }

# Refresh first. USAGE_OAUTH_TTL=0 is load-bearing: the producer skips the
# fetch when oauth_checked_at is younger than the default 3540s, and the
# drift pair fires 30 min apart — without this, leg 2 is BANK-STALE every
# night. </dev/null is load-bearing too: the producer reads `input=$(cat)`
# and blocks until EOF.
if [ -z "${CADENCE_BANK_SKIP_REFRESH:-}" ] && [ -f "$PRODUCER" ]; then
  CLAUDE_USAGE_CACHE="$CACHE" USAGE_OAUTH_TTL=0 \
    bash "$PRODUCER" </dev/null >/dev/null 2>&1 || true
fi

command -v jq >/dev/null 2>&1 || { echo "bank-preflight: jq missing" >&2; emit BANK-UNKNOWN; }
[ -f "$CACHE" ] || { echo "bank-preflight: no cache at $CACHE" >&2; emit BANK-UNKNOWN; }

# One jq process keeps the cadence guard inside the held-stdin regression's
# 3s bound on Git Bash, where each extra process launch is comparatively slow.
{
  IFS= read -r fh
  IFS= read -r sd
  IFS= read -r xu
  IFS= read -r stamp
} < <(jq -r '
  .five_hour.utilization // "",
  .seven_day.utilization // "",
  .extra_usage.utilization // "",
  .primaries_refreshed_at // ""
  ' "$CACHE" 2>/dev/null)
# Process-substitution output is CRLF-translated by some Git Bash builds.
fh=${fh%$'\r'}; sd=${sd%$'\r'}; xu=${xu%$'\r'}; stamp=${stamp%$'\r'}

usable=0
is_num "$fh" && usable=$((usable+1))
is_num "$sd" && usable=$((usable+1))
[ "$usable" -gt 0 ] || { echo "bank-preflight: no usable primary" >&2; emit BANK-UNKNOWN; }

# Staleness keys on primaries_refreshed_at, NOT file mtime. The producer only
# advances this aggregate stamp when both fetched primary windows are valid;
# partial-primary and extra_usage-only writes preserve the prior stamp.
is_int "$stamp" || { echo "bank-preflight: no usable primaries_refreshed_at" >&2; emit BANK-STALE; }
# 10# forces base-10: a leading-zero stamp ("0123") would otherwise be read as
# octal and a value like "089" errors outright. Not reachable from the real
# producer (--argjson integer), but it fails open loudly rather than quietly.
stamp=$((10#$stamp))
age=$(( $(date +%s) - stamp ))
if [ "$age" -lt 0 ] || [ "$age" -gt "$MAX_AGE" ]; then
  echo "bank-preflight: primaries ${age}s old (max ${MAX_AGE})" >&2
  emit BANK-STALE
fi

[ "$usable" -eq 2 ] || echo "bank-preflight: degraded — one primary unusable" >&2
echo "bank-preflight: leg=$LEG five_hour=${fh:-n/a} seven_day=${sd:-n/a} extra_usage=${xu:-n/a} age=${age}s" >&2

over() { is_num "$1" && awk -v a="$1" -v b="$MAX_PCT" 'BEGIN{exit !(a>=b)}'; }
if over "$fh" || over "$sd"; then
  echo "bank-preflight: at/over ${MAX_PCT}% — skipping leg=$LEG" >&2
  emit SKIPPED-BANK
fi
emit PROCEED
