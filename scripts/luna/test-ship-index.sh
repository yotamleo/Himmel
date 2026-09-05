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
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ship-index-test.XXXXXX")
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
      # rc 6 (HIMMEL-1416 round 4): the PRIMARY receiver contract (swap +
      # plain daemon + verify) fully succeeded -- only the HTTP-singleton
      # daemon restore failed. Distinct from remote-fail above (a genuine
      # transport failure, rc 5).
      if [ -e "$STATE/remote-http-restore-fail" ]; then
          echo "SHIP-REMOTE: verified=ok"
          echo "SHIP-REMOTE: http_daemon_restored=FAILED" >&2
          exit 6
      fi
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
assert_contains "dry-run labels the per-invocation remote suffix as a <run-tag> template" "<run-tag>" "$out"
assert_not_contains "dry-run does not claim a fixed index upload name the real run would not use" "qmd-index.incoming.sqlite" "$out"
# REMOTE_TMP is resolved to the receiver's AppData/Local/Temp only AFTER the
# dry-run exits (resolve_remote_paths), so it is empty here. A naive
# interpolation printed "win2:/qmd-index..." -- a misleading root-level path
# in exactly the safety preview an operator validates the swap target with.
# Default mode must show a truthful <receiver-user-profile>/... placeholder
# instead, and must NOT emit the bare host-colon-slash root path.
assert_contains "dry-run shows a receiver-tmp placeholder for the upload destination" "<receiver-user-profile>/AppData/Local/Temp" "$out"
assert_contains "dry-run labels the tmp default as derived at run time" "(derived at run time)" "$out"
assert_not_contains "dry-run default mode prints NO bare host-colon-slash tmp path" "win2:/qmd-index" "$out"
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
# ship-index.sh also resolves ensure-qmd-daemon.ps1 from ../qmd relative to its
# OWN directory (HIMMEL-1416 round 2) -- mirror that sibling layout here too,
# or the preflight existence check dies rc 2 before reaching anything this
# sandbox exists to exercise.
mkdir -p "$SANDBOX/../qmd"
cp "$SCRIPT_DIR/../qmd/ensure-qmd-daemon.ps1" "$SANDBOX/../qmd/"
printf '#!/bin/sh\necho "reindex exploded" >&2\nexit 3\n' > "$SANDBOX/qmd-reindex.sh"
chmod +x "$SANDBOX/qmd-reindex.sh"
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" \
    "$REAL_BASH" "$SANDBOX/ship-index.sh" --no-graph 2>&1) || rc=$?
assert_rc "failed reindex rc 3" 3 "$rc"
assert_contains "says nothing was shipped" "NOTHING shipped" "$out"
assert_not_contains "no upload attempted after a failed reindex" "scp " "$(calls)"

# ============================================================================
echo "TEST: the pinned qmd is forwarded to the reindex leg (HIMMEL-1286)"
# ============================================================================
# WHY THIS MATTERS: qmd-reindex.sh resolves qmd through qmd_pinned_invocation,
# which needs `command -v bun` (or a bare `command -v qmd`) to succeed. A
# scheduler fires with a MINIMAL PATH carrying neither, so before this passthrough
# existed every unattended ship died at rc 3 having shipped nothing — i.e. the
# script could not be put on a cadence at all, which is what HIMMEL-1286's
# push-only transport requires. The assertion is on the ARGS the reindex leg
# actually received, not on a log line, so a silently-dropped forward fails here.
ARGS_FILE="$TMP_ROOT/reindex-args.txt"
# One argument PER LINE, not "$*". Joining collapses argv into a string, so a
# flag and its value fused into a single argument would still satisfy a
# substring assertion — the exact defect the forwarding must not have.
# The stub also stamps `__invoked__` before its argv. Without that marker the
# NEGATIVE assertion below ("an unpinned run forwards nothing") passes just as
# happily when qmd-reindex.sh was never reached at all — and run_sandbox_ship
# swallows ship-index.sh's exit code, so a script that died before the reindex
# leg would read as a clean pass. Absence of a flag only means something once
# the stub proves it ran.
printf '#!/bin/sh\nprintf "__invoked__\\n" > "%s"\nprintf "%%s\\n" "$@" >> "%s"\nexit 0\n' \
    "$ARGS_FILE" "$ARGS_FILE" > "$SANDBOX/qmd-reindex.sh"
chmod +x "$SANDBOX/qmd-reindex.sh"
FAKE_QMD="$TMP_ROOT/fake-qmd-bin"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_QMD"
chmod +x "$FAKE_QMD"

run_sandbox_ship() {
    env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" \
        "$REAL_BASH" "$SANDBOX/ship-index.sh" --no-graph "$@" 2>&1 || true
}

# assert_arg_pair NAME FLAG VALUE FILE — FLAG and VALUE must appear as ADJACENT
# lines, in that order.
#
# A two-line needle handed to `grep -F` does NOT do this: grep -F treats each
# line of the pattern as a SEPARATE fixed string and ORs them, so
# `assert_contains "--qmd-bin\n<path>"` passed when only `--qmd-bin` was
# present — with its value dropped, fused to it, or somewhere else entirely.
# That is the exact defect these assertions exist to catch, so the assertion
# itself has to be positional.
assert_arg_pair() {
    local name="$1" flag="$2" val="$3" file="$4"
    if awk -v f="$flag" -v v="$val" '
            prev == f && $0 == v { found = 1 }
            { prev = $0 }
            END { exit !found }' "$file"; then
        pass "$name"
    else
        fail "$name" "no adjacent '$flag' -> '$val' in $(printf '%s' "$(cat "$file")" | tr '\n' '|')"
    fi
}

: > "$ARGS_FILE"
run_sandbox_ship --qmd-bin "$FAKE_QMD" >/dev/null
assert_contains "the reindex leg actually ran" "__invoked__" "$(cat "$ARGS_FILE")"
assert_arg_pair "--qmd-bin reaches qmd-reindex.sh with its value" "--qmd-bin" "$FAKE_QMD" "$ARGS_FILE"

