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

# ── HIMMEL-1613: avail monotone supersede — a timeout on run 1 followed by a
# success on run 2 at the SAME (head,model) used to hit the flat dedup above
# and get silently dropped, permanently wedging clear-cr-marker at that SHA.
AV="$tmp/avail-supersede.jsonl"
CR_LEDGER="$AV" bash "$LA" avail --branch b --head SH1 --model glm --status unavailable --reason quota-5h
CR_LEDGER="$AV" bash "$LA" avail --branch b --head SH1 --model glm --status ok
check "avail unavailable->ok appends (not dropped)" "$(grep -c '"kind":"avail".*"head":"SH1"' "$AV")" "2"
check "avail unavailable->ok: the ok row is the effective (last) record" "$(L="$AV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="avail"&&r.head==="SH1");console.log(rs[rs.length-1].status)')" "ok"

# A downgrade (ok -> unavailable) must be refused/dropped: a later transient
# failure must never erase an earlier success (that could dodge a blocker).
CR_LEDGER="$AV" bash "$LA" avail --branch b --head SH1 --model glm --status unavailable --reason later-failure 2>"$tmp/downgrade.err"
check "avail ok->unavailable downgrade exits 0 (quiet refusal, not an error)" "$?" "0"
check "avail ok->unavailable downgrade writes NOTHING" "$(grep -c '"kind":"avail".*"head":"SH1"' "$AV")" "2"
check "avail ok->unavailable downgrade names the reason" "$(grep -c 'DOWNGRADE' "$tmp/downgrade.err")" "1"
check "avail downgrade leaves the ok row as the last record" "$(L="$AV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="avail"&&r.head==="SH1");console.log(rs[rs.length-1].status)')" "ok"

# An identical repeat is still a quiet no-op (idempotent /pr-check re-runs).
CR_LEDGER="$AV" bash "$LA" avail --branch b --head SH1 --model glm --status ok
check "avail identical repeat after supersede still dedups" "$(grep -c '"kind":"avail".*"head":"SH1"' "$AV")" "2"

# ── HIMMEL-2128: same-status RECLASSIFICATION — `reason` is now gate-relevant
# (CR_FLOOR_FALLBACK reads it to judge VERIFIED exhaustion), so a lane first
# classified unavailable(reason=quota) that later degrades to a different
# reason (e.g. config) must not keep showing the stale reason forever. A
# same-status write with a DIFFERENT reason appends (supersedes); the SAME
# reason repeated still dedups.
AV2="$tmp/avail-reclassify.jsonl"
CR_LEDGER="$AV2" bash "$LA" avail --branch b --head SH4 --model codex --status unavailable --reason quota
CR_LEDGER="$AV2" bash "$LA" avail --branch b --head SH4 --model codex --status unavailable --reason config
check "avail unavailable(quota) -> unavailable(config) appends (reclassification)" "$(grep -c '"kind":"avail".*"head":"SH4"' "$AV2")" "2"
check "avail reclassification: config is the effective (last) reason" "$(L="$AV2" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="avail"&&r.head==="SH4");console.log(rs[rs.length-1].reason)')" "config"

CR_LEDGER="$AV2" bash "$LA" avail --branch b --head SH5 --model codex --status unavailable --reason quota
CR_LEDGER="$AV2" bash "$LA" avail --branch b --head SH5 --model codex --status unavailable --reason quota
check "avail unavailable(quota) -> unavailable(quota) still dedups (same reason)" "$(grep -c '"kind":"avail".*"head":"SH5"' "$AV2")" "1"

# ── HIMMEL-1640: avail supersession identity is (head, model) ONLY ──────────
# The prior-record matcher ignores artifact/perspective. A recovery (unavailable
# -> ok) supersedes even across DIFFERENT review arms, and an ok -> unavailable
# downgrade is refused even across arms. Availability is a property of the
# (head, model) pair, not of the arm that probed it.
AVI="$tmp/avail-supersede-id.jsonl"
# (a) recovery across a DIFFERENT artifact: unavailable recorded on diff, then
# ok recorded on spec at the same (head, model) -> the ok APPENDS (supersedes
# the stale unavailable). (artifact must be diff|spec|plan; pr-body is not a
# valid artifact, so the two readings use diff then spec.)
CR_LEDGER="$AVI" bash "$LA" avail --branch b --head SH2 --model glm --status unavailable --reason quota-5h --artifact diff
CR_LEDGER="$AVI" bash "$LA" avail --branch b --head SH2 --model glm --status ok --artifact spec
check "avail recovery across different artifact appends (supersedes on head+model)" "$(grep -c '"kind":"avail".*"head":"SH2"' "$AVI")" "2"
check "avail recovery across artifact: ok is the effective (last) record" "$(L="$AVI" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="avail"&&r.head==="SH2");console.log(rs[rs.length-1].status)')" "ok"
# (b) downgrade across a DIFFERENT perspective: ok then unavailable at the same
# (head, model) -> REFUSED. A later transient failure on another arm must never
# erase an earlier success.
CR_LEDGER="$AVI" bash "$LA" avail --branch b --head SH3 --model glm --status ok --perspective off
CR_LEDGER="$AVI" bash "$LA" avail --branch b --head SH3 --model glm --status unavailable --reason later-failure --perspective on 2>"$tmp/downgrade-arm.err"
check "avail downgrade across perspective exits 0 (quiet refusal)" "$?" "0"
check "avail downgrade across perspective writes NOTHING" "$(grep -c '"kind":"avail".*"head":"SH3"' "$AVI")" "1"
check "avail downgrade across perspective names the reason" "$(grep -c 'DOWNGRADE' "$tmp/downgrade-arm.err")" "1"

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
# avail: same head+model across two perspective arms. Unlike finding/usage
# above, avail's supersession identity is (head, model) ONLY (HIMMEL-1640) — a
# critic's availability is global to the commit, not per-arm — so a second ok
# on a different perspective arm dedups as a quiet no-op, NOT one row per arm.
CR_LEDGER="$LP" bash "$LA" avail --branch b --head HP --model m --status ok --perspective off
CR_LEDGER="$LP" bash "$LA" avail --branch b --head HP --model m --status ok --perspective on
check "avail across perspective arms dedups on (head,model)" "$(grep -c '"kind":"avail"' "$LP")" "1"
CR_LEDGER="$LP" bash "$LA" avail --branch b --head HP --model m --status ok --perspective on
check "avail same head+model+perspective still dedups" "$(grep -c '"kind":"avail"' "$LP")" "1"
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

# Identity is still (head,model) for avail, but a same-status write whose
# reason/detail DIFFERS now APPENDS rather than dedups (HIMMEL-2128 — see the
# SH4/SH5 reclassification cases below): reason is gate-relevant to
# CR_FLOOR_FALLBACK, so a stale reason must not silently persist forever.
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RH1 --model glm --status unavailable --reason auth --detail "different text"
check "reason/detail change on a same-status repeat appends (reclassification)" "$(grep -c '"head":"RH1"' "$LR")" "2"

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

# HIMMEL-1996: modern keys are HYPHENATED (`sk-proj-…`, `sk-ant-…`) - the bare
# alphanumeric class this scrub started with stopped at the first hyphen and let
# the whole key through. Keep in lockstep with Get-ScrubbedToken in
# scripts/observability/agent-runtime-census.ps1 (HIMMEL-1988).
CR_LEDGER="$LR" bash "$LA" avail --branch b --head RHA --model m --status unavailable --reason auth --detail "401: incorrect api key sk-proj-FAKEFAKEFAKEFAKEFAKE0000"  # gitleaks:allow (fake fixture for the scrub test)
check "detail scrubs a hyphenated sk- key" "$(contains_json_detail RHA 'sk-proj-FAKEFAKEFAKEFAKEFAKE0000')" "false"  # gitleaks:allow (fake fixture)
check "the hyphenated-key scrub leaves a marker" "$(contains_json_detail RHA '[REDACTED]')" "true"

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

# ── HIMMEL-2078: --text plumbing (the panel's one-line prose claim) ─────────
LT="$tmp/text.jsonl"
CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX1 --model m --id t-1 --severity imp --file f --line 1 --verdict "" --text "- [t-1]: the thing is wrong [f:1]"
check "finding stores text" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX1");console.log(o.text)')" "- [t-1]: the thing is wrong [f:1]"

CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX2 --model m --id t-2 --severity imp --file f --line 1 --verdict ""
check "no --text -> text key absent" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX2");console.log("text" in o)')" "false"

LONG_TEXT="$(printf 'y%.0s' $(seq 1 600))"
CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX3 --model m --id t-3 --severity imp --file f --line 1 --verdict "" --text "$LONG_TEXT"
check "text truncated to <=500 chars" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX3");console.log(o.text.length<=500)')" "true"

CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX4 --model m --id t-4 --severity imp --file f --line 1 --verdict "" --text "line one
line two"
check "text flattens newlines" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX4");console.log(o.text)')" "line one line two"

# quotes inside --text must round-trip through JSON.parse cleanly (proper
# JSON-escaping, same mechanism the other fields already use).
CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX5 --model m --id t-5 --severity imp --file f --line 1 --verdict "" --text 'the "quoted" claim'
check "text with quotes round-trips" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX5");console.log(o.text)')" 'the "quoted" claim'

# text secret-scrub (critic-panel.sh CR round, HIMMEL-2078): review prose can
# quote a secret straight out of the diff being reviewed — reuse the same
# scrub --detail already gets.
CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX6 --model m --id t-6 --severity imp --file f --line 1 --verdict "" --text "found a leaked Bearer sk-abcdefghij0123456789 in the diff"  # gitleaks:allow (fake fixture for the scrub test)
check "text scrubs a secret" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX6");console.log(o.text.includes("sk-abcdefghij0123456789"))')" "false"  # gitleaks:allow (fake fixture)
check "text scrub leaves a [REDACTED] marker" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX6");console.log(o.text.includes("[REDACTED]"))')" "true"

# HIMMEL-2078 CR round (CodeRabbit): a token split across an EMBEDDED newline
# (e.g. word-wrapped in the reviewed diff) must still be scrubbed — flatten
# happens before the scrub, not after, or sed's line-at-a-time processing
# never sees the token+value pair as one line.
CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX7 --model m --id t-7 --severity imp --file f --line 1 --verdict "" --text "Token:
abcdefghijklmnopqrst"  # gitleaks:allow (fake fixture for the scrub test)
check "text scrubs a token split across an embedded newline" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX7");console.log(o.text.includes("abcdefghijklmnopqrst")+","+o.text.includes("[REDACTED]"))')" "false,true"  # gitleaks:allow (fake fixture)

# HIMMEL-2078 CR round 2 (codex): a LONE carriage return (not paired with a
# following \n) must flatten the same way \n does.
CR_LEDGER="$LT" bash "$LA" finding --branch b --head TX8 --model m --id t-8 --severity imp --file f --line 1 --verdict "" --text $'Token:\rzxywvutsrqponmlkjihg'  # gitleaks:allow (fake fixture for the scrub test)
check "text scrubs a token split across a lone carriage return" "$(L="$LT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="TX8");console.log(o.text.includes("zxywvutsrqponmlkjihg")+","+o.text.includes("[REDACTED]"))')" "false,true"  # gitleaks:allow (fake fixture)

# Consumer read over a mixed ledger (some rows with text, some without,
# including a pre-existing legacy row that never had the field at all) must
# not crash and must not confuse text-bearing rows with text-less ones.
LMX="$tmp/mixed-consumer.jsonl"
{
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"MX1","model":"m","finding_id":"mx-1","severity":"imp","file":"f","line":1,"verdict":"","artifact":"diff","perspective":"off"}\n'
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"MX2","model":"m","finding_id":"mx-2","severity":"imp","file":"f","line":1,"verdict":"","artifact":"diff","perspective":"off","text":"has text"}\n'
} > "$LMX"
check "mixed ledger (legacy row with no text + a new row with text) parses cleanly" \
    "$(node -e 'const rs=require("fs").readFileSync(process.argv[1],"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(("text" in rs[0])+","+rs[1].text)' "$LMX")" "false,has text"

# ── HIMMEL-1294: conflicting re-append + the amend verb ─────────────────────
# The wedge this ticket is about: re-appending a finding with a LOWER severity
# hit the dedup key, wrote nothing, and exited 0. The caller believed the
# record was corrected; the gate kept reading the original and kept refusing.
AM="$tmp/amend.jsonl"; : > "$AM"
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH1 --model codex-adv --id codex-adv-1 --severity imp --file f --line 3 --verdict agreed

CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH1 --model codex-adv --id codex-adv-1 --severity sug --file f --line 3 --verdict agreed 2>"$tmp/conflict.err"
check "conflicting re-append exits non-zero (was a silent 0)" "$?" "3"
check "conflicting re-append wrote NOTHING" "$(wc -l < "$AM" | tr -d ' ')" "1"
check "conflicting re-append names the amend verb" "$(grep -c 'amend --head' "$tmp/conflict.err")" "1"
check "conflicting re-append says nothing was written" "$(grep -c 'NOTHING was written' "$tmp/conflict.err")" "1"

# An IDENTICAL re-append must stay a quiet success — /pr-check re-runs on the
# same head as a matter of course, and idempotency is a real feature.
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH1 --model codex-adv --id codex-adv-1 --severity imp --file f --line 3 --verdict agreed
check "identical re-append still exits 0 (idempotent)" "$?" "0"
check "identical re-append adds no line" "$(wc -l < "$AM" | tr -d ' ')" "1"

# HIMMEL-2020: callers may still pass an abbreviated HEAD. The writer normalizes
# all SHA-like short heads before writing, so panel rows and later verdict rows
# land under one full-SHA key instead of parallel short/full rows.
GIT_FULL=$(git rev-parse --verify HEAD)
GIT_SHORT=$(git rev-parse --short HEAD)
HN="$tmp/head-normalize.jsonl"; : > "$HN"
CR_LEDGER="$HN" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-1 --severity imp --file f --line 3 --verdict ""
CR_LEDGER="$HN" bash "$LA" avail --branch b --head "$GIT_SHORT" --model codex --status ok
CR_LEDGER="$HN" bash "$LA" usage --branch b --head "$GIT_SHORT" --model codex --prompt-chars 40 --response-chars 8
CR_LEDGER="$HN" bash "$LA" attempt --branch b --head "$GIT_SHORT" --model codex --status ok --attempt 1 --duration-secs 2
check "short --head normalizes for finding/avail/usage/attempt" "$(L="$HN" FULL="$GIT_FULL" node -e 'const rows=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rows.length+","+rows.every(r=>r.head===process.env.FULL))')" "4,true"
CR_LEDGER="$HN" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-1 --severity imp --file f --line 3 --verdict disproved
check "verdict-only re-append at short head exits 0" "$?" "0"
check "verdict-only re-append writes an amend at the full key" "$(L="$HN" FULL="$GIT_FULL" node -e 'const rows=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);const a=rows.find(r=>r.kind==="amend"&&r.finding_id==="codex-1");console.log(a.target_head+","+a.set.verdict)')" "$GIT_FULL,disproved"
BAD="$tmp/bad-short.jsonl"; : > "$BAD"
CR_LEDGER="$BAD" bash "$LA" avail --branch b --head 0000000 --model codex --status ok 2>"$tmp/bad-short.err"
check "unresolvable abbreviated --head is rejected" "$?" "2"
check "unresolvable abbreviated --head writes no row" "$(wc -l < "$BAD" | tr -d ' ')" "0"
check "unresolvable abbreviated --head error is loud" "$(grep -c 'does not resolve' "$tmp/bad-short.err")" "1"

# The verdict-only carve-out must not swallow a genuinely differing re-append:
# an empty-verdict prior whose severity ALSO changes is a real conflict, not an
# adjudication, and must still hit the pre-existing loud refusal.
CR_LEDGER="$HN" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-2 --severity crit --file f --line 3 --verdict ""
CR_LEDGER="$HN" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-2 --severity sug --file f --line 3 --verdict disproved 2>/dev/null
check "empty-verdict prior + severity change still refuses (not verdict-only)" "$?" "3"

