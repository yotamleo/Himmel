#!/usr/bin/env bash
# scripts/ci/test-ci-main-cron.sh -- regression suite for HIMMEL-5113: main CI
# runs on a cron (plus workflow_dispatch) instead of on every merge push.
#
# Asserts, over .github/workflows/ci.yml (comment-stripped):
#   - no `push:` trigger (main push runs were ~52/day, half cancelled);
#   - two schedule crons: the nightly `17 7 * * *` and a main-sweep cron whose
#     hours leave no gap above 7 h;
#   - the cadence is documented next to the cron;
#   - nightly-only behaviour (windows legs, tier=all, extended-tier issue,
#     guard-corpus-full) is keyed on the nightly cron's github.event.schedule,
#     never on a bare event_name == 'schedule' that the main cron would also hit;
#   - the selector-miss ledger no longer keys on `push`;
#   - the cron run prints the merge range since the previous main run.
#
# Usage: bash scripts/ci/test-ci-main-cron.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

stripped="$(sed 's/^[[:space:]]*#.*$//; s/[[:space:]][[:space:]]*#.*$//' "$CI_YML")"

# The workflow-level `on:` block: column-0 `on:` up to the next column-0 key.
on_block="$(awk '/^on:/ {f=1; next} f && /^[^ ]/ {f=0} f' <<< "$stripped")"

if grep -q '^  push:' <<< "$on_block"; then bad "ci.yml still has a push: trigger"
else ok "ci.yml has no push: trigger"; fi
if grep -q '^  pull_request:' <<< "$on_block"; then ok "pull_request trigger kept"
else bad "pull_request trigger is gone"; fi
if grep -q '^  workflow_dispatch:' <<< "$on_block"; then ok "workflow_dispatch trigger kept"
else bad "workflow_dispatch trigger is gone"; fi

crons="$(sed -n "s/^[[:space:]]*- cron:[[:space:]]*'\\(.*\\)'.*/\\1/p" <<< "$on_block")"
if grep -qx '17 7 \* \* \*' <<< "$crons"; then ok "nightly cron 17 7 * * * kept"
else bad "nightly cron 17 7 * * * missing; crons: $crons"; fi

main_cron="$(grep -v '^17 7 \* \* \*$' <<< "$crons" | head -n 1)"
if [ -z "$main_cron" ]; then
  bad "no main-sweep cron besides the nightly"
else
  ok "main-sweep cron: $main_cron"
  hours="$(awk '{print $2}' <<< "$main_cron")"
  # Exactly two crons, and the main one fires daily at a fixed minute: a weekly
  # or monthly entry with the same hours field would pass the gap check below.
  ncrons="$(grep -c . <<< "$crons")"
  if [ "$ncrons" -eq 2 ]; then ok "exactly two schedule crons"
  else bad "expected exactly two schedule crons, got $ncrons: $crons"; fi
  if grep -Eqx '([0-9]|[1-5][0-9]) [^ ]+ \* \* \*' <<< "$main_cron"; then
    ok "main-sweep cron fires daily at a single fixed minute"
  else bad "main-sweep cron is not daily at one numeric minute (0-59, day/month/weekday * * *): '$main_cron'"; fi
  case "$hours" in
    *[!0-9,]*|''|,*|*,|*,,*) bad "main-sweep cron hours field is not a plain comma list: '$hours'" ;;
    *[0-9][0-9][0-9]*|*2[4-9]*|*[3-9][0-9]*) bad "main-sweep cron hours field has an hour above 23: '$hours'" ;;
    *)
      maxgap="$(printf '%s\n' "$hours" | tr ',' '\n' | sort -n | awk '
        { h[NR] = $1 }
        END { m = 0
              for (i = 1; i <= NR; i++) {
                n = (i == NR) ? h[1] + 24 : h[i + 1]
                if (n - h[i] > m) m = n - h[i]
              }
              print m }')"
      if [ "$maxgap" -le 7 ]; then ok "main-sweep cron max gap is ${maxgap}h (<= 7h)"
      else bad "main-sweep cron max gap is ${maxgap}h (> 7h)"; fi ;;
  esac
fi

# The real cadence is documented in a comment beside the cron.
if grep -q -i '7 h' "$CI_YML" && grep -q -i 'cadence' "$CI_YML"; then ok "cadence is documented"
else bad "cadence (7 h) is not documented in ci.yml"; fi

# Nightly-only behaviour must key on the nightly cron, not the event name.
bare="$(grep -c "github.event_name == 'schedule'" <<< "$stripped")"
if [ "$bare" -eq 0 ]; then ok "no bare event_name == 'schedule' gate remains"
else bad "$bare bare event_name == 'schedule' gate(s) remain (the main cron would hit them)"; fi
nightly="$(grep -c "github.event.schedule == '17 7 \* \* \*'" <<< "$stripped")"
if [ "$nightly" -ge 7 ]; then ok "nightly gates keyed on the nightly cron ($nightly sites)"
else bad "only $nightly nightly-cron gates (expected >= 7)"; fi

# Nothing may still be gated on a push event.
if grep -q "github.event_name == 'push'" <<< "$stripped"; then bad "a gate still keys on event_name == 'push'"
else ok "no gate keys on event_name == 'push'"; fi

# The cron run names the merge range it covers.
if grep -q 'git log --oneline' <<< "$stripped"; then ok "cron run prints the merge range"
else bad "no merge-range step (git log --oneline prev..HEAD)"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
