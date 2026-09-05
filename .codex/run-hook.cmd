@echo off
REM himmel Codex hook wrapper (HIMMEL-427/HIMMEL-2019). Windows-only; Codex
REM selects this file through commandWindows. Unix uses run-hook.sh.
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
REM The adapter exits 0 on EVERY normal path (a block lives in its stdout JSON,
REM not its exit code — HIMMEL-1987). So in sandbox mode a nonzero adapter code
REM means the ADAPTER ITSELF failed to run (Git Bash unusable, fork failure under
REM memory pressure, ...) — the guardrail never ran. Propagating that code made
REM Codex render "hook exited with code 1" while still failing OPEN (HIMMEL-1981);
REM instead we fail CLOSED with the JSON deny Codex honours and exit 0. Guardrails
REM read the hook JSON from STDIN (inherited); the wrapper forwards no positional
REM args to them.
REM
REM Usage (from .codex/hooks.json):
REM   run-hook.cmd [--sandbox|--no-sandbox] [--lifecycle] <script-name.sh>
REM Missing script name -> fail CLOSED with a JSON deny on stdout (exit /b 2 would
REM fail OPEN under Codex), mirroring the no-Git-Bash branch below. Sandbox mode
REM is the default and the tracked .codex/hooks.json setup. --no-sandbox is only
REM for trusted/manual diagnostics where surfacing the raw child rc is useful.
REM
REM --lifecycle marks a hook wired to a NO-PERMISSION-GATE event (SessionStart,
REM Stop): there is nothing to deny there, and Codex's per-event output schemas
REM reject a PreToolUse deny envelope. So on an adapter failure a lifecycle hook
REM reports honestly (stderr + rc 1 -> Codex's "hook failed" banner) instead of
REM emitting a deny shaped for the wrong event, while a permission-gate hook
REM (the default) still fails CLOSED. That applies to EVERY failure — the
REM preconditions below all route through one `:failclosed` exit, so a new branch
REM cannot forget the contract. `.codex/hooks.json` must carry the flag on every
REM SessionStart/Stop entry — enforced by test-codex-hook-parity.sh.
REM The wrapper is the ONLY authority on the lifecycle flag: clear any inherited
REM value first, or a permission-gate hook launched from an environment that
REM already exported it would downgrade its fail-closed deny to a bare rc 1
REM (which Codex fails OPEN on).
set "HIMMEL_CODEX_HOOK_LIFECYCLE="
set "HOOK_MODE=sandbox"
set "HOOK_KIND=gate"
set "HOOK_NAME=%~1"
if /i "%~1"=="--sandbox" set "HOOK_NAME=%~2"
if /i "%~1"=="--no-sandbox" (
  set "HOOK_MODE=no-sandbox"
  set "HOOK_NAME=%~2"
)
REM --lifecycle is accepted both on its own and after a mode flag, matching the
REM usage line and the Unix branch's flag loop.
if /i "%~1"=="--lifecycle" (
  set "HOOK_KIND=lifecycle"
  set "HOOK_NAME=%~2"
)
if /i "%~2"=="--lifecycle" (
  set "HOOK_KIND=lifecycle"
  set "HOOK_NAME=%~3"
)
if "%HOOK_NAME%"=="" (
  set "FAIL_REASON=missing script name"
  goto :failclosed
)
if /i "%HOOK_KIND%"=="lifecycle" set "HIMMEL_CODEX_HOOK_LIFECYCLE=1"
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
  set "FAIL_REASON=no Git Bash found - install Git for Windows"
  goto :failclosed
)
if not exist "%ADAPTER%" (
  set "FAIL_REASON=adapter not found"
  goto :failclosed
)
REM Git Bash can exist but be unusable inside Codex's Windows sandbox (or fail to
REM fork under memory pressure); Codex then treats the failed hook as non-blocking
REM and allows the tool call. The adapter call itself is the startup check — it
REM exits 0 on every normal path, so a nonzero code means it never ran. Checking
REM AFTER the fact rather than smoke-testing `bash -c "exit 0"` first saves a whole
REM extra bash spawn per hook invocation (HIMMEL-1981: the Codex hook chain was
REM pwsh -> cmd -> bash(smoke) -> bash(adapter) -> bash(guardrail); the smoke spawn
REM is both a third of the cost and, under fork pressure, the thing that fails).
REM No-sandbox diagnostics keep surfacing the raw child rc instead.
REM Flat branches, not nested if-blocks: `exit /b <code>` from a DOUBLY nested
REM block returns 0 under cmd.exe (same family as the bare-`exit /b` trap noted
REM above), which silently downgraded the lifecycle failure to success.
call "%BASH%" "%ADAPTER%" "%HOOK_NAME%"
if /i "%HOOK_MODE%"=="no-sandbox" exit /b %ERRORLEVEL%
if not errorlevel 1 exit /b 0
set "FAIL_REASON=hook adapter did not complete - Git Bash unusable or an adapter precondition failed"
goto :failclosed

REM Single failure exit for EVERY precondition + the adapter-failure path, so the
REM lifecycle contract cannot be honoured on one branch and skipped on another.
REM FAIL_REASON must stay free of ( ) — it is expanded while cmd parses the
REM if-block below, where an unescaped paren would close the block early.
:failclosed
if /i "%HOOK_KIND%"=="lifecycle" (
  echo run-hook.cmd: %FAIL_REASON%; advisory hook %HOOK_NAME% did not run 1>&2
  exit /b 1
)
echo {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"run-hook.cmd: %FAIL_REASON%; blocking %HOOK_NAME% fail-closed"}}
exit /b 0
