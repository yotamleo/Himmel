#!/usr/bin/env bash
# test-bank-preflight-admit-gate.sh — HIMMEL-3019. RED-first suite for the
# reclaim/release GATE around bank-preflight.sh's `.admit` admission lock.
#
# The bug: _fleet_steal_stale_admit's `mv admit victim` displaces WHATEVER
# currently occupies `.admit` — including a live holder's brand-new claim
# made after the reclaimer read the stale stamp. The mismatch branch then
# restores it, but `.admit` is absent between the rename and the restore, so a
# fourth party's ordinary `mkdir` claim can win that window and two callers
# hold the lock at once. The fix serialises every actor that can DISPLACE an
# existing `.admit` (steal, and every release) on `.admit.reclaim`, and moves
# the stamp check UNDER that gate, before any rename.
#
# The interleavings are forced in-process (no sleeps, no races): the functions
# are extracted from the SUT and driven with an env-gated seam
# (FLEET_ADMIT_TEST_HOOK, default unset = off in production) plus an `mv`
# function shadow that runs a hook straight after a rename. SUT is a variable
# (FLEET_SUT) so this SAME suite runs against the pre-fix script for genuine
# RED evidence and against the fixed one for GREEN.
#
# No .ps1 twin: the mkdir-based admission lock lives on a POSIX tmpfs
# (${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-<uid>) with no Windows equivalent
# (project convention: a documented platform guard suffices for a test
# harness).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="${FLEET_SUT:-$REPO/scripts/lib/bank-preflight.sh}"
PASS=0; FAIL=0
W="$(mktemp -d -t bank-preflight-admit-gate.XXXXXX)" || { echo "FAIL - could not create scratch dir via mktemp" >&2; exit 1; }
if [ -z "$W" ] || [ ! -d "$W" ]; then echo "FAIL - mktemp returned an empty/invalid scratch dir" >&2; exit 1; fi
# A long-lived foreign process: its pid is "a live holder that is not this
# shell". Every party below runs inside this one shell (so $$ is shared);
# ownership questions are therefore asked about A_PID, never about $$.
sleep 300 & A_PID=$!
trap 'kill "$A_PID" 2>/dev/null; rm -rf "$W"' EXIT
NOW="$(date +%s)"

# count_glob <pattern...> — how many of the (already glob-expanded) paths exist;
# a bash-glob count, so no GNU/BSD `find -maxdepth` divergence.
count_glob() { local n=0 f; for f in "$@"; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# Extract the admit-lock functions (everything from the first one up to the
# census counters) so they can be driven directly.
_start="$(grep -n '^_fleet_admit_stamp_or_fail() {' "$SUT" | cut -d: -f1)"
_end="$(grep -n '^fleet_n=0$' "$SUT" | cut -d: -f1)"
if [ -z "$_start" ] || [ -z "$_end" ] || [ "$_end" -le "$_start" ]; then
  echo "FAIL - could not locate the admit-lock functions in $SUT" >&2; exit 1
fi
sed -n "${_start},$((_end - 1))p" "$SUT" > "$W/fns.sh"

# shellcheck disable=SC2034 # read by the SUT functions sourced below
FLEET_ADMIT_STALE_SECS=60
# shellcheck disable=SC2034
FLEET_ADMIT_RETRY_SLEEP=0.01
# shellcheck disable=SC2034
FLEET_ADMIT_RELEASE_ITERS=3
export FLEET_ADMIT_TEST_HOOK=_t_hook

# --- seams ------------------------------------------------------------------
HOOK_MODE=""; HOOK_FIRED=0; MV_INJECT=""
_t_hook() { # <point> <path> — env-gated seam target; a no-op unless a case sets HOOK_MODE
  [ -n "$HOOK_MODE" ] || return 0
  case "$HOOK_MODE:$1" in
    dclaim:post-verify|dclaim:post-rename) HOOK_FIRED=$((HOOK_FIRED + 1)); _inject_d "$2" ;;
    release-and-claim:post-verify) HOOK_FIRED=$((HOOK_FIRED + 1)); _inject_release_and_claim "$2" ;;
    swap-fresh:post-verify) HOOK_FIRED=$((HOOK_FIRED + 1)); _inject_swap_fresh "$2" ;;
    pid-write-fails:post-verify) HOOK_FIRED=$((HOOK_FIRED + 1)); PRINTF_FAIL=1 ;;
    break-race:gate-break) HOOK_FIRED=$((HOOK_FIRED + 1)); HOOK_MODE=""; _inject_breaker_one "$2" ;;
    count-retry:release-retry) HOOK_FIRED=$((HOOK_FIRED + 1)) ;;
    paused-holder:post-verify) HOOK_FIRED=$((HOOK_FIRED + 1)); HOOK_MODE=""; _inject_paused_holder "$2" ;;
    paused-taker:gate-made) HOOK_FIRED=$((HOOK_FIRED + 1)); HOOK_MODE=""; _inject_paused_taker "$2" ;;
    gen-pause1:gate-break) _inject_s_pause1 ;;
  esac
  return 0
}
# shellcheck disable=SC2317  # reached through the shadowed `mv` below and _t_hook
_inject_d() { # D, a fourth party, runs the ORDINARY claim path inside the window
  local saved="$HOOK_MODE" saved_mv="$MV_INJECT"
  HOOK_MODE=""; MV_INJECT=""
  _fleet_claim_admit "$1" && D_WON=1
  HOOK_MODE="$saved"; MV_INJECT="$saved_mv"
}
# shellcheck disable=SC2317
_inject_release_and_claim() { # the presumed-dead holder releases, then D claims — both inside C's verify->rename window
  local saved="$HOOK_MODE"; HOOK_MODE=""
  _fleet_release_admit "$1" 2>/dev/null; REL_RC=$?
  _fleet_claim_admit "$1"; D_RC=$?
  HOOK_MODE="$saved"
}
# shellcheck disable=SC2317
_inject_swap_fresh() { # an UNGATED older-copy actor replaces the stale claim with a fresh live one after C's verify
  rm -rf "$1"; mkdir "$1"; printf '%s\n' "$(date +%s)" > "$1/acquired"; printf '%s\n' "$A_PID" > "$1/pid"
}
# shellcheck disable=SC2317
_inject_breaker_one() { # breaker B1 takes the (stale) gate in full while B2 sits between its age check and its rename
  _fleet_gate_take "$1"; B1_RC=$?
}
# shellcheck disable=SC2317
_inject_paused_holder() { # C is PAUSED past the gate age between its verify and its rename
  # The pause: C's gate is now older than FLEET_ADMIT_GATE_STALE_SECS. B breaks
  # it and completes its OWN steal of the same stale admit — B is the live
  # successor holder, marked `who=B`. Only then does D (a fourth party) arm, to
  # claim in whatever window C's resumed rename opens.
  builtin printf '%s\n' "$(( $(date +%s) - 10 ))" > "$1.reclaim/acquired"
  _fleet_steal_stale_admit "$1" "$P_STALE"; B1_RC=$?
  builtin printf '%s\n' B > "$1/who" 2>/dev/null
  MV_INJECT=_inject_d
}
# shellcheck disable=SC2317
_inject_paused_taker() { # A is PAUSED between its gate mkdir and its fence mkdir
  # The pause ages A's (still unstamped) gate out; B breaks it and holds a
  # fresh, fenced gate. A then resumes INTO B's gate.
  builtin printf '%s\n' "$(( $(date +%s) - 10 ))" > "$1/acquired"
  _fleet_gate_take "$1"; B1_RC=$?; B_FENCE="${_fleet_gate_fence:-}" # set by the SUT's _fleet_gate_take
}
# `mv` shadow: a function outranks the command, so the SUT's own `mv` calls run
# this — the pre-fix script has no hook points at all, and this is how the SAME
# interleaving is forced against it (D claims straight after the rename).
mv() { command mv "$@"; local rc=$?; [ -n "$MV_INJECT" ] && "$MV_INJECT" "${1:-}"; return $rc; }
# `rm` shadow, same shape: RM_INJECT fires after a `rm` whose arguments name a
# fence of RM_GATE (the pre-HIMMEL-3232 breaker's in-place fence delete) — the
# one point between that delete and the breaker's gate `mv`; (s) only.
RM_INJECT=""; RM_GATE=""
# RM_FAIL_GATE (HIMMEL-3223): a `rm` naming a fence of that gate, or one of its
# `.broken.` victims, fails without removing anything — a simulated EACCES.
RM_FAIL_GATE=""
# shellcheck disable=SC2317
rm() {
  if [ -n "$RM_FAIL_GATE" ]; then
    case " $* " in *" $RM_FAIL_GATE/fence."*|*" $RM_FAIL_GATE.broken."*) return 1 ;; esac
  fi
  command rm "$@"; local rc=$?; case " $* " in *" $RM_GATE/fence."*) [ -n "$RM_INJECT" ] && "$RM_INJECT" ;; esac; return $rc
}
# `mkdir` shadow, same shape: MK_INJECT fires after a `mkdir "$MK_GATE/revoked"`
# (the pre-HIMMEL-3232 breaker's first step), so (s) can pause a breaker there.
MK_INJECT=""; MK_GATE=""
# shellcheck disable=SC2317
mkdir() { command mkdir "$@"; local rc=$?; case " $* " in *" $MK_GATE/revoked "*) [ -n "$MK_INJECT" ] && "$MK_INJECT" ;; esac; return $rc; }
PRINTF_FAIL=0
# shellcheck disable=SC2317,SC2059
printf() { if [ "$PRINTF_FAIL" = 1 ] && [ "${1:-}" = '%s\n' ] && [ "${2:-}" = "$$" ]; then return 1; fi; builtin printf "$@"; }
D_WON=0; D_RC=""; REL_RC=""; B1_RC=""; P_STALE=""; B_FENCE=""
# shellcheck disable=SC1091
. "$W/fns.sh"

