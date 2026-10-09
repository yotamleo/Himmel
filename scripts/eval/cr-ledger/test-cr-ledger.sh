#!/usr/bin/env bash
# scripts/eval/cr-ledger/test-cr-ledger.sh - suite for the CR-ledger eval
# (HIMMEL-4482): the amend fold, the cutoff, the critic join, re-raise and
# deferral-class counts, the seeded sample and the coded-sample check, all on
# a fixture ledger. No model call, never the live ledger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="$HERE/cr_ledger_eval.py"
FIX="$HERE/fixtures/ledger.jsonl"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cr-ledger-test.XXXXXX")" || { echo "test-cr-ledger: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Never the live ledger, whatever a case forgets to pass.
export CR_LEDGER="$TMP/never.jsonl"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-cr-ledger: python3 not on PATH"; exit 0; }

CUT=2026-09-10T00:00:00Z
# jget <json-file> <a/b/c> - one value from the --json output.
jget() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$1" "$2"; }

python3 "$EVAL" --ledger "$FIX" --until "$CUT" --json > "$TMP/out.json" 2> "$TMP/err"; rc=$?
eq "json: exit 0" "$rc" "0"
eq "json: findings up to the cutoff" "$(jget "$TMP/out.json" findings)" "6"
eq "json: a malformed line is counted, not fatal" "$(jget "$TMP/out.json" malformed)" "1"
eq "fold: gpt-x total" "$(jget "$TMP/out.json" critics/codex:gpt-x/n)" "4"
eq "fold: fixed counts as agreed" "$(jget "$TMP/out.json" critics/codex:gpt-x/agreed)" "1"
eq "fold: gpt-x disproved" "$(jget "$TMP/out.json" critics/codex:gpt-x/disproved)" "2"
eq "fold: gpt-x deferred" "$(jget "$TMP/out.json" critics/codex:gpt-x/deferred)" "1"
eq "fold: precision = agreed / (agreed + disproved)" "$(jget "$TMP/out.json" critics/codex:gpt-x/precision)" "0.3333"
eq "join: a different responding model is a different critic" "$(jget "$TMP/out.json" critics/codex:gpt-y/agreed)" "1"
eq "cutoff: an amend after the cutoff is ignored" "$(jget "$TMP/out.json" critics/codex:gpt-y/disproved)" "0"
eq "join: no avail row leaves the slug alone" "$(jget "$TMP/out.json" critics/claude/unadjudicated)" "1"
eq "ci: one PR cannot vary, so no interval" "$(jget "$TMP/out.json" critics/codex:gpt-x/precision_ci)" "null"
eq "reraise: a fingerprint raised at two heads of a branch" "$(jget "$TMP/out.json" reraise/reraised)" "1"
eq "reraise: fingerprinted findings" "$(jget "$TMP/out.json" reraise/fingerprinted)" "3"
eq "deferred: fu_class tally" "$(jget "$TMP/out.json" deferred_class/polish)" "1"
eq "severity: crit row folded" "$(jget "$TMP/out.json" severity/critical/deferred)" "1"
eq "critic x severity: gpt-x suggestions" "$(jget "$TMP/out.json" critic_severity/codex:gpt-x/suggestion/n)" "2"

python3 "$EVAL" --ledger "$FIX" > "$TMP/all.json" --json 2>/dev/null
eq "cutoff: without --until the late finding counts" "$(jget "$TMP/all.json" findings)" "7"

out="$(python3 "$EVAL" --ledger "$FIX" --until "$CUT" 2>&1)"
has "table: a row per critic" "$out" "codex:gpt-x"
has "table: the cutoff is printed" "$out" "$CUT"

python3 "$EVAL" --ledger "$FIX" --until "$CUT" --sample 5 --seed 7 > "$TMP/s1" 2>/dev/null
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --sample 5 --seed 7 > "$TMP/s2" 2>/dev/null
eq "sample: only disproved findings" "$(wc -l < "$TMP/s1" | tr -d ' ')" "2"
eq "sample: seeded, so repeatable" "$(cmp -s "$TMP/s1" "$TMP/s2" && echo same)" "same"
has "sample: carries the reason for the coder" "$(cat "$TMP/s1")" "by design"

ids="$(python3 -c 'import json,sys; print(" ".join(json.loads(l)["id"] for l in open(sys.argv[1])))' "$TMP/s1")"
read -r id1 id2 <<< "$ids"
{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-x\tintent-blind\tx\n' "$id1"; printf '%s\tcodex:gpt-x\tre-raise\ty\n' "$id2"; } > "$TMP/coded.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/coded.tsv" --json > "$TMP/c.json" 2>"$TMP/cerr"; rc=$?
eq "coded: a valid sample is accepted" "$rc" "0"
eq "coded: class counts" "$(jget "$TMP/c.json" taxonomy/counts/re-raise)" "1"
eq "coded: coded total" "$(jget "$TMP/c.json" taxonomy/n)" "2"

{ printf 'id\tcritic\tclass\tnote\n'; printf 'deadbeef0000\tcodex:gpt-x\tintent-blind\tx\n'; } > "$TMP/bad1.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad1.tsv" >/dev/null 2>&1; rc=$?
eq "coded: an id that is not a disproved finding is refused" "$rc" "2"
{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-x\tnot-a-class\tx\n' "$id1"; } > "$TMP/bad2.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad2.tsv" >/dev/null 2>&1; rc=$?
eq "coded: an undeclared class is refused" "$rc" "2"
{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-y\tintent-blind\tx\n' "$id1"; } > "$TMP/bad3.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad3.tsv" >/dev/null 2>&1; rc=$?
eq "coded: a critic that does not match the ledger is refused" "$rc" "2"

{ printf 'id\tcritic\tclass\tnote\n'; printf '%s\tcodex:gpt-x\tintent-blind\tx\n' "$id1" "$id1"; } > "$TMP/bad4.tsv"
python3 "$EVAL" --ledger "$FIX" --until "$CUT" --coded "$TMP/bad4.tsv" >/dev/null 2>"$TMP/err4"; rc=$?
eq "coded: a duplicate finding id is refused" "$rc" "2"
has "coded: the duplicate is named" "$(cat "$TMP/err4")" "duplicate"

python3 "$EVAL" --ledger "$FIX" --until "$CUT" --sample -1 >/dev/null 2>&1; rc=$?
eq "sample: a negative N is refused" "$rc" "2"

# A fractional-second ts sorts before the whole second as a string, not as a time.
printf '%s\n' '{"kind":"finding","ts":"2026-10-06T20:00:00.500Z","branch":"feat/c","head":"h5","model":"codex","finding_id":"codex-1","severity":"imp","verdict":"","text":"late"}' > "$TMP/frac.jsonl"
python3 "$EVAL" --ledger "$TMP/frac.jsonl" --until 2026-10-06T20:00:00Z --json > "$TMP/frac.json" 2>/dev/null
eq "cutoff: a fractional second after the cut is a time, not a string" "$(jget "$TMP/frac.json" findings)" "0"
python3 "$EVAL" --ledger "$TMP/frac.jsonl" --until 2026-10-06T20:00:01Z --json > "$TMP/frac.json" 2>/dev/null
eq "cutoff: the same finding before a later cut counts" "$(jget "$TMP/frac.json" findings)" "1"
python3 "$EVAL" --ledger "$FIX" --until not-a-time >/dev/null 2>&1; rc=$?
eq "cutoff: an unparseable --until is refused" "$rc" "2"

python3 "$EVAL" --ledger "$TMP/absent.jsonl" >/dev/null 2>&1; rc=$?
eq "usage: a missing ledger is an error" "$rc" "2"

echo
echo "test-cr-ledger: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
