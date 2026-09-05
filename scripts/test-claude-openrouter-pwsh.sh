#!/usr/bin/env bash
# test-claude-openrouter-pwsh.sh — run the PowerShell smoke suite for
# claude-openrouter.ps1 from the bash suite runner (HIMMEL-1792).
#
# The .ps1 twin was invisible to every automated check before this ticket: the
# bash suite never executes it, so a PowerShell-only regression shipped green
# (HIMMEL-1774 CR round 3). This wrapper makes the .ps1 suite reachable from
# scripts/ci/run-shell-tests.sh while degrading cleanly on hosts without
# PowerShell.
#
# pwsh is a RUNTIME capability this suite needs the way the launcher suites
# need node. Where it is absent the wrapper SKIPs — loudly and attributed
# (HIMMEL-1788: an unattended run must never exit-0 silently), never as a
# quiet pass: the skip line is the wrapper's entire output. In the runner it
# is registered in SUITE_REQUIRE_TOOL (capability-conditional, HIMMEL-1792):
# it RUNS wherever pwsh is on PATH and the runner's own [SKIP] line — the one
# place a skip is visible in a green full-suite run — covers it where pwsh is
# absent. This guard is the SECOND layer (belt and braces): it covers direct
# invocation and any host that overrides the runner table.
#
# Exit codes: 0 = suite ran and passed, or pwsh absent (loud skip); the pwsh
# suite's own exit code otherwise.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/test-claude-openrouter.ps1"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[SKIP] test-claude-openrouter-pwsh.sh — pwsh not found on PATH; the PowerShell-side coverage (first-launch seeding + egress refusal of claude-openrouter.ps1, HIMMEL-1792) did NOT run on this host."
  exit 0
fi

exec pwsh -NoProfile -NonInteractive -File "$SUITE"
