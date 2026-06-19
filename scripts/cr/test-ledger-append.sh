#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C intentional in check() and final assert
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; LA="$HERE/ledger-append.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; L="$tmp/ledger.jsonl"
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

CR_LEDGER="$L" bash "$LA" finding --branch b --head H1 --model m --id m-1 --severity critical --file f --line 3 --verdict agreed
CR_LEDGER="$L" bash "$LA" finding --branch b --head H1 --model m --id m-1 --severity critical --file f --line 3 --verdict agreed
check "finding dedup on (head,id)" "$(wc -l < "$L" | tr -d ' ')" "1"

CR_LEDGER="$L" bash "$LA" finding --branch b --head H2 --model m --id m-1 --severity critical --file f --line 3 --verdict disproved
check "new head -> new line" "$(wc -l < "$L" | tr -d ' ')" "2"

CR_LEDGER="$L" bash "$LA" avail --branch b --head H1 --model m --status ok
CR_LEDGER="$L" bash "$LA" avail --branch b --head H1 --model m --status ok
check "avail dedup on (head,model)" "$(grep -c '"kind":"avail"' "$L")" "1"

check "valid json lines" "$(L="$L" node -e 'require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).forEach(l=>JSON.parse(l));console.log("ok")')" "ok"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
