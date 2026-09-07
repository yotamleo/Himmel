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
if [ -n "${FLEET_PS_CMD:-}" ]; then
  _fleet_ps_cmd="$FLEET_PS_CMD"
  _fleet_ps_raw="$("$FLEET_PS_CMD" 2>&1)"
else
  _fleet_ps_cmd="ps -eo pid=,args="
  _fleet_ps_raw="$(ps -eo pid=,args= 2>&1)"
fi
_fleet_ps_rc=$?
if [ "$_fleet_ps_rc" -ne 0 ]; then
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

fleet_n=0
fleet_native=0
fleet_claudex=0
_fleet_procfs_warned=0
# Plain (non-IFS=) `read` here is deliberate: a real `ps -eo pid=,args=`
# right-justifies the PID column with LEADING spaces for every row
# narrower than the widest pid in the table, and default `read` field
# splitting trims that leading whitespace before assigning $_fleet_pid —
# an explicit `IFS= read -r` whole-line capture followed by `${line%% *}`
# does NOT, and silently produces an EMPTY pid (failing is_int, and so
# silently dropping the row) for every line except the one with the
# widest pid in the table.
while read -r _fleet_pid _fleet_rest; do
  is_int "$_fleet_pid" || continue
  _fleet_comm="$(cat "${FLEET_PROC:-/proc}/$_fleet_pid/comm" 2>/dev/null)"
  if [ -n "$_fleet_comm" ]; then
    [ "$_fleet_comm" = claude ] || continue
  elif [ "$_fleet_procfs_warned" -eq 0 ]; then
    echo "bank-preflight: comm unreadable for at least one fleet candidate (pid $_fleet_pid) — falling back to argv-only matching for it (less precise: may double-count a launcher/child pair)" >&2
    _fleet_procfs_warned=1
  fi
  fleet_n=$((fleet_n + 1))
  if [ "$(_fleet_lane_of "$_fleet_pid")" = claudex ]; then
    fleet_claudex=$((fleet_claudex + 1))
  else
    fleet_native=$((fleet_native + 1))
  fi
done <<FLEET_CANDIDATES
$(printf '%s\n' "$_fleet_ps_raw" \
  | grep -E -- '-n[[:space:]]+(HIMMEL|LUNA)-' \
  | grep -vE -- '-n[[:space:]]+(HIMMEL|LUNA)-[^[:space:]]*-console')
FLEET_CANDIDATES

echo "bank-preflight: FLEET native=$fleet_native claudex=$fleet_claudex total=$fleet_n/$FLEET_CAP" >&2

if [ "$fleet_n" -ge "$FLEET_CAP" ]; then
  # codex-3 (CR review, 2nd panel round, Suggestion): the documented
  # contract is FLEET_CAP_OK=1 specifically; a bare `-n` (non-empty) test
  # would also treat FLEET_CAP_OK=0 or FLEET_CAP_OK=false as an enabled
  # bypass. Compare exactly.
  if [ "${FLEET_CAP_OK:-}" = "1" ]; then
    echo "bank-preflight: fleet at/over cap ($fleet_n/$FLEET_CAP) — FLEET_CAP_OK bypass in effect (launching shell only), proceeding" >&2
  elif [ "$LAUNCH_INTENT" = "1" ]; then
    echo "bank-preflight: fleet at/over cap ($fleet_n/$FLEET_CAP) — skipping leg=$LEG (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >&2
    emit SKIPPED-FLEET
  else
    echo "bank-preflight: fleet at/over cap ($fleet_n/$FLEET_CAP) — not a declared launch (CADENCE_BANK_LAUNCH unset), reporting only" >&2
  fi
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
