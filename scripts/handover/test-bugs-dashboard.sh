#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; D="$HERE/bugs-dashboard.sh"; B="$HERE/bug.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

root="$tmp/state"
mkdir -p "$root/epics/HIMMEL-1-alpha" "$root/standalones/HIMMEL-2-beta"
ba="$root/epics/HIMMEL-1-alpha/bugs.md"; bb="$root/standalones/HIMMEL-2-beta/bugs.md"
bash "$B" add --bugs "$ba" --symptom "alpha race" >/dev/null            # BUG-1 open
bash "$B" fix --bugs "$ba" --id BUG-1 --outcome FAILED --note "x" >/dev/null
bash "$B" add --bugs "$bb" --symptom "beta leak" >/dev/null             # BUG-1 open
bash "$B" status --bugs "$bb" --id BUG-1 --to resolved

out="$(bash "$D" --root "$root")"
check "table header"   "$(printf '%s' "$out" | grep -c '^| Item | Bug | Status | Symptom | Fixes |')" "1"
check "alpha row"      "$(printf '%s' "$out" | grep -c '| epics/HIMMEL-1-alpha | BUG-1 | open | alpha race | 1 |')" "1"
check "beta row"       "$(printf '%s' "$out" | grep -c '| standalones/HIMMEL-2-beta | BUG-1 | resolved | beta leak | 0 |')" "1"
check "totals all"     "$(printf '%s' "$out" | grep -c '\*\*Totals:\*\* 2 bug(s), 1 open/fixing\.')" "1"

# sort: alpha (epics/) sorts before beta (standalones/)
la=$(printf '%s' "$out" | grep -n 'alpha race' | head -1 | cut -d: -f1)
lb=$(printf '%s' "$out" | grep -n 'beta leak'  | head -1 | cut -d: -f1)
check "epics sorts first" "$( [ "$la" -lt "$lb" ] && echo yes )" "yes"

# --open: only open/fixing rows, totals reflect filtered set
oout="$(bash "$D" --open --root "$root")"
check "open: keeps alpha" "$(printf '%s' "$oout" | grep -c 'alpha race')" "1"
check "open: drops beta"  "$(printf '%s' "$oout" | grep -c 'beta leak')" "0"

# symptom with a pipe is escaped so the table stays valid
mkdir -p "$root/standalones/HIMMEL-3-pipe"
bash "$B" add --bugs "$root/standalones/HIMMEL-3-pipe/bugs.md" --symptom 'a | b' >/dev/null
pout="$(bash "$D" --root "$root")"
check "pipe escaped" "$(printf '%s' "$pout" | grep -cF 'a \| b')" "1"

# multiple bugs in one item: both rows render in id order; --open filters within the
# item and the totals reflect the filtered set.
root4="$tmp/multi"; mkdir -p "$root4/epics/HIMMEL-7-multi"
m="$root4/epics/HIMMEL-7-multi/bugs.md"
bash "$B" add --bugs "$m" --symptom "first open" >/dev/null     # BUG-1 open
bash "$B" add --bugs "$m" --symptom "second done" >/dev/null    # BUG-2
bash "$B" status --bugs "$m" --id BUG-2 --to resolved
mout="$(bash "$D" --root "$root4")"
check "multi: BUG-1 row" "$(printf '%s' "$mout" | grep -c '| epics/HIMMEL-7-multi | BUG-1 | open | first open | 0 |')" "1"
check "multi: BUG-2 row" "$(printf '%s' "$mout" | grep -c '| epics/HIMMEL-7-multi | BUG-2 | resolved | second done | 0 |')" "1"
ml1=$(printf '%s' "$mout" | grep -n 'first open'  | head -1 | cut -d: -f1)
ml2=$(printf '%s' "$mout" | grep -n 'second done' | head -1 | cut -d: -f1)
check "multi: id order"  "$( [ "$ml1" -lt "$ml2" ] && echo yes )" "yes"
check "multi: totals"    "$(printf '%s' "$mout" | grep -c '\*\*Totals:\*\* 2 bug(s), 1 open/fixing\.')" "1"
mopen="$(bash "$D" --open --root "$root4")"
check "multi --open: keeps BUG-1" "$(printf '%s' "$mopen" | grep -c 'BUG-1')" "1"
check "multi --open: drops BUG-2" "$(printf '%s' "$mopen" | grep -c 'BUG-2')" "0"
check "multi --open: totals"      "$(printf '%s' "$mopen" | grep -c '\*\*Totals:\*\* 1 bug(s), 1 open/fixing\.')" "1"

# empty root -> friendly message, rc 0
empty="$tmp/empty"; mkdir -p "$empty"
eout="$(bash "$D" --root "$empty")"; erc=$?
check "empty rc 0"   "$erc" "0"
check "empty message" "$(printf '%s' "$eout" | grep -c '_No bugs tracked._')" "1"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
