#!/usr/bin/env bash
# scripts/lib/test-merge-block-alert.sh -- fixture test for
# scripts/lib/merge-block-alert.sh (HIMMEL-3381).
#
# Pins the alert's contract: ONE stderr line always, ONE operator DM per
# (repo, PR, head), a failed delivery never changes the caller's status and
# releases the dedupe slot, and the DEFAULT sender never reaches the bridge
# under HIMMEL_TEST_FIXTURE=1 without a sandbox BRIDGE_ROOT.
#
# RED control: the dedupe case runs twice against a FRESH sentinel dir first and
# must see two DMs -- so the "one DM" assertion below cannot pass vacuously.
#
# Platform: POSIX bash 3.2+, needs jq (the alert reads access.json with it).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${MBA_SRC:-$HERE/merge-block-alert.sh}"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
eq()   { if [ "$2" = "$3" ]; then pass; else fail "$1 (want '$2', got '$3')"; fi; }

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not installed"
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mba-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
# Sender stub: logs "<chat>|<text>"; fails when SENDER_FAIL is set.
cat > "$TMP/bin/sender" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$ALERT_LOG"
[ -z "${SENDER_FAIL:-}" ]
EOF
chmod +x "$TMP/bin/sender"
# A `bun` that records any call: the default sender must never reach it here.
cat > "$TMP/bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "bun $*" >> "$BUN_LOG"
EOF
chmod +x "$TMP/bin/bun"

ACCESS="$TMP/access.json"
printf '{"allowFrom":["-100777","555","666"]}\n' > "$ACCESS"

# alert <case> [env...] -- <repo> <pr> <head> <rule...>; prints stderr to $TMP/err
new_case() {
    CASE="$TMP/$1"; mkdir -p "$CASE"
    : > "$CASE/alerts.log"; : > "$CASE/bun.log"
}
run_alert() {
    # $1 = case dir; remaining = merge_block_alert args. Env comes from the caller.
    local c="$1"; shift
    (
        # shellcheck disable=SC1090
        . "$LIB"
        MERGE_BLOCK_ALERT_DIR="$c/sentinels" ALERT_LOG="$c/alerts.log" BUN_LOG="$c/bun.log" \
        TELEGRAM_ACCESS_PATH="${ACCESS_OVERRIDE:-$ACCESS}" \
        merge_block_alert "$@" 2>>"$c/err"
    )
}
sender_env() { export MERGE_BLOCK_ALERT_CMD="$TMP/bin/sender"; }
count() { grep -c . "$1" 2>/dev/null || true; }

sender_env

# --- 1. stderr line + DM to the first POSITIVE allowFrom entry ---------------
new_case c1
run_alert "$CASE" octo/demo 42 0123456789abcdef0123 "required check(s) FAILED: tests"
rc=$?
eq "1: returns 0" 0 "$rc"
eq "1: one DM" 1 "$(count "$CASE/alerts.log")"
eq "1: DM goes to the first positive allowFrom (skips the negative group id)" \
    "555|MERGE-BLOCKED octo/demo#42 @0123456789ab: required check(s) FAILED: tests" "$(cat "$CASE/alerts.log")"
if grep -q 'MERGE-BLOCKED octo/demo#42 @0123456789ab: required check(s) FAILED: tests' "$CASE/err"; then pass; else fail "1: stderr carries the MERGE-BLOCKED line"; fi

# --- 2. RED control: a fresh sentinel dir DOES send again --------------------
new_case c2a
run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
new_case c2b
run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
eq "2: control — a fresh sentinel dir sends its own DM" 1 "$(count "$CASE/alerts.log")"

