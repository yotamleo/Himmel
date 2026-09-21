# provenance.ps1 -- the install-provenance ledger writer, PowerShell dialect
# (HIMMEL-3332 S1). DOT-SOURCE it:  . "$PSScriptRoot/lib/provenance.ps1"
# Twins: scripts/lib/provenance.sh (bash) and scripts/himmelctl/lib/provenance.js
# (node) write BYTE-IDENTICAL rows; this file mirrors the bash key order, string
# escaping (`jq -c`: DEL -> \u007f, control chars \u00xx lowercase) and hashing.
# Format, kinds, write points: docs/internals/install-provenance.md.
#
#   Prov-Begin  -Writer adopt.ps1 -Argv $args         # opens a session, sets $env:HIMMEL_PROVENANCE_IID
#   ... the writer does its atomic write ...
#   Prov-Record replace file $dest -PreFile $snapshot -Backup -PostFile $dest `
#       -Scope project -Class code -Row adopter-scripts
#   Prov-End ok
#
# Prov-Record flags mirror the bash ones: -Unit -Scope -Class -Row -Writer,
# -Field ([ordered]@{ key = '<JSON>' }, insertion order is the row order),
# -PreAbsent | -PreFile | -PreJson | -PreText, -PostFile | -PostJson | -PostText,
# -Backup, -DryRun (also $env:DRY_RUN = '1': prints "DRY: record <op> <kind> <path>",
# writes nothing). Path '-' means none (registrations). Call AFTER the writer's
# atomic write; -PreFile names a file holding the PRE bytes (the writer's own
# snapshot), never the already-overwritten destination. A failure THROWS
# "provenance: <why>"; the caller decides whether that is fatal.
#
# ponytail: this dialect could NOT be executed where it was written (no pwsh on
# the authoring host); it is verified by parity-by-construction plus the
# pwsh-gated block in scripts/lib/test-provenance.sh, which SKIPs (named) when
# pwsh is absent. Known deliberate differences from bash/node:
#   * mode: file modes come from GetUnixFileMode (.NET 7+); on Windows the "mode"
#     key is OMITTED from pre/post (bash on Git Bash would report an emulated one).
#   * parent-chain path resolution is Resolve-Path only: symlinked parents and
#     8.3 short names are not resolved (bash resolves them with pwd -P/cygpath).
#   * no jq on PATH: canonicalisation falls back to ConvertFrom-Json + a sorted
#     re-serialiser, which diverges from `jq -cS` on non-canonical number literals
#     (1.0, 1E+2, integers past 2^63) and non-BMP key order.

$script:ProvOps = @('create', 'replace', 'insert', 'append', 'register', 'link', 'noop')
$script:ProvKinds = @('file', 'tree', 'json-key', 'json-elem', 'block', 'line', 'plugin', 'marketplace',
    'job', 'unit', 'shim', 'symlink', 'git-hook', 'mcp', 'collection', 'tool')
$script:ProvScopes = @('user', 'project', 'clone', 'machine')
$script:ProvClasses = @('code', 'state', 'keep')
$script:ProvReserved = @('t', 'iid', 'op', 'kind', 'path', 'unit', 'scope', 'class', 'pre', 'post', 'writer', 'manifest_row')
$script:ProvUtf8 = [System.Text.UTF8Encoding]::new($false)
$script:ProvOwns = $null
$script:ProvIsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$script:ProvRoot = ((Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath) -replace '\\', '/'

function _ProvFail([string]$Msg) { throw "provenance: $Msg" }

# ── encoding: exactly what `jq -c` emits ────────────────────────────────
function _ProvStr([string]$s) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -eq 8) { [void]$sb.Append('\b') }
        elseif ($c -eq 9) { [void]$sb.Append('\t') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 12) { [void]$sb.Append('\f') }
        elseif ($c -eq 13) { [void]$sb.Append('\r') }
        elseif ($c -lt 32 -or $c -eq 127) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function _ProvStrOrNull([string]$s) { if ($s) { return (_ProvStr $s) } else { return 'null' } }
function _ProvObj($pairs) {
    $parts = @()
    foreach ($p in $pairs) { $parts += ((_ProvStr $p[0]) + ':' + $p[1]) }
    return '{' + ($parts -join ',') + '}'
}

