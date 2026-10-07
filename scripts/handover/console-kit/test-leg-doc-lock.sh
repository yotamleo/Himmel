#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check(), as in test-append-results.sh
# scripts/handover/console-kit/test-leg-doc-lock.sh - suite for leg-doc-lock.sh
# (HIMMEL-4795): every writer of a handover doc shares one lock, so the
# launcher's session_ids: front-matter rewrite never drops a concurrent
# append-results.sh bullet.
#   1. an append fired while a rewrite sits between its re-check and its mv
#      waits for the mv and survives (the race #2043's cksum re-check missed)
#   2. concurrent appends and rewrites: no bullet and no recorded id is lost
#   3. the rewrite leaves no temp file and keeps the doc's mode
#   4. no flock on PATH: append-results.sh and the rewrite still write, unlocked
#   5. live-state.sh and inbox-send.sh --doc wait for the same lock
#
# Never runs the launcher: the rewrite is called through the sourced helper.
# Hermetic: temp dir only. Platform guard: bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/leg-doc-lock.sh"
APPEND="$HERE/append-results.sh"
export LEG_JIRA_STATUS=0

if ! command -v flock >/dev/null 2>&1; then
    echo "SKIP: flock not installed - the lock under test is flock"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/leg-doc-lock-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

mkdoc() { printf -- '---\ntemplate_version: 3\n---\n\n# leg\n\n## Results (newest at the bottom)\n' > "$1"; }
sid() { printf '%08d-0000-4000-8000-%012d' "$1" "$1"; }
# rewrite <doc> <n>: the launcher's session_ids: rewrite, as headed-arm-leg.sh runs it.
# shellcheck source=scripts/handover/console-kit/leg-doc-lock.sh
rewrite() { ( . "$LIB"; leg_doc_add_session_id "$1" "$(sid "$2")" ); }
sids_in() { awk 'NR == 1 { next } /^---$/ { exit } { print }' "$1" | sed -n 's/^session_ids: *//p' | tr ',' '\n' | grep -c .; }

