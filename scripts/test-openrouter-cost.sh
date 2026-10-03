#!/usr/bin/env bash
# HIMMEL-4076: real read-only helper, hermetic account/key endpoints.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/test-openrouter-cost.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/home"
cat > "$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
input="$(cat)"
case "$*" in *test-secret*) exit 9 ;; esac
case "$input" in *'Bearer test-secret'*) ;; *) exit 9 ;; esac
printf '%s\n' "$*" >> "$CALLS"
case "${@: -1}" in
  */credits) printf '%s' "$CREDITS" ;;
  */key) printf '%s' "$KEY" ;;
  *) exit 9 ;;
esac
STUB
chmod +x "$W/bin/curl"
export PATH="$W/bin:$PATH" HOME="$W/home" OPENROUTER_API_KEY=test-secret
export OPENROUTER_API_BASE=https://fixture.invalid/api CALLS="$W/calls"
export CREDITS='{"data":{"total_credits":20,"total_usage":4}}'
export KEY='{"data":{"limit":10,"limit_remaining":7.5}}'
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1: want=$2 got=$3"; fi; }
run() { bash "$HERE/lanes/openrouter-cost.sh" "$@" 2>"$W/err"; }
# A missing min(balance, key remaining) calculation misreports available spend.
check 'capped key is effective minimum' 'balance=7.50:key-limit_remaining spend=?' "$(run)"
export KEY='{"data":{"limit":100,"limit_remaining":50}}'
check 'credits are effective minimum' 'balance=16.00:credit spend=?' "$(run)"
export KEY='{"data":{"limit":null}}'
# shellcheck disable=SC2016  # literal launcher dollar amount, not a variable
printf '%s\n' 'claude-openrouter: remaining metered credit: $19.50 (OpenRouter balance).' > "$W/launch.log"
check 'uncapped key and launch account delta' 'balance=16.00:credit spend=3.50' "$(run --since "$W/launch.log")"
check 'missing launch never invents spend' 'balance=16.00:credit spend=?' "$(run --since "$W/missing")"
export KEY='{"data":{"limit":10,"limit_remaining":0}}'
check 'exhausted key surfaced without launch' 'balance=0.00:key-limit_remaining spend=?' "$(run)"
export KEY='{"data":{"limit":10,"limit_remaining":null}}'
check 'unknown cap does not advertise credits' 'balance=? spend=?' "$(run)"
export KEY='{"data":{"limit":null}}' CREDITS='{"data":{"total_credits":null,"total_usage":0}}'
check 'null credit is unknown' 'balance=? spend=?' "$(run)"
export CREDITS='not-json'
check 'malformed credit is unknown' 'balance=? spend=?' "$(run)"
check 'no runtime config seeded' absent "$(if [ -e "$HOME/.claude-openrouter" ]; then echo present; else echo absent; fi)"
if grep -qvE -- '^.*https://fixture.invalid/api/(credits|key)$' "$CALLS"; then FAIL=$((FAIL+1)); echo 'FAIL - inference or unexpected endpoint called'; else PASS=$((PASS+1)); echo 'ok - account endpoints only'; fi
if grep -q test-secret "$W/err" "$CALLS"; then FAIL=$((FAIL+1)); echo 'FAIL - key exposed'; else PASS=$((PASS+1)); echo 'ok - key absent from output and argv'; fi
export CREDITS='{"data":{"total_credits":10,"total_usage":0}}' KEY='{"data":{"limit":10,"limit_remaining":2.999}}'
check 'raw mode preserves sub-floor key balance' 'balance=2.999:key-limit_remaining spend=?' "$(run --raw)"
check 'display mode remains byte-identical and rounded' 'balance=3.00:key-limit_remaining spend=?' "$(run)"
export CREDITS='{"data":{"total_credits":2.999,"total_usage":0}}' KEY='{"data":{"limit":null}}'
check 'raw mode preserves sub-floor credit balance' 'balance=2.999:credit spend=?' "$(run --raw)"
help_text="$(run --help)"
check '--help documents --raw' yes "$(case "$help_text" in *--raw*) echo yes ;; *) echo no ;; esac)"
echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
