<#
  vault-autosync.ps1 — OPT-IN auto-commit + push for a luna-brain vault.
  Lockstep with vault-autosync.sh.

  OFF by default. A vault's content IS the product, so when enabled this stages
  everything (`git add -A`) and commits THROUGH pre-commit — NEVER --no-verify —
  so the vault's gitleaks + secret hooks BLOCK any commit containing an API key
  BEFORE it can be committed or pushed. .gitignore (.env, .single-writer, …) is
  the second layer. Push targets the configured remote only.

  Enable explicitly (never defaulted on):
    $env:LUNA_VAULT_AUTOSYNC = '1'; pwsh -File scripts\vault-autosync.ps1

  Behaviour:
    OFF             → no commit, no push, no network.
    ON  + no remote → logged no-op.
    ON  + remote    → git add -A; commit (through pre-commit); push.
#>
param(
    [switch] $Sweep,
    [string] $VaultPath           = '',
    [string] $ExpectedOriginUrl   = '',
    [string] $GitExe              = 'C:\Program Files\Git\cmd\git.exe',
    [string] $GitBinDir           = 'C:\Program Files\Git\bin',
    [string] $GhExe               = 'C:\Program Files\GitHub CLI\gh.exe',
    [string] $ObsidianProcessName = 'obsidian',
    [int]    $FreshWriteSeconds   = 30,
    [int]    $PullSkipAlarmAfter  = 12,
    [string] $StateDir            = ''
)

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Defaults resolved here, not as param() default expressions (LUNA-131 D2):
# a scheduled task's CWD is system32, so vault resolution must go through
# $PSScriptRoot, never CWD.
if (-not $VaultPath) { $VaultPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $StateDir) { $StateDir = Join-Path $env:USERPROFILE '.himmel\luna-sync' }

function Log($m) { Write-Host "[vault-autosync] $m" }

# =====================================================================
# LUNA-131 -Sweep path — headless vault sweeper. Everything from here down
# to the gate-dispatch line is NEW (pure addition). The legacy
# LUNA_VAULT_AUTOSYNC body that follows the dispatch line is byte-unchanged.
# =====================================================================

function Get-SweepNowIso {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Add-SweepLogLine {
    param([string]$StateDir, [string]$Line)
    $logPath = Join-Path $StateDir 'sync.log'
    if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -ge 1MB)) {
        Move-Item -Force $logPath (Join-Path $StateDir 'sync.log.old')
    }
    Add-Content -Path $logPath -Value $Line
}

function Write-SweepStatus {
    param([string]$StateDir, $Status)
    $path = Join-Path $StateDir 'status.json'
    $tmp = "$path.tmp"
    ($Status | ConvertTo-Json -Depth 5) | Set-Content -NoNewline -Path $tmp
    Move-Item -Force $tmp $path
}

function Read-SweepStatus {
    param([string]$StateDir)
    $default = [ordered]@{
        schema = 1; ts = $null; last_clean_ts = $null; head = $null
        ahead_origin = 0; behind_origin = 0
        consecutive_pull_skips = 0; consecutive_push_failures = 0
        alarm_class = $null; last_alarm_ts = $null
    }
    $path = Join-Path $StateDir 'status.json'
    if (Test-Path $path) {
        try {
            $raw = Get-Content -Raw $path | ConvertFrom-Json
            foreach ($k in @($default.Keys)) {
                if ($raw.PSObject.Properties.Name -contains $k) { $default[$k] = $raw.$k }
            }
        } catch { }
    }
    return $default
}

function Get-SweepAheadBehind {
    param([string]$GitExe, [string]$VaultPath)
    $raw = & $GitExe -C $VaultPath rev-list --count --left-right 'HEAD...origin/main' 2>$null
    if ($LASTEXITCODE -ne 0) {
        $aheadOnly = (& $GitExe -C $VaultPath rev-list --count HEAD 2>$null)
        return @{ Ahead = [int]("$aheadOnly".Trim()); Behind = 0 }
    }
    $parts = @(("$raw" -split '\s+') | Where-Object { $_ -ne '' })
    return @{ Ahead = [int]$parts[0]; Behind = [int]$parts[1] }
}

function Normalize-SweepRemoteUrl($u) {
    # CR (codex-2, pr-check pass): NOT case-folded — this feeds two security
    # comparisons (wrong-remote against -ExpectedOriginUrl, and origin==
    # template-remote). Lowercasing the whole URL made two distinct
    # case-sensitive repo paths (most git hosts, especially over SSH, treat
    # the path as case-sensitive) compare EQUAL, so a genuinely-wrong remote
    # that happened to differ only by case would sail through the check it
    # exists to catch. Trim/trailing-slash/.git-suffix normalization stays;
    # case does not.
    $x = $u.Trim().TrimEnd('/')
    if ($x.EndsWith('.git')) { $x = $x.Substring(0, $x.Length - 4) }
    return $x
}

