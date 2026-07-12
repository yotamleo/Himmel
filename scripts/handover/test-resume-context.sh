#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HERE/resume-context.sh"; B="$HERE/bug.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

item="$tmp/it"; mkdir -p "$item"
# one open bug w/ a failed fix
bash "$B" add --bugs "$item/bugs.md" --symptom "leaks fd" >/dev/null
bash "$B" fix --bugs "$item/bugs.md" --id BUG-1 --outcome FAILED --note "closed in finally"
# two CR-findings blocks (older then newer) in reviewer-notes.md
printf '%s\n' '# Reviewer Notes' '' '## CR Findings' '' \
  '### 2026-06-18 — HEAD aaa' '- 🔵 Suggestion [s-1] x.ts:1 — old (agreed)' '' \
  '### 2026-06-20 — HEAD bbb (PR 99)' '- 🔴 Critical [c-1] y.ts:2 — new (agreed)' > "$item/reviewer-notes.md"

out="$(bash "$R" --item "$item")"
check "panel: open-bugs header"   "$(printf '%s' "$out" | grep -c 'Open bugs')" "1"
check "panel: bug line"           "$(printf '%s' "$out" | grep -c 'BUG-1 \[open\] leaks fd')" "1"
check "panel: failed fix shown"   "$(printf '%s' "$out" | grep -c 'closed in finally → FAILED')" "1"
check "panel: CR header"          "$(printf '%s' "$out" | grep -c 'Latest CR findings')" "1"
check "panel: newest CR block"    "$(printf '%s' "$out" | grep -c 'HEAD bbb (PR 99)')" "1"
check "panel: newest CR bullet"   "$(printf '%s' "$out" | grep -c 'c-1\] y.ts:2 — new')" "1"
check "panel: old CR block hidden" "$(printf '%s' "$out" | grep -c 'HEAD aaa')" "0"

# clean item (no bugs, no CR) -> empty output, rc 0.
clean="$tmp/clean"; mkdir -p "$clean"
out2="$(bash "$R" --item "$clean")"; rc=$?
check "clean item -> rc 0"        "$rc" "0"
check "clean item -> empty"       "$out2" ""

# bugs-only item: open-bugs section present, no CR section.
bonly="$tmp/bonly"; mkdir -p "$bonly"
bash "$B" add --bugs "$bonly/bugs.md" --symptom "only a bug" >/dev/null
out_b="$(bash "$R" --item "$bonly")"
check "bugs-only: open-bugs header"  "$(printf '%s' "$out_b" | grep -c 'Open bugs')" "1"
check "bugs-only: no CR header"      "$(printf '%s' "$out_b" | grep -c 'Latest CR findings')" "0"

# CR-only item: CR section present, no open-bugs section.
cronly="$tmp/cronly"; mkdir -p "$cronly"
printf '%s\n' '# Reviewer Notes' '' '## CR Findings' '' '### 2026-06-20 — HEAD zzz' '- 🔴 Critical [c-9] z.ts:1 — only cr (agreed)' > "$cronly/reviewer-notes.md"
out_c="$(bash "$R" --item "$cronly")"
check "cr-only: CR header"           "$(printf '%s' "$out_c" | grep -c 'Latest CR findings')" "1"
check "cr-only: no open-bugs header" "$(printf '%s' "$out_c" | grep -c 'Open bugs')" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