# HIMMEL-1712: hermetic identity so the cache fixture below matches the
# current session -- this suite is about the admit-gate lock, not identity.
# Below the mkdir()/printf() shadows above so shellcheck sees them in
# definition order (it flags a bare call to a name shadowed further down).
export HOME="$W/home"; mkdir -p "$HOME"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-admit-gate-test"}}' > "$HOME/.claude.json"
# shellcheck source=usage-cache-identity.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/usage-cache-identity.sh"
ACCT="$(current_account_hash)"

mk_admit() { # <admit> <stamp> <pid> — a claim in a given state; clears any gate
  rm -rf "$1" "$1.reclaim"; mkdir "$1"; builtin printf '%s\n' "$2" > "$1/acquired"; builtin printf '%s\n' "$3" > "$1/pid"
}
mk_gate() { # <gate> <stamp> <pid>
  rm -rf "$1"; mkdir "$1"; builtin printf '%s\n' "$2" > "$1/acquired"; builtin printf '%s\n' "$3" > "$1/pid"
}
have_fn() { command -v "$1" >/dev/null 2>&1 && [ "$(type -t "$1")" = function ]; }

admit="$W/.admit"

# --- (a) THE TICKET RACE, x20 -------------------------------------------------
# A holds a FRESH, live claim. C observed a stale stamp S earlier and now
# reclaims with expected_at=S; D (a fourth party) runs the ordinary claim path
# inside the window. Exactly one holder must exist: A keeps the lock, C gets a
# clean return 1, D is refused. Pre-fix: C's rename displaces A's live dir, D's
# mkdir wins the empty slot, and two callers hold the lock (20/20).
bad=0
for _i in $(seq 1 20); do
  _now="$(date +%s)"
  mk_admit "$admit" "$_now" "$A_PID"
  D_WON=0; HOOK_FIRED=0; HOOK_MODE=dclaim; MV_INJECT=_inject_d
  _fleet_steal_stale_admit "$admit" "$((_now - 61))"; c_rc=$?
  HOOK_MODE=""; MV_INJECT=""
  _fleet_claim_admit "$admit"; d_after=$?
  owner="$(cat "$admit/pid" 2>/dev/null)"
  if [ "$c_rc" != 1 ] || [ "$D_WON" != 0 ] || [ "$d_after" != 1 ] || [ "$owner" != "$A_PID" ] || [ -e "$admit.reclaim" ]; then
    bad=$((bad + 1))
  fi
done
check "(a) ticket race x20: A keeps the lock, C returns 1, D refused, no gate left behind (violating runs)" 0 "$bad"

# --- (a2) a mismatched reclaimer must not touch .admit at all -----------------
# Stronger than "one holder": with the check under the gate there is no rename,
# so A's directory is the SAME inode-level object afterwards — its files are
# byte-identical and no `.stale.` victim was ever created.
_now="$(date +%s)"
mk_admit "$admit" "$_now" "$A_PID"
rm -rf "$W"/.admit.stale.* 2>/dev/null
_fleet_steal_stale_admit "$admit" "$((_now - 61))"
victims="$(count_glob "$W"/.admit.stale.*)"
check "(a2) a mismatched reclaim creates no .stale. victim (it never renames)" 0 "$victims"