# ConvertFrom-Json auto-parses ISO-8601-looking strings into [datetime]
# (observed on pwsh 7.6), so a value read back from owner.json/status.json
# may already be a [datetime] rather than the string it was written as.
# Normalize either shape to a single UTC [datetime] before comparing —
# comparing a re-formatted [datetime] against a raw 'o'-format string via
# -eq/-ne is format-sensitive and silently wrong.
function ConvertTo-SweepUtcDateTime($val) {
    if ($val -is [datetime]) { return $val.ToUniversalTime() }
    return ([datetime]::Parse([string]$val, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
}

# --- 1.1 single-instance lock (D12) ---
#
# CR round 3 (codex-1): the earlier create-then-write-owner.json design had a
# real TOCTOU window — a contender could see the lock DIRECTORY exist with no
# owner.json yet (the legitimate holder just hasn't written it) and treat
# that as abandoned, steal it, and both ends up believing they hold the lock.
# Fixed by making PUBLISH atomic instead of racing the write: build the fully
# -formed lock (owner.json already inside) in a uniquely-named temp dir, then
# publish it with a single directory rename. A rename onto an existing path
# fails outright — no process can ever observe a half-built lock directory,
# and stealing (renaming an existing, stale lock OUT of the way) is the same
# single atomic primitive, so at most one contender's rename wins.
function Enter-SweepLock {
    param([string]$StateDir)
    $lockDir = Join-Path $StateDir 'tick.lock'
    $ownerPath = Join-Path $lockDir 'owner.json'

    $tmpDir = Join-Path $StateDir ("tick.lock.tmp." + $PID + "." + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $self = Get-Process -Id $PID
    $owner = @{
        pid               = $PID
        process_start_utc = $self.StartTime.ToUniversalTime().ToString('o')
        acquired_utc      = (Get-Date).ToUniversalTime().ToString('o')
    }
    ($owner | ConvertTo-Json) | Set-Content -Path (Join-Path $tmpDir 'owner.json')

    # [System.IO.Directory]::Move, NOT Move-Item: PowerShell's Move-Item nests
    # the source INSIDE an existing destination directory instead of failing
    # — the opposite of the fail-if-exists rename semantics this lock design
    # depends on. Directory.Move throws IOException when $To already exists,
    # which is exactly the atomic "did I win the race" signal needed here.
    function Publish-SweepLock([string]$From, [string]$To) {
        try { [System.IO.Directory]::Move($From, $To); return $true } catch { return $false }
    }

    $acquired = Publish-SweepLock -From $tmpDir -To $lockDir

    if (-not $acquired) {
        $steal = $false
        if (Test-Path $ownerPath) {
            $prevOwner = $null
            try { $prevOwner = Get-Content -Raw $ownerPath | ConvertFrom-Json } catch { $prevOwner = $null }
            if ($prevOwner) {
                $proc = Get-Process -Id $prevOwner.pid -ErrorAction SilentlyContinue
                if (-not $proc) {
                    $steal = $true
                } elseif ($proc.StartTime.ToUniversalTime() -ne (ConvertTo-SweepUtcDateTime $prevOwner.process_start_utc)) {
                    $steal = $true
                } else {
                    # CR (codex-1, round 5): the heartbeat before the pull half
                    # covers most of a tick, but a single pull that itself runs
                    # past 10 min would still leave a VERIFIABLY-alive holder
                    # (matching pid + StartTime) stealable. Two different
                    # questions get two different thresholds instead of one:
                    # a dead/restarted pid (above) is stolen immediately — no
                    # grace needed, nothing is running. A pid that is alive AND
                    # matches means real, distinguishable evidence of liveness
                    # (not just an unrefreshed timestamp), so it gets a much
                    # longer ceiling before being presumed wedged.
                    $acq = ConvertTo-SweepUtcDateTime $prevOwner.acquired_utc
                    if (((Get-Date).ToUniversalTime() - $acq).TotalMinutes -ge 60) { $steal = $true }
                }
            } else {
                $steal = $true
            }
        } else {
            # Lock dir exists but owner.json is missing. With the atomic
            # publish above this can now ONLY mean a genuinely orphaned
            # directory from an old pre-this-fix build, or a crash between
            # rename and process exit — never an in-flight competitor (their
            # owner.json is always already inside before their rename lands).
            $steal = $true
        }
        if ($steal) {
            $deadDir = Join-Path $StateDir ("tick.lock.dead." + [System.Guid]::NewGuid().ToString('N'))
            if (Publish-SweepLock -From $lockDir -To $deadDir) {
                Remove-Item -Recurse -Force $deadDir -ErrorAction SilentlyContinue
                $acquired = Publish-SweepLock -From $tmpDir -To $lockDir
            }
            # A failed steal-rename means another contender already moved
            # $lockDir out from under us (or a live holder republished it) —
            # back off rather than retry, this tick's race is already lost.
        }
    }

    if (-not $acquired) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        return @{ Acquired = $false }
    }
    return @{ Acquired = $true }
}

# CR (codex-2, round 4): the steal threshold was pure wall-clock age since
# acquisition, with no distinction between a stuck holder and one still
# legitimately mid-tick (a slow network pull can run past 10 min on its
# own). Called mid-tick before the network-bound pull half so an actively
# progressing holder keeps refreshing its own acquired_utc and is never
# mistaken for abandoned; only a holder that stops calling this (crashed,
# hung) goes stale.
function Update-SweepLockHeartbeat {
    param([string]$StateDir)
    $ownerPath = Join-Path $StateDir 'tick.lock\owner.json'
    if (-not (Test-Path $ownerPath)) { return }
    $owner = $null
    try { $owner = Get-Content -Raw $ownerPath -ErrorAction Stop | ConvertFrom-Json } catch { $owner = $null }
    if (-not $owner -or [int]$owner.pid -ne $PID) { return }
    # Round-trip process_start_utc through ConvertTo-SweepUtcDateTime + 'o'
    # explicitly — ConvertFrom-Json may have already auto-parsed it into a
    # [datetime], and re-stringifying that with default ToString() (instead
    # of 'o') would silently corrupt the format future reads expect.
    $updated = @{
        pid               = $PID
        process_start_utc = (ConvertTo-SweepUtcDateTime $owner.process_start_utc).ToString('o')
        acquired_utc      = (Get-Date).ToUniversalTime().ToString('o')
    }
    # CR (codex-2, round 5): write-then-atomically-replace, same idiom as
    # Write-SweepStatus — an in-place Set-Content overwrite lets a concurrent
    # reader observe a truncated/partial owner.json mid-write and misread a
    # live lock as ownerless.
    $tmp = "$ownerPath.tmp"
    ($updated | ConvertTo-Json) | Set-Content -NoNewline -Path $tmp
    Move-Item -Force $tmp $ownerPath
}

function Exit-SweepLock {
    param([string]$StateDir)
    # CR (codex-3): a live lock can be STOLEN out from under a stuck holder
    # (owner unresponsive >=10 min). If the original holder later reaches
    # here, an unconditional delete would remove the NEW owner's lock and
    # let two sweepers run concurrently. Only remove the dir if it still
    # records US as owner.
    $lockDir = Join-Path $StateDir 'tick.lock'
    $ownerPath = Join-Path $lockDir 'owner.json'
    $owner = $null
    try { $owner = Get-Content -Raw $ownerPath -ErrorAction Stop | ConvertFrom-Json } catch { $owner = $null }
    if ($owner -and [int]$owner.pid -ne $PID) { return }
    Remove-Item -Recurse -Force $lockDir -ErrorAction SilentlyContinue
}

# --- 1.2 environment pinning (D11) ---
function Set-SweepEnvironment {
    param([string]$GitBinDir, [string]$StateDir)
    $env:PATH = "$GitBinDir;$($env:PATH)"
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_ASKPASS = ''
    $env:SSH_ASKPASS = ''
    if (-not $env:HOME) { $env:HOME = $env:USERPROFILE }

    # Diagnostic only (LUNA-131 S18 test seam): record which `bash` the
    # pinned PATH resolves to, so the suite can assert the pin displaced a
    # decoy that preceded $GitBinDir on the starting PATH. This can't be
    # observed by dot-sourcing this file instead — the legacy env-gated body
    # below calls `exit`, which would terminate a dot-sourcing host.
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    try {
        Set-Content -NoNewline -Path (Join-Path $StateDir 'path-probe.txt') -Value $(if ($bashCmd) { $bashCmd.Source } else { 'NONE' })
    } catch { }

    return (Test-Path (Join-Path $GitBinDir 'sh.exe'))
}

# --- 1.3 sanity gate ---
function Test-SweepSanity {
    param([string]$GitExe, [string]$VaultPath, [string]$ExpectedOriginUrl)

    $branch = & $GitExe -C $VaultPath rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or "$branch".Trim() -ne 'main') {
        return @{ Ok = $false; SkipReason = 'not-main' }
    }

    # CR (codex-3, round 5): every prior check here was NEGATIVE (reject a
    # known-bad shape) with no POSITIVE proof this is actually a luna vault —
    # a misconfigured $VaultPath pointing at any other main-branch repo with
    # an origin (and no ExpectedOriginUrl pin, which is opt-in) would sail
    # through to auto-commit/push. .vault-template.json with
    # template=="luna-second-brain" is the one file every luna vault carries
    # and no other repo would.
    $identityPath = Join-Path $VaultPath '.vault-template.json'
    $identity = $null
    if (Test-Path $identityPath) {
        try { $identity = Get-Content -Raw $identityPath | ConvertFrom-Json } catch { $identity = $null }
    }
    if (-not $identity -or "$($identity.template)" -ne 'luna-second-brain') {
        return @{ Ok = $false; SkipReason = 'not-a-vault' }
    }

    $originUrl = & $GitExe -C $VaultPath remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $originUrl) {
        return @{ Ok = $false; SkipReason = 'no-origin' }
    }
    $originUrl = "$originUrl".Trim()

    $templateUrl = & $GitExe -C $VaultPath remote get-url template 2>$null
    if ($LASTEXITCODE -eq 0 -and $templateUrl -and ((Normalize-SweepRemoteUrl $originUrl) -eq (Normalize-SweepRemoteUrl "$templateUrl".Trim()))) {
        return @{ Ok = $false; AlarmClass = 'wrong-remote' }
    }
    if ($ExpectedOriginUrl -and ((Normalize-SweepRemoteUrl $originUrl) -ne (Normalize-SweepRemoteUrl $ExpectedOriginUrl))) {
        return @{ Ok = $false; AlarmClass = 'wrong-remote' }
    }

    $pluginsPath = Join-Path $VaultPath '.obsidian\community-plugins.json'
    if (Test-Path $pluginsPath) {
        $plugins = $null
        try { $plugins = @(Get-Content -Raw $pluginsPath | ConvertFrom-Json) } catch { $plugins = $null }
        # CR (codex-2): a parse FAILURE must not silently read as "empty plugin
        # list" — that fails OPEN and would let a malformed file mask
        # github-sync being re-enabled. Fail closed instead: cannot verify.
        if ($null -eq $plugins) {
            return @{ Ok = $false; AlarmClass = 'plugin-check-failed' }
        }
        if ($plugins -contains 'github-sync') {
            return @{ Ok = $false; AlarmClass = 'plugin-resurrected' }
        }
    }

    & $GitExe -C $VaultPath diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        return @{ Ok = $false; SkipReason = 'foreign-staging' }
    }

    # CR (codex-3): provision .single-writer only once every check above has
    # PASSED — creating it earlier (e.g. before the remote/plugin checks)
    # would permanently opt a mistakenly-selected repo (wrong remote, github
    # -sync still enabled) out of edit-on-main protection even though this
    # same sanity gate is about to reject it.
    $marker = Join-Path $VaultPath '.single-writer'
    if (-not (Test-Path $marker)) { New-Item -ItemType File -Path $marker | Out-Null }

    return @{ Ok = $true }
}

