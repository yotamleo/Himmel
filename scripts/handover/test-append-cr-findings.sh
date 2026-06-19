#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; A="$HERE/append-cr-findings.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
N="$tmp/reviewer-notes.md"
seed(){ printf '%s\n' '---' 'template_version: 2' '---' '# Reviewer Notes' '' '## Automated Review' '' '## Human Feedback' '' > "$N"; }

add(){ bash "$A" --notes "$N" --head H1 --date 2026-06-20 --pr 602 \
  --id "$1" --severity "$2" --file "$3" --line "$4" --title "$5" --verdict "$6"; }

seed
add gptoss-1 crit src/a.ts 42 "off-by-one" agreed
check "section created" "$(grep -c '^## CR Findings' "$N")" "1"
check "head header"     "$(grep -c '^### 2026-06-20 — HEAD H1 (PR 602)' "$N")" "1"
check "bullet present"   "$(grep -c '\[gptoss-1\] src/a.ts:42 — off-by-one (agreed)' "$N")" "1"

# Dedup: same (head,id) again -> no new bullet.
add gptoss-1 crit src/a.ts 42 "off-by-one" agreed
check "dedup (head,id)" "$(grep -c 'cr:H1:gptoss-1' "$N")" "1"

# Second finding, same head -> 1 header, 2 bullets.
add kimi-2 imp src/b.ts 10 "missing guard" disproved
check "same head: 1 header"  "$(grep -c '^### 2026-06-20 — HEAD H1' "$N")" "1"
check "same head: 2 bullets" "$(grep -c '^- ' "$N")" "2"

# Different head -> new header block.
bash "$A" --notes "$N" --head H2 --date 2026-06-21 --id qwen-1 --severity sug --file c.ts --line 1 --title "nit" --verdict agreed
check "new head: 2 headers" "$(grep -c '^### ' "$N")" "2"

# Placement: H1's second bullet (kimi-2) sits between the H1 and H2 headers;
# H2's bullet (qwen-1) sits after the H2 header.
ln_h2=$(grep -n '^### 2026-06-21 — HEAD H2' "$N" | head -1 | cut -d: -f1)
ln_kimi2=$(grep -n 'cr:H1:kimi-2' "$N" | head -1 | cut -d: -f1)
ln_qwen1=$(grep -n 'cr:H2:qwen-1' "$N" | head -1 | cut -d: -f1)
check "placement: kimi-2 under H1 (before H2)" "$( [ "$ln_kimi2" -lt "$ln_h2" ] && echo yes )" "yes"
check "placement: qwen-1 under H2 (after H2)"  "$( [ "$ln_qwen1" -gt "$ln_h2" ] && echo yes )" "yes"

# Dedup must anchor on the full marker: the existing cr:H1:gptoss-12 must NOT
# swallow a later cr:H1:gptoss-1 (substring of the longer id).
seed
add gptoss-12 crit src/a.ts 9 "twelfth" agreed
add gptoss-1  crit src/a.ts 1 "first"   agreed
check "no prefix-collision: both ids recorded" "$(grep -c '^- ' "$N")" "2"
check "gptoss-1 present"  "$(grep -c 'cr:H1:gptoss-1 ' "$N")" "1"
check "gptoss-12 present" "$(grep -c 'cr:H1:gptoss-12 ' "$N")" "1"

# Seed: item dir exists but reviewer-notes.md is missing -> create it, then append.
itemdir="$tmp/item"; mkdir -p "$itemdir"; M="$itemdir/reviewer-notes.md"
bash "$A" --notes "$M" --head H9 --date 2026-06-20 --id seed-1 --severity crit --file x.ts --line 1 --title "seeded" --verdict agreed
check "seed: file created"          "$( [ -f "$M" ] && echo yes )" "yes"
check "seed: has automated review"  "$(grep -c '^## Automated Review' "$M")" "1"
check "seed: has human feedback"    "$(grep -c '^## Human Feedback' "$M")" "1"
check "seed: bullet present"        "$(grep -c '\[seed-1\] x.ts:1 — seeded (agreed)' "$M")" "1"

# Missing parent dir -> exit 2, no stray file.
bash "$A" --notes "$tmp/nodir/reviewer-notes.md" --head H9 --id z-1 --severity crit --file a --line 1 --title t --verdict agreed 2>/dev/null
check "missing parent dir -> rc 2"  "$?" "2"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
