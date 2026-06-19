# end-session-wiki.ps1 — Claude Code SessionEnd hook (Windows / PowerShell)
#
# Epic #7 — end-session-wiki-hook, tasks #26 (vault-write-integration) +
# #27 (opt-out-and-failure-handling).
#
# Reads SessionEnd JSON payload from stdin, gathers session metadata + a
# verbatim slice of the transcript, renders a Markdown note matching the
# schema in docs/luna/end-session-wiki-schema.md, and PUTs it into the
# Luna Obsidian vault via the Local REST API.
#
# Operational controls (#27): see docs/luna/end-session-wiki.md
#   - Env opt-out:  CLAUDE_END_SESSION_WIKI=0 (or "false") skips silently.
#   - Repo config:  $CLAUDE_PROJECT_DIR/.claude/end-session-wiki.json
#                   { enabled, dry_run, min_duration_seconds }
#   - Dry-run:      renders note to log file instead of vault HTTP PUT.
#   - Min duration: sessions shorter than min_duration_seconds are skipped.
#   - Error isol.:  entire body wrapped in try/catch; on any failure the hook
#                   logs the exception + stack and EXITS 0.
#   - Log:          $CLAUDE_PROJECT_DIR/.claude/end-session-wiki.log
#                   Rotates to .log.old at 1 MB.
#
# Failure policy (#27): hook MUST NEVER exit non-zero. See epic success
# criterion #5.

# Platform guard: this hook is the Windows variant. On non-Windows the
# companion end-session-wiki.sh runs instead. Both are registered in
# .claude/settings.json because Claude Code's `shell` field is an
# interpreter spec, not a platform filter — without this guard both
# would fire on the same platform and the second write would overwrite
# the first (silent vault inconsistency, see PR #56 review).
# Note: on Windows PowerShell 5.1, $IsWindows does not exist but 5.1 only
# ships on Windows so it falls through correctly. The PSEdition='Core'
# branch only skips when running PS7+ on Linux/macOS.
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    exit 0
}

# ---------- Bootstrap log path + rotation (must work even if body throws) ----

$projectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
$logDir     = Join-Path $projectDir '.claude'
$logPath    = Join-Path $logDir 'end-session-wiki.log'
$logOldPath = Join-Path $logDir 'end-session-wiki.log.old'
$configPath = Join-Path $logDir 'end-session-wiki.json'

function Write-HookLog {
    param([string]$Message)
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        # Rotate at 1 MB
        if (Test-Path $logPath) {
            $size = (Get-Item $logPath).Length
            if ($size -gt 1048576) {
                Move-Item -LiteralPath $logPath -Destination $logOldPath -Force
            }
        }
        $stamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        Add-Content -LiteralPath $logPath -Value "[$stamp] $Message"
    } catch {
        # Last-resort: swallow. Hook must never block.
    }
}