# --- 3. dedupe: same (repo, PR, head) sends once; a new head or PR sends again
new_case c3
run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule again"
eq "3: same repo/PR/head -> ONE DM" 1 "$(count "$CASE/alerts.log")"
run_alert "$CASE" octo/demo 42 bbbbbbbbbbbb "rule"
eq "3: a new head alerts again" 2 "$(count "$CASE/alerts.log")"
run_alert "$CASE" octo/demo 43 bbbbbbbbbbbb "rule"
eq "3: a different PR alerts again" 3 "$(count "$CASE/alerts.log")"
if [ "$(grep -c 'MERGE-BLOCKED octo/demo#42 @aaaaaaaaaaaa: rule again' "$CASE/err")" = "1" ]; then pass; else fail "3: the stderr line is printed on EVERY call (only the DM is deduped)"; fi

# --- 4. a failed send returns 0, says so, and frees the slot for a retry -----
new_case c4
SENDER_FAIL=1 run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
rc=$?
eq "4: failed delivery still returns 0" 0 "$rc"
if grep -q 'DM delivery failed' "$CASE/err"; then pass; else fail "4: says the delivery failed"; fi
run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
eq "4: the slot was released, a later run delivers (2 sends total)" 2 "$(count "$CASE/alerts.log")"

# --- 5. no readable operator id: stderr only, returns 0, no sentinel kept ----
new_case c5
ACCESS_OVERRIDE="$TMP/missing.json" run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
rc=$?
eq "5: no access.json returns 0" 0 "$rc"
eq "5: no DM" 0 "$(count "$CASE/alerts.log")"
if grep -q 'no operator chat id readable' "$CASE/err"; then pass; else fail "5: says no operator id was readable"; fi
printf '{"allowFrom":["-100777"]}\n' > "$TMP/groups-only.json"
ACCESS_OVERRIDE="$TMP/groups-only.json" run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
eq "5: an access.json with only negative (group) ids sends nothing" 0 "$(count "$CASE/alerts.log")"

# --- 6. hostile components never reach the DM path ---------------------------
new_case c6
run_alert "$CASE" 'octo/demo;rm' 42 aaaaaaaaaaaa "rule"
rc=$?
eq "6: returns 0" 0 "$rc"
eq "6: a component outside [A-Za-z0-9._/-] sends no DM" 0 "$(count "$CASE/alerts.log")"
if grep -q 'MERGE-BLOCKED' "$CASE/err"; then pass; else fail "6: the stderr line is still printed"; fi

# --- 7. default sender under HIMMEL_TEST_FIXTURE=1 never calls bun -----------
new_case c7
(
    unset MERGE_BLOCK_ALERT_CMD
    # shellcheck disable=SC1090
    . "$LIB"
    PATH="$TMP/bin:$PATH" HIMMEL_TEST_FIXTURE=1 BRIDGE_ROOT='' BUN_LOG="$CASE/bun.log" \
    MERGE_BLOCK_ALERT_DIR="$CASE/sentinels" TELEGRAM_ACCESS_PATH="$ACCESS" \
    merge_block_alert octo/demo 42 aaaaaaaaaaaa "rule" 2>>"$CASE/err"
)
eq "7: HIMMEL_TEST_FIXTURE=1 without BRIDGE_ROOT never runs bun" 0 "$(count "$CASE/bun.log")"
new_case c7b
(
    unset MERGE_BLOCK_ALERT_CMD
    # shellcheck disable=SC1090
    . "$LIB"
    PATH="$TMP/bin:$PATH" HIMMEL_TEST_FIXTURE=1 BRIDGE_ROOT="$CASE/bridge" BUN_LOG="$CASE/bun.log" \
    MERGE_BLOCK_ALERT_DIR="$CASE/sentinels" TELEGRAM_ACCESS_PATH="$ACCESS" \
    merge_block_alert octo/demo 42 aaaaaaaaaaaa "rule" 2>>"$CASE/err"
)
if grep -q 'console-route.ts reply 555 MERGE-BLOCKED octo/demo#42' "$CASE/bun.log"; then pass; else fail "7: control — with a sandbox BRIDGE_ROOT the default sender runs bun console-route.ts reply <chat> (got: $(cat "$CASE/bun.log"))"; fi

