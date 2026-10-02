#!/usr/bin/env bash
# HIMMEL-4076: read-only account balance and account-wide spend since a launch.
# No inference, configuration seed or subscription probe. --since reads the
# launcher's credit line, not its key-cap line (a cap may reset independently).
# PLATFORM GUARD: Bash helper for the Linux console tick; no PowerShell twin.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
since=""
case "${1:-}" in
  '') ;;
  --since) [ "$#" -eq 2 ] || exit 2; since="$2" ;;
  --help) echo 'usage: openrouter-cost.sh [--since launch.log] (spend is account-wide)'; echo 'Credits metadata can lag: an immediate --since delta can under-report spend; re-read later.'; exit 0 ;;
  *) exit 2 ;;
esac
unknown() { echo 'balance=? spend=?'; exit 0; }
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -r "$HERE/../lib/load-dotenv.sh" ]; then
  # shellcheck source=../lib/load-dotenv.sh
  . "$HERE/../lib/load-dotenv.sh"
  load_dotenv --root "$(_load_dotenv_primary_for "$HERE/../..")" OPENROUTER_API_KEY
fi
[ -n "${OPENROUTER_API_KEY:-}" ] || unknown
# curl config receives the header on stdin, never in process argv. Refuse
# config metacharacters rather than letting a malformed key inject options.
case "$OPENROUTER_API_KEY" in *[[:cntrl:]]*|*\"*|*\\*) unknown ;; esac
command -v curl >/dev/null 2>&1 || unknown
command -v jq >/dev/null 2>&1 || unknown
base="${OPENROUTER_API_BASE:-https://openrouter.ai/api/v1}"
probe() {
  printf 'header "Authorization: Bearer %s"\n' "$OPENROUTER_API_KEY" |
    curl -fsS -m 5 --noproxy '*' -K - "$base/$1" 2>/dev/null
}
credit_raw="$(probe credits)" || unknown
credit="$(printf '%s' "$credit_raw" | jq -er '
  .data // . | select((.total_credits | type) == "number" and (.total_usage | type) == "number")
  | .total_credits - .total_usage' 2>/dev/null)" || unknown
key_raw="$(probe key)" || unknown
key="$(printf '%s' "$key_raw" | jq -er '
  .data // . | if has("limit") and .limit == null then "none"
  elif (.limit | type) == "number" and (.limit_remaining | type) == "number" then .limit_remaining
  else empty end' 2>/dev/null)" || unknown
balance="$credit"; source=credit
if [ "$key" != none ] && awk -v k="$key" -v c="$credit" 'BEGIN{exit !(k<c)}'; then
  balance="$key"; source='key-limit_remaining'
fi
balance="$(awk -v n="$balance" 'BEGIN{printf "%.2f",n}')"
spend='?'
if [ -n "$since" ] && [ -r "$since" ]; then
  start="$(sed -n 's/^.*claude-openrouter: remaining metered credit: \$\([0-9][0-9.]*\) .*/\1/p' "$since" | head -n 1)"
  case "$start" in ''|*[!0-9.]*|*.*.*) : ;;
    *) spend="$(awk -v s="$start" -v c="$credit" 'BEGIN{if(s>=c) printf "%.2f",s-c; else printf "?"}')" ;;
  esac
fi
printf 'balance=%s:%s spend=%s\n' "$balance" "$source" "$spend"
