#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-compacted-check.sh
# scripts/handover/console-kit/test-append-results.sh - suite for
# append-results.sh (HIMMEL-3794), the helper that appends a leg's marker
# bullet at a handover doc's true EOF so it can never land mid-doc (the
# Edit-tool-anchors-on-an-old-bullet failure close-wrapped-leg.sh hit twice
# in one shift):
#   1. doc whose Results section is last  -> bullet appended at EOF, `- HH:MM ` prefix
#   2. doc with no trailing newline        -> bullet still lands as its own line
#   3. missing doc                        -> rc != 0, nothing written
#   4. doc with no `## Results` heading   -> rc != 0, doc unchanged
#   5. close-wrapped-leg.sh's WRAPPED gate (leg_tail_status, the shared
#      parser) accepts a WRAPPED bullet the helper appended AFTER older
#      out-of-order bullets, first try
#   6. HIMMEL-3796: a `## Results-old` heading (grep -q's old prefix match)
#      is rejected -> rc != 0, doc unchanged (word-boundary match only)
#
# Hermetic: temp dir only. Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/append-results.sh"
TAIL_STATUS_LIB="$HERE/../../lib/leg-tail-status.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/append-results-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }

# --- 1. doc whose Results section is last -------------------------------
d1="$tmp/d1.md"
printf '# leg\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE fixture\n' > "$d1"
rc=0; bash "$SCRIPT" "$d1" "READY fixture" >/dev/null 2>&1 || rc=$?
check "1: appends rc 0" "$rc" 0
last_line="$(tail -n 1 "$d1")"
contains "1: last line is the new bullet body" "$last_line" "READY fixture"
case "$last_line" in
    "- "[0-9][0-9]:[0-9][0-9]" READY fixture") echo "ok - 1: last line has - HH:MM prefix" ;;
    *) echo "FAIL - 1: last line has no - HH:MM prefix: [$last_line]"; fails=$((fails+1)) ;;
esac
bullet_count1="$(grep -c '^- ' "$d1")"
check "1: old bullet is still present (2 bullets total)" "$bullet_count1" 2

# --- 2. doc with no trailing newline -------------------------------------
d2="$tmp/d2.md"
printf '# leg\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE fixture' > "$d2"
rc=0; bash "$SCRIPT" "$d2" "WRAPPED fixture" >/dev/null 2>&1 || rc=$?
check "2: appends rc 0 despite missing trailing newline" "$rc" 0
contains "2: original last line preserved intact" "$(sed -n '5p' "$d2")" "- 10:00 LIVE fixture"
last_line2="$(tail -n 1 "$d2")"
contains "2: new bullet is its own line" "$last_line2" "WRAPPED fixture"
bullet_count2="$(grep -c '^- ' "$d2")"
check "2: two distinct bullets (not glued together)" "$bullet_count2" 2

# --- 3. missing doc -------------------------------------------------------
rc=0; bash "$SCRIPT" "$tmp/does-not-exist.md" "LIVE fixture" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && echo "ok - 3: missing doc rc != 0" || { echo "FAIL - 3: missing doc rc == 0"; fails=$((fails+1)); }
[ -e "$tmp/does-not-exist.md" ] && { echo "FAIL - 3: missing doc got created"; fails=$((fails+1)); } || echo "ok - 3: nothing written"

# --- 4. no `## Results` heading -------------------------------------------
d4="$tmp/d4.md"
printf '# leg\n\nno results section here\n' > "$d4"
before_d4="$(cat "$d4")"
rc=0; bash "$SCRIPT" "$d4" "LIVE fixture" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && echo "ok - 4: no Results heading rc != 0" || { echo "FAIL - 4: no Results heading rc == 0"; fails=$((fails+1)); }
after_d4="$(cat "$d4")"
check "4: doc unchanged" "$after_d4" "$before_d4"

# --- 5. close-wrapped-leg.sh's WRAPPED gate accepts it first try ----------
d5="$tmp/d5.md"
printf '# leg\n\n## Results (newest at the bottom)\n\n- 09:00 LIVE start\n- 09:30 FINDING q1\n- 09:35 RESOLVED ruled\n- 09:40 READY 123 abc GREEN\n' > "$d5"
rc=0; bash "$SCRIPT" "$d5" "WRAPPED merged" >/dev/null 2>&1 || rc=$?
check "5: append succeeds rc 0" "$rc" 0
# shellcheck source=scripts/lib/leg-tail-status.sh
# shellcheck disable=SC1090,SC1091
. "$TAIL_STATUS_LIB"
marker="$(leg_tail_status "$d5")"
check "5: leg_tail_status reads WRAPPED first try" "$marker" "WRAPPED"

# --- 6. HIMMEL-3796: `## Results-old` is a prefix match, not the heading ---
d6="$tmp/d6.md"
printf '# leg\n\n## Results-old\n\nstale content\n' > "$d6"
before_d6="$tmp/d6.before"
cp "$d6" "$before_d6"
rc=0; bash "$SCRIPT" "$d6" "LIVE fixture" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && echo "ok - 6: '## Results-old' heading rc == 4 (no-heading refusal, not a real Results heading)" || { echo "FAIL - 6: '## Results-old' heading rc == $rc, want 4"; fails=$((fails+1)); }
cmp -s "$d6" "$before_d6" && echo "ok - 6: doc unchanged" || { echo "FAIL - 6: doc unchanged"; fails=$((fails+1)); }

# --- 7. HIMMEL-4570: PARKED-BANK / RESUMED are vocabulary; a coined marker is refused ---
d7="$tmp/d7.md"
printf '# leg\n\n## Results (newest at the bottom)\n\n- 10:00 LIVE working\n' > "$d7"
rc=0; bash "$SCRIPT" "$d7" "PARKED-BANK committed and pushed, waiting for RESUME" >/dev/null 2>&1 || rc=$?
check "7: PARKED-BANK append rc 0" "$rc" 0
check "7: leg_tail_status reads PARKED-BANK, not the earlier LIVE" "$(leg_tail_status "$d7")" "PARKED-BANK"
bash "$SCRIPT" "$d7" "RESUMED bank lifted" >/dev/null 2>&1
check "7: leg_tail_status reads RESUMED" "$(leg_tail_status "$d7")" "RESUMED"
before_d7="$tmp/d7.before"; cp "$d7" "$before_d7"
rc=0; bash "$SCRIPT" "$d7" "SHIPPED the thing" >/dev/null 2>&1 || rc=$?
check "7: a coined leading marker is refused rc 6" "$rc" 6
cmp -s "$d7" "$before_d7" && echo "ok - 7: refused doc unchanged" || { echo "FAIL - 7: refused doc unchanged"; fails=$((fails+1)); }
for ok in "CONSULT design :: q :: read: x" "SUCCESSION accepted: a replaces b" "MAIN-RED job case" "Released the lock"; do
    rc=0; bash "$SCRIPT" "$d7" "$ok" >/dev/null 2>&1 || rc=$?
    check "7: non-status bullet '${ok%% *}' still appends" "$rc" 0
done

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