# --- (b) release under a BUSY gate retry-succeeds once the gate drops ---------
# Non-vacuous: the hook counts the failed gate attempts, so a pass proves the
# release actually waited (retry path) rather than took a free gate or aged out.
if have_fn _fleet_release_admit; then
  mk_admit "$admit" "$(date +%s)" "$$"
  mk_gate "$admit.reclaim" "$(date +%s)" "$A_PID"
  ( sleep 0.3; rm -rf "$admit.reclaim" ) & _bg=$!
  HOOK_FIRED=0; HOOK_MODE=count-retry
  FLEET_ADMIT_RELEASE_ITERS=100 _fleet_release_admit "$admit" 2>"$W/rel.err"; b_rc=$?
  HOOK_MODE=""; wait "$_bg" 2>/dev/null
  check "(b) release under a busy gate returns 0 after the gate drops" 0 "$b_rc"
  check "(b) the release removed its own admit" "gone" "$([ -e "$admit" ] && echo present || echo gone)"
  if [ "$HOOK_FIRED" -ge 1 ]; then PASS=$((PASS+1)); echo "ok - (b) the gate was genuinely busy first ($HOOK_FIRED retries observed) — not a vacuous pass"
  else FAIL=$((FAIL+1)); echo "FAIL - (b) the release never retried: the gate was not busy, so this case proved nothing"; fi
  if grep -q 'age out' "$W/rel.err"; then FAIL=$((FAIL+1)); echo "FAIL - (b) took the age-out fallback instead of waiting for the gate"
  else PASS=$((PASS+1)); echo "ok - (b) no age-out fallback taken"; fi
  check "(b) the release dropped the gate it took" "gone" "$([ -e "$admit.reclaim" ] && echo present || echo gone)"

  # (b2) a gate that never drops: bounded wait, admit left to age out, logged.
  mk_admit "$admit" "$(date +%s)" "$$"
  mk_gate "$admit.reclaim" "$(date +%s)" "$A_PID"
  FLEET_ADMIT_RELEASE_ITERS=3 _fleet_release_admit "$admit" 2>"$W/rel2.err"; b2_rc=$?
  check "(b2) a permanently busy gate -> release gives up with rc 1" 1 "$b2_rc"
  check "(b2) ...leaving the admit in place to age out" present "$([ -e "$admit" ] && echo present || echo gone)"
  if grep -q 'age out' "$W/rel2.err"; then PASS=$((PASS+1)); echo "ok - (b2) the age-out fallback is logged to stderr"
  else FAIL=$((FAIL+1)); echo "FAIL - (b2) the age-out fallback was silent"; fi
else
  FAIL=$((FAIL+8)); echo "FAIL - (b) _fleet_release_admit does not exist (no gated release)"
fi

# --- (c) two racing breakers of an ORPHAN gate -> one winner -------------------
# The orphan is a gate left by a reclaimer that died mid-reclaim (old stamp).
# B1 and B2 both observed it stale; B1 breaks it and holds a FRESH gate while B2
# is between its age check and its rename. B2's rename then displaces B1's live
# gate — it must notice (stamp mismatch), put it back, and lose.
if have_fn _fleet_gate_take; then
  gate="$W/.gate-c"
  mk_gate "$gate" "$((NOW - 10))" 999999
  HOOK_FIRED=0; B1_RC=""; HOOK_MODE=break-race
  _fleet_gate_take "$gate"; b2_rc=$?
  HOOK_MODE=""
  check "(c) the seam fired (B1 broke the orphan while B2 was mid-break)" 1 "$HOOK_FIRED"
  check "(c) B1 won the orphan gate" 0 "$B1_RC"
  check "(c) B2 lost (one winner, not two)" 1 "$b2_rc"
  check "(c) B1's gate is still in place and fresh after B2's failed break" "held" \
    "$([ -d "$gate" ] && [ "$(cat "$gate/acquired" 2>/dev/null)" -ge "$NOW" ] && echo held || echo lost)"
  check "(c) no .broken. victim left behind" 0 "$(count_glob "$W"/.gate-c.broken.*)"
else
  FAIL=$((FAIL+5)); echo "FAIL - (c) _fleet_gate_take does not exist (no gate)"
fi

# --- (d) gate liveness rules --------------------------------------------------
if have_fn _fleet_gate_take; then
  # (d1) a YOUNG gate (held for ms in real life) is respected: reclaim refuses
  # and leaves the stale admit and the gate exactly as found.
  mk_admit "$admit" "$((NOW - 61))" 999999
  mk_gate "$admit.reclaim" "$(date +%s)" "$$"
  _fleet_steal_stale_admit "$admit" "$((NOW - 61))"; d1_rc=$?
  check "(d1) young gate held -> reclaim returns 1" 1 "$d1_rc"
  check "(d1) ...admit untouched" "$((NOW - 61))" "$(cat "$admit/acquired" 2>/dev/null)"
  check "(d1) ...gate untouched" held "$([ -d "$admit.reclaim" ] && echo held || echo lost)"
  # (d2) an AGED gate is breakable even when its recorded pid is alive: a
  # reused pid must not wedge every reclaim and every release forever.
  mk_admit "$admit" "$((NOW - 61))" 999999
  mk_gate "$admit.reclaim" "$((NOW - 10))" "$$"
  _fleet_steal_stale_admit "$admit" "$((NOW - 61))"; d2_rc=$?
  check "(d2) aged gate with a LIVE recorded pid is broken -> reclaim succeeds" 0 "$d2_rc"
  check "(d2) ...gate dropped afterwards" gone "$([ -e "$admit.reclaim" ] && echo present || echo gone)"
  # (d3) an unreadable gate stamp is stamped in place and treated as busy once,
  # so a crash between the gate's mkdir and its stamp write ages out too.
  mk_admit "$admit" "$((NOW - 61))" 999999
  rm -rf "$admit.reclaim"; mkdir "$admit.reclaim"
  _fleet_steal_stale_admit "$admit" "$((NOW - 61))"; d3_rc=$?
  check "(d3) unstamped gate -> busy this once (rc 1)" 1 "$d3_rc"
  check "(d3) ...and it is stamped so it can age out" numeric "$(case "$(cat "$admit.reclaim/acquired" 2>/dev/null)" in ''|*[!0-9]*) echo bad ;; *) echo numeric ;; esac)"
else
  FAIL=$((FAIL+8)); echo "FAIL - (d) _fleet_gate_take does not exist (no gate)"
fi

# --- (e) a release only deletes a lock it still owns --------------------------
if have_fn _fleet_release_admit; then
  mk_admit "$admit" "$(date +%s)" "$A_PID"
  _fleet_release_admit "$admit" 2>/dev/null; e1_rc=$?
  check "(e1) release of a FOREIGN owner's admit is a no-op (rc 0)" 0 "$e1_rc"
  check "(e1) ...the foreign admit is still there" present "$([ -e "$admit" ] && echo present || echo gone)"
  check "(e1) ...and still names its owner" "$A_PID" "$(cat "$admit/pid" 2>/dev/null)"
  mk_admit "$admit" "$(date +%s)" "$$"
  _fleet_release_admit "$admit" 2>/dev/null; e2_rc=$?
  check "(e2) release of our OWN admit succeeds" 0 "$e2_rc"
  check "(e2) ...and removes it" gone "$([ -e "$admit" ] && echo present || echo gone)"
  check "(e2) ...and drops the gate" gone "$([ -e "$admit.reclaim" ] && echo present || echo gone)"
