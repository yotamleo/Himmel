#!/usr/bin/env bash
# test-update-marketplaces.sh — hermetic tests for update-marketplaces.sh
# (HIMMEL-2134).
#
# Fully offline: known_marketplaces.json is a fixture supplied via
# DRIFT_KNOWN_MARKETPLACES, and the claude CLI is a local stub supplied via
# HIMMEL_UPDATE_CLAUDE_BIN. The real CLI is never invoked and no marketplace on
# this machine is ever touched.
#
# Covers:
#   1. tier filter — only autoUpdate-falsy rows are selected; autoUpdate:true
#      rows and `himmel` are never touched.
#   2. `himmel` is excluded even when its autoUpdate is FALSE (the belt-and-
#      braces second reason in the script header — chain item 2 owns it).
#   3. FAILURE ISOLATION — a row that fails does not stop the rows after it;
#      every row is still attempted and rc is 1 with the failure named.
#   4. --check mutates nothing (the stub is never invoked) and exits 0.
#   5. no manual-tier rows at all -> rc 0 (a no-op is a success).
#   6. malformed / missing known_marketplaces.json -> rc 2, never a clean 0.
#   7. claude CLI absent -> rc 2 (cannot look), not rc 1 (looked and broke).
#
# Bash 3.2 compatible.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/update-marketplaces.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL: $SCRIPT not found" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

# grepq — a `grep -q` test with NO pipeline. printf-into-`grep -q` is a trap
# under pipefail: grep exits on first match, the producer takes SIGPIPE, and the
# PIPELINE reports failure on a SUCCESSFUL match. A here-string is not a
# pipeline. (Same guard as test-himmel-update-chain.sh, HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

assert_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then assert_pass "$desc"
    else assert_fail "$desc — expected '$pattern', got: $actual"; fi
}
assert_not_contains() {
    local desc="$1" pattern="$2" actual="$3"
    if grepq "$actual" "$pattern"; then
        assert_fail "$desc — did NOT expect '$pattern', got: $actual"
    else assert_pass "$desc"; fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then assert_pass "$desc"
    else assert_fail "$desc — expected '$expected', got '$actual'"; fi
}

# A claude stub that appends every `plugin marketplace update <name>` call to a
# log, and fails for the names listed in FAIL_NAMES (space-separated).
make_claude_stub() {
    local path="$1" log="$2" fail_names="${3:-}"
    cat >"$path" <<EOF
#!/usr/bin/env bash
# args: plugin marketplace update <name>
name="\$4"
echo "\$name" >> "$log"
for f in ${fail_names}; do
    if [ "\$f" = "\$name" ]; then
        echo "stub: refusing \$name" >&2
        exit 1
    fi
done
echo "stub: updated \$name"
exit 0
EOF
    chmod +x "$path"
}

run_case() {  # run_case <fixture-json-path> <claude-bin> [args...]
    local fixture="$1" claude_bin="$2"; shift 2
    DRIFT_KNOWN_MARKETPLACES="$fixture" \
    HIMMEL_UPDATE_CLAUDE_BIN="$claude_bin" \
        bash "$SCRIPT" "$@" 2>&1
}

echo "== test 1+2: tier filter (autoUpdate + himmel exclusion) =="
FIX1="$TMP/mkts1.json"
cat >"$FIX1" <<'JSON'
{
  "himmel":           { "source": { "source": "directory" }, "autoUpdate": false },
  "obsidian-skills":  { "source": { "source": "github", "repo": "kepano/obsidian-skills" }, "autoUpdate": true },
  "openai-codex":     { "source": { "source": "github", "repo": "openai/codex-plugin-cc" } },
  "claude-video":     { "source": { "source": "github", "repo": "bradautomates/claude-video" }, "autoUpdate": false }
}
JSON
LOG1="$TMP/log1"; : >"$LOG1"
STUB1="$TMP/claude1.sh"; make_claude_stub "$STUB1" "$LOG1"
OUT1="$(run_case "$FIX1" "$STUB1")"; RC1=$?
assert_eq "rc 0 when every selected row updates" "0" "$RC1"
assert_contains "reports what it updated" "updated:.*openai-codex" "$OUT1"
assert_not_contains "a clean run reports no failures" "FAILED:" "$OUT1"
CALLS1="$(cat "$LOG1")"
assert_contains "openai-codex (autoUpdate absent) IS updated" "openai-codex" "$CALLS1"
assert_contains "claude-video (autoUpdate false) IS updated" "claude-video" "$CALLS1"
assert_not_contains "obsidian-skills (autoUpdate true) is NOT updated" "obsidian-skills" "$CALLS1"
# The `himmel` fixture row carries autoUpdate:FALSE on purpose — the tier filter
# alone would select it, so this asserts the explicit name skip, not the filter.
assert_not_contains "himmel is NOT updated even with autoUpdate false" "himmel" "$CALLS1"

