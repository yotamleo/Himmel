#requires -Version 5
# HIMMEL-709 — PowerShell twin of setup-hooks.sh (git hooks + guardrail mode toggle).
[CmdletBinding()]
param(
  [ValidateSet('global', 'project')]
  [string]$GuardrailMode,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuardrailBlock = Join-Path $ScriptDir 'hooks/guardrail-block.mjs'

function Resolve-NodeAbs {
  $n = Get-Command node -ErrorAction SilentlyContinue
  if (-not $n) { throw 'setup-hooks: node not found on PATH (required for guardrail mode)' }
  return $n.Source
}

# Absolute native bash for the wrapper's GUARDRAIL_BASH — prefer git-bash.exe so a
# WSL System32 stub can't fail the guardrail closed.
function Resolve-BashAbs {
  foreach ($c in @('C:/Program Files/Git/bin/bash.exe', 'C:/Program Files/Git/usr/bin/bash.exe', 'C:/Program Files (x86)/Git/bin/bash.exe')) {
    if (Test-Path $c) { return $c }
  }
  $b = Get-Command bash -ErrorAction SilentlyContinue
  if ($b) { return $b.Source }
  return 'bash'
}

function Invoke-GuardrailMode {
  param([string]$Mode)

  Resolve-NodeAbs | Out-Null
  $current = (& node $GuardrailBlock detect).Trim()

  if ($Mode -eq 'project') {
    if ($current -ne 'global') { Write-Host 'guardrail mode already project (no user-level block to remove).'; return }
    # Destructive: NEVER infer consent from a non-tty (an in-himmel agent runs
    # non-interactive and must not silently strip the security guardrails).
    if (-not $Yes -and [Console]::IsInputRedirected) {
      # Write to stderr directly, NOT Write-Error — under ErrorActionPreference
      # 'Stop' Write-Error throws (exit 1) before we reach the intended exit 3.
      [Console]::Error.WriteLine('setup-hooks: refusing global->project (removes user-level guardrails) without -Yes on a non-interactive shell')
      exit 3
    }
    if (-not $Yes) {
      $ans = Read-Host 'Remove the user-level guardrail block (global -> project)? [y/N]'
      if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host 'aborted.'; return }
    }
    & node $GuardrailBlock project
    return
  }

  # global: prompt only on a real transition; then always re-sync (idempotent;
  # re-bakes stale paths in place — the re-home case).
  if ($current -ne 'global' -and -not $Yes) {
    $ans = Read-Host 'Install the himmel user-level guardrail block (-> global)? [y/N]'
    if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host 'aborted.'; return }
  }
  $nodeAbs = Resolve-NodeAbs
  $bashAbs = Resolve-BashAbs
  & node $GuardrailBlock global --node $nodeAbs --bash $bashAbs
}

if ($GuardrailMode) {
  Invoke-GuardrailMode -Mode $GuardrailMode
  exit 0
}

# ── git / pre-commit hooks (default) ─────────────────────────────────────────
Write-Host '==> Installing pre-commit...'
pip install pre-commit --quiet
Write-Host '==> Installing git hooks...'
pre-commit install
pre-commit install --hook-type pre-push
pre-commit install --hook-type commit-msg
Write-Host "==> Done. Run 'pre-commit run --all-files' to validate all hooks now."

if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $GuardrailBlock)) {
  Write-Host ('==> guardrail mode: ' + (& node $GuardrailBlock status))
  Write-Host '    Toggle with: pwsh scripts/setup-hooks.ps1 -GuardrailMode global|project [-Yes]'
}