# alert_watch <case> [env...] -- <repo> <pr> <head> <rule...>; merge_watch_alert (HIMMEL-3430)
run_watch_alert() {
    local c="$1"; shift
    (
        # shellcheck disable=SC1090
        . "$LIB"
        MERGE_BLOCK_ALERT_DIR="$c/sentinels" ALERT_LOG="$c/alerts.log" BUN_LOG="$c/bun.log" \
        TELEGRAM_ACCESS_PATH="${ACCESS_OVERRIDE:-$ACCESS}" MERGE_WATCH_ALERT_BRIDGE_ROOT="$c/bridge" \
        merge_watch_alert "$@" 2>>"$c/err"
    )
}
console_case() { mkdir -p "$1/bridge/consoles"; : > "$1/bridge/consoles/$2.md"; }

# --- 8. console-leg red -> NO operator DM, one console-inbox line (row a) ----
new_case c8
console_case "$CASE" opsdesk
HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=opsdesk run_watch_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "required check(s) FAILED: tests"
rc=$?
eq "8: returns 0" 0 "$rc"
eq "8: no operator DM" 0 "$(count "$CASE/alerts.log")"
eq "8: exactly one console-inbox line" 1 "$(count "$CASE/bridge/consoles/opsdesk.md")"
if grep -q '\[merge-watch octo/demo#42\] MERGE-BLOCKED octo/demo#42 @aaaaaaaaaaaa: required check(s) FAILED: tests' "$CASE/bridge/consoles/opsdesk.md"; then pass; else fail "8: console line carries the merge-watch tag and text (got: $(cat "$CASE/bridge/consoles/opsdesk.md" 2>/dev/null))"; fi

# --- 9. merge_block_alert (a refused merge) still DMs the operator even in a
#        console-leg context -- merge-on-green.sh/pr-merge.sh call this
#        directly, unchanged, so a genuine merge refusal always pages (row b)
new_case c9
HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=opsdesk run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "gh pr merge refused"
eq "9: merge_block_alert ignores console context, DMs the operator" 1 "$(count "$CASE/alerts.log")"

# --- 10. no console resolvable -> check-ci red still DMs the operator (row c,
#          today's behaviour) -----------------------------------------------
new_case c10
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_NAME
run_watch_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "required check(s) FAILED: tests"
eq "10a: HIMMEL_CONSOLE_LEG unset -> operator DM" 1 "$(count "$CASE/alerts.log")"
new_case c10b
unset HIMMEL_CONSOLE_NAME
HIMMEL_CONSOLE_LEG=1 run_watch_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "required check(s) FAILED: tests"
eq "10b: console-leg but no HIMMEL_CONSOLE_NAME -> operator DM" 1 "$(count "$CASE/alerts.log")"
new_case c10c
HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=ghost run_watch_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "required check(s) FAILED: tests"
eq "10c: console name set but its inbox was never armed -> operator DM" 1 "$(count "$CASE/alerts.log")"
eq "10c: the never-armed inbox is NOT created (HIMMEL-3440)" "absent" "$([ -e "$CASE/bridge/consoles/ghost.md" ] && echo present || echo absent)"

# --- 11. dedupe holds for the watch channel, independent of the operator
#          channel (row d) ---------------------------------------------------
new_case c11
console_case "$CASE" opsdesk
HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=opsdesk run_watch_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule"
HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=opsdesk run_watch_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "rule again"
eq "11: repeated watch alerts for the same (repo,PR,head) -> ONE console line" 1 "$(count "$CASE/bridge/consoles/opsdesk.md")"
eq "11: still no operator DM" 0 "$(count "$CASE/alerts.log")"
# a prior watch alert must not suppress a later genuine merge-refusal DM for
# the SAME (repo, PR, head) -- separate sentinel domains.
run_alert "$CASE" octo/demo 42 aaaaaaaaaaaa "gh pr merge refused"
eq "11: a later merge_block_alert for the same head still DMs (separate sentinel from .watch)" 1 "$(count "$CASE/alerts.log")"

