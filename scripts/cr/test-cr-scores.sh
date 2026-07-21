#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C intentional in check() and final assert
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CS="$HERE/cr-scores.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; L="$tmp/ledger.jsonl"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { echo "$2" | grep -qF "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { echo "$2" | grep -qF "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# ---------------------------------------------------------------------------
# Fixture: two models (alpha, beta) with known score distributions
# alpha: 12 findings: 8 agreed, 2 disproved, 1 conflict, 1 unaddressed
#        -> agreed%= 8/12 = 66.7%  (above 40 threshold -> no drop advice)
#        avail: 3 ok, 1 unavailable -> availability%= 3/4 = 75%
# beta:  11 findings: 3 agreed, 5 disproved, 2 conflict, 1 unaddressed
#        -> agreed%= 3/11 = 27.3%  (below 40 threshold, >=10 findings -> drop advice)
#        avail: 2 ok, 0 unavailable -> availability%= 2/2 = 100%
# ---------------------------------------------------------------------------
# We use 3 distinct heads (H1, H2, H3) to also exercise the window logic.

# alpha findings (H1/H2/H3) + beta findings (H1/H2/H3) + avail rows — one block
{
  # alpha: 8 agreed, 2 disproved, 1 conflict, 1 unaddressed (total 12)
  echo '{"kind":"finding","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-1","severity":"critical","file":"f","line":1,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:01Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-2","severity":"major","file":"f","line":2,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:02Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-3","severity":"minor","file":"f","line":3,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:03Z","branch":"b","head":"H1","model":"alpha","finding_id":"a-4","severity":"minor","file":"f","line":4,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:04Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-5","severity":"major","file":"f","line":5,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:05Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-6","severity":"major","file":"f","line":6,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:06Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-7","severity":"critical","file":"f","line":7,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:07Z","branch":"b","head":"H2","model":"alpha","finding_id":"a-8","severity":"minor","file":"f","line":8,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:08Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-9","severity":"major","file":"f","line":9,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:09Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-10","severity":"minor","file":"f","line":10,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:10Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-11","severity":"critical","file":"f","line":11,"verdict":"conflict"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:00:11Z","branch":"b","head":"H3","model":"alpha","finding_id":"a-12","severity":"minor","file":"f","line":12,"verdict":"unaddressed"}'
  # beta: 3 agreed, 5 disproved, 2 conflict, 1 unaddressed (total 11)
  echo '{"kind":"finding","ts":"2026-01-01T00:01:00Z","branch":"b","head":"H1","model":"beta","finding_id":"b-1","severity":"critical","file":"f","line":1,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:01Z","branch":"b","head":"H1","model":"beta","finding_id":"b-2","severity":"major","file":"f","line":2,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:02Z","branch":"b","head":"H1","model":"beta","finding_id":"b-3","severity":"minor","file":"f","line":3,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:03Z","branch":"b","head":"H2","model":"beta","finding_id":"b-4","severity":"major","file":"f","line":4,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:04Z","branch":"b","head":"H2","model":"beta","finding_id":"b-5","severity":"minor","file":"f","line":5,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:05Z","branch":"b","head":"H2","model":"beta","finding_id":"b-6","severity":"critical","file":"f","line":6,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:06Z","branch":"b","head":"H2","model":"beta","finding_id":"b-7","severity":"major","file":"f","line":7,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:07Z","branch":"b","head":"H3","model":"beta","finding_id":"b-8","severity":"minor","file":"f","line":8,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:08Z","branch":"b","head":"H3","model":"beta","finding_id":"b-9","severity":"critical","file":"f","line":9,"verdict":"conflict"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:09Z","branch":"b","head":"H3","model":"beta","finding_id":"b-10","severity":"major","file":"f","line":10,"verdict":"conflict"}'
  echo '{"kind":"finding","ts":"2026-01-01T00:01:10Z","branch":"b","head":"H3","model":"beta","finding_id":"b-11","severity":"minor","file":"f","line":11,"verdict":"unaddressed"}'
  # avail: alpha 3 ok + 1 unavailable; beta 2 ok
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"alpha","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H2","model":"alpha","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H3","model":"alpha","status":"unavailable"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H4","model":"alpha","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"beta","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H2","model":"beta","status":"ok"}'
  # usage (HIMMEL-485): codex 2 calls (est_total 1200 + 600 = 1800), alpha 1 call (400).
  # ts are LATER than every other record so per-head ts minima (and thus the window
  # ordering exercised by test 8) are unchanged by these rows.
  echo '{"kind":"usage","ts":"2026-01-01T00:02:00Z","branch":"b","head":"H1","model":"codex","prompt_chars":4000,"response_chars":800,"est_prompt_tokens":1000,"est_completion_tokens":200,"est_total_tokens":1200,"estimated":true}'
  echo '{"kind":"usage","ts":"2026-01-01T00:02:01Z","branch":"b","head":"H2","model":"codex","prompt_chars":2000,"response_chars":400,"est_prompt_tokens":500,"est_completion_tokens":100,"est_total_tokens":600,"estimated":true}'
  echo '{"kind":"usage","ts":"2026-01-01T00:02:02Z","branch":"b","head":"H1","model":"alpha","prompt_chars":1200,"response_chars":400,"est_prompt_tokens":300,"est_completion_tokens":100,"est_total_tokens":400,"estimated":true}'
} >> "$L"

