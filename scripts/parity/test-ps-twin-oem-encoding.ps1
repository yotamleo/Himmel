# test-ps-twin-oem-encoding.ps1 -- the non-ASCII half of the HIMMEL-2256 guard.
#
# PowerShell decodes a CAPTURED native command's stdout using
# [Console]::OutputEncoding, which on a default Windows install is the legacy
# OEM codepage (cp437/cp850 here), not UTF-8. Every non-ASCII byte a native
# process writes is therefore mis-decoded the moment PowerShell captures it,
# and a twin that writes the captured text back out corrupts the file it was
# asked to edit. The one-line fix each affected twin carries:
#
#     [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
#
# WHY THIS SUITE EXISTS AT ALL. The HIMMEL-2250 leg shipped byte-parity tests
# that passed three CR rounds with this bug live, because every fixture was
# ASCII-only -- an ASCII fixture is a VACUOUS control for an encoding class: it
# cannot fail whether the fix is present or absent. So this file does not just
# assert the fixed twin behaves; it first proves, on this host, that the
# fixture CAN detect the bug -- by running an unfixed copy of the same twin and
# requiring it to CORRUPT. If the negative control does not corrupt, the
# positive case proves nothing and the suite says so instead of passing.
#
# The subject twin is scripts/lib/unwire-handover-dir.ps1: it pipes a whole
# settings.json through `jq` and writes the captured result back, so a
# mis-decode silently rewrites a real user's config. Its non-ASCII payload sits
# in env.LUNA_VAULT_PATH -- a key the twin must PRESERVE untouched, so the
# assertion is about data the script never means to modify at all.
#
# Usage: pwsh -File scripts/parity/test-ps-twin-oem-encoding.ps1
# Exit 0 = passed (or the host cannot host the control -- reported loudly);
#      1 = failed.
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO = Split-Path -Parent (Split-Path -Parent $HERE)
$TWIN = Join-Path $REPO 'scripts/lib/unwire-handover-dir.ps1'
$FIXLINE = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'

# Non-ASCII spanning three UTF-8 byte-lengths' worth of trouble: Latin-1
# accents (2-byte) and an em dash (3-byte). All three mis-decode differently
# under cp437, so a partial fix cannot squeak through.
$PAYLOAD = 'C:/Users/jose/Documents/naive/vault'
$PAYLOAD = $PAYLOAD -replace 'jose', "jos$([char]0xE9)" -replace 'naive', "na$([char]0xEF)ve" -replace 'vault', "vault $([char]0x2014) donn$([char]0xE9)es"

$failures = 0
function Fail($msg) { Write-Host "  FAIL  $msg"; $script:failures++ }
function Pass($msg) { Write-Host "  PASS  $msg" }

if (-not (Test-Path $TWIN)) {
    Write-Host "FAIL: subject twin not found: $TWIN"
    exit 1
}
if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Host "[SKIP] test-ps-twin-oem-encoding.ps1 -- jq not on PATH; the non-ASCII behavioural coverage for the HIMMEL-2256 encoding class did NOT run on this host."
    exit 0
}

# ---------------------------------------------------------------------------
# Force the legacy OEM decode. Without this the suite would only ever exercise
# the class on a host whose console already defaults to an OEM codepage --
# i.e. it would silently self-disable on the UTF-8 hosts where CI runs, which
# is the same never-executed blind spot the ASCII-only fixtures had.
# ---------------------------------------------------------------------------
$oem = $null
try {
    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
} catch { }   # already registered, or unavailable -- GetEncoding below decides
try { $oem = [System.Text.Encoding]::GetEncoding(437) } catch { $oem = $null }

$restore = [Console]::OutputEncoding
if ($null -eq $oem) {
    Write-Host "[SKIP] test-ps-twin-oem-encoding.ps1 -- codepage 437 is not available on this host, so the OEM mis-decode cannot be reproduced here and the fixture would be a vacuous control. The HIMMEL-2256 behavioural coverage did NOT run."
    exit 0
}

