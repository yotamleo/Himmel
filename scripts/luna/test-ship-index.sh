#!/usr/bin/env bash
# Tests for scripts/luna/ship-index.sh (HIMMEL-1275).
#
# Covers everything reachable WITHOUT a second machine: argument handling,
# preflight refusals, the dry-run plan, and the "nothing ships when the local
# build fails" ordering guarantee. Deliberately does NOT test the actual
# swap/fence/restart — that mutates a remote machine's live index, so it must
# never be a CI test (the ticket says so explicitly).
#
# Strategy: stub `ssh`, `scp`, `node` and the reindex runner on PATH so the
# script's ORDER OF OPERATIONS and its refusals are observable via a call log,
# with no network and no real qmd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ship-index.sh"

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

REAL_BASH="$(command -v bash)"
# Resolve the REAL node BEFORE the stub dir shadows PATH. The stub falls back to
# the real interpreter for the tiny inline JSON programs the script pipes
# through node — and `env node` there would re-resolve through the shadowed
# PATH straight back into the stub, an infinite exec loop that hangs the suite
# to the CI timeout (the same shape test-graphmap-cadence.sh documents for bash).
REAL_NODE="$(command -v node 2>/dev/null || true)"
[ -n "$REAL_NODE" ] || { echo "SKIP: node not on PATH"; exit 0; }
TMP_ROOT=$(mktemp -d)
BIN="$TMP_ROOT/bin"
STATE="$TMP_ROOT/state"
mkdir -p "$BIN" "$STATE"
: > "$STATE/calls"

# --- stubs -------------------------------------------------------------------
# All /bin/sh with an ABSOLUTE shebang so a shadowed PATH can never make one
# re-resolve into another stub.
# shellcheck disable=SC2016  # stub BODIES are deliberately literal: `$*`, `$STATE`
# and friends must reach the generated stub unexpanded, to be evaluated when the
# stub RUNS, not when this suite writes it.
mk_stub() {
    local name="$1" body="$2"
    { printf '#!/bin/sh\nSTATE="%s"\n' "$STATE"; printf '%s\n' "$body"; } > "$BIN/$name"
    chmod +x "$BIN/$name"
}

# ssh: records argv; `qmd collection list` answers with the receiver's set.
# shellcheck disable=SC2016  # literal body — expands when the STUB runs, not now
mk_stub ssh '
printf "ssh %s\n" "$*" >> "$STATE/calls"
if [ -e "$STATE/ssh-fail" ]; then exit 255; fi
case "$*" in
  *USERPROFILE*)
      # The receiver reports where its OWN profile lives; ship-index derives the
      # remote index/graph/tmp paths from it rather than hardcoding a home dir.
      # Backslashes + CR on purpose: that is what real PowerShell over ssh emits.
      if [ -e "$STATE/no-remote-home" ]; then exit 1; fi
      printf "C:\\\\Users\\\\fakeuser\r\n" ;;
  *"qmd collection list"*)
      # The REAL `qmd collection list` output (HIMMEL-1284), not a pre-parsed
      # one. This fixture used to emit a bare "himmel\nluna" — already shaped
      # like the parser OUTPUT — so the suite could not see the header bug at
      # all: `Collections (2):` was being picked up as a phantom collection and
      # every default ship died in prepare-ship-index. A stub that answers with
      # the answer tests nothing. CRs on purpose: this arrives over ssh.
      if [ -e "$STATE/no-remote-collections" ]; then exit 1; fi
      printf "Collections (2):\r\n"
      printf "\r\n"
      printf "himmel (qmd://himmel/)\r\n"
      printf "  Pattern:  **/*.md\r\n"
      printf "  Files:    286\r\n"
      printf "  Updated:  22h ago\r\n"
      printf "\r\n"
      printf "luna (qmd://luna/)\r\n"
      printf "  Pattern:  **/*.md\r\n"
      printf "  Files:    14155\r\n"
      printf "  Updated:  22h ago\r\n" ;;
  *"cmd /c del"*)
      # per-run artifact cleanup — always succeeds, never the ship result
      exit 0 ;;
  *ship-index-remote*)
      # matches the PER-INVOCATION name (ship-index-remote.<tag>.ps1), not a
      # fixed one — the orchestrator uniquifies remote paths per run.
      if [ -e "$STATE/remote-fail" ]; then echo "SHIP-REMOTE: swapped=no" >&2; exit 5; fi
      echo "SHIP-REMOTE: verified=ok" ;;