# git index.lock contention retry (LUNA-131 1.1 "separately"): 3 attempts,
# 5 s backoff, distinct from the tick lock (which serializes the sweeper
# only against itself).
function Invoke-SweepGitCommit {
    param([string]$GitExe, [string]$VaultPath, [string]$MsgFile)
    $attempt = 0
    while ($true) {
        $errFile = [System.IO.Path]::GetTempFileName()
        & $GitExe -C $VaultPath commit -q -F $MsgFile 2> $errFile
        $rc = $LASTEXITCODE
        $err = Get-Content -Raw $errFile -ErrorAction SilentlyContinue
        Remove-Item -Force $errFile -ErrorAction SilentlyContinue
        if ($rc -eq 0) { return $true }
        if ("$err" -notmatch 'index\.lock' -or $attempt -ge 2) { return $false }
        $attempt++
        Start-Sleep -Seconds 5
    }
}

# --- 1.4 step 3: commit half ---
function Invoke-SweepCommitHalf {
    param([string]$GitExe, [string]$VaultPath, [int]$FreshWriteSeconds)

    # --untracked-files=all: without it, git collapses a wholly-new directory
    # into one "?? dir/" record instead of one record per file inside it,
    # which would make the freshness scan below check the DIRECTORY's mtime
    # (touched by the file creation moments ago) instead of each file's own.
    $raw = & $GitExe -C $VaultPath status --porcelain -z --untracked-files=all
    if (-not $raw) { return @{ Result = 'nothing-to-commit' } }

    # Freshness scan is scoped to git's own candidate set (status --porcelain
    # -z) ONLY, never a filesystem walk. `git fetch` (ordered-tick step 2)
    # writes inside .git/ on every tick, so a raw walk would always see a
    # sub-30s mtime and this half would never run (LUNA-131 S6c regression
    # pin).
    $records = @("$raw" -split "`0" | Where-Object { $_ -ne '' })
    $paths = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $records.Count) {
        $rec = $records[$i]
        $code = $rec.Substring(0, 2)
        $path = $rec.Substring(3)
        $paths.Add($path)
        if ($code[0] -eq 'R' -or $code[0] -eq 'C' -or $code[1] -eq 'R' -or $code[1] -eq 'C') { $i += 2 } else { $i += 1 }
    }

    $now = Get-Date
    foreach ($p in $paths) {
        $full = Join-Path $VaultPath $p
        if (Test-Path $full) {
            $age = ($now - (Get-Item $full).LastWriteTime).TotalSeconds
            if ($age -lt $FreshWriteSeconds) { return @{ Result = 'fresh-writes' } }
        }
    }

    & $GitExe -C $VaultPath add -A
    $staged = @((& $GitExe -C $VaultPath diff --cached --name-only) -split "`n" | Where-Object { $_ -ne '' })
    if ($staged.Count -eq 0) { return @{ Result = 'nothing-to-commit' } }

    # CR (codex-1, round 6): the scan above and `add -A` are not atomic — a
    # file created/modified in that gap would be staged mid-write. This does
    # not close the race (nothing short of a filesystem lock fully does), but
    # re-checking the now-STAGED set's ages right before committing shrinks
    # the window to the few remaining lines of this function instead of the
    # whole scan-then-add sequence.
    $now2 = Get-Date
    foreach ($p in $staged) {
        $full = Join-Path $VaultPath $p
        if (Test-Path $full) {
            $age = ($now2 - (Get-Item $full).LastWriteTime).TotalSeconds
            if ($age -lt $FreshWriteSeconds) {
                & $GitExe -C $VaultPath restore --staged -- $staged
                return @{ Result = 'fresh-writes' }
            }
        }
    }

    $msgFile = [System.IO.Path]::GetTempFileName()
    Set-Content -NoNewline -Path $msgFile -Value "chore: vault autosync`n`nauto-sync: $(Get-SweepNowIso)`nagent: luna-131-sweeper`n"
    $ok = Invoke-SweepGitCommit -GitExe $GitExe -VaultPath $VaultPath -MsgFile $msgFile
    if (-not $ok) {
        # HIMMEL-501: an auto-fixer may have modified a staged file and
        # aborted the commit — re-stage and retry once.
        & $GitExe -C $VaultPath add -A
        # CR (codex-3, pr-check pass): the retry's own add -A can pick up a
        # newly-created/modified file the first freshness scan never saw —
        # re-run the SAME staged-set re-check the first attempt already gets
        # (above) before retrying the commit, not just before the first one.
        $retryStaged = @((& $GitExe -C $VaultPath diff --cached --name-only) -split "`n" | Where-Object { $_ -ne '' })
        $now3 = Get-Date
        $retryFresh = $false
        foreach ($p in $retryStaged) {
            $full = Join-Path $VaultPath $p
            if ((Test-Path $full) -and (($now3 - (Get-Item $full).LastWriteTime).TotalSeconds -lt $FreshWriteSeconds)) {
                $retryFresh = $true
                break
            }
        }
        if ($retryFresh) {
            & $GitExe -C $VaultPath restore --staged -- $retryStaged
            Remove-Item -Force $msgFile -ErrorAction SilentlyContinue
            return @{ Result = 'fresh-writes' }
        }
        $staged = $retryStaged
        $ok = Invoke-SweepGitCommit -GitExe $GitExe -VaultPath $VaultPath -MsgFile $msgFile
    }
    Remove-Item -Force $msgFile -ErrorAction SilentlyContinue

    if ($ok) { return @{ Result = 'committed' } }

    # Second failure (D7): unstage ONLY this tick's own paths — never a
    # blanket reset, since the lock doesn't serialize against a human
    # session or pre-commit's own stash path (HIMMEL-834).
    & $GitExe -C $VaultPath restore --staged -- $staged
    return @{ Result = 'commit-blocked' }
}