function New-Fixture {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("oemtwin-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $settings = Join-Path $dir 'settings.json'
    $obj = [pscustomobject]@{
        env = [pscustomobject]@{ HANDOVER_DIR = 'C:/handover'; LUNA_VAULT_PATH = $PAYLOAD }
    }
    # Write real UTF-8 bytes, no BOM -- exactly what a settings.json carries.
    [System.IO.File]::WriteAllText($settings, ($obj | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    return $settings
}

# Read the payload back as true UTF-8 bytes, never via the console, so the
# assertion measures the SCRIPT's decode and not this harness's.
function Get-VaultPath([string]$settings) {
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($settings))
    return ($text | ConvertFrom-Json).env.LUNA_VAULT_PATH
}

try {
    [Console]::OutputEncoding = $oem
    if ([Console]::OutputEncoding.CodePage -ne 437) {
        Write-Host "[SKIP] test-ps-twin-oem-encoding.ps1 -- this host refused the cp437 console encoding (still $([Console]::OutputEncoding.CodePage)), so the negative control cannot be established. The HIMMEL-2256 behavioural coverage did NOT run."
        exit 0
    }

    # -----------------------------------------------------------------------
    # Setting [Console]::OutputEncoding calls SetConsoleOutputCP, which is
    # console-wide -- a fresh child pwsh DOES inherit cp437 on this host
    # (measured), but that inheritance is not guaranteed on every host. Probe
    # a trivial child before trusting the negative control below: if the
    # child does not itself report 437, "did not corrupt" would be a spurious
    # FAIL rather than the real signal, so skip loudly instead.
    # -----------------------------------------------------------------------
    $childCp = "$(& pwsh -NoProfile -NonInteractive -Command '[Console]::OutputEncoding.CodePage')".Trim()
    if ($childCp -ne '437') {
        Write-Host "[SKIP] test-ps-twin-oem-encoding.ps1 -- a child pwsh process did not inherit the cp437 console encoding (reported '$childCp', not 437), so the negative control cannot be established on this host. The HIMMEL-2256 behavioural coverage did NOT run."
        exit 0
    }

    # -----------------------------------------------------------------------
    # Negative control FIRST: an unfixed copy of the same twin must corrupt.
    # This is the assertion that makes the positive case below mean anything.
    # -----------------------------------------------------------------------
    $unfixedDir = Join-Path ([System.IO.Path]::GetTempPath()) ("oemtwin-unfixed-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $unfixedDir | Out-Null
    $unfixed = Join-Path $unfixedDir 'unwire-handover-dir.ps1'
    $src = Get-Content $TWIN
    $stripped = @($src | Where-Object { $_.Trim() -ne $FIXLINE })
    if ($stripped.Count -eq $src.Count) {
        Fail "negative control could not be built: the fix line is absent from $TWIN, so there was nothing to strip (has the subject twin regressed, or was the line reworded?)"
    } else {
        Set-Content -LiteralPath $unfixed -Value $stripped -Encoding utf8
        $s = New-Fixture
        pwsh -NoProfile -NonInteractive -File $unfixed -SettingsPath $s | Out-Null
        $got = Get-VaultPath $s
        if ($got -eq $PAYLOAD) {
            Fail "negative control did NOT corrupt: the unfixed twin preserved the non-ASCII payload under cp437, so this fixture cannot detect the HIMMEL-2256 class and every other case here is vacuous."
        } else {
            Pass "negative control: the unfixed twin corrupts the non-ASCII payload under cp437 (fixture is not vacuous)"
        }
        Remove-Item -Recurse -Force (Split-Path -Parent $s)
    }
    Remove-Item -Recurse -Force $unfixedDir

    # -----------------------------------------------------------------------
    # The real twin, same host state, must round-trip the payload untouched.
    # -----------------------------------------------------------------------
    $s2 = New-Fixture
    pwsh -NoProfile -NonInteractive -File $TWIN -SettingsPath $s2 | Out-Null
    $got2 = Get-VaultPath $s2
    if ($got2 -ne $PAYLOAD) {
        Fail "the fixed twin corrupted the non-ASCII payload under cp437 (expected the value to survive untouched; got a differing string of length $($got2.Length) vs $($PAYLOAD.Length))"
    } else {
        Pass "fixed twin preserves a non-ASCII settings.json value across the jq capture under cp437"
    }
    # The edit it WAS asked to make must still have happened -- a twin that
    # preserves the payload by doing nothing at all would pass the case above.
    $stillThere = ([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($s2)) | ConvertFrom-Json).env.PSObject.Properties.Name -contains 'HANDOVER_DIR'
    if ($stillThere) {
        Fail "the twin left env.HANDOVER_DIR in place -- it did not perform its edit, so the preservation case above proves nothing"
    } else {
        Pass "the twin still performed its own edit (env.HANDOVER_DIR removed)"
    }
    Remove-Item -Recurse -Force (Split-Path -Parent $s2)
} finally {
    [Console]::OutputEncoding = $restore
}

if ($failures -eq 0) {
    Write-Host "OK: all cases passed"
    exit 0
}
Write-Host "FAIL: $failures case(s) failed"
exit 1
