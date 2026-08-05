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

# HIMMEL-1553: pending-CR-marker audit panel. A KEY-N item whose ticket has a
# stale marker in the repo the panel runs from -> the machine classification
# surfaces next to the inherited prose. Hermetic: its own temp git repo is the
# cwd, so the real repo's markers never leak in.
repo="$tmp/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q -b main . && git config user.email t@t.t && git config user.name t \
  && echo hi > f.txt && git add f.txt && git commit -qm base \
  && git checkout -qb fix/test-77-x && echo x >> f.txt && git commit -qam w ) >/dev/null 2>&1
mkdir -p "$repo/.git/cr-pending/fix"
printf '2026-08-04T10:00:00+02:00 | 0000000000000000000000000000000000000000 | full\n' > "$repo/.git/cr-pending/fix/test-77-x"
kitem="$tmp/TEST-77-slug"; mkdir -p "$kitem"
out_k="$(cd "$repo" && bash "$R" --item "$kitem")"
check "marker panel: header"     "$(printf '%s' "$out_k" | grep -c 'Pending CR markers')" "1"
check "marker panel: stale line" "$(printf '%s' "$out_k" | grep -c 'reason=stale-marker')" "1"
check "marker panel: remedy"     "$(printf '%s' "$out_k" | grep -c 're-run /pr-check')" "1"
# an unkeyed item in the same repo stays clean/empty (audit skipped, no key)
out_u="$(cd "$repo" && bash "$R" --item "$clean")"
check "marker panel: unkeyed item skipped" "$out_u" ""

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
