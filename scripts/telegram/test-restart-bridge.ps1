# Hermetic tests for restart-bridge.ps1's server.ts attribution (HIMMEL-1309).
# Get-CimInstance is NOT mocked: the .ps1 exposes a pure classifier,
# Get-ServerTsAttribution, fed a synthetic parent lookup. We dot-source with
# -AsLibrary (defines the function, never touches the bridge) and assert the
# attribution for the exact topology that produced the 2026-07-27 misdiagnosis:
# 45 luna-correlate MCP servers reported as "rogue telegram-himmel children …
# live 2nd getUpdates consumer".
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'restart-bridge.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

. $Helper -AsLibrary

function Rec($procId, $parentId, $cl) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = 'bun.exe'; CommandLine = $cl }
}
function ByPid($procs) {
  $h = @{}
  foreach ($p in $procs) { $h[[string]$p.ProcessId] = $p }
  return $h
}

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source — the propagation leak scan fail-closes on them).
$UserHomeFwd = ($env:USERPROFILE) -replace '\\', '/'
$Cache = "$UserHomeFwd/.codex/plugins/cache/himmel"
$LUNA_LAUNCHER = "`"$UserHomeFwd/.bun/bin\bun.exe`" run --cwd $Cache/luna-correlate/0.2.0 --shell=bun --silent start"
$TELE_LAUNCHER = "`"$UserHomeFwd/.bun/bin\bun.exe`" run --cwd $Cache/telegram-himmel/0.0.6 --shell=bun --silent start"
$SERVER = 'bun.exe server.ts'

$table = @(
  (Rec 100 1   $LUNA_LAUNCHER)
  (Rec 101 100 $SERVER)          # luna-correlate MCP server -> codex-plugin
  (Rec 200 1   $TELE_LAUNCHER)
  (Rec 201 200 $SERVER)          # telegram-himmel MCP server -> telegram
  (Rec 301 999 $SERVER)          # launcher pid 999 absent -> unattributable
  (Rec 400 1   $null)
  (Rec 401 400 $SERVER)          # launcher cmdline unreadable -> unattributable
)
$map = ByPid $table

Write-Host "Test 1: the 2026-07-27 misdiagnosis — a luna-correlate MCP server is NOT telegram"
Check 'luna-correlate server.ts attributes to codex-plugin' `
  ((Get-ServerTsAttribution -Proc $table[1] -ByPid $map) -eq 'codex-plugin') `
  "got=$(Get-ServerTsAttribution -Proc $table[1] -ByPid $map)"

Write-Host "Test 2: a real telegram-himmel child IS still attributed to telegram"
Check 'telegram-himmel server.ts attributes to telegram' `
  ((Get-ServerTsAttribution -Proc $table[3] -ByPid $map) -eq 'telegram')

Write-Host "Test 3: an unreadable launcher is 'unattributable', never a telegram claim"
Check 'dead launcher -> unattributable'      ((Get-ServerTsAttribution -Proc $table[4] -ByPid $map) -eq 'unattributable')
Check 'blind launcher cmdline -> unattributable' ((Get-ServerTsAttribution -Proc $table[6] -ByPid $map) -eq 'unattributable')

Write-Host "Test 4: --cwd is read in every spelling the live table actually uses"
foreach ($case in @(
    @{ n = 'backslash separators'; cl = "bun run --cwd $($Cache -replace '/', '\')\telegram-himmel\0.0.6 start"; want = 'telegram' },
    @{ n = 'quoted path with a space'; cl = "bun run --cwd `"C:/a b/.codex/plugins/cache/himmel/telegram-himmel/0.0.6`" start"; want = 'telegram' },
    @{ n = '--cwd=<path> form'; cl = "bun run --cwd=$Cache/luna-correlate/0.2.0 start"; want = 'codex-plugin' },
    @{ n = 'other plugin, telegram nowhere in it'; cl = "bun run --cwd $Cache/qmd/1.0.0 start"; want = 'codex-plugin' }
  )) {
  $t = @((Rec 10 1 $case.cl), (Rec 11 10 $SERVER))
  Check "$($case.n) -> $($case.want)" ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq $case.want) `
    "got=$(Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t))"
}

Write-Host "Test 5: a plugin merely NAMED like telegram-himmel does not borrow its identity"
$t = @((Rec 20 1 "bun run --cwd $Cache/telegram-himmel-fork/0.0.1 start"), (Rec 21 20 $SERVER))
Check 'telegram-himmel-fork attributes to codex-plugin, not telegram' `
  ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'codex-plugin') `
  "got=$(Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t))"

Write-Host "Test 6: a launcher with no --cwd still attributes by its plugin lineage"
$t = @((Rec 30 1 'bun run telegram-himmel start'), (Rec 31 30 $SERVER))
Check 'bare telegram-himmel mention -> telegram' ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'telegram')
$t = @((Rec 40 1 "bun $UserHomeFwd/.codex/plugins/cache/himmel/other/1.0.0/index.ts"), (Rec 41 40 $SERVER))
Check 'bare .codex plugin-cache path -> codex-plugin' ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'codex-plugin')
$t = @((Rec 50 1 'bun some-unrelated-thing.ts'), (Rec 51 50 $SERVER))
Check 'an unrelated bun parent -> unattributable (never a telegram claim)' `
  ((Get-ServerTsAttribution -Proc $t[1] -ByPid (ByPid $t)) -eq 'unattributable')

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
