#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in check(); backtick spans are literal
# scripts/handover/console-kit/test-live-state.sh - suite for live-state.sh
# (HIMMEL-3987), which renders a console doc's `## Live state` `legs:` entries
# from its fleet manifest + the held leg locks:
#   1. a held manifest leg gets `<label>:<nonce>:<lock-token>:<pid>`, the lock
#      token read from the lock, the nonce from --nonce (a new leg)
#   2. a rerun with no flags keeps the console-written nonce and pid
#   3. a manifest leg that holds no lock is left out; a leg off the manifest drops
#   4. a new leg with no --nonce is refused and the doc is untouched
#   5. prose on the legs: line survives; other fields and sections are untouched
#   6. --print writes nothing; the rendered line is what tick.sh's parser reads
#   7. a console doc with no `legs:` line is refused
#
# Hermetic: temp dir + its own HANDOVER_DIR. PLATFORM GUARD: Linux-only kit.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/live-state.sh"
LOCK="$HERE/../queue-lock.sh"
FM="$HERE/fleet-manifest.sh"

if ! command -v flock >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip - test-live-state.sh: needs flock and jq (the console kit is Linux-only)"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/live-state-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HANDOVER_DIR="$tmp/root"
mkdir -p "$HANDOVER_DIR/b"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

con="$HANDOVER_DIR/b/HIMMEL-nextleg-X-console.md"
m="${con%.md}.fleet.json"
d1="$HANDOVER_DIR/b/HIMMEL-1-N61-a-2026-09-30-RESUME.md"
d2="$HANDOVER_DIR/b/HIMMEL-2-N65-b-2026-09-30-RESUME.md"
d3="$HANDOVER_DIR/b/HIMMEL-3-N66-c-2026-09-30-RESUME.md"
: > "$d1"; : > "$d2"; : > "$d3"
t1="$(bash "$LOCK" acquire "$d1" tok-one 2>/dev/null | sed -n 's/^release-token: `\(.*\)`$/\1/p')"
bash "$LOCK" acquire "$d2" tok-two >/dev/null 2>&1
bash "$FM" add "$m" "$d1" "$d2" "$d3" >/dev/null 2>&1   # d3 holds no lock

cat > "$con" <<'DOC'
# console

## Live state

legs: `N99:old-nonce:old-lock:1` (N50 WRAPPED earlier)
queue: none
last GO: none

## Results
- legs: `N61:not:an:entry` in a bullet below the section
DOC

# 4. a new leg without --nonce is refused, doc untouched.
before="$(cat "$con")"
bash "$SCRIPT" "$con" >/dev/null 2>&1; rc=$?
check '4. a new leg with no nonce is refused' 1 "$rc"
check '4. the refused run leaves the doc untouched' "$before" "$(cat "$con")"

# 1. nonce supplied; token from the lock.
bash "$SCRIPT" "$con" --nonce N61=nonce-61 --nonce N65=nonce-65 --pid N61=111 --pid N65=222 >/dev/null 2>&1; rc=$?
check '1. render succeeds' 0 "$rc"
line="$(grep '^legs:' "$con")"
case "$line" in *'`N61:nonce-61:tok-one:111`'*) r=yes ;; *) r=no ;; esac
check '1. N61 entry carries its nonce, the lock token and pid' yes "$r"
case "$line" in *'`N65:nonce-65:tok-two:222`'*) r=yes ;; *) r=no ;; esac
check '1. N65 entry carries its own lock token' yes "$r"
case "$line" in *N66*) r=has ;; *) r=none ;; esac
check '3. a manifest leg holding no lock is left out' none "$r"
case "$line" in *N99*) r=has ;; *) r=none ;; esac
check '3. a leg off the manifest drops' none "$r"
case "$line" in *'(N50 WRAPPED earlier)'*) r=kept ;; *) r=lost ;; esac
check '5. prose on the legs: line survives' kept "$r"
check '5. the queue: field is untouched' 'queue: none' "$(grep '^queue:' "$con")"
check '5. a legs: bullet outside Live state is untouched' '- legs: `N61:not:an:entry` in a bullet below the section' "$(grep '^- legs:' "$con")"

# 2. rerun with no flags keeps nonce and pid.
cp "$con" "$tmp/after1"
bash "$SCRIPT" "$con" >/dev/null 2>&1; rc=$?
check '2. a rerun with no flags succeeds' 0 "$rc"
check '2. a rerun changes nothing' "$(cat "$tmp/after1")" "$(cat "$con")"

# 2b. a lock token that changed is picked up, the nonce stays.
bash "$LOCK" release "$d2" tok-two >/dev/null 2>&1
bash "$LOCK" acquire "$d2" tok-two-b >/dev/null 2>&1
bash "$SCRIPT" "$con" >/dev/null 2>&1
case "$(grep '^legs:' "$con")" in *'`N65:nonce-65:tok-two-b:222`'*) r=yes ;; *) r=no ;; esac
check '2b. a re-acquired lock updates the token, keeps nonce and pid' yes "$r"

