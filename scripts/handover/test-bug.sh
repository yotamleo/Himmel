#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; B="$HERE/bug.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
F="$tmp/bugs.md"
seed(){ printf '%s\n' '---' 'template_version: 2' '---' '# Bug Log — Task #1 Demo' '' > "$F"; }

# add: first bug -> BUG-1, status open, body skeleton present, id echoed.
seed
id1="$(bash "$B" add --bugs "$F" --symptom "race on resume")"
check "add: echoes BUG-1"       "$id1" "BUG-1"
check "add: heading present"     "$(grep -c '^### BUG-1 — race on resume <!-- status: open -->' "$F")" "1"
check "add: symptom field"       "$(grep -c '^- \*\*Symptom:\*\* race on resume' "$F")" "1"
check "add: fixes-tried field"   "$(grep -c '^- \*\*Fixes tried:\*\*' "$F")" "1"

# add: second bug -> BUG-2 (sequential).
id2="$(bash "$B" add --bugs "$F" --symptom "dup CR entry")"
check "add: echoes BUG-2"        "$id2" "BUG-2"
check "add: two headings"        "$(grep -c '^### BUG-' "$F")" "2"

# seq must use max+1, not count: removing the lower id still yields max+1.
# (simulate by adding a high id by hand, then add -> next = high+1)
printf '%s\n' '### BUG-9 — manual <!-- status: open -->' >> "$F"
id3="$(bash "$B" add --bugs "$F" --symptom "after gap")"
check "add: next = max+1 (BUG-10)" "$id3" "BUG-10"

# seed-if-missing: item dir exists, bugs.md absent -> create + add.
mkdir -p "$tmp/item"; G="$tmp/item/bugs.md"
idg="$(bash "$B" add --bugs "$G" --symptom "fresh")"
check "seed: file created"       "$( [ -f "$G" ] && echo yes )" "yes"
check "seed: BUG-1 echoed"       "$idg" "BUG-1"
check "seed: has title"          "$(grep -c '^# Bug Log' "$G")" "1"

# missing parent dir -> exit 2, no stray file.
bash "$B" add --bugs "$tmp/nodir/bugs.md" --symptom x 2>/dev/null
check "missing parent -> rc 2"   "$?" "2"
check "no stray file"            "$( [ -e "$tmp/nodir/bugs.md" ] && echo bad || echo ok )" "ok"

# fix: append a FAILED then a WORKED outcome under the right bug.
seed
bash "$B" add --bugs "$F" --symptom "alpha" >/dev/null   # BUG-1
bash "$B" add --bugs "$F" --symptom "beta"  >/dev/null   # BUG-2
bash "$B" fix --bugs "$F" --id BUG-2 --outcome FAILED --note "bumped timeout"
bash "$B" fix --bugs "$F" --id BUG-2 --outcome WORKED --note "added mutex"
check "fix: FAILED line present"  "$(grep -c -- '- bumped timeout → FAILED' "$F")" "1"
check "fix: WORKED line present"  "$(grep -c -- '- added mutex → WORKED' "$F")" "1"

# fix lands under BUG-2, not BUG-1: the WORKED line is after the BUG-2 heading.
ln_b2=$(grep -n '^### BUG-2 — ' "$F" | head -1 | cut -d: -f1)
ln_fx=$(grep -n -- '- added mutex → WORKED' "$F" | head -1 | cut -d: -f1)
check "fix: under correct bug"   "$( [ "$ln_fx" -gt "$ln_b2" ] && echo yes )" "yes"

# anchor: BUG-1 must NOT match BUG-12 (prefix-collision guard).
printf '%s\n' '### BUG-12 — twelfth <!-- status: open -->' '- **Fixes tried:**' >> "$F"
bash "$B" fix --bugs "$F" --id BUG-1 --outcome FAILED --note "only one"
ln_b12=$(grep -n '^### BUG-12 — ' "$F" | head -1 | cut -d: -f1)
ln_one=$(grep -n -- '- only one → FAILED' "$F" | head -1 | cut -d: -f1)
check "fix: BUG-1 not under BUG-12" "$( [ "$ln_one" -lt "$ln_b12" ] && echo yes )" "yes"

# unknown id -> rc 3 (graceful).
bash "$B" fix --bugs "$F" --id BUG-99 --outcome FAILED --note nope 2>/dev/null
check "fix: unknown id -> rc 3"   "$?" "3"

# bad outcome -> rc 2.
bash "$B" fix --bugs "$F" --id BUG-1 --outcome MAYBE --note x 2>/dev/null
check "fix: bad outcome -> rc 2"  "$?" "2"

# status: flip BUG-1 open -> resolved without touching BUG-2.
seed
bash "$B" add --bugs "$F" --symptom "gamma" >/dev/null   # BUG-1
bash "$B" add --bugs "$F" --symptom "delta" >/dev/null   # BUG-2
bash "$B" status --bugs "$F" --id BUG-1 --to resolved
check "status: BUG-1 resolved"   "$(grep -c '^### BUG-1 — gamma <!-- status: resolved -->' "$F")" "1"
check "status: BUG-2 untouched"  "$(grep -c '^### BUG-2 — delta <!-- status: open -->' "$F")" "1"

# anchor guard: BUG-1 status change must not hit BUG-12.
printf '%s\n' '### BUG-12 — twelfth <!-- status: open -->' >> "$F"
bash "$B" status --bugs "$F" --id BUG-1 --to fixing
check "status: BUG-12 untouched" "$(grep -c '^### BUG-12 — twelfth <!-- status: open -->' "$F")" "1"

