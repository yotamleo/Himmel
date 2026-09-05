#!/usr/bin/env bash
# scripts/lib/test-git-test-env.sh -- regression test for git_test_env_repair
# and the init.templateDir hygiene fix (HIMMEL-2231).
#
# THE TICKET'S HYPOTHESIS WAS WRONG: it guessed "a racing `git -c` from a
# sibling process writes our git env". Environment variables cannot cross
# processes, so that mechanism is impossible, and six spawn paths were probed
# for an empty-value drop (bash->git, node->git, powershell->git,
# node->powershell->git, python subprocess->git, git->pre-commit-hook->git) --
# all six preserved it. The actor that corrupts the GIT_CONFIG_* block was
# NEVER IDENTIFIED. So this suite does not test a diagnosis; it tests a
# property: the block scripts/lib/git-test-env.sh hands downstream is always
# internally consistent, and contains no empty value for a drop to eat.
#
# The reported tell has exactly one producer: GIT_CONFIG_COUNT says N but some
# index < N is missing its KEY or VALUE. Reproduced exactly (case 1 below):
#   export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=init.templateDir   # VALUE_2 absent
#   git init -q r
#   error: missing config value GIT_CONFIG_VALUE_2
#   fatal: unable to parse command-line config
#
# Every case runs in its OWN subshell (`( ... )`) so its GIT_CONFIG_* exports
# cannot leak into the next case -- the single easiest way to write a
# vacuously-passing suite here is to let an earlier case's env survive into a
# later one that never actually re-derives its own state. That subshell
# isolation is also why the export-in-subshell-is-local lint (SC2030/SC2031)
# fires throughout this file -- the isolation IS the point, same convention
# as scripts/lib/test-load-dotenv.sh.
#
# rc: 0 all cases pass | 1 a case failed | 2 cannot evaluate (setup failed).
# shellcheck disable=SC2030,SC2031  # subshell-local exports are the isolation, see above
# shellcheck disable=SC1090         # `. "$LIB"` -- LIB is derived from BASH_SOURCE, not a literal
set -uo pipefail

# HIMMEL-2267: scripts/ci/run-shell-tests.sh calls git_test_env_pin_perf once in
# its OWN shell before spawning suites, exporting HIMMEL_GIT_TEST_ENV_PERF plus
# a GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n block; every suite it
# spawns -- this one included -- inherits both. git_test_env_pin_perf early-
# returns once the marker is set, so this suite's own pin_perf calls become
# no-ops under a full runner pass, and cases that assert a specific index is
# MISSING find it already populated by the runner's real pin instead. This
# suite tests git-test-env.sh's own hermetic behaviour, so it must control its
# starting environment rather than inherit the runner's -- strip the marker and
# the whole inherited GIT_CONFIG_* block before any case runs.
unset HIMMEL_GIT_TEST_ENV_PERF
_i=0
while [ "$_i" -lt 1000 ]; do
  _k="GIT_CONFIG_KEY_${_i}"; _v="GIT_CONFIG_VALUE_${_i}"
  if eval "[ \"\${${_k}+set}\" = set ]" || eval "[ \"\${${_v}+set}\" = set ]"; then
    unset "$_k" "$_v"
  else
    break
  fi
  _i=$(( _i + 1 ))
done
unset GIT_CONFIG_COUNT _i _k _v

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/git-test-env.sh"

die() { echo "-> test-git-test-env: $*" >&2; exit 2; }

[ -f "$LIB" ] || die "$LIB not found"

tmpd=$(mktemp -d -t git-test-env-XXXXXX) || die "mktemp failed"
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() { rm -rf "$tmpd" 2>/dev/null || true; }
trap cleanup EXIT

# Results are tallied through a shared file rather than a shell variable
# because each case below runs in its own subshell -- a subshell's variable
# increments never reach the parent, but its writes to a file the parent also
# holds open do.
results="$tmpd/results"
: > "$results"
ok()  { echo "  ok   -- $1";        echo ok   >> "$results"; }
bad() { echo "  FAIL -- $1";        echo fail >> "$results"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi; }

