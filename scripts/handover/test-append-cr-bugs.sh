#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-append-cr-bugs.sh — CR->bug bridge (HIMMEL-446 / Task 5).
# Verifies: open Critical/Important findings as tracked bugs (deduped by
# finding-id), reopen on regression, and resolve a vanished finding ONLY when
# the raising critic was panel-available that run (the F-D guard).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; S="$HERE/append-cr-bugs.sh"; BUG="$HERE/bug.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
F="$tmp/bugs.md"; fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
porc(){ bash "$BUG" list --bugs "$F" --porcelain 2>/dev/null; }
nopen(){ porc | grep -c "$(printf '\topen\t')"; }
nres(){ porc | grep -c "$(printf '\tresolved\t')"; }

# Fixtures use REAL tabs: \t lives in the printf FORMAT string (interpreted),
# never inside a %s arg (where it would stay literal backslash-t).
# Round 1: two findings (Critical + Important) → two open bugs carrying finding-id.
printf 'gptoss-1\tCritical\trace on resume\nkimi-2\tImportant\tnull deref\n' > "$tmp/find1"
printf 'gptoss\tok\nkimi\tok\n' > "$tmp/avail1"
bash "$S" --bugs "$F" --findings "$tmp/find1" --avail "$tmp/avail1"
check "r1: two bugs opened" "$(nopen)" "2"

# Round 1 re-run, same findings → idempotent (still two, no dupes).
bash "$S" --bugs "$F" --findings "$tmp/find1" --avail "$tmp/avail1"
check "r1b: still two headings" "$(grep -c '^### BUG-' "$F")" "2"

# Round 2: kimi-2 gone, kimi available → its bug resolves; gptoss-1 stays open.
printf 'gptoss-1\tCritical\trace on resume\n' > "$tmp/find2"
printf 'gptoss\tok\nkimi\tok\n' > "$tmp/avail2"
bash "$S" --bugs "$F" --findings "$tmp/find2" --avail "$tmp/avail2"
check "r2: one resolved"    "$(nres)" "1"
check "r2: one still open"  "$(nopen)" "1"

# Round 2b guard (F-D): gptoss-1 gone BUT gptoss unavailable → bug stays open.
: > "$tmp/find3"
printf 'gptoss\tunavailable\nkimi\tok\n' > "$tmp/avail3"
bash "$S" --bugs "$F" --findings "$tmp/find3" --avail "$tmp/avail3"
check "r2b: open bug NOT resolved (critic down)" "$(nopen)" "1"

# Regression reopen: resolve gptoss-1 by hand, then re-feed it → reopens.
bash "$BUG" status --bugs "$F" --id "$(bash "$BUG" find --bugs "$F" --finding-id gptoss-1 | cut -f1)" --to resolved >/dev/null
bash "$S" --bugs "$F" --findings "$tmp/find1" --avail "$tmp/avail1"
check "reopen: regression reopens bug" "$(nopen)" "2"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