# ── Run the script and capture output ──────────────────────────────────────
out="$(CR_LEDGER="$L" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" 2>&1)"

# 1. Per-model agreed% appears in output
# alpha: 8/12 = 66.7% -> rounds to 67%
contains "alpha agreed% contains 67" "$out" "67"
# beta: 3/11 = 27.3% -> look for "27" in beta row
contains "beta agreed% contains 27" "$out" "27"

# 2. Availability %: alpha= 3ok/(3ok+1unavail)=75%; beta=2ok/2ok=100%
contains "alpha avail% contains 75" "$out" "75"
contains "beta avail% contains 100" "$out" "100"

# 3. Drop advice fires for beta (27% < 40, 11 findings >= 10)
#    Assert the actual advice string, not just presence of "beta" anywhere.
echo "$out" | grep -qi "consider dropping beta" \
  && echo "ok - drop advice fires for beta" \
  || { echo "FAIL - drop advice fires for beta: [$out]"; fails=$((fails+1)); }

# 4. Drop advice does NOT fire for alpha (66% >= 40 threshold)
not_contains "no drop advice for alpha" "$out" "consider dropping alpha"

# 5. Empty ledger -> friendly message + exit 0
empty="$tmp/empty.jsonl"
touch "$empty"
empty_out="$(CR_LEDGER="$empty" bash "$CS" 2>&1)"
empty_rc=$?
check "empty ledger exit 0" "$empty_rc" "0"
contains "empty ledger friendly message" "$empty_out" "no critic scores"

# 6. Missing ledger -> friendly message + exit 0 (treated like empty)
missing_out="$(CR_LEDGER="$tmp/nonexistent.jsonl" bash "$CS" 2>&1)"
missing_rc=$?
check "missing ledger exit 0" "$missing_rc" "0"
contains "missing ledger friendly message" "$missing_out" "no critic scores"

# 7. Below-threshold: a model with 9 findings and low agreed% should NOT get drop advice
#    (CR_SCORES_MIN_N=10 -> need >=10 findings)
L2="$tmp/small.jsonl"
for i in 1 2 3 4 5 6 7 8 9; do
  echo "{\"kind\":\"finding\",\"ts\":\"2026-01-01T00:00:0${i}Z\",\"branch\":\"b\",\"head\":\"H1\",\"model\":\"gamma\",\"finding_id\":\"g-${i}\",\"severity\":\"minor\",\"file\":\"f\",\"line\":${i},\"verdict\":\"disproved\"}" >> "$L2"
done
small_out="$(CR_LEDGER="$L2" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" 2>&1)"
not_contains "no drop advice for gamma (below CR_SCORES_MIN_N)" "$small_out" "consider dropping gamma"

