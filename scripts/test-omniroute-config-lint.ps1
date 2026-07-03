#Requires -Version 7
<#
  Hermetic tests for scripts/omniroute-config-lint.ps1 (HIMMEL-654 WS2, child
  HIMMEL-666) - Windows twin of test-omniroute-config-lint.sh. Same fixtures,
  same expected output lines and exit codes. Each fixture is built from one
  compliant BASE (a fresh ordered dict per call) with a targeted patch, then
  serialized with ConvertTo-Json. The lint runs in a CHILD pwsh so a scenario's
  `exit 1`/`exit 2` cannot terminate this harness. Sandbox is a temp dir.
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$Lint = Join-Path $ScriptDir 'omniroute-config-lint.ps1'

$script:fails = 0
function Pass($m) { Write-Host "  ok: $m" }
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fails++ }
function FileHas($path, $needle) { (Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch -Quiet -Pattern $needle) }

$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('omniroute-lint-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
$OutTxt = Join-Path $TMP 'out.txt'
$PassLine = 'PASS: omniroute compression stack disabled (18 keys asserted)'

function Get-Base {
  # Fresh compliant config each call: every bundled optimizer explicitly disabled.
  [ordered]@{
    autoRoutingEnabled = $false
    compression        = [ordered]@{
      enabled                          = $false
      defaultMode                      = 'off'
      autoTriggerMode                  = 'off'
      rtkConfig                        = [ordered]@{ enabled = $false }
      cavemanConfig                    = [ordered]@{ enabled = $false }
      cavemanOutputMode                = [ordered]@{ enabled = $false }
      ultra                            = [ordered]@{ enabled = $false }
      contextEditing                   = [ordered]@{ enabled = $false }
      languageConfig                   = [ordered]@{ enabled = $false }
      mcpDescriptionCompressionEnabled = $false
      mcpAccessibilityConfig           = [ordered]@{ enabled = $false }
      engines                          = [ordered]@{}
      aggressive                       = [ordered]@{ summarizerEnabled = $false; toolStrategies = [ordered]@{} }
      stackedPipeline                  = @()
      cache                            = [ordered]@{ semanticCacheEnabled = $false; promptCacheEnabled = $false }
    }
  }
}

function New-Config { param([string]$Path, [scriptblock]$Patch)
  $c = Get-Base
  if ($Patch) { & $Patch $c }
  $c | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-Lint { param([string[]]$LArgs = @())
  & pwsh -NoProfile -File $Lint @LArgs 2>&1 | Out-File -LiteralPath $OutTxt -Encoding utf8
  return $LASTEXITCODE
}

function Assert-Exit($got, $want, $name) {
  if ($got -eq $want) { Pass $name }
  else { Fail "$name (exit $got, want $want)"; if (Test-Path -LiteralPath $OutTxt) { Get-Content -LiteralPath $OutTxt | ForEach-Object { Write-Host "    | $_" } } }
}
function Have($needle) {
  if (FileHas $OutTxt $needle) { Pass "output has: $needle" }
  else { Fail "output missing: $needle"; if (Test-Path -LiteralPath $OutTxt) { Get-Content -LiteralPath $OutTxt | ForEach-Object { Write-Host "    | $_" } } }
}

try {
  # --- T1: compliant config -> PASS (exit 0) ---
  $f = Join-Path $TMP 'compliant.json'; New-Config $f $null
  Assert-Exit (Invoke-Lint @($f)) 0 'compliant config passes'
  Have $PassLine

  # --- T2: optimization subtree IGNORED -> still PASS ---
  $f = Join-Path $TMP 'opt.json'; New-Config $f { param($c) $c.compression.optimization = [ordered]@{ vacuumIntervalMs = 1000; walEnabled = $true } }
  Assert-Exit (Invoke-Lint @($f)) 0 'optimization subtree ignored, still passes'
  Have $PassLine

  # --- T3: one engine explicitly ENABLED -> FAIL ---
  $f = Join-Path $TMP 'enabled.json'; New-Config $f { param($c) $c.compression.rtkConfig.enabled = $true }
  Assert-Exit (Invoke-Lint @($f)) 1 'explicitly enabled engine fails'
  Have 'FAIL: compression.rtkConfig.enabled expected false, got true'

  # --- T4: one engine entry OMITTED -> FAIL (default-on red path) ---
  $f = Join-Path $TMP 'omitted.json'; New-Config $f { param($c) $c.compression.Remove('cavemanConfig') }
  Assert-Exit (Invoke-Lint @($f)) 1 'omitted engine fails (default-on red path)'
  Have 'FAIL: compression.cavemanConfig.enabled expected false, got <absent>'

  # --- T5: mcpDescriptionCompressionEnabled true (source default TRUE) -> FAIL ---
  $f = Join-Path $TMP 'mcpdesc.json'; New-Config $f { param($c) $c.compression.mcpDescriptionCompressionEnabled = $true }
  Assert-Exit (Invoke-Lint @($f)) 1 'default-on mcpDescriptionCompression true fails'
  Have 'FAIL: compression.mcpDescriptionCompressionEnabled expected false, got true'

  # --- T6: free lane autoRoutingEnabled ABSENT -> FAIL ---
  $f = Join-Path $TMP 'noauto.json'; New-Config $f { param($c) $c.Remove('autoRoutingEnabled') }
  Assert-Exit (Invoke-Lint @($f)) 1 'autoRoutingEnabled absent fails'
  Have 'FAIL: autoRoutingEnabled expected false, got <absent>'

  # --- T7: unknown key inside compression -> FAIL ---
  $f = Join-Path $TMP 'unknown.json'; New-Config $f { param($c) $c.compression.newTurboEngine = [ordered]@{ enabled = $true } }
  Assert-Exit (Invoke-Lint @($f)) 1 'unknown compression key fails'
  Have 'FAIL: compression.newTurboEngine is not a recognized key'

  # --- T8: engines map with one enabled:true entry -> FAIL ---
  $f = Join-Path $TMP 'engine-on.json'; New-Config $f { param($c) $c.compression.engines = [ordered]@{ evil = [ordered]@{ enabled = $true } } }
  Assert-Exit (Invoke-Lint @($f)) 1 'engines entry enabled fails'
  Have 'FAIL: compression.engines["evil"].enabled expected false, got true'

  # --- T8b: engines map with a properly disabled entry -> PASS ---
  $f = Join-Path $TMP 'engine-off.json'; New-Config $f { param($c) $c.compression.engines = [ordered]@{ legacy = [ordered]@{ enabled = $false } } }
  Assert-Exit (Invoke-Lint @($f)) 0 'engines disabled entry passes'
  Have $PassLine

  # --- T9: stackedPipeline non-empty -> FAIL ---
  $f = Join-Path $TMP 'stack.json'; New-Config $f { param($c) $c.compression.stackedPipeline = @([ordered]@{ name = 'x' }) }
  Assert-Exit (Invoke-Lint @($f)) 1 'non-empty stackedPipeline fails'
  Have 'FAIL: compression.stackedPipeline expected an empty array, got 1 entry'

  # --- T9b: stackedPipeline with TWO entries -> FAIL using the PLURAL "entries"
  # branch (the length>1 arm of the entry/ies ternary; T9 only covers the 1-entry
  # "entry" arm). CR F1: this branch was untested on both twins. ---
  $f = Join-Path $TMP 'stack2.json'; New-Config $f { param($c) $c.compression.stackedPipeline = @([ordered]@{ name = 'x' }, [ordered]@{ name = 'y' }) }
  Assert-Exit (Invoke-Lint @($f)) 1 'two-entry stackedPipeline fails (plural)'
  Have 'FAIL: compression.stackedPipeline expected an empty array, got 2 entries'

  # --- T10: wrong string value on defaultMode -> FAIL ---
  $f = Join-Path $TMP 'mode.json'; New-Config $f { param($c) $c.compression.defaultMode = 'aggressive' }
  Assert-Exit (Invoke-Lint @($f)) 1 'wrong defaultMode fails'
  Have 'FAIL: compression.defaultMode expected off, got aggressive'

  # --- T11: aggressive.toolStrategies object entry enabled -> FAIL ---
  $f = Join-Path $TMP 'ts.json'; New-Config $f { param($c) $c.compression.aggressive.toolStrategies = [ordered]@{ bigTool = [ordered]@{ enabled = $true } } }
  Assert-Exit (Invoke-Lint @($f)) 1 'toolStrategies object entry enabled fails'
  Have 'FAIL: compression.aggressive.toolStrategies.bigTool.enabled expected false, got true'

  # --- T11b: aggressive.toolStrategies BARE BOOLEAN true entry -> FAIL (the bare-
  # boolean branch: a strategy expressed as `true` rather than `@{enabled=...}`) ---
  $f = Join-Path $TMP 'tsbool.json'; New-Config $f { param($c) $c.compression.aggressive.toolStrategies = [ordered]@{ bigTool = $true } }
  Assert-Exit (Invoke-Lint @($f)) 1 'toolStrategies bare-boolean true entry fails'
  Have 'FAIL: compression.aggressive.toolStrategies.bigTool expected false, got true'

  # --- T12: compression object missing entirely -> FAIL ---
  $f = Join-Path $TMP 'nocomp.json'; New-Config $f { param($c) $c.Remove('compression') }
  Assert-Exit (Invoke-Lint @($f)) 1 'missing compression object fails'
  Have 'FAIL: compression object is missing'

  # --- T13: ALL failures reported, not just the first ---
  $f = Join-Path $TMP 'multi.json'; New-Config $f { param($c) $c.compression.ultra.enabled = $true; $c.Remove('autoRoutingEnabled') }
  Assert-Exit (Invoke-Lint @($f)) 1 'reports all failures'
  Have 'FAIL: compression.ultra.enabled expected false, got true'
  Have 'FAIL: autoRoutingEnabled expected false, got <absent>'

  # --- T13b..T13f: defensive structural FAIL branches (CR F2). Each exercises a
  # guard the happy path never hits, so a future fail-open simplification is caught.
  # These mirror the bash twin case-for-case (keep both twins' matrices in sync). ---
  # engines MISSING
  $f = Join-Path $TMP 'noeng.json'; New-Config $f { param($c) $c.compression.Remove('engines') }
  Assert-Exit (Invoke-Lint @($f)) 1 'engines missing fails'
  Have 'FAIL: compression.engines missing (expected an object with every entry disabled)'

  # engines present but NOT an object
  $f = Join-Path $TMP 'engnonobj.json'; New-Config $f { param($c) $c.compression.engines = $true }
  Assert-Exit (Invoke-Lint @($f)) 1 'engines non-object fails'
  Have 'FAIL: compression.engines expected an object, got true'

  # aggressive.toolStrategies MISSING
  $f = Join-Path $TMP 'nots.json'; New-Config $f { param($c) $c.compression.aggressive.Remove('toolStrategies') }
  Assert-Exit (Invoke-Lint @($f)) 1 'toolStrategies missing fails'
  Have 'FAIL: compression.aggressive.toolStrategies missing (expected an object with every entry disabled)'

  # aggressive.toolStrategies entry that is a STRING (not bool, not object) -> else branch
  $f = Join-Path $TMP 'tsstr.json'; New-Config $f { param($c) $c.compression.aggressive.toolStrategies = [ordered]@{ weird = 'somestring' } }
  Assert-Exit (Invoke-Lint @($f)) 1 'toolStrategies string entry fails'
  Have 'FAIL: compression.aggressive.toolStrategies.weird expected disabled, got somestring'

  # stackedPipeline MISSING
  $f = Join-Path $TMP 'nosp.json'; New-Config $f { param($c) $c.compression.Remove('stackedPipeline') }
  Assert-Exit (Invoke-Lint @($f)) 1 'stackedPipeline missing fails'
  Have 'FAIL: compression.stackedPipeline missing (expected an empty array)'

  # --- T14: missing/unreadable file -> exit 2 ---
  Assert-Exit (Invoke-Lint @((Join-Path $TMP 'does-not-exist.json'))) 2 'missing file exits 2'

  # --- T15: unparseable JSON -> exit 2 ---
  $f = Join-Path $TMP 'bad.json'; '{ this is not json' | Set-Content -LiteralPath $f -NoNewline
  Assert-Exit (Invoke-Lint @($f)) 2 'unparseable JSON exits 2'

  # --- T16: non-object JSON root -> exit 2 ---
  $f = Join-Path $TMP 'array.json'; '["a","b"]' | Set-Content -LiteralPath $f -NoNewline
  Assert-Exit (Invoke-Lint @($f)) 2 'array root exits 2'

  # --- T17: usage (no args) -> exit 2 ---
  Assert-Exit (Invoke-Lint @()) 2 'no-args usage exits 2'

  # --- T18: usage (two args) -> exit 2 ---
  Assert-Exit (Invoke-Lint @('a', 'b')) 2 'two-args usage exits 2'

  # --- T19: FAIL diagnostics route to STDERR (not stdout); PASS stays on stdout.
  # CR F5: locks the routing contract so a future regression that re-merges FAIL to
  # stdout is caught. (The cases above capture 2>&1, so they pass either way.) ---
  $rf = Join-Path $TMP 'rfail.json'; New-Config $rf { param($c) $c.compression.ultra.enabled = $true }
  $RoutOut = Join-Path $TMP 'rout-stdout.txt'; $RoutErr = Join-Path $TMP 'rout-stderr.txt'
  & pwsh -NoProfile -File $Lint $rf 2>$RoutErr | Out-File -LiteralPath $RoutOut -Encoding utf8
  if ($LASTEXITCODE -eq 1) { Pass 'routing case exit 1' } else { Fail "routing case exit $LASTEXITCODE, want 1" }
  if (FileHas $RoutErr 'FAIL: compression.ultra.enabled expected false, got true') { Pass 'FAIL on stderr' } else { Fail 'FAIL not on stderr' }
  if (FileHas $RoutOut 'FAIL:') { Fail 'FAIL leaked to stdout' } else { Pass 'no FAIL on stdout' }
  # PASS on stdout, nothing on stderr
  $cf = Join-Path $TMP 'rcompliant.json'; New-Config $cf $null
  & pwsh -NoProfile -File $Lint $cf 2>$RoutErr | Out-File -LiteralPath $RoutOut -Encoding utf8
  if ($LASTEXITCODE -eq 0) { Pass 'compliant routing exit 0' } else { Fail "compliant routing exit $LASTEXITCODE, want 0" }
  if (FileHas $RoutOut $PassLine) { Pass 'PASS on stdout' } else { Fail 'PASS not on stdout' }
  $errRaw = if (Test-Path -LiteralPath $RoutErr) { (Get-Content -LiteralPath $RoutErr -Raw) } else { '' }
  if ([string]::IsNullOrWhiteSpace($errRaw)) { Pass 'PASS case stderr empty' } else { Fail 'PASS case wrote to stderr' }

  # --- T21 (CR F6, #836): a DUPLICATE JSON key makes the config ambiguous. Both
  # engines (PS ConvertFrom-Json, node JSON.parse) silently keep the LAST value, so a
  # duplicate-key config could lint differently per platform if an engine ever kept
  # FIRST. The lint now rejects duplicate keys explicitly (pre-parse scan) on BOTH
  # twins, so the outcome is deterministic and cross-platform identical. This case
  # injects a duplicate autoRoutingEnabled whose LAST value is `false` (compliant) —
  # WITHOUT detection the lint would PASS (exit 0), so the exit-1 + dup message here
  # PROVES detection fired, not coincidental keep-last catching a non-compliant last
  # value. The .sh twin asserts the IDENTICAL outcome + message (parity). ---
  $f = Join-Path $TMP 'dupkey.json'
  $baseRaw = '{"autoRoutingEnabled":false,"compression":{"enabled":false,"defaultMode":"off","autoTriggerMode":"off","rtkConfig":{"enabled":false},"cavemanConfig":{"enabled":false},"cavemanOutputMode":{"enabled":false},"ultra":{"enabled":false},"contextEditing":{"enabled":false},"languageConfig":{"enabled":false},"mcpDescriptionCompressionEnabled":false,"mcpAccessibilityConfig":{"enabled":false},"engines":{},"aggressive":{"summarizerEnabled":false,"toolStrategies":{}},"stackedPipeline":[],"cache":{"semanticCacheEnabled":false,"promptCacheEnabled":false}}}'
  $dupRaw = $baseRaw -replace [regex]::Escape('{"autoRoutingEnabled":false,'), '{"autoRoutingEnabled":true,"autoRoutingEnabled":false,'
  $dupRaw | Set-Content -LiteralPath $f -NoNewline
  Assert-Exit (Invoke-Lint @($f)) 1 'duplicate-key config rejected (exit 1, both twins)'
  Have 'FAIL: duplicate JSON key "autoRoutingEnabled"'

  # --- T22 (CR F6, #836 — CR round 2): NESTED duplicate key. The engine keys this
  # lint exists to catch live in nested objects (rtkConfig.enabled etc.), and the
  # scanner's per-object stack is what distinguishes a real nested dup from the
  # many legitimate same-name "enabled" keys across DIFFERENT objects (the
  # compliant PASS case already guards that direction). A dup INSIDE one nested
  # object must flag — catches any future "flatten/scan-root-only" regression the
  # top-level T21 case would miss. LAST value compliant (false) for the same
  # detection-proof reasoning as T21. The .sh twin asserts the IDENTICAL
  # outcome + message (parity). ---
  $f2 = Join-Path $TMP 'nesteddupkey.json'
  $nestedRaw = $baseRaw -replace [regex]::Escape('"rtkConfig":{"enabled":false}'), '"rtkConfig":{"enabled":true,"enabled":false}'
  if ($nestedRaw -eq $baseRaw) { Fail 'T22 fixture injection did not match BASE' }
  $nestedRaw | Set-Content -LiteralPath $f2 -NoNewline
  Assert-Exit (Invoke-Lint @($f2)) 1 'nested duplicate-key config rejected (exit 1, both twins)'
  Have 'FAIL: duplicate JSON key "enabled"'

  # --- T23 (CR F6, #836 — CR round 2): CASE-VARIANT sibling keys — a DOCUMENTED
  # ENGINE DIVERGENCE, deliberately pinned per twin (not parity). ConvertFrom-Json
  # REJECTS keys differing only in case ("keys with different casing") BEFORE the
  # dup scan runs → this twin exits 2 (invalid JSON, fail-closed — the safe
  # direction). node's JSON.parse accepts them as two distinct keys → the .sh twin
  # PASSes exit 0. The exact-dup parity guarantee (T21/T22) is scoped to exact-case
  # duplicates; this case pins each twin's actual behavior so neither drifts
  # silently. (The scanner's Ordinal HashSet keeps its own comparison
  # case-sensitive like node's, should the parse gate ever start admitting
  # case-variant keys, e.g. -AsHashtable.) ---
  $f3 = Join-Path $TMP 'casevariantkey.json'
  $caseRaw = $baseRaw -replace [regex]::Escape('"rtkConfig":{"enabled":false}'), '"rtkConfig":{"enabled":false,"Enabled":false}'
  if ($caseRaw -eq $baseRaw) { Fail 'T23 fixture injection did not match BASE' }
  $caseRaw | Set-Content -LiteralPath $f3 -NoNewline
  Assert-Exit (Invoke-Lint @($f3)) 2 'case-variant sibling keys rejected by ConvertFrom-Json (exit 2; .sh twin exits 0 — documented divergence)'

  Write-Host ''
  if ($script:fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fails) failure(s)" -ForegroundColor Red; exit 1 }
}
finally {
  Remove-Item $TMP -Recurse -Force -ErrorAction SilentlyContinue
}
