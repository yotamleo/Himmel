#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
# scripts/handover/console-kit/test-compacted-check.sh - suite for
# compacted-check.sh (HIMMEL-2973 G11), the checker that proves a console's
# post-compaction COMPACTED bullet matches the PreCompact snapshot
# (scripts/hooks/console-precompact-snapshot.sh) taken at the moment of
# compaction:
#   1. matching bullet                       -> rc 0, `G11 ok`
#   2. corrupted queue order + dropped tail  -> rc 1, one `G11 LOSS <field>` each
#   3. two snaps                             -> the NEWEST (highest n) is used
#   4. snap sha256 does not match its body   -> rc 2, `snapshot corrupt`
#   5. no snap in the dir                    -> rc 2, `no snapshot`
#   6. no COMPACTED bullet in the doc        -> rc 1, `G11 LOSS bullet`
#   7. backticks in the bullet are stripped before comparing (the template
#      mandates a backtick span per token)
#   8. n is compared NUMERICALLY (precompact-10 beats precompact-9)
#   9. an optional `, acked:` trailer is compared only when the bullet has one
#  10. a non-COMPACTED prose bullet mentioning the word is never picked
#
# Hermetic: temp dir only. Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/compacted-check.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/compacted-check-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { printf '%s' "$2" | grep -qF -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
lacks()    { printf '%s' "$2" | grep -qF -e "$3" && { echo "FAIL - $1: output unexpectedly contains [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

# mk_snap <dir> <n> <legs> <queue> <last-go> [acked] -- a well-formed snap.
mk_snap() {
    local d="$1" n="$2" body
    mkdir -p "$d"
    body="lock=tok1
legs=$3
queue=$4
last-go=$5
go-file=12.abc1234
acked=${6:-none}
--- tick
tick fixture line"
    { printf 'sha256=%s\n' "$(printf '%s\n' "$body" | sha_of)"; printf '%s\n' "$body"; } > "$d/precompact-$n.snap"
}

# mk_doc <file> <bullet-line> -- a console doc carrying one bullet.
mk_doc() {
    printf '# console\n\n## Results (newest at the bottom)\n- 10:00 LIVE fixture\n%s\n' "$2" > "$1"
}

LEGS='N1:nA:lA:111'
GOOD="- COMPACTED 12:00 — legs: \`$LEGS\`, queue: 12,13, last GO: 12:abc1234"

# --- 1. matching bullet ------------------------------------------------------
s1="$tmp/s1"; mk_snap "$s1" 1 "$LEGS" "12,13" "12:abc1234"
d1="$tmp/d1.md"; mk_doc "$d1" "$GOOD"
rc=0; out="$(bash "$SCRIPT" "$d1" "$s1" 2>&1)" || rc=$?
check    "1: matching bullet rc 0" "$rc" 0
contains "1: matching bullet prints G11 ok" "$out" "G11 ok"

# --- 2. corrupted queue order + dropped last GO ------------------------------
d2="$tmp/d2.md"; mk_doc "$d2" "- COMPACTED 12:00 — legs: \`$LEGS\`, queue: 13,12, last GO: none"
rc=0; out="$(bash "$SCRIPT" "$d2" "$s1" 2>&1)" || rc=$?
check    "2: corrupted bullet rc 1" "$rc" 1
contains "2: names the queue loss" "$out" "G11 LOSS queue"
contains "2: names the last-go loss" "$out" "G11 LOSS last-go"
lacks    "2: does not blame legs (which matched)" "$out" "G11 LOSS legs"

# --- 3. two snaps: the newest is used ----------------------------------------
s3="$tmp/s3"; mk_snap "$s3" 1 "$LEGS" "12,13" "12:abc1234"; mk_snap "$s3" 2 "$LEGS" "13" "12:abc1234"
d3="$tmp/d3.md"; mk_doc "$d3" "- COMPACTED 12:05 — legs: \`$LEGS\`, queue: 13, last GO: 12:abc1234"
rc=0; out="$(bash "$SCRIPT" "$d3" "$s3" 2>&1)" || rc=$?
check    "3: newest snap wins rc 0" "$rc" 0
contains "3: newest snap wins G11 ok" "$out" "G11 ok"

# --- 4. corrupt snap ---------------------------------------------------------
s4="$tmp/s4"; mk_snap "$s4" 1 "$LEGS" "12,13" "12:abc1234"
sed -i.bak 's/^queue=.*/queue=99/' "$s4/precompact-1.snap" && rm -f "$s4/precompact-1.snap.bak"
rc=0; out="$(bash "$SCRIPT" "$d1" "$s4" 2>&1)" || rc=$?
check    "4: tampered snap rc 2" "$rc" 2
contains "4: tampered snap says snapshot corrupt" "$out" "snapshot corrupt"

# --- 5. no snap --------------------------------------------------------------
s5="$tmp/s5"; mkdir -p "$s5"
rc=0; out="$(bash "$SCRIPT" "$d1" "$s5" 2>&1)" || rc=$?
check    "5: empty dir rc 2" "$rc" 2
contains "5: empty dir says no snapshot" "$out" "no snapshot"
rc=0; out="$(bash "$SCRIPT" "$d1" "$tmp/does-not-exist" 2>&1)" || rc=$?
check    "5: missing dir rc 2" "$rc" 2
contains "5: missing dir says no snapshot" "$out" "no snapshot"

# --- 6. no COMPACTED bullet ---------------------------------------------------
d6="$tmp/d6.md"; mk_doc "$d6" "- 12:00 something else"
rc=0; out="$(bash "$SCRIPT" "$d6" "$s1" 2>&1)" || rc=$?
check    "6: no bullet rc 1" "$rc" 1
contains "6: no bullet names the bullet" "$out" "G11 LOSS bullet"

# --- 7. backticks stripped ----------------------------------------------------
d7="$tmp/d7.md"; mk_doc "$d7" "- COMPACTED 12:00 — legs: \`$LEGS\`, queue: 12,13, last GO: \`12:abc1234\`"
rc=0; out="$(bash "$SCRIPT" "$d7" "$s1" 2>&1)" || rc=$?
check    "7: backticked bullet rc 0" "$rc" 0

# --- 8. numeric n ordering ----------------------------------------------------
s8="$tmp/s8"; mk_snap "$s8" 9 "$LEGS" "12,13" "12:abc1234"; mk_snap "$s8" 10 "$LEGS" "13" "12:abc1234"
rc=0; out="$(bash "$SCRIPT" "$d3" "$s8" 2>&1)" || rc=$?
check    "8: precompact-10 beats precompact-9 (rc 0)" "$rc" 0

# --- 9. optional acked trailer -------------------------------------------------
s9="$tmp/s9"; mk_snap "$s9" 1 "$LEGS" "12,13" "12:abc1234" "e1,e2"
d9="$tmp/d9.md"; mk_doc "$d9" "$GOOD, acked: e1,e2"
rc=0; out="$(bash "$SCRIPT" "$d9" "$s9" 2>&1)" || rc=$?
check    "9: matching acked trailer rc 0" "$rc" 0
d9b="$tmp/d9b.md"; mk_doc "$d9b" "$GOOD, acked: e1"
rc=0; out="$(bash "$SCRIPT" "$d9b" "$s9" 2>&1)" || rc=$?
check    "9: differing acked trailer rc 1" "$rc" 1
contains "9: names the acked loss" "$out" "G11 LOSS acked"
rc=0; out="$(bash "$SCRIPT" "$d1" "$s9" 2>&1)" || rc=$?
check    "9: bullet with no acked trailer is not judged on acked (rc 0)" "$rc" 0

# --- 10. prose mention of the word is not a bullet ------------------------------
d10="$tmp/d10.md"
printf '# console\n\n- 11:00 note: the COMPACTED bullet format is described above\n%s\n- 12:30 wrote the COMPACTED check line\n' "$GOOD" > "$d10"
rc=0; out="$(bash "$SCRIPT" "$d10" "$s1" 2>&1)" || rc=$?
check    "10: prose bullets after the real one are ignored (rc 0)" "$rc" 0

# --- 11. usage ---------------------------------------------------------------
rc=0; out="$(bash "$SCRIPT" 2>&1)" || rc=$?
check    "11: no args rc 64" "$rc" 64

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