# BOTH halves of the pair, in the same run: a bun-served qmd is only invocable
# as `<bun> <qmd.js>`, so forwarding one token without the other pins something
# that cannot run. Asserting only --qmd-js here would have missed a dropped
# --qmd-bin entirely.
# DISTINCT fixtures for the two halves. Passing $FAKE_QMD as both would let
# ship-index.sh forward the wrong variable — `--qmd-js "$QMD_BIN"` — and still
# satisfy every assertion, which is the specific mistake a paired-flag
# passthrough is most likely to make.
FAKE_QMD_JS="$TMP_ROOT/fake-qmd.js"
printf 'console.log("stub");\n' > "$FAKE_QMD_JS"
: > "$ARGS_FILE"
run_sandbox_ship --qmd-bin "$FAKE_QMD" --qmd-js "$FAKE_QMD_JS" >/dev/null
assert_arg_pair "--qmd-bin survives the paired form" "--qmd-bin" "$FAKE_QMD" "$ARGS_FILE"
assert_arg_pair "--qmd-js rides along with its OWN value" "--qmd-js" "$FAKE_QMD_JS" "$ARGS_FILE"

# The interactive path must be untouched: no pin passed => nothing forwarded, so
# qmd-reindex.sh keeps resolving qmd itself exactly as it did before.
: > "$ARGS_FILE"
run_sandbox_ship >/dev/null
assert_contains "an unpinned run still reaches the reindex leg" "__invoked__" "$(cat "$ARGS_FILE")"
assert_not_contains "an unpinned run forwards no --qmd-bin" "--qmd-bin" "$(cat "$ARGS_FILE")"
# Both halves, not just the one: asserting only --qmd-bin's absence would miss a
# stray --qmd-js leaking through on its own, which qmd-reindex.sh rejects as a
# usage error — so the unattended run would die at rc 1 having shipped nothing.
assert_not_contains "an unpinned run forwards no --qmd-js either" "--qmd-js" "$(cat "$ARGS_FILE")"

# --qmd-js is the SCRIPT ARG for --qmd-bin, never a standalone qmd.
rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
    "$SANDBOX/ship-index.sh" --no-graph --qmd-js "$FAKE_QMD" >/dev/null 2>&1 || rc=$?
assert_rc "--qmd-js without --qmd-bin is refused" 1 "$rc"

# A pin that cannot run is a 05:00 failure waiting to happen — refuse at invoke
# time rather than forwarding it and failing deeper in.
rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
    "$SANDBOX/ship-index.sh" --no-graph --qmd-bin "relative/qmd" >/dev/null 2>&1 || rc=$?
assert_rc "a relative --qmd-bin is refused" 1 "$rc"
rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
    "$SANDBOX/ship-index.sh" --no-graph --qmd-bin "$TMP_ROOT/not-there" >/dev/null 2>&1 || rc=$?
assert_rc "a MISSING --qmd-bin is refused" 2 "$rc"
# A file that EXISTS but is not executable exercises the `! -x` branch, which
# the missing-file case above never reaches — the assertion was named for a
# check it was not performing. The fixture carries NO shebang on purpose: MSYS
# reports a shebanged file as -x regardless of its mode, so only a plain file
# can test this on Git Bash.
NOT_EXEC="$TMP_ROOT/not-executable-qmd"
printf 'not a program\n' > "$NOT_EXEC"
chmod 644 "$NOT_EXEC"
if [ -x "$NOT_EXEC" ]; then
    pass "non-executable --qmd-bin SKIPPED (this filesystem reports 644 as -x)"
else
    rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
        "$SANDBOX/ship-index.sh" --no-graph --qmd-bin "$NOT_EXEC" >/dev/null 2>&1 || rc=$?
    assert_rc "a present-but-non-executable --qmd-bin is refused" 2 "$rc"
fi

# With --no-reindex there is no reindex leg to pin, so the pin is inert and must
# not be validated into a spurious failure.
rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
    "$SANDBOX/ship-index.sh" --no-graph --no-reindex --qmd-bin "relative/qmd" >/dev/null 2>&1 || rc=$?
assert_rc "--no-reindex makes the pin inert, not fatal" 0 "$rc"

# The `=` spelling must validate like the space form. An empty `--qmd-bin=` (an
# unset var expanding to nothing) would otherwise forward NO pin and recreate
# the unpinned-scheduler failure this passthrough exists to prevent — silently,
# at 05:00, having shipped nothing.
rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
    "$SANDBOX/ship-index.sh" --no-graph "--qmd-bin=" >/dev/null 2>&1 || rc=$?
assert_rc "--qmd-bin= (empty, = form) is rc 1, not a silent unpin" 1 "$rc"
rc=0; env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" "$REAL_BASH" \
    "$SANDBOX/ship-index.sh" --no-graph "--qmd-js=" >/dev/null 2>&1 || rc=$?
assert_rc "--qmd-js= (empty, = form) is rc 1" 1 "$rc"
# And the = form still WORKS when given a real value.
: > "$ARGS_FILE"
run_sandbox_ship "--qmd-bin=$FAKE_QMD" >/dev/null
assert_arg_pair "--qmd-bin= forwards a real value" "--qmd-bin" "$FAKE_QMD" "$ARGS_FILE"

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
# HIMMEL-1416 round 2: ensure-qmd-daemon.ps1 rides along so the receiver can
# restore the HTTP-singleton MCP daemon if the stop sweep kills it.
assert_contains "uploaded ensure-qmd-daemon.ps1 alongside the receiver script" "ensure-qmd-daemon" "$(calls)"
assert_contains "passed -EnsureScript to the receiver invocation" "-EnsureScript" "$(calls)"

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

echo "TEST: dry-run shows a SHIP_REMOTE_TMP override in the upload destinations"
# The other half of the truthful-remote-tmp fix. With an explicit
# SHIP_REMOTE_TMP, the dry-run must print the override value (not the
# <receiver-user-profile> placeholder) in the upload destinations, and label
# it as the override -- mirroring the SHIP_REMOTE_INDEX override line above.
reset_calls
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" \
    GRAPHIFY_GRAPH_PATH="$TMP_ROOT/nograph.json" SHIP_REMOTE_TMP="D:/tmp/ship" \
    "$REAL_BASH" "$SCRIPT" --dry-run 2>&1) || rc=$?
