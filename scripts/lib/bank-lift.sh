#!/usr/bin/env bash
# bank-lift.sh — HIMMEL-4423. An expiring, account-bound OPERATOR decision to
# spend the seven_day bank past the launch ceiling before it resets anyway.
#
#   bank-lift.sh set [cache]   record a lift until the cache's seven_day.resets_at
#   bank-lift.sh show          print the lift file and whether it is valid now
#   bank-lift.sh clear         remove it
#
# Sourced by bank-preflight.sh for `bank_lift_valid <cache>` (rc 0 = valid).
# Operator-set only — nothing calls `set` automatically. The lift voids itself
# when `until` has passed or outlives the cache's seven_day.resets_at, the file
# is not owner-only, or the current account differs from the one that set it; a missing or malformed file is simply "no lift" (fails toward the ceiling).
# The five_hour ceiling, fleet cap and SKIPPED-* tokens are not touched here.
#
# State file: ${BANK_LIFT_FILE:-$HOME/.himmel/state/bank-lift.json}
#   {"window":"seven_day","until":<epoch>,"account":"<hash>","set_by":..,"set_at":..}

_BL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-cache-identity.sh
# shellcheck disable=SC1091
. "$_BL_DIR/usage-cache-identity.sh"

bank_lift_file() { printf '%s' "${BANK_LIFT_FILE:-${HOME:-/tmp}/.himmel/state/bank-lift.json}"; }

# Epoch seconds from a resets_at that is an epoch already or an ISO-8601 string.
_bank_lift_epoch() {
  local v="$1" t
  case "$v" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$v"; return 0 ;;
  esac
  [ -n "$v" ] || return 1
  # Only a full ISO-8601 stamp WITH an explicit zone is accepted (the lift-file
  # writer emits Python isoformat, +00:00). An offset-less stamp is local time to
  # `date -d` but UTC to the BSD path, so both reject it: fail toward the ceiling.
  [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$ ]] || return 1
  t=$(date -d "$v" +%s 2>/dev/null) && [ -n "$t" ] && { printf '%s' "$t"; return 0; }  # gnu-ok: BSD date -j fallback follows
  # BSD date: drop fractional seconds, normalise a zero offset (+00:00, +0000,
  # +00, minus forms) / Z to a bare UTC stamp. Any other offset survives the sed
  # and is refused (BSD date would drop it and read local time as UTC).
  v=$(printf '%s' "$v" | sed -e 's/\.[0-9]*//' -e 's/[+-]00\(:\{0,1\}00\)\{0,1\}$//' -e 's/Z$//' -e 's/ /T/')
  [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  t=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$v" +%s 2>/dev/null) && [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  return 1
}

_bank_lift_default_cache() { printf '%s' "${CADENCE_BANK_CACHE:-${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}}"; }

# _bank_lift_trusted <file>: owned by the current uid and not group/world-writable.
_bank_lift_trusted() {
  local f="$1" owner mode me
  owner=$(stat -c '%u' "$f" 2>/dev/null || stat -f '%u' "$f" 2>/dev/null) || return 1  # gnu-ok: BSD stat -f fallback
  mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null) || return 1  # gnu-ok: BSD stat -f fallback
  me=$(id -u) || return 1
  case "$owner$mode" in ''|*[!0-9]*) return 1 ;; esac
  [ "$owner" = "$me" ] || return 1
  [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 1
}

# bank_lift_valid [cache]: 0 only when the file is owner/mode-trusted,
# well-formed, unexpired, bound to the current account (which must also be the
# cache's account), and its `until` does not outlive the cache's current
# seven_day.resets_at. An unreadable cache or unparseable resets_at is no lift.
bank_lift_valid() {
  local cache="${1:-}" f win until acct cur now cached fields resets rs_epoch
  [ -n "$cache" ] || cache="$(_bank_lift_default_cache)"
  f="$(bank_lift_file)"
  [ -f "$f" ] && command -v jq >/dev/null 2>&1 || return 1
  _bank_lift_trusted "$f" || return 1
  # A parse error anywhere in the file (even after a valid object) is no lift.
  fields=$(jq -r '
    (if (.window|type)=="string" then .window else "" end),
    (if (.until|type)=="number" and (.until|floor)==.until then (.until|tostring) else "" end),
    (if (.account|type)=="string" then .account else "" end)
    ' "$f" 2>/dev/null) || return 1
  {
    IFS= read -r win
    IFS= read -r until
    IFS= read -r acct
  } <<<"$fields"
  win=${win%$'\r'}; until=${until%$'\r'}; acct=${acct%$'\r'}
  [ "$win" = "seven_day" ] || return 1
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$acct" ] || return 1
  now=$(date +%s)
  [ "$until" -gt "$now" ] || return 1
  cur=$(current_account_hash)
  [ -n "$cur" ] && [ "$acct" = "$cur" ] || return 1
  [ -f "$cache" ] || return 1
  cached=$(jq -r 'if (.account|type)=="string" then .account else "" end' "$cache" 2>/dev/null)
  [ "$cached" = "$cur" ] || return 1
  resets=$(jq -r '.seven_day.resets_at // empty' "$cache" 2>/dev/null)
  rs_epoch=$(_bank_lift_epoch "$resets") || return 1
  [ "$until" -le "$rs_epoch" ] || return 1
  return 0
}

_bank_lift_cmd() {
  local cmd="${1:-}" f cache resets until acct tmp
  f="$(bank_lift_file)"
  case "$cmd" in
    set)
      cache="${2:-$(_bank_lift_default_cache)}"
      command -v jq >/dev/null 2>&1 || { echo "bank-lift: jq missing" >&2; return 1; }
      [ -f "$cache" ] || { echo "bank-lift: no usage cache at $cache" >&2; return 1; }
      acct=$(current_account_hash)
      [ -n "$acct" ] || { echo "bank-lift: current account undeterminable" >&2; return 1; }
      usage_cache_account_mismatch "$cache" && { echo "bank-lift: usage cache is not this account's" >&2; return 1; }
      resets=$(jq -r '.seven_day.resets_at // empty' "$cache" 2>/dev/null)
      until=$(_bank_lift_epoch "$resets") || { echo "bank-lift: no usable seven_day.resets_at ('$resets')" >&2; return 1; }
      [ "$until" -gt "$(date +%s)" ] || { echo "bank-lift: seven_day window already reset" >&2; return 1; }
      mkdir -p "$(dirname "$f")" || return 1
      tmp=$(mktemp "$f.tmp.XXXXXX") || return 1
      if ! ( umask 077; jq -n --argjson u "$until" --arg a "$acct" --arg by "${USER:-unknown}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{window:"seven_day",until:$u,account:$a,set_by:$by,set_at:$at}' > "$tmp" ); then rm -f "$tmp"; return 1; fi
      if ! mv "$tmp" "$f"; then rm -f "$tmp"; return 1; fi
      echo "bank-lift: set until $until ($resets)"
      ;;
    show)
      if [ -f "$f" ]; then cat "$f"; else echo "bank-lift: none"; fi
      if bank_lift_valid "${2:-}"; then echo "bank-lift: VALID"; else echo "bank-lift: not valid"; fi
      ;;
    clear)
      rm -f "$f" && echo "bank-lift: cleared"
      ;;
    *)
      echo "usage: bank-lift.sh set [cache] | show [cache] | clear" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _bank_lift_cmd "$@"
  exit $?
fi