# --- 1. an append inside the rewrite's re-check-to-mv gap ----------------
# A PATH-stub mv pauses the rewrite just before its mv until the test says go.
mkdir -p "$tmp/pause-bin"
cat > "$tmp/pause-bin/mv" <<STUB
#!/usr/bin/env bash
: > "$tmp/at-mv"
i=0; while [ ! -e "$tmp/go" ] && [ "\$i" -lt 100 ]; do sleep 0.05; i=\$((i+1)); done
exec "$(command -v mv)" "\$@"
STUB
chmod +x "$tmp/pause-bin/mv"
d1="$tmp/d1.md"; mkdoc "$d1"
( PATH="$tmp/pause-bin:$PATH" rewrite "$d1" 1 ) &
rw=$!
i=0; while [ ! -e "$tmp/at-mv" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
check "1a the rewrite reached its mv" "$([ -e "$tmp/at-mv" ] && echo yes)" "yes"
bash "$APPEND" "$d1" "FINDING appended mid-rewrite" >/dev/null 2>&1 &
ap=$!
sleep 0.5
: > "$tmp/go"
wait "$rw"; rw_rc=$?
wait "$ap"; ap_rc=$?
check "1b the rewrite recorded its id (rc 0)" "$rw_rc" "0"
check "1c the append succeeded (rc 0)" "$ap_rc" "0"
check "1d the bullet appended mid-rewrite survives" "$(grep -c 'FINDING appended mid-rewrite' "$d1")" "1"
check "1e the id is in the front matter" "$(sids_in "$d1")" "1"

# --- 2. concurrent appends and rewrites ----------------------------------
d2="$tmp/d2.md"; mkdoc "$d2"
pids=""
n=1
while [ "$n" -le 20 ]; do
    rewrite "$d2" "$n" & pids="$pids $!"
    bash "$APPEND" "$d2" "FINDING race-a-$n" >/dev/null 2>&1 & pids="$pids $!"
    bash "$APPEND" "$d2" "FINDING race-b-$n" >/dev/null 2>&1 & pids="$pids $!"
    n=$((n+1))
done
rw_ok=0
for p in $pids; do wait "$p" || rw_ok=$((rw_ok+1)); done
check "2a every writer exited 0" "$rw_ok" "0"
check "2b all 40 racing bullets survive" "$(grep -c '^- [0-9][0-9]:[0-9][0-9] FINDING race-' "$d2")" "40"
check "2c all 20 racing ids are recorded" "$(sids_in "$d2")" "20"
check "2d the doc still opens on its front matter" "$(head -n 1 "$d2")" "---"

# --- 3. no temp file left, mode kept -------------------------------------
d3="$tmp/d3.md"; mkdoc "$d3"; chmod 640 "$d3"
rewrite "$d3" 3
left=0; for f in "$tmp"/d3.md?*; do [ -e "$f" ] && left=$((left+1)); done
check "3a no temp file is left beside the doc" "$left" "0"
check "3b the rewrite keeps the doc's mode" "$(stat -c %a "$d3" 2>/dev/null || stat -f %Lp "$d3")" "640"

# --- 4. no flock: today's unlocked writes, never a failure ---------------
mkdir -p "$tmp/noflock-bin"
for t in bash env grep date tail dirname cat cksum cp awk mv rm mktemp realpath sha256sum mkdir chmod sed tr head; do
    p="$(command -v "$t")" && ln -s "$p" "$tmp/noflock-bin/$t"
done
d4="$tmp/d4.md"; mkdoc "$d4"
rc=0; PATH="$tmp/noflock-bin" bash "$APPEND" "$d4" "FINDING no flock" >/dev/null 2>&1 || rc=$?
check "4a append-results.sh appends without flock (rc 0)" "$rc" "0"
check "4b the unlocked bullet is written" "$(grep -c 'FINDING no flock' "$d4")" "1"
rc=0
# shellcheck disable=SC2123 # the PATH swap is the point: no flock on it
( PATH="$tmp/noflock-bin"; rewrite "$d4" 4 ) || rc=$?
check "4c the rewrite records without flock (rc 0)" "$rc" "0"
check "4d the unlocked id is written" "$(sids_in "$d4")" "1"

# --- 5. the other rewriters wait for the same lock -----------------------
# Hold the doc's lock from the test, start each writer, and check it has not
# written until the lock is released.
# shellcheck source=scripts/handover/console-kit/leg-doc-lock.sh
hold() { ( . "$LIB"; doc_lock "$1" test && { : > "$tmp/held"; while [ ! -e "$tmp/release" ]; do sleep 0.05; done; } ) & }
# wait_held: the holder must have the lock before a writer starts, or a
# "waits" check below could pass on a slow writer with no lock held at all.
held_n=0
wait_held() {
    held_n=$((held_n+1))
    i=0; while [ ! -e "$tmp/held" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    check "5.$held_n the test holds the lock before the writer starts" "$([ -e "$tmp/held" ] && echo yes)" "yes"
}
d5="$tmp/HIMMEL-5-N5-x-console.md"
printf '# console\n\n## Live state\nlegs: none\n\n## Results\n' > "$d5"
rm -f "$tmp/held" "$tmp/release"; hold "$d5"; hp=$!
wait_held
bash "$APPEND" "$d5" "MERGED held" >/dev/null 2>&1 & ap=$!
sleep 0.5
check "5a append-results.sh waits while the lock is held" "$(grep -c 'MERGED held' "$d5")" "0"
: > "$tmp/release"; wait "$hp"; wait "$ap"
check "5b append-results.sh writes once it is released" "$(grep -c 'MERGED held' "$d5")" "1"
# live-state.sh with an empty fleet manifest rewrites `legs: old` to `legs: none old`.
printf '{"legs":[]}\n' > "${d5%.md}.fleet.json"
printf '# console\n\n## Live state\nlegs: old\n\n## Results\n' > "$d5"
rm -f "$tmp/held" "$tmp/release"; hold "$d5"; hp=$!
wait_held
bash "$HERE/live-state.sh" "$d5" >/dev/null 2>&1 & lp=$!
sleep 0.5
check "5c live-state.sh waits while the lock is held" "$(grep -c '^legs: none old$' "$d5")" "0"
: > "$tmp/release"; wait "$hp"; wait "$lp"
check "5d live-state.sh rewrites once it is released" "$(grep -c '^legs: none old$' "$d5")" "1"
# inbox-send.sh --doc mirrors the ruling into the doc's Console Rulings section.
d6="$tmp/d6.md"; mkdoc "$d6"
mkdir -p "$tmp/root"
rm -f "$tmp/held" "$tmp/release"; hold "$d6"; hp=$!
wait_held
HANDOVER_DIR="$tmp/root" bash "$HERE/inbox-send.sh" leg-six "ruling held" --doc "$d6" >/dev/null 2>&1 & ip=$!
sleep 0.5
check "5e inbox-send.sh --doc waits while the lock is held" "$(grep -c 'ruling held' "$d6")" "0"
: > "$tmp/release"; wait "$hp"; wait "$ip"; ip_rc=$?
check "5f inbox-send.sh --doc mirrors once it is released (rc 0)" "$ip_rc:$(grep -c 'ruling held' "$d6")" "0:1"

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-leg-doc-lock.sh"
    exit 0
fi
echo "FAIL - test-leg-doc-lock.sh: $fails failure(s)"
exit 1