# codex-1, HIMMEL-2020 round 2: the verdict-only check must compare against
# the EFFECTIVE state, not the raw append-only row - otherwise a SECOND
# verdict change on an already-amended finding reads the raw rows still-empty
# verdict field and silently mints another auto-amend, overwriting the first
# adjudication instead of refusing (a genuine re-adjudication must go through
# the explicit amend verb, same as any other post-adjudication correction).
RV="$tmp/reverdict.jsonl"; : > "$RV"
CR_LEDGER="$RV" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-3 --severity imp --file f --line 3 --verdict ""
CR_LEDGER="$RV" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-3 --severity imp --file f --line 3 --verdict agreed
check "first verdict fill-in is a verdict-only amend" "$(L="$RV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend"&&r.finding_id==="codex-3");console.log(rs.length+","+rs[0].set.verdict)')" "1,agreed"
CR_LEDGER="$RV" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-3 --severity imp --file f --line 3 --verdict disproved 2>/dev/null
check "re-verdicting an ALREADY-amended finding refuses (not another auto-amend)" "$?" "3"
check "the already-amended finding gets no second amend" "$(L="$RV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend"&&r.finding_id==="codex-3");console.log(rs.length)')" "1"

# codex-1, HIMMEL-2020 round 3: a LEGACY finding row stored under a short head
# (written before this ticket) must still be found by the finding-dedup
# lookup when a caller re-appends using that SAME short spelling - matching
# only the normalized full key missed it and created a parallel row instead
# of colliding, recreating a milder form of the original bug for legacy data.
# The stored (short) and incoming (normalized-full) head strings genuinely
# differ, so this is correctly a "differing content" refusal (rc=3, use
# amend) rather than a silent verdict-only amend - the fix under test is that
# it collides at all instead of falling through to a brand-new parallel row.
LG="$tmp/legacy-short.jsonl"
printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"codex-4","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$GIT_SHORT" > "$LG"
CR_LEDGER="$LG" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-4 --severity imp --file f --line 3 --verdict agreed 2>/dev/null
check "verdict append against a legacy short-keyed row refuses (collision, not a new row)" "$?" "3"
check "legacy short row collision writes no parallel finding row" "$(L="$LG" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs.filter(r=>r.kind==="finding"&&r.finding_id==="codex-4").length)')" "1"

# codex-1, HIMMEL-2020 round 4: a STALE pre-existing pair - a legacy short-head
# row AND a full-head row already both recorded for the same finding_id (the
# exact shape the original bug used to produce) - must refuse the write as
# AMBIGUOUS rather than silently picking one via pop() and leaving the other
# blocking the gate forever with no signal.
AMB="$tmp/ambiguous-pair.jsonl"
{
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"codex-5","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$GIT_SHORT"
  printf '{"kind":"finding","ts":"2020-01-02T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"codex-5","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$GIT_FULL"
} > "$AMB"
CR_LEDGER="$AMB" bash "$LA" finding --branch b --head "$GIT_SHORT" --model codex --id codex-5 --severity imp --file f --line 3 --verdict agreed 2>"$tmp/ambiguous.err"
check "a stale short+full duplicate pair refuses (ambiguous, not a guess)" "$?" "3"
check "ambiguity refusal names the count" "$(grep -c 'matches 2 distinct existing rows' "$tmp/ambiguous.err")" "1"
check "ambiguity refusal writes nothing" "$(wc -l < "$AMB" | tr -d ' ')" "2"

# HIMMEL-2029: the amend verb's OWN target lookup reused this SAME
# resolve-then-compare matching, so on a stale short+full pair like $AMB it
# could match BOTH rows and silently amend whichever was LAST in ledger order
# via .pop() - not necessarily the row named by --head. It must instead
# prefer the row whose RAW stored head equals the --head ARGUMENT
# byte-for-byte (the literal spelling passed, before any resolve-to-full
# normalization).
AMB_A="$tmp/ambiguous-pair-a.jsonl"; cp "$AMB" "$AMB_A"
CR_LEDGER="$AMB_A" bash "$LA" amend --head "$GIT_SHORT" --id codex-5 --set severity=sug --reason "picking the short-keyed row"
check "amend on an ambiguous pair: exact match on the SHORT raw head resolves it" "$?" "0"
check "amend on an ambiguous pair: targets the short-keyed row, not last-in-order" \
    "$(L="$AMB_A" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");console.log(rs[rs.length-1].target_head)')" "$GIT_SHORT"

# Reversed insertion order from $AMB (full-keyed row FIRST, short-keyed row
# LAST) so this case actually discriminates: under the old .pop()-picks-last
# behavior this would wrongly target the SHORT row, not the FULL one asked for.
AMB_B="$tmp/ambiguous-pair-b.jsonl"
{
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"codex-5","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$GIT_FULL"
  printf '{"kind":"finding","ts":"2020-01-02T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"codex-5","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$GIT_SHORT"
} > "$AMB_B"
CR_LEDGER="$AMB_B" bash "$LA" amend --head "$GIT_FULL" --id codex-5 --set severity=sug --reason "picking the full-keyed row"
check "amend on an ambiguous pair: exact match on the FULL raw head resolves it" "$?" "0"
check "amend on an ambiguous pair: targets the full-keyed row even though it is NOT last-in-order" \
    "$(L="$AMB_B" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");console.log(rs[rs.length-1].target_head)')" "$GIT_FULL"

# A THIRD abbreviation of the same commit that matches NEITHER raw stored
# spelling exactly must still refuse - and name both candidates - rather than
# guess.
AMB_C="$tmp/ambiguous-pair-c.jsonl"; cp "$AMB" "$AMB_C"
AMBIG_ABBR="${GIT_FULL:0:$((${#GIT_SHORT} + 3))}"
CR_LEDGER="$AMB_C" bash "$LA" amend --head "$AMBIG_ABBR" --id codex-5 --set severity=sug --reason x 2>"$tmp/amend-ambiguous.err"
check "amend on an ambiguous pair: a third non-matching abbreviation still refuses" "$?" "3"
# GIT_SHORT is itself a prefix of AMBIG_ABBR (both prefixes of GIT_FULL), so
# it also appears in both the "amend --head <AMBIG_ABBR>" echo line and the
# "None of them is EXACTLY <AMBIG_ABBR>" line, not just the "sit at" list -
# hence 3, not 1.
check "amend ambiguity refusal names the short raw head" "$(grep -c "$GIT_SHORT" "$tmp/amend-ambiguous.err")" "3"
check "amend ambiguity refusal names the full raw head" "$(grep -c "$GIT_FULL" "$tmp/amend-ambiguous.err")" "1"
check "amend ambiguity refusal writes nothing" "$(wc -l < "$AMB_C" | tr -d ' ')" "2"

# codex-1, HIMMEL-2029 CR round 4: the exact-match preference must compare
# against a row EFFECTIVE (post-amend) head, not its raw stored head - a row
# a PRIOR amend already re-keyed elsewhere still carries its ORIGINAL raw
# head forever (append-only), so matching on raw heads could silently prefer
# an unrelated row whose raw spelling happens to equal --head over the row
# that was actually re-keyed TO that head.
#
# (a) The precise old-vs-new discriminator: row1 (raw=AH10) is re-keyed to
# effective head Z; row2 (raw=Z) is SEPARATELY re-keyed away to effective
# head W. Both still match the amend lookup at --head Z (row1 via its
# EFFECTIVE head, row2 via its stale RAW head, since key(o) checks the raw
# field and re-keying never changes it - append-only). The OLD raw-based
# exact filter picked row2 (raw===Z) - WRONG, row2 no longer lives at Z. The
# FIX must pick row1 (only row1 EFFECTIVELY sits at Z now).
REKEY_ONLY="$tmp/rekey-only-effective.jsonl"
{
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"AH10","model":"codex","finding_id":"codex-10","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n'
  printf '{"kind":"amend","ts":"2020-01-02T00:00:00Z","branch":"b","target_head":"AH10","finding_id":"codex-10","artifact":"diff","perspective":"off","set":{"head":"aaaa1110"},"reason":"re-key row1 onto aaaa1110"}\n'
  printf '{"kind":"finding","ts":"2020-01-03T00:00:00Z","branch":"b","head":"aaaa1110","model":"codex","finding_id":"codex-10","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n'
  printf '{"kind":"amend","ts":"2020-01-04T00:00:00Z","branch":"b","target_head":"aaaa1110","finding_id":"codex-10","artifact":"diff","perspective":"off","set":{"head":"cccc3330"},"reason":"re-key row2 AWAY onto cccc3330"}\n'
} > "$REKEY_ONLY"
CR_LEDGER="$REKEY_ONLY" bash "$LA" amend --head aaaa1110 --id codex-10 --set severity=sug --reason "target the row that EFFECTIVELY sits at aaaa1110"
check "amend picks the row whose EFFECTIVE head matches, not the one whose stale raw head matches" "$?" "0"
check "amend on the re-keyed row records row1 (AH10) as target_head, not row2" \
    "$(L="$REKEY_ONLY" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");console.log(rs[rs.length-1].target_head)')" "AH10"

