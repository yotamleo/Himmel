#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C intentional in check() and final assert
# Test harness for cr-tune.sh (HIMMEL-978)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/cr-tune.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0

check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { echo "$2" | grep -qF "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { echo "$2" | grep -qF "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# ---------------------------------------------------------------------------
# Fixture: Task-1 test data as specified in the brief
# ---------------------------------------------------------------------------
{
  echo '{"kind":"finding","ts":"2026-07-01T10:00:00Z","branch":"b1","head":"aaaa111","model":"modelA","finding_id":"modelA-1","severity":"imp","file":"scripts/foo.sh","line":10,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-07-01T10:01:00Z","branch":"b1","head":"aaaa111","model":"modelA","finding_id":"modelA-2","severity":"imp","file":"scripts/foo.sh","line":20,"verdict":"agreed"}'
  echo '{"kind":"finding","ts":"2026-07-01T10:02:00Z","branch":"b1","head":"aaaa111","model":"modelA","finding_id":"modelA-3","severity":"crit","file":"scripts/bar.sh","line":5,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-07-02T10:00:00Z","branch":"b2","head":"bbbb222","model":"modelB","finding_id":"modelB-1","severity":"crit","file":"scripts/test-foo.sh","line":1,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-07-02T10:01:00Z","branch":"b2","head":"bbbb222","model":"modelB","finding_id":"modelB-2","severity":"crit","file":"scripts/test-bar.sh","line":2,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-07-02T10:02:00Z","branch":"b2","head":"bbbb222","model":"modelB","finding_id":"modelB-3","severity":"crit","file":"scripts/test-baz.sh","line":3,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-07-03T10:00:00Z","branch":"b3","head":"cccc333","model":"modelB","finding_id":"modelB-r2-1","severity":"imp","file":"scripts/check-ci.sh","line":9,"verdict":"disproved"}'
  echo '{"kind":"finding","ts":"2026-07-03T10:01:00Z","branch":"b3","head":"cccc333","model":"modelA","finding_id":"modelA-4","severity":"sug","file":"docs/x.md","line":1,"verdict":"unaddressed"}'
  echo '{"kind":"avail","ts":"2026-07-01T10:00:00Z","branch":"b1","head":"aaaa111","model":"modelA","status":"ok"}'
  echo '{"kind":"avail","ts":"2026-07-02T10:00:00Z","branch":"b2","head":"bbbb222","model":"modelA","status":"unavailable"}'
  echo '{"kind":"avail","ts":"2026-07-02T10:00:01Z","branch":"b2","head":"bbbb222","model":"modelB","status":"ok"}'
  echo '{"kind":"finding","ts":"2026-07-01T10:03:00Z","branch":"b1","head":"aaaa111","model":"modelC","finding_id":"modelC-1","severity":"imp","file":"scripts/qux.sh","line":7,"verdict":"n"}'
  echo '{"kind":"finding","ts":"2026-07-01T10:04:00Z","branch":"b1","head":"aaaa111","model":"modelC","finding_id":"modelC-r10-1","severity":"imp","file":"scripts/qux.sh","line":8,"verdict":"agreed"}'
  echo '{"kind":"usage","ts":"2026-07-01T10:00:00Z","model":"modelA","est_tokens":123}'
  echo 'not-json-garbage-line'
} > "$tmp/ledger.jsonl"

# ── Run the script and capture output ──────────────────────────────────────
out="$(CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" 2>&1)"
rc=$?

# ── Task-1 Assertions ─────────────────────────────────────────────────────
# 1. modelA row: n=4, agreed=2, disproved=1, unaddressed=1, avail 1/2 ok
contains "modelA row present" "$out" "modelA"
contains "modelA n=4" "$out" "modelA: n=4"
contains "modelA agreed=2" "$out" "agreed=2"
contains "modelA disproved=1" "$out" "disproved=1"
contains "modelA unaddressed=1" "$out" "unaddressed=1"
contains "modelA avail 1/2" "$out" "avail=1/2"

# 2. modelB row: n=4, disproved=4 (100%)
contains "modelB row present" "$out" "modelB"
contains "modelB n=4" "$out" "modelB: n=4"
contains "modelB disproved=4" "$out" "disproved=4"
contains "modelB disproved 100%" "$out" "disproved=4 (100%)"

# 3. severity-calibration section flags modelB crit as 3/3 disproved (100%)
#    (the flag threshold is: n>=3 AND disproved >=80%)
contains "severity calibration section present" "$out" "== severity calibration flags"
contains "modelB crit flag present" "$out" "modelB crit:"
contains "modelB crit 3/3 disproved" "$out" "3/3 disproved (100%)"

