#!/usr/bin/env bash
# scripts/lib/test-hermetic-path.sh — unit tests for the shared hermetic-PATH
# helpers (HIMMEL-2535).
#
# The library had NO direct test: every assertion about it was indirect, through
# whichever suite happened to source it. That is how the same defect class shipped
# three times in one week (HIMMEL-2470 node, HIMMEL-2520 bun, HIMMEL-2530
# uv/graphify) plus its inverse (HIMMEL-2524, an allowlist built from a
# directory). These cases pin the CONTRACT itself, so the next regression is
# caught here rather than in a downstream fixture's confusing red.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+. Pure
# shell over a scratch dir; NOT ported to native PowerShell. A test harness needs
# no .ps1 twin (project convention: a documented platform guard suffices for a
# test fixture) -- this is the T15 marker scripts/parity/test-ws5-invariants.sh
# looks for. The library under test is itself sourced only by shell suites, and
# HERMETIC_EXE_SUFFIX carries the Windows half of its behaviour, which these
# cases exercise through that variable rather than through a second twin.
#
# Usage: bash scripts/lib/test-hermetic-path.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pass=0
fails=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fails=$((fails+1)); echo "  FAIL: $1"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# check_not — the command must FAIL. It runs in THIS shell on purpose: the
# obvious spelling, `bash -c '! some_helper ...'`, starts a subshell that has
# NOT sourced the library, so the helper is not defined, `!` inverts rc 127
# "command not found", and the assertion passes without ever calling it. Five
# assertions in the first draft of this file were vacuous exactly that way —
# in the suite whose whole job is to pin this library's contract.
check_not() { local d="$1"; shift; if "$@"; then bad "$d"; else ok "$d"; fi; }

# Define fail() BEFORE sourcing so the library's fallback does not take over:
# these tests must never exit the suite on a helper's error path.
# shellcheck disable=SC2317,SC2329
# Invoked INDIRECTLY: link_hermetic_tool/build_hermetic_bin in the sourced
# library call `fail`, and nothing in this file calls it directly. Shellcheck
# cannot see that when it is run over this file alone -- which is how the
# pre-commit hook runs it, without -x and without the library in the same
# changeset -- so it reports the function as never invoked (SC2329) and its body
# as unreachable (SC2317). Both are the "or ignore if invoked indirectly" case
# those checks name. Kept as a pair deliberately: `shellcheck -x` follows the
# source and emits SC2317, the hook's bare run emits SC2329, and only silencing
# both keeps the file clean under either invocation.
fail() { printf 'test-hermetic-path: %s\n' "$*" >&2; return 1; }

# shellcheck source=scripts/lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hermetic-path.sh"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hermetic-path-test.XXXXXX")" || {
    echo "FATAL: could not create scratch dir" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

echo "[test-hermetic-path] build_hermetic_bin links bash even when unnamed"
d1="$tmpdir/d1"
build_hermetic_bin "$d1" sed
check "bash is linked without being asked for" test -e "$d1/bash$HERMETIC_EXE_SUFFIX"
check "the named tool is linked" test -e "$d1/sed$HERMETIC_EXE_SUFFIX"
check "an unnamed tool is NOT linked" test ! -e "$d1/awk$HERMETIC_EXE_SUFFIX"

echo "[test-hermetic-path] the built dir actually RESOLVES its tools"
# The regression that matters: a dir full of dangling links resolves nothing.
# Resolution is checked from INSIDE a shell started under that PATH -- `command`
# is a shell builtin, so `env PATH=... command -v x` would try to exec a binary
# named `command` and fail for a reason that has nothing to do with the library.
# Starting the shell as `bash` also proves the dir can bootstrap an interpreter,
# which is the property the whole floor exists for.
check "bash resolves under the built dir alone" \
  env PATH="$d1" bash -c 'command -v bash >/dev/null'
check "sed resolves under the built dir alone" \
  env PATH="$d1" bash -c 'command -v sed >/dev/null'
check "an unlinked tool does NOT resolve there" \
  env PATH="$d1" bash -c '! command -v awk >/dev/null'

echo "[test-hermetic-path] build_hermetic_bin creates a dir that does not exist yet"
d2="$tmpdir/nested/deeper"
build_hermetic_bin "$d2" cat
check "nested destination created" test -d "$d2"
check "tool present in nested destination" test -e "$d2/cat$HERMETIC_EXE_SUFFIX"

echo "[test-hermetic-path] a missing tool is REPORTED, not masked (fail-open guard)"
# This suite's fail() returns rather than exits, which is exactly the caller
# shape that made the bug reachable: link_hermetic_tool returned non-zero, the
# loop carried on, and the LAST iteration's success became the helper's rc — so
# an incomplete floor reported success. Panel round 2 [codex-1].
d4="$tmpdir/d4"
check_not "a missing NON-FINAL tool makes build_hermetic_bin fail" \
  build_hermetic_bin "$d4" definitely-not-a-real-tool-2535 sed