function _ProvSorted($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [string]) { return (_ProvStr $v) }
    if ($v -is [System.Array]) {
        $items = @()
        foreach ($e in $v) { $items += (_ProvSorted $e) }
        return '[' + ($items -join ',') + ']'
    }
    if ($v -is [System.Management.Automation.PSCustomObject]) {
        $names = [string[]]@($v.PSObject.Properties | ForEach-Object { $_.Name })
        [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
        $items = @()
        foreach ($n in $names) { $items += ((_ProvStr $n) + ':' + (_ProvSorted $v.PSObject.Properties[$n].Value)) }
        return '{' + ($items -join ',') + '}'
    }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0}', $v)
}

# `jq -cS` of a JSON text, no trailing newline; $null when it is not valid JSON.
function _ProvJqCanon([string]$Text) {
    $jq = Get-Command jq -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($jq) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($jq.Source)
        $psi.Arguments = '-cS .'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:ProvUtf8
        $p = [System.Diagnostics.Process]::Start($psi)
        $bytes = $script:ProvUtf8.GetBytes($Text)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        [void]$p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { return $null }
        # CRLF-safe (jq.exe on Windows may end lines with \r\n); one JSON document only:
        # jq -c prints a line per document ('1 2' -> two lines), so more than one line is refused
        $out = $out.TrimEnd([char]13, [char]10)
        if ($out -eq '' -or $out.Contains("`n")) { return $null }
        return $out
    }
    try { return (_ProvSorted (ConvertFrom-Json -InputObject $Text)) } catch { return $null }
}
function _ProvCanonOrThrow([string]$Text) {
    $c = _ProvJqCanon $Text
    if ($null -eq $c) { _ProvFail "not valid JSON: $Text" }
    return $c
}

function _ProvShaBytes([byte[]]$Bytes) {
    $h = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($h.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $h.Dispose() }
}
function _ProvShaText([string]$s) { return (_ProvShaBytes $script:ProvUtf8.GetBytes($s)) }
function _ProvShaFile([string]$f) { return (_ProvShaBytes ([System.IO.File]::ReadAllBytes($f))) }

# ── paths ───────────────────────────────────────────────────────────────
function _ProvCanonPartial([string]$p) {
    if (-not $p) { _ProvFail 'cannot resolve an empty path' }
    $p = $p -replace '\\', '/'
    $rest = ''
    while (-not (Test-Path -LiteralPath $p -PathType Container)) {
        $i = $p.LastIndexOf('/')
        if ($i -lt 0) { _ProvFail "cannot resolve $p" }
        $rest = $p.Substring($i) + $rest
        $p = $p.Substring(0, $i)
        if (-not $p) { $p = '/' }
    }
    $real = ((Resolve-Path -LiteralPath $p).ProviderPath) -replace '\\', '/'
    return $real.TrimEnd('/') + $rest
}
function _ProvAbs([string]$p) {
    $p = $p -replace '\\', '/'
    if (-not ($p.StartsWith('/') -or $p -match '^[A-Za-z]:/')) { $p = ((Get-Location).ProviderPath -replace '\\', '/') + '/' + $p }
    while ($p.Length -gt 1 -and $p.EndsWith('/')) { $p = $p.Substring(0, $p.Length - 1) }
    $i = $p.LastIndexOf('/')
    $base = $p.Substring($i + 1)
    $dir = $p.Substring(0, $i)
    if (-not $dir) { $dir = '/' }
    $dir = _ProvCanonPartial $dir
    if ($base -eq '') { return $dir }
    return $dir.TrimEnd('/') + '/' + $base
}

function Get-ProvLedgerDir {
    $d = $env:HIMMEL_PROVENANCE_DIR
    if (-not $d) {
        if (-not $HOME) { _ProvFail 'HOME is unset and HIMMEL_PROVENANCE_DIR is not given' }
        $d = ($HOME -replace '\\', '/') + '/.himmel'
    }
    return (_ProvCanonPartial $d)
}
function Get-ProvLedgerPath { return ((Get-ProvLedgerDir) + '/provenance.jsonl') }