# (b) A re-keyed row AND an unrelated row that happens to raw-key onto the
# SAME head the re-key targeted: both now have effective head = bbbb2220, a
# genuine ambiguity (no head spelling can tell them apart) that must REFUSE,
# not silently pick the unrelated row just because ITS raw head literally
# matches (the round-4 bug: comparing raw heads picked the wrong duplicate).
REKEY_DUP="$tmp/rekey-dup-effective.jsonl"
{
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"AH20","model":"codex","finding_id":"codex-11","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n'
  printf '{"kind":"amend","ts":"2020-01-02T00:00:00Z","branch":"b","target_head":"AH20","finding_id":"codex-11","artifact":"diff","perspective":"off","set":{"head":"bbbb2220"},"reason":"re-key onto bbbb2220"}\n'
  printf '{"kind":"finding","ts":"2020-01-03T00:00:00Z","branch":"b","head":"bbbb2220","model":"codex","finding_id":"codex-11","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n'
} > "$REKEY_DUP"
CR_LEDGER="$REKEY_DUP" bash "$LA" amend --head bbbb2220 --id codex-11 --set severity=sug --reason x 2>"$tmp/rekey-dup.err"
check "amend refuses when a re-keyed row and an unrelated row share one effective head (genuine ambiguity)" "$?" "3"
check "amend refusal on shared effective heads writes nothing" "$(wc -l < "$REKEY_DUP" | tr -d ' ')" "3"

# codex-1, HIMMEL-2020 round 5: a finding RE-KEYED by a prior amend (--set
# head=) lives, EFFECTIVELY, at its new head while its raw stored row still
# reads the old one. A later finding-append at the NEW (re-keyed-to) head
# must collide with it via key(effective(o)), not fall through to a brand-new
# duplicate finding row - the raw stored head and the incoming head are
# genuinely different strings, so this correctly refuses (rc=3, use amend)
# rather than silently verdict-only-amending, same posture as the legacy
# short-row case above.
RK="$tmp/rekeyed-finding.jsonl"; : > "$RK"
CR_LEDGER="$RK" bash "$LA" finding --branch b --head AH2 --model codex --id codex-6 --severity imp --file f --line 3 --verdict ""
CR_LEDGER="$RK" bash "$LA" amend --head AH2 --id codex-6 --set head="$GIT_SHORT" --reason "raised against $GIT_SHORT, mis-keyed onto AH2"
CR_LEDGER="$RK" bash "$LA" finding --branch b --head "$GIT_FULL" --model codex --id codex-6 --severity imp --file f --line 3 --verdict agreed 2>/dev/null
check "verdict append at the re-keyed head collides (not a duplicate row)" "$?" "3"
check "re-keyed finding collision writes no duplicate finding row" "$(L="$RK" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs.filter(r=>r.kind==="finding"&&r.finding_id==="codex-6").length)')" "1"

# HIMMEL-2020 review round 1: amend's --head is a LOOKUP key, not a write key.
# A finding re-keyed via `--set head=` onto a sha this repo cannot resolve (the
# HIMMEL-1294 escape hatch explicitly allows this) must still be reachable by a
# FOLLOW-UP amend using that same literal spelling - normalizing/refusing on
# that lookup would dead-end the exact re-key it was meant to enable.
FH="$tmp/foreign-head.jsonl"; : > "$FH"
CR_LEDGER="$FH" bash "$LA" finding --branch b --head AH1 --model codex-adv --id codex-adv-1 --severity imp --file f --line 3 --verdict agreed
CR_LEDGER="$FH" bash "$LA" amend --head AH1 --id codex-adv-1 --set head=deadbeef --reason "raised against a public head not in this repo"
check "amend can re-key onto a head this repo cannot resolve" "$?" "0"
CR_LEDGER="$FH" bash "$LA" amend --head deadbeef --id codex-adv-1 --set severity=sug --reason "follow-up on the foreign-keyed finding"
check "a follow-up amend can still locate it by that literal spelling" "$?" "0"

# amend appends a SUPERSEDE record; it never rewrites the original line.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set severity=sug --reason "out of diff, pre-existing, already public"
check "amend exits 0" "$?" "0"
check "amend APPENDS rather than rewriting" "$(wc -l < "$AM" | tr -d ' ')" "2"
check "the original finding line is untouched" "$(L="$AM" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="finding");console.log(o.severity)')" "imp"
check "amend records the target + the set" "$(L="$AM" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="amend");console.log(o.target_head+","+o.finding_id+","+o.set.severity)')" "AH1,codex-adv-1,sug"
check "amend records the reason" "$(L="$AM" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="amend");console.log(o.reason)')" "out of diff, pre-existing, already public"

# The whole point of the verb: it must NEVER report success without writing.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id no-such-finding --set severity=sug --reason x 2>"$tmp/noop.err"
check "amend with no target exits non-zero" "$?" "3"
check "amend with no target says nothing was amended" "$(grep -c 'nothing amended' "$tmp/noop.err")" "1"
check "amend with no target wrote no line" "$(wc -l < "$AM" | tr -d ' ')" "2"

# A correction with no stated reason is indistinguishable from tampering.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set severity=sug 2>/dev/null
check "amend requires --reason" "$?" "2"
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --reason x 2>/dev/null
check "amend requires at least one --set" "$?" "2"
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set model=evil --reason x 2>/dev/null
check "amend refuses to set a non-amendable key" "$?" "2"

# Incident 2: the finding was keyed to the head that FIXES it instead of the
# head it was raised against. amend can re-key it.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set head="$GIT_SHORT" --reason "raised against $GIT_SHORT, mis-keyed onto the fixing head"
check "amend can re-key the head" "$(L="$AM" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");console.log(rs[rs.length-1].set.head)')" "$GIT_SHORT"

# codex-1 round 3: a re-key to something the gate cannot recognise as a head
# makes the finding vanish from gate 4 entirely - fail OPEN. Validate exactly
# the shape the gate consumes (isHex: 7-64 hex chars), no narrower, no wider.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set head=HEAD~1 --reason x 2>/dev/null
check "amend rejects a non-sha head (would silently unblock)" "$?" "2"
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set head=abc123 --reason x 2>/dev/null
check "amend rejects a too-short head" "$?" "2"

# HIMMEL-2029: a SHA-256 repo's full head is 64 hex chars, not 40 - the old
# 7-40 ceiling rejected every such head as "not a head" at all (fail OPEN).
# Isolated ledger: an amend here must not disturb $AM's ongoing re-key narrative.
SHA256_HEAD="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
SH="$tmp/sha256-head.jsonl"; : > "$SH"
CR_LEDGER="$SH" bash "$LA" finding --branch b --head AH9 --model codex --id codex-9 --severity imp --file f --line 3 --verdict agreed
CR_LEDGER="$SH" bash "$LA" amend --head AH9 --id codex-9 --set head="$SHA256_HEAD" --reason x
check "amend accepts a 64-hex (SHA-256-length) head" "$?" "0"
check "amend records the 64-hex head" "$(L="$SH" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");console.log(rs[rs.length-1].set.head)')" "$SHA256_HEAD"
CR_LEDGER="$SH" bash "$LA" amend --head AH9 --id codex-9 --set head="${SHA256_HEAD}f" --reason x 2>/dev/null
check "amend rejects a 65-char head (too long for either scheme)" "$?" "2"