else
  FAIL=$((FAIL+6)); echo "FAIL - (e) _fleet_release_admit does not exist"
fi

# --- (f) a claim whose pid write fails fails CLOSED ---------------------------
# Once every release is pid-verified, a pid-less claim could never be released
# by its owner and would wedge admission until it aged out.
rm -rf "$admit" "$admit.reclaim"
PRINTF_FAIL=1; _fleet_claim_admit "$admit"; f_rc=$?; PRINTF_FAIL=0
check "(f) fresh claim with a failing pid write -> rc 1 (fails closed)" 1 "$f_rc"
check "(f) ...and no pid-less admit is left behind" gone "$([ -e "$admit" ] && echo present || echo gone)"
rm -rf "$admit" "$admit.reclaim"
_fleet_claim_admit "$admit"; f2_rc=$?
check "(f) control: the same claim without the injected failure -> rc 0" 0 "$f2_rc"
check "(f) control: ...and records this pid" "$$" "$(cat "$admit/pid" 2>/dev/null)"
# (f2) the steal path's own pid write, after the gate is taken
if have_fn _fleet_gate_take; then
  mk_admit "$admit" "$((NOW - 61))" 999999
  HOOK_FIRED=0; HOOK_MODE=pid-write-fails
  _fleet_steal_stale_admit "$admit" "$((NOW - 61))"; f3_rc=$?
  HOOK_MODE=""; PRINTF_FAIL=0
  check "(f2) reclaim whose pid write fails -> rc 1 (fails closed)" 1 "$f3_rc"
  check "(f2) ...no pid-less admit left behind" gone "$([ -e "$admit" ] && echo present || echo gone)"
  check "(f2) ...gate dropped" gone "$([ -e "$admit.reclaim" ] && echo present || echo gone)"
else
  FAIL=$((FAIL+3)); echo "FAIL - (f2) no gate to exercise"
fi

# --- (g) verify->rename window: a holder release + a fresh claim inside it ----
# The presumed-dead holder releases and D claims while C sits between its
# stamp verification and its rename. Both must be turned away by the gate and
# C must still complete its reclaim.
if have_fn _fleet_release_admit; then
  mk_admit "$admit" "$((NOW - 61))" "$$"
  HOOK_FIRED=0; REL_RC=""; D_RC=""; HOOK_MODE=release-and-claim
  _fleet_steal_stale_admit "$admit" "$((NOW - 61))"; g_rc=$?
  HOOK_MODE=""
  check "(g) the seam fired inside the verify->rename window" 1 "$HOOK_FIRED"
  check "(g) the holder's release was turned away by the gate (rc 1)" 1 "$REL_RC"
  check "(g) D's claim was refused (admit still occupied)" 1 "$D_RC"
  check "(g) C completed its reclaim (rc 0)" 0 "$g_rc"
  check "(g) ...with a FRESH stamp" fresh "$([ "$(cat "$admit/acquired" 2>/dev/null)" -ge "$NOW" ] && echo fresh || echo stale)"
else
  FAIL=$((FAIL+5)); echo "FAIL - (g) no gated release"
fi

# --- (h) defence in depth: the post-rename verify + restore is kept -----------
# arm-resume.sh resolves the preflight relative to ITSELF, so an arm launched
# from a worktree runs an older, UNGATED copy against the same slot dir. If
# such an actor swaps a fresh claim in after C's verification, C's rename
# displaces it: C must notice the stamp mismatch and restore it (same stamp,
# same pid), returning 1.
if have_fn _fleet_gate_take; then
  mk_admit "$admit" "$((NOW - 61))" 999999
  HOOK_FIRED=0; HOOK_MODE=swap-fresh
  _fleet_steal_stale_admit "$admit" "$((NOW - 61))"; h_rc=$?
  HOOK_MODE=""
  check "(h) seam fired (an ungated actor swapped in a fresh claim)" 1 "$HOOK_FIRED"
  check "(h) C returns 1 (it displaced a live claim, it does not own the lock)" 1 "$h_rc"
  check "(h) the displaced claim is restored with its pid" "$A_PID" "$(cat "$admit/pid" 2>/dev/null)"
  check "(h) ...and its (fresh) stamp" fresh "$([ "$(cat "$admit/acquired" 2>/dev/null)" -ge "$NOW" ] && echo fresh || echo stale)"
else
  FAIL=$((FAIL+4)); echo "FAIL - (h) no gate to exercise"
fi

# --- (i) the gate and its debris are invisible to the reservation census ------
# The gate is dot-prefixed on purpose: the prune/census pass globs
# "$SLOTS"/*/ with no dotglob, and that is the only thing keeping a gate (or a
# `.admit.stale.*` / `.admit.reclaim.broken.*` victim) from being counted as a
# fleet reservation. End-to-end through the real script.
slots_i="$W/slots-i"; mkdir -p "$slots_i/.admit.reclaim" "$slots_i/.admit.stale.1.2" "$slots_i/.admit.reclaim.broken.1.2"
printf '%s\n' "$NOW" > "$slots_i/.admit.reclaim/acquired"
mkdir -p "$W/ps/proc"; printf '%s\n' '#!/usr/bin/env bash' 'true' > "$W/ps/ps"; chmod +x "$W/ps/ps"
printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s,"account":"%s"}' "$NOW" "$ACCT" > "$W/c.json"
env -u FLEET_ADMIT_TEST_HOOK FLEET_ADMIT_GATE_STALE_SECS=0 FLEET_CAP_OK= CADENCE_BANK_LAUNCH= HIMMEL_FLEET_SLOTS="$slots_i" FLEET_PS_CMD="$W/ps/ps" FLEET_PROC="$W/ps/proc" \
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" HIMMEL_FLEET_CAP=4 \
  bash "$SUT" </dev/null >"$W/i.out" 2>"$W/i.err"