# ── misc ────────────────────────────────────────────────────────────────
function _ProvNow {
    if ($env:HIMMEL_PROVENANCE_NOW) { return $env:HIMMEL_PROVENANCE_NOW }
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}
function _ProvNewIid {
    $b = New-Object 'byte[]' 3
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    return $stamp + '-' + (([System.BitConverter]::ToString($b) -replace '-', '').ToLowerInvariant())
}
function _ProvIsDry { return ($env:DRY_RUN -eq '1') }
function _ProvPlatform {
    if ($script:ProvIsWin) { return 'win32' }
    if ($PSVersionTable.PSEdition -eq 'Core' -and $IsMacOS) { return 'darwin' }
    return 'linux'
}
# four-digit octal of the unix mode, or $null where there is none (Windows).
function _ProvMode([string]$f) {
    if ($script:ProvIsWin) { return $null }
    $m = [int][System.IO.File]::GetUnixFileMode($f)
    return ([Convert]::ToString($m, 8)).PadLeft(4, '0')
}
function _ProvSetMode([string]$f, [int]$octalValue) {
    if (-not $script:ProvIsWin) { [System.IO.File]::SetUnixFileMode($f, [System.IO.UnixFileMode]$octalValue) }
}

function _ProvAppend([string]$Line) {
    $dir = Get-ProvLedgerDir
    $file = $dir + '/provenance.jsonl'
    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
            if (-not $script:ProvIsWin) { [System.IO.File]::SetUnixFileMode($dir, [System.IO.UnixFileMode]0x1C0) }
        }
        $torn = $false
        $isNew = -not (Test-Path -LiteralPath $file -PathType Leaf)
        if (-not $isNew) {
            $fi = [System.IO.FileInfo]::new($file)
            if ($fi.Length -gt 0) {
                $fs = [System.IO.File]::OpenRead($file)
                try { [void]$fs.Seek(-1, [System.IO.SeekOrigin]::End); $torn = ($fs.ReadByte() -ne 10) } finally { $fs.Dispose() }
            }
        }
        $bytes = $script:ProvUtf8.GetBytes($(if ($torn) { "`n" } else { '' }) + $Line + "`n")
        $out = [System.IO.File]::Open($file, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { $out.Write($bytes, 0, $bytes.Length) } finally { $out.Dispose() }
        if ($isNew) { _ProvSetMode $file 0x180 }
    }
    catch { _ProvFail "cannot append to ${file}: $($_.Exception.Message)" }
}

# ── rows ────────────────────────────────────────────────────────────────
function _ProvBeginRow([string]$Iid, [string]$Writer, [string]$Target, [string]$Root, [string[]]$Argv) {
    $head = ''
    $g = & git -C $Root rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $g) { $head = ([string]$g).Trim() }
    $version = ''
    $vf = Join-Path $Root 'VERSION'
    if (Test-Path -LiteralPath $vf -PathType Leaf) { $version = (Get-Content -LiteralPath $vf -Raw) -replace '[ \r\n]', '' }
    $home_ = $HOME -replace '\\', '/'
    try { $home_ = ((Resolve-Path -LiteralPath $HOME).ProviderPath) -replace '\\', '/' } catch { }
    $cfgRaw = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { $home_ + '/.claude' }
    $cfg = $cfgRaw
    try { $cfg = _ProvCanonPartial $cfgRaw } catch { }
    $argvJson = '[' + ((@($Argv) | ForEach-Object { _ProvStr $_ }) -join ',') + ']'
    return (_ProvObj @(
            @('t', (_ProvStr (_ProvNow))), @('iid', (_ProvStr $Iid)), @('op', (_ProvStr 'install-begin')),
            @('himmel_root', (_ProvStr $Root)), @('himmel_head', (_ProvStrOrNull $head)), @('version', (_ProvStrOrNull $version)),
            @('argv', $argvJson), @('home', (_ProvStr $home_)), @('claude_config_dir', (_ProvStr $cfg)),
            @('target', (_ProvStrOrNull $Target)), @('platform', (_ProvStr (_ProvPlatform))), @('writer', (_ProvStrOrNull $Writer))))
}
function _ProvEndRow([string]$Iid, [string]$Status, [string]$Step) {
    return (_ProvObj @(
            @('t', (_ProvStr (_ProvNow))), @('iid', (_ProvStr $Iid)), @('op', (_ProvStr 'install-end')),
            @('status', (_ProvStr $Status)), @('failed_step', (_ProvStrOrNull $Step))))
}

# ── sessions ────────────────────────────────────────────────────────────
function Prov-Begin {
    param([string]$Writer = '', [string]$Target = '', [string]$Root = '', [string]$Iid = '', [string[]]$Argv = @(), [switch]$DryRun)
    if ($DryRun -or (_ProvIsDry)) { return }
    if (-not $Root) { $Root = $script:ProvRoot }
    if (-not $Iid) {
        if ($env:HIMMEL_PROVENANCE_IID) { return }
        $Iid = _ProvNewIid
    }
    if ($Target) { try { $Target = _ProvAbs $Target } catch { } }
    _ProvAppend (_ProvBeginRow $Iid $Writer $Target $Root $Argv)
    $env:HIMMEL_PROVENANCE_IID = $Iid
    $script:ProvOwns = $Iid
}