# HIMMEL-2321: a producer self-write (coderabbit-review.sh / codex-adv-
# harvest.sh, mirroring critic-panel.sh's existing --batch-file self-write)
# records `text` at panel time (verdict empty). The interactive step-4.5
# finding call NEVER sends --text (.claude/commands/pr-check.md step 4.5) -
# before this fix a verdict-only re-append then refused as "different
# content" purely because of the extra `text` key on the producer's row (RED:
# reproduced against the pre-fix comparator - `norm()` compared raw key sets
# including `text`, so the producer row's extra key never matched a
# session-side rec that never carries one). Single-row producer write, then
# the session's ordinary verdict-only finding call.
TXV="$tmp/text-verdict-single.jsonl"; : > "$TXV"
CR_LEDGER="$TXV" bash "$LA" finding --branch b --head "$GIT_FULL" --model coderabbit --id coderabbit-1 --severity crit --file f.txt --line 10 --verdict "" --text "the script's rc is unchecked"
CR_LEDGER="$TXV" bash "$LA" finding --branch b --head "$GIT_FULL" --model coderabbit --id coderabbit-1 --severity crit --file f.txt --line 10 --verdict agreed --reason "fixed literal" 2>"$tmp/txv.err"
check "verdict-only re-append converges despite the producer row carrying text" "$?" "0"
check "  ...via an amend, not a refusal" "$(L="$TXV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs.filter(r=>r.kind==="finding").length+","+rs.filter(r=>r.kind==="amend").length)')" "1,1"
check "  ...the original text is preserved (producer text wins)" "$(L="$TXV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs[0].text)')" "the script's rc is unchecked"
check "  ...the amended verdict wins" "$(L="$TXV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs.find(r=>r.kind==="amend").set.verdict)')" "agreed"

# Same convergence via the --batch-file producer path (critic-panel.sh's/the
# new producers' actual call shape), not just the single-row finding path.
TXB="$tmp/text-verdict-batch.jsonl"; : > "$TXB"
TXBF="$tmp/text-verdict-batch-rows.jsonl"
printf '{"branch":"b","head":"%s","model":"coderabbit","id":"coderabbit-1","severity":"crit","file":"f.txt","line":10,"verdict":"","text":"the script'"'"'s rc is unchecked"}\n' "$GIT_FULL" > "$TXBF"
CR_LEDGER="$TXB" bash "$LA" finding --batch-file "$TXBF"
CR_LEDGER="$TXB" bash "$LA" finding --branch b --head "$GIT_FULL" --model coderabbit --id coderabbit-1 --severity crit --file f.txt --line 10 --verdict agreed 2>"$tmp/txb.err"
check "verdict-only re-append converges after a --batch-file producer write too" "$?" "0"
check "  ...via an amend, not a refusal (batch path)" "$(L="$TXB" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs.filter(r=>r.kind==="finding").length+","+rs.filter(r=>r.kind==="amend").length)')" "1,1"

# HIMMEL-2321 CR round 2 (codex-1): the regression the round-1 fix opened.
# Unconditionally dropping `text` from BOTH sides of the comparison made a
# genuinely DIFFERENT finding that reuses an id (a reordered/updated producer
# run remapping the same id onto new text - the realistic case, since ids are
# minted in stream order) compare EQUAL and silently drop, where before it
# was a loud rc=3 refusal. A second PRODUCER-shaped write (carries --text)
# for the SAME (head,id) with DIFFERENT text must still refuse, not converge.
TXD="$tmp/text-diverge-single.jsonl"; : > "$TXD"
CR_LEDGER="$TXD" bash "$LA" finding --branch b --head "$GIT_FULL" --model coderabbit --id coderabbit-2 --severity crit --file f.txt --line 5 --verdict "" --text "finding A text"
CR_LEDGER="$TXD" bash "$LA" finding --branch b --head "$GIT_FULL" --model coderabbit --id coderabbit-2 --severity crit --file f.txt --line 5 --verdict "" --text "finding B text (different)" 2>"$tmp/txd.err"
check "a second producer write with DIFFERENT text under the same id still refuses" "$?" "3"
check "  ...names the amend fix, not a silent dedupe" "$(grep -c 'ALREADY recorded' "$tmp/txd.err")" "1"
check "  ...only the first write landed (no silent overwrite)" "$(wc -l < "$TXD" | tr -d ' ')" "1"

# Same divergence check via the --batch-file producer path.
TXDB="$tmp/text-diverge-batch.jsonl"; : > "$TXDB"
TXDBF1="$tmp/text-diverge-batch-1.jsonl"
TXDBF2="$tmp/text-diverge-batch-2.jsonl"
printf '{"branch":"b","head":"%s","model":"coderabbit","id":"coderabbit-2","severity":"crit","file":"f.txt","line":5,"verdict":"","text":"finding A text"}\n' "$GIT_FULL" > "$TXDBF1"
printf '{"branch":"b","head":"%s","model":"coderabbit","id":"coderabbit-2","severity":"crit","file":"f.txt","line":5,"verdict":"","text":"finding B text (different)"}\n' "$GIT_FULL" > "$TXDBF2"
CR_LEDGER="$TXDB" bash "$LA" finding --batch-file "$TXDBF1"
CR_LEDGER="$TXDB" bash "$LA" finding --batch-file "$TXDBF2" 2>"$tmp/txdb.err"
check "batch mode: a second producer write with DIFFERENT text under the same id still refuses" "$?" "3"
check "  ...only the first write landed (batch path)" "$(wc -l < "$TXDB" | tr -d ' ')" "1"

# codex-1 round 4: after a re-key, the original row still reads the OLD head
# (append-only), so a second amend aimed at the NEW head - the only head an
# operator can see in the effective state - must still resolve. Otherwise the
# recovery path breaks exactly when it is being used to recover.
CR_LEDGER="$AM" bash "$LA" amend --head "$GIT_SHORT" --id codex-adv-1 --set severity=sug --reason "second amend, aimed at the re-keyed head"
check "amend resolves a finding through a prior re-key" "$?" "0"
check "the follow-up amend still keys on the ORIGINAL head" "$(L="$AM" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");console.log(rs[rs.length-1].target_head)')" "AH1"

# ── HIMMEL-1294: the deferral field ─────────────────────────────────────────
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH3 --model glm --id glm-1 --severity imp --file f --line 1 --verdict deferred --deferred-to HIMMEL-1293 --reason "pre-existing, already public"
check "finding stores deferred_to" "$(L="$AM" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="AH3");console.log(o.verdict+","+o.deferred_to)')" "deferred,HIMMEL-1293"
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH4 --model glm --id glm-2 --severity imp --file f --line 1 --verdict deferred --deferred-to "not a ticket" 2>/dev/null
check "a malformed --deferred-to is rejected" "$?" "2"

# codex-1: the validator was a shell GLOB, not a regex. In `[A-Z][A-Z0-9]*-[0-9]*`
# the trailing `*` means ANY characters, so HI-1x passed here and was then
# rejected by the gate's anchored regex — split validation, the exact trap that
# makes a deferral fail late and opaquely.
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH5 --model glm --id glm-3 --severity imp --file f --line 1 --verdict deferred --deferred-to "HI-1x" --reason r 2>/dev/null
check "ticket key with a trailing non-digit is rejected (glob-vs-regex)" "$?" "2"
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH5 --model glm --id glm-3 --severity imp --file f --line 1 --verdict deferred --deferred-to "himmel-1" --reason r 2>/dev/null
check "lowercase ticket key is rejected" "$?" "2"
CR_LEDGER="$AM" bash "$LA" finding --branch b --head AH6 --model glm --id glm-4 --severity imp --file f --line 1 --verdict deferred --deferred-to "HI-1" --reason r
check "a minimal well-formed ticket key is accepted" "$?" "0"

# codex-1: gate 4 blocks on severity IN (crit, imp), so a typo matches neither
# and would silently unblock. The one verb that can change a gate verdict must
# not fail OPEN on a fat finger.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set severity=suq --reason x 2>/dev/null
check "amend rejects a typo'd severity (would silently unblock)" "$?" "2"
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set severity=imp --reason x
check "amend accepts a valid severity" "$?" "0"
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set verdict=disprovd --reason x 2>/dev/null
check "amend rejects a typo'd verdict" "$?" "2"

# glm-5: --set deferred_to= must get the SAME eager validation, or a typo is
# only caught at gate time — on the very path amend exists to unblock.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set deferred_to=nope --reason x 2>/dev/null
check "amend --set deferred_to= validates the ticket key too" "$?" "2"

# glm-3: the gate reads the FINDING's reason, so `reason` must be amendable —
# otherwise deferring an already-recorded finding (the documented recovery) is a
# dead end for any finding logged without one.
CR_LEDGER="$AM" bash "$LA" amend --head AH1 --id codex-adv-1 --set reason="out of scope for this branch" --reason "deferring after review"
check "amend can set the finding-level reason" "$?" "0"
check "amend --set reason lands in set, not on the amend reason" "$(L="$AM" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="amend");const r=rs[rs.length-1];console.log(r.set.reason+"|"+r.reason)')" "out of scope for this branch|deferring after review"