# --- 12. .watch sentinel create fails for a reason OTHER than already-
#          existing, while the plain (non-.watch) sentinel merge_block_alert's
#          own fallback writes still fits -- must fall back to the operator
#          DM, not be swallowed as if already delivered (HIMMEL-3430 panel
#          finding). Forced via a head long enough that "<key>.watch" trips
#          this filesystem's 255-byte NAME_MAX while the plain "<key>"
#          (6 bytes shorter) still fits -- a real, not simulated, create
#          failure that is not "already exists" ------------------------------
new_case c12
console_case "$CASE" opsdesk
LONGHEAD=$(printf '%235s' '' | tr ' ' 'a')
HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=opsdesk run_watch_alert "$CASE" octo/demo 42 "$LONGHEAD" "rule"
eq "12: watch-sentinel name-too-long falls back to operator DM" 1 "$(count "$CASE/alerts.log")"
eq "12: no console-inbox line" 0 "$(count "$CASE/bridge/consoles/opsdesk.md")"

# --- 13. _mba_append_if_exists (HIMMEL-3440): O_CREAT-free append -- appends
#          to a file that already exists, and never creates one that doesn't
#          (the primitive behind _mba_route_console; the previous separate
#          `[ -f ]` check followed by `>>` had a TOCTOU window where a file
#          deleted between the two was silently recreated by the append) -----
new_case c13
f="$CASE/opsdesk.md"; : > "$f"
(
    # shellcheck disable=SC1090
    . "$LIB"
    _mba_append_if_exists "$f" "- line one"
)
rc=$?
eq "13: appends to an existing file, returns 0" 0 "$rc"
eq "13: the line landed" "- line one" "$(cat "$f")"
eq "13: the append adds its own trailing newline" "- line one
x" "$(cat "$f"; echo x)"
(
    # shellcheck disable=SC1090
    . "$LIB"
    _mba_append_if_exists "$f" "- line two"
)
eq "13: a second append lands on its OWN line, not concatenated onto the first" "- line one
- line two" "$(cat "$f")"
f2="$CASE/ghost.md"
(
    # shellcheck disable=SC1090
    . "$LIB"
    _mba_append_if_exists "$f2" "- line one"
)
rc2=$?
eq "13: a missing file returns nonzero" 1 "$rc2"
eq "13: a missing file is NOT created" "absent" "$([ -e "$f2" ] && echo present || echo absent)"

# --- 14. HIMMEL_TEST_FIXTURE=1 with no bridge root named -> the console route
#         refuses the DEFAULT $HOME inbox (HIMMEL-3478: test-check-ci.sh wrote
#         fixture lines into the live console inbox). Case 8 is the control.
new_case c14
mkdir -p "$CASE/home/.claude/handover/bridge/consoles"
: > "$CASE/home/.claude/handover/bridge/consoles/opsdesk.md"
(
    # shellcheck disable=SC1090
    . "$LIB"
    HOME="$CASE/home" HIMMEL_TEST_FIXTURE=1 BRIDGE_ROOT='' MERGE_WATCH_ALERT_BRIDGE_ROOT='' \
    MERGE_BLOCK_ALERT_DIR="$CASE/sentinels" ALERT_LOG="$CASE/alerts.log" BUN_LOG="$CASE/bun.log" \
    TELEGRAM_ACCESS_PATH="$ACCESS" HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=opsdesk \
    merge_watch_alert octo/demo 42 aaaaaaaaaaaa "required check(s) FAILED: tests" 2>>"$CASE/err"
)
rc=$?
eq "14: returns 0" 0 "$rc"
eq "14: the default-path console inbox gains no line" 0 "$(count "$CASE/home/.claude/handover/bridge/consoles/opsdesk.md")"
eq "14: no operator DM" 0 "$(count "$CASE/alerts.log")"

echo
echo "merge-block-alert: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