if grep -q 'reserved=0 total=0/4' "$W/i.err"; then PASS=$((PASS+1)); echo "ok - (i) dot-prefixed gate/victim dirs are not counted as reservations"
else FAIL=$((FAIL+1)); echo "FAIL - (i) a dot-prefixed lock dir was counted as a fleet reservation"; grep 'FLEET' "$W/i.err" || true; fi
# The census line alone would also be logged by a run that then dies, and the
# script exits 0 by contract (an exit-status assert is vacuous), so completion
# is asserted through the verdict token on stdout.
check "(i) the run completes to a PROCEED verdict on stdout" PROCEED "$(cat "$W/i.out")"
# Control: a run that logs the census line and then dies passes the census grep
# above but must NOT yield a verdict — proves the PROCEED assert can fail.
printf '%s\n' '#!/usr/bin/env bash' 'echo "bank-preflight: FLEET reserved=0 total=0/4" >&2' 'exit 3' > "$W/dies.sh"
bash "$W/dies.sh" </dev/null >"$W/dies.out" 2>"$W/dies.err"
check "(i) control: census-line-then-die passes the census grep" 1 "$(grep -c 'reserved=0 total=0/4' "$W/dies.err")"
check "(i) control: census-line-then-die yields no PROCEED verdict" "" "$(cat "$W/dies.out")"
# CodeRabbit (PR 909): with the gate younger than the gate-stale age the child's
# final release would retry, log the age-out message and still print PROCEED —
# a green run hiding a failed release. The run must be free of that message.
check "(i) the run logs no admit-lock age-out (its release took the gate)" 0 "$(grep -c 'could not take the admit-lock gate' "$W/i.err")"

# --- (j) the release retry window outlasts the gate-stale age -----------------
# CodeRabbit (PR 909): a release that meets an orphaned gate younger than
# FLEET_ADMIT_GATE_STALE_SECS must keep retrying until the gate is breakable, or
# it gives up and leaves `.admit` refused for the 60s admit-stale window.
# Asserted as a RELATION over the script's own defaults (not a literal), so a
# later change to either knob trips it.
# CodeRabbit (PR 909, round 2): the declaration COUNT is taken before any
# deduplication, and separately from the extracted value — `sort -u` collapses
# identical duplicates and an empty extraction still counts one line, so a
# missing or duplicated default used to pass.
_dflt_vals() { sed -n "s/.*$2:-\\([0-9][0-9.]*\\)}.*/\\1/p" "$1"; }
_dflt_sites() { _dflt_vals "$1" "$2" | grep -c . || true; }
_dflt_distinct() { _dflt_vals "$1" "$2" | sort -u | grep -c . || true; }
# _j_shape <script> — "<sites ITERS SLEEP GATE> / <distinct values ITERS SLEEP GATE>"
_j_shape() {
  echo "$(_dflt_sites "$1" FLEET_ADMIT_RELEASE_ITERS) $(_dflt_sites "$1" FLEET_ADMIT_RETRY_SLEEP) $(_dflt_sites "$1" FLEET_ADMIT_GATE_STALE_SECS) / $(_dflt_distinct "$1" FLEET_ADMIT_RELEASE_ITERS) $(_dflt_distinct "$1" FLEET_ADMIT_RETRY_SLEEP) $(_dflt_distinct "$1" FLEET_ADMIT_GATE_STALE_SECS)"
}
# Declaration sites in the script: ITERS 1 (the release loop), GATE_STALE 1 (the
# gate age check), RETRY_SLEEP 2 (the release loop and the claim loop) — each
# knob one value across its sites.
_j_want="1 2 1 / 1 1 1"
check "(j) each knob is declared at the expected sites, with one value each" "$_j_want" "$(_j_shape "$SUT")"
_j_iters="$(_dflt_vals "$SUT" FLEET_ADMIT_RELEASE_ITERS | sort -u)"; _j_sleep="$(_dflt_vals "$SUT" FLEET_ADMIT_RETRY_SLEEP | sort -u)"; _j_gate="$(_dflt_vals "$SUT" FLEET_ADMIT_GATE_STALE_SECS | sort -u)"
check "(j) default ITERS x SLEEP exceeds the default gate-stale age" exceeds "$(awk -v i="$_j_iters" -v s="$_j_sleep" -v g="$_j_gate" 'BEGIN{print (i*s > g) ? "exceeds" : "short"}')"
# Controls on variant copies of the script: a DUPLICATED and an ABSENT default
# must each change the shape (the old sort -u | wc -l check saw "1 1 1" for both).
cp "$SUT" "$W/j-dup.sh"
# shellcheck disable=SC2016 # a literal declaration line appended to the copy
printf '%s\n' ': "${FLEET_ADMIT_RELEASE_ITERS:-160}"' >> "$W/j-dup.sh"
sed 's/FLEET_ADMIT_GATE_STALE_SECS:-5}/FLEET_ADMIT_GATE_STALE_SECS}/' "$SUT" > "$W/j-absent.sh"
check "(j) control: a duplicated default is caught" "2 2 1 / 1 1 1" "$(_j_shape "$W/j-dup.sh")"
check "(j) control: an absent default is caught" "1 2 0 / 1 1 0" "$(_j_shape "$W/j-absent.sh")"

# --- (k) a failed release leaves the flag set, so the final cleanup retries ---
# CodeRabbit (PR 909): the in-lock-census-failure branch used to clear
# `_fleet_admitted` unconditionally after `_fleet_release_admit`, on the premise
# that the lock was gone. The gated release can now FAIL (gate busy), so the flag
# is cleared only on success; otherwise the final cleanup retries the (pid-
# verified, therefore safe) release. End to end: the pre-lock census passes, the
# in-lock one fails, the first release meets a busy gate and gives up
# (ITERS=2), and the hook frees the gate during the SECOND release's retry.
slots_k="$W/slots-k"; mkdir -p "$slots_k/.admit.reclaim" "$W/k"
# The gate is stamped now and pinned unbreakable (GATE_STALE_SECS=3600 below), so
# the first release meets a genuinely busy gate however long the earlier cases ran.
printf '%s\n' "$(date +%s)" > "$slots_k/.admit.reclaim/acquired"
# shellcheck disable=SC2016 # the stub bodies are literal scripts, expanded when THEY run
printf '%s\n' '#!/usr/bin/env bash' 'c="$(cat "$0.n" 2>/dev/null || echo 0)"; echo $((c+1)) > "$0.n"' \
  '[ "$1" = release-retry ] && [ "$c" -ge 1 ] && rm -rf "$2"' 'exit 0' > "$W/k/hook.sh"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'c="$(cat "$0.n" 2>/dev/null || echo 0)"; echo $((c+1)) > "$0.n"' '[ "$c" -eq 0 ]' > "$W/k/ps.sh"
chmod +x "$W/k/hook.sh" "$W/k/ps.sh"
env FLEET_ADMIT_TEST_HOOK="$W/k/hook.sh" FLEET_ADMIT_RELEASE_ITERS=2 FLEET_ADMIT_RETRY_SLEEP=0.01 FLEET_ADMIT_GATE_STALE_SECS=3600 FLEET_CAP_OK= CADENCE_BANK_LAUNCH= \
  HIMMEL_FLEET_SLOTS="$slots_k" FLEET_PS_CMD="$W/k/ps.sh" FLEET_PROC="$W/ps/proc" CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_LEDGER="$W/ledger.jsonl" HIMMEL_FLEET_CAP=4 bash "$SUT" </dev/null >"$W/k.out" 2>"$W/k.err"
