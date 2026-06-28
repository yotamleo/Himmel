# Pure vault-root resolver for the end-session-wiki hook — PowerShell twin of
# scripts/lib/vault-resolve.sh (HIMMEL-403). Dot-source it, then call
# Resolve-VaultRoot. Returns the resolved vault root (a leading "~/" or "~\" is
# left LITERAL for the caller to expand once) OR an empty string => the caller
# must skip (log, no write).
#
# Resolution order (first match wins) — identical to the bash twin:
#   1. config.vault_path (existing absolute key)
#   2. config.vault NAME (validated) -> registry[name] -> else
#      <USERPROFILE>\Documents\<name> (only if it has an .obsidian marker, or dry-run)
#   3. LUNA_VAULT_PATH env
#   4. default: registry["luna"] -> else the <USERPROFILE>\Documents\luna
#      convention, but ONLY if it's a real vault (.obsidian marker) or dry-run.
#      No configured and no real luna vault => '' (skip) — the hook never
#      materializes a phantom vault for an adopter (HIMMEL-590 F7).

function Remove-Bom {
    # Strip a leading UTF-8 BOM (U+FEFF) so ConvertFrom-Json doesn't treat the
    # file as invalid JSON and make the hook silently stop capturing (HIMMEL-408).
    # No-op when Get-Content already stripped it; also normalizes $null -> ''.
    param([string]$Text)
    if ($Text.Length -gt 0 -and [int]$Text[0] -eq 0xFEFF) { return $Text.Substring(1) }
    return [string]$Text
}

function Test-VaultName {
    # Validate an untrusted vault name (it travels in a tracked, cloned file).
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..') { return $false }
    if ($Name -match '\.\.') { return $false }            # no ".." substring
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return $false }
    return $true
}

function Get-RegistryVault {
    # Echo registry.vaults[<key>] or '' on any miss/error. No pipeline noise.
    param([string]$RegistryPath, [string]$Key)
    if (-not (Test-Path -LiteralPath $RegistryPath)) { return '' }
    try {
        $r = Remove-Bom (Get-Content -LiteralPath $RegistryPath -Raw) | ConvertFrom-Json -ErrorAction Stop
        if ($r.PSObject.Properties['vaults'] -and $r.vaults.PSObject.Properties[$Key]) {
            $val = $r.vaults.$Key
            if ($val -is [string]) { return $val }   # ignore array/object values
        }
    } catch { }
    return ''
}

function Resolve-VaultRoot {
    param(
        [string]$ConfigPath,
        [string]$RegistryPath,
        [bool]$DryRun = $false
    )
    $userHome = $env:USERPROFILE
    $cfgVaultPath = ''
    $hasVault = $false
    $cfgVault = ''
    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Remove-Bom (Get-Content -LiteralPath $ConfigPath -Raw)
        try {
            $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            # Exists but not valid JSON -> skip (don't misroute to default).
            return ''
        }
        # Fail-closed on a config that isn't a JSON object — an empty file
        # (ConvertFrom-Json -> $null) or a non-object (null/false/[]/"str"/42).
        # Mirrors the bash `type == "object"` guard so both runtimes agree.
        # NB: `-is [pscustomobject]` is unreliable (PS's PSObject adapter makes
        # it true for scalars too); compare the concrete type name instead. The
        # raw-text `[` check also rejects a top-level array — PS auto-unwraps a
        # single-element array ([{...}]) into its inner object, which would
        # otherwise pass the type-name check and diverge from bash.
        if ($null -eq $cfg -or $cfg.GetType().Name -ne 'PSCustomObject' -or $raw.TrimStart().StartsWith('[')) { return '' }
        if ($cfg.PSObject.Properties['vault_path']) { $cfgVaultPath = [string]$cfg.vault_path }
        if ($cfg.PSObject.Properties['vault']) { $hasVault = $true; $cfgVault = [string]$cfg.vault }
    }

    # 1. explicit absolute vault_path (existing key) wins.
    if ($cfgVaultPath) { return $cfgVaultPath }

    # 2. per-repo vault NAME (validated, fail-closed). A PRESENT key (even empty)
    #    enters this branch; only an absent key falls through to steps 3-4.
    if ($hasVault) {
        if (-not (Test-VaultName $cfgVault)) { return '' }       # invalid/empty => skip
        $reg = Get-RegistryVault -RegistryPath $RegistryPath -Key $cfgVault
        if ($reg) {
            if ($reg -match '\.\.') { return '' }                       # reject traversal
            if ($reg -notmatch '^([A-Za-z]:[\\/]|[\\/]|~[\\/])') { return '' }  # require absolute or ~/
            return $reg
        }
        $conv = Join-Path (Join-Path $userHome 'Documents') $cfgVault
        if ($DryRun -or (Test-Path -LiteralPath (Join-Path $conv '.obsidian'))) { return $conv }
        return ''                                                # declared but no real vault => skip
    }

    # 3. LUNA_VAULT_PATH env.
    if ($env:LUNA_VAULT_PATH) { return $env:LUNA_VAULT_PATH }

    # 4. default: registry["luna"] (explicit operator config -> honored unchecked,
    #    like vault_path) else the Documents\luna convention, but ONLY if it's a
    #    REAL vault (.obsidian marker) or in dry-run. An adopter who never
    #    configured luna has no such directory -> '' (skip), so the session-end
    #    hook never writes into / creates a phantom vault (HIMMEL-590 F7).
    $def = Get-RegistryVault -RegistryPath $RegistryPath -Key 'luna'
    if ($def) { return $def }
    $conv = Join-Path (Join-Path $userHome 'Documents') 'luna'
    if ($DryRun -or (Test-Path -LiteralPath (Join-Path $conv '.obsidian'))) { return $conv }
    return ''
}