esac
exit 0'

# shellcheck disable=SC2016  # literal body — expands when the STUB runs, not now
mk_stub scp '
printf "scp %s\n" "$*" >> "$STATE/calls"
if [ -e "$STATE/scp-fail" ]; then exit 1; fi
exit 0'

# node: stands in for prepare-ship-index.mjs. Emits the --json shape the
# orchestrator parses, and still behaves as a real node for the tiny inline
# JSON-extraction programs the script pipes through it.
{ printf '#!/bin/sh\nSTATE="%s"\nREAL_NODE="%s"\n' "$STATE" "$REAL_NODE"; cat <<'NODE_EOF'
case "$*" in
  *prepare-ship-index.mjs*)
      printf "node-prepare %s\n" "$*" >> "$STATE/calls"
      if [ -e "$STATE/prepare-fail" ]; then echo "prepare exploded" >&2; exit 4; fi
      if [ -e "$STATE/prepare-badjson" ]; then echo "not json at all"; exit 0; fi
      # create the staging file the orchestrator expects to upload
      prev=""
      for a in "$@"; do
          if [ "$prev" = "--out" ]; then : > "$a"; fi
          prev="$a"
      done
      echo '{"ok":true,"after":{"documents":14782,"vectors":50698}}'
      exit 0 ;;
esac
# ABSOLUTE path, never `env node` — see the REAL_NODE comment above.
exec "$REAL_NODE" "$@"
NODE_EOF
} > "$BIN/node"
chmod +x "$BIN/node"

FAKE_INDEX="$TMP_ROOT/index.sqlite"
printf 'not-a-real-index' > "$FAKE_INDEX"