# 3b. removing a leg from the manifest drops it.
bash "$FM" remove "$m" N65 >/dev/null 2>&1
bash "$SCRIPT" "$con" >/dev/null 2>&1
case "$(grep '^legs:' "$con")" in *N65*) r=has ;; *) r=none ;; esac
check '3b. a leg removed from the manifest drops' none "$r"

# 6. --print writes nothing.
cp "$con" "$tmp/after2"
out="$(bash "$SCRIPT" "$con" --print 2>/dev/null)"
check '6. --print leaves the doc untouched' "$(cat "$tmp/after2")" "$(cat "$con")"
case "$out" in 'legs: `N61:nonce-61:tok-one:111`'*) r=yes ;; *) r=no ;; esac
check '6. --print prints the legs: line' yes "$r"

# 7. no legs: line.
printf '# c\n\n## Live state\n\nqueue: none\n' > "$HANDOVER_DIR/b/HIMMEL-nextleg-Y-console.md"
bash "$FM" add "$HANDOVER_DIR/b/HIMMEL-nextleg-Y-console.fleet.json" "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$HANDOVER_DIR/b/HIMMEL-nextleg-Y-console.md" --nonce N61=x >/dev/null 2>&1; rc=$?
check '7. a doc with no legs: line is refused' 1 "$rc"

# 8. a backslash in a nonce is refused (awk -v would interpret it).
before8="$(cat "$con")"
bash "$SCRIPT" "$con" --nonce 'N61=a\nb' >/dev/null 2>&1; rc=$?
check '8. a backslash in --nonce is refused' 2 "$rc"
check '8. the refused run leaves the doc untouched' "$before8" "$(cat "$con")"

# 9. the `none` placeholder is not carried into a rendered line.
con9="$HANDOVER_DIR/b/HIMMEL-nextleg-Z-console.md"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\n' > "$con9"
bash "$FM" add "${con9%.md}.fleet.json" "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$con9" --nonce N61=n9 --pid N61=9 >/dev/null 2>&1
check '9. legs: none becomes the entries alone' 'legs: `N61:n9:tok-one:9`' "$(grep '^legs:' "$con9")"
bash "$FM" remove "${con9%.md}.fleet.json" N61 >/dev/null 2>&1
bash "$SCRIPT" "$con9" >/dev/null 2>&1
bash "$SCRIPT" "$con9" >/dev/null 2>&1
check '9. an empty render is a stable single none' 'legs: none' "$(grep '^legs:' "$con9")"

# 10. a backslash in the preserved prose survives the rewrite (not awk-interpreted).
con10="$HANDOVER_DIR/b/HIMMEL-nextleg-W-console.md"
printf '# c\n\n## Live state\n\nlegs: `N61:n10:tok-one:10` note a\\nb \\t end\nqueue: none\n' > "$con10"
bash "$FM" add "${con10%.md}.fleet.json" "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$con10" >/dev/null 2>&1
check '10. backslashes in prose are written verbatim' 'legs: `N61:n10:tok-one:10` note a\nb \t end' "$(grep '^legs:' "$con10")"
check '10. the doc keeps its line count' 6 "$(wc -l < "$con10" | tr -d ' ')"

# 11. a lock status failure (not "free") refuses and leaves the doc untouched.
con11="$HANDOVER_DIR/b/HIMMEL-nextleg-V-console.md"
printf '# c\n\n## Live state\n\nlegs: `N61:n11:tok-one:11`\n' > "$con11"
bash "$FM" add "${con11%.md}.fleet.json" "$d1" >/dev/null 2>&1
before11="$(cat "$con11")"
cp -R "$HERE/.." "$tmp/kitcopy" 2>/dev/null
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/kitcopy/queue-lock.sh"
bash "$tmp/kitcopy/console-kit/live-state.sh" "$con11" >/dev/null 2>&1; rc=$?
check '11. a lock status failure refuses' 1 "$rc"
check '11. the refused run leaves the doc untouched' "$before11" "$(cat "$con11")"

# 12. a held lock whose owner is unreadable refuses and leaves the doc untouched.
printf '#!/usr/bin/env bash\necho garbage\nexit 11\n' > "$tmp/kitcopy/queue-lock.sh"
bash "$tmp/kitcopy/console-kit/live-state.sh" "$con11" >/dev/null 2>&1; rc=$?
check '12. an unreadable lock owner refuses' 1 "$rc"
check '12. the refused run leaves the doc untouched' "$before11" "$(cat "$con11")"