echo ""
echo "== test 3: failure isolation =="
FIX3="$TMP/mkts3.json"
cat >"$FIX3" <<'JSON'
{
  "aaa-first":  { "source": { "source": "github", "repo": "x/a" } },
  "bbb-broken": { "source": { "source": "github", "repo": "x/b" } },
  "ccc-last":   { "source": { "source": "github", "repo": "x/c" } }
}
JSON
LOG3="$TMP/log3"; : >"$LOG3"
STUB3="$TMP/claude3.sh"; make_claude_stub "$STUB3" "$LOG3" "bbb-broken"
OUT3="$(run_case "$FIX3" "$STUB3")"; RC3=$?
CALLS3="$(cat "$LOG3")"
assert_contains "row before the failure was attempted" "aaa-first" "$CALLS3"
assert_contains "the failing row was attempted" "bbb-broken" "$CALLS3"
# THE point of the ticket: a mid-sweep failure must not abort the sweep.
assert_contains "row AFTER the failure was still attempted" "ccc-last" "$CALLS3"
assert_eq "rc 1 when a row failed" "1" "$RC3"
assert_contains "the failed row is named in the report" "FAILED:.*bbb-broken" "$OUT3"
assert_contains "the succeeding rows are reported as updated" "updated:.*aaa-first" "$OUT3"

echo ""
echo "== test 4: --check mutates nothing =="
LOG4="$TMP/log4"; : >"$LOG4"
STUB4="$TMP/claude4.sh"; make_claude_stub "$STUB4" "$LOG4"
OUT4="$(run_case "$FIX3" "$STUB4" --check)"; RC4=$?
assert_eq "--check exits 0" "0" "$RC4"
assert_eq "--check invoked the claude stub ZERO times" "" "$(cat "$LOG4")"
assert_contains "--check lists the rows it would update" "bbb-broken" "$OUT4"

echo ""
echo "== test 5: no manual-tier rows -> rc 0 =="
FIX5="$TMP/mkts5.json"
cat >"$FIX5" <<'JSON'
{ "himmel": { "source": { "source": "directory" }, "autoUpdate": true },
  "obsidian-skills": { "source": { "source": "github", "repo": "k/o" }, "autoUpdate": true } }
JSON
LOG5="$TMP/log5"; : >"$LOG5"
STUB5="$TMP/claude5.sh"; make_claude_stub "$STUB5" "$LOG5"
OUT5="$(run_case "$FIX5" "$STUB5")"; RC5=$?
assert_eq "empty selection is a successful no-op (rc 0)" "0" "$RC5"
assert_eq "no claude call on an empty selection" "" "$(cat "$LOG5")"
assert_contains "says nothing to update" "nothing to update" "$OUT5"

echo ""
echo "== test 6: malformed / missing registry -> rc 2 =="
FIX6="$TMP/mkts6.json"
printf '{ this is not json' >"$FIX6"
LOG6="$TMP/log6"; : >"$LOG6"
STUB6="$TMP/claude6.sh"; make_claude_stub "$STUB6" "$LOG6"
OUT6="$(run_case "$FIX6" "$STUB6")"; RC6=$?
# rc 2, never 0: a parse failure returning "no rows" would read as a clean run.
assert_eq "malformed registry exits 2 (never a clean 0)" "2" "$RC6"
assert_eq "no claude call on a malformed registry" "" "$(cat "$LOG6")"
assert_contains "a parse failure refuses to report a clean run" "refusing to report a clean run" "$OUT6"
assert_not_contains "a parse failure never says 'nothing to update'" "nothing to update" "$OUT6"

