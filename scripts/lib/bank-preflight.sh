#!/usr/bin/env bash
# bank-preflight.sh — HIMMEL-1841. Pre-run bank guard for scheduled legs.
#
# Prints ONE verdict token to stdout; diagnostics to stderr; a row to the
# ledger; ALWAYS exits 0. Callers branch on the TOKEN, never the exit code
# — a non-zero exit is indistinguishable from a crash to the schtasks/cron
# wrapper, and the two fail-open verdicts must not look like failures.
#
# extra_usage is NOT thresholded: it is paid overflow that engages when a
# primary is exhausted, so high extra_usage with low primaries means the
# bank is HEALTHY. Diagnostics only.
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
