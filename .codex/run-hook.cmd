: << 'CMDBLOCK'
@echo off
REM himmel Codex hook wrapper (HIMMEL-427). Polyglot: cmd.exe runs the batch
REM part on Windows; bash interprets the part after CMDBLOCK on Unix (`:` is a
REM no-op and `<< 'CMDBLOCK'` swallows the batch lines as a heredoc).
REM
REM Fixes the reasons himmel's PreToolUse guardrails don't fire/block under Codex:
REM   (1) Codex injects NO CLAUDE_PROJECT_DIR for *project* hooks -> derive the
REM       repo root from this wrapper's own location (.codex\.. ) and export it.
REM   (2) bare `bash` via cmd.exe hits the WSL System32\bash.exe stub (can't read
REM       C:\, exit 127) -> find Git Bash explicitly; skip any System32 bash.
REM   (3) himmel guardrails BLOCK by exiting 2 (Claude convention); Codex ignores
REM       exit 2 and blocks only on a JSON permissionDecision:"deny" on stdout ->
REM       both branches delegate to codex-hook-adapter.sh, which runs the guardrail
REM       and translates an exit-2 block into the JSON deny Codex understands.
REM
REM The adapter exits 0 after emitting a deny (the block now lives in its stdout
REM JSON, not the exit code), so propagating its code with `exit /b %ERRORLEVEL%`
REM at TOP LEVEL is still correct (a bare `exit /b` inside an if-(...) block
REM returns 0, not the child's code). Guardrails read the hook JSON from STDIN
REM (inherited); the wrapper forwards no positional args to them.
REM
REM Usage (from .codex/hooks.json): run-hook.cmd [--sandbox|--no-sandbox] <script-name.sh>
REM Missing script name -> fail CLOSED with a JSON deny on stdout (exit /b 2 would
REM fail OPEN under Codex), mirroring the no-Git-Bash branch below. Sandbox mode
REM is the default and the tracked .codex/hooks.json setup. --no-sandbox is only
REM for trusted/manual diagnostics where surfacing the raw child rc is useful.
set "HOOK_MODE=sandbox"
set "HOOK_NAME=%~1"
if /i "%~1"=="--sandbox" set "HOOK_NAME=%~2"
if /i "%~1"=="--no-sandbox" (
  set "HOOK_MODE=no-sandbox"
  set "HOOK_NAME=%~2"
)
if "%HOOK_NAME%"=="" (
  echo {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"run-hook.cmd: missing script name - fail closed"}}
  exit /b 0
)
set "HOOK_DIR=%~dp0"
for %%I in ("%HOOK_DIR%..") do set "CLAUDE_PROJECT_DIR=%%~fI"
set "ADAPTER=%CLAUDE_PROJECT_DIR%\.codex\codex-hook-adapter.sh"
set "BASH="
if defined HIMMEL_CODEX_HOOK_BASH set "BASH=%HIMMEL_CODEX_HOOK_BASH%"
if not defined BASH if exist "C:\Program Files\Git\bin\bash.exe" set "BASH=C:\Program Files\Git\bin\bash.exe"
if not defined BASH if exist "C:\Program Files (x86)\Git\bin\bash.exe" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not defined BASH for /f "delims=" %%B in ('where bash 2^>nul') do echo %%B| find /i "\System32\" >nul || if not defined BASH set "BASH=%%B"
REM No Git Bash -> FAIL CLOSED. himmel guardrails are fail-closed and Git Bash is a
REM hard dependency; a missing-bash env is misconfigured and must be surfaced
REM loudly, never silently run unprotected. Emit Codex's JSON deny on stdout (exit
REM 2 would fail OPEN under Codex), and exit 0 so the deny decision is honored.
if not defined BASH (
  echo {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"run-hook.cmd: no Git Bash found (install Git for Windows); blocking %HOOK_NAME% fail-closed"}}
  exit /b 0
)
if not exist "%ADAPTER%" (
  echo {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"run-hook.cmd: adapter not found; blocking %HOOK_NAME% fail-closed"}}
  exit /b 0
)
REM Git Bash can exist but be unusable inside Codex's Windows sandbox. In sandbox
REM mode, smoke-test startup before invoking the adapter; otherwise Codex may
REM treat the failed hook as non-blocking and allow the tool call. No-sandbox
REM diagnostics skip this check and surface the raw child rc.
if /i not "%HOOK_MODE%"=="no-sandbox" (
  call "%BASH%" --noprofile --norc -c "exit 0" >nul 2>nul
  if errorlevel 1 (
    echo {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"run-hook.cmd: Git Bash failed startup check; blocking %HOOK_NAME% fail-closed"}}
    exit /b 0
  )
)
call "%BASH%" "%ADAPTER%" "%HOOK_NAME%"
exit /b %ERRORLEVEL%
CMDBLOCK

# --- Unix (bash) ------------------------------------------------------------
# `:`/heredoc above hid the batch lines from bash; resolve + run the adapter,
# which runs the guardrail and translates an exit-2 block into Codex's JSON deny.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PROJECT_DIR="$(cd "$HOOK_DIR/.." && pwd)"
export CLAUDE_PROJECT_DIR
# Guardrails read the hook JSON from stdin (inherited); no positional args
# forwarded. A missing script name is handled by the adapter (fail-closed JSON
# deny), so it is passed straight through rather than gated with a bare exit 2.
case "${1:-}" in
  --sandbox|--no-sandbox) shift ;;
esac
exec bash "$CLAUDE_PROJECT_DIR/.codex/codex-hook-adapter.sh" "${1:-}"