# unknown id -> rc 3; bad target -> rc 2.
bash "$B" status --bugs "$F" --id BUG-77 --to open 2>/dev/null
check "status: unknown id -> rc 3" "$?" "3"
bash "$B" status --bugs "$F" --id BUG-1 --to nope 2>/dev/null
check "status: bad --to -> rc 2"   "$?" "2"

# list: open-only shows open+fixing, hides resolved; includes fixes-tried.
seed
bash "$B" add --bugs "$F" --symptom "open one"  >/dev/null   # BUG-1
bash "$B" add --bugs "$F" --symptom "done one"  >/dev/null   # BUG-2
bash "$B" fix --bugs "$F" --id BUG-1 --outcome FAILED --note "tried X"
bash "$B" status --bugs "$F" --id BUG-2 --to resolved
out="$(bash "$B" list --bugs "$F" --open)"
check "list --open: shows BUG-1"     "$(printf '%s' "$out" | grep -c 'BUG-1 \[open\] open one')" "1"
check "list --open: hides BUG-2"     "$(printf '%s' "$out" | grep -c 'BUG-2')" "0"
check "list --open: shows fix line"  "$(printf '%s' "$out" | grep -c 'tried X → FAILED')" "1"

# list (no filter) shows all including resolved.
all="$(bash "$B" list --bugs "$F")"
check "list all: shows BUG-2"         "$(printf '%s' "$all" | grep -c 'BUG-2 \[resolved\] done one')" "1"

# missing file -> empty, rc 0.
out2="$(bash "$B" list --bugs "$tmp/none.md" 2>/dev/null)"; rc=$?
check "list missing -> rc 0"         "$rc" "0"
check "list missing -> empty"        "$out2" ""

# status: wontfix is a valid target.
seed
bash "$B" add --bugs "$F" --symptom "wf bug" >/dev/null   # BUG-1
bash "$B" status --bugs "$F" --id BUG-1 --to wontfix
check "status: wontfix accepted" "$(grep -c '^### BUG-1 — wf bug <!-- status: wontfix -->' "$F")" "1"

# list --open: a fixing-status bug is shown (open OR fixing).
seed
bash "$B" add --bugs "$F" --symptom "fix me" >/dev/null   # BUG-1
bash "$B" status --bugs "$F" --id BUG-1 --to fixing
out_fx="$(bash "$B" list --bugs "$F" --open)"
check "list --open: shows fixing bug" "$(printf '%s' "$out_fx" | grep -c 'BUG-1 \[fixing\] fix me')" "1"

# list --porcelain: tab-delimited id/status/nfixes/symptom; nfixes counts fixes.
seed
bash "$B" add --bugs "$F" --symptom "porc one" >/dev/null            # BUG-1
bash "$B" add --bugs "$F" --symptom "porc two" >/dev/null            # BUG-2
bash "$B" fix --bugs "$F" --id BUG-1 --outcome FAILED --note "a" >/dev/null
bash "$B" fix --bugs "$F" --id BUG-1 --outcome WORKED --note "b" >/dev/null
bash "$B" status --bugs "$F" --id BUG-2 --to resolved
pall="$(bash "$B" list --porcelain --bugs "$F")"
check "porc: BUG-1 row" "$(printf '%s' "$pall" | grep -c $'^BUG-1\topen\t2\tporc one$')" "1"
check "porc: BUG-2 row" "$(printf '%s' "$pall" | grep -c $'^BUG-2\tresolved\t0\tporc two$')" "1"
popen="$(bash "$B" list --porcelain --open --bugs "$F")"
check "porc --open: keeps BUG-1" "$(printf '%s' "$popen" | grep -c $'^BUG-1\t')" "1"
check "porc --open: drops BUG-2" "$(printf '%s' "$popen" | grep -c $'^BUG-2\t')" "0"

# porc: a single zero-fix bug emits nfixes=0 (not an empty field that would
# collapse under IFS=tab in a consumer's read loop).
seed
bash "$B" add --bugs "$F" --symptom "no fixes" >/dev/null              # BUG-1, 0 fixes
psingle="$(bash "$B" list --porcelain --bugs "$F")"
check "porc: zero-fix nfixes=0" "$(printf '%s' "$psingle" | grep -c $'^BUG-1\topen\t0\tno fixes$')" "1"

# porc: a heading missing the status comment (legacy/hand-edited) defaults to open,
# so it surfaces in --open rather than rendering a garbage status / silently vanishing.
printf '%s\n' '---' 'template_version: 2' '---' '# Bug Log' '' '### BUG-1 — legacy no status' > "$F"
pleg="$(bash "$B" list --porcelain --bugs "$F")"
check "porc: no-status -> open"        "$(printf '%s' "$pleg" | grep -c $'^BUG-1\topen\t0\tlegacy no status$')" "1"
plegopen="$(bash "$B" list --porcelain --open --bugs "$F")"
check "porc --open: no-status surfaces" "$(printf '%s' "$plegopen" | grep -c $'^BUG-1\t')" "1"

# porc: a literal tab in a symptom is sanitized to a space so the 4-field contract holds.
seed
bash "$B" add --bugs "$F" --symptom "$(printf 'tab\there')" >/dev/null   # BUG-1
ptab="$(bash "$B" list --porcelain --bugs "$F")"
check "porc: tab field count = 4" "$(printf '%s' "$ptab" | awk -F'\t' 'NR==1{print NF}')" "4"
check "porc: tab sanitized"       "$(printf '%s' "$ptab" | grep -c $'^BUG-1\topen\t0\ttab here$')" "1"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
