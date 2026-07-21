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

CR_LEDGER="$L" bash "$LA" finding --branch b --head H5 --model qwen3coder --responding-model qwen-flash --id qwen3coder-1 --severity critical --file f --line 3 --verdict agreed
check "finding stores responding_model separately from model key" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="H5");console.log(o.model+","+o.responding_model)')" "qwen3coder,qwen-flash"

CR_LEDGER="$L" bash "$LA" avail --branch b --head H1 --model m --status ok
CR_LEDGER="$L" bash "$LA" avail --branch b --head H1 --model m --status ok
check "avail dedup on (head,model)" "$(grep -c '"kind":"avail"' "$L")" "1"

CR_LEDGER="$L" bash "$LA" avail --branch b --head H5 --model qwen3coder --responding-model qwen-flash --status ok
CR_LEDGER="$L" bash "$LA" avail --branch b --head H5 --model qwen3coder --responding-model qwen-plus --status ok
check "avail responding_model does not change dedup key" "$(grep -c '"kind":"avail".*"head":"H5"' "$L")" "1"
check "avail stores first responding_model" "$(L="$L" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="avail"&&r.head==="H5");console.log(o.model+","+o.responding_model)')" "qwen3coder,qwen-flash"

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

# ── HIMMEL-1176: --reason/--detail plumbing (additive, back-compat) ────────
LR="$tmp/reason.jsonl"
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH1 --model glm --status unavailable --reason quota-5h --detail "429 usage limit reached"
check "reason field stored" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH1");console.log(o.reason)')" "quota-5h"
check "detail field stored" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH1");console.log(o.detail)')" "429 usage limit reached"

# Omitted --reason/--detail -> fields ABSENT (not empty strings) — back-compat.
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH2 --model glm --status ok
check "no --reason -> reason key absent" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH2");console.log("reason" in o)')" "false"
check "no --detail -> detail key absent" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH2");console.log("detail" in o)')" "false"

# Dedup key is UNCHANGED by --reason/--detail (still (head,model) for avail).
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH1 --model glm --status unavailable --reason auth --detail "different text"
check "reason/detail do not widen the avail dedup key" "$(grep -c '"head":"RH1"' "$LR")" "1"

# reason/detail also plumb through `finding` (generic support, same flags).
CR_LEDGER="$LR" bash "$LA" finding --branch b --head RH3 --model m --id m-9 --severity minor --file f --line 1 --verdict agreed --reason malformed-output
check "finding reason field stored" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH3");console.log(o.reason)')" "malformed-output"

# detail truncated to <=200 chars.
LONG_DETAIL="$(printf 'x%.0s' $(seq 1 250))"
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH4 --model m --status unavailable --reason generic-rc-1 --detail "$LONG_DETAIL"
check "detail truncated to <=200 chars" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH4");console.log(o.detail.length<=200)')" "true"

# detail flattens embedded newlines to spaces.
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH5 --model m --status unavailable --reason http-5xx --detail "line one
line two"
check "detail flattens newlines" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH5");console.log(o.detail)')" "line one line two"

# ── HIMMEL-1176: detail secret-scrub ────────────────────────────────────────
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH6 --model m --status unavailable --reason auth --detail "auth failed, token: abcdef0123456789ghijklm"  # gitleaks:allow (fake fixture for the scrub test)
check "detail scrubs a token=<value> shape" "$(L="$LR" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="RH6");console.log(o.detail.includes("abcdef0123456789ghijklm"))')" "false"  # gitleaks:allow (fake fixture)
contains_json_detail() { L="$LR" HEAD_="$1" NEEDLE="$2" node -e 'const fs=require("fs"),e=process.env;const o=fs.readFileSync(e.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head===e.HEAD_);console.log(o.detail.includes(e.NEEDLE))'; }
check "detail scrub leaves [REDACTED] marker" "$(contains_json_detail RH6 '[REDACTED]')" "true"

CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH7 --model m --status unavailable --reason auth --detail "Authorization: Bearer sk-abcdefghij0123456789"  # gitleaks:allow (fake fixture for the scrub test)
check "detail scrubs a Bearer token" "$(contains_json_detail RH7 'sk-abcdefghij0123456789')" "false"  # gitleaks:allow (fake fixture)

CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH8 --model m --status unavailable --reason auth --detail "aws key AKIAABCDEFGHIJKLMNOP leaked"  # gitleaks:allow (fake fixture for the scrub test)
check "detail scrubs an AWS-shaped key" "$(contains_json_detail RH8 'AKIAABCDEFGHIJKLMNOP')" "false"  # gitleaks:allow (fake fixture)

# Fake telegram-bot-token fixture built at runtime from split parts so the
# digits:secret LITERAL never appears in source — a literal would trip gitleaks
# AND the public-propagation leak scanner (which, unlike gitleaks, ignores
# `# gitleaks:allow`), blocking propagation. Joined at runtime it still matches
# the scrub regex [0-9]{8,10}:[A-Za-z0-9_-]{35}.
_tg_id="123456789"; _tg_sec="AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawX"
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH9 --model m --status unavailable --reason http-4xx --detail "telegram token ${_tg_id}:${_tg_sec} leaked"
check "detail scrubs a telegram-bot-token shape" "$(contains_json_detail RH9 "${_tg_id}:${_tg_sec}")" "false"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
