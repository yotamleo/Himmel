#!/usr/bin/env bash
# Unit tests for scripts/luna/qmd-reindex.sh (HIMMEL-568).
#
# The runner is a deterministic two-step (`qmd update` then `qmd embed`) plus a
# completeness assert (a second `qmd embed` that must report the all-clear).
# Everything here is exercised against a FAKE qmd, so the suite is hermetic:
# it needs no real qmd, no index, no network, and runs identically on CI's bare
# Linux runner and on the Windows box (mirrors the fixture discipline in
# test-graphmap-cadence.sh).
#
# The fake records every invocation to a call log, which is what lets us assert
# ORDER (update before embed) and COUNT (dry-run invokes nothing; the happy path
# embeds twice — once for real, once to verify).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/qmd-reindex.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
# Match with a HERE-STRING, not `printf … | grep -q` (HIMMEL-1115). Under the
# `set -o pipefail` in force here, grep -q exits early on a match, printf takes
# SIGPIPE (141), and pipefail surfaces 141 as the pipeline status — so a
# SUCCESSFUL match reads as a FAILURE as soon as the haystack outgrows the pipe
# buffer. Today's haystacks are small enough to fit, which is exactly what makes
# it a latent trap: the suite would start failing on genuine matches only once a
# runner/output grew, and the failure would look like a real regression.
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# --- the fake qmd -----------------------------------------------------------
#
# Behaviour is driven by marker files in $STATE, so each test sets up the exact
# qmd behaviour it needs. Shebang is /bin/sh (ABSOLUTE, POSIX body) — an
# `#!/usr/bin/env bash` shebang would be re-resolved through a shadowed PATH,
# the failure mode documented at length in test-graphmap-cadence.sh.
#
# Markers:
#   fail-update   `qmd update` exits nonzero
#   fail-embed    the FIRST `qmd embed` exits nonzero
#   fail-verify   the SECOND `qmd embed` (the completeness assert) exits nonzero
#   incomplete    every `qmd embed` reports work remaining (never the all-clear)
#   did-work      the first embed reports it embedded chunks (the realistic
#                 happy path); the verify pass still reports the all-clear
FAKE_QMD="$TMP_ROOT/qmd"
cat >"$FAKE_QMD" <<FAKE
#!/bin/sh
STATE="$STATE"
FAKE
cat >>"$FAKE_QMD" <<'FAKE'
printf '%s\n' "$*" >> "$STATE/calls"
case "${1:-}" in
    update)
        if [ -e "$STATE/fail-update" ]; then
            echo "qmd: update exploded" >&2
            exit 7
        fi
        echo "Indexed: 45 new, 22 updated, 14119 unchanged, 20 removed"
        echo "4 collections updated."
        ;;
    embed)
        # `grep -c` PRINTS "0" and exits 1 when there are no matches, so a
        # `|| echo 0` fallback would emit a SECOND zero and make n="0\n0" —
        # which then blows up the numeric tests below with "integer expression
        # expected". Swallow grep's status instead, and floor an empty result
        # (file absent) to 0.
        n=$(grep -c '^embed' "$STATE/calls" 2>/dev/null || :)
        [ -n "$n" ] || n=0
        if [ -e "$STATE/fail-embed" ] && [ "$n" -eq 1 ]; then
            echo "qmd: embed exploded" >&2
            exit 9
        fi
        if [ -e "$STATE/fail-verify" ] && [ "$n" -ge 2 ]; then
            echo "qmd: verify embed exploded" >&2
            exit 9
        fi
        if [ -e "$STATE/incomplete" ]; then
            echo "Embedded 100 chunks from 20 documents in 5s"
            exit 0
        fi
        if [ -e "$STATE/did-work" ] && [ "$n" -eq 1 ]; then
            echo "Embedded 457 chunks from 81 documents in 22s"
            exit 0
        fi
        echo "All content hashes already have embeddings."
        ;;
    *)
        echo "qmd-fake: unsupported argv: $*" >&2
        exit 64
        ;;
esac
FAKE
chmod +x "$FAKE_QMD"

