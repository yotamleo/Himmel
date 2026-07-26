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
        # A future qmd release that REWORDS its no-op line (HIMMEL-1282). Note
        # what this says: the index IS complete, just phrased differently. The
        # runner must not report it as "INCOMPLETE" — that diagnosis would be
        # wrong, and wrong nightly.
        if [ -e "$STATE/reworded" ] && [ "$n" -ge 2 ]; then
            echo "Nothing to embed: every content hash is up to date."
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

# HERMETICITY: PATH filtering ALONE is no longer sufficient (HIMMEL-1283).
# The no-flag fallback now resolves through scripts/lib/qmd-bin.sh, whose
# preference order checks the bun-served install at
# $BUN_INSTALL/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js BEFORE
# consulting PATH at all — and BUN_INSTALL defaults to $HOME/.bun. On a
# developer machine that path is the operator's REAL qmd, so a suite that only
# sanitises PATH will reach straight past its fake and run `qmd update` +
# `qmd embed` against the LIVE index. That is not a hypothetical: it happened
# while writing this change, and a real `qmd embed` is a multi-hour job.
#
# Point HOME, USERPROFILE and BUN_INSTALL at the temp dir so the bun branch
# cannot resolve anything real. Tests that want the bun branch exercised set
# BUN_INSTALL explicitly to a fixture (see the bun-preference test below).
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
export USERPROFILE="$HOME"
export BUN_INSTALL="$TMP_ROOT/bun-none"

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
# Wording follows the resolver, not PATH: since HIMMEL-1283 the fallback checks
# the bun-served install too, so "not found on PATH" would have been a lie.
assert_contains "missing-qmd error is actionable" "no usable qmd found" "$out"

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

# HIMMEL-1283: with no --qmd-bin, the fallback goes through the SHARED resolver,
# which prefers the bun-served install over whatever is first on PATH — the same
# preference order qmd_cmd uses, and the whole point of the ticket (a bare
# `command -v qmd` finds the broken Claude-plugin stub). Assert the preference
# actually holds AND that it is invoked as TWO tokens (`bun <qmd.js> update`),
# which is why --qmd-js exists at all.
echo "TEST: the bun-served install WINS over a PATH qmd, pinned as two tokens"
reset_state
touch "$STATE/did-work"
BUN_FIX="$TMP_ROOT/bunfix"
BUN_JS="$BUN_FIX/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
mkdir -p "$(dirname "$BUN_JS")" "$TMP_ROOT/bunbin"
printf 'stub\n' > "$BUN_JS"
# Fake `bun`: records "<js-basename> <args>" so we can prove it was invoked with
# the js path as its FIRST argument, then behaves like the fake qmd for the
# update/embed calls the runner makes.
cat >"$TMP_ROOT/bunbin/bun" <<BUNFAKE
#!/bin/sh
STATE="$STATE"
BUNFAKE
cat >>"$TMP_ROOT/bunbin/bun" <<'BUNFAKE'
js="$1"; shift
printf 'bun-js:%s %s\n' "$js" "$*" >> "$STATE/calls"
case "${1:-}" in
    update) echo "Indexed: 1 new" ;;
    embed)  echo "All content hashes already have embeddings" ;;
esac
exit 0
BUNFAKE
chmod +x "$TMP_ROOT/bunbin/bun"
# BOTH PATH entries need POSIX form on Windows, not just the bun one: TMP_ROOT
# carries the fake qmd, and a mixed-form (C:/...) entry is unresolvable to
# Git-Bash — leaving it raw makes the fake unreachable, so the test would prove
# "bun beat nothing" instead of "bun beat a PATH qmd".
BUNBIN_PATH="$TMP_ROOT/bunbin"
TMP_ROOT_PATH="$TMP_ROOT"
if command -v cygpath >/dev/null 2>&1; then
    BUNBIN_PATH=$(cygpath -u "$TMP_ROOT/bunbin")
    TMP_ROOT_PATH=$(cygpath -u "$TMP_ROOT")
fi
rc=0; out=$(env BUN_INSTALL="$BUN_FIX" PATH="$BUNBIN_PATH:$TMP_ROOT_PATH:$PATH_NOQMD" \
    bash "$SCRIPT" 2>&1) || rc=$?
assert_rc "bun-served resolution rc 0" 0 "$rc"
assert_contains "banner names the two-token bun invocation" "$BUN_JS" "$out"
assert_contains "bun was invoked with the js path first" "bun-js:$BUN_JS update" "$(calls)"
# Assert against the CALL RECORDER, not stdout: the recorder is the direct
# evidence of what actually executed, whereas stdout only shows what a banner
# happened to print — a fake qmd that ran silently would slip past a stdout
# check entirely.
assert_not_contains "the PATH qmd was NOT what ran" "$FAKE_QMD" "$(calls)"

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

# HIMMEL-1282: a REWORDED verifier is not an incomplete index -----------------
#
# This is the whole ticket. Before, anything that was not the exact sentinel
# read as "embed INCOMPLETE" (rc 5) — so the day qmd rewords its no-op line, a
# fully COMPLETE index reports a loud failure with a WRONG diagnosis, nightly,
# and the rational operator response to a cadence that cries wolf every night
# is to disarm it. That re-opens the staleness hole HIMMEL-568 closed. The
# fixture below says "the index IS complete", just differently: the runner must
# still refuse (fail-closed), but say what is actually true — it cannot READ the
# verifier — and it must NOT claim the index is stale.
echo "TEST: a REWORDED verifier exits 6 (unreadable), NOT 5 (incomplete)"
reset_state
touch "$STATE/reworded"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "reworded verifier rc 6" 6 "$rc"
assert_contains "names the real problem: cannot read the verifier" "UNRECOGNIZED verifier output" "$out"
assert_contains "explicitly denies the stale-index reading" "This is NOT 'the index is stale'" "$out"
assert_contains "surfaces the sentinel it looked for" "All content hashes already have embeddings" "$out"
assert_contains "names the version the sentinels were checked against" "qmd 2.6.3" "$out"
assert_contains "shows what qmd actually printed" "Nothing to embed" "$out"
assert_not_contains "does NOT misreport it as incomplete" "embed INCOMPLETE" "$out"
assert_not_contains "reworded verifier never claims success" "index refreshed, all content hashes embedded" "$out"

echo "TEST: a failing verify pass exits 4 (not silently treated as complete)"
reset_state
touch "$STATE/fail-verify"
rc=0; out=$(bash "$SCRIPT" --qmd-bin "$FAKE_QMD" 2>&1) || rc=$?
assert_rc "verify failure rc 4" 4 "$rc"
assert_contains "verify failure is explicit" "completeness re-check" "$out"
assert_not_contains "verify failure never claims success" "index refreshed, all content hashes embedded" "$out"

summary