# --- 1.4 step 4: pull half ---
function Invoke-SweepPullHalf {
    param([string]$GitExe, [string]$VaultPath, [string]$ObsidianProcessName, [int]$Behind)

    if (Get-Process -Name $ObsidianProcessName -ErrorAction SilentlyContinue) {
        return @{ Result = 'obsidian-open' }
    }
    if ($Behind -eq 0) { return @{ Result = 'up-to-date' } }

    # Pre-merge-refusal pre-check: `git pull` refuses to start when a file in
    # the incoming diff is locally modified (neither union-mergeable nor
    # --abort-able), so detect the overlap before attempting it.
    $localMod = @((& $GitExe -C $VaultPath diff --name-only) -split "`n" | Where-Object { $_ -ne '' })
    $incoming = @((& $GitExe -C $VaultPath diff --name-only 'HEAD' 'origin/main') -split "`n" | Where-Object { $_ -ne '' })
    if (($localMod | Where-Object { $incoming -contains $_ }).Count -gt 0) {
        return @{ Result = 'merge-would-overwrite' }
    }

    # origin/main explicit: the sanity gate already requires origin+main, and
    # this doesn't depend on branch.main.merge tracking config being set.
    & $GitExe -C $VaultPath pull --no-rebase --no-edit origin main 2>$null
    if ($LASTEXITCODE -eq 0) { return @{ Result = 'pulled' } }

    & $GitExe -C $VaultPath merge --abort 2>$null
    return @{ Result = 'merge-conflict' }
}

