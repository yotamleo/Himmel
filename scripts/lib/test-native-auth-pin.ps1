# test-native-auth-pin.ps1 -- committed PS test for native-auth-pin.ps1
# (HIMMEL-1867). Mirrors test-native-auth-pin.sh: neutralisation asserted on a
# CHILD pwsh process's environment (the environment a headless claude launch
# would inherit, never the parent's table), CLAUDE_CODE_OAUTH_TOKEN preserved,
# and the --settings screen refusing (exit 3 in script mode) on any-case
# canonical-key injection while failing closed on unparseable/unreadable
# payloads. Run: pwsh -NoProfile -File test-native-auth-pin.ps1 (or via the
# bash wrapper test-native-auth-pin-pwsh.sh from the suite runner).

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pin = Join-Path $here 'native-auth-pin.ps1'
$fails = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { Write-Host "ok - $name" }
    else { Write-Host "FAIL - ${name}: [$got]!=[$want]"; $script:fails++ }
}

# Child observer: a separate pwsh whose exit code says whether the named
# variable reached it. Asserting through the child is the point -- same rule as
# the bash suite.
function ChildHas([string]$name) {
    # The child is exit-code-only and prints nothing, so no output redirection
    # is needed (and a `2>&1` merge would turn native stderr into ErrorRecords
    # under $ErrorActionPreference = 'Stop').
    pwsh -NoProfile -Command "if (Test-Path env:$name) { exit 0 } else { exit 1 }"
    return ($LASTEXITCODE -eq 0)
}

# Snapshot + restore the process env we mutate (ANTHROPIC_* may be real in the
# invoking session; the pin must not leak its clears into the caller).
$watch = 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY',
         'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX',
         'CLAUDE_CODE_OAUTH_TOKEN', 'NATIVE_PIN_TEST_SENTINEL'
$orig = @{}
foreach ($n in $watch) { $orig[$n] = [Environment]::GetEnvironmentVariable($n) }

try {
    . $pin  # define NativeAuthPinEnv / NativeAuthPinScreenSettings

    # --- neutralisation: set AMBIENTLY, pin, observe in a CHILD pwsh ---------
    $env:ANTHROPIC_BASE_URL = 'http://proxy.local:8217'
    NativeAuthPinEnv
    Check 'P1 ANTHROPIC_BASE_URL absent in child after pin' (ChildHas 'ANTHROPIC_BASE_URL') $false

    $env:ANTHROPIC_AUTH_TOKEN = 'tok-secret'
    NativeAuthPinEnv
    Check 'P2 ANTHROPIC_AUTH_TOKEN absent in child after pin' (ChildHas 'ANTHROPIC_AUTH_TOKEN') $false

    $env:ANTHROPIC_API_KEY = 'sk-test'
    NativeAuthPinEnv
    Check 'P3 ANTHROPIC_API_KEY absent in child after pin' (ChildHas 'ANTHROPIC_API_KEY') $false

    $env:CLAUDE_CODE_USE_BEDROCK = '1'
    $env:CLAUDE_CODE_USE_VERTEX = '1'
    NativeAuthPinEnv
    Check 'P4 CLAUDE_CODE_USE_BEDROCK absent in child after pin' (ChildHas 'CLAUDE_CODE_USE_BEDROCK') $false
    Check 'P5 CLAUDE_CODE_USE_VERTEX absent in child after pin' (ChildHas 'CLAUDE_CODE_USE_VERTEX') $false

    # Guard against overreach: the native credential must survive the pin.
    $env:CLAUDE_CODE_OAUTH_TOKEN = 'oauth-test-token'
    $env:NATIVE_PIN_TEST_SENTINEL = 'keep'
    NativeAuthPinEnv
    Check 'P6 CLAUDE_CODE_OAUTH_TOKEN preserved in child after pin' (ChildHas 'CLAUDE_CODE_OAUTH_TOKEN') $true
    Check 'P7 bystander variable preserved in child after pin' (ChildHas 'NATIVE_PIN_TEST_SENTINEL') $true

    # --- --settings screen: script mode (-File) so refusal is an EXIT CODE (3)
    # exactly like the bash side's return, and stderr is capturable. ----------
    $td = Join-Path ([System.IO.Path]::GetTempPath()) ('nap-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $td | Out-Null
    $errfile = Join-Path $td 'err.txt'
    function RunScreen([string]$payload) {
        & pwsh -NoProfile -NonInteractive -File $pin -ScreenPayload $payload 2>$errfile
        return $LASTEXITCODE
    }
    $benign = '{"enabledPlugins":{"qmd@himmel":true}}'

    Check 'P8 benign inline payload passes (rc 0)' (RunScreen $benign) 0
    Check 'P9 injecting env.ANTHROPIC_* refuses (rc 3)' (RunScreen '{"env":{"ANTHROPIC_BASE_URL":"http://evil"}}') 3
    Check 'P9 refusal message on stderr' ((Get-Content -LiteralPath $errfile -Raw) -match 'REFUSED') $true
    Check 'P10 lower-case env.anthropic_* refuses (rc 3)' (RunScreen '{"env":{"anthropic_base_url":"http://evil"}}') 3
    Check 'P11 mixed-case env.Claude_Code_Use_* refuses (rc 3)' (RunScreen '{"env":{"Claude_Code_Use_Vertex":"1"}}') 3
    Check 'P12 env.CLAUDE_CODE_USE_* refuses (rc 3)' (RunScreen '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}') 3
    Check 'P13 unparseable payload fails closed (rc 3)' (RunScreen 'not json') 3
    # Non-zero (not exactly 3): Windows PowerShell 5.1 drops empty-string argv,
    # which routes to usage (rc 2) -- still fail-closed, still no false pass.
    Check 'P14 empty payload fails closed (non-zero rc)' ((RunScreen '') -ne 0) $true
    $evfile = Join-Path $td 'evil.json'
    $okfile = Join-Path $td 'ok.json'
    Set-Content -LiteralPath $evfile -Value '{"env":{"ANTHROPIC_AUTH_TOKEN":"tok"}}' -NoNewline
    Set-Content -LiteralPath $okfile -Value $benign -NoNewline
    Check 'P15 file-backed injecting payload refuses (rc 3)' (RunScreen $evfile) 3
    Check 'P16 benign file-backed payload passes (rc 0)' (RunScreen $okfile) 0
    Check 'P17 nonexistent path fails closed (rc 3)' (RunScreen (Join-Path $td 'nope.json')) 3
    Remove-Item -Recurse -Force $td
} finally {
    foreach ($n in $watch) {
        # Restore exactly what was there before: Remove-Item for the
        # originally-absent (SetEnvironmentVariable with $null would leave an
        # EMPTY-valued variable behind — the very distinction this suite
        # exists to enforce), a plain set otherwise.
        if ($null -eq $orig[$n]) {
            if (Test-Path "env:$n") { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
        } else {
            [Environment]::SetEnvironmentVariable($n, $orig[$n], 'Process')
        }
    }
}
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILED"; exit 1 }