assert_rc "dry-run with SHIP_REMOTE_TMP override rc 0" 0 "$rc"
assert_contains "dry-run shows the tmp override value in the upload destination" "D:/tmp/ship/qmd-index.incoming.<run-tag>.sqlite" "$out"
assert_contains "dry-run labels the tmp override" "SHIP_REMOTE_TMP override" "$out"
assert_not_contains "dry-run does not show the receiver-tmp placeholder when overridden" "<receiver-user-profile>" "$out"

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
echo "TEST: receiver rc 6 (HTTP restore failed) still runs the graph leg and exits 8 (HIMMEL-1416 round 4 [codex-adv-6])"
# ============================================================================
# The receiver's PRIMARY contract (swap + plain daemon + verify) succeeded --
# only its secondary HTTP-daemon restore failed. This must NOT take the
# generic die-6 "receiver-side ship failed" path above (that would skip the
# graph leg entirely, recreating the exact blocked-graph-leg bug this ticket
# already fixed once for a different reason) -- it must run the graph leg
# normally and THEN exit non-zero (8) so unattended automation still gets a
# signal, rather than a silent, misleadingly clean 0.
reset_calls
touch "$STATE/remote-http-restore-fail"
REAL_GRAPH="$TMP_ROOT/real-graph-for-rc6-test.json"
printf '{"nodes":[]}' > "$REAL_GRAPH"
rc=0; out=$(env PATH="$BIN:$PATH" QMD_INDEX_PATH="$FAKE_INDEX" GRAPHIFY_GRAPH_PATH="$REAL_GRAPH" \
    "$REAL_BASH" "$SCRIPT" --no-reindex 2>&1) || rc=$?
assert_rc "receiver rc 6 -> sender exits 8 (not 0, not the generic die-6)" 8 "$rc"
assert_contains "warns loudly about the HTTP restore failure" "HTTP-singleton MCP daemon restore FAILED" "$out"
assert_contains "the graph leg actually ran (shipped the real graph file)" "graph shipped" "$out"
assert_not_contains "did NOT take the generic die-6 receiver-failure path" "receiver-side ship failed" "$out"

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

# ============================================================================
echo "TEST: Test-IsQmdHostProcess matches all qmd-hosting process shapes (HIMMEL-1416)"
# ============================================================================
# Regression pin for the live stop-sweep miss: a bun.exe-only filter left a
# compiled qmd.exe and a node-hosted qmd.js MCP daemon running through four
# straight ship failures (rc=6 "file being used by another process",
# stopped_pids=none every time; two holders had to be killed by hand over
# ssh). Extract the REAL function (so this cannot drift from it) and probe it
# against every shape the sweep must now catch, plus the shapes it must still
# leave alone.
if [ -z "$PS_BIN" ]; then
    echo "  SKIP: no powershell/pwsh on this host (Test-IsQmdHostProcess check)"
else
    HOST_PROBE="$TMP_ROOT/qmdhost-probe.ps1"
    {
        sed -n '/^function Test-IsQmdHostProcess/,/^}/p' "$SCRIPT_DIR/ship-index-remote.ps1"
        cat <<'HOST_EOF'
$cases = @(
    @{ Name = 'bun.exe';  Cmd = '"C:\Users\op\.bun\bin\qmd.exe" mcp --keep-models'; Want = $true;  Label = 'bun.exe launching a qmd.exe command line' }
    @{ Name = 'bun.exe';  Cmd = '"C:\Users\op\.bun\bin\bun.exe" run --cwd C:\plugins\luna-correlate\0.2.0 --shell=bun --silent start'; Want = $false; Label = 'unrelated bun.exe (luna-correlate)' }
    @{ Name = 'qmd.exe';  Cmd = '"C:\Users\op\.bun\bin\qmd.exe" mcp --keep-models'; Want = $true;  Label = 'qmd.exe compiled binary (HIMMEL-1416, invisible to a bun.exe-only filter)' }
    @{ Name = 'qmd.exe';  Cmd = $null; Want = $true;  Label = 'qmd.exe with no visible command line -- access-denied to an elevated/other-session process, exactly the Services-session case (CR codex-1)' }
    @{ Name = 'node.exe'; Cmd = 'node "C:\Users\op\.bun\install\global\node_modules\@tobilu\qmd\dist\cli\qmd.js" mcp --http --daemon'; Want = $true;  Label = 'node-hosted qmd.js HTTP-singleton daemon (HIMMEL-592)' }
    @{ Name = 'node.exe'; Cmd = 'node C:\some\other\app\server.js --port 3000'; Want = $false; Label = 'unrelated node.exe' }
    @{ Name = 'node.exe'; Cmd = $null; Want = $false; Label = 'node.exe with no command line -- the null guard still applies to non-qmd.exe shapes' }
)
$failed = $false
foreach ($c in $cases) {
    $got = Test-IsQmdHostProcess -Name $c.Name -CommandLine $c.Cmd
    if ($got -ne $c.Want) {
        Write-Output "MISMATCH: $($c.Label) -> got $got, want $($c.Want)"
        $failed = $true
    }
}
if ($failed) { exit 1 } else { exit 0 }
HOST_EOF
    } > "$HOST_PROBE"
    if ! grep -q 'function Test-IsQmdHostProcess' "$HOST_PROBE"; then
        fail "could not extract Test-IsQmdHostProcess from ship-index-remote.ps1" "the function shape changed; update this test"
    else
        host_rc=0
        host_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$HOST_PROBE" 2>&1) || host_rc=$?
        assert_rc "Test-IsQmdHostProcess matches every qmd-hosting shape and only those" 0 "$host_rc"
        [ "$host_rc" -eq 0 ] || printf '    %s\n' "$host_out"
    fi
fi

# ============================================================================
echo "TEST: Test-IsHttpDaemonProcess flags the HTTP-singleton daemon shape (HIMMEL-1416 round 2)"
# ============================================================================
# Round-2 CR [codex-adv-2], verified: Start-QmdDaemon's own restart relaunches
# only the plain `mcp --keep-models` form, never the HIMMEL-592 HTTP-singleton
# daemon (`mcp --http --daemon`). This function decides whether a STOPPED
# process was that HTTP daemon, so the restart step knows to restore it via
# ensure-qmd-daemon.ps1. Matched on CommandLine alone (not process name): the
# daemon can be bun- or node-hosted, but ensure-qmd-daemon.ps1 always launches
# it with `--http`, which the plain daemon's command line never carries.
if [ -z "$PS_BIN" ]; then
    echo "  SKIP: no powershell/pwsh on this host (Test-IsHttpDaemonProcess check)"
