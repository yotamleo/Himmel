#!/usr/bin/env bash
# Test for scripts/where-are-we/statusline-rollup.sh (HIMMEL-538).
# Hermetic: the jira CLI is a STUB via --jira-cmd; an isolated temp --out dir;
# no real jira/gh/git network.
# Exit: 0 = all pass, 1 = at least one failed.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SUT="$DIR/statusline-rollup.sh"
[ -x "$SUT" ] || chmod +x "$SUT" 2>/dev/null || true

FAILED=0; PASSED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub jira CLI: dispatches on the verb. Emits real shapes:
#   get <KEY> --json  → {"fields":{"parent":{"key":"HIMMEL-514"}}}
#   list ...          → TSV rows (no header), incl. a junk non-key line
# STUB_NOPARENT=1 → get returns object with no parent.
make_stub() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
verb="$1"
# STUB_FAIL=1 → every jira call fails (simulate a transient outage/timeout).
if [ -n "${STUB_FAIL:-}" ]; then exit 1; fi
if [ "$verb" = "get" ]; then
    if [ -n "${STUB_NOPARENT:-}" ]; then
        printf '%s\n' '{"fields":{"summary":"x"}}'
    else
        printf '%s\n' '{"fields":{"parent":{"key":"HIMMEL-514"}}}'
    fi
    exit 0
fi
if [ "$verb" = "list" ]; then
    # Record the invocation args for assertion.
    [ -n "${STUB_ARGLOG:-}" ] && printf '%s\n' "$*" > "$STUB_ARGLOG"
    printf 'HIMMEL-515\tStory\tDone\tL1a contract\n'
    printf 'HIMMEL-516\tStory\tDone\tL2 view\n'
    printf 'HIMMEL-538\tTask\tIn Progress\tstatus line\n'
    printf 'HIMMEL-539\tTask\tTo Do\ttasklist\n'
    printf 'not a key line — should be ignored\n'
    exit 0
fi
exit 0
STUB
    chmod +x "$path"
}

STUB="$TMP/jira-stub.sh"
make_stub "$STUB"

# --- Case 1: happy path → cache {epic, done=2, total=4} ----------------------
out1="$TMP/c1.json"
STUB_ARGLOG="$TMP/c1.args" bash "$SUT" --key HIMMEL-538 --out "$out1" --jira-cmd "bash $STUB" >/dev/null 2>&1
epic1="$(jq -r '.epic' "$out1" 2>/dev/null)"
done1="$(jq -r '.done' "$out1" 2>/dev/null)"
total1="$(jq -r '.total' "$out1" 2>/dev/null)"
if [ "$epic1" = "HIMMEL-514" ] && [ "$done1" = "2" ] && [ "$total1" = "4" ]; then
    pass "happy path -> epic=HIMMEL-514 done=2 total=4 (junk line excluded)"
else
    fail "happy path -> got epic=$epic1 done=$done1 total=$total1 (want 514/2/4)"
fi

# --- Case 2: list invocation includes --jql passthrough + --limit 500 --------
args1="$(cat "$TMP/c1.args" 2>/dev/null)"
if printf '%s' "$args1" | grep -qF -- '--jql parent = HIMMEL-514' \
   && printf '%s' "$args1" | grep -qF -- '--limit 500'; then
    pass "list invocation uses --jql passthrough + --limit 500"
else
    fail "list invocation args wrong: '$args1'"
fi

# --- Case 3: no parent → cache {epic:null,done:0,total:0} --------------------
out3="$TMP/c3.json"
STUB_NOPARENT=1 bash "$SUT" --key HIMMEL-538 --out "$out3" --jira-cmd "bash $STUB" >/dev/null 2>&1
if [ "$(jq -r '.epic' "$out3" 2>/dev/null)" = "null" ] \
   && [ "$(jq -r '.done' "$out3" 2>/dev/null)" = "0" ] \
   && [ "$(jq -r '.total' "$out3" 2>/dev/null)" = "0" ]; then
    pass "no parent -> epic:null done:0 total:0"
else
    fail "no parent -> got $(cat "$out3" 2>/dev/null)"
fi

# --- Case 4: lock HELD → bail, cache untouched (no double-write) -------------
out4="$TMP/c4.json"
printf '%s' 'SENTINEL' > "$out4"
mkdir "$out4.lock"
bash "$SUT" --key HIMMEL-538 --out "$out4" --jira-cmd "bash $STUB" >/dev/null 2>&1
rmdir "$out4.lock" 2>/dev/null || true
if [ "$(cat "$out4" 2>/dev/null)" = "SENTINEL" ]; then
    pass "lock held -> bails, cache untouched"