OUT6b="$(run_case "$TMP/does-not-exist.json" "$STUB6")"; RC6b=$?
assert_eq "missing registry exits 2" "2" "$RC6b"
assert_contains "missing registry names the path it looked at" "does-not-exist.json" "$OUT6b"

# Valid JSON of the WRONG SHAPE is malformed, not empty — the one case where
# "zero rows" would silently read as a clean run.
FIX6c="$TMP/mkts6c.json"
printf '["not", "an", "object"]' >"$FIX6c"
OUT6c="$(run_case "$FIX6c" "$STUB6")"; RC6c=$?
assert_eq "valid JSON of the wrong shape exits 2, not a clean 0" "2" "$RC6c"
assert_not_contains "wrong-shape registry never says 'nothing to update'" "nothing to update" "$OUT6c"

# A malformed ENTRY is malformed for the same reason as a malformed doc —
# skipping it would report a clean run for the very row it corrupted.
FIX6d="$TMP/mkts6d.json"
printf '{ "good": { "source": { "source": "github" } }, "broken": "not-an-object" }' >"$FIX6d"
LOG6d="$TMP/log6d"; : >"$LOG6d"
# make_claude_stub is <path> <log> [fail-names] — NOT <path> <exit-code> <log>
# (the same-named helper in test-himmel-update-axis-b.sh takes that other shape).
# Passing `0` as the log made this assert vacuous: the stub logged to a file
# named "0" and $LOG6d stayed empty whether or not the CLI was invoked, so the
# mutation check passed for the wrong reason. Caught by CR round 2, codex-2.
STUB6d="$TMP/claude6d.sh"; make_claude_stub "$STUB6d" "$LOG6d"
OUT6d="$(run_case "$FIX6d" "$STUB6d")"; RC6d=$?
assert_eq "a malformed ENTRY exits 2, not a partial clean run" "2" "$RC6d"
assert_eq "no marketplace is updated when an entry is malformed" "" "$(cat "$LOG6d")"
assert_contains "a malformed entry refuses to report a clean run" "refusing to report a clean run" "$OUT6d"

# A quoted boolean is truthy in Python — it would silently mark the row
# auto-updating and drop it from the sweep while the run reported success.
FIX6e="$TMP/mkts6e.json"
printf '{ "good": { "source": { "source": "github" }, "autoUpdate": "false" } }' >"$FIX6e"
LOG6e="$TMP/log6e"; : >"$LOG6e"
STUB6e="$TMP/claude6e.sh"; make_claude_stub "$STUB6e" "$LOG6e"
OUT6e="$(run_case "$FIX6e" "$STUB6e")"; RC6e=$?
assert_eq "a non-boolean autoUpdate exits 2, never a silent skip" "2" "$RC6e"
assert_eq "no marketplace is updated when autoUpdate is malformed" "" "$(cat "$LOG6e")"
assert_not_contains "a malformed autoUpdate never says 'nothing to update'" "nothing to update" "$OUT6e"

echo ""
echo "== test 7: claude CLI absent -> rc 2, not rc 1 =="
OUT7="$(run_case "$FIX3" "$TMP/no-such-claude-binary")"; RC7=$?
assert_eq "absent claude CLI exits 2 (cannot look), not 1 (looked and broke)" "2" "$RC7"
assert_contains "names the missing CLI" "claude CLI not on PATH" "$OUT7"

echo ""
echo "== test 8: bad flag -> rc 2 =="
OUT8="$(run_case "$FIX3" "$STUB3" --wat)"; RC8=$?
assert_eq "unknown flag exits 2" "2" "$RC8"
assert_contains "prints usage" "usage:" "$OUT8"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