# 14. an owner session carrying a span delimiter (colon, backtick, whitespace) refuses and leaves the doc untouched.
for bad14 in 'a:b' 'a`b' 'a b'; do
    printf '{"session":"%s"}\n' "$bad14" > "$tmp/owner14.json"
    printf '#!/usr/bin/env bash\ncat "%s"\nexit 11\n' "$tmp/owner14.json" > "$tmp/kitcopy/queue-lock.sh"
    err14="$(bash "$tmp/kitcopy/console-kit/live-state.sh" "$con11" 2>&1 >/dev/null)"; rc=$?
    check "14. owner session [$bad14] refuses" 1 "$rc"
    case "$err14" in *'span delimiter'*) r=guard ;; *) r="[$err14]" ;; esac
    check "14. owner session [$bad14] hits the delimiter guard" guard "$r"
    check "14. owner session [$bad14] leaves the doc untouched" "$before11" "$(cat "$con11")"
done

# 13. end to end: tick.sh reads the rendered doc as livestate=ok.
e2e="$HANDOVER_DIR/b/HIMMEL-nextleg-T-console.md"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\nlast GO: none\nacked: none\n' > "$e2e"
bash "$FM" add "${e2e%.md}.fleet.json" "$d1" >/dev/null 2>&1
bash "$SCRIPT" "$e2e" --nonce N61=n13 --pid N61=13 >/dev/null 2>&1
mkdir -p "$tmp/tickstate"
tick_out="$(TICK_STATE_DIR="$tmp/tickstate" TICK_TMPDIR="$tmp" TICK_LAUNCH_DIR="$tmp" bash "$HERE/tick.sh" --doc "$e2e" --token test-token --legs "$d1" 2>/dev/null)"
case "$tick_out" in *'livestate=ok'*) r=ok ;; *) r="[$tick_out]" ;; esac
check '13. tick.sh reads the rendered Live state as livestate=ok' ok "$r"

# 15. HIMMEL-5074: a lockless manifest row gets its own `lockless:` line, not a
# "holds no lock" omission, and a rerun replaces the line instead of stacking it.
lk="$HANDOVER_DIR/b/HIMMEL-nextleg-L-console.md"
lkd="$HANDOVER_DIR/b/HIMMEL-4869-N90-pilot.md"
: > "$lkd"
printf '# c\n\n## Live state\n\nlegs: none\nlockless: stale (x) /old; \nqueue: none\n\n## Results\n' > "$lk"
bash "$FM" add "${lk%.md}.fleet.json" "$d1" >/dev/null 2>&1
bash "$FM" add "${lk%.md}.fleet.json" --lane deepseek --lockless "$lkd" >/dev/null 2>&1
lk_err="$(bash "$SCRIPT" "$lk" --nonce N61=n14 --pid N61=14 2>&1 >/dev/null)"
check '15. the lockless row is listed with its lane and doc' "lockless: N90 (deepseek) $lkd" "$(grep '^lockless:' "$lk")"
check '15. the stale lockless line is replaced, not stacked' 1 "$(grep -c '^lockless:' "$lk")"
case "$lk_err" in *N90*) r=noise ;; *) r=quiet ;; esac
check '15. a lockless row is not reported as a leg that holds no lock' quiet "$r"
check '15. the legs: line carries only the locked leg' 'legs: `N61:n14:tok-one:14`' "$(grep '^legs:' "$lk")"
check '15. the queue: field is untouched' 'queue: none' "$(grep '^queue:' "$lk")"
bash "$FM" remove "${lk%.md}.fleet.json" N90 >/dev/null 2>&1
bash "$SCRIPT" "$lk" >/dev/null 2>&1
check '15. with no lockless row the line is dropped' 0 "$(grep -c '^lockless:' "$lk")"

# 16. HIMMEL-5074 N3/B1b: an empty lane reads unknown (not the next field), and only the
# boolean true is lockless: the string "true" stays a locked, visible row.
lk2="$HANDOVER_DIR/b/HIMMEL-nextleg-M-console.md"
lk2d="$HANDOVER_DIR/b/HIMMEL-4869-N91-pilot.md"; lk2s="$HANDOVER_DIR/b/HIMMEL-4869-N92-str.md"
: > "$lk2d"; : > "$lk2s"
printf '# c\n\n## Live state\n\nlegs: none\nqueue: none\n\n## Results\n' > "$lk2"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N91","lane":"","lockless":true},{"doc":"%s","label":"N92","lane":"native","lockless":"true"}]}\n' "$lk2d" "$lk2s" > "${lk2%.md}.fleet.json"
lk2_err="$(bash "$SCRIPT" "$lk2" 2>&1 >/dev/null)"
check '16. an empty lane is listed as unknown' "lockless: N91 (unknown) $lk2d" "$(grep '^lockless:' "$lk2")"
case "$lk2_err" in *'N92 holds no lock'*) r=visible ;; *) r="[$lk2_err]" ;; esac
check '16. a string "true" lockless row is not hidden as lockless' visible "$r"

[ "$t1" = tok-one ] || { echo "FAIL - setup: lock token [$t1]"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