else
    HTTP_PROBE="$TMP_ROOT/httpdaemon-probe.ps1"
    {
        sed -n '/^function Test-IsHttpDaemonProcess/,/^}/p' "$SCRIPT_DIR/ship-index-remote.ps1"
        cat <<'HTTP_EOF'
$cases = @(
    @{ Cmd = '"C:\Users\op\.bun\bin\qmd.exe" mcp --http --daemon'; Want = $true;  Label = 'qmd.exe HTTP-singleton daemon' }
    @{ Cmd = 'node "C:\Users\op\.bun\install\global\node_modules\@tobilu\qmd\dist\cli\qmd.js" mcp --http --daemon'; Want = $true;  Label = 'node-hosted qmd.js HTTP-singleton daemon' }
    @{ Cmd = '"C:\Users\op\.bun\bin\qmd.exe" mcp --keep-models'; Want = $false; Label = 'the plain stdio daemon Start-QmdDaemon itself relaunches' }
    @{ Cmd = $null; Want = $false; Label = 'no command line at all' }
)
$failed = $false
foreach ($c in $cases) {
    $got = Test-IsHttpDaemonProcess -CommandLine $c.Cmd
    if ($got -ne $c.Want) {
        Write-Output "MISMATCH: $($c.Label) -> got $got, want $($c.Want)"
        $failed = $true
    }
}
if ($failed) { exit 1 } else { exit 0 }
HTTP_EOF
    } > "$HTTP_PROBE"
    if ! grep -q 'function Test-IsHttpDaemonProcess' "$HTTP_PROBE"; then
        fail "could not extract Test-IsHttpDaemonProcess from ship-index-remote.ps1" "the function shape changed; update this test"
    else
        http_rc=0
        http_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$HTTP_PROBE" 2>&1) || http_rc=$?
        assert_rc "Test-IsHttpDaemonProcess flags --http command lines and only those" 0 "$http_rc"
        [ "$http_rc" -eq 0 ] || printf '    %s\n' "$http_out"
    fi
fi

# ============================================================================
echo "TEST: Get-ShipVerdict fails on any doc-count mismatch (HIMMEL-1416 round 2)"
# ============================================================================
# Round-2 CR [codex-adv-1], verified against the qmd fork source: the live
# false-fail (receiver docs 14844 != sender-staged docs 15189, despite vectors
# 52967==52967 and pending 0) was a PREDICATE mismatch -- qmd status counts
# `WHERE active = 1`, prepare-ship-index.mjs staged a bare COUNT(*). Now that
# the sender counts with the same active=1 predicate, a genuine post-swap
# mismatch means something is actually wrong, so it goes back to being a HARD
# failure -- same as an unparseable count. The 14844/15189 regression values
# are asserted FATAL here: the fix for the live incident is the sender
# predicate change (prepare-ship-index.mjs), not tolerance in this function.
if [ -z "$PS_BIN" ]; then
    echo "  SKIP: no powershell/pwsh on this host (Get-ShipVerdict check)"
else
    VERDICT_PROBE="$TMP_ROOT/verdict-probe.ps1"
    {
        sed -n '/^function Get-ShipVerdict/,/^}/p' "$SCRIPT_DIR/ship-index-remote.ps1"
        cat <<'VERDICT_EOF'
function Check($label, $got, $wantFailCode) {
    if ($got.FailCode -ne $wantFailCode) {
        Write-Output "MISMATCH: $label -> FailCode=$($got.FailCode) (want FailCode=$wantFailCode)"
        return $false
    }
    return $true
}
$ok = $true
if (-not (Check 'unparsed vectors is fatal' (Get-ShipVerdict -Docs 100 -Vecs $null -Pending 0 -ExpectDocs -1 -ExpectVectors -1) 5)) { $ok = $false }
if (-not (Check 'unparsed docs is fatal' (Get-ShipVerdict -Docs $null -Vecs 100 -Pending 0 -ExpectDocs -1 -ExpectVectors -1) 5)) { $ok = $false }
if (-not (Check 'pending>0 is fatal' (Get-ShipVerdict -Docs 100 -Vecs 100 -Pending 3 -ExpectDocs -1 -ExpectVectors -1) 5)) { $ok = $false }
if (-not (Check 'vector count mismatch is fatal' (Get-ShipVerdict -Docs 100 -Vecs 90 -Pending 0 -ExpectDocs -1 -ExpectVectors 100) 5)) { $ok = $false }
if (-not (Check 'doc count mismatch is fatal' (Get-ShipVerdict -Docs 90 -Vecs 100 -Pending 0 -ExpectDocs 100 -ExpectVectors -1) 5)) { $ok = $false }
if (-not (Check 'live regression (14844 vs 15189) is now FATAL, not tolerated' (Get-ShipVerdict -Docs 14844 -Vecs 52967 -Pending 0 -ExpectDocs 15189 -ExpectVectors 52967) 5)) { $ok = $false }
if (-not (Check 'same-predicate counts equal -> clean verify' (Get-ShipVerdict -Docs 100 -Vecs 100 -Pending 0 -ExpectDocs 100 -ExpectVectors 100) 0)) { $ok = $false }
if ($ok) { exit 0 } else { exit 1 }
VERDICT_EOF
    } > "$VERDICT_PROBE"
    if ! grep -q 'function Get-ShipVerdict' "$VERDICT_PROBE"; then
        fail "could not extract Get-ShipVerdict from ship-index-remote.ps1" "the function shape changed; update this test"
    else
        verdict_rc=0
        verdict_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$VERDICT_PROBE" 2>&1) || verdict_rc=$?
        assert_rc "Get-ShipVerdict: doc/vector count mismatches and unparseable counts are all hard failures" 0 "$verdict_rc"
        [ "$verdict_rc" -eq 0 ] || printf '    %s\n' "$verdict_out"
    fi
fi

