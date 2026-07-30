#!/usr/bin/env bash
# scripts/lib/test-cadence-format.sh — unit tests for cadence-format.sh.
#
# Covers cadence_cmd_escape (HIMMEL-1281), the shared .bat value escaper the
# four cadence emitters (pipeline / graphmap / qmd / codex-sweep) now share.
# The per-emitter arm tests assert the escape end-to-end through a generated
# .bat; this suite pins the transform itself, including the characters it must
# deliberately LEAVE ALONE — that half is what the four deleted copies got
# wrong, and it is invisible in a test that only checks what changes.
#
# cadence_runner_stamp already has coverage in test-himmel-update-hermes.sh
# (a live-ish fixture harness); this suite stays on the pure string transform.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/cadence-format.sh
# shellcheck disable=SC1091  # sourced file not in input on test-only commits
. "$SCRIPT_DIR/cadence-format.sh"

pass=0
fail=0

# assert_esc <desc> <input> <expected>
assert_esc() {
  local desc="$1" in="$2" want="$3" got
  got="$(cadence_cmd_escape "$in")"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  ok: $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL: $desc"
    echo "        in:   [$in]"
    echo "        want: [$want]"
    echo "        got:  [$got]"
  fi
}

echo "[test-cadence-format] cadence_cmd_escape — what it MUST transform"
assert_esc "percent is doubled (batch expansion is live inside quotes)" \
  'C:\a%X%b' 'C:\a%%X%%b'
assert_esc "every percent is doubled, not just the first" \
  '%A%%B%' '%%A%%%%B%%'
assert_esc "double quote is backslash-escaped for MSVCRT argv parsing" \
  'say "hi"' 'say \"hi\"'
assert_esc "quote and percent compose" \
  '"%X%"' '\"%%X%%\"'

echo "[test-cadence-format] cadence_cmd_escape — what it MUST LEAVE ALONE"
# This is the HIMMEL-1281 defect. Inside the double quotes every emitter wraps
# these values in, cmd.exe treats & < > | as literal data and ^ as a literal
# character — it is not an escape char there. The four deleted per-emitter
# copies caret-escaped all five, which corrupted the value: a real directory
# `C:\some&dir` was emitted as `C:\some^&dir`, a path that does not exist.
assert_esc "ampersand survives verbatim" 'C:\some&dir\bash.exe' 'C:\some&dir\bash.exe'
assert_esc "caret survives verbatim (NOT doubled)" 'C:\up^dir' 'C:\up^dir'
assert_esc "angle brackets survive verbatim" 'a<b>c' 'a<b>c'
assert_esc "pipe survives verbatim" 'a|b' 'a|b'
assert_esc "the whole hostile set at once" \
  'C:\va&ult %X%^Y<z>|w' 'C:\va&ult %%X%%^Y<z>|w'

echo "[test-cadence-format] cadence_cmd_escape — edges"
assert_esc "empty string round-trips" '' ''
assert_esc "a clean path is unchanged" \
  'C:\Program Files\Git\bin\bash.exe' 'C:\Program Files\Git\bin\bash.exe'
assert_esc "backslashes are never touched (no path mangling)" \
  'C:\a\\b' 'C:\a\\b'
assert_esc "trailing percent is doubled" 'x%' 'x%%'

echo "[test-cadence-format] runner format stamp"
# Pinned to the exact current value, not merely "is an integer" — an
# any-integer assertion can never fail, so it pinned nothing. The point of a
# literal here is the tripwire: a version bump is a deliberate act (it nudges
# every armed operator to `arm --force`), so it should require touching this
# line. Bump it in the same commit that bumps cadence-format.sh.
if [ "$CADENCE_RUNNER_FORMAT_VERSION" = 7 ]; then
  pass=$((pass + 1)); echo "  ok: CADENCE_RUNNER_FORMAT_VERSION is the expected 7"
else
  fail=$((fail + 1)); echo "  FAIL: expected CADENCE_RUNNER_FORMAT_VERSION=7, got '$CADENCE_RUNNER_FORMAT_VERSION'"
fi

echo
echo "[test-cadence-format] pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
