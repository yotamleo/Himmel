#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || C` reporting pattern is intentional here
# test-initiative-legs.sh — unit test for scripts/lib/initiative-legs.sh
# (HIMMEL-443). Verifies the pure leg resolver: named-arg inputs → normalized,
# canonical-ordered, deduped active leg set, across interactive + overnight
# profiles, subsets, falsy values, case/space tolerance, and selector precedence.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$here/initiative-legs.sh"
fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"
  else printf 'FAIL - %s\n     expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=1; fi
}

# interactive profile (selector empty → read arg1)
check "interactive all → legacy 4"      "prcheck pr ticket handover" "$(resolve_legs all '' '')"
check "interactive 1 → legacy 4"        "prcheck pr ticket handover" "$(resolve_legs 1 '' '')"
check "interactive falsy 0 → empty"     ""                            "$(resolve_legs 0 '' '')"
check "interactive empty → empty"       ""                            "$(resolve_legs '' '' '')"
check "interactive off → empty"         ""                            "$(resolve_legs off '' '')"
check "interactive subset+order"        "prcheck pr merge"            "$(resolve_legs 'merge,prcheck,pr' '' '')"
check "interactive unknown ignored"     "pr ticket"                   "$(resolve_legs 'pr,bogus,ticket' '' '')"
check "interactive case+space"          "prcheck handover"            "$(resolve_legs '  Handover , PRCHECK ' '' '')"
check "interactive dedup"               "pr"                          "$(resolve_legs 'pr,pr' '' '')"
check "interactive plan token kept"     "plan prcheck"                "$(resolve_legs 'plan,prcheck' '' '')"

# overnight profile (selector truthy → read arg2, ignore arg1)
check "overnight all → 6 legs"          "execute prcheck pr ticket merge handover" "$(resolve_legs '' all 1)"
check "overnight bare 1 → 6 legs"       "execute prcheck pr ticket merge handover" "$(resolve_legs '' 1 1)"
check "overnight subset"                "execute merge"               "$(resolve_legs '' 'merge,execute' 1)"
check "selector wins over initiative"   "execute"                     "$(resolve_legs all execute 1)"
check "overnight falsy → empty"         ""                            "$(resolve_legs '' 0 1)"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
