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

# assert_eq <desc> <got> <expected>
assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    echo "  ok: $desc"
  else
    fail=$((fail + 1))
    echo "  FAIL: $desc"
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

# printf, not echo: these lines carry a literal `\b` (usr\bin), which echo is
# allowed to eat as a backspace escape (SC2028).
printf '%s\n' "[test-cadence-format] cadence_git_bin_path_win — Git usr\\bin ahead of bin, derived (HIMMEL-1672)"
# A non-login bash.exe inherits the bare Windows PATH, so the emitted .bat must
# prepend Git's usr\bin + bin (GNU coreutils) ahead of System32. The fragment is
# DERIVED from the baked-in bash.exe path — never hardcoded — so these pin both
# the ordering (usr\bin FIRST) and the derivation (a non-default install root
# comes through verbatim, a non-Git bash yields nothing).
assert_eq "usr\\bin layout yields <root>\\usr\\bin;<root>\\bin (usr\\bin FIRST)" \
  "$(cadence_git_bin_path_win 'C:\Program Files\Git\usr\bin\bash.exe')" \
  'C:\Program Files\Git\usr\bin;C:\Program Files\Git\bin'
assert_eq "non-default Git install root is derived, not hardcoded" \
  "$(cadence_git_bin_path_win 'D:\dev tools\Git\usr\bin\bash.exe')" \
  'D:\dev tools\Git\usr\bin;D:\dev tools\Git\bin'
assert_eq "bin\\bash.exe wrapper form resolves the SAME root (usr\\bin still first)" \
  "$(cadence_git_bin_path_win 'C:\Program Files\Git\bin\bash.exe')" \
  'C:\Program Files\Git\usr\bin;C:\Program Files\Git\bin'
assert_eq "a non-Git bash (WSL System32 stub) yields nothing, not a wrong path" \
  "$(cadence_git_bin_path_win 'C:\Windows\System32\bash.exe')" ''

# Tie the derivation to the line an emitted runner actually carries: escape the
# fragment (cadence_cmd_escape, as every bash-emitter's emit_bat does) and wrap
# it as the `set "PATH=...;%PATH%"` line a generated .bat stamps. Git's usr\bin
# must land AHEAD of %PATH% — i.e. ahead of the inherited Windows PATH where
# System32's find.exe/timeout.exe live — so a non-login bash.exe resolves GNU
# coreutils first. (The consumer suites can't assert this directly: their fake
# bash stub is deliberately non-Git-shaped for hermeticity, so the derivation
# returns empty there. This is the deterministic home for that contract.)
_emitted="set \"PATH=$(cadence_cmd_escape "$(cadence_git_bin_path_win 'C:\Program Files\Git\usr\bin\bash.exe')");%PATH%\""
case "$_emitted" in
  *\\usr\\bin*%PATH%*) pass=$((pass + 1)); printf '%s\n' "  ok: emitted PATH line puts Git usr\\bin ahead of %PATH%" ;;
  *) fail=$((fail + 1)); printf '%s\n' "  FAIL: emitted PATH line does NOT put Git usr\\bin ahead of %PATH%: [$_emitted]" ;;
esac

echo "[test-cadence-format] cadence_vbs_wrapper — execution preserves rc=42 (HIMMEL-1753)"
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*)
    cscript_bin=""
    if command -v cscript.exe >/dev/null 2>&1; then
      cscript_bin="$(command -v cscript.exe)"
    elif command -v cscript >/dev/null 2>&1; then
      cscript_bin="$(command -v cscript)"
    fi
    if [ -z "$cscript_bin" ] || ! command -v cygpath >/dev/null 2>&1; then
      fail=$((fail + 1))
      echo "  FAIL: Windows rc=42 execution test needs cscript and cygpath"
    else
      shim_tmp="$(mktemp -d -t cadence-format.XXXXXX)"
      shim_dir="$shim_tmp/rc 42 fixture"
      mkdir -p "$shim_dir"
      shim_bat="$shim_dir/exit-42.bat"
      shim_vbs="$shim_dir/exit-42.vbs"
      printf '@echo off\r\necho ran> "%%~dp0ran.txt"\r\nexit /b 42\r\n' > "$shim_bat"
      cadence_vbs_wrapper "$(cygpath -w "$shim_bat")" > "$shim_vbs"
      shim_rc=0
      MSYS_NO_PATHCONV=1 "$cscript_bin" //B //NoLogo "$(cygpath -w "$shim_vbs")" >/dev/null 2>&1 || shim_rc=$?
      if [ -f "$shim_dir/ran.txt" ]; then
        pass=$((pass + 1)); echo "  ok: generated shim executes the fixture runner"
      else
        fail=$((fail + 1)); echo "  FAIL: generated shim did not execute the fixture runner"
      fi
      assert_eq "generated shim forwards the fixture runner's literal rc=42" "$shim_rc" "42"
      rm -rf "$shim_tmp"
    fi
    ;;
  *) echo "  SKIP: execution check is Windows-only (cscript + .bat)" ;;
esac

echo "[test-cadence-format] runner format stamp"
# Pinned to the exact current value, not merely "is an integer" — an
# any-integer assertion can never fail, so it pinned nothing. The point of a
# literal here is the tripwire: a version bump is a deliberate act (it nudges
# every armed operator to `arm --force`), so it should require touching this
# line. Bump it in the same commit that bumps cadence-format.sh.
if [ "$CADENCE_RUNNER_FORMAT_VERSION" = 16 ]; then
  pass=$((pass + 1)); echo "  ok: CADENCE_RUNNER_FORMAT_VERSION is the expected 16"