check "(k) the in-lock census failed (precondition)" 1 "$(grep -c 'in-lock fleet census failed' "$W/k.err")"
check "(k) the first release met the busy gate and gave up (precondition)" 1 "$(grep -c 'could not take the admit-lock gate' "$W/k.err")"
check "(k) the final cleanup retried and released the lock" absent "$([ -e "$slots_k/.admit" ] && echo present || echo absent)"

# --- (l) HIMMEL-3210: a gate holder PAUSED past the gate age is fenced -------
# C takes the gate and verifies the stale admit, then "pauses": its gate ages
# out, B breaks it and completes its own steal (B now holds a LIVE admit), and D
# arms a claim for any window C opens. C resumes and renames. Pre-fence, C's
# rename displaces B's live claim, D wins the empty slot, C's restore mkdir
# loses, and B's claim ends as `.admit.stale.*` debris: two holders (B and D),
# B's claim silently gone. Fenced, C's rename fails (its fence left with the
# broken gate) and nothing moves. Deterministic: the pause is simulated by the
# hook backdating the gate stamp — no SIGSTOP, no sleeps.
P_STALE=$((NOW - 61))
mk_admit "$admit" "$P_STALE" 999999
rm -rf "$W"/.admit.stale.* 2>/dev/null
D_WON=0; B1_RC=""; HOOK_FIRED=0; HOOK_MODE=paused-holder
_fleet_steal_stale_admit "$admit" "$P_STALE"; l_rc=$?
HOOK_MODE=""; MV_INJECT=""
check "(l) the seam fired (C paused between its verify and its rename)" 1 "$HOOK_FIRED"
check "(l) precondition: B broke C's aged gate and stole the stale admit" 0 "$B1_RC"
check "(l) the resumed C does not own the lock (rc 1)" 1 "$l_rc"
check "(l) D was refused (C's resumed rename opened no window)" 0 "$D_WON"
check "(l) B's live claim is still THE admit" B "$(cat "$admit/who" 2>/dev/null)"
check "(l) no .stale. victim left behind" 0 "$(count_glob "$W"/.admit.stale.*)"
check "(l) no gate left behind" gone "$([ -e "$admit.reclaim" ] && echo present || echo gone)"

# --- (m) HIMMEL-3210: a taker paused between its gate mkdir and its fence -----
# A's gate is broken while A is paused before creating its fence; B holds a
# fresh, fenced gate. A resumes and would drop its fence into B's gate — the
# sole-fence check must make A lose and leave B's gate (and fence) intact.
gate="$W/.gate-m"
rm -rf "$gate"; B1_RC=""; B_FENCE=""; HOOK_FIRED=0; HOOK_MODE=paused-taker
_fleet_gate_take "$gate"; m_rc=$?
HOOK_MODE=""
check "(m) the seam fired (A paused between its gate mkdir and its fence)" 1 "$HOOK_FIRED"
check "(m) precondition: B broke A's aged gate and holds it" 0 "$B1_RC"
check "(m) A, resumed inside B's gate, does not hold it (rc 1)" 1 "$m_rc"
check "(m) B's fence is the gate's only fence" "1 1" \
  "$([ -n "$B_FENCE" ] && [ -d "$B_FENCE" ] && echo 1 || echo 0) $(count_glob "$gate"/fence.*)"

# --- (o) HIMMEL-3210: a rename that resolved its fence BEFORE the break -------
# Panel codex-1. C holds the gate and its rename has already resolved the fence
# (simulated by pinning the fence as this shell's cwd and renaming into it
# RELATIVELY — renameat against a destination parent resolved in advance). C's
# gate ages out; B breaks it, and in the window between B's `mv "$gate"` and its
# `rm -rf` of the broken copy E takes the freed gate name, steals the stale
# admit and holds a LIVE claim, and C's pre-resolved rename lands. With the
# fence still alive inside B's broken copy it moves E's live claim; with E's
# take sweeping the broken copy before it may hold (HIMMEL-3232), it fails
# ENOENT and E keeps the lock.
# shellcheck disable=SC2317
_inject_e_after_break() { # E acts right after B's gate `mv`, before B's `rm -rf`
  [ "$1" = "$admit.reclaim" ] || return 0
  MV_INJECT=""; HOOK_FIRED=$((HOOK_FIRED + 1))
  _fleet_steal_stale_admit "$admit" "$P_STALE"; E_RC=$?
  builtin printf '%s\n' E > "$admit/who" 2>/dev/null
  command mv "$admit" victim 2>/dev/null; o_rc=$? # C's rename lands, still inside B's window
}
P_STALE=$((NOW - 61)); E_RC=""; o_rc=""
mk_admit "$admit" "$P_STALE" 999999
_fleet_gate_take "$admit.reclaim"; o_take=$?; C_FENCE="${_fleet_gate_fence:-}"
o_pwd="$PWD"; o_cd=1
if builtin cd "$C_FENCE" 2>/dev/null; then o_cd=0; fi
builtin printf '%s\n' "$(( $(date +%s) - 10 ))" > "$admit.reclaim/acquired"
HOOK_FIRED=0; MV_INJECT=_inject_e_after_break
_fleet_gate_take "$admit.reclaim"; B1_RC=$?
MV_INJECT=""
builtin cd "$o_pwd" || exit 1
check "(o) precondition: C held the gate with its fence pinned" "0 0" "$o_take $o_cd"
check "(o) the seam fired (E acted between B's gate mv and its rm)" 1 "$HOOK_FIRED"
check "(o) precondition: E stole the stale admit" 0 "$E_RC"
check "(o) C's pre-resolved rename fails (its fence died before the break)" 1 "$([ -n "$o_rc" ] && [ "$o_rc" -ne 0 ] && echo 1 || echo 0)"
check "(o) E's live claim is still THE admit" E "$(cat "$admit/who" 2>/dev/null)"
[ "$B1_RC" = 0 ] && _fleet_gate_drop "$admit.reclaim" "${_fleet_gate_fence:-}"
rm -rf "$admit.reclaim"

