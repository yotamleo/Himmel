#!/usr/bin/env bash
set -uo pipefail
usage() { echo "foo --keep-flag"; }
t=$(mktemp -d)
ok=$(mktemp -d "${TMPDIR:-/tmp}/foo.XXXXXX")
timeout 5 sleep 1
timeout 5 sleep 1   # gnu-ok: test fixture
mapfile -t arr < /dev/null
n=$((COUNT + 1))
m=$((10#$COUNT + 1))
p="$HOME/handovers/x"
echo "$t $ok ${arr[*]} $n $m $p"
printf x | grep -q x || true
aid=$(jq -r '.agent_id // empty' <<< "$p")
aid2=$(jq -r '(.agent_id | type) == "string"' <<< "$p")
nm=$(jq -r '.branch // empty' f.json)
grep -E "SKIPPED [—-] 0 cases ran" "$p" || true
grep -E "SKIPPED (—|-) 0 cases ran" "$p" || true
run "/usr/bin/cat" "$p"
cat "$p"
echo "$aid $aid2 $nm"
tt=$(jq -r '.agent_id // empty | type' f.json)
echo "$tt"
rm -f "$t/missing"
wait
[ -n "$t" ] && flag=1
rm -f "$t/x" || true
wait "$pid"
[ "$(date +%m)" -gt 8 ] && echo late
[[ "$(date +%m)" -gt 8 ]] && echo late
gd=$(git rev-parse --git-common-dir)
top=$(git rev-parse --show-toplevel)
t2=$(mktemp -d 2>/dev/null)