run_ship() {
    env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" GRAPHIFY_GRAPH_PATH="$TMP_ROOT/nograph.json" \
        "$REAL_BASH" "$SCRIPT" "$@"
}
# Clear EVERY behaviour marker, not just the *-fail ones — a leftover marker
# silently changes the next test's meaning (and did: prepare-badjson leaked into
# three later cases and made them fail for the wrong reason).
reset_calls() {
    : > "$STATE/calls"
    rm -f "$STATE"/*-fail "$STATE/no-remote-collections" "$STATE/no-remote-home" "$STATE/prepare-badjson" 2>/dev/null || true
}
calls() { cat "$STATE/calls" 2>/dev/null || true; }

# ============================================================================
echo "TEST: argument handling"
# ============================================================================
rc=0; out=$(run_ship --help 2>&1) || rc=$?
assert_rc "--help rc 0" 0 "$rc"
assert_contains "--help documents the exit codes" "6 receiver" "$out"
rc=0; out=$(run_ship --nope 2>&1) || rc=$?
assert_rc "unknown arg rc 1" 1 "$rc"
rc=0; out=$(run_ship --host 2>&1) || rc=$?
assert_rc "trailing --host rc 1" 1 "$rc"
assert_contains "trailing --host explains itself" "--host requires a value" "$out"
rc=0; out=$(run_ship --collections 2>&1) || rc=$?
assert_rc "trailing --collections rc 1" 1 "$rc"

# ============================================================================
echo "TEST: preflight refuses a missing local index"
# ============================================================================
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$TMP_ROOT/absent.sqlite" \
    "$REAL_BASH" "$SCRIPT" --no-reindex 2>&1) || rc=$?
assert_rc "missing local index rc 2" 2 "$rc"
assert_contains "names the missing index" "local qmd index not found" "$out"

# ============================================================================
echo "TEST: --dry-run plans everything and touches nothing"
# ============================================================================
reset_calls
rc=0; out=$(run_ship --dry-run 2>&1) || rc=$?
assert_rc "dry-run rc 0" 0 "$rc"
assert_contains "dry-run names the host" "host              : win2" "$out"
assert_contains "dry-run says the remote index is derived" "derived from the receiver's USERPROFILE" "$out"
assert_not_contains "dry-run does not print a stray backslash-apostrophe" "receiver\\'s" "$out"
assert_contains "dry-run mentions the reconcile query" "qmd collection list" "$out"
assert_contains "dry-run mentions the receiver script" "ship-index-remote.ps1" "$out"
assert_contains "dry-run names the fence/swap/verify order" "daemon fence -> swap -> WMI restart -> verify -> reap" "$out"
if [ ! -s "$STATE/calls" ]; then
    pass "dry-run made no ssh/scp/node calls at all"
else
    fail "dry-run performed calls" "$(calls)"
fi

# ============================================================================
echo "TEST: a failed local reindex ships NOTHING"
# ============================================================================
# Ordering guarantee: the receiver must keep its current index rather than
# receive a half-built one.
reset_calls
# ship-index.sh resolves its siblings from its OWN directory, so a copy of it
# into a temp dir alongside a FAILING qmd-reindex.sh exercises the real code
# path with no patching of the script under test.
SANDBOX="$TMP_ROOT/sandbox"
mkdir -p "$SANDBOX"
cp "$SCRIPT" "$SANDBOX/ship-index.sh"
cp "$SCRIPT_DIR/prepare-ship-index.mjs" "$SANDBOX/"
cp "$SCRIPT_DIR/ship-index-remote.ps1" "$SANDBOX/"
printf '#!/bin/sh\necho "reindex exploded" >&2\nexit 3\n' > "$SANDBOX/qmd-reindex.sh"
chmod +x "$SANDBOX/qmd-reindex.sh"
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" \
    "$REAL_BASH" "$SANDBOX/ship-index.sh" --no-graph 2>&1) || rc=$?
assert_rc "failed reindex rc 3" 3 "$rc"
assert_contains "says nothing was shipped" "NOTHING shipped" "$out"
assert_not_contains "no upload attempted after a failed reindex" "scp " "$(calls)"

# ============================================================================
echo "TEST: remote_collections parses ROWS, never the header (HIMMEL-1284)"
# ============================================================================
# Unit-level, independent of the ship flow: extract the function and feed it a
# fake `ssh` that emits the REAL `qmd collection list` prose. The regression is
# specifically that `Collections (2):` — whose first token is a bare identifier
# — was kept as a collection name, so assert its ABSENCE explicitly rather than
# only asserting the happy set. Also covers the detail lines (`Pattern:`,
# `Files:`, `Updated:`), which the old identifier filter dropped only because
# they happen to carry a colon.
rc_fixture=$(mktemp -t ship-collections.XXXXXX)
{
    printf 'ssh() {\n'
    printf '  printf "Collections (2):\\r\\n"\n'
    printf '  printf "\\r\\n"\n'
    printf '  printf "himmel (qmd://himmel/)\\r\\n"\n'
    printf '  printf "  Pattern:  **/*.md\\r\\n"\n'
    printf '  printf "  Files:    286\\r\\n"\n'
    printf '  printf "  Updated:  22h ago\\r\\n"\n'
    printf '  printf "\\r\\n"\n'
    printf '  printf "luna (qmd://luna/)\\r\\n"\n'
    printf '  printf "  Pattern:  **/*.md\\r\\n"\n'
    printf '  printf "  Files:    14155\\r\\n"\n'
    printf '  printf "  Updated:  22h ago\\r\\n"\n'
    printf '}\n'
    printf 'HOST=fakehost\n'
    sed -n '/^remote_collections()/,/^}/p' "$SCRIPT"
    printf 'remote_collections\n'
} > "$rc_fixture"
parsed=$(bash "$rc_fixture")
rm -f "$rc_fixture"
if [ "$parsed" = "himmel,luna" ]; then
    pass "real qmd output parses to exactly himmel,luna"
