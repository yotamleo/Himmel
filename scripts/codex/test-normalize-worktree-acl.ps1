$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'normalize-worktree-acl.ps1'
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('himmel-acl-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$Pass = 0
$Fail = 0

function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

function Run-Helper([string]$Path, [string]$Icacls) {
  $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $Helper $Path -IcaclsPath $Icacls 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out | Out-String) }
}

try {
  New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
  $primary = Join-Path $Tmp 'primary-checkout'
  New-Item -ItemType Directory -Path $primary -Force | Out-Null

  $log = Join-Path $Tmp 'icacls.log'
  $fake = Join-Path $Tmp 'fake-icacls.ps1'
  @"
`$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath '$log' -Value (`$args -join '|')
exit 0
"@ | Set-Content -NoNewline -Path $fake

  Write-Host 'Test 1: primary checkout path is refused before icacls runs'
  $r = Run-Helper $primary $fake
  Check 'primary checkout exits 2' ($r.Code -eq 2) "rc=$($r.Code) out=$($r.Output)"
  Check 'primary checkout refusal mentions .claude\worktrees' ($r.Output -like '*.claude\worktrees*') $r.Output
  Check 'primary checkout did not invoke icacls' (-not (Test-Path -LiteralPath $log))

  Write-Host 'Test 2: fake worktree invokes icacls once per top-level child directory'
  $wt = Join-Path $Tmp '.claude\worktrees\fix+acl'
  $childA = Join-Path $wt 'scripts'
  $childB = Join-Path $wt 'docs'
  $nested = Join-Path $childA 'nested'
  New-Item -ItemType Directory -Path $nested -Force | Out-Null
  New-Item -ItemType Directory -Path $childB -Force | Out-Null
  Set-Content -NoNewline -Path (Join-Path $wt 'README.md') -Value 'not a directory'
  Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue

  $r = Run-Helper $wt $fake
  Check 'worktree exits 0' ($r.Code -eq 0) "rc=$($r.Code) out=$($r.Output)"
  $calls = @(Get-Content -LiteralPath $log)
  Check 'two top-level directory calls' ($calls.Count -eq 2) ($calls -join '; ')
  Check 'scripts child reset with expected args' ($calls -contains "$childA|/reset|/T|/C|/Q") ($calls -join '; ')
  Check 'docs child reset with expected args' ($calls -contains "$childB|/reset|/T|/C|/Q") ($calls -join '; ')
  Check 'root itself is never reset' (-not ($calls -contains "$wt|/reset|/T|/C|/Q")) ($calls -join '; ')
  Check 'nested dir is not a separate top-level call' (-not ($calls -contains "$nested|/reset|/T|/C|/Q")) ($calls -join '; ')

  Write-Host "Results: $Pass passed, $Fail failed"
  if ($Fail -ne 0) { exit 1 }
} finally {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}