# =====================================================================
# D17 REGION — auth-failure handling, kept deliberately self-contained.
# The spec default (D17) is ALARM-ONLY: no sticky auth-blocked marker file.
# A stateless 10-min task cannot reliably tell an auth-dead remote from a
# network blip, so retries continue every tick — consecutive_push_failures
# + alarm_class=auth (surfaced via status.json) carry the whole signal.
# D17 carries an OUTSTANDING operator veto window. If it flips to a sticky
# marker, THIS FUNCTION is the only place that changes: add a marker-file
# write in the $isAuth branch below, plus a check for that marker earlier
# in Invoke-Sweep (before the push attempt).
# --- 1.4 step 5: push half ---
function Invoke-SweepPushHalf {
    param([string]$GitExe, [string]$VaultPath, [int]$Ahead)

    if ($Ahead -eq 0) { return @{ Result = 'nothing-to-push' } }

    $errFile = [System.IO.Path]::GetTempFileName()
    & $GitExe -C $VaultPath push origin main 2> $errFile
    $ok = ($LASTEXITCODE -eq 0)
    $errText = Get-Content -Raw $errFile -ErrorAction SilentlyContinue
    Remove-Item -Force $errFile -ErrorAction SilentlyContinue

    if ($ok) { return @{ Result = 'pushed' } }

    # CR (codex-2, round 6): common SSH-remote auth failures weren't matched,
    # so an SSH vault fell through to generic push-failed instead of the
    # immediately-RED auth alarm class.
    $isAuth = "$errText" -match 'could not read Username|Authentication failed|403|terminal prompts disabled|Permission denied \(publickey\)|Could not read from remote repository'
    if ($isAuth) { return @{ Result = 'push-failed'; AlarmClass = 'auth' } }
    return @{ Result = 'push-failed'; AlarmClass = 'push-failed' }
}
# ============================ end D17 region ==========================