# Closes the session THIS process opened; a no-op for a child that only inherited the id.
function Prov-End {
    param([Parameter(Mandatory, Position = 0)][string]$Status, [Parameter(Position = 1)][string]$FailedStep = '')
    if (@('ok', 'failed', 'partial') -notcontains $Status) { _ProvFail 'prov_end: status must be ok|failed|partial' }
    if (_ProvIsDry) { return }
    $iid = $env:HIMMEL_PROVENANCE_IID
    if (-not $iid -or $script:ProvOwns -ne $iid) { return }
    _ProvAppend (_ProvEndRow $iid $Status $FailedStep)
    # close ownership only once the end row is on disk, so a failed append can be retried
    $env:HIMMEL_PROVENANCE_IID = $null
    $script:ProvOwns = $null
}

# ── artifact rows ───────────────────────────────────────────────────────
function _ProvBody([string]$Kind, [string]$Type, [string]$Val) {
    if ($Type -eq 'file') {
        if (-not (Test-Path -LiteralPath $Val -PathType Leaf)) { _ProvFail "not a file: $Val" }
        $pairs = @(@('sha', (_ProvStr (_ProvShaFile $Val))), @('size', ([string]([System.IO.FileInfo]::new($Val).Length))))
        $mode = _ProvMode $Val
        if ($mode) { $pairs += , @('mode', (_ProvStr $mode)) }
        return (_ProvObj $pairs)
    }
    if ($Type -eq 'text') { return (_ProvObj @(, @('sha', (_ProvStr (_ProvShaText $Val))))) }
    $c = _ProvCanonOrThrow $Val
    if ($Kind -eq 'json-key' -or $Kind -eq 'json-elem') { return (_ProvObj @(, @('sha', (_ProvStr (_ProvShaText $c))))) }
    return (_ProvObj @(, @('value', $c)))
}