else
    fail "real qmd output mis-parsed" "expected 'himmel,luna', got '$parsed'"
fi
assert_not_contains "the 'Collections' header is NOT a collection" "Collections" "$parsed"
assert_not_contains "detail-line labels are not collections" "Pattern" "$parsed"

# A row whose DISPLAY NAME and URI disagree must be rejected outright, not
# silently resolved to the display name (public-PR CR). Anchoring on `(qmd://`
# alone accepted `wrong (qmd://other/)` and yielded `wrong`, so the parser could
# have shipped to a collection the URI never named. The two names are now tied
# by a backreference. This shape does not occur in qmd 2.6.3's output — which is
# the point: the invariant the parser RELIES on is asserted rather than assumed,
# and it fails visibly (a short collection set) instead of silently wrong.
#
# The fixture keeps ONE good row alongside the bad one, so the assertion cannot
# pass by rejecting everything.
rc_bad=$(mktemp -t ship-collections-bad.XXXXXX)
{
    printf 'ssh() {\n'
    printf '  printf "Collections (2):\\r\\n"\n'
    printf '  printf "\\r\\n"\n'
    printf '  printf "himmel (qmd://himmel/)\\r\\n"\n'
    printf '  printf "wrong (qmd://other/)\\r\\n"\n'
    printf '}\n'
    printf 'HOST=fakehost\n'
    sed -n '/^remote_collections()/,/^}/p' "$SCRIPT"
    printf 'remote_collections\n'
} > "$rc_bad"
parsed_bad=$(bash "$rc_bad")
rm -f "$rc_bad"
if [ "$parsed_bad" = "himmel" ]; then
    pass "a name/URI mismatch row is rejected, the matching row survives"
else
    fail "name/URI mismatch not rejected" "expected 'himmel', got '$parsed_bad'"
fi
assert_not_contains "the mismatched display name is not emitted" "wrong" "$parsed_bad"

# A row with NO trailing slash still parses — the slash is optional in the
# pattern, and asserting it here stops a future tightening from quietly
# requiring a trailing slash that qmd may omit.
rc_noslash=$(mktemp -t ship-collections-noslash.XXXXXX)
{
    printf 'ssh() {\n'
    printf '  printf "himmel (qmd://himmel)\\r\\n"\n'
    printf '}\n'
    printf 'HOST=fakehost\n'
    sed -n '/^remote_collections()/,/^}/p' "$SCRIPT"
    printf 'remote_collections\n'
} > "$rc_noslash"
parsed_noslash=$(bash "$rc_noslash")
rm -f "$rc_noslash"
if [ "$parsed_noslash" = "himmel" ]; then
    pass "a row without the trailing slash still parses"
else
    fail "trailing-slash-less row mis-parsed" "expected 'himmel', got '$parsed_noslash'"
fi

# ============================================================================
echo "TEST: the RECEIVER decides the collection set"
# ============================================================================
reset_calls
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "happy path rc 0" 0 "$rc"
assert_contains "queried the receiver's collections" "qmd collection list" "$(calls)"
assert_contains "reports what the receiver configures" "receiver configures: himmel,luna" "$out"
assert_contains "passed that set to prepare" "--collections himmel,luna" "$(calls)"
assert_contains "uploaded the index" "scp " "$(calls)"
assert_contains "ran the receiver script" "ship-index-remote.ps1" "$(calls)"
assert_contains "reports the shipped counts" "14782 docs / 50698 vectors" "$out"

echo "TEST: remote paths are DERIVED from the receiver, never hardcoded"
# A baked C:/Users/<name>/... default would tie the script to one operator's
# account AND put a personal home path into a file that propagates publicly.
reset_calls
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "derived-paths happy path rc 0" 0 "$rc"
assert_contains "asked the receiver for its profile" "USERPROFILE" "$(calls)"
assert_contains "derived the index path from it" "C:/Users/fakeuser/.cache/qmd/index.sqlite" "$out"
if LC_ALL=C grep -qE 'C:/Users/[A-Za-z0-9._-]+/' "$SCRIPT"; then
    fail "ship-index.sh still contains a hardcoded home path" "derive it from the receiver instead"