# ── HIMMEL-1500: `attempt` kind — per-invocation timing, NEVER deduped ──────
AT="$tmp/attempt.jsonl"
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH1 --model glm --responding-model glm-5.2 --status timeout --attempt 1 --duration-secs 451 --detail "rc=124"
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH1 --model glm --responding-model glm-5.2 --status ok --attempt 2 --duration-secs 12 --detail "rc=0"
check "attempt: two tries at the SAME head+model both land (no avail-style dedup)" \
    "$(grep -c '"kind":"attempt".*"head":"TH1"' "$AT")" "2"
check "attempt: first row carries status=timeout" \
    "$(L="$AT" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="attempt"&&r.head==="TH1");console.log(rs[0].status)')" "timeout"
check "attempt: first row carries the measured duration_secs" \
    "$(L="$AT" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="attempt"&&r.head==="TH1");console.log(rs[0].duration_secs)')" "451"
check "attempt: second row carries attempt=2, status=ok" \
    "$(L="$AT" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).filter(r=>r.kind==="attempt"&&r.head==="TH1");console.log(rs[1].attempt+","+rs[1].status)')" "2,ok"
check "attempt: a repeat of the IDENTICAL first attempt still appends (never deduped)" \
    "$(CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH1 --model glm --responding-model glm-5.2 --status timeout --attempt 1 --duration-secs 451 --detail "rc=124" >/dev/null 2>&1; grep -c '"kind":"attempt".*"head":"TH1"' "$AT")" "3"
check "attempt: hour_utc is derived from ts (queryable without re-parsing ISO8601 per row)" \
    "$(L="$AT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="attempt"&&r.head==="TH1");console.log(typeof o.hour_utc==="number"&&o.hour_utc>=0&&o.hour_utc<=23)')" "true"

# Required fields.
CR_LEDGER="$AT" bash "$LA" attempt --branch b --model glm --status ok >/dev/null 2>&1
check "attempt requires --head" "$?" "2"
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH2 --status ok >/dev/null 2>&1
check "attempt requires --model" "$?" "2"

# --status must be ok|timeout|error — NOT avail's ok|unavailable vocabulary
# (a typo'd "unavailable" here would silently become an unrecognised outcome).
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH3 --model glm --status unavailable >/dev/null 2>&1
check "attempt rejects avail's --status vocabulary (ok|timeout|error only)" "$?" "2"
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH3 --model glm --status error >/dev/null 2>&1
check "attempt accepts --status error" "$?" "0"

# --attempt / --duration-secs must be non-negative integers.
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH4 --model glm --status ok --attempt abc >/dev/null 2>&1
check "attempt rejects a non-numeric --attempt" "$?" "2"
CR_LEDGER="$AT" bash "$LA" attempt --branch b --head TH4 --model glm --status ok --duration-secs abc >/dev/null 2>&1
check "attempt rejects a non-numeric --duration-secs" "$?" "2"

# ── HIMMEL-2335: `delegation` kind — one row per anchor->branch delegation,
# NEVER deduped (same posture as `attempt`) ─────────────────────────────────
DG="$tmp/delegation.jsonl"
CR_LEDGER="$DG" bash "$LA" delegation --branch fix/himmel-2335-prcheck-anchor --head cccccccccccccccccccccccccccccccccccccccc --reason "diff touches scripts/cr/ - branch self-review required" --detail "anchor=fake-anchor-dir delegate=fake-delegate-dir"
check "delegation write exits 0" "$?" "0"
check "delegation row shape: kind/branch/head/reason/detail" \
    "$(L="$DG" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="delegation");console.log(o.kind+"|"+o.branch+"|"+o.head+"|"+o.reason+"|"+o.detail)')" \
    "delegation|fix/himmel-2335-prcheck-anchor|cccccccccccccccccccccccccccccccccccccccc|diff touches scripts/cr/ - branch self-review required|anchor=fake-anchor-dir delegate=fake-delegate-dir"
check "delegation row has no artifact/perspective keys (not part of the delegation contract)" \
    "$(L="$DG" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="delegation");console.log(("artifact" in o)+","+("perspective" in o))')" \
    "false,false"

# --detail is OPTIONAL -- omitted -> key ABSENT (never an empty string),
# same back-compat posture as --reason/--detail elsewhere in this file.
CR_LEDGER="$DG" bash "$LA" delegation --branch b --head dddddddddddddddddddddddddddddddddddddddd --reason "diff touches scripts/cr/"
check "delegation without --detail exits 0" "$?" "0"
check "delegation without --detail -> detail key absent" \
    "$(L="$DG" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.head==="dddddddddddddddddddddddddddddddddddddddd");console.log("detail" in o)')" \
    "false"

# required-flag refusal: --head and --reason are both mandatory.
CR_LEDGER="$DG" bash "$LA" delegation --branch b --reason "diff touches scripts/cr/" >/dev/null 2>"$tmp/dg-no-head.err"
check "delegation without --head is refused (exit 2)" "$?" "2"
check "delegation without --head names --head in the refusal" "$(grep -c -- '--head' "$tmp/dg-no-head.err")" "1"
CR_LEDGER="$DG" bash "$LA" delegation --branch b --head eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee >/dev/null 2>"$tmp/dg-no-reason.err"
check "delegation without --reason is refused (exit 2)" "$?" "2"
check "delegation without --reason names --reason in the refusal" "$(grep -c -- '--reason' "$tmp/dg-no-reason.err")" "1"

# NEVER deduped: an IDENTICAL repeat at the same head still appends its own
# row (unlike finding/avail, which dedup on (head,id)/(head,model)) -- a
# delegation is a per-run EVENT, not a property of a (head,model) pair.
CR_LEDGER="$DG" bash "$LA" delegation --branch fix/himmel-2335-prcheck-anchor --head cccccccccccccccccccccccccccccccccccccccc --reason "diff touches scripts/cr/ - branch self-review required" --detail "anchor=fake-anchor-dir delegate=fake-delegate-dir"
check "delegation identical repeat exits 0 (not a refusal)" "$?" "0"
check "delegation identical repeat still appends a SECOND row (never deduped)" \
    "$(grep -c '"kind":"delegation".*"head":"cccccccccccccccccccccccccccccccccccccccc"' "$DG")" "2"

# ── HIMMEL-2035 T4 SC4: foreign-repo fence ──────────────────────────────────
# ledger-append.sh already resolves its ledger via
# `git rev-parse --git-common-dir` off cwd (no -C — see line 225), so it
# already writes into whatever repo the caller's cwd sits in; no --repo flag
# was added. Prove it: running with cwd = a repo that is NOT the himmel
# checkout (this suite's OWN fixture, no himmel scripts) writes the fixture's
# OWN ledger and leaves himmel's real ledger byte-for-byte untouched.

# mk_foreign_repo <dir> — a repo that is emphatically NOT the himmel checkout:
# bare origin (HEAD pinned to main) + clone, origin/HEAD set, one commit on
# the default branch, one feature branch with one commit. No himmel scripts.
mk_foreign_repo() {
  local d="$1"; mkdir -p "$d/origin.git" "$d/work"
  git init --bare -q "$d/origin.git"
  # A freshly-inited bare repo's HEAD follows init.defaultBranch (which may be
  # `master`, or anything the machine configures). `git push HEAD:main` does NOT
  # move it, so `git remote set-head origin -a` on the clone would resolve the
  # WRONG branch — or nothing at all. Pin it explicitly.
  git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$d/origin.git" "$d/work"
  # Hermetic identity: CI boxes and fresh VMs have no global user.name/email,
  # and `git commit` hard-fails without one. Repo-local config, never --global.
  git -C "$d/work" config user.name  "himmel-test"
  git -C "$d/work" config user.email "himmel-test@example.invalid"
  ( cd "$d/work" && git commit -q --allow-empty -m init && git push -q origin HEAD:refs/heads/main \
    && git remote set-head origin -a >/dev/null 2>&1 \
    && git checkout -qb feat/x && git commit -q --allow-empty -m change )
  # ASSERT the fixture's own precondition — a silently-missing origin/HEAD would
  # make every base-resolution assertion test the fallback, not production.
  git -C "$d/work" symbolic-ref refs/remotes/origin/HEAD >/dev/null \
    || { echo "fixture: origin/HEAD not established in $d/work" >&2; return 1; }
}