function _ProvBackup([string]$Iid, [string]$UPath, [string]$Type, [string]$Val) {
    $bdir = (Get-ProvLedgerDir) + '/provenance-backups/' + $Iid
    try {
        if (-not (Test-Path -LiteralPath $bdir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($bdir)
            if (-not $script:ProvIsWin) { [System.IO.File]::SetUnixFileMode($bdir, [System.IO.UnixFileMode]0x1C0) }
        }
        $n = @(Get-ChildItem -LiteralPath $bdir -Force).Count + 1
        while ($true) {
            $name = ([string]$n).PadLeft(3, '0') + '-' + $UPath.Substring($UPath.LastIndexOf('/') + 1)
            if ($Type -eq 'json') { $name += '.prior.json' } elseif ($Type -eq 'text') { $name += '.prior.txt' }
            $dest = $bdir + '/' + $name
            # reserve the name atomically (CreateNew = O_EXCL) so two writers sharing an
            # iid cannot both pick the same sequence number
            try { [System.IO.File]::Open($dest, [System.IO.FileMode]::CreateNew).Dispose(); break }
            catch [System.IO.IOException] { if (-not (Test-Path -LiteralPath $dest)) { throw } }
            $n++
        }
        if ($Type -eq 'file') {
            [System.IO.File]::Copy($Val, $dest, $true)
            if (-not $script:ProvIsWin) { [System.IO.File]::SetUnixFileMode($dest, [System.IO.File]::GetUnixFileMode($Val)) }
        }
        else {
            $data = if ($Type -eq 'json') { _ProvCanonOrThrow $Val } else { $Val }
            [System.IO.File]::WriteAllBytes($dest, $script:ProvUtf8.GetBytes($data))
            _ProvSetMode $dest 0x180
        }
        return $dest
    }
    catch {
        if ($_.Exception.Message -like 'provenance:*') { throw }
        _ProvFail "cannot write backup in ${bdir}: $($_.Exception.Message)"
    }
}

function Prov-Record {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Op,
        [Parameter(Mandatory, Position = 1)][string]$Kind,
        [Parameter(Mandatory, Position = 2)][string]$Path,
        [string]$Unit = '', [string]$Scope = '', [string]$Class = '', [string]$Row = '', [string]$Writer = '',
        [System.Collections.IDictionary]$Field,
        [switch]$PreAbsent, [string]$PreFile, [string]$PreJson, [string]$PreText,
        [string]$PostFile, [string]$PostJson, [string]$PostText,
        [switch]$Backup, [switch]$DryRun
    )
    if ($script:ProvOps -notcontains $Op) { _ProvFail "prov_record: unknown op '$Op'" }
    if ($script:ProvKinds -notcontains $Kind) { _ProvFail "prov_record: unknown kind '$Kind'" }
    if ($Scope -and $script:ProvScopes -notcontains $Scope) { _ProvFail "prov_record: bad scope '$Scope'" }
    if ($Class -and $script:ProvClasses -notcontains $Class) { _ProvFail "prov_record: bad class '$Class'" }

    $fields = [ordered]@{}
    if ($Field) {
        foreach ($k in $Field.Keys) {
            if ($k -cnotmatch '^[a-z_][a-z0-9_]*$') { _ProvFail "prov_record: bad field key '$k'" }
            if ($script:ProvReserved -contains $k) { _ProvFail "prov_record: field key '$k' is reserved" }
            $c = _ProvJqCanon ([string]$Field[$k])
            if ($null -eq $c) { _ProvFail "prov_record: --field $k is not valid JSON" }
            $fields[$k] = $c
        }
    }

    $preT = ''; $preV = ''
    $bound = $PSBoundParameters
    if ($PreAbsent) { $preT = 'absent' }
    if ($bound.ContainsKey('PreFile')) { $preT = 'file'; $preV = $PreFile }
    if ($bound.ContainsKey('PreJson')) { $preT = 'json'; $preV = $PreJson }
    if ($bound.ContainsKey('PreText')) { $preT = 'text'; $preV = $PreText }
    $postT = ''; $postV = ''
    if ($bound.ContainsKey('PostFile')) { $postT = 'file'; $postV = $PostFile }
    if ($bound.ContainsKey('PostJson')) { $postT = 'json'; $postV = $PostJson }
    if ($bound.ContainsKey('PostText')) { $postT = 'text'; $postV = $PostText }
    if ($Backup -and @('file', 'json', 'text') -notcontains $preT) {
        _ProvFail 'prov_record: --backup needs -PreFile, -PreJson or -PreText'
    }
    if ($DryRun -or (_ProvIsDry)) { Write-Output "DRY: record $Op $Kind $Path"; return }

    $iid = $env:HIMMEL_PROVENANCE_IID
    $implicit = (-not $iid)
    if ($implicit) { $iid = _ProvNewIid }
    $cpath = ''
    if ($Path -ne '-' -and $Path -ne '') { $cpath = _ProvAbs $Path }

    $pre = $null
    if ($preT -eq 'absent') { $pre = '{"state":"absent"}' }
    elseif ($preT) {
        $b = _ProvBody $Kind $preT $preV
        $bk = 'null'
        if ($Backup) {
            $bpath = if ($cpath) { $cpath } elseif ($Unit) { $Unit } else { 'unit' }
            $bk = _ProvStr (_ProvBackup $iid $bpath $preT $preV)
        }
        $pre = '{"state":"present",' + $b.Substring(1, $b.Length - 2) + ',"backup":' + $bk + '}'
    }
    $post = $null
    if ($postT) { $post = _ProvBody $Kind $postT $postV }

    $pairs = @(@('t', (_ProvStr (_ProvNow))), @('iid', (_ProvStr $iid)), @('op', (_ProvStr $Op)), @('kind', (_ProvStr $Kind)))
    if ($cpath) { $pairs += , @('path', (_ProvStr $cpath)) }
    if ($Unit) { $pairs += , @('unit', (_ProvStr $Unit)) }
    if ($Scope) { $pairs += , @('scope', (_ProvStr $Scope)) }
    if ($Class) { $pairs += , @('class', (_ProvStr $Class)) }
    foreach ($k in $fields.Keys) { $pairs += , @($k, $fields[$k]) }
    if ($null -ne $pre) { $pairs += , @('pre', $pre) }
    if ($null -ne $post) { $pairs += , @('post', $post) }
    if ($Writer) { $pairs += , @('writer', (_ProvStr $Writer)) }
    if ($Row) { $pairs += , @('manifest_row', (_ProvStr $Row)) }

    if ($implicit) { _ProvAppend (_ProvBeginRow $iid $Writer '' $script:ProvRoot @()) }
    _ProvAppend (_ProvObj $pairs)
    if ($implicit) { _ProvAppend (_ProvEndRow $iid 'ok' '') }
}
