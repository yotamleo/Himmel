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

[ "$t1" = tok-one ] || { echo "FAIL - setup: lock token [$t1]"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