# --- ordered tick orchestrator (1.4) ---
function Invoke-Sweep {
    $tickStartIso = Get-SweepNowIso
    $t0 = Get-Date

    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

    # 0. pin environment FIRST, inside the sweep path only.
    $envOk = Set-SweepEnvironment -GitBinDir $GitBinDir -StateDir $StateDir
    if (-not $envOk) {
        Add-SweepLogLine -StateDir $StateDir -Line "$(Get-SweepNowIso) tick_start=$tickStartIso dur_ms=$([int]((Get-Date) - $t0).TotalMilliseconds) commit=n/a pull=n/a push=n/a ahead=0 behind=0 skip=n/a alarm=env"
        return
    }

    # 1.1 single-instance lock
    $lock = Enter-SweepLock -StateDir $StateDir
    if (-not $lock.Acquired) {
        Add-SweepLogLine -StateDir $StateDir -Line "$(Get-SweepNowIso) tick_start=$tickStartIso dur_ms=$([int]((Get-Date) - $t0).TotalMilliseconds) commit=n/a pull=n/a push=n/a ahead=0 behind=0 skip=locked alarm=null"
        return
    }

    try {
        $status = Read-SweepStatus -StateDir $StateDir

        # 1.3 sanity gate
        $sanity = Test-SweepSanity -GitExe $GitExe -VaultPath $VaultPath -ExpectedOriginUrl $ExpectedOriginUrl
        if (-not $sanity.Ok) {
            $nowIso = Get-SweepNowIso
            Add-SweepLogLine -StateDir $StateDir -Line "$nowIso tick_start=$tickStartIso dur_ms=$([int]((Get-Date) - $t0).TotalMilliseconds) commit=n/a pull=n/a push=n/a ahead=0 behind=0 skip=$($sanity.SkipReason) alarm=$($sanity.AlarmClass)"
            $status.ts = $nowIso
            $status.alarm_class = $sanity.AlarmClass
            if ($sanity.AlarmClass) { $status.last_alarm_ts = $nowIso }
            Write-SweepStatus -StateDir $StateDir -Status $status
            return
        }

        # 2. fetch, unconditionally, every tick (D5) — before any divergence math.
        # CR: a failed fetch (auth/network outage) must not be treated as "no
        # remote changes" — the ahead/behind math below would run against
        # stale refs and a silently-stranded vault could still be marked
        # last_clean_ts (codex-1). Recorded as fetchFailed and folded into
        # alarmClass so it blocks the clean-tick reset below.
        & $GitExe -C $VaultPath fetch origin 2>$null
        $fetchFailed = ($LASTEXITCODE -ne 0)

        $ab0 = Get-SweepAheadBehind -GitExe $GitExe -VaultPath $VaultPath
        $behind = $ab0.Behind

        # 3. commit half
        $commitRes = Invoke-SweepCommitHalf -GitExe $GitExe -VaultPath $VaultPath -FreshWriteSeconds $FreshWriteSeconds
        $skipReason = $null
        $alarmClass = $null
        if ($fetchFailed) { $alarmClass = 'fetch-failed' }
        if ($commitRes.Result -eq 'fresh-writes') { $skipReason = 'fresh-writes' }
        elseif ($commitRes.Result -eq 'commit-blocked') { $alarmClass = 'commit-blocked' }

        # 4. pull half — heartbeat first: the network-bound step most likely
        # to legitimately run long, so a still-progressing holder refreshes
        # its own staleness clock right before it (codex-2, round 4).
        Update-SweepLockHeartbeat -StateDir $StateDir
        $pullRes = Invoke-SweepPullHalf -GitExe $GitExe -VaultPath $VaultPath -ObsidianProcessName $ObsidianProcessName -Behind $behind
        switch ($pullRes.Result) {
            'obsidian-open' { $status.consecutive_pull_skips = [int]$status.consecutive_pull_skips + 1 }
            'merge-would-overwrite' { $status.consecutive_pull_skips = [int]$status.consecutive_pull_skips + 1 }
            'up-to-date' { $status.consecutive_pull_skips = 0 }
            'pulled' { $status.consecutive_pull_skips = 0 }
            'merge-conflict' { $alarmClass = 'merge-conflict' }
        }
        if ([int]$status.consecutive_pull_skips -ge $PullSkipAlarmAfter) { $alarmClass = 'pull-backlog' }

        $abF = Get-SweepAheadBehind -GitExe $GitExe -VaultPath $VaultPath

        # 5. push half — skipped entirely when the commit half was blocked,
        # OR when the pull half just hit a merge-conflict: local is still
        # diverged from origin at that point, so a push would only fail
        # again (non-fast-forward) and its alarm_class would silently
        # overwrite the merge-conflict alarm this tick already raised —
        # exactly the ambiguity D9's single alarm_class field can't carry.
        if ($commitRes.Result -eq 'commit-blocked' -or $pullRes.Result -eq 'merge-conflict') {
            $pushRes = @{ Result = 'skipped-commit-blocked-or-conflict' }
        } else {
            $pushRes = Invoke-SweepPushHalf -GitExe $GitExe -VaultPath $VaultPath -Ahead $abF.Ahead
        }
        if ($pushRes.Result -eq 'push-failed') {
            $status.consecutive_push_failures = [int]$status.consecutive_push_failures + 1
            if ($pushRes.AlarmClass) { $alarmClass = $pushRes.AlarmClass }
        } elseif ($pushRes.Result -eq 'pushed' -or $pushRes.Result -eq 'nothing-to-push') {
            # CR (codex-2): 'nothing-to-push' means the push dimension is
            # caught up too (e.g. an operator manually pushed the pending
            # commits out of band) — not resetting here left
            # consecutive_push_failures >= 6 stuck RED forever even once the
            # vault was genuinely back in sync.
            $status.consecutive_push_failures = 0
        }

        # 6. state files
        $head = & $GitExe -C $VaultPath rev-parse HEAD 2>$null
        $nowIso = Get-SweepNowIso
        Add-SweepLogLine -StateDir $StateDir -Line "$nowIso tick_start=$tickStartIso dur_ms=$([int]((Get-Date) - $t0).TotalMilliseconds) commit=$($commitRes.Result) pull=$($pullRes.Result) push=$($pushRes.Result) ahead=$($abF.Ahead) behind=$($abF.Behind) skip=$skipReason alarm=$alarmClass"

        $status.ts = $nowIso
        $status.head = "$head".Trim()
        $status.ahead_origin = $abF.Ahead
        $status.behind_origin = $abF.Behind
        $status.alarm_class = $alarmClass
        if ($alarmClass) { $status.last_alarm_ts = $nowIso }

        # CR (codex-2): a tick that committed+pushed cleanly but SKIPPED the
        # pull half (obsidian-open / merge-would-overwrite) can still be
        # behind origin — last_clean_ts must not advance while remote changes
        # sit unapplied, or the 60-min stale detection never fires.
        $committedOrNothing = ($commitRes.Result -eq 'committed' -or $commitRes.Result -eq 'nothing-to-commit')
        $pushedOrNothing = ($pushRes.Result -eq 'pushed' -or $pushRes.Result -eq 'nothing-to-push')
        if ($committedOrNothing -and $pushedOrNothing -and (-not $alarmClass) -and $abF.Behind -eq 0) {
            $status.last_clean_ts = $nowIso
        }

        Write-SweepStatus -StateDir $StateDir -Status $status
    }
    finally {
        Exit-SweepLock -StateDir $StateDir
    }
}

