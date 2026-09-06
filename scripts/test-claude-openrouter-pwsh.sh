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
# Exit codes: 0 = suite ran and passed, or pwsh absent (loud skip); 1 = this
# wrapper's OWN setup failed (mktemp, or writing/chmod-ing the hermetic claude
# shim below) before pwsh ever ran — a distinct failure class from the suite
# itself, not the pwsh suite's exit code; the pwsh suite's own exit code
# otherwise, propagated unchanged once it actually runs.
#
# HIMMEL-2599: the .ps1 suite's own mock `claude` is a Windows batch file
# (claude.cmd). pwsh's native-command PATH lookup on non-Windows hosts is a
# literal filename match — no PATHEXT-style extension resolution — so
# claude.cmd is invisible to the launcher's bare `claude` lookup there, and
# the suite's `& claude ...` call falls straight through the fixture's BIN
# dir to whatever REAL claude sits further down PATH. Every dev station has
# one installed, so it silently absorbed the launch and the suite stayed
# green there; the GitHub Actions runner has no claude on PATH at all, so the
# launcher's own "claude not found" guard fired and every launch case failed
# (exit 2) before reaching its real assertion. This wrapper is bash-only —
# it never runs the .ps1 suite on Windows — so the fix lives entirely here:
# install a hermetic POSIX `claude` shim ahead of the suite's own PATH so it
# wins UNCONDITIONALLY, runner or dev station, real CLI installed or not.
# The shim mirrors the .cmd mock's contract: it records argv and dumps the
# full child env exactly where the suite already expects them
# ($MOCK_ARGV_OUT / $MOCK_ENV_OUT), inherited via the environment the same
# way the .cmd's own pwsh sub-invocation does it.
#
# We do NOT exec pwsh: exec replaces this shell, so nothing would ever remove
# SHIM_DIR — every run would leak a temp directory. Instead we run pwsh,
# capture its exit status, clean up (via an EXIT trap, so it also fires if
# this wrapper is interrupted or dies before pwsh returns), and exit with
# pwsh's own status unchanged — preserving the "the pwsh suite's own exit
# code otherwise" contract documented above.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/test-claude-openrouter.ps1"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[SKIP] test-claude-openrouter-pwsh.sh — pwsh not found on PATH; the PowerShell-side coverage (first-launch seeding + egress refusal of claude-openrouter.ps1, HIMMEL-1792) did NOT run on this host."
  exit 0
fi

SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-openrouter-pwsh-shim.XXXXXX")" || {
  echo "test-claude-openrouter-pwsh.sh: mktemp -d failed; cannot build the hermetic claude shim" >&2
  exit 1
}
# shellcheck disable=SC2317,SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
  # Guard against SHIM_DIR being unset/empty before removing anything, and
  # remove exactly the directory we created — nothing derived/globbed.
  if [ -n "${SHIM_DIR:-}" ] && [ -d "$SHIM_DIR" ]; then
    rm -rf -- "$SHIM_DIR"
  fi
}
trap cleanup EXIT

# Both the heredoc write and the chmod below are checked: with `set -u` but
# no `set -e` in this file, neither failure would otherwise stop the script
# (disk full, a read-only TMPDIR, a restrictive umask). An unnoticed failure
# here leaves $SHIM_DIR/claude missing or non-executable, so pwsh's PATH
# lookup would fall straight through to a real `claude` further down PATH —
# silently reintroducing the exact failure this whole fix exists to prevent.
# Abort loudly instead, same shape as the mktemp guard above.
if ! cat > "$SHIM_DIR/claude" <<'SHIM'
#!/usr/bin/env bash
# Hermetic claude shim (HIMMEL-2599) — see the wrapper's own header comment.
# Stands in unconditionally, ahead of any real claude on PATH, so the .ps1
# suite's launch cases never depend on (or silently fall through to) a real
# CLI install. Records argv + dumps the full child env where the suite
# expects them.
#
# The :? guards are deliberate: Invoke-Launcher (test-claude-openrouter.ps1)
# sets both $env:MOCK_ARGV_OUT and $env:MOCK_ENV_OUT unconditionally, before
# EVERY launcher invocation in EVERY test case — including cases (T1, T2,
# T2b) whose launcher exits before ever reaching `& claude`. This shim can
# only ever run as a child of that launcher process, which only runs as a
# child of Invoke-Launcher, so both vars are always set by the time this
# shim executes; an unbound one here would mean the shim was reached through
# some path the suite never takes, which is worth failing loudly on rather
# than masking.
printf '%s\n' "$*" >> "${MOCK_ARGV_OUT:?}"
env > "${MOCK_ENV_OUT:?}"
exit 0
SHIM
then
  echo "test-claude-openrouter-pwsh.sh: failed writing the hermetic claude shim to $SHIM_DIR/claude" >&2
  exit 1
fi
if ! chmod +x "$SHIM_DIR/claude"; then
  echo "test-claude-openrouter-pwsh.sh: failed making the hermetic claude shim executable ($SHIM_DIR/claude)" >&2
  exit 1
fi
export PATH="$SHIM_DIR:$PATH"

pwsh -NoProfile -NonInteractive -File "$SUITE"
status=$?
exit "$status"
