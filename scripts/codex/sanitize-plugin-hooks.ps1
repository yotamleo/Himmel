<#
.SYNOPSIS
  Strip the top-level `description` key from external-plugin hooks.json under the
  Codex plugin cache (HIMMEL-651) — twin of sanitize-plugin-hooks.sh.

.DESCRIPTION
  Codex's strict plugin-hooks parser rejects a top-level `description`
  ("unknown field description") and skips those hooks at boot. himmel-owned
  plugins don't ship that shape; this clears the boot-time noise from external
  plugins (warp, hookify, ralph-loop, security-guidance, ...).

  Idempotent + re-runnable: re-run after a `codex` plugin update re-adds the
  field. Only the `description` key is removed; the `hooks` block is preserved.

    sanitize-plugin-hooks.ps1            # strip in place, report
    sanitize-plugin-hooks.ps1 -DryRun    # report what WOULD change, mutate nothing

  Env overrides: CODEX_HOME (default ~/.codex).
#>
[CmdletBinding(PositionalBinding=$false)]
param(
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$cache     = Join-Path $codexHome 'plugins/cache'

if (-not (Test-Path -LiteralPath $cache)) {
  Write-Host "OK: no Codex plugin cache at $cache (nothing to sanitize)."
  exit 0
}

$scanned  = 0
$stripped = 0
# `foreach` (statement, not ForEach-Object) runs in THIS scope so the counters
# persist across iterations.
foreach ($item in (Get-ChildItem -LiteralPath $cache -Recurse -Filter hooks.json -File)) {
  $scanned++
  $file = $item.FullName
  try {
    $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  } catch {
    Write-Warning "SKIP (parse): $file - $($_.Exception.Message)"
    continue
  }
  if ($json.PSObject.Properties.Name -contains 'description') {
    if ($DryRun) {
      Write-Host "WOULD STRIP : $file"
    } else {
      $json.PSObject.Properties.Remove('description')
      $text = ($json | ConvertTo-Json -Depth 100)
      # Write to a sibling temp then atomic Move-Item, mirroring the .sh twin's
      # temp+mv (an interrupted write never corrupts the cache file). UTF8Encoding
      # ($false) is BOM-free AND works on Windows PowerShell 5.1 (where the
      # `-Encoding utf8NoBOM` token does NOT exist); a BOM would itself trip
      # Codex's strict parser.
      $tmp = Join-Path $item.DirectoryName ('.hooks.json.' + [guid]::NewGuid().ToString('N').Substring(0,8))
      [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
      Move-Item -LiteralPath $tmp -Destination $file -Force
      Write-Host "STRIPPED    : $file"
    }
    $stripped++
  }
}

Write-Host ""
if ($DryRun) {
  Write-Host "DRY-RUN: $stripped of $scanned hooks.json would be sanitized."
} elseif ($stripped -eq 0) {
  Write-Host "OK: nothing to sanitize ($scanned hooks.json already clean)."
} else {
  Write-Host "OK: sanitized $stripped of $scanned hooks.json. Restart Codex to clear the warnings."
}