# --- (p) HIMMEL-3210/3232: a late fence created in the broken generation ------
# Panel round-2 codex-1, case (i). A took the gate and paused before its fence
# mkdir, its path already resolved; the gate aged out. B breaks it, and A
# resumes right after B's gate `mv`: its fence lands in B's victim, and its
# sole-fence check (which lists the gate BY NAME) must refuse. B's own take
# then sweeps the victim, so B holds with the only fence.
# shellcheck disable=SC2317
_inject_late_fence() { # A's fence mkdir + sole check, just after B's gate mv
  [ "$1" = "$gate" ] || return 0
  local v
  MV_INJECT=""; HOOK_FIRED=$((HOOK_FIRED + 1))
  for v in "$gate".broken.*; do p_fence="$v/fence.A.1"; done
  mkdir "$p_fence" 2>/dev/null; p_mk=$?
  _fleet_gate_sole "$gate" "$gate/fence.A.1"; p_sole=$?
}
gate="$W/.gate-p"; rm -rf "$gate"; mkdir "$gate"
builtin printf '%s\n' "$(( $(date +%s) - 10 ))" > "$gate/acquired"
p_mk=""; p_sole=""; p_fence=""; HOOK_FIRED=0
MV_INJECT=_inject_late_fence
_fleet_gate_take "$gate"; p_rc=$?; P_FENCE="${_fleet_gate_fence:-}"
MV_INJECT=""
check "(p) the seam fired (A resumed just after B's gate mv)" 1 "$HOOK_FIRED"
check "(p) precondition: A's fence was created in the broken generation" 0 "$p_mk"
check "(p) A's sole-fence check refuses (rc 1)" 1 "$p_sole"
check "(p) B holds a fresh gate, its fence the only one, the victim swept" "0 1 1 0" \
  "$p_rc $([ -n "$P_FENCE" ] && [ -d "$P_FENCE" ] && echo 1 || echo 0) $(count_glob "$gate"/fence.*) $(count_glob "$gate".broken.*)"
[ "$p_rc" = 0 ] && _fleet_gate_drop "$gate" "$P_FENCE"
rm -rf "$gate"

# --- (q) HIMMEL-3210: a late fence created after the doomed gate's mv --------
# Case (ii), first half: A resumes after B's gate `mv` and before B re-creates
# the gate — its fence mkdir finds no parent (ENOENT) and A refuses. The second
# half (A's fence lands in the successor's fenced gate and the sole check sees
# two fences) is (m).
# shellcheck disable=SC2317
_inject_fence_after_mv() {
  [ "$1" = "$gate" ] || return 0
  MV_INJECT=""; HOOK_FIRED=$((HOOK_FIRED + 1))
  mkdir "$gate/fence.A.2" 2>/dev/null; q_mk=$?
}
gate="$W/.gate-q"; rm -rf "$gate"; mkdir "$gate"
builtin printf '%s\n' "$(( $(date +%s) - 10 ))" > "$gate/acquired"
q_mk=""; HOOK_FIRED=0; MV_INJECT=_inject_fence_after_mv
_fleet_gate_take "$gate"; q_rc=$?; Q_FENCE="${_fleet_gate_fence:-}"
MV_INJECT=""
check "(q) the seam fired (A resumed between B's gate mv and its re-mkdir)" 1 "$HOOK_FIRED"
check "(q) A's fence mkdir fails: the gate name is gone" 1 "$([ -n "$q_mk" ] && [ "$q_mk" -ne 0 ] && echo 1 || echo 0)"
check "(q) B holds the fresh gate, its fence the only one" "0 1 1" \
  "$q_rc $([ -n "$Q_FENCE" ] && [ -d "$Q_FENCE" ] && echo 1 || echo 0) $(count_glob "$gate"/fence.*)"
[ "$q_rc" = 0 ] && _fleet_gate_drop "$gate" "$Q_FENCE"

# --- (r) HIMMEL-3210: a stamp failure never removes a successor's gate --------
# A passes its sole-fence check, then pauses past the gate age. B breaks the gate
# (mv, then the victim's rm), so A's stamp fails ENOENT, and a successor takes
# the gate before A's cleanup runs. That cleanup must be fence-verified like
# every other gate removal. A genuine stamp failure, with A's fence still in
# place, must still remove A's own gate.
STAMP_INJECT=""; r_succ_rc=""; R_FENCE=""
# shellcheck disable=SC2317
_fleet_admit_stamp_or_fail() { # overrides the SUT's stamp; (r) only
  local inj="$STAMP_INJECT" rc; STAMP_INJECT=""
  [ "$inj" = fail ] && return 1
  if [ "$inj" = break ]; then
    command mv "$1" "$1.broken.r"; command rm -rf "$1.broken.r"
  fi
  date +%s > "$1/acquired" 2>/dev/null; rc=$?
  if [ "$inj" = break ]; then _fleet_gate_take "$1"; r_succ_rc=$?; R_FENCE="${_fleet_gate_fence:-}"; fi
  return $rc
}
gate="$W/.gate-r"; command rm -rf "$gate"
STAMP_INJECT="break"; _fleet_gate_take "$gate"; r_rc=$?
check "(r) A's take refuses after its stamp fails" 1 "$r_rc"
check "(r) the successor took the gate in the window" 0 "$r_succ_rc"
check "(r) A's cleanup leaves the successor's gate and fence in place" "1 1" \
  "$([ -d "$gate" ] && echo 1 || echo 0) $([ -n "$R_FENCE" ] && [ -d "$R_FENCE" ] && echo 1 || echo 0)"
[ "$r_succ_rc" = 0 ] && _fleet_gate_drop "$gate" "$R_FENCE"
command rm -rf "$gate"
STAMP_INJECT=fail; _fleet_gate_take "$gate"; r_rc=$?
check "(r) a genuine stamp failure refuses and removes A's own gate" "1 0" \
  "$r_rc $([ -e "$gate" ] && echo 1 || echo 0)"
# shellcheck disable=SC1091
. "$W/fns.sh" # restore the SUT's own stamp
rm -rf "$gate"

