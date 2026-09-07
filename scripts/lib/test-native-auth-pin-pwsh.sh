#!/usr/bin/env bash
# test-native-auth-pin-pwsh.sh — run the PowerShell suite for
# native-auth-pin.ps1 from the bash suite runner (HIMMEL-1867).
#
# Same reachability contract as scripts/test-claude-openrouter-pwsh.sh
# (HIMMEL-1792): the .ps1 twin is invisible to every automated check unless a
# bash wrapper executes it. pwsh is a RUNTIME capability this suite needs the
# way the launcher suites need node; where it is absent the wrapper SKIPs —
# loudly and attributed (HIMMEL-1788: an unattended run must never exit-0
# silently) — never as a quiet pass. In the runner it is registered in
# SUITE_REQUIRE_TOOL (capability-conditional): it RUNS wherever pwsh is on
# PATH and the runner's own [SKIP] line covers it where pwsh is absent; this
# guard is the second layer for direct invocation.
#
# Exit codes: 0 = suite ran and passed, or pwsh absent (loud skip); the pwsh
# suite's own exit code otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/test-native-auth-pin.ps1"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[SKIP] test-native-auth-pin-pwsh.sh — pwsh not found on PATH; the PowerShell-side coverage (canonical-set clearing + screen refusal of native-auth-pin.ps1, HIMMEL-1867) did NOT run on this host."
  exit 0
fi

exec pwsh -NoProfile -NonInteractive -File "$SUITE"