# The REAL himmel checkout's git-common-dir — resolved off $HERE (this test's
# own directory), which sits inside it whether run from the primary checkout
# or a worktree (both share one git-common-dir). This is the artifact the
# no-touch assertion below must see unaffected by the foreign-repo append.
HIMMEL_LEDGER="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"
# The no-touch assertion must be CONCURRENCY-SAFE (codex CR round, matching
# the same fix already applied to this diff's test-clear-cr-marker.sh T15):
# himmel's ledger is APPEND-ONLY LIVE shared state — another session (a
# parallel /pr-check, another worktree's push) can legitimately append a row
# while this suite runs, and a whole-file hash comparison would then fail
# for a reason that has nothing to do with the code under test. Assert the
# precise property instead: no line APPENDED during this run may name the
# fixture head — unrelated concurrent appends are ignored, a leaked
# foreign-repo row is still caught.
BEFORE_HIMMEL_LEDGER_LINES=0
[ -f "$HIMMEL_LEDGER" ] && BEFORE_HIMMEL_LEDGER_LINES=$(wc -l < "$HIMMEL_LEDGER")

FX="$tmp/foreign-repo"
# Stop on a failed fixture setup (codex CR round) rather than cascading into
# git/node operations against a nonexistent or half-built $FX/work — those
# would fail for the WRONG reason and mask the real setup error.
mk_foreign_repo "$FX" || { echo "FAIL - foreign-repo fixture setup"; fails=$((fails+1)); exit 1; }
FX_HEAD="$(git -C "$FX/work" rev-parse HEAD)"
( cd "$FX/work" && bash "$LA" finding --branch feat/x --head "$FX_HEAD" --model m --id fx-1 --severity minor --file f --line 1 --verdict agreed )
check "foreign-repo ledger-append exits 0" "$?" "0"
check "foreign-repo ledger lands under the FIXTURE's own .git" "$([ -f "$FX/work/.git/cr-critic-scores.jsonl" ] && echo yes || echo no)" "yes"
check "foreign-repo ledger row carries the fixture head" \
    "$(node -e 'const o=require("fs").readFileSync(process.argv[1],"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="finding");console.log(o.head)' "$FX/work/.git/cr-critic-scores.jsonl")" "$FX_HEAD"
if [ -f "$HIMMEL_LEDGER" ]; then
    appended_himmel_ledger=$(tail -n "+$((BEFORE_HIMMEL_LEDGER_LINES + 1))" "$HIMMEL_LEDGER" 2>/dev/null || true)
else
    appended_himmel_ledger=""
fi
himmel_ledger_leak=""
case "$appended_himmel_ledger" in *"$FX_HEAD"*) himmel_ledger_leak="$FX_HEAD" ;; esac
check "himmel's OWN ledger is untouched by the foreign-repo append" "${himmel_ledger_leak:-clean}" "clean"

# ── HIMMEL-2052: full-SHA heads short-circuit resolveHead (no git spawn) ────
# Root cause: resolveHead used to shell out to `git rev-parse --verify` once
# per DISTINCT stored head hit during the dedup scan - on a ledger that has
# accumulated hundreds of distinct heads that was hundreds of process spawns
# for a SINGLE row append (measured on the live 3.4MB ledger: 1615 spawns,
# ~55s). A canonical 40-hex SHA can never change under git resolution, so it
# never needs a spawn at all.
#
# A PATH-shimmed `git` (the ticket's preferred proof) does not work on this
# Windows/Node setup: ledger-append.sh's resolveHead calls
# `execFileSync("git", args)` with no `shell:true`, and Node's non-shell
# Windows spawn (a) never appends PATHEXT extensions to a bare "git" lookup -
# a shim script or .cmd placed earlier on PATH is silently skipped in favour
# of the real git.exe found deeper in PATH (empirically confirmed: a `git.cmd`
# shim placed first on PATH was never invoked), and (b) cannot run a .cmd/.bat
# shim at all without shell:true (spawnSync fails EINVAL, confirmed directly).
# So this locks in the fix via a time bound instead - a large synthetic seed
# (300 distinct full-SHA heads, none matching the caller's head) makes the two
# behaviors clearly distinguishable: unpatched code would need ~300 real git
# spawns (many seconds, per the measured ~1615-spawns/55s rate above); fixed
# code makes ZERO spawns for an all-full-SHA scan and finishes in well under
# a second. The bound below (5s) has wide margin either way.
FSH="$tmp/full-sha-heads.jsonl"
: > "$FSH"
for i in $(seq 1 300); do
  h=$(printf '%040d' "$i")
  printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"codex-seed-%d","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$h" "$i"
done >> "$FSH"
NEWHEAD=$(printf '%040d' 999)
_fsh_t0=$(($(date +%s) * 1000))
CR_LEDGER="$FSH" bash "$LA" finding --branch b --head "$NEWHEAD" --model codex --id codex-new --severity imp --file f --line 3 --verdict agreed
_fsh_rc=$?
_fsh_t1=$(($(date +%s) * 1000))
_fsh_ms=$(( _fsh_t1 - _fsh_t0 ))
check "full-SHA-only dedup scan against 300 distinct heads exits 0" "$_fsh_rc" "0"
check "full-SHA-only dedup scan writes the new row" "$(grep -c '"finding_id":"codex-new"' "$FSH")" "1"
[ "$_fsh_ms" -lt 5000 ] && echo "ok - full-SHA-only dedup scan completes in well under 5s (zero git spawns): ${_fsh_ms}ms" \
    || { echo "FAIL - full-SHA-only dedup scan took ${_fsh_ms}ms (>=5000ms - resolveHead may be spawning git again)"; fails=$((fails+1)); }

# The legacy short-head resolve-then-compare path itself (a stored abbreviated
# head still matching a full-SHA caller head) is already covered above by
# "short --head normalizes", "verdict-only re-append writes an amend at the
# full key", and "legacy short row collision refuses" - all still green with
# this fix, proving the batched git-cat-file resolution preserves exactly the
# same match semantics as the old per-head `git rev-parse --verify` calls.

# ── HIMMEL-2052: `finding --batch-file` ─────────────────────────────────────
BHEAD=$(printf '%040d' 12345)
BF="$tmp/batch-basic.jsonl"
BFL="$tmp/batch-basic-ledger.jsonl"; : > "$BFL"
{
  printf '{"branch":"b","head":"%s","model":"codex","id":"b-1","severity":"imp","file":"f","line":1,"verdict":""}\n' "$BHEAD"
  printf '{"branch":"b","head":"%s","model":"glm","id":"b-2","severity":"crit","file":"f","line":2,"verdict":""}\n' "$BHEAD"
  printf '{"branch":"b","head":"%s","model":"codex","id":"b-1","severity":"imp","file":"f","line":1,"verdict":""}\n' "$BHEAD"
} > "$BF"
CR_LEDGER="$BFL" bash "$LA" finding --batch-file "$BF"
check "batch mode exits 0 on all-successful rows" "$?" "0"
check "batch mode writes 2 distinct rows (intra-batch identical dup is a quiet no-op)" "$(wc -l < "$BFL" | tr -d ' ')" "2"

# A row within the batch that conflicts with an EARLIER row in the SAME batch
# must refuse that ONE row and still write the others - partial success, same
# per-row refusal semantics as N separate invocations, not all-or-nothing.
BF2="$tmp/batch-conflict.jsonl"
BFL2="$tmp/batch-conflict-ledger.jsonl"; : > "$BFL2"
{
  printf '{"branch":"b","head":"%s","model":"codex","id":"c-1","severity":"imp","file":"f","line":1,"verdict":""}\n' "$BHEAD"
  printf '{"branch":"b","head":"%s","model":"codex","id":"c-1","severity":"crit","file":"f","line":1,"verdict":""}\n' "$BHEAD"
  printf '{"branch":"b","head":"%s","model":"codex","id":"c-2","severity":"imp","file":"f","line":2,"verdict":""}\n' "$BHEAD"
} > "$BF2"
CR_LEDGER="$BFL2" bash "$LA" finding --batch-file "$BF2" 2>"$tmp/batch-conflict.err"
check "batch mode exits non-zero if ANY row refused" "$?" "3"
check "batch mode still writes the non-conflicting rows" "$(wc -l < "$BFL2" | tr -d ' ')" "2"
check "batch mode names the conflicting row in stderr" "$(grep -c 'c-1' "$tmp/batch-conflict.err")" "2"