# ============================================================================
echo "TEST: Invoke-EnsureRestore is wired into every post-sweep exit path (HIMMEL-1416 round 3)"
# ============================================================================
# Round-3 [codex-adv-3]/[codex-adv-4]: the restore must be UNCONDITIONAL and
# run on every post-sweep exit, not gated on classifying what was stopped, and
# not just on the happy path. These drive the REAL ship-index-remote.ps1
# end-to-end -- dot-sourced verbatim, so its own functions run unmodified, no
# sed extraction and no drift risk -- with the WMI/process cmdlets it calls
# fault-injected via function shadowing (Get-CimInstance, Stop-Process,
# Invoke-CimMethod, Get-Command). Fixture-level fault injection throughout;
# never a live process, a real qmd binary, or a real bun/node daemon.
if [ -z "$PS_BIN" ]; then
    echo "  SKIP: no powershell/pwsh on this host (Invoke-EnsureRestore wiring check)"
else
    REAL_REMOTE_SCRIPT="$SCRIPT_DIR/ship-index-remote.ps1"

    # Git-Bash auto-translates a POSIX path to its Windows form ONLY when the
    # path is its OWN whole argv token on a command line handed to a native
    # (non-MSYS) process -- which is why `-File "$SOME_PROBE"` elsewhere in
    # this suite just works. It does NOT reach into a path written as literal
    # TEXT inside a generated .ps1 file's CONTENT: PowerShell's own parser
    # reads that text directly, with zero Git-Bash involvement, so a bare
    # "/c/Users/..." or "/tmp/..." string there is parsed as a literal
    # (nonexistent) path and fails with CommandNotFoundException /
    # DirectoryNotFoundException. Every path embedded INSIDE a probe file
    # below (dot-source args, $env:SENTINEL_PATH, the $env:PATH prepend, and
    # the -Command string in make_staged) needs this explicit conversion;
    # bash-side operations (mkdir, printf >, rm -f, [ -f ]) keep using the
    # original bash-native path throughout -- both spellings name the
    # identical file, bash just needs its own.
    winpath() {
        local w
        w="$(cygpath -w "$1" 2>/dev/null)"
        if [ -n "$w" ]; then printf '%s' "$w" | tr "\\\\" "/"; else printf '%s' "$1"; fi
    }

    # A staged index must exist and be >=50MB to pass ship-index-remote.ps1's
    # own truncation guard -- write one for real rather than special-casing
    # that guard, so these tests exercise it too instead of routing around it.
    make_staged() {
        "$PS_BIN" -NoProfile -ExecutionPolicy Bypass -Command \
            "[System.IO.File]::WriteAllBytes('$(winpath "$1")', (New-Object byte[] 52428800))"
    }
    # Shared fake ensure-script body: touches $env:SENTINEL_PATH and exits 0 --
    # standing in for the real ensure-qmd-daemon.ps1 without starting anything.
    make_fake_ensure() {
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf 'New-Item -ItemType File -Force -Path $env:SENTINEL_PATH | Out-Null\nexit 0\n' > "$1"
    }

    # The separator PowerShell actually splits $env:PATH on for THIS OS:
    # ';' under real Windows PowerShell (Git-Bash/MSYS), ':' under pwsh on
    # Linux/macOS. A hardcoded ';' on non-Windows collapses the whole
    # prepended entry into ONE bogus path segment -- the directory inside it
    # is never resolved at all, regardless of what stub lives there.
    ps_path_sep() {
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*) printf ';' ;;
            *) printf ':' ;;
        esac
    }

    # Emits a `$env:PATH = "..."` line prepending one or more directories
    # ahead of the inherited PATH, using the OS-appropriate separator so the
    # generated probe resolves stubs on both real Windows PowerShell and pwsh
    # on Linux.
    ps_prepend_path_line() {
        local sep joined d w
        sep="$(ps_path_sep)"
        joined=""
        for d in "$@"; do
            [ -z "$d" ] && continue
            w="$(winpath "$d")"
            joined="${joined}${w}${sep}"
        done
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf '$env:PATH = "%s" + $env:PATH\n' "$joined"
    }

    # Fake `qmd status`, resolvable as a bare `qmd` on PATH. Real Windows
    # PowerShell resolves an extensionless command through PATHEXT, so a
    # .cmd batch file works there -- but pwsh on non-Windows does NOT do
    # PATHEXT-style resolution: it needs a file literally named `qmd`,
    # executable, with a shebang. Without this, `& qmd status` throws
    # CommandNotFoundException on Linux (measured: exactly the "qmd status
    # failed after swap: The term 'qmd' is not recognized" failure on the
    # ubuntu CI runner).
    make_qmd_stub() {
        local dir="$1"
        mkdir -p "$dir"
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                {
                    printf '@echo off\r\n'
                    printf 'echo QMD Status\r\n'
                    printf 'echo.\r\n'
                    printf 'echo Documents\r\n'
                    printf 'echo   Total:    100 files indexed\r\n'
                    printf 'echo   Vectors:  100 embedded\r\n'
                    printf 'exit /b 0\r\n'
                } > "$dir/qmd.cmd"
                ;;
            *)
                {
                    printf '#!/bin/sh\n'
                    printf 'echo "QMD Status"\n'
                    printf 'echo\n'
                    printf 'echo "Documents"\n'
                    printf 'echo "  Total:    100 files indexed"\n'
                    printf 'echo "  Vectors:  100 embedded"\n'
                    printf 'exit 0\n'
                } > "$dir/qmd"
                chmod +x "$dir/qmd"
                ;;
        esac
    }

    # Fake `powershell`, forwarding to $PS_BIN. ship-index-remote.ps1's
    # Invoke-EnsureRestore hardcodes a literal `powershell` invocation to
    # relaunch the ensure script as a genuinely separate process -- correct
    # on the real receiver (win2, real Windows PowerShell 5.1), but
    # `powershell` does not exist at all on the Linux CI runner (only
    # `pwsh`), so that call throws CommandNotFoundException and the ensure
    # script body never runs (measured: SHIP-REMOTE: http_daemon_restored=
    # FAILED, and the sentinel file the ensure script writes never appears).
    # A same-named forwarding shim makes the hardcoded name resolve without
    # touching the CR-certified receiver script. Windows-only, real
    # `powershell` already resolves there -- and, measured, real Windows
    # PowerShell's own command resolution picks an extensionless same-named
    # PATH entry over the real powershell.exe rather than skipping it, so
    # shadowing it on Windows would break the real interpreter instead of
    # leaving it alone. PSSHIM_DIR stays empty (never prepended -- see
    # ps_prepend_path_line's blank-arg skip) on Windows.
    PSSHIM_DIR=""
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *)
            PSSHIM_DIR="$TMP_ROOT/psshim"
            mkdir -p "$PSSHIM_DIR"
            { printf '#!/bin/sh\nexec "%s" "$@"\n' "$PS_BIN"; } > "$PSSHIM_DIR/powershell"
            chmod +x "$PSSHIM_DIR/powershell"
            ;;
    esac

    # ---- (a) sweep-stopped-something + a genuine success path ----------------
    # The fullest form: also fakes `qmd status` on PATH so the run completes
    # with a real rc 0, proving the restore fires on an ACTUAL successful ship,
    # not just on a path that happens to call the function.
    SENT_A="$TMP_ROOT/sentinel-a.txt"; rm -f "$SENT_A"
    STAGED_A="$TMP_ROOT/staged-a.sqlite"; TARGET_A="$TMP_ROOT/target-a.sqlite"
    make_staged "$STAGED_A"
    printf 'old-index' > "$TARGET_A"
    ENSURE_A="$TMP_ROOT/ensure-a.ps1"; make_fake_ensure "$ENSURE_A"
    FAKEBIN_A="$TMP_ROOT/fakebin-a"; make_qmd_stub "$FAKEBIN_A"
    PROBE_A="$TMP_ROOT/wiring-success-probe.ps1"
    cat > "$PROBE_A" <<'PROBE_A_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @([pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 4242; CommandLine = '"C:\fake\qmd.exe" mcp --keep-models' })
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = 9999 }
}
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'qmd') { return [pscustomobject]@{ Source = 'qmd' } }
    return $null
}
PROBE_A_EOF
    {
        ps_prepend_path_line "$FAKEBIN_A" "$PSSHIM_DIR"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_A")"
        # `&`, NOT dot-source (`.`): a dot-sourced script's `exit` inside a
        # FUNCTION (Fail(), here) does not propagate as this WRAPPER's own
        # process exit code -- measured empirically, it comes back 0 every
        # time regardless of the real code. `&` runs it as a child script
        # invocation instead: its `exit N` sets $LASTEXITCODE correctly in
        # the caller, while fake functions defined above (Get-CimInstance
        # etc.) remain visible to it via normal PowerShell scope inheritance.
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s" -ExpectDocs 100 -ExpectVectors 100\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_A")" "$(winpath "$TARGET_A")" "$(winpath "$ENSURE_A")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_A"
    a_rc=0
    a_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_A" 2>&1) || a_rc=$?
    assert_rc "(a) success path: the real script exits 0 (transport verified)" 0 "$a_rc"
    [ "$a_rc" -eq 0 ] || printf '    %s\n' "$a_out"
    if [ -f "$SENT_A" ]; then pass "(a) success path: Invoke-EnsureRestore actually ran the ensure script"; else fail "(a) success path: ensure script never ran"; fi

    # ---- (b) stop-failure AFTER a first successful stop -----------------------
    # Two qualifying processes; the first Stop-Process succeeds ($stopped
    # becomes non-empty), the second throws -- landing in the stop-sweep's own
    # catch with $stopped.Count -gt 0, before any swap is attempted.
    SENT_B="$TMP_ROOT/sentinel-b.txt"; rm -f "$SENT_B"
    STAGED_B="$TMP_ROOT/staged-b.sqlite"; TARGET_B="$TMP_ROOT/target-b.sqlite"
    make_staged "$STAGED_B"
    printf 'old-index' > "$TARGET_B"
    ENSURE_B="$TMP_ROOT/ensure-b.ps1"; make_fake_ensure "$ENSURE_B"
    PROBE_B="$TMP_ROOT/wiring-stopfail-probe.ps1"
    cat > "$PROBE_B" <<'PROBE_B_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @(
        [pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 4242; CommandLine = $null },
        [pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 4243; CommandLine = $null }
    )
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
    if ($Id -eq 4243) { throw 'Access is denied' }
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = 9999 }
}
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'qmd') { return [pscustomobject]@{ Source = 'qmd' } }
    return $null
}
PROBE_B_EOF
    {
        ps_prepend_path_line "$PSSHIM_DIR"
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_B")"
        # `&`, not dot-source -- see the comment on the (a) probe for why.
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s"\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_B")" "$(winpath "$TARGET_B")" "$(winpath "$ENSURE_B")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_B"
    b_rc=0
    b_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_B" 2>&1) || b_rc=$?
    assert_rc "(b) stop-failure after a partial stop: exits 2" 2 "$b_rc"
    [ "$b_rc" -eq 2 ] || printf '    %s\n' "$b_out"
    if [ -f "$SENT_B" ]; then pass "(b) stop-failure: Invoke-EnsureRestore ran before Fail 2"; else fail "(b) stop-failure: ensure script never ran"; fi
    # Round 4 [codex-adv-7]: this catch never attempted the PLAIN daemon form
    # before, leaving a stopped plain daemon down on a failed deploy. The fake
    # Invoke-CimMethod above (used by Start-QmdDaemon) reports success, so
    # Complete-PostSweepFailure's -AlsoRestartPlainDaemon attempt should Emit
    # a real PID here, not skip straight to the HTTP restore alone.
    assert_contains "(b) stop-failure: the PLAIN daemon restart was also attempted" "restarted_after_failure=9999" "$b_out"

    # ---- (c) swap-failure recovery ---------------------------------------------
    # The stop sweep succeeds cleanly ($stopped.Count -gt 0); the swap itself
    # fails because $Target's parent directory does not exist, so Move-Item
    # into it throws -- a genuine filesystem failure, not a faked cmdlet --
    # landing in the swap catch's rollback/restart-best-effort block.
    SENT_C="$TMP_ROOT/sentinel-c.txt"; rm -f "$SENT_C"
    STAGED_C="$TMP_ROOT/staged-c.sqlite"
    make_staged "$STAGED_C"
    TARGET_C="$TMP_ROOT/nonexistent-dir-c/target.sqlite"
    ENSURE_C="$TMP_ROOT/ensure-c.ps1"; make_fake_ensure "$ENSURE_C"
    PROBE_C="$TMP_ROOT/wiring-swapfail-probe.ps1"
    cat > "$PROBE_C" <<'PROBE_C_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @([pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 5000; CommandLine = $null })
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = 9999 }
}
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'qmd') { return [pscustomobject]@{ Source = 'qmd' } }
    return $null
}
PROBE_C_EOF
    {
        ps_prepend_path_line "$PSSHIM_DIR"
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_C")"
        # `&`, not dot-source -- see the comment on the (a) probe for why.
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s"\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_C")" "$(winpath "$TARGET_C")" "$(winpath "$ENSURE_C")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_C"
    c_rc=0
    c_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_C" 2>&1) || c_rc=$?
    assert_rc "(c) swap-failure recovery: exits 3" 3 "$c_rc"
    [ "$c_rc" -eq 3 ] || printf '    %s\n' "$c_out"
    if [ -f "$SENT_C" ]; then pass "(c) swap-failure: Invoke-EnsureRestore ran during rollback recovery"; else fail "(c) swap-failure: ensure script never ran"; fi

    # ---- (d) Start-QmdDaemon returns null (round 4 [codex-adv-5]) -------------
    # The stop sweep and swap both succeed; the restart's Start-QmdDaemon
    # returns $null (Get-Command finds no qmd), landing in the `if (-not
    # $newPid)` branch that used to call Fail 4 directly -- BEFORE the HTTP
    # restore further down ever ran.
    SENT_D="$TMP_ROOT/sentinel-d.txt"; rm -f "$SENT_D"
    STAGED_D="$TMP_ROOT/staged-d.sqlite"; TARGET_D="$TMP_ROOT/target-d.sqlite"
    make_staged "$STAGED_D"
    printf 'old-index' > "$TARGET_D"
    ENSURE_D="$TMP_ROOT/ensure-d.ps1"; make_fake_ensure "$ENSURE_D"
    PROBE_D="$TMP_ROOT/wiring-restartnull-probe.ps1"
    cat > "$PROBE_D" <<'PROBE_D_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @([pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 6000; CommandLine = $null })
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = 9999 }
}
function Get-Command {
    param($Name, $ErrorAction)
    return $null
}
PROBE_D_EOF
    {
        ps_prepend_path_line "$PSSHIM_DIR"
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_D")"
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s"\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_D")" "$(winpath "$TARGET_D")" "$(winpath "$ENSURE_D")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_D"
    d_rc=0
    d_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_D" 2>&1) || d_rc=$?
    assert_rc "(d) Start-QmdDaemon returns null: exits 4" 4 "$d_rc"
    [ "$d_rc" -eq 4 ] || printf '    %s\n' "$d_out"
    if [ -f "$SENT_D" ]; then pass "(d) restart-returns-null: Invoke-EnsureRestore still ran before Fail 4"; else fail "(d) restart-returns-null: ensure script never ran"; fi

    # ---- (e) Start-QmdDaemon throws (round 4 [codex-adv-5]) --------------------
    # Same shape as (d), but Get-Command resolves qmd fine and Invoke-CimMethod
    # (the WMI process-create call inside Start-QmdDaemon) throws instead --
    # the OTHER branch that used to call Fail 4 directly.
    SENT_E="$TMP_ROOT/sentinel-e.txt"; rm -f "$SENT_E"
    STAGED_E="$TMP_ROOT/staged-e.sqlite"; TARGET_E="$TMP_ROOT/target-e.sqlite"
    make_staged "$STAGED_E"
    printf 'old-index' > "$TARGET_E"
    ENSURE_E="$TMP_ROOT/ensure-e.ps1"; make_fake_ensure "$ENSURE_E"
    PROBE_E="$TMP_ROOT/wiring-restartthrow-probe.ps1"
    cat > "$PROBE_E" <<'PROBE_E_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @([pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 7000; CommandLine = $null })
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    throw 'WMI create failed'
}
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'qmd') { return [pscustomobject]@{ Source = 'qmd' } }
    return $null
}
PROBE_E_EOF
    {
        ps_prepend_path_line "$PSSHIM_DIR"
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_E")"
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s"\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_E")" "$(winpath "$TARGET_E")" "$(winpath "$ENSURE_E")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_E"
    e_rc=0
    e_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_E" 2>&1) || e_rc=$?
    assert_rc "(e) Start-QmdDaemon throws: exits 4" 4 "$e_rc"
    [ "$e_rc" -eq 4 ] || printf '    %s\n' "$e_out"
    if [ -f "$SENT_E" ]; then pass "(e) restart-throws: Invoke-EnsureRestore still ran before Fail 4"; else fail "(e) restart-throws: ensure script never ran"; fi

    # ---- (f) restore FAILS after an otherwise-full success (round 4 [codex-adv-6]) --
    # The fullest form again (fakes `qmd status` too, like (a)), but this time
    # the ensure script itself touches the sentinel THEN exits 1 -- proving it
    # was genuinely invoked and failed, not merely skipped. The transport
    # verified cleanly; only the auxiliary HTTP-daemon restore failed, so this
    # must exit 6, not 0.
    SENT_F="$TMP_ROOT/sentinel-f.txt"; rm -f "$SENT_F"
    STAGED_F="$TMP_ROOT/staged-f.sqlite"; TARGET_F="$TMP_ROOT/target-f.sqlite"
    make_staged "$STAGED_F"
    printf 'old-index' > "$TARGET_F"
    ENSURE_F="$TMP_ROOT/ensure-f.ps1"
    # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
    printf 'New-Item -ItemType File -Force -Path $env:SENTINEL_PATH | Out-Null\nexit 1\n' > "$ENSURE_F"
    FAKEBIN_F="$TMP_ROOT/fakebin-f"; make_qmd_stub "$FAKEBIN_F"
    PROBE_F="$TMP_ROOT/wiring-restorefail-probe.ps1"
    cat > "$PROBE_F" <<'PROBE_F_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @([pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 8000; CommandLine = '"C:\fake\qmd.exe" mcp --keep-models' })
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = 9999 }
}
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'qmd') { return [pscustomobject]@{ Source = 'qmd' } }
    return $null
}
PROBE_F_EOF
    {
        ps_prepend_path_line "$FAKEBIN_F" "$PSSHIM_DIR"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_F")"
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s" -ExpectDocs 100 -ExpectVectors 100\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_F")" "$(winpath "$TARGET_F")" "$(winpath "$ENSURE_F")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_F"
    f_rc=0
    f_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_F" 2>&1) || f_rc=$?
    assert_rc "(f) restore failure after a full successful verify: exits 6" 6 "$f_rc"
    [ "$f_rc" -eq 6 ] || printf '    %s\n' "$f_out"
    if [ -f "$SENT_F" ]; then pass "(f) restore failure: the ensure script actually ran (and reported failure)"; else fail "(f) restore failure: ensure script never ran at all"; fi
    assert_contains "(f) restore failure: the verify stage itself still reported ok" "verified=ok" "$f_out"

    # ---- (g) self-swap validation now fails PRE-SWEEP (round 5 [codex-adv-8]) --
    # Moved before the stop sweep entirely -- a collision must exit 1 WITHOUT
    # ever touching a process. Fakes that THROW if called prove this: reaching
    # them would land in the sweep's own catch (Complete-PostSweepFailure
    # -Code 2), producing rc 2, not rc 1 -- so asserting exactly rc 1 already
    # proves the sweep was never reached, and "the restore question vanishes"
    # as the finding puts it: nothing was ever stopped, so nothing needs
    # restoring, so a plain Fail 1 is correct.
    SENT_G="$TMP_ROOT/sentinel-g.txt"; rm -f "$SENT_G"
    STAGED_G="$TMP_ROOT/staged-g.sqlite"
    make_staged "$STAGED_G"
    ENSURE_G="$TMP_ROOT/ensure-g.ps1"; make_fake_ensure "$ENSURE_G"
    PROBE_G="$TMP_ROOT/wiring-selfswap-probe.ps1"
    cat > "$PROBE_G" <<'PROBE_G_EOF'