reset_state() {
    rm -f "$STATE"/* 2>/dev/null || true
    : > "$STATE/calls"
}

calls() { cat "$STATE/calls" 2>/dev/null || true; }

# A PATH with every dir carrying a real `qmd` filtered out — the not-found probe
# must not be satisfied by an operator's actually-installed qmd. Filtering the
# real PATH beats replacing it: a bare stub dir strips coreutils and the script
# dies on `date`/`grep` before reaching the check under test (the lesson baked
# into test-graphmap-cadence.sh's PATH_NOCLAUDE).
PATH_NOQMD=""
_oldifs=$IFS; IFS=:
for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -x "$_d/qmd" ] || [ -x "$_d/qmd.exe" ] || [ -x "$_d/qmd.cmd" ]; then continue; fi
    PATH_NOQMD="${PATH_NOQMD:+$PATH_NOQMD:}$_d"
done
IFS=$_oldifs

# ============================================================================
# Argument handling
# ============================================================================

echo "TEST: --help exits 0 and documents the exit codes"
rc=0; out=$(bash "$SCRIPT" --help 2>&1) || rc=$?
assert_rc "--help rc 0" 0 "$rc"
assert_contains "--help documents --qmd-bin" "--qmd-bin" "$out"
assert_contains "--help documents the incomplete-embed code" "5 embed incomplete" "$out"

echo "TEST: unknown arg exits 1"
rc=0; out=$(bash "$SCRIPT" --nope 2>&1) || rc=$?
assert_rc "unknown arg rc 1" 1 "$rc"
assert_contains "unknown arg names the offender" "unknown arg: --nope" "$out"

echo "TEST: --qmd-bin with no operand exits 1 with a message (not a silent set -e death)"
rc=0; out=$(bash "$SCRIPT" --qmd-bin 2>&1) || rc=$?
assert_rc "trailing --qmd-bin rc 1" 1 "$rc"
assert_contains "trailing --qmd-bin explains itself" "requires an absolute path operand" "$out"

echo "TEST: --qmd-bin swallowing the NEXT FLAG is refused"
rc=0; out=$(bash "$SCRIPT" --qmd-bin --dry-run 2>&1) || rc=$?
assert_rc "--qmd-bin --dry-run rc 1" 1 "$rc"
assert_contains "flag-as-operand explains itself" "requires an absolute path operand" "$out"

echo "TEST: an EXPLICITLY EMPTY --qmd-bin operand is refused (not silently PATH-resolved)"
# `--qmd-bin ""` must not quietly fall through to PATH resolution — that ignores
# the flag the caller deliberately passed.
rc=0; out=$(bash "$SCRIPT" --qmd-bin "" 2>&1) || rc=$?
assert_rc "empty --qmd-bin operand rc 1" 1 "$rc"
assert_contains "empty operand explains itself" "requires an absolute path operand" "$out"
rc=0; out=$(bash "$SCRIPT" --qmd-bin= 2>&1) || rc=$?
assert_rc "empty --qmd-bin=VALUE rc 1" 1 "$rc"

echo "TEST: qmd not found (absent from PATH, no --qmd-bin) exits 2"
rc=0; out=$(env PATH="$PATH_NOQMD" bash "$SCRIPT" 2>&1) || rc=$?
assert_rc "missing qmd rc 2" 2 "$rc"
assert_contains "missing-qmd error is actionable" "not found on PATH" "$out"

echo "TEST: --qmd-bin pointing at a non-existent file exits 2"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$TMP_ROOT/no-such-qmd" 2>&1) || rc=$?
assert_rc "bad --qmd-bin rc 2" 2 "$rc"
assert_contains "bad --qmd-bin says not executable" "is not an executable file" "$out"

echo "TEST: a RELATIVE --qmd-bin is refused (rc 2)"
# A relative path is meaningless once a scheduled runner has cd'd elsewhere —
# the same class the sibling cadence guards against for `claude`.
rc=0; out=$(bash "$SCRIPT" --qmd-bin "./qmd" 2>&1) || rc=$?
assert_rc "relative --qmd-bin rc 2" 2 "$rc"
assert_contains "relative --qmd-bin explains why" "non-absolute path" "$out"

echo "TEST: --qmd-bin=VALUE form is accepted"
reset_state
rc=0; out=$(bash "$SCRIPT" "--qmd-bin=$FAKE_QMD" --dry-run 2>&1) || rc=$?
assert_rc "--qmd-bin=VALUE rc 0" 0 "$rc"
assert_contains "--qmd-bin=VALUE resolves the fake" "$FAKE_QMD" "$out"

# ============================================================================
# --dry-run executes nothing
# ============================================================================

echo "TEST: --dry-run prints the plan and invokes qmd zero times"
reset_state
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" --dry-run 2>&1) || rc=$?
assert_rc "dry-run rc 0" 0 "$rc"
assert_contains "dry-run previews update" "would run: $FAKE_QMD update" "$out"
assert_contains "dry-run previews embed" "would run: $FAKE_QMD embed" "$out"
assert_contains "dry-run previews the completeness assert" "completeness assert" "$out"
if [ ! -s "$STATE/calls" ]; then
    pass "dry-run invoked qmd zero times"
else
    fail "dry-run invoked qmd" "$(calls)"
fi

# ============================================================================
# Happy path
# ============================================================================

echo "TEST: happy path runs update, then embed, then the verify embed"
reset_state
touch "$STATE/did-work"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "happy path rc 0" 0 "$rc"
assert_contains "reports success" "index refreshed, all content hashes embedded" "$out"
assert_contains "step 1 labelled" "[1/3] qmd update" "$out"
assert_contains "step 2 labelled" "[2/3] qmd embed" "$out"
assert_contains "step 3 labelled" "[3/3] verifying embed completeness" "$out"
# Order + count: exactly `update`, then `embed`, then `embed`.
got_calls=$(calls | tr '\n' ',')
if [ "$got_calls" = "update,embed,embed," ]; then
    pass "call sequence is update -> embed -> embed(verify)"
else
    fail "wrong call sequence" "got: $got_calls"
fi

echo "TEST: happy path passes NO -c flag (all collections is the default scope)"
# Collection scope is deliberately not hardcoded: `qmd update`/`qmd embed`
# default to every configured collection and take -c only to NARROW, so a
# collection added later must be picked up with no edit to the runner.
assert_not_contains "no -c narrowing on any call" "-c " "$(calls)"

echo "TEST: an already-complete index (no embedding work) still succeeds"
reset_state
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "no-op embed rc 0" 0 "$rc"
assert_contains "still reports success" "index refreshed" "$out"

echo "TEST: qmd resolved from PATH when --qmd-bin is omitted"
reset_state
touch "$STATE/did-work"
rc=0; out=$(env PATH="$TMP_ROOT:$PATH" bash "$SCRIPT" 2>&1) || rc=$?
assert_rc "PATH-resolved qmd rc 0" 0 "$rc"
assert_contains "banner names the resolved qmd" "$FAKE_QMD" "$out"

# ============================================================================
# Failure paths — each must be LOUD and carry its own exit code
# ============================================================================

echo "TEST: 'qmd update' failure exits 3 and never embeds"
reset_state
touch "$STATE/fail-update"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "update failure rc 3" 3 "$rc"
assert_contains "update failure is explicit" "'qmd update' failed" "$out"
assert_contains "update failure surfaces qmd stderr" "update exploded" "$out"
assert_not_contains "no embed attempted after a failed update" "embed" "$(calls)"

echo "TEST: 'qmd embed' failure exits 4 and says vectors are stale"
reset_state
touch "$STATE/fail-embed"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "embed failure rc 4" 4 "$rc"
assert_contains "embed failure names the half-state" "lex index is fresh but vectors are NOT" "$out"

echo "TEST: an INCOMPLETE embed exits 5 (this is the whole point of HIMMEL-568)"
# A `qmd embed` that hits its session cap exits 0 having embedded only PART of
# the pending set. Without the completeness assert the cadence would report
# success while vectors lag lex — the silently-stale state the ticket exists to
# eliminate, just with a fresher timestamp on it.
reset_state
touch "$STATE/incomplete"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "incomplete embed rc 5" 5 "$rc"
assert_contains "incomplete embed is named as such" "embed INCOMPLETE" "$out"
assert_contains "incomplete embed explains the likely cause" "session" "$out"
assert_contains "incomplete embed offers the manual escape" "embed --timeout 0" "$out"
assert_not_contains "incomplete embed never claims success" "index refreshed, all content hashes embedded" "$out"

echo "TEST: a failing verify pass exits 4 (not silently treated as complete)"
reset_state
touch "$STATE/fail-verify"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "verify failure rc 4" 4 "$rc"
assert_contains "verify failure is explicit" "completeness re-check" "$out"
assert_not_contains "verify failure never claims success" "index refreshed, all content hashes embedded" "$out"

summary
