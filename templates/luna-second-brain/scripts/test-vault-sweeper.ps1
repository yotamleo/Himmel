<#
  Suite for the LUNA-131 `-Sweep` headless vault sweeper (vault-autosync.ps1).
  Modelled on test-vault-git.ps1: SKIPs loud if pre-commit/git are absent.
  Per-case fixture: a throwaway vault copy + a second bare origin,
  `.single-writer` CREATED (gitignored, so a fresh copy lacks it), hooks
  installed as BOTH pre-commit AND commit-msg. Cases run through the
  fixture's OWN copy of vault-autosync.ps1 (scripts/ is copied per fixture),
  same convention as test-vault-git.ps1.
  Run: pwsh scripts/test-vault-sweeper.ps1
#>
$ErrorActionPreference = 'Continue'

# Captured native stdout is decoded via [Console]::OutputEncoding -- the
# legacy OEM codepage on default Windows installs, not UTF-8, so any
# non-ASCII byte a native command emits is silently mis-decoded on capture
# and written back corrupted (HIMMEL-2256; reference fix: gen-changelog.ps1).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$TR = (Resolve-Path (Join-Path $here '..')).Path
$failed = 0
function Assert([string]$label, [bool]$cond, [string]$detail = '') {
    if ($cond) { Write-Host "PASS $label" } else { Write-Host "FAIL $label $detail"; $script:failed++ }
}

if (-not (Get-Command pre-commit -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP all — pre-commit not on PATH (Precondition B)"; exit 0
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "SKIP all — git not on PATH"; exit 0
}
$GitExeReal = 'C:\Program Files\Git\cmd\git.exe'
$GitBinDirReal = 'C:\Program Files\Git\bin'
if (-not (Test-Path $GitExeReal) -or -not (Test-Path (Join-Path $GitBinDirReal 'sh.exe'))) {
    Write-Host "SKIP all — Git for Windows not found at the sweeper's default paths"; exit 0
}

$env:USER_SLUG = 'luna-test'
$env:GIT_AUTHOR_NAME = 'luna-test'; $env:GIT_AUTHOR_EMAIL = 'lt@example.com'
$env:GIT_COMMITTER_NAME = 'luna-test'; $env:GIT_COMMITTER_EMAIL = 'lt@example.com'

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sweepps-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Isolate the fixtures from the HOST's global git config (LUNA-131, same fix
# as test-vault-git.ps1): a host that sets core.hooksPath globally makes
# `pre-commit install` abort with "Cowardly refusing to install hooks with
# core.hooksPath set", which would SKIP every hook-dependent case here for a
# reason unrelated to the code under test.
$env:GIT_CONFIG_GLOBAL = Join-Path $tmp 'gitconfig-isolated'
New-Item -ItemType File -Force -Path $env:GIT_CONFIG_GLOBAL | Out-Null

function New-SweepFixture {
    param([string]$Name)
    $caseTmp = Join-Path $tmp $Name
    $V = Join-Path $caseTmp 'vault'
    New-Item -ItemType Directory -Force -Path $V | Out-Null
    foreach ($f in @('.gitignore', '.gitattributes', '.pre-commit-config.yaml', '.gitleaks.toml', '.env.example', '.vault-template.json', 'README.md', '_CLAUDE.md', 'index.md', 'log.md', 'Welcome.md')) {
        Copy-Item (Join-Path $TR $f) (Join-Path $V $f)
    }
    Copy-Item -Recurse (Join-Path $TR 'scripts') (Join-Path $V 'scripts')
    New-Item -ItemType Directory -Force -Path (Join-Path $V '.obsidian') | Out-Null
    Set-Content -NoNewline -Path (Join-Path $V '.obsidian\community-plugins.json') -Value '["dataview","qmd-as-md-obsidian","obsidian-local-rest-api","calendar","obsidian-banners"]'
    foreach ($d in @('00-Inbox', '10-Projects', '20-Areas', '30-Resources', '40-Archive', '50-Journal', '60-Maps', '_Templates')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $V $d) | Out-Null
        # git tracks no empty directory, so a directory with nothing committed
        # in it is silently ABSENT from a fresh `git clone` (several cases
        # clone the bare origin into a second working copy and then write
        # into these dirs there) — seed a placeholder so every case's
        # directories survive a clone.
        Set-Content -NoNewline -Path (Join-Path $V "$d\.gitkeep") -Value ''
    }

    git -C $V init -q -b main
    git -C $V add -A
    git -C $V commit -q -m 'chore: scaffold'
    New-Item -ItemType File -Force -Path (Join-Path $V '.single-writer') | Out-Null

    Push-Location $V
    pre-commit install --hook-type pre-commit --hook-type commit-msg *> $null
    Pop-Location

    $bare = Join-Path $caseTmp 'bare.git'
    git init --bare -q -b main $bare
    git -C $V remote add origin $bare
    # -u: a real vault gets branch tracking for free from `git clone`; this
    # fixture is built via `init` + `remote add` + `push` instead, which
    # does NOT set tracking on its own — matters because plain `git pull`
    # (with no explicit remote/branch) needs it.
    git -C $V push -qu origin main
    git -C $V fetch -q origin

    $stateDir = Join-Path $caseTmp 'state'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

    return [ordered]@{ CaseTmp = $caseTmp; V = $V; Bare = $bare; StateDir = $stateDir }
}