# find_value_for_key <key> -- echoes the VALUE for the first GIT_CONFIG_KEY_n
# equal to <key> (searching the currently exported GIT_CONFIG_* block) and
# returns 0; returns 1 if no such key is present. Same base-10 idiom as
# git_test_env_append/git_test_env_repair for a malformed COUNT.
find_value_for_key() {
  local want="$1" i=0 n k
  case "${GIT_CONFIG_COUNT:-}" in
    ''|*[!0-9]*) n=0 ;;
    *) n=$(( 10#${GIT_CONFIG_COUNT} )) ;;
  esac
  while [ "$i" -lt "$n" ]; do
    eval "k=\${GIT_CONFIG_KEY_${i}:-}"
    if [ "$k" = "$want" ]; then
      eval "printf '%s' \"\${GIT_CONFIG_VALUE_${i}}\""
      return 0
    fi
    i=$(( i + 1 ))
  done
  return 1
}

echo "test-git-test-env (HIMMEL-2231)"

# --- case 1: negative control -- the exact reproduction ---------------------
echo
echo "negative control -- corrupt block reproduces the reported git failure:"
(
  d="$tmpd/case1"; mkdir -p "$d" || exit 2
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
         GIT_CONFIG_KEY_1=core.fsyncMethod GIT_CONFIG_VALUE_1=batch \
         GIT_CONFIG_KEY_2=init.templateDir
  out=$(git init -q "$d/r" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then ok "corrupt block: git init fails (rc=$rc)"; else bad "corrupt block: git init fails (rc=$rc)"; fi
  case "$out" in
    *"missing config value GIT_CONFIG_VALUE_2"*)
      ok "corrupt block: failure names the missing value" ;;
    *)
      bad "corrupt block: failure names the missing value (got: $out)" ;;
  esac
) || bad "case 1: aborted before completing (rc=$?)"

# --- case 2: positive -- repair makes the next git init succeed, loudly -----
echo
echo "repair fixes the exact corrupt state from case 1:"
(
  d="$tmpd/case2"; mkdir -p "$d" || exit 2
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
         GIT_CONFIG_KEY_1=core.fsyncMethod GIT_CONFIG_VALUE_1=batch \
         GIT_CONFIG_KEY_2=init.templateDir
  . "$LIB"
  # NOT `warn=$(git_test_env_repair ...)` -- that command substitution is
  # itself a subshell, so the exports git_test_env_repair makes (the whole
  # point of this case) would never reach the `git init` below. Route stderr
  # through a file instead so the repair runs in THIS shell.
  warnfile="$tmpd/case2.warn"
  git_test_env_repair 2>"$warnfile" >/dev/null
  warn=$(cat "$warnfile")
  if [ -n "$warn" ]; then ok "repair prints to stderr when it truncates"; else bad "repair prints to stderr when it truncates"; fi
  case "$warn" in
    *HIMMEL-2231*) ok "repair's stderr line cites HIMMEL-2231" ;;
    *) bad "repair's stderr line cites HIMMEL-2231 (got: $warn)" ;;
  esac
  if git init -q "$d/r" >/dev/null 2>&1; then
    ok "git init succeeds after repair"
  else
    bad "git init succeeds after repair"
  fi
) || bad "case 2: aborted before completing (rc=$?)"

# --- case 3: repair truncates correctly, preserving the surviving entries ---
echo
echo "repair truncates a COUNT=3 block missing index 2:"
(
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
         GIT_CONFIG_KEY_1=core.fsyncMethod GIT_CONFIG_VALUE_1=batch \
         GIT_CONFIG_KEY_2=init.templateDir
  . "$LIB"
  git_test_env_repair >/dev/null 2>&1
  check "GIT_CONFIG_COUNT truncated to 2" "2" "$GIT_CONFIG_COUNT"
  check "index 0 key preserved"   "core.fsync"       "${GIT_CONFIG_KEY_0:-}"
  check "index 0 value preserved" "none"              "${GIT_CONFIG_VALUE_0:-}"
  check "index 1 key preserved"   "core.fsyncMethod"  "${GIT_CONFIG_KEY_1:-}"
  check "index 1 value preserved" "batch"              "${GIT_CONFIG_VALUE_1:-}"
  if [ -n "${GIT_CONFIG_KEY_2+x}" ]; then bad "index 2 key unset after truncation"; else ok "index 2 key unset after truncation"; fi
) || bad "case 3: aborted before completing (rc=$?)"

# --- case 4: a missing KEY_n (not VALUE_n) is repaired the same way ---------
echo
echo "repair truncates a block missing a KEY (not a VALUE):"
(
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
         GIT_CONFIG_VALUE_1=batch
  # GIT_CONFIG_KEY_1 intentionally left unset.
  . "$LIB"
  git_test_env_repair >/dev/null 2>&1
  check "GIT_CONFIG_COUNT truncated to 1" "1" "$GIT_CONFIG_COUNT"
  check "index 0 key preserved"   "core.fsync" "${GIT_CONFIG_KEY_0:-}"
  check "index 0 value preserved" "none"        "${GIT_CONFIG_VALUE_0:-}"
  if [ -n "${GIT_CONFIG_VALUE_1+x}" ]; then bad "index 1 value unset after truncation"; else ok "index 1 value unset after truncation"; fi
) || bad "case 4: aborted before completing (rc=$?)"