# --- gate dispatch (D1) --- the switch IS the opt-in and bypasses the env
# gate entirely. Everything below this line is the pre-existing legacy
# LUNA_VAULT_AUTOSYNC path, untouched.
if ($Sweep) { Invoke-Sweep; exit }

# --- flag gate (default OFF) ---
$flag = ("$($env:LUNA_VAULT_AUTOSYNC)").Trim().ToLower()
if ($flag -notin @('1', 'true', 'on', 'yes')) {
    Log "LUNA_VAULT_AUTOSYNC is off — no commit, no push, no network. (set LUNA_VAULT_AUTOSYNC=1 to enable)"
    exit 0
}

$RepoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) {
    Log "not inside a git repo — nothing to sync."
    exit 0
}
Set-Location "$RepoRoot".Trim()

# ON requires a remote — autosync's whole job is to push.
if ([string]::IsNullOrWhiteSpace(((git remote) -join ''))) {
    Log "enabled but no remote is configured — nothing to push (no-op)."
    exit 0
}

if ([string]::IsNullOrWhiteSpace(((git status --porcelain) -join ''))) {
    Log "working tree clean — nothing to commit."
    exit 0
}

# The commit lands on `main` (a vault is single-writer by design); the
# worktree-isolation guard requires the .single-writer marker. Enabling
# LUNA_VAULT_AUTOSYNC is the operator's explicit opt-in, so ensure the marker
# exists — a clone WITH a remote won't have one (setup leaves clones as-is),
# and without it this commit would be hard-blocked.
$marker = Join-Path $RepoRoot '.single-writer'
if (-not (Test-Path $marker)) {
    New-Item -ItemType File -Path $marker | Out-Null
    Log "created .single-writer (autosync commits to main; the flag is your opt-in)."
}