else
  fail=$((fail + 1)); echo "  FAIL: expected CADENCE_RUNNER_FORMAT_VERSION=16, got '$CADENCE_RUNNER_FORMAT_VERSION'"
fi

echo "[test-cadence-format] CADENCE_RUNNER_BASENAMES includes upstream-watch (HIMMEL-2367)"
case " $CADENCE_RUNNER_BASENAMES " in
  *" upstream-watch "*)
    pass=$((pass + 1)); echo "  ok: upstream-watch is a stamped runner basename" ;;
  *)
    fail=$((fail + 1)); echo "  FAIL: upstream-watch missing from CADENCE_RUNNER_BASENAMES: '$CADENCE_RUNNER_BASENAMES'" ;;
esac

echo "[test-cadence-format] cadence_wsh_probe — prefers pwsh over powershell.exe (HIMMEL-2126)"
# shellcheck source=scripts/lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/hermetic-path.sh"
_wsh_tmp="$(mktemp -d -t cadence-wsh.XXXXXX)"
_fake_wscript="$_wsh_tmp/wscript-fake"
printf '#!/bin/sh\nexit 0\n' > "$_fake_wscript"; chmod +x "$_fake_wscript"
_fake_ps_absent() { printf '#!/bin/sh\necho ABSENT\n' > "$1"; chmod +x "$1"; }

# Case 1: both pwsh and powershell.exe on PATH -> pwsh wins, no warning.
_bin1="$_wsh_tmp/bin1"; mkdir -p "$_bin1"
_fake_ps_absent "$_bin1/pwsh"
_fake_ps_absent "$_bin1/powershell.exe"
CADENCE_WSH_CHECKED=0; CADENCE_WSH_AVAILABLE=0; CADENCE_WSH_DETAIL=""
unset CADENCE_WSH_POWERSHELL
_stderr1="$_wsh_tmp/stderr1.log"
if PATH="$_bin1:$PATH" CADENCE_WSCRIPT_BIN="$_fake_wscript" cadence_wsh_probe 2>"$_stderr1"; then
  pass=$((pass + 1)); echo "  ok: cadence_wsh_probe available when pwsh is present"
else
  fail=$((fail + 1)); echo "  FAIL: cadence_wsh_probe should be available (detail: $CADENCE_WSH_DETAIL)"
fi
if [ -s "$_stderr1" ]; then
  fail=$((fail + 1)); echo "  FAIL: cadence_wsh_probe warned even though pwsh was found: $(cat "$_stderr1")"
else
  pass=$((pass + 1)); echo "  ok: cadence_wsh_probe stays silent when pwsh is found"
fi

# Case 2: no pwsh anywhere on PATH, only powershell.exe -> loud named fallback.
# scrub_path drops the real pwsh install dir so this box's own pwsh cannot leak in.
# HIMMEL-2535: prepend a tool floor. scrub_path drops a PATH dir WHOLESALE, so
# on any box where pwsh ships alongside the coreutils (the /usr/bin case that
# made HIMMEL-2470/2520/2524/2530 red) this scrub would take bash and the
# probe's own utilities with it. It is green here only because this station has
# no pwsh at all, so the scrub currently drops nothing -- latent, not correct.
# Tool set measured, not guessed: the case reaches for mktemp, rm and tr.
_wsh_floor="$_wsh_tmp/floor"
build_hermetic_bin "$_wsh_floor" mktemp rm tr
_path_no_pwsh="$_wsh_floor:$(scrub_path "$PATH" pwsh)"
hermetic_path_excludes "$_path_no_pwsh" pwsh || {
  fail=$((fail + 1)); echo "  FAIL: the no-pwsh PATH still resolves a pwsh"; }
_bin2="$_wsh_tmp/bin2"; mkdir -p "$_bin2"
_fake_ps_absent "$_bin2/powershell.exe"
# shellcheck disable=SC2034  # CADENCE_WSH_CHECKED/AVAILABLE consumed by cadence_wsh_probe (sourced, SC1091-disabled)
CADENCE_WSH_CHECKED=0
# shellcheck disable=SC2034
CADENCE_WSH_AVAILABLE=0
CADENCE_WSH_DETAIL=""
_stderr2="$_wsh_tmp/stderr2.log"
if PATH="$_bin2:$_path_no_pwsh" CADENCE_WSCRIPT_BIN="$_fake_wscript" cadence_wsh_probe 2>"$_stderr2"; then
  pass=$((pass + 1)); echo "  ok: cadence_wsh_probe falls back to powershell.exe when pwsh is absent"
else
  fail=$((fail + 1)); echo "  FAIL: cadence_wsh_probe should still be available via the powershell.exe fallback (detail: $CADENCE_WSH_DETAIL)"
fi
if grep -q 'HIMMEL-2126' "$_stderr2" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok: cadence_wsh_probe names the trap class + HIMMEL-2126 on fallback"
else
  fail=$((fail + 1)); echo "  FAIL: cadence_wsh_probe fallback did not warn: $(cat "$_stderr2" 2>/dev/null)"
fi
rm -rf "$_wsh_tmp"

echo
echo "[test-cadence-format] pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