# --- case 5: a consistent block is left completely untouched ----------------
echo
echo "a consistent block is not trigger-happy repaired:"
(
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
         GIT_CONFIG_KEY_1=core.fsyncMethod GIT_CONFIG_VALUE_1=batch
  . "$LIB"
  warn=$(git_test_env_repair 2>&1 1>/dev/null)
  if [ -z "$warn" ]; then ok "consistent block: nothing printed to stderr"; else bad "consistent block: nothing printed to stderr (got: $warn)"; fi
  check "COUNT unchanged" "2" "$GIT_CONFIG_COUNT"
  check "index 0 key unchanged"   "core.fsync"       "$GIT_CONFIG_KEY_0"
  check "index 0 value unchanged" "none"              "$GIT_CONFIG_VALUE_0"
  check "index 1 key unchanged"   "core.fsyncMethod"  "$GIT_CONFIG_KEY_1"
  check "index 1 value unchanged" "batch"              "$GIT_CONFIG_VALUE_1"
) || bad "case 5: aborted before completing (rc=$?)"

# --- case 6: a legitimately empty value is NOT treated as missing -----------
echo
echo "presence, not non-emptiness -- an empty value is not corruption:"
(
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.templateDir GIT_CONFIG_VALUE_0=''
  . "$LIB"
  warn=$(git_test_env_repair 2>&1 1>/dev/null)
  if [ -z "$warn" ]; then ok "empty value: nothing printed to stderr"; else bad "empty value: nothing printed to stderr (got: $warn)"; fi
  check "empty-value entry's COUNT is untouched" "1" "$GIT_CONFIG_COUNT"
  if [ -n "${GIT_CONFIG_VALUE_0+x}" ]; then ok "empty-value entry is still present"; else bad "empty-value entry is still present"; fi
) || bad "case 6: aborted before completing (rc=$?)"