# --- (s) HIMMEL-3232: one break, two gate generations (double pause) ---------
# Breaker B1 observed G1 stale and pauses at its first break step (pause 1).
# B2 breaks G1 in full and holds G2. Pre-fix, B1 had already written `revoked`
# into G1, so its fence delete and its `mv` now act on the unrevoked G2: a
# taker T fences into G2 after that delete and passes its sole check. B1 moves
# G2 away and pauses again (pause 2). S takes the freed name, steals the stale
# admit and claims fresh, and then the pre-resolved rename of a fence still
# alive in the moved generation (T's pre-fix, B2's post-fix; pinned as this
# shell's cwd) lands. It must not move S's live claim. Pause 1 is the breaker's
# first step: after `mkdir revoked` where the SUT has one, else its age check.
gate="$admit.reclaim"
s_p1=0; s_p2=0; s_pin=1; s_mv=""; S_RC=""; B1_RC=""
# shellcheck disable=SC2317
_inject_s_pause1() { # B2 breaks G1 in full and holds G2
  MK_INJECT=""; HOOK_MODE=""; s_p1=1
  _fleet_gate_take "$gate"; B1_RC=$?
  RM_GATE="$gate"; RM_INJECT=_inject_s_taker; MV_INJECT=_inject_s_pause2
}
# shellcheck disable=SC2317
_inject_s_taker() { # pre-fix only (a fence delete by name): T fences G2 after it
  RM_INJECT=""
  mkdir "$gate/fence.T.1" 2>/dev/null && _fleet_gate_sole "$gate" "$gate/fence.T.1"
}
# shellcheck disable=SC2317
_inject_s_pause2() { # right after B1's gate mv: S steals, then the pinned rename lands
  [ "$1" = "$gate" ] || return 0
  local f pin="" here="$PWD"
  MV_INJECT=""; RM_INJECT=""; s_p2=1
  for f in "$gate".broken.*/fence.*; do [ -d "$f" ] && pin="$f"; done
  [ -n "$pin" ] && builtin cd "$pin" && s_pin=0
  _fleet_steal_stale_admit "$admit" "$P_STALE"; S_RC=$?
  builtin printf '%s\n' S > "$admit/who" 2>/dev/null
  [ "$s_pin" = 0 ] && { command mv "$admit" victim 2>/dev/null; s_mv=$?; }
  builtin cd "$here" || exit 1
}
P_STALE=$((NOW - 61))
mk_admit "$admit" "$P_STALE" 999999
mk_gate "$gate" "$((NOW - 10))" 999999; mkdir "$gate/fence.dead.1"
if grep -q '/revoked"' "$W/fns.sh"; then MK_GATE="$gate"; MK_INJECT=_inject_s_pause1; else HOOK_MODE=gen-pause1; fi
_fleet_gate_take "$gate"; s_rc=$?
HOOK_MODE=""; MK_INJECT=""; MK_GATE=""; RM_INJECT=""; RM_GATE=""; MV_INJECT=""
check "(s) both pauses fired" "1 1" "$s_p1 $s_p2"
check "(s) precondition: B2 broke G1 and held G2" 0 "$B1_RC"
check "(s) precondition: a fence of the moved generation was pinned, S stole" "0 0" "$s_pin $S_RC"
check "(s) the pinned rename fails (its fence died before S could steal)" 1 "$([ -n "$s_mv" ] && [ "$s_mv" -ne 0 ] && echo 1 || echo 0)"
check "(s) S's live claim is still THE admit" S "$(cat "$admit/who" 2>/dev/null)"
check "(s) B1 does not hold" 1 "$s_rc"
command rm -rf "$gate" "$gate".broken.* "$admit"

# --- (t) HIMMEL-3223: a break whose fence kill fails holds nothing ----------
# An orphan gate with a dead holder's fence is broken while every `rm` of its
# fences (in place, or inside its `.broken.` victim) fails. Pre-fix the break
# continued and the breaker held a fresh gate while the old fence survived
# (a live one would carry a pre-resolved rename). Fail-closed: no one holds the
# gate while a fence of the broken generation survives, and it heals once the
# fault clears.
gate="$W/.gate-t"; command rm -rf "$gate" "$gate".broken.*
mk_gate "$gate" "$((NOW - 10))" 999999; mkdir "$gate/fence.dead.1"
RM_FAIL_GATE="$gate"
_fleet_gate_take "$gate"; t_rc=$?
_fleet_gate_take "$gate"; t_rc2=$?
RM_FAIL_GATE=""
check "(t) the break refuses while the old fence survives (rc 1, twice)" "1 1" "$t_rc $t_rc2"
check "(t) the old fence survived (fault injected)" 1 "$(count_glob "$gate"/fence.dead.1 "$gate".broken.*/fence.dead.1)"
_fleet_gate_take "$gate"; t_rc3=$?; T_FENCE="${_fleet_gate_fence:-}"
check "(t) once the fault clears a take holds, no victim left, its fence sole" "0 0 1" \
  "$t_rc3 $(count_glob "$gate".broken.*) $(count_glob "$gate"/fence.*)"
[ "$t_rc3" = 0 ] && _fleet_gate_drop "$gate" "$T_FENCE"
command rm -rf "$gate" "$gate".broken.*

# --- (n) HIMMEL-3210: displaced-victim debris is pruned by age ----------------
# End to end through the real script. Debris first seen long ago goes; debris
# never seen before is stamped and kept (it may still be in flight); debris
# seen recently is kept; a reservation is untouched by the debris pass.
slots_n="$W/slots-n"; rm -rf "$slots_n"
mkdir -p "$slots_n/.admit.stale.1.1" "$slots_n/.admit.reclaim.broken.1.1" "$slots_n/.admit.stale.2.2" \
  "$slots_n/.admit.reclaim.broken.2.2" "$slots_n/.admit.stale.3.3" "$slots_n/HIMMEL-resv"
builtin printf '%s\n' "$((NOW - 7200))" > "$slots_n/.admit.stale.1.1/seen"
builtin printf '%s\n' "$((NOW - 7200))" > "$slots_n/.admit.reclaim.broken.1.1/seen"
builtin printf '%s\n' "$NOW" > "$slots_n/.admit.stale.3.3/seen"
builtin printf '%s\n' "$((NOW + 3600))" > "$slots_n/HIMMEL-resv/expires"
env -u FLEET_ADMIT_TEST_HOOK FLEET_CAP_OK= CADENCE_BANK_LAUNCH= HIMMEL_FLEET_SLOTS="$slots_n" FLEET_PS_CMD="$W/ps/ps" FLEET_PROC="$W/ps/proc" \
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" HIMMEL_FLEET_CAP=4 \
  bash "$SUT" </dev/null >"$W/n.out" 2>"$W/n.err"
check "(n) the run completes to a PROCEED verdict" PROCEED "$(cat "$W/n.out")"
check "(n) long-seen .admit.stale.* debris is pruned" gone "$([ -e "$slots_n/.admit.stale.1.1" ] && echo present || echo gone)"
check "(n) long-seen .admit.reclaim.broken.* debris is pruned" gone "$([ -e "$slots_n/.admit.reclaim.broken.1.1" ] && echo present || echo gone)"
check "(n) never-seen .admit.stale.* debris is kept and stamped" numeric \
  "$(case "$(cat "$slots_n/.admit.stale.2.2/seen" 2>/dev/null)" in ''|*[!0-9]*) echo bad ;; *) echo numeric ;; esac)"
# HIMMEL-3232: every gate holder sweeps `.admit.reclaim.broken.*` before it may
# hold, so the run's own gated release removes even a never-seen one.
check "(n) never-seen .admit.reclaim.broken.* debris is swept by the release's gate take" gone \
  "$([ -e "$slots_n/.admit.reclaim.broken.2.2" ] && echo present || echo gone)"
check "(n) recently-seen debris is kept" present "$([ -e "$slots_n/.admit.stale.3.3" ] && echo present || echo gone)"
check "(n) a live reservation is untouched and counted" "present 1" \
  "$([ -e "$slots_n/HIMMEL-resv" ] && echo present || echo gone) $(grep -c 'reserved=1 total=1/4' "$W/n.err")"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