function Get-CimInstance { throw 'the stop sweep must never run for a self-swap collision' }
function Stop-Process { throw 'the stop sweep must never run for a self-swap collision' }
function Invoke-CimMethod { throw 'Start-QmdDaemon must never run for a self-swap collision' }
function Get-Command { throw 'Start-QmdDaemon must never run for a self-swap collision' }
PROBE_G_EOF
    {
        # shellcheck disable=SC2016  # PowerShell syntax -- must stay literal until the .ps1 file is parsed, not expand as bash now
        printf '$env:SENTINEL_PATH = "%s"\n' "$(winpath "$SENT_G")"
        # -Target IS -Staged: the exact self-swap collision.
        printf '& "%s" -Staged "%s" -Target "%s" -EnsureScript "%s"\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_G")" "$(winpath "$STAGED_G")" "$(winpath "$ENSURE_G")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_G"
    g_rc=0
    g_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_G" 2>&1) || g_rc=$?
    assert_rc "(g) self-swap collision fails pre-sweep: exits 1, not 2" 1 "$g_rc"
    [ "$g_rc" -eq 1 ] || printf '    %s\n' "$g_out"
    assert_contains "(g) self-swap: names the collision" "refusing to swap a file onto itself" "$g_out"
    if [ -f "$SENT_G" ]; then fail "(g) self-swap: recovery ran even though nothing was ever stopped" "$g_out"; else pass "(g) self-swap: no restore attempted (correctly -- nothing was stopped)"; fi

    # ---- (h) stopped>0 + missing ensure script -> rc 6, not 0 (round 5 [codex-adv-9]) --
    # The full genuine-success harness (like (a)/(f)), but -EnsureScript is
    # omitted entirely -- the legitimate standalone/debug invocation the
    # receiver script's own default ('') supports. Something WAS stopped, so
    # Invoke-EnsureRestore's skipped-no-ensure-script branch must now set
    # EnsureRestoreFailed: a null-CommandLine qmd.exe cannot be classified
    # either way, so a receiver with no ensure script genuinely cannot confirm
    # the HTTP surface came back, and this must not silently read as success.
    STAGED_H="$TMP_ROOT/staged-h.sqlite"; TARGET_H="$TMP_ROOT/target-h.sqlite"
    make_staged "$STAGED_H"
    printf 'old-index' > "$TARGET_H"
    FAKEBIN_H="$TMP_ROOT/fakebin-h"; make_qmd_stub "$FAKEBIN_H"
    PROBE_H="$TMP_ROOT/wiring-noensure-probe.ps1"
    cat > "$PROBE_H" <<'PROBE_H_EOF'
function Get-CimInstance {
    param($ClassName, [string]$Filter, $ErrorAction)
    return @([pscustomobject]@{ Name = 'qmd.exe'; ProcessId = 9001; CommandLine = $null })
}
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
}
function Invoke-CimMethod {
    param($ClassName, $MethodName, $Arguments)
    return [pscustomobject]@{ ReturnValue = 0; ProcessId = 9999 }
}
function Get-Command {
    param($Name, $ErrorAction)
    if ($Name -eq 'qmd') { return [pscustomobject]@{ Source = 'qmd' } }
    return $null
}
PROBE_H_EOF
    {
        ps_prepend_path_line "$FAKEBIN_H"
        # No -EnsureScript at all -- exercises the parameter's own empty default.
        printf '& "%s" -Staged "%s" -Target "%s" -ExpectDocs 100 -ExpectVectors 100\n' \
            "$(winpath "$REAL_REMOTE_SCRIPT")" "$(winpath "$STAGED_H")" "$(winpath "$TARGET_H")"
        # shellcheck disable=SC2016  # PowerShell syntax, same reason as above
        printf 'exit $LASTEXITCODE\n'
    } >> "$PROBE_H"
    h_rc=0
    h_out=$("$PS_BIN" -NoProfile -ExecutionPolicy Bypass -File "$PROBE_H" 2>&1) || h_rc=$?
    assert_rc "(h) stopped>0 + no ensure script: exits 6, not 0" 6 "$h_rc"
    [ "$h_rc" -eq 6 ] || printf '    %s\n' "$h_out"
    assert_contains "(h) reports skipped-no-ensure-script" "http_daemon_restored=skipped-no-ensure-script" "$h_out"
    assert_contains "(h) the verify stage itself still reported ok" "verified=ok" "$h_out"
fi

summary