# batch mode requires a pre-resolved full-SHA head per row (it does not
# per-row shell out to normalize an abbreviation - that would reintroduce the
# very per-row git-spawn cost this mode exists to avoid).
BF3="$tmp/batch-abbrev.jsonl"
BFL3="$tmp/batch-abbrev-ledger.jsonl"; : > "$BFL3"
printf '{"branch":"b","head":"abc1234","model":"codex","id":"d-1","severity":"imp","file":"f","line":1,"verdict":""}\n' > "$BF3"
CR_LEDGER="$BFL3" bash "$LA" finding --batch-file "$BF3" 2>"$tmp/batch-abbrev.err"
check "batch mode refuses a row with a non-full-SHA head" "$?" "3"
check "batch mode writes nothing for the refused row" "$(wc -l < "$BFL3" | tr -d ' ')" "0"

# batch mode refuses a row MISSING a required key (branch/model/severity/
# file/line/verdict) - a syntactically-valid object short one of these must
# not silently write `undefined` into a ledger record (codex-1, HIMMEL-2052
# CR round). Presence, not truthiness: an EMPTY value for the same key is a
# legitimate citation-less finding (HIMMEL-1494) and must still write - see
# the companion check below.
BF4="$tmp/batch-missing-key.jsonl"
BFL4="$tmp/batch-missing-key-ledger.jsonl"; : > "$BFL4"
printf '{"head":"%s","model":"codex","id":"e-1","severity":"imp","file":"f","line":1,"verdict":""}\n' "$BHEAD" > "$BF4"
CR_LEDGER="$BFL4" bash "$LA" finding --batch-file "$BF4" 2>"$tmp/batch-missing-key.err"
check "batch mode refuses a row missing a required key" "$?" "3"
check "batch mode writes nothing for the key-missing row" "$(wc -l < "$BFL4" | tr -d ' ')" "0"
check "batch mode names the missing key in stderr" "$(grep -c 'branch' "$tmp/batch-missing-key.err")" "1"

# Companion: a row with an EMPTY value (key present) for the same fields -
# the actual shape critic-panel.sh emits for a citation-less finding - still
# writes normally.
BF5="$tmp/batch-empty-values.jsonl"
BFL5="$tmp/batch-empty-values-ledger.jsonl"; : > "$BFL5"
printf '{"branch":"","head":"%s","model":"codex","id":"e-2","severity":"imp","file":"","line":"","verdict":""}\n' "$BHEAD" > "$BF5"
CR_LEDGER="$BFL5" bash "$LA" finding --batch-file "$BF5" 2>"$tmp/batch-empty-values.err"
check "batch mode accepts a row with present-but-empty values" "$?" "0"
check "batch mode writes the empty-value row" "$(wc -l < "$BFL5" | tr -d ' ')" "1"

# --batch-file is scoped to the finding kind only.
CR_LEDGER="$tmp/batch-kind.jsonl" bash "$LA" avail --batch-file "$BF" 2>/dev/null
check "--batch-file on a non-finding kind is rejected" "$?" "2"

# batch mode against a PRE-EXISTING ledger: a verdict-only re-append still
# auto-amends (same carve-out as the single-row path), not a duplicate row.
BFV="$tmp/batch-verdict.jsonl"
printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","finding_id":"v-1","severity":"imp","file":"f","line":3,"verdict":"","artifact":"diff","perspective":"off"}\n' "$BHEAD" > "$BFV"
BFVB="$tmp/batch-verdict-batch.jsonl"
printf '{"branch":"b","head":"%s","model":"codex","id":"v-1","severity":"imp","file":"f","line":3,"verdict":"agreed"}\n' "$BHEAD" > "$BFVB"
CR_LEDGER="$BFV" bash "$LA" finding --batch-file "$BFVB"
check "batch mode verdict-only re-append exits 0" "$?" "0"
check "batch mode verdict-only re-append writes an amend, not a duplicate finding row" \
    "$(L="$BFV" node -e 'const rs=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse);console.log(rs.filter(r=>r.kind==="finding").length+","+rs.filter(r=>r.kind==="amend").length)')" "1,1"

# ── HIMMEL-2078: --batch-file text plumbing (spec.text bypasses the
# shell-side scrub, so ledger-append.sh's node writer must sanitize it too) ──
BFT="$tmp/batch-text.jsonl"; : > "$BFT"
BFTF="$tmp/batch-text-rows.jsonl"
LONG_BATCH_TEXT="$(printf 'z%.0s' $(seq 1 600))"
{
  printf '{"branch":"b","head":"%s","model":"codex","id":"bt-1","severity":"imp","file":"f","line":1,"verdict":"","text":"- [bt-1]: batch claim [f:1]"}\n' "$BHEAD"
  printf '{"branch":"b","head":"%s","model":"codex","id":"bt-2","severity":"imp","file":"f","line":2,"verdict":""}\n' "$BHEAD"
  printf '{"branch":"b","head":"%s","model":"codex","id":"bt-3","severity":"imp","file":"f","line":3,"verdict":"","text":"%s"}\n' "$BHEAD" "$LONG_BATCH_TEXT"
  printf '{"branch":"b","head":"%s","model":"codex","id":"bt-4","severity":"imp","file":"f","line":4,"verdict":"","text":"diff leaks aws key AKIAABCDEFGHIJKLMNOP here"}\n' "$BHEAD"  # gitleaks:allow (fake fixture for the scrub test)
  # HIMMEL-2078 CR round (CodeRabbit): a JSON-escaped \n embedded in spec.text
  # decodes to a real newline splitting the token from its value — must still
  # scrub (flatten before scrub in the node writer too).
  printf '{"branch":"b","head":"%s","model":"codex","id":"bt-5","severity":"imp","file":"f","line":5,"verdict":"","text":"Token:\\napikeyvalue1234567890"}\n' "$BHEAD"  # gitleaks:allow (fake fixture for the scrub test)
  # HIMMEL-2078 CR round 2 (codex): a JSON-escaped \r (lone carriage return)
  # must also flatten before the scrub sees it.
  printf '{"branch":"b","head":"%s","model":"codex","id":"bt-6","severity":"imp","file":"f","line":6,"verdict":"","text":"Token:\\rzxywvutsrqponmlkjihg"}\n' "$BHEAD"  # gitleaks:allow (fake fixture for the scrub test)
} > "$BFTF"
CR_LEDGER="$BFT" bash "$LA" finding --batch-file "$BFTF"
check "batch mode exits 0 with mixed text/no-text rows" "$?" "0"
check "batch mode stores text" "$(L="$BFT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.finding_id==="bt-1");console.log(o.text)')" "- [bt-1]: batch claim [f:1]"
check "batch mode: no text key -> absent" "$(L="$BFT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.finding_id==="bt-2");console.log("text" in o)')" "false"
check "batch mode caps text to <=500 chars" "$(L="$BFT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.finding_id==="bt-3");console.log(o.text.length<=500)')" "true"
# HIMMEL-2078 CR round: --batch-file is critic-panel.sh's real call path
# (HIMMEL-2052) and bypasses the shell-side scrub entirely, so the node
# writer itself must scrub spec.text — not just flatten/cap it.
check "batch mode scrubs a secret in text" "$(L="$BFT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.finding_id==="bt-4");console.log(o.text.includes("AKIAABCDEFGHIJKLMNOP")+","+o.text.includes("[REDACTED]"))')" "false,true"  # gitleaks:allow (fake fixture)
check "batch mode scrubs a token split across an embedded newline" "$(L="$BFT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.finding_id==="bt-5");console.log(o.text.includes("apikeyvalue1234567890")+","+o.text.includes("[REDACTED]"))')" "false,true"  # gitleaks:allow (fake fixture)
check "batch mode scrubs a token split across a lone carriage return" "$(L="$BFT" node -e 'const o=require("fs").readFileSync(process.env.L,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.finding_id==="bt-6");console.log(o.text.includes("zxywvutsrqponmlkjihg")+","+o.text.includes("[REDACTED]"))')" "false,true"  # gitleaks:allow (fake fixture)

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