else
    pass "ship-index.sh has no hardcoded home path"
fi

echo "TEST: an unreadable receiver profile is fatal, not a silent default"
reset_calls
touch "$STATE/no-remote-home"
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "unresolvable remote home rc 2" 2 "$rc"
assert_contains "names the override env vars" "SHIP_REMOTE_INDEX" "$out"
assert_not_contains "nothing uploaded without resolved paths" "scp " "$(calls)"

echo "TEST: dry-run reports an explicit override, not the derived placeholder"
# A dry-run that misreports its own plan is worse than no dry-run.
reset_calls
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" \
    GRAPHIFY_GRAPH_PATH="$TMP_ROOT/nograph.json" SHIP_REMOTE_INDEX="D:/idx/index.sqlite" \
    "$REAL_BASH" "$SCRIPT" --dry-run 2>&1) || rc=$?
assert_rc "dry-run with override rc 0" 0 "$rc"
assert_contains "dry-run shows the override value" "D:/idx/index.sqlite" "$out"
assert_contains "dry-run labels it an override" "SHIP_REMOTE_INDEX override" "$out"
assert_not_contains "dry-run does not claim it will be derived" "derived from the receiver's" "$out"

echo "TEST: SHIP_REMOTE_* overrides skip the receiver query entirely"
reset_calls
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" \
    GRAPHIFY_GRAPH_PATH="$TMP_ROOT/nograph.json" \
    SHIP_REMOTE_INDEX="D:/idx/index.sqlite" SHIP_REMOTE_GRAPH="D:/idx/graph.json" \
    SHIP_REMOTE_TMP="D:/tmp" \
    "$REAL_BASH" "$SCRIPT" --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "explicit remote overrides rc 0" 0 "$rc"
assert_contains "used the override index path" "D:/idx/index.sqlite" "$out"
assert_not_contains "did NOT query the receiver profile" "USERPROFILE" "$(calls)"

echo "TEST: --collections overrides the receiver query"
reset_calls
rc=0; out=$(run_ship --no-reindex --no-graph --collections himmel 2>&1) || rc=$?
assert_rc "override rc 0" 0 "$rc"
assert_contains "reports the override" "explicit override: himmel" "$out"
assert_not_contains "did NOT query the receiver" "qmd collection list" "$(calls)"

echo "TEST: an unreadable receiver collection set is fatal, not a silent default"
reset_calls
touch "$STATE/no-remote-collections"
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "unreadable receiver set rc 2" 2 "$rc"
assert_contains "suggests the explicit override" "--collections" "$out"
assert_not_contains "nothing uploaded" "scp " "$(calls)"

# ============================================================================
echo "TEST: failures are attributed to the right stage"
# ============================================================================
reset_calls
touch "$STATE/prepare-fail"
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "prepare failure rc 4" 4 "$rc"
assert_contains "prepare failure says nothing shipped" "NOTHING shipped" "$out"
assert_not_contains "no upload after a failed prepare" "scp " "$(calls)"

echo "TEST: unparseable prepare metadata does NOT silently disable verification"
# The receiver treats a NEGATIVE expectation as "skip this check", so an
# unparsed count sailing through as -1 would quietly turn the post-swap
# doc/vector verification into a no-op — the ship would report success while
# having verified nothing.
reset_calls
touch "$STATE/prepare-badjson"
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "unparseable counts rc 4" 4 "$rc"
assert_contains "explains the verification would be disabled" "verification disabled" "$out"
assert_not_contains "nothing uploaded on unusable counts" "scp " "$(calls)"

reset_calls
touch "$STATE/scp-fail"
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "upload failure rc 5" 5 "$rc"
assert_contains "upload failure says the receiver is untouched" "receiver untouched" "$out"

