#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; L="$HERE/lessons-sweep.sh"; B="$HERE/bug.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

root="$tmp/state"
mkdir -p "$root/epics/HIMMEL-1-a" "$root/standalones/HIMMEL-2-b"
a="$root/epics/HIMMEL-1-a"; b="$root/standalones/HIMMEL-2-b"
# Same resolved symptom in two items -> recurring candidate.
bash "$B" add --bugs "$a/bugs.md" --symptom "flaky timeout" >/dev/null
bash "$B" status --bugs "$a/bugs.md" --id BUG-1 --to resolved
bash "$B" add --bugs "$b/bugs.md" --symptom "flaky timeout" >/dev/null
bash "$B" status --bugs "$b/bugs.md" --id BUG-1 --to resolved
# A non-recurring wontfix bug.
bash "$B" add --bugs "$a/bugs.md" --symptom "unique glitch" >/dev/null   # BUG-2
bash "$B" status --bugs "$a/bugs.md" --id BUG-2 --to wontfix
# An open bug must NOT appear (only resolved/wontfix are lessons).
bash "$B" add --bugs "$b/bugs.md" --symptom "still open" >/dev/null      # BUG-2 open
# A CR finding in item a.
printf '%s\n' '## CR Findings' '### 2026-06-20 — HEAD abc (PR 1)' \
  '- 🟠 Important [k-1] f.sh:9 — unquoted var in trap (real) <!-- cr:abc:k-1 -->' > "$a/reviewer-notes.md"

out="$(bash "$L" --root "$root")"
check "recurring section present" "$(printf '%s' "$out" | grep -c '## Recurring (lesson candidates)')" "1"
check "recurring catches shared"  "$(printf '%s' "$out" | grep -c '^- flaky timeout  (in: ')" "1"
check "recurring lists both items" "$(printf '%s' "$out" | grep -c 'epics/HIMMEL-1-a, standalones/HIMMEL-2-b')" "1"
check "digest section present"    "$(printf '%s' "$out" | grep -c '## Digest')" "1"
check "digest lists wontfix bug"  "$(printf '%s' "$out" | grep -c 'unique glitch')" "1"
check "digest lists CR title"     "$(printf '%s' "$out" | grep -c 'unquoted var in trap')" "1"
check "open bug excluded"         "$(printf '%s' "$out" | grep -c 'still open')" "0"

# No recurrence -> no Recurring section, still a digest, rc 0.
root2="$tmp/s2"; mkdir -p "$root2/standalones/HIMMEL-9-z"
bash "$B" add --bugs "$root2/standalones/HIMMEL-9-z/bugs.md" --symptom "lonely" >/dev/null
bash "$B" status --bugs "$root2/standalones/HIMMEL-9-z/bugs.md" --id BUG-1 --to resolved
out2="$(bash "$L" --root "$root2")"; rc=$?
check "no-recur rc 0"          "$rc" "0"
check "no-recur omits section" "$(printf '%s' "$out2" | grep -c '## Recurring')" "0"
check "no-recur has digest"    "$(printf '%s' "$out2" | grep -c 'lonely')" "1"

# norm(): case + whitespace differences still recur (keystone of recurrence detection).
rootn="$tmp/norm"; mkdir -p "$rootn/epics/HIMMEL-1-a" "$rootn/standalones/HIMMEL-2-b"
bash "$B" add --bugs "$rootn/epics/HIMMEL-1-a/bugs.md" --symptom "Flaky   Timeout" >/dev/null
bash "$B" status --bugs "$rootn/epics/HIMMEL-1-a/bugs.md" --id BUG-1 --to resolved
bash "$B" add --bugs "$rootn/standalones/HIMMEL-2-b/bugs.md" --symptom "flaky timeout" >/dev/null
bash "$B" status --bugs "$rootn/standalones/HIMMEL-2-b/bugs.md" --id BUG-1 --to resolved
nout="$(bash "$L" --root "$rootn")"
check "norm: case/ws recurs" "$(printf '%s' "$nout" | grep -c '## Recurring (lesson candidates)')" "1"

# negative twin: symptoms differing after normalization do NOT recur.
rootnn="$tmp/nonorm"; mkdir -p "$rootnn/epics/HIMMEL-1-a" "$rootnn/standalones/HIMMEL-2-b"
bash "$B" add --bugs "$rootnn/epics/HIMMEL-1-a/bugs.md" --symptom "timeout A" >/dev/null
bash "$B" status --bugs "$rootnn/epics/HIMMEL-1-a/bugs.md" --id BUG-1 --to resolved
bash "$B" add --bugs "$rootnn/standalones/HIMMEL-2-b/bugs.md" --symptom "timeout B" >/dev/null
bash "$B" status --bugs "$rootnn/standalones/HIMMEL-2-b/bugs.md" --id BUG-1 --to resolved
nnout="$(bash "$L" --root "$rootnn")"
check "norm: distinct no recur" "$(printf '%s' "$nnout" | grep -c '## Recurring')" "0"

# CR title containing an inner " — " keeps the FULL title (split on the FIRST sep).
rootd="$tmp/dash"; mkdir -p "$rootd/epics/HIMMEL-1-a"
printf '%s\n' '## CR Findings' '### 2026-06-20 — HEAD abc (PR 1)' \
  '- 🟠 Important [k-1] f.sh:9 — title — with inner dash (real) <!-- cr:abc:k-1 -->' > "$rootd/epics/HIMMEL-1-a/reviewer-notes.md"
dout="$(bash "$L" --root "$rootd")"
check "cr title keeps inner dash" "$(printf '%s' "$dout" | grep -c 'title — with inner dash')" "1"

# reviewer-notes.md present but with NO "## CR Findings" section -> no cr digest lines, rc 0.
rootc="$tmp/nocr"; mkdir -p "$rootc/epics/HIMMEL-1-a"
printf '%s\n' '# Reviewer Notes' '' '## Human Feedback' '' 'some prose' > "$rootc/epics/HIMMEL-1-a/reviewer-notes.md"
cout="$(bash "$L" --root "$rootc")"; crc=$?
check "no-cr rc 0"               "$crc" "0"
check "no-cr: no cr digest lines" "$(printf '%s' "$cout" | grep -c '^- cr · ')" "0"

# Empty root -> digest placeholder, rc 0.
root3="$tmp/s3"; mkdir -p "$root3"
out3="$(bash "$L" --root "$root3")"; rc3=$?
check "empty rc 0"        "$rc3" "0"
check "empty placeholder" "$(printf '%s' "$out3" | grep -c '_No resolved bugs or CR findings yet._')" "1"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
