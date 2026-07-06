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

# ── usage kind (HIMMEL-485): chars/4 token estimate, dedup on (head,model) ──
CR_LEDGER="$L" bash "$LA" usage --branch b --head H1 --model codex --prompt-chars 4000 --response-chars 800
CR_LEDGER="$L" bash "$LA" usage --branch b --head H1 --model codex --prompt-chars 4000 --response-chars 800
check "usage dedup on (head,model)" "$(grep -c '"kind":"usage"' "$L")" "1"
# est tokens = round(chars/4): prompt 4000/4=1000, response 800/4=200, total 1200
check "usage est_prompt_tokens=1000" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage");console.log(o.est_prompt_tokens)')" "1000"
check "usage est_completion_tokens=200" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage");console.log(o.est_completion_tokens)')" "200"
check "usage est_total_tokens=1200" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage");console.log(o.est_total_tokens)')" "1200"
check "usage marked estimated" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage");console.log(o.estimated)')" "true"
# new head -> new usage line (not deduped against H1)
CR_LEDGER="$L" bash "$LA" usage --branch b --head H2 --model codex --prompt-chars 40 --response-chars 8
check "usage new head -> new line" "$(grep -c '"kind":"usage"' "$L")" "2"

# non-numeric char counts coerce to 0 (Math.max(0,Number()||0)) — guards the
# durable ledger against a NaN if wc -c ever yields garbage. response stays valid.
CR_LEDGER="$L" bash "$LA" usage --branch b --head H3 --model codex --prompt-chars abc --response-chars 800
check "non-numeric prompt-chars -> est_prompt_tokens 0" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage"&&r.head==="H3");console.log(o.est_prompt_tokens+","+o.est_completion_tokens)')" "0,200"

# zero-char prompt+response (hermes returned empty raw but CR_USAGE_LOG=1 fired):
# a well-formed all-zero estimate, still marked estimated.
CR_LEDGER="$L" bash "$LA" usage --branch b --head H4 --model codex --prompt-chars 0 --response-chars 0
check "zero-char usage -> est_total 0, estimated" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage"&&r.head==="H4");console.log(o.est_total_tokens+","+o.estimated)')" "0,true"

# ── WS4 (HIMMEL-414): artifact/perspective segmentation ─────────────────────
# The dedup key gains artifact+perspective so a second arm (same head, same
# finding_id, perspectives flipped) is NOT silently dropped.
LP="$tmp/persp.jsonl"
# (a) same (head,finding_id) in two perspective arms → BOTH lines (round-2 red path)
CR_LEDGER="$LP" bash "$LA" finding --branch b --head HP --model m --id p-1 --severity major --file f --line 1 --verdict agreed --perspective off
CR_LEDGER="$LP" bash "$LA" finding --branch b --head HP --model m --id p-1 --severity major --file f --line 1 --verdict agreed --perspective on
check "perspective off+on both recorded (no silent drop)" "$(grep -c '"kind":"finding"' "$LP")" "2"
# (b) same head+id+artifact+perspective twice → ONE line (dedup still works)
CR_LEDGER="$LP" bash "$LA" finding --branch b --head HP --model m --id p-1 --severity major --file f --line 1 --verdict agreed --perspective on
check "same head+id+artifact+perspective dedups" "$(grep -c '"kind":"finding"' "$LP")" "2"
# avail: same head+model across two perspective arms → BOTH (one avail per row per arm)
CR_LEDGER="$LP" bash "$LA" avail --branch b --head HP --model m --status ok --perspective off
CR_LEDGER="$LP" bash "$LA" avail --branch b --head HP --model m --status ok --perspective on
check "avail two perspective arms both recorded" "$(grep -c '"kind":"avail"' "$LP")" "2"
CR_LEDGER="$LP" bash "$LA" avail --branch b --head HP --model m --status ok --perspective on
check "avail same head+model+perspective dedups" "$(grep -c '"kind":"avail"' "$LP")" "2"
# artifact segmentation: same head+id, artifact diff then spec → BOTH lines
LArt="$tmp/artifact.jsonl"
CR_LEDGER="$LArt" bash "$LA" finding --branch b --head HA --model m --id a-1 --severity major --file f --line 1 --verdict agreed --artifact diff
CR_LEDGER="$LArt" bash "$LA" finding --branch b --head HA --model m --id a-1 --severity major --file f --line 1 --verdict agreed --artifact spec
check "artifact diff+spec both recorded (no silent drop)" "$(grep -c '"kind":"finding"' "$LArt")" "2"
# (c) record without new flags carries artifact:diff, perspective:off defaults
LD="$tmp/default.jsonl"
CR_LEDGER="$LD" bash "$LA" finding --branch b --head HD --model m --id d-1 --severity minor --file f --line 2 --verdict agreed
check "default artifact=diff" "$(L="$LD" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="finding");console.log(o.artifact)')" "diff"
check "default perspective=off" "$(L="$LD" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="finding");console.log(o.perspective)')" "off"
# invalid enum values rejected (exit 2)
CR_LEDGER="$LD" bash "$LA" finding --branch b --head HD --model m --id d-2 --severity minor --file f --line 2 --verdict agreed --artifact bogus >/dev/null 2>&1
check "invalid --artifact rejected" "$?" "2"
CR_LEDGER="$LD" bash "$LA" finding --branch b --head HD --model m --id d-3 --severity minor --file f --line 2 --verdict agreed --perspective maybe >/dev/null 2>&1
check "invalid --perspective rejected" "$?" "2"
# unknown kind still rejected
CR_LEDGER="$L" bash "$LA" bogus --branch b --head H1 --model m >/dev/null 2>&1
check "unknown kind rejected" "$?" "2"

check "valid json lines" "$(L="$L" node -e 'require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).forEach(l=>JSON.parse(l));console.log("ok")')" "ok"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