function Write-NoteToFile {
    # Local-filesystem fallback used when the Obsidian Local REST API is
    # unavailable (no API key, or the PUT failed). Obsidian picks up on-disk
    # changes automatically, so a direct write produces the same note without
    # depending on the plugin being running.
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # UTF-8 without BOM, matching the REST API write.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

try {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    # ---------- Opt-out: env var -------------------------------------------------
    $envOptOut = $env:CLAUDE_END_SESSION_WIKI
    if ($envOptOut) {
        $envLower = $envOptOut.ToLowerInvariant()
        if ($envLower -eq '0' -or $envLower -eq 'false') {
            Write-HookLog "skipped: env opt-out (CLAUDE_END_SESSION_WIKI=$envOptOut)"
            exit 0
        }
    }

    # ---------- Repo-local config -----------------------------------------------
    $cfgEnabled = $true
    $cfgDryRun  = $false
    $cfgMinDur  = 60
    # vault_path / vault are read by Resolve-VaultRoot (scripts/lib/vault-resolve.ps1),
    # not here, so this parse stays focused on the gate fields.
    if (Test-Path $configPath) {
        try {
            $cfgRaw = Get-Content -LiteralPath $configPath -Raw
            $cfg    = $cfgRaw | ConvertFrom-Json
            if ($cfg.PSObject.Properties['enabled']) { $cfgEnabled = [bool]$cfg.enabled }
            if ($cfg.PSObject.Properties['dry_run']) { $cfgDryRun  = [bool]$cfg.dry_run }
            if ($cfg.PSObject.Properties['min_duration_seconds']) { $cfgMinDur = [int]$cfg.min_duration_seconds }
        } catch {
            Write-HookLog "config parse failed (using defaults): $($_.Exception.Message)"
        }
    }

    if (-not $cfgEnabled) {
        Write-HookLog "skipped: config disabled"
        exit 0
    }

    # ---------- 1. Read SessionEnd payload from stdin -----------------------------

    $payloadJson = [Console]::In.ReadToEnd()
    if (-not $payloadJson -or $payloadJson.Trim().Length -eq 0) {
        Write-HookLog "ERROR: empty stdin payload"
        exit 0
    }

    try {
        $payload = $payloadJson | ConvertFrom-Json
    } catch {
        Write-HookLog "ERROR: invalid JSON on stdin: $($_.Exception.Message)"
        exit 0
    }

    $transcriptPath = $payload.transcript_path
    $sessionCwd     = $payload.cwd
    $sessionId      = $payload.session_id
    $reason         = if ($payload.PSObject.Properties['reason']) { $payload.reason } else { 'other' }

    if (-not $sessionCwd) {
        Write-HookLog "ERROR: payload missing 'cwd'"
        exit 0
    }

    # ---------- 2. Gather git / fs metadata ---------------------------------------

    function Invoke-Git {
        # NOTE: parameter must not be named $Args — shadows the automatic variable.
        param([string[]]$GitArgs, [string]$WorkDir = $sessionCwd)
        $out = & git -C $WorkDir @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($out -join "`n").Trim()
    }

    $repoToplevel = Invoke-Git -GitArgs @('rev-parse', '--show-toplevel')
    if (-not $repoToplevel) { $repoToplevel = $sessionCwd }

    # repo name = git remote origin basename (no .git), fallback to cwd basename
    $remoteUrl = Invoke-Git -GitArgs @('remote', 'get-url', 'origin')
    if ($remoteUrl) {
        $repoName = [System.IO.Path]::GetFileNameWithoutExtension(($remoteUrl -split '[/\\]')[-1])
    } else {
        $repoName = Split-Path $sessionCwd -Leaf
    }
    if (-not $repoName) { $repoName = 'unknown-repo' }

    $branch = Invoke-Git -GitArgs @('branch', '--show-current')
    if (-not $branch) { $branch = 'detached' }

    # files_touched: prefer HEAD..worktree (committed since branch base would need
    # merge-base detection; schema asks for HEAD@{session-start}..HEAD which we
    # don't track. Use uncommitted+staged as a pragmatic stand-in.)
    $filesDiffRaw = Invoke-Git -GitArgs @('diff', '--name-only', 'HEAD')
    # Force array — single-result pipelines collapse to scalar in PS, and an empty
    # pipeline yields $null. Strict mode rejects .Count on either.
    $filesList = @()
    if ($filesDiffRaw) {
        $filesList = @($filesDiffRaw -split "`n" | Where-Object { $_ -and $_.Trim() })
    }
    $filesCount = $filesList.Count

    # ---------- 3. Read transcript: timestamps + last assistant turn + commands ---

    $firstTs   = $null
    $lastAssistantText = ''
    $bashCommands = New-Object System.Collections.Generic.List[string]
    $transcriptReadable = $true

    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        try {
            $lines = Get-Content -LiteralPath $transcriptPath -ErrorAction Stop
            foreach ($line in $lines) {
                if (-not $line) { continue }
                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction Stop
                } catch { continue }

                if (-not $firstTs -and $obj.PSObject.Properties['timestamp']) {
                    $firstTs = $obj.timestamp
                }

                # Capture last assistant turn raw text. Two shapes observed: top-level
                # role+content OR nested message.role/message.content (Claude Code variant).
                $role    = $null
                $content = $null
                if ($obj.PSObject.Properties['role'])    { $role    = $obj.role }
                if ($obj.PSObject.Properties['content']) { $content = $obj.content }
                if (-not $role -and $obj.PSObject.Properties['message']) {
                    if ($obj.message -and $obj.message.PSObject.Properties['role'])    { $role    = $obj.message.role }
                    if ($obj.message -and $obj.message.PSObject.Properties['content']) { $content = $obj.message.content }
                }

                if ($role -eq 'assistant' -and $content) {
                    $turnText = New-Object System.Text.StringBuilder
                    if ($content -is [string]) {
                        [void]$turnText.Append($content)
                    } else {
                        foreach ($block in $content) {
                            if ($block -and $block.PSObject.Properties['type'] -and $block.type -eq 'text' -and $block.PSObject.Properties['text']) {
                                [void]$turnText.AppendLine($block.text)
                            }
                            if ($block -and $block.PSObject.Properties['type'] -and $block.type -eq 'tool_use' -and $block.PSObject.Properties['name'] -and ($block.name -eq 'Bash' -or $block.name -eq 'PowerShell')) {
                                if ($block.PSObject.Properties['input'] -and $block.input -and $block.input.PSObject.Properties['command']) {
                                    $cmd = [string]$block.input.command
                                    if ($cmd) { $bashCommands.Add($cmd) }
                                }
                            }
                        }
                    }
                    $candidate = $turnText.ToString().Trim()
                    if ($candidate) { $lastAssistantText = $candidate }
                }
            }
        } catch {
            $transcriptReadable = $false
        }
    } else {
        $transcriptReadable = $false
    }

    # duration_seconds + duration_minutes
    $nowUtc = [DateTime]::UtcNow
    $durationSeconds = 0
    $durationMinutes = 0
    if ($firstTs) {
        try {
            $start = [DateTimeOffset]::Parse($firstTs).UtcDateTime
            $deltaSec = ($nowUtc - $start).TotalSeconds
            if ($deltaSec -lt 0) { $deltaSec = 0 }
            $durationSeconds = [int][Math]::Round($deltaSec)
            # Match bash: integer (DELTA + 30) / 60 — round half-up to whole minutes.
            $durationMinutes = [int][Math]::Floor(($deltaSec + 30) / 60)
            if ($durationMinutes -lt 0) { $durationMinutes = 0 }
        } catch {
            $durationSeconds = 0
            $durationMinutes = 0
        }
    }

    # Min-duration skip (only when we have a transcript timestamp; otherwise we
    # can't compute duration and the cautious choice is to capture rather than drop).
    if ($firstTs -and $durationSeconds -lt $cfgMinDur) {
        Write-HookLog "skipped: duration ${durationSeconds}s < min ${cfgMinDur}s"
        exit 0
    }

    # Filter trivial bash commands
    $trivialPattern = '^(ls|cd|pwd|echo)(\s|$)'
    $keptCommands = @($bashCommands | Where-Object { $_ -notmatch $trivialPattern } | Select-Object -Last 20)

    # ---------- 4. Compute path -------------------------------------------------

    function Get-Slug {
        param([string]$Text)
        $s = $Text.ToLowerInvariant()
        $s = [Regex]::Replace($s, '[^a-z0-9]+', '-')
        $s = $s.Trim('-')
        return $s
    }

    $rawSlug = Get-Slug -Text "$repoName-$branch"
    # Schema §1 slug max 80 chars, leave room for collision suffix later
    $slugBudget = 80
    if ($rawSlug.Length -gt $slugBudget) {
        $cut = $rawSlug.Substring(0, $slugBudget)
        $lastDash = $cut.LastIndexOf('-')
        if ($lastDash -gt 0) { $rawSlug = $cut.Substring(0, $lastDash) } else { $rawSlug = $cut }
    }

    $dateStr = $nowUtc.ToString('yyyy-MM-dd')
    $hhmm    = $nowUtc.ToString('HHmm')
    $year    = $nowUtc.ToString('yyyy')
    $month   = $nowUtc.ToString('MM')

    # Vault root: resolved by scripts/lib/vault-resolve.ps1 (HIMMEL-403), the
    # PowerShell twin of vault-resolve.sh. Precedence: config.vault_path >
    # validated config.vault NAME (operator registry ~/.claude/luna-vaults.json
    # -> <USERPROFILE>\Documents\<name> w/ .obsidian marker) > LUNA_VAULT_PATH >
    # default luna. Empty result => declared-but-unresolved => skip (fail-closed).
    . (Join-Path $PSScriptRoot '..\lib\vault-resolve.ps1')
    $vaultRoot = Resolve-VaultRoot -ConfigPath $configPath `
        -RegistryPath (Join-Path $env:USERPROFILE '.claude\luna-vaults.json') -DryRun $cfgDryRun
    if (-not $vaultRoot) {
        Write-HookLog "skipped: vault unresolved (invalid name / no real vault / unparseable config) — no write"
        exit 0
    }
    # Expand a leading ~/ or ~\ (registry values / config can't rely on tilde expansion).
    if ($vaultRoot -match '^~[\\/](.*)$') { $vaultRoot = Join-Path $env:USERPROFILE $matches[1] }

    $relDir = "sessions/$year/$month"
    $baseName = "$dateStr-$hhmm-$rawSlug"
    $relPath  = "$relDir/$baseName.md"

    # Collision suffix (skipped in dry-run since we don't actually write to vault)
    if (-not $cfgDryRun) {
        $absDir = Join-Path $vaultRoot ($relDir -replace '/', '\')
        $absPath = Join-Path $absDir "$baseName.md"
        $suffix = 2
        while (Test-Path $absPath) {
            $suffixStr = "-$suffix"
            $maxSlug = 80 - $suffixStr.Length
            $slugForCollision = $rawSlug
            if (($slugForCollision.Length) -gt $maxSlug) {
                $cut = $slugForCollision.Substring(0, $maxSlug)
                $lastDash = $cut.LastIndexOf('-')
                if ($lastDash -gt 0) { $slugForCollision = $cut.Substring(0, $lastDash) } else { $slugForCollision = $cut }
            }
            $baseName = "$dateStr-$hhmm-$slugForCollision$suffixStr"
            $relPath  = "$relDir/$baseName.md"
            $absPath  = Join-Path $absDir "$baseName.md"
            $suffix++
            if ($suffix -gt 100) { break }  # paranoia
        }
    }

    # ---------- 5. Render markdown ----------------------------------------------

    $dateIso = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")

    # Summary: first 4 non-empty lines of last assistant turn, or fallback
    $summaryLines = @()
    if ($lastAssistantText) {
        $summaryLines = @($lastAssistantText -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 4)
    }
    if ($summaryLines.Count -eq 0) {
        $summary = "_Transcript unavailable; auto-summary not generated._ (speculation)"
    } else {
        $summary = ($summaryLines -join "`n").Trim()
    }

    # For-future-Claude preamble (schema §3.1)
    $preamble = "Auto-captured Claude Code session in repo [[$repoName]] on branch ``$branch``. Filed by the end-session-wiki hook (epic #7 / task #26)."

    # Files Touched section
    $filesSection = ""
    if ($filesCount -eq 0) {
        $filesSection = "_None._"
    } else {
        $shown = @($filesList | Select-Object -First 50)
        $filesSection = (($shown | ForEach-Object { "- ``$_``" }) -join "`n")
        if ($filesCount -gt 50) {
            $filesSection += "`n- _+$($filesCount - 50) more (use git log to inspect)_"
        }
    }

    # Commands section
    $cmdsSection = "``````bash`n"
    if ($keptCommands.Count -gt 0) {
        $cmdsSection += ($keptCommands -join "`n") + "`n"
    }
    $cmdsSection += "``````"

    # Raw conversation callout
    if ($transcriptReadable -and $lastAssistantText) {
        $rawBody = ($lastAssistantText -split "`n" | ForEach-Object { "> $_" }) -join "`n"
        $rawSection = "> [!note]- Raw conversation`n$rawBody"
    } else {
        $rawSection = "> [!note]- Raw conversation`n> _Transcript unavailable._"
    }

    $worktreeAbs = ($sessionCwd -replace '/', '\')

    $markdown = @"
---
date: $dateIso
type: session
repo: $repoName
branch: $branch
worktree: $worktreeAbs
duration_minutes: $durationMinutes
files_touched: $filesCount
tags:
  - session
  - autocapture
ai-first: true
---

$preamble

## Summary

$summary

## Decisions

_None._

## Files Touched

$filesSection

## Commands

$cmdsSection

## Follow-ups

_None._

## Raw Conversation

$rawSection
"@

    # ---------- 6. Dry-run short-circuit ----------------------------------------

    if ($cfgDryRun) {
        $sep = "=" * 78
        $renderedLen = $markdown.Length
        # Log the summary first (this is also where rotation fires). Then append
        # the rendered note directly so a single dry-run can't push the log to
        # ~2x the cap before the next invocation notices.
        Write-HookLog "dry_run: rendered $renderedLen chars (path=$relPath)"
        try {
            if (-not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            Add-Content -LiteralPath $logPath -Value "$sep"
            Add-Content -LiteralPath $logPath -Value "DRY-RUN RENDERED NOTE  path=$relPath  bytes=$renderedLen"
            Add-Content -LiteralPath $logPath -Value "$sep"
            Add-Content -LiteralPath $logPath -Value $markdown
            Add-Content -LiteralPath $logPath -Value "$sep"
        } catch {
            # fall through to top-level catch
            throw
        }
        exit 0
    }

    # ---------- 7. Discover Obsidian Local REST API key + PUT --------------------

    # Token discovery priority:
    #   1. $env:OBSIDIAN_API_KEY (matches mcp-obsidian convention)
    #   2. <vault>/.obsidian/plugins/obsidian-local-rest-api/data.json -> .apiKey
    #      (canonical plugin storage location)
    $apiKey = $env:OBSIDIAN_API_KEY
    if (-not $apiKey) {
        $pluginData = Join-Path $vaultRoot '.obsidian\plugins\obsidian-local-rest-api\data.json'
        if (Test-Path $pluginData) {
            try {
                $cfgPlugin = Get-Content -LiteralPath $pluginData -Raw | ConvertFrom-Json
                if ($cfgPlugin.PSObject.Properties['apiKey']) { $apiKey = $cfgPlugin.apiKey }
            } catch {
                Write-HookLog "WARN: failed to parse $pluginData : $($_.Exception.Message)"
            }
        }
    }
    if (-not $apiKey) {
        # No REST API key — fall back to a direct on-disk write into the vault.
        try {
            Write-NoteToFile -Path $absPath -Content $markdown
            Write-HookLog "wrote (local fs, no api key) $relPath"
        } catch {
            Write-HookLog "ERROR: local fs write failed ($absPath): $($_.Exception.Message)"
        }
        exit 0
    }

    $baseUrl = $env:OBSIDIAN_API_URL
    if (-not $baseUrl) { $baseUrl = 'https://127.0.0.1:27124' }

    # URL-encode each path segment (preserve / separators)
    $encodedRel = ($relPath -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $endpoint = "$baseUrl/vault/$encodedRel"

    $headers = @{
        'Authorization' = "Bearer $apiKey"
        'Content-Type'  = 'text/markdown'
    }

    # The Local REST API plugin uses a self-signed cert by default — skip cert
    # validation. Security note: this is loopback only (127.0.0.1) so MITM risk is
    # limited to local-user processes (which already have full FS access anyway).
    $irmArgs = @{
        Uri     = $endpoint
        Method  = 'Put'
        Headers = $headers
        Body    = $markdown
    }
    if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
        $irmArgs['SkipCertificateCheck'] = $true
    } else {
        # PowerShell 5.1 fallback: globally bypass cert validation for this process
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }

    $startTime = Get-Date
    try {
        Invoke-RestMethod @irmArgs | Out-Null
    } catch {
        # REST PUT failed (e.g. Obsidian not running) — fall back to on-disk write.
        Write-HookLog "WARN: PUT $endpoint failed ($($_.Exception.Message)); falling back to local fs"
        try {
            Write-NoteToFile -Path $absPath -Content $markdown
            Write-HookLog "wrote (local fs fallback) $relPath"
        } catch {
            Write-HookLog "ERROR: local fs fallback write failed ($absPath): $($_.Exception.Message)"
        }
        exit 0
    }
    $elapsed = ((Get-Date) - $startTime).TotalMilliseconds

    Write-HookLog "wrote $relPath (${elapsed}ms)"
    exit 0

} catch {
    # Outer error isolation — any unhandled exception in body lands here.
    Write-HookLog "FAILED with exception: $($_.Exception.Message)`nStack: $($_.ScriptStackTrace)"
    exit 0
}