# 8. Window narrowing: --window 2 uses only the last 2 distinct heads.
#    The fixture has 4 distinct heads in findings+avail (H1-H4); last 2 = H3, H4.
#    Alpha has findings only in H3 (4 findings) and none in H4 -> windowed total=4.
#    All-time alpha total is 12. The two tables must show different totals.
#    Both "4" (windowed) and "12" (all-time) must appear in the combined output.
win_out="$(CR_LEDGER="$L" CR_SCORES_DROP_BELOW=40 CR_SCORES_MIN_N=10 bash "$CS" --window 2 2>&1)"
contains "window section header present" "$win_out" "Last-2-PRs"
# All-time alpha total = 12; windowed alpha total = 4 (only H3 has alpha findings in window).
contains "all-time alpha total 12 appears" "$win_out" "12"
# "4" appears in the windowed table (alpha windowed total) proving narrowing occurred.
# We confirm via the agreed% in the windowed section: alpha H3 has 0 agreed -> "0%"
# which differs from all-time alpha 67%. Assert "0%" appears (windowed agreed%).
contains "windowed alpha shows different agreed pct" "$win_out" "0%"

# 9. Usage section (HIMMEL-485): per-model est tokens + cumulative.
contains "usage section header present" "$out" "Usage (estimated tokens"
contains "usage codex row present" "$out" "codex"
contains "usage codex est_total 1800" "$out" "1800"
contains "usage cumulative line (2200 over 3)" "$out" "cumulative: est_total=2200 over 3"

# 9b. A usage-ONLY model (codex has no finding/avail records) must NOT appear as a
#     phantom zero row in the score tables — it should show ONLY in the Usage
#     section. Both score tables + the usage table start a codex line at col 0, so
#     before the fix codex would start 3 lines; after, exactly 1 (the usage row).
check "usage-only model absent from score tables" "$(echo "$out" | grep -c '^codex')" "1"

# 10. No usage section when the ledger has no usage records (output unchanged).
not_contains "no usage section without usage records" "$small_out" "Usage (estimated tokens"

# 11. cr-scores tolerates a usage record MISSING est_* fields (older/hand-edited
#     schema): the Number()||0 guards must render numeric zeros, never NaN.
L3="$tmp/partial-usage.jsonl"
echo '{"kind":"usage","ts":"2026-01-01T00:00:00Z","branch":"b","head":"H1","model":"codex"}' > "$L3"
partial_out="$(CR_LEDGER="$L3" bash "$CS" 2>&1)"
not_contains "partial usage record produces no NaN" "$partial_out" "NaN"
contains "partial usage record cumulative is 0" "$partial_out" "cumulative: est_total=0 over 1"

