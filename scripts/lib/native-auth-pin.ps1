# native-auth-pin.ps1 -- PowerShell counterpart of native-auth-pin.sh
# (HIMMEL-1867, epic HIMMEL-1859). PowerShell cadence sites (voice-loop.ps1 is
# a converted site in this epic) cannot source the bash chokepoint, so the twin
# carries the SAME two behaviours over the SAME canonical variable set defined
# in native-auth-pin.sh's header -- that header is the single definition this
# twin is checked against:
#
#   every environment variable whose UPPER-CASED name starts with
#   `ANTHROPIC_` or `CLAUDE_CODE_USE_`
#
# CLAUDE_CODE_OAUTH_TOKEN is NOT in the set (native credential). The proxy
# launchers (claude-codex.ps1, claude-glm.ps1) are supposed to set
# ANTHROPIC_BASE_URL and are out of scope.
#
# Dot-source to use the functions:
#   . <himmel>/scripts/lib/native-auth-pin.ps1
#   NativeAuthPinEnv                        # before any headless claude launch
#   if (-not (NativeAuthPinScreenSettings $payload)) { exit 3 }
# Or run as a script (refusal = exit 3, like the bash side's return):
#   pwsh -File native-auth-pin.ps1 -ClearEnv
#   pwsh -File native-auth-pin.ps1 -ScreenPayload '<inline json or file path>'

[CmdletBinding()]
param(
    [switch]$ClearEnv,
    [string]$ScreenPayload
)

function NativeAuthPinEnv {
    # REMOVE (not empty-set) every canonical-set variable from the PROCESS
    # environment, so children spawned after this point cannot inherit it.
    # An empty ANTHROPIC_API_KEY is itself a routed-auth shape; removal is the
    # only form that neutralises. GetEnvironmentVariables('Process') returns a
    # fresh table, and the keys are snapshotted into an array BEFORE any
    # deletion so the collection is never modified mid-iteration.
    #
    # Removal is `Remove-Item env:` and NOT
    # [Environment]::SetEnvironmentVariable($name, $null, 'Process'):
    # on PowerShell 7.6.4 / Windows the latter leaves an EMPTY-valued variable
    # behind (GetEnvironmentVariable -> '', Test-Path env: -> True, child
    # processes STILL inherit it) — observed empirically while writing this
    # twin's child-process test. An empty ANTHROPIC_BASE_URL is not a
    # neutralised one.
    $names = @([Environment]::GetEnvironmentVariables('Process').Keys)
    foreach ($name in $names) {
        $u = "$name".ToUpperInvariant()
        if ($u.StartsWith('ANTHROPIC_') -or $u.StartsWith('CLAUDE_CODE_USE_')) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction Stop
        }
    }
}

function NativeAuthPinScreenSettings {
    # $Payload = --settings value (inline JSON or a file path). Returns $true
    # when the payload is parseable/readable AND injects no canonical-set key
    # (case-insensitive); on refusal prints a REFUSED line to stderr and
    # returns $false. FAILS CLOSED: unparseable, unreadable, or empty payloads
    # refuse -- an unusable payload is not a passing one.
    param([string]$Payload)
    $raw = $null
    if ("$Payload".TrimStart().StartsWith('{')) {
        $raw = "$Payload"
    } elseif (Test-Path -LiteralPath $Payload -PathType Leaf) {
        try { $raw = Get-Content -LiteralPath $Payload -Raw -ErrorAction Stop } catch { $raw = $null }
    }
    if (-not $raw) {
        [Console]::Error.WriteLine('native-auth-pin: REFUSED - --settings payload is empty or unreadable (fails closed); an unusable payload might pull headless claude off native auth (HIMMEL-1867).')
        return $false
    }
    try {
        $j = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine('native-auth-pin: REFUSED - --settings payload is unparseable JSON (fails closed); it might pull headless claude off native auth (HIMMEL-1867).')
        return $false
    }
    if ($j -and $j.env) {
        foreach ($p in $j.env.PSObject.Properties) {
            $u = $p.Name.ToUpperInvariant()
            if ($u.StartsWith('ANTHROPIC_') -or $u.StartsWith('CLAUDE_CODE_USE_')) {
                [Console]::Error.WriteLine("native-auth-pin: REFUSED - --settings payload sets env.$($p.Name), which would pull headless claude off native auth (HIMMEL-1867).")
                return $false
            }
        }
    }
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($ClearEnv) { NativeAuthPinEnv; exit 0 }
    if ($PSBoundParameters.ContainsKey('ScreenPayload')) {
        if (NativeAuthPinScreenSettings $ScreenPayload) { exit 0 } else { exit 3 }
    }
    Write-Error 'usage: native-auth-pin.ps1 -ClearEnv | -ScreenPayload <inline json or file path>'
    exit 2
}