# --- case 7: pin_perf's init.templateDir is a real, empty directory ---------
echo
echo "git_test_env_pin_perf pins init.templateDir to an existing empty dir:"
(
  d="$tmpd/case7"; mkdir -p "$d" || exit 2
  . "$LIB"
  git_test_env_pin_perf
  if tmpl=$(find_value_for_key init.templateDir); then
    if [ -d "$tmpl" ]; then ok "templateDir exists and is a directory"; else bad "templateDir exists and is a directory (got [$tmpl])"; fi
    if [ -z "$(ls -A "$tmpl" 2>/dev/null)" ]; then ok "templateDir is empty"; else bad "templateDir is empty (got: $(ls -A "$tmpl" 2>/dev/null))"; fi
  else
    bad "templateDir exists and is a directory (init.templateDir not in the pinned block)"
    bad "templateDir is empty (init.templateDir not in the pinned block)"
  fi
  git init -q "$d/r" >/dev/null 2>&1
  samples=0
  if [ -d "$d/r/.git/hooks" ]; then
    for f in "$d/r/.git/hooks"/*.sample; do
      [ -e "$f" ] && samples=$(( samples + 1 ))
    done
  fi
  if [ "$samples" -eq 0 ]; then
    ok "git init under the pin produces no *.sample hooks"
  else
    bad "git init under the pin produces no *.sample hooks (found $samples)"
  fi
) || bad "case 7: aborted before completing (rc=$?)"

# --- case 8: pin_perf is idempotent ------------------------------------------
echo
echo "git_test_env_pin_perf is idempotent:"
(
  . "$LIB"
  git_test_env_pin_perf
  first="$GIT_CONFIG_COUNT"
  git_test_env_pin_perf
  second="$GIT_CONFIG_COUNT"
  check "second call does not grow GIT_CONFIG_COUNT" "$first" "$second"
) || bad "case 8: aborted before completing (rc=$?)"

# --- case 9: templateDir closes the fixed-shared-path review finding --------
# codex critic (this branch): a fixed, predictable, never-cleaned templateDir
# path in a shared temp dir is pre-populatable by any other process, and
# `git init` COPIES templateDir's contents -- including executable hooks --
# into every fixture repo's .git/. Proves the property, not the
# implementation string: (1) the pin is a real, empty directory; (2) it is
# NOT a fixed name -- two independently-pinning shells get different
# directories; (3) the copy mechanism is real (a negative control that git
# DOES copy a planted file) and the lib's own pin does not exhibit it.
echo
echo "git_test_env_pin_perf's templateDir closes the fixed-shared-path finding:"
(
  d="$tmpd/case9"; mkdir -p "$d" || exit 2

  # --- (1) the pinned templateDir is a real, empty directory ----------------
  . "$LIB"
  git_test_env_pin_perf
  if tmpl=$(find_value_for_key init.templateDir); then
    if [ -d "$tmpl" ]; then ok "pinned templateDir exists and is a directory"; else bad "pinned templateDir exists and is a directory (got [$tmpl])"; fi
    if [ -z "$(ls -A "$tmpl" 2>/dev/null)" ]; then ok "pinned templateDir is empty"; else bad "pinned templateDir is empty (got: $(ls -A "$tmpl" 2>/dev/null))"; fi
  else
    bad "pinned templateDir exists and is a directory (init.templateDir not in the pinned block)"
    bad "pinned templateDir is empty (init.templateDir not in the pinned block)"
  fi

  # --- (2) not a fixed name -- two clean-env pins differ ---------------------
  # Each pin runs in its own bash -c, with the marker and GIT_CONFIG_* block
  # explicitly unset so neither inherits the other's (or this case's) pin.
  # A return to a hardcoded path makes tmpl1 == tmpl2 and fails this check --
  # this is the assertion that actually pins the fix.
  export -f find_value_for_key
  # shellcheck disable=SC2016  # single-quoted deliberately -- expands in the CHILD bash -c, not here
  tmpl1=$(env -u HIMMEL_GIT_TEST_ENV_PERF -u GIT_CONFIG_COUNT \
              -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
              -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 \
              -u GIT_CONFIG_KEY_2 -u GIT_CONFIG_VALUE_2 \
              bash -c '. "$1"; git_test_env_pin_perf; find_value_for_key init.templateDir' _ "$LIB")
  # shellcheck disable=SC2016  # single-quoted deliberately -- expands in the CHILD bash -c, not here
  tmpl2=$(env -u HIMMEL_GIT_TEST_ENV_PERF -u GIT_CONFIG_COUNT \
              -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
              -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 \
              -u GIT_CONFIG_KEY_2 -u GIT_CONFIG_VALUE_2 \
              bash -c '. "$1"; git_test_env_pin_perf; find_value_for_key init.templateDir' _ "$LIB")
  if [ -n "$tmpl1" ] && [ -n "$tmpl2" ] && [ "$tmpl1" != "$tmpl2" ]; then
    ok "two independent pins produce different templateDir paths"
  else
    bad "two independent pins produce different templateDir paths (got [$tmpl1] and [$tmpl2])"
  fi

  # --- (3a) negative control: git DOES copy a planted templateDir file ------
  # Independent of the lib -- this is git's own documented behaviour, and the
  # mechanism the review finding relies on. Runs in a NESTED subshell so its
  # one-off GIT_CONFIG_* override cannot clobber the pin from step (1), which
  # step (3b) below still needs.
  planted="$d/planted-template"; mkdir -p "$planted" || exit 2
  printf '#!/bin/sh\necho PWNED\n' > "$planted/hooks-probe-marker"
  (
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.templateDir GIT_CONFIG_VALUE_0="$planted"
    git init -q "$d/planted-repo" >/dev/null 2>&1
  )
  if [ -e "$d/planted-repo/.git/hooks-probe-marker" ]; then
    ok "negative control: git init copies a planted templateDir file into .git/"
  else
    bad "negative control: git init copies a planted templateDir file into .git/"
  fi

  # --- (3b) dependent on the lib: its own pin shows no such contamination ---
  # Uses the GIT_CONFIG_* block git_test_env_pin_perf produced in step (1),
  # untouched by the nested subshell above -- a fresh mktemp dir is empty by
  # construction, so nothing lands in the new repo's .git/.
  git init -q "$d/pinned-repo" >/dev/null 2>&1
  if [ -e "$d/pinned-repo/.git/hooks-probe-marker" ]; then
    bad "pinned templateDir: no planted-style file leaks into .git/"
  else
    ok "pinned templateDir: no planted-style file leaks into .git/"
  fi
  samples=0
  if [ -d "$d/pinned-repo/.git/hooks" ]; then
    for f in "$d/pinned-repo/.git/hooks"/*.sample; do
      [ -e "$f" ] && samples=$(( samples + 1 ))
    done
  fi
  if [ "$samples" -eq 0 ]; then
    ok "pinned templateDir: git init produces no *.sample hooks"
  else
    bad "pinned templateDir: git init produces no *.sample hooks (found $samples)"
  fi
) || bad "case 9: aborted before completing (rc=$?)"

# --- case 10: a malformed GIT_CONFIG_COUNT is repaired, loudly (HIMMEL-2231) -
# codex-2 review, this ticket: a SET-but-non-numeric COUNT (e.g. `abc`) used
# to be treated as count=0 by the truncation walk, which made the walk a
# no-op and left the malformed value exported -- every later `git` call then
# fatals with "bogus count in GIT_CONFIG_COUNT". Reproduced directly:
#   export GIT_CONFIG_COUNT=abc; git init -q r
#   error: bogus count in GIT_CONFIG_COUNT
#   fatal: unable to parse command-line config
echo
echo "repair unsets a malformed (non-numeric) GIT_CONFIG_COUNT:"
(
  d="$tmpd/case10"; mkdir -p "$d" || exit 2
  export GIT_CONFIG_COUNT=abc GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none
  . "$LIB"
  warnfile="$tmpd/case10.warn"
  git_test_env_repair 2>"$warnfile" >/dev/null
  warn=$(cat "$warnfile")
  if [ -n "$warn" ]; then ok "malformed COUNT: repair prints to stderr"; else bad "malformed COUNT: repair prints to stderr"; fi
  case "$warn" in
    *HIMMEL-2231*) ok "malformed COUNT: repair's stderr line cites HIMMEL-2231" ;;
    *) bad "malformed COUNT: repair's stderr line cites HIMMEL-2231 (got: $warn)" ;;
  esac
  if [ -z "${GIT_CONFIG_COUNT+set}" ]; then
    ok "malformed COUNT: GIT_CONFIG_COUNT is unset after repair"
  else
    bad "malformed COUNT: GIT_CONFIG_COUNT is unset after repair (got: $GIT_CONFIG_COUNT)"
  fi
  if [ -n "${GIT_CONFIG_KEY_0+x}" ]; then
    bad "malformed COUNT: stray GIT_CONFIG_KEY_0 unset after repair"
  else
    ok "malformed COUNT: stray GIT_CONFIG_KEY_0 unset after repair"
  fi
  if git init -q "$d/r" >/dev/null 2>&1; then
    ok "git init succeeds after malformed-COUNT repair"
  else
    bad "git init succeeds after malformed-COUNT repair"
  fi
) || bad "case 10: aborted before completing (rc=$?)"

# --- case 11: pin_perf re-pins after repair clears a stale marker -----------
# The finding's ordering concern: git_test_env_pin_perf calls
# git_test_env_repair BEFORE checking HIMMEL_GIT_TEST_ENV_PERF, so a repair
# that clears the marker on a malformed COUNT must result in a re-pin on that
# SAME call, not a return-early on a marker whose pins no longer exist. This
# is the exact reproduction from the ticket: marker pre-set + malformed COUNT.
echo
echo "pin_perf re-pins when repair clears the marker on a malformed COUNT:"
(
  d="$tmpd/case11"; mkdir -p "$d" || exit 2
  export GIT_CONFIG_COUNT=abc HIMMEL_GIT_TEST_ENV_PERF=1
  . "$LIB"
  git_test_env_pin_perf
  case "${GIT_CONFIG_COUNT:-}" in
    ''|*[!0-9]*) bad "pin_perf: GIT_CONFIG_COUNT is a valid integer after re-pin (got: ${GIT_CONFIG_COUNT:-<unset>})" ;;
    *) ok "pin_perf: GIT_CONFIG_COUNT is a valid integer after re-pin" ;;
  esac
  if [ "${HIMMEL_GIT_TEST_ENV_PERF:-0}" = "1" ]; then
    ok "pin_perf: marker is set again after re-pin"
  else
    bad "pin_perf: marker is set again after re-pin"
  fi
  if git init -q "$d/r" >/dev/null 2>&1; then
    ok "git init succeeds after pin_perf re-pins over a malformed COUNT"
  else
    bad "git init succeeds after pin_perf re-pins over a malformed COUNT"
  fi
) || bad "case 11: aborted before completing (rc=$?)"

echo
pass=$(grep -c '^ok$'   "$results" || true)
fail=$(grep -c '^fail$' "$results" || true)
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