reset_calls
touch "$STATE/remote-fail"
rc=0; out=$(run_ship --no-reindex --no-graph 2>&1) || rc=$?
assert_rc "receiver failure rc 6" 6 "$rc"
assert_contains "points at the receiver's own output" "SHIP-REMOTE" "$out"

# ============================================================================
echo "TEST: the receiver script's Fail() preserves its stage-specific exit code"
# ============================================================================
# Regression pin for CR finding [codex-1]. ship-index-remote.ps1 runs under
# $ErrorActionPreference='Stop', where Write-Error raises a TERMINATING error —
# so a `Write-Error ...; exit $code` Fail() never reaches the exit and the
# script dies with PowerShell's generic status 1. That collapses every documented
# stage code into "1", destroying the distinction that matters most after a
# failure: 3 = index NOT swapped vs 4 = index WAS swapped.
#
# Extract the REAL Fail() from the shipped script (so this cannot drift from it)
# and assert a non-1 code survives. Skipped where powershell is unavailable.
# ============================================================================
echo "TEST: the receiver script is ASCII-only and PARSES"
# ============================================================================
# Both halves of a real bug. The file is UTF-8, but Windows PowerShell 5.1 reads
# a BOM-less script with the ANSI codepage: a UTF-8 em dash (E2 80 94) decodes
# to three chars ending in U+201D RIGHT DOUBLE QUOTATION MARK — which PowerShell
# accepts AS A STRING DELIMITER. One em dash inside a double-quoted string
# desyncs every quote after it. Measured: 18 em dashes produced 4 parse errors,
# i.e. the receiver would not have run on win2 AT ALL. Assert both the byte-level
# rule (cheap, runs everywhere) and a real parse (where powershell exists).
if LC_ALL=C grep -qP '[^\x00-\x7F]' "$SCRIPT_DIR/ship-index-remote.ps1" 2>/dev/null; then
    fail "receiver script contains non-ASCII bytes" \
        "PowerShell 5.1 mis-decodes them under the ANSI codepage; keep this file ASCII-only"
else
    pass "receiver script is ASCII-only"
fi

PS_BIN="$(command -v powershell 2>/dev/null || command -v pwsh 2>/dev/null || true)"
if [ -n "$PS_BIN" ]; then
    PARSE_PROBE="$TMP_ROOT/parse-probe.ps1"
    cat >"$PARSE_PROBE" <<'PARSE_EOF'
param([Parameter(Mandatory=$true)][string]$Path)
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path).Path, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    foreach ($e in $errs) { Write-Output ("line " + $e.Extent.StartLineNumber + ": " + $e.Message) }
    exit 1
}
exit 0
PARSE_EOF
    parse_rc=0
    parse_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PARSE_PROBE" -Path "$SCRIPT_DIR/ship-index-remote.ps1" 2>&1) || parse_rc=$?
    assert_rc "receiver script parses with 0 errors" 0 "$parse_rc"
    [ "$parse_rc" -eq 0 ] || printf '    %s\n' "$parse_out"
fi


if [ -z "$PS_BIN" ]; then
    echo "  SKIP: no powershell/pwsh on this host (receiver-script check)"
else
    PS_PROBE="$TMP_ROOT/fail-probe.ps1"
    {
        # shellcheck disable=SC2016  # PowerShell variable, must stay literal
        echo '$ErrorActionPreference = "Stop"'
        # the Fail() body as actually shipped
        sed -n '/^function Fail(/,/^}/p' "$SCRIPT_DIR/ship-index-remote.ps1"
        echo 'Fail 5 "probe"'
    } > "$PS_PROBE"
    if ! grep -q 'function Fail(' "$PS_PROBE"; then
        fail "could not extract Fail() from ship-index-remote.ps1" "the function shape changed; update this test"
    else
        ps_rc=0
        "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PS_PROBE" >/dev/null 2>&1 || ps_rc=$?
        assert_rc "Fail 5 really exits 5 (not collapsed to 1)" 5 "$ps_rc"
    fi
fi

summary