check "the tools that DID resolve are still linked (every tool is attempted)" \
  test -e "$d4/sed$HERMETIC_EXE_SUFFIX"
# And the missing one must leave NO entry behind: falling through with an empty
# source wrote a wrapper containing `exec "" "$@"`, and the idempotency guard
# would then skip re-linking that poisoned path forever.
check "the missing tool leaves no poisoned stub behind" \
  test ! -e "$d4/definitely-not-a-real-tool-2535$HERMETIC_EXE_SUFFIX"

echo "[test-hermetic-path] hermetic_path_excludes"
# A dir carrying a fake 'bun' stands in for the distro that co-locates it.
withbun="$tmpdir/withbun"; mkdir -p "$withbun"
# Name the fixture through HERMETIC_EXE_SUFFIX, the same variable the READER
# (path_dir_has_scrubbed_tool) consults. The library header requires exactly
# this so the writer side cannot drift from the reader side; a hard-coded bare
# name would still be found today (the reader checks bare BEFORE .exe/.cmd) but
# would stop resembling a real scrubbed tool on Windows. No-op on POSIX, where
# the suffix is empty.
printf '#!/bin/sh\nexit 0\n' > "$withbun/bun$HERMETIC_EXE_SUFFIX"
chmod +x "$withbun/bun$HERMETIC_EXE_SUFFIX"
# Meta-control: the negative cases below are only meaningful if the function is
# actually in scope. Assert that first, so a rename or a failed source can never
# turn the whole block into a row of vacuous passes.
check "hermetic_path_excludes is in scope for the negative cases below" \
  test "$(type -t hermetic_path_excludes 2>/dev/null)" = function
check "reports EXCLUDED when the tool is absent" \
  hermetic_path_excludes "$d1" bun
check_not "reports NOT-excluded when the tool is present" \
  hermetic_path_excludes "$withbun" bun
check_not "a later dir carrying the tool is still caught" \
  hermetic_path_excludes "$d1:$withbun" bun
check_not "checks every named tool, not just the first" \
  hermetic_path_excludes "$withbun" node bun
check "empty PATH segments do not crash it" \
  hermetic_path_excludes ":$d1:" bun
# An empty segment IS the cwd to a shell. Skipping it made this function answer
# "excluded" about a PATH the shell resolves the tool on — a false negative in
# the one direction that matters, since callers use it to PROVE unreachability.
# Panel round 1 [codex-1]; reproduced before fixing, and this case is what pins it.
# cd rather than a subshell: check_not must run in THIS shell to see the function.
_prev_cwd="$PWD"
cd "$withbun" || bad "could not cd into the fixture dir"
check_not "an empty segment is read as the cwd, not skipped" \
  hermetic_path_excludes ":/nonexistent:" bun
# Word splitting cannot see every empty segment, and each one missed is a false
# "excluded" about a PATH the shell WOULD resolve on. Panel round 3 [codex-1]
# named the wholly-empty case; measuring it showed a TRAILING empty segment is
# silently dropped too. All four degenerate shapes are pinned here.
check_not "an entirely empty PATH is the cwd (0 fields, not 'nothing')" \
  hermetic_path_excludes "" bun
check_not "a lone ':' is the cwd" \
  hermetic_path_excludes ":" bun
check_not "a TRAILING empty segment is not dropped" \
  hermetic_path_excludes "/nonexistent:" bun
check_not "a LEADING empty segment is not dropped" \
  hermetic_path_excludes ":/nonexistent" bun
# Control: without any empty segment the answer must still be "excluded", so the
# four cases above are not passing merely because the function turned pessimistic.
check "a path with no empty segment still reports EXCLUDED" \
  hermetic_path_excludes "/nonexistent" bun
cd "$_prev_cwd" || bad "could not restore cwd"

echo "[test-hermetic-path] scrub_path still drops a dir WHOLESALE (the hazard the helpers exist for)"
# Not a wish, a pin: this is why a floor must be prepended. If scrub_path ever
# became surgical, the floor advice would need revisiting -- so pin the behaviour.
check "a dir carrying the scrubbed tool is dropped entirely" \
  test -z "$(scrub_path "$withbun" bun)"
printf "x" > "$withbun/sed$HERMETIC_EXE_SUFFIX"; chmod +x "$withbun/sed$HERMETIC_EXE_SUFFIX"
check "sibling tools in that dir go with it" \
  test -z "$(scrub_path "$withbun" bun)"

echo "[test-hermetic-path] the documented composition is safe end to end"
d3="$tmpdir/d3"
build_hermetic_bin "$d3" sed
composed="$d3:$(scrub_path "$withbun" bun)"
check "composed PATH resolves the interpreter" \
  env PATH="$composed" bash -c 'command -v bash >/dev/null'
check "composed PATH excludes the scrubbed tool" hermetic_path_excludes "$composed" bun

echo
if [ "$fails" -eq 0 ]; then echo "[test-hermetic-path] pass=$pass fail=0"; exit 0; fi
echo "[test-hermetic-path] pass=$pass fail=$fails"; exit 1