function Invoke-SweepTick {
    param(
        $Fixture,
        [string]$ObsidianProcessName = 'luna-sweeper-test-none',
        [string]$ExpectedOriginUrl = '',
        [int]$FreshWriteSeconds = 30,
        [int]$PullSkipAlarmAfter = 12,
        [switch]$NoVaultPath
    )
    $script = Join-Path $Fixture.V 'scripts\vault-autosync.ps1'
    $argList = @('-NoProfile', '-File', $script, '-Sweep', '-StateDir', $Fixture.StateDir,
        '-ObsidianProcessName', $ObsidianProcessName, '-FreshWriteSeconds', $FreshWriteSeconds,
        '-PullSkipAlarmAfter', $PullSkipAlarmAfter)
    if (-not $NoVaultPath) { $argList += @('-VaultPath', $Fixture.V) }
    if ($ExpectedOriginUrl) { $argList += @('-ExpectedOriginUrl', $ExpectedOriginUrl) }
    & pwsh @argList *> $null
}

function Get-SweepStatus($Fixture) {
    Get-Content -Raw (Join-Path $Fixture.StateDir 'status.json') | ConvertFrom-Json
}
function Get-SweepLogTail($Fixture, [int]$n = 1) {
    (Get-Content (Join-Path $Fixture.StateDir 'sync.log') | Select-Object -Last $n) -join "`n"
}
function Age-SweepFile([string]$Path, [int]$Seconds) {
    (Get-Item $Path).LastWriteTime = (Get-Date).AddSeconds(-$Seconds)
}
# The "obsidian open" decoy process. NOT notepad.exe: on Windows 11, Notepad
# is a packaged (MSIX) app — it launches through an activation-broker stub
# whose PID differs from the real Notepad process AND whose window is opened
# by the broker, not by this script's own child process, so `-WindowStyle
# Hidden` on the Start-Process call does not reliably reach it (a real
# desktop window was observed even with the flag set). A renamed COPY of
# powershell.exe is a plain Win32 console app: -WindowStyle Hidden actually
# suppresses its window (verified: MainWindowHandle=0), and it registers
# under the copy's own file name in Get-Process, so it can never collide
# with the suite's own pwsh/powershell processes.
$SweepDecoyName = 'luna-sweep-test-decoy'
$SweepDecoyExe = $null
function Get-SweepDecoyExe {
    if (-not $script:SweepDecoyExe) {
        $script:SweepDecoyExe = Join-Path $tmp "$SweepDecoyName.exe"
        Copy-Item -Path (Get-Command powershell.exe).Source -Destination $script:SweepDecoyExe -Force
    }
    return $script:SweepDecoyExe
}
function Start-SweepDecoy {
    $p = Start-Process -FilePath (Get-SweepDecoyExe) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    return $p
}
function Stop-SweepDecoy {
    # Cleanup by NAME, not by the PassThru PID: robust even if Start-Process's
    # returned process ever turns out not to be the final long-lived one.
    Get-Process -Name $SweepDecoyName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

try {
    # =================================================================
    # Task 4 — dispatch, environment pinning, vault resolution
    # =================================================================

    # --- S1: bare -Sweep, LUNA_VAULT_AUTOSYNC unset ⇒ a commit lands ---
    $env:LUNA_VAULT_AUTOSYNC = $null
    $f1 = New-SweepFixture -Name 's1'
    Set-Content -NoNewline -Path (Join-Path $f1.V '00-Inbox\s1-note.md') -Value "s1 content`n"
    Age-SweepFile (Join-Path $f1.V '00-Inbox\s1-note.md') 60
    $base = (git -C $f1.V rev-list --count HEAD).Trim()
    Invoke-SweepTick -Fixture $f1
    $after = (git -C $f1.V rev-list --count HEAD).Trim()
    Assert 'S1 bare -Sweep, LUNA_VAULT_AUTOSYNC unset: commit lands' (([int]$after) -gt ([int]$base))

    # --- S3: commit subject passes the installed commit-msg hook; body carries auto-sync: ---
    $subject = (git -C $f1.V log -1 --format=%s).Trim()
    $body = (git -C $f1.V log -1 --format=%b) -join "`n"
    Assert 'S3 commit subject is conventional (installed commit-msg hook passed)' ($subject -eq 'chore: vault autosync')
    Assert 'S3 commit body contains auto-sync:' ($body -match 'auto-sync:')

    # --- S2: -Sweep run with CWD = C:\Windows\System32 ⇒ still resolves the vault and commits ---
    $f2 = New-SweepFixture -Name 's2'
    Set-Content -NoNewline -Path (Join-Path $f2.V '00-Inbox\s2-note.md') -Value "s2 content`n"
    Age-SweepFile (Join-Path $f2.V '00-Inbox\s2-note.md') 60
    $base = (git -C $f2.V rev-list --count HEAD).Trim()
    Push-Location 'C:\Windows\System32'
    Invoke-SweepTick -Fixture $f2 -NoVaultPath
    Pop-Location
    $after = (git -C $f2.V rev-list --count HEAD).Trim()
    Assert 'S2 -Sweep from CWD=System32 (no -VaultPath): commit lands' (([int]$after) -gt ([int]$base))

    # --- S18: unpinned-PATH control ⇒ the pin displaces a decoy bash.exe ---
    $f18 = New-SweepFixture -Name 's18'
    $decoyDir = Join-Path $f18.CaseTmp 'decoy-bin'
    New-Item -ItemType Directory -Force -Path $decoyDir | Out-Null
    Set-Content -Path (Join-Path $decoyDir 'bash.exe') -Value 'decoy, not a real bash'
    Set-Content -NoNewline -Path (Join-Path $f18.V '00-Inbox\s18-note.md') -Value "s18 content`n"
    Age-SweepFile (Join-Path $f18.V '00-Inbox\s18-note.md') 60
    $origPath = $env:PATH
    $env:PATH = "$decoyDir;$origPath"
    try {
        Invoke-SweepTick -Fixture $f18
    } finally {
        $env:PATH = $origPath
    }
    $probe = (Get-Content -Raw (Join-Path $f18.StateDir 'path-probe.txt')).Trim().ToLowerInvariant()
    Assert 'S18 unpinned-PATH control: pin resolves bash under $GitBinDir' ($probe.StartsWith('c:\program files\git\bin'))
    Assert 'S18 unpinned-PATH control: pin does NOT resolve the decoy' (-not ($probe.StartsWith($decoyDir.ToLowerInvariant())))

    # =================================================================
    # Task 5 — lock, sanity gate, ordered tick, commit + push, state files
    # =================================================================

    # --- S4: template .gitattributes contains exactly the two merge=union lines ---
    $gaContent = Get-Content (Join-Path $TR '.gitattributes')
    $unionLines = @($gaContent | Where-Object { $_ -match 'merge=union' })
    Assert 'S4 template .gitattributes has exactly 2 merge=union lines' ($unionLines.Count -eq 2)
    Assert 'S4 arms.jsonl union line present' (($unionLines -match 'arms\.jsonl').Count -eq 1)
    Assert 'S4 takeovers.log union line present' (($unionLines -match 'takeovers\.log').Count -eq 1)

    # --- S6a: a file touched 1s ago ⇒ skip=fresh-writes AND the push half still ran ---
    $f6a = New-SweepFixture -Name 's6a'
    Set-Content -NoNewline -Path (Join-Path $f6a.V '00-Inbox\pre-existing.md') -Value "pre-existing`n"
    git -C $f6a.V add -A
    git -C $f6a.V commit -q -m 'chore: vault autosync'
    Set-Content -NoNewline -Path (Join-Path $f6a.V '00-Inbox\fresh.md') -Value "fresh content`n"
    Invoke-SweepTick -Fixture $f6a
    $tail = Get-SweepLogTail $f6a
    Assert 'S6a fresh-writes: commit half skipped' ($tail -match 'skip=fresh-writes')
    Assert 'S6a fresh-writes: push half still ran (pushed)' ($tail -match 'push=pushed')
    Assert 'S6a fresh-writes: bare origin received the earlier commit' (((git -C $f6a.Bare rev-parse main).Trim()) -eq ((git -C $f6a.V rev-parse HEAD).Trim()))
    Assert 'S6a fresh-writes: fresh.md left uncommitted' (((git -C $f6a.V status --porcelain) -join '') -match 'fresh\.md')

    # --- S6c: quiescent vault, run immediately after a git fetch ⇒ NOT fresh-writes (regression pin) ---
    $f6c = New-SweepFixture -Name 's6c'
    Set-Content -NoNewline -Path (Join-Path $f6c.V '00-Inbox\s6c-note.md') -Value "s6c content`n"
    Age-SweepFile (Join-Path $f6c.V '00-Inbox\s6c-note.md') 90
    $base = (git -C $f6c.V rev-list --count HEAD).Trim()
    Invoke-SweepTick -Fixture $f6c
    $after = (git -C $f6c.V rev-list --count HEAD).Trim()
    $tail = Get-SweepLogTail $f6c
    Assert 'S6c quiescent vault post-fetch: commit lands (not fresh-writes)' (([int]$after) -gt ([int]$base))
    Assert 'S6c quiescent vault post-fetch: no fresh-writes skip' (-not ($tail -match 'skip=fresh-writes'))

    # --- S7: index non-empty on entry ⇒ tick aborts, foreign staging untouched ---
    $f7 = New-SweepFixture -Name 's7'
    Set-Content -NoNewline -Path (Join-Path $f7.V '00-Inbox\foreign.md') -Value "foreign staged content`n"
    git -C $f7.V add '00-Inbox/foreign.md'
    $stagedBefore = (git -C $f7.V diff --cached --name-only) -join ','
    $base = (git -C $f7.V rev-list --count HEAD).Trim()
    Invoke-SweepTick -Fixture $f7
    $after = (git -C $f7.V rev-list --count HEAD).Trim()
    $stagedAfter = (git -C $f7.V diff --cached --name-only) -join ','
    Assert 'S7 foreign staging: tick aborts, no new commit' ($after -eq $base)
    Assert 'S7 foreign staging: staged content untouched' ($stagedAfter -eq $stagedBefore)
    Assert 'S7 foreign staging: skip=foreign-staging logged' ((Get-SweepLogTail $f7) -match 'skip=foreign-staging')

    # --- S8: gitleaks-style rejection ⇒ only this tick's paths unstaged, .gitleaks.toml byte-identical, alarm_class=commit-blocked ---
    $f8 = New-SweepFixture -Name 's8'
    $gitleaksBefore = Get-Content -Raw (Join-Path $f8.V '.gitleaks.toml')
    $akp = 'AKIA'; $aks = '1234567890ABCDEF'
    $leakPath = Join-Path $f8.V '30-Resources\leak.toml'
    Set-Content -Path $leakPath -Value "note = ""leaky data""`naws_key = ""$akp$aks"""
    Age-SweepFile $leakPath 60
    $base = (git -C $f8.V rev-list --count HEAD).Trim()
    Invoke-SweepTick -Fixture $f8
    $after = (git -C $f8.V rev-list --count HEAD).Trim()
    Assert 'S8 secret rejection: no new commit' ($after -eq $base)
    $stagedAfter = git -C $f8.V diff --cached --name-only
    Assert 'S8 secret rejection: leak.toml unstaged after retry' (-not ("$stagedAfter" -match 'leak\.toml'))
    $gitleaksAfter = Get-Content -Raw (Join-Path $f8.V '.gitleaks.toml')
    Assert 'S8 secret rejection: .gitleaks.toml byte-identical' ($gitleaksAfter -eq $gitleaksBefore)
    Assert 'S8 secret rejection: alarm_class=commit-blocked' ((Get-SweepStatus $f8).alarm_class -eq 'commit-blocked')

    # --- S9: clean tree + one unpushed commit ⇒ the tick still pushes ---
    $f9 = New-SweepFixture -Name 's9'
    Set-Content -NoNewline -Path (Join-Path $f9.V '00-Inbox\pre.md') -Value "pre content`n"
    git -C $f9.V add -A
    git -C $f9.V commit -q -m 'chore: vault autosync'
    Invoke-SweepTick -Fixture $f9
    Assert 'S9 clean tree + unpushed commit: pushed' (((git -C $f9.Bare rev-parse main).Trim()) -eq ((git -C $f9.V rev-parse HEAD).Trim()))
    $tail = Get-SweepLogTail $f9
    Assert 'S9 push half ran (push=pushed)' ($tail -match 'push=pushed')
    Assert 'S9 commit half found nothing new (commit=nothing-to-commit)' ($tail -match 'commit=nothing-to-commit')

    # --- S12: non-ff push ⇒ logged, consecutive_push_failures incremented, no sticky marker ---
    $f12 = New-SweepFixture -Name 's12'
    $V2 = Join-Path $f12.CaseTmp 'vault2'
    git clone -q $f12.Bare $V2
    Set-Content -NoNewline -Path (Join-Path $V2 '00-Inbox\remote-note.md') -Value "remote change`n"
    git -C $V2 add -A
    git -C $V2 -c user.name=other -c user.email=other@example.com commit -q -m 'chore: remote change'
    git -C $V2 push -q origin main
    Set-Content -NoNewline -Path (Join-Path $f12.V '00-Inbox\local-note.md') -Value "local change`n"
    git -C $f12.V add -A
    git -C $f12.V commit -q -m 'chore: vault autosync'
    $decoy = Start-SweepDecoy
    try {
        Invoke-SweepTick -Fixture $f12 -ObsidianProcessName $SweepDecoyName
    } finally {
        Stop-SweepDecoy
    }
    $status12 = Get-SweepStatus $f12
    Assert 'S12 non-ff push: consecutive_push_failures incremented' ($status12.consecutive_push_failures -ge 1)
    Assert 'S12 non-ff push: push-failed logged' ((Get-SweepLogTail $f12) -match 'push=push-failed')
    $stickyMarkers = @(Get-ChildItem -Recurse $f12.StateDir -File | Where-Object { $_.Name -match 'auth' -or $_.Name -match 'blocked' })
    Assert 'S12 non-ff push: no sticky auth-blocked marker file created' ($stickyMarkers.Count -eq 0)

    # --- S13: on an ALARMING tick status.json is written and last_clean_ts did NOT advance ---
    $f13 = New-SweepFixture -Name 's13'
    Invoke-SweepTick -Fixture $f13
    $status13a = Get-SweepStatus $f13
    Assert 'S13 setup: first clean tick set last_clean_ts' ($null -ne $status13a.last_clean_ts)
    Set-Content -NoNewline -Path (Join-Path $f13.V '.obsidian\community-plugins.json') -Value '["github-sync","dataview","qmd-as-md-obsidian","obsidian-local-rest-api","calendar","obsidian-banners"]'
    Start-Sleep -Milliseconds 1100
    Invoke-SweepTick -Fixture $f13
    $status13b = Get-SweepStatus $f13
    Assert 'S13 alarming tick: alarm_class=plugin-resurrected' ($status13b.alarm_class -eq 'plugin-resurrected')
    Assert 'S13 alarming tick: last_clean_ts unchanged' ($status13b.last_clean_ts -eq $status13a.last_clean_ts)
    Assert 'S13 alarming tick: ts advanced' ($status13b.ts -ne $status13a.ts)

    # --- S15: dead-PID lock ⇒ next tick steals; live-PID lock ⇒ second instance exits skip=locked ---
    $f15 = New-SweepFixture -Name 's15'
    $lockDir = Join-Path $f15.StateDir 'tick.lock'
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    $deadOwner = @{ pid = 999999; process_start_utc = (Get-Date).ToUniversalTime().ToString('o'); acquired_utc = (Get-Date).ToUniversalTime().ToString('o') }
    ($deadOwner | ConvertTo-Json) | Set-Content -Path (Join-Path $lockDir 'owner.json')
    Set-Content -NoNewline -Path (Join-Path $f15.V '00-Inbox\s15-dead.md') -Value "s15 dead-pid content`n"
    Age-SweepFile (Join-Path $f15.V '00-Inbox\s15-dead.md') 60
    $base = (git -C $f15.V rev-list --count HEAD).Trim()
    Invoke-SweepTick -Fixture $f15
    $after = (git -C $f15.V rev-list --count HEAD).Trim()
    Assert 'S15 dead-PID lock: next tick steals and commits' (([int]$after) -gt ([int]$base))

    $f15b = New-SweepFixture -Name 's15b'
    $sleeper = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 500
    $sleeperProc = Get-Process -Id $sleeper.Id
    $lockDir2 = Join-Path $f15b.StateDir 'tick.lock'
    New-Item -ItemType Directory -Force -Path $lockDir2 | Out-Null
    $liveOwner = @{
        pid               = $sleeperProc.Id
        process_start_utc = $sleeperProc.StartTime.ToUniversalTime().ToString('o')
        acquired_utc      = (Get-Date).ToUniversalTime().ToString('o')
    }
    ($liveOwner | ConvertTo-Json) | Set-Content -Path (Join-Path $lockDir2 'owner.json')
    Set-Content -NoNewline -Path (Join-Path $f15b.V '00-Inbox\s15-live.md') -Value "s15 live-pid content`n"
    Age-SweepFile (Join-Path $f15b.V '00-Inbox\s15-live.md') 60
    $base = (git -C $f15b.V rev-list --count HEAD).Trim()
    try {
        Invoke-SweepTick -Fixture $f15b
    } finally {
        Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
    }
    $after = (git -C $f15b.V rev-list --count HEAD).Trim()
    Assert 'S15 live-PID lock: second instance did not commit' ($after -eq $base)
    Assert 'S15 live-PID lock: skip=locked logged' ((Get-SweepLogTail $f15b) -match 'skip=locked')

    # --- S16: origin = template remote's URL ⇒ abort alarm_class=wrong-remote before any network call; -ExpectedOriginUrl mismatch ⇒ same ---
    $f16 = New-SweepFixture -Name 's16'
    git -C $f16.V remote add template 'C:\bogus\template-remote.git'
    git -C $f16.V remote set-url origin 'C:\bogus\template-remote.git'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-SweepTick -Fixture $f16
    $sw.Stop()
    $status16a = Get-SweepStatus $f16
    Assert 'S16a origin=template URL: alarm_class=wrong-remote' ($status16a.alarm_class -eq 'wrong-remote')
    Assert 'S16a origin=template URL: aborted fast (no network call attempted)' ($sw.Elapsed.TotalSeconds -lt 15)

    $f16b = New-SweepFixture -Name 's16b'
    Invoke-SweepTick -Fixture $f16b -ExpectedOriginUrl 'C:\bogus\different-remote.git'
    $status16b = Get-SweepStatus $f16b
    Assert 'S16b -ExpectedOriginUrl mismatch: alarm_class=wrong-remote' ($status16b.alarm_class -eq 'wrong-remote')

    # --- S17: github-sync re-enabled ⇒ STOP, alarm_class=plugin-resurrected ---
    $f17 = New-SweepFixture -Name 's17'
    Set-Content -NoNewline -Path (Join-Path $f17.V '.obsidian\community-plugins.json') -Value '["github-sync","dataview"]'
    Invoke-SweepTick -Fixture $f17
    Assert 'S17 github-sync re-enabled: alarm_class=plugin-resurrected' ((Get-SweepStatus $f17).alarm_class -eq 'plugin-resurrected')

    # --- S19: sync.log rotates at 1MB keeping one .old ---
    $f19 = New-SweepFixture -Name 's19'
    $logPath = Join-Path $f19.StateDir 'sync.log'
    $bigLine = ('x' * 200) + "`n"
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt 1100000) { [void]$sb.Append($bigLine) }
    Set-Content -NoNewline -Path $logPath -Value $sb.ToString()
    Set-Content -NoNewline -Path "$logPath.old" -Value "OLD-PRIOR-MARKER`n"
    Assert 'S19 setup: seeded sync.log >= 1MB' (((Get-Item $logPath).Length) -ge 1MB)
    Invoke-SweepTick -Fixture $f19
    $oldContent = Get-Content -Raw "$logPath.old"
    Assert 'S19 rotation: prior sync.log content moved to .old' (-not ($oldContent -match 'OLD-PRIOR-MARKER'))
    Assert 'S19 rotation: .old now holds the big rotated content' ($oldContent.Length -ge 1000000)
    Assert 'S19 rotation: new sync.log is small (just this tick''s line)' (((Get-Item $logPath).Length) -lt 1000)
    Assert 'S19 rotation: only ONE .old kept (no .old.old)' (-not (Test-Path "$logPath.old.old"))

    # =================================================================
    # Task 6 — the pull half
    # =================================================================

    # --- S5: decoy obsidian process running AND origin advanced ⇒ behind_origin > 0 recorded ---
    $f5 = New-SweepFixture -Name 's5'
    $V2 = Join-Path $f5.CaseTmp 'vault2'
    git clone -q $f5.Bare $V2
    Set-Content -NoNewline -Path (Join-Path $V2 '00-Inbox\remote-note.md') -Value "remote content`n"
    git -C $V2 add -A
    git -C $V2 -c user.name=other -c user.email=other@example.com commit -q -m 'chore: remote change'
    git -C $V2 push -q origin main
    $decoy = Start-SweepDecoy
    try {
        Invoke-SweepTick -Fixture $f5 -ObsidianProcessName $SweepDecoyName
    } finally {
        Stop-SweepDecoy
    }
    $status5 = Get-SweepStatus $f5
    Assert 'S5 decoy obsidian + advanced origin: behind_origin > 0' ($status5.behind_origin -gt 0)
    Assert 'S5 pull skipped due to obsidian-open' ((Get-SweepLogTail $f5) -match 'pull=obsidian-open')

    # --- S6b: extend S6a — on a fresh-writes skip, the pull half also still ran ---
    $f6b = New-SweepFixture -Name 's6b'
    $V2b = Join-Path $f6b.CaseTmp 'vault2'
    git clone -q $f6b.Bare $V2b
    Set-Content -NoNewline -Path (Join-Path $V2b '00-Inbox\remote-note.md') -Value "remote change`n"
    git -C $V2b add -A
    git -C $V2b -c user.name=other -c user.email=other@example.com commit -q -m 'chore: remote change'
    git -C $V2b push -q origin main
    Set-Content -NoNewline -Path (Join-Path $f6b.V '00-Inbox\fresh.md') -Value "fresh content`n"
    Invoke-SweepTick -Fixture $f6b
    $tail = Get-SweepLogTail $f6b
    Assert 'S6b fresh-writes: commit half skipped' ($tail -match 'skip=fresh-writes')
    Assert 'S6b fresh-writes: pull half still ran (pulled)' ($tail -match 'pull=pulled')
    Assert 'S6b fresh-writes: remote-note.md landed via pull' (Test-Path (Join-Path $f6b.V '00-Inbox\remote-note.md'))

    # --- S10: incoming diff touches a locally-modified file ⇒ skip=merge-would-overwrite, no pull attempted, vault untouched ---
    $f10 = New-SweepFixture -Name 's10'
    $sharedFile = '00-Inbox\shared.md'
    Set-Content -NoNewline -Path (Join-Path $f10.V $sharedFile) -Value "base content`n"
    git -C $f10.V add -A
    git -C $f10.V commit -q -m 'chore: vault autosync'
    git -C $f10.V push -q origin main
    $V2c = Join-Path $f10.CaseTmp 'vault2'
    git clone -q $f10.Bare $V2c
    Set-Content -NoNewline -Path (Join-Path $V2c $sharedFile) -Value "remote-modified content`n"
    git -C $V2c add -A
    git -C $V2c -c user.name=other -c user.email=other@example.com commit -q -m 'chore: remote edit'
    git -C $V2c push -q origin main
    Set-Content -NoNewline -Path (Join-Path $f10.V $sharedFile) -Value "local-modified content`n"
    $localBefore = Get-Content -Raw (Join-Path $f10.V $sharedFile)
    Invoke-SweepTick -Fixture $f10
    Assert 'S10 overlap with incoming diff: skip=merge-would-overwrite' ((Get-SweepLogTail $f10) -match 'pull=merge-would-overwrite')
    $localAfter = Get-Content -Raw (Join-Path $f10.V $sharedFile)
    Assert 'S10 overlap: vault untouched (local edit preserved)' ($localAfter -eq $localBefore)

    # --- S11: non-union conflict ⇒ merge --abort, vault untouched, alarm_class=merge-conflict ---
    $f11 = New-SweepFixture -Name 's11'
    $confFile = '00-Inbox\conflict.md'
    Set-Content -NoNewline -Path (Join-Path $f11.V $confFile) -Value "line one`nline two`nline three`n"
    git -C $f11.V add -A
    git -C $f11.V commit -q -m 'chore: vault autosync'
    git -C $f11.V push -q origin main
    $V2d = Join-Path $f11.CaseTmp 'vault2'
    git clone -q $f11.Bare $V2d
    Set-Content -NoNewline -Path (Join-Path $V2d $confFile) -Value "line one`nREMOTE CHANGE`nline three`n"
    git -C $V2d add -A
    git -C $V2d -c user.name=other -c user.email=other@example.com commit -q -m 'chore: remote edit'
    git -C $V2d push -q origin main
    Set-Content -NoNewline -Path (Join-Path $f11.V $confFile) -Value "line one`nLOCAL CHANGE`nline three`n"
    Age-SweepFile (Join-Path $f11.V $confFile) 60
    Invoke-SweepTick -Fixture $f11
    $tail = Get-SweepLogTail $f11
    Assert 'S11 non-union conflict: pull=merge-conflict' ($tail -match 'pull=merge-conflict')
    Assert 'S11 non-union conflict: alarm=merge-conflict' ($tail -match 'alarm=merge-conflict')
    Assert 'S11 non-union conflict: status alarm_class=merge-conflict' ((Get-SweepStatus $f11).alarm_class -eq 'merge-conflict')
    Assert 'S11 non-union conflict: no MERGE_HEAD left behind (abort completed)' (-not (Test-Path (Join-Path $f11.V '.git\MERGE_HEAD')))
    $contentAfter = Get-Content -Raw (Join-Path $f11.V $confFile)
    # `merge --abort` restores the file via a checkout, which re-applies the
    # vault's `* text=auto` line-ending normalization (LF -> CRLF on
    # Windows) — compare content normalized to LF so that benign, expected
    # git normalization doesn't fail an otherwise-correct assertion.
    $contentAfterNormalized = $contentAfter -replace "`r`n", "`n"
    Assert 'S11 non-union conflict: vault content untouched (local change preserved)' ($contentAfterNormalized -eq "line one`nLOCAL CHANGE`nline three`n")

    # --- S11b: seeded arms.jsonl divergence on both sides ⇒ union merge auto-resolves, both sides' lines present ---
    $f11b = New-SweepFixture -Name 's11b'
    $locksDir = Join-Path $f11b.V 'handovers\.locks'
    New-Item -ItemType Directory -Force -Path $locksDir | Out-Null
    Set-Content -Path (Join-Path $locksDir 'arms.jsonl') -Value '{"line":"base"}'
    git -C $f11b.V add -A
    git -C $f11b.V commit -q -m 'chore: vault autosync'
    git -C $f11b.V push -q origin main
    $V2e = Join-Path $f11b.CaseTmp 'vault2'
    git clone -q $f11b.Bare $V2e
    Add-Content -Path (Join-Path $V2e 'handovers\.locks\arms.jsonl') -Value '{"line":"remote-added"}'
    git -C $V2e add -A
    git -C $V2e -c user.name=other -c user.email=other@example.com commit -q -m 'chore: remote arms line'
    git -C $V2e push -q origin main
    Add-Content -Path (Join-Path $f11b.V 'handovers\.locks\arms.jsonl') -Value '{"line":"local-added"}'
    Age-SweepFile (Join-Path $f11b.V 'handovers\.locks\arms.jsonl') 60
    Invoke-SweepTick -Fixture $f11b
    Assert 'S11b union merge: pull=pulled (auto-resolved, no conflict)' ((Get-SweepLogTail $f11b) -match 'pull=pulled')
    $finalContent = Get-Content -Raw (Join-Path $f11b.V 'handovers\.locks\arms.jsonl')
    Assert 'S11b union merge: base line present' ($finalContent -match 'base')
    Assert 'S11b union merge: local-added line present' ($finalContent -match 'local-added')
    Assert 'S11b union merge: remote-added line present' ($finalContent -match 'remote-added')

    # --- S14: 12th consecutive pull skip ⇒ consecutive_pull_skips == 12 and alarm_class=pull-backlog ---
    $f14 = New-SweepFixture -Name 's14'
    $decoy14 = Start-SweepDecoy
    try {
        for ($n = 1; $n -le 12; $n++) {
            Invoke-SweepTick -Fixture $f14 -ObsidianProcessName $SweepDecoyName
        }
    } finally {
        Stop-SweepDecoy
    }
    $status14 = Get-SweepStatus $f14
    Assert 'S14 12th consecutive pull skip: consecutive_pull_skips == 12' ($status14.consecutive_pull_skips -eq 12)
    Assert 'S14 12th consecutive pull skip: alarm_class=pull-backlog' ($status14.alarm_class -eq 'pull-backlog')

    # =================================================================
    # S20 — production headlessness pin (operator-observed defect class:
    # a headless Task Scheduler batch-logon session has no desktop to show a
    # window on, and any window-creating spawn on the -Sweep path is exactly
    # the failure LUNA-131 exists to eliminate). Regression pin, not a
    # one-time cleanup: a source-level scan over the -Sweep path region only
    # (the marker comment through the gate-dispatch line), asserting no
    # window/shell-association call, or any Start-Process lacking explicit
    # window suppression.
    # =================================================================
    function Test-SweepPathHeadless([string]$Source) {
        $lines = @($Source -split "`r?`n")
        $startIdx = ($lines | Select-String -Pattern 'LUNA-131 -Sweep path' -SimpleMatch | Select-Object -First 1).LineNumber
        $endIdx = ($lines | Select-String -Pattern '^if \(\$Sweep\) \{ Invoke-Sweep; exit \}$' | Select-Object -First 1).LineNumber
        if (-not $startIdx -or -not $endIdx) { return @{ Ok = $false; Reason = 'markers not found in source' } }
        $region = $lines[($startIdx - 1)..($endIdx - 1)]
        foreach ($line in $region) {
            if ($line -match 'Invoke-Item|ShellExecute|explorer\.exe') {
                return @{ Ok = $false; Reason = "forbidden window/shell-association call: $line" }
            }
            if ($line -match '(?i)\bStart-Process\b' -and $line -notmatch '(?i)-WindowStyle\s+Hidden|-NoNewWindow') {
                return @{ Ok = $false; Reason = "Start-Process without window suppression: $line" }
            }
        }
        return @{ Ok = $true }
    }

    $sweeperSource = Get-Content -Raw (Join-Path $TR 'scripts\vault-autosync.ps1')
    $headlessCheck = Test-SweepPathHeadless -Source $sweeperSource
    Assert 'S20 -Sweep path is headless: no window-creating invocation' ($headlessCheck.Ok) ($headlessCheck.Reason)

    # Prove the pin can actually fail (a check that cannot fail is not a
    # pin): inject a deliberately headed spawn into the same region and
    # confirm the checker catches it.
    $badSource = $sweeperSource -replace [regex]::Escape('if ($Sweep) { Invoke-Sweep; exit }'), "Start-Process notepad.exe`nif (`$Sweep) { Invoke-Sweep; exit }"
    $badCheck = Test-SweepPathHeadless -Source $badSource
    Assert 'S20 self-check: the pin fails on an injected headed spawn' (-not $badCheck.Ok)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed -eq 0) { Write-Host 'All vault-sweeper tests passed.' }
else { Write-Host "$failed test(s) failed."; exit 1 }
