#!/usr/bin/env bash
# test-autocompact-ab.sh - HIMMEL-5193: scripts/eval/autocompact-ab.py over the
# fixture legs (one 200k control with a compaction, one 400k arm with a
# handoff and a second READY, one unwrapped leg). Linux-only like the console kit.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/autocompact-ab.py"
FX="$HERE/fixtures/autocompact-ab"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/autocompact-ab.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi; }

ctl="$FX/docs/HIMMEL-9001-N901-ctl-2026-10-11.md"
trt="$FX/docs/HIMMEL-9002-N902-trt-2026-10-11.md"
opn="$FX/docs/HIMMEL-9003-N903-open-2026-10-11.md"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N901","arm":"200k"},{"doc":"%s","label":"N902","arm":"400k"},{"doc":"%s","label":"N903","arm":"400k"}]}\n' "$ctl" "$trt" "$opn" > "$tmp/m.json"

out="$tmp/out.json"
python3 -I "$SUT" --manifest "$tmp/m.json" --projects "$FX/projects" --json > "$out" 2>"$tmp/err"; rc=$?
check "exit 0" 0 "$rc"
check "unwrapped leg is left out (2 legs)" 2 "$(jq '.legs | length' "$out")"
c='.legs[] | select(.leg | startswith("HIMMEL-9001"))'
t='.legs[] | select(.leg | startswith("HIMMEL-9002"))'
check "ctl arm from the manifest" 200k "$(jq -r "$c | .arm" "$out")"
check "ctl calls deduped by message id" 3 "$(jq "$c | .calls" "$out")"
check "ctl cache_read" 3500 "$(jq "$c | .cache_read" "$out")"
check "ctl cache_create" 500 "$(jq "$c | .cache_create" "$out")"
check "ctl uncached" 4 "$(jq "$c | .uncached" "$out")"
check "ctl cost_eq (4 + 350 + 625 + 1500)" 2479 "$(jq "$c | .cost_eq" "$out")"
check "ctl one compaction" 1 "$(jq "$c | .compactions | length" "$out")"
check "ctl compaction level" 170000 "$(jq "$c | .compactions[0].tokens" "$out")"
check "ctl wall-clock seconds" 1800 "$(jq "$c | .wall_s" "$out")"
check "ctl mean output per turn" 100.0 "$(jq "$c | .mean_out_per_turn" "$out")"
check "ctl CI first try" yes "$(jq -r "$c | .ci_first_try" "$out")"
check "ctl pr" 101 "$(jq -r "$c | .pr" "$out")"
check "ctl handoffs" 0 "$(jq "$c | .handoffs" "$out")"
check "trt arm from the manifest" 400k "$(jq -r "$t | .arm" "$out")"
python3 -I "$SUT" --doc "$trt" --projects "$FX/projects" --json > "$tmp/b.json" 2>/dev/null
check "brief ruling line alone is not evidence of the arm" unlabelled "$(jq -r '.legs[0].arm' "$tmp/b.json")"
cp "$FX/docs/HIMMEL-9002-N902b-trt-RESUME.md" "$tmp/HIMMEL-9002-N9020-other-RESUME.md"
cp "$trt" "$tmp/HIMMEL-9002-N902-trt-2026-10-11.md"; cp "$FX/docs/HIMMEL-9002-N902b-trt-RESUME.md" "$tmp/"
python3 -I "$SUT" --doc "$tmp/HIMMEL-9002-N902-trt-2026-10-11.md" --projects "$FX/projects" --all --json > "$tmp/r.json" 2>/dev/null
check "N902 RESUME glob does not collect N9020 docs" 1 "$(jq '.legs[0].handoffs' "$tmp/r.json")"
check "trt compactions" 0 "$(jq "$t | .compactions | length" "$out")"
check "trt handoffs (RESUME doc)" 1 "$(jq "$t | .handoffs" "$out")"
check "trt calls include the RESUME session" 3 "$(jq "$t | .calls" "$out")"
check "trt transcripts (own + RESUME session)" 2 "$(jq "$t | .transcripts" "$out")"
check "trt uncached" 4 "$(jq "$t | .uncached" "$out")"
check "trt cache_read" 14000 "$(jq "$t | .cache_read" "$out")"
check "trt cost_eq (4 + 1400 + 1250 + 3500)" 6154 "$(jq "$t | .cost_eq" "$out")"
check "trt mean output per turn" 233.3 "$(jq "$t | .mean_out_per_turn" "$out")"
check "trt CI first try is no (two READY)" no "$(jq -r "$t | .ci_first_try" "$out")"
check "trt review rounds" 1 "$(jq "$t | .review_rounds" "$out")"
check "summary has both arms" 2 "$(jq '.summary | length' "$out")"
check "summary 200k mean compactions" 1.0 "$(jq '.summary[] | select(.arm=="200k") | .compactions' "$out")"
check "summary 400k mean compactions" 0.0 "$(jq '.summary[] | select(.arm=="400k") | .compactions' "$out")"

# no arm in the manifest and no brief line: unlabelled, not in the summary
python3 -I "$SUT" --doc "$ctl" --projects "$FX/projects" --json > "$tmp/u.json" 2>/dev/null
check "unlabelled leg is reported as unlabelled" unlabelled "$(jq -r '.legs[0].arm' "$tmp/u.json")"
check "unlabelled leg is not in the summary" 0 "$(jq '.summary | length' "$tmp/u.json")"

# --all includes the unwrapped leg
python3 -I "$SUT" --manifest "$tmp/m.json" --projects "$FX/projects" --all --json > "$tmp/a.json" 2>/dev/null
check "--all includes the unwrapped leg" 3 "$(jq '.legs | length' "$tmp/a.json")"
check "--all: transcript-less leg is unmeasured, not averaged" "1 1" "$(jq -r '.summary[] | select(.arm=="400k") | "\(.legs) \(.unmeasured)"' "$tmp/a.json")"

# text mode prints the arm summary table; no input is a usage error
python3 -I "$SUT" --manifest "$tmp/m.json" --projects "$FX/projects" > "$tmp/t.txt" 2>/dev/null
check "text report carries the arm summary" 1 "$(grep -c '^arm summary' "$tmp/t.txt")"
python3 -I "$SUT" >/dev/null 2>&1; rc=$?
check "no legs is a usage error (rc 2)" 2 "$rc"

if [ "$fails" -eq 0 ]; then echo "PASS - test-autocompact-ab.sh"; exit 0; fi
echo "FAIL - test-autocompact-ab.sh ($fails failure(s))"; exit 1