# ── WS4 (HIMMEL-414): artifact/perspective segmenting reader ─────────────────
# Perspective filter: a dedicated single-model ledger so percentages are unambiguous.
L4="$tmp/persp-scores.jsonl"
{
  echo '{"kind":"finding","ts":"2026-02-01T00:00:00Z","branch":"b","head":"MH1","model":"mix","finding_id":"x-1","severity":"major","file":"f","line":1,"verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:01Z","branch":"b","head":"MH2","model":"mix","finding_id":"x-2","severity":"major","file":"f","line":2,"verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:02Z","branch":"b","head":"MH3","model":"mix","finding_id":"x-3","severity":"major","file":"f","line":3,"verdict":"agreed","artifact":"diff","perspective":"on"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:03Z","branch":"b","head":"MH4","model":"mix","finding_id":"x-4","severity":"major","file":"f","line":4,"verdict":"disproved","artifact":"diff","perspective":"on"}'
} >> "$L4"
mix_all="$(CR_LEDGER="$L4" bash "$CS" 2>&1)"
contains "mix unfiltered agreed 75" "$mix_all" "75%"
mix_on="$(CR_LEDGER="$L4" bash "$CS" --perspective on 2>&1)"
contains "mix perspective-on agreed 50" "$mix_on" "50%"
not_contains "mix perspective-on excludes off records (no 75)" "$mix_on" "75%"
mix_off="$(CR_LEDGER="$L4" bash "$CS" --perspective off 2>&1)"
contains "mix perspective-off agreed 100" "$mix_off" "100%"
# Artifact filter: mixed artifact records, single model.
L5="$tmp/artifact-scores.jsonl"
{
  echo '{"kind":"finding","ts":"2026-02-01T00:00:00Z","branch":"b","head":"AH1","model":"amix","finding_id":"y-1","severity":"major","file":"f","line":1,"verdict":"agreed","artifact":"diff","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:01Z","branch":"b","head":"AH2","model":"amix","finding_id":"y-2","severity":"major","file":"f","line":2,"verdict":"agreed","artifact":"spec","perspective":"off"}'
  echo '{"kind":"finding","ts":"2026-02-01T00:00:02Z","branch":"b","head":"AH3","model":"amix","finding_id":"y-3","severity":"major","file":"f","line":3,"verdict":"disproved","artifact":"spec","perspective":"off"}'
} >> "$L5"
spec_out="$(CR_LEDGER="$L5" bash "$CS" --artifact spec 2>&1)"
contains "artifact-spec agreed 50" "$spec_out" "50%"
# Legacy records (no perspective field) coerce to off: --perspective off shows them, on hides them.
off_legacy="$(CR_LEDGER="$L" bash "$CS" --perspective off 2>&1)"
contains "legacy records coerce to perspective off (alpha 67 present)" "$off_legacy" "67"
on_legacy="$(CR_LEDGER="$L" bash "$CS" --perspective on 2>&1)"
not_contains "legacy records absent from perspective on (no 67)" "$on_legacy" "67"

# ── HIMMEL-1176: Unavailability breakdown (additive, reason-capture) ────────
# 12. A reason-less ledger (every fixture used above) must render NO
#     "Unavailability breakdown" section — output stays byte-identical to
#     pre-HIMMEL-1176 (same precedent as the Usage section: rendered only
#     when the underlying record type is present).
not_contains "no breakdown section on a reason-less ledger" "$out" "Unavailability breakdown"

# 13. A ledger WITH avail.reason fields renders the breakdown table, grouped
#     per (model, reason), and leaves the existing tables untouched.
L6="$tmp/reason-scores.jsonl"
{
  echo '{"kind":"avail","ts":"2026-03-01T00:00:00Z","branch":"b","head":"RH1","model":"glm","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:01Z","branch":"b","head":"RH2","model":"glm","status":"unavailable","reason":"quota-5h"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:02Z","branch":"b","head":"RH3","model":"glm","status":"unavailable","reason":"quota-5h"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:03Z","branch":"b","head":"RH4","model":"glm","status":"unavailable","reason":"auth"}'
  echo '{"kind":"avail","ts":"2026-03-01T00:00:04Z","branch":"b","head":"RH5","model":"codex","status":"unavailable","reason":"timeout"}'
} >> "$L6"
reason_out="$(CR_LEDGER="$L6" bash "$CS" 2>&1)"
contains "breakdown section header present" "$reason_out" "Unavailability breakdown"
contains "breakdown counts glm/quota-5h=2" "$reason_out" "glm                     quota-5h          2"
contains "breakdown counts glm/auth=1" "$reason_out" "glm                     auth              1"
contains "breakdown counts codex/timeout=1" "$reason_out" "codex                   timeout           1"
# The pre-existing avail% table must be untouched by the new reason field
# (glm: 1 ok / 4 total = 25%).
contains "existing avail table unaffected by reason field (glm 25%)" "$reason_out" "25%"

# 14. A record whose reason is an EMPTY string must NOT be counted (mirrors
#     the "absent, not empty" rule enforced by ledger-append.sh).
L7="$tmp/reason-empty.jsonl"
echo '{"kind":"avail","ts":"2026-03-01T00:00:00Z","branch":"b","head":"EH1","model":"m","status":"unavailable","reason":""}' > "$L7"
empty_reason_out="$(CR_LEDGER="$L7" bash "$CS" 2>&1)"
not_contains "empty-string reason does not trigger breakdown section" "$empty_reason_out" "Unavailability breakdown"

# ── Final ──────────────────────────────────────────────────────────────────
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