else
    fail "lock held -> cache was modified: $(cat "$out4" 2>/dev/null)"
fi

# --- Case 5: stale lock (> max(TTL,300)) → reaped, refresh runs --------------
out5="$TMP/c5.json"
mkdir "$out5.lock"
# Backdate the lock dir ~20 min (well over max(900,300)=900s). Portable touch -t.
old="$(date -d '20 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-20M +%Y%m%d%H%M 2>/dev/null)"
if [ -n "$old" ]; then
    touch -t "$old" "$out5.lock" 2>/dev/null || true
    bash "$SUT" --key HIMMEL-538 --out "$out5" --jira-cmd "bash $STUB" >/dev/null 2>&1
    if [ "$(jq -r '.epic' "$out5" 2>/dev/null)" = "HIMMEL-514" ]; then
        pass "stale lock -> reaped, refresh ran"
    else
        fail "stale lock -> refresh did not run: $(cat "$out5" 2>/dev/null)"
    fi
    rmdir "$out5.lock" 2>/dev/null || true
else
    fail "stale lock -> could not backdate (no portable touch -t)"
fi

# --- Case 6: near-threshold lock (< max(TTL,300)) → NOT reaped → bails -------
out6="$TMP/c6.json"
printf '%s' 'SENTINEL6' > "$out6"
mkdir "$out6.lock"
# Backdate ~5 min (under the 900s reaper threshold). Should NOT be reaped.
recent="$(date -d '5 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-5M +%Y%m%d%H%M 2>/dev/null)"
if [ -n "$recent" ]; then
    touch -t "$recent" "$out6.lock" 2>/dev/null || true
    bash "$SUT" --key HIMMEL-538 --out "$out6" --jira-cmd "bash $STUB" >/dev/null 2>&1
    if [ "$(cat "$out6" 2>/dev/null)" = "SENTINEL6" ]; then
        pass "near-threshold lock -> not reaped, bails (cache untouched)"
    else
        fail "near-threshold lock -> wrongly reaped: $(cat "$out6" 2>/dev/null)"
    fi
    rmdir "$out6.lock" 2>/dev/null || true
else
    fail "near-threshold lock -> could not backdate"
fi

# --- Case 7: atomic write → no leftover *.tmp -------------------------------
out7="$TMP/c7.json"
bash "$SUT" --key HIMMEL-538 --out "$out7" --jira-cmd "bash $STUB" >/dev/null 2>&1
leftover="$(find "$TMP" -name 'c7.json.*.tmp' 2>/dev/null)"
if [ -z "$leftover" ]; then
    pass "atomic write -> no leftover .tmp"
else
    fail "atomic write -> leftover tmp: $leftover"
fi

# --- Case 8: transient jira failure → prior cache NOT poisoned (I2) ----------
out8="$TMP/c8.json"
printf '%s' '{"epic":"HIMMEL-514","done":4,"total":9,"refreshed_at":"old"}' > "$out8"
STUB_FAIL=1 bash "$SUT" --key HIMMEL-538 --out "$out8" --jira-cmd "bash $STUB" >/dev/null 2>&1
if [ "$(jq -r '.done' "$out8" 2>/dev/null)" = "4" ] && [ "$(jq -r '.refreshed_at' "$out8" 2>/dev/null)" = "old" ]; then
    pass "transient jira failure -> prior cache left intact (not poisoned)"
else
    fail "transient failure -> cache changed: $(cat "$out8" 2>/dev/null)"
fi

# --- Case 9: non-numeric jira-timeout env → falls back to default, still works
out9="$TMP/c9.json"
HIMMEL_WHERE_ARE_WE_JIRA_TIMEOUT="abc" bash "$SUT" --key HIMMEL-538 --out "$out9" --jira-cmd "bash $STUB" >/dev/null 2>&1
if [ "$(jq -r '.epic' "$out9" 2>/dev/null)" = "HIMMEL-514" ]; then
    pass "non-numeric jira-timeout -> default fallback, refresh still runs"
else
    fail "non-numeric jira-timeout -> $(cat "$out9" 2>/dev/null)"
fi

echo "---"
echo "rollup: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