# 4. severity-calibration section does NOT flag modelA
#    (modelA crit n=1, below n>=3 threshold)
not_contains "modelA crit not flagged" "$out" "modelA crit:"

# 5. Malformed line + usage rows ignored without error (rc=0)
check "exit code 0" "$rc" "0"

# ── Task-2 Assertions ─────────────────────────────────────────────────────
# 6. clusters section: modelB test-fixture cluster n=3, with the three citations
contains "clusters section present" "$out" "== disproved clusters"
contains "modelB test-fixture cluster n=3" "$out" "modelB test-fixture: 3 disproved"
contains "modelB test-fixture citation test-foo.sh:1" "$out" "scripts/test-foo.sh:1"
contains "modelB test-fixture citation test-bar.sh:2" "$out" "scripts/test-bar.sh:2"
contains "modelB test-fixture citation test-baz.sh:3" "$out" "scripts/test-baz.sh:3"

# 7. clusters section does NOT contain a modelA cluster (only 1 disproved row — below MIN_CITE)
not_contains "modelA cluster not present (below MIN_CITE)" "$out" "modelA scripts:"

# 8. re-litigation section: modelB with 1 round-marker finding (modelB-r2-1), disproved
contains "re-litigation section present" "$out" "== re-litigation signals"
contains "modelB re-litigation 1 round-marker, 1 disproved" "$out" "modelB: 1 round-marker findings, 1 disproved"
contains "modelB re-litigation citation modelB-r2-1" "$out" "modelB-r2-1"

# 9. --min-cite 1: modelA's single disproved row now appears as a modelA scripts cluster
out_mincite1="$(CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --min-cite 1 2>&1)"
contains "--min-cite 1: modelA scripts cluster n=1" "$out_mincite1" "modelA scripts: 1 disproved"

# 10. --json completeness: all four arrays populated
CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --json | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); if(!(j.models.length&&j.calibration.length&&j.clusters.length&&j.relitigation.length)) process.exit(1)'
rc_json=$?
check "--json completeness (all four arrays populated)" "$rc_json" "0"

# 11. empty ledger: message + rc=0
: > "$tmp/empty.jsonl"
out_empty="$(CR_LEDGER="$tmp/empty.jsonl" bash "$SCRIPT" 2>&1)"
rc_empty=$?
contains "empty ledger message" "$out_empty" "no critic scores recorded yet"
check "empty ledger rc=0" "$rc_empty" "0"

# 12. usage errors: --bogus rc=2, --window (missing arg) rc=2
CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --bogus >/dev/null 2>&1
rc_bogus=$?
check "--bogus rc=2" "$rc_bogus" "2"

CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --window >/dev/null 2>&1
rc_window_missing=$?
check "--window (missing arg) rc=2" "$rc_window_missing" "2"

# 13. --window 1 on the fixture: only head cccc333 rows counted (modelA n=1, modelB n=1)
out_window1="$(CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --window 1 2>&1)"
contains "--window 1: modelA n=1" "$out_window1" "modelA: n=1"
contains "--window 1: modelB n=1" "$out_window1" "modelB: n=1"

# ── Task-2 hardening assertions (coderabbit round 1) ──────────────────────
# 14. verdict whitelist: modelC's verdict:"n" row counts in n= totals but must
#     not mutate any accumulator field (unguarded m[f.verdict]++ would bump n twice)
contains "verdict whitelist: bogus verdict counts in n only" "$out" "modelC: n=2 agreed=1 (50%) disproved=0 (0%) conflict=0 unaddressed=0"

# 15. round-marker regex detects -r10- (two-digit rounds)
contains "-r10- round marker detected" "$out" "modelC: 1 round-marker findings, 0 disproved"
contains "-r10- citation present" "$out" "modelC-r10-1"

# 16. numeric arg validation: --window abc rc=2, --min-cite -1 rc=2
CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --window abc >/dev/null 2>&1
rc_window_abc=$?
check "--window abc rc=2" "$rc_window_abc" "2"

CR_LEDGER="$tmp/ledger.jsonl" bash "$SCRIPT" --min-cite -1 >/dev/null 2>&1
rc_mincite_neg=$?
check "--min-cite -1 rc=2" "$rc_mincite_neg" "2"

# ── END ─────────────────────────────────────────────────────────────────────
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