# Stage the whole vault — its content is the product.
git add -A
if ($LASTEXITCODE -ne 0) {
    Log "git add -A failed — NOT committing or pushing."
    exit 1
}

# Commit THROUGH pre-commit (NEVER --no-verify): the gitleaks/secret hooks are
# the egress guard. A blocked commit exits non-zero, and the push below is gated
# on this success, so nothing leaves.
#
# A pre-commit AUTO-FIXER (e.g. end-of-file-fixer on a staged code/config file) may
# modify a staged file, which aborts the commit and leaves the tree dirty — at a
# glance indistinguishable from a real block. So retry ONCE: re-stage and commit
# again. A genuine gitleaks/secret rejection survives both passes (gitleaks never
# auto-fixes, so the second commit fails too) and still aborts the push.
git commit -q -m "chore: vault autosync"
if ($LASTEXITCODE -ne 0) {
    if ([string]::IsNullOrWhiteSpace(((git status --porcelain) -join ''))) {
        Log "nothing to commit after hooks ran — no-op."
        exit 0
    }
    # A hook auto-fixed files — re-stage and retry once.
    git add -A
    git commit -q -m "chore: vault autosync"
    if ($LASTEXITCODE -ne 0) {
        if ([string]::IsNullOrWhiteSpace(((git status --porcelain) -join ''))) {
            Log "nothing to commit after retry — no-op."
            exit 0
        }
        Log "commit BLOCKED by pre-commit (secret detected, or a hook keeps modifying files) — NOT pushing."
        exit 1
    }
}
Log "committed."

$remote = (git remote | Select-Object -First 1)
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
git push $remote $branch
if ($LASTEXITCODE -ne 0) {
    Log "push to $remote/$branch failed."
    exit 1
}
Log "pushed to $remote/$branch."
