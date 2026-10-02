# Shared PowerShell lane mirror/lock (HIMMEL-4091). No credentials/history copied.
# The caller's state retains its sanitizer, identity stamp and trust policy.
function Get-LaneSeedFingerprint($Seed) {
  $FingerprintJs = @'
const fs=require("fs"), path=require("path"), crypto=require("crypto");
const root=process.argv[1], hash=crypto.createHash("sha256");
function walk(rel,ancestors=new Set()) {
  const p=path.join(root,rel);
  hash.update(JSON.stringify(rel)+"\n");
  let s;
  try { s=fs.lstatSync(p); } catch(e) { if(e.code==="ENOENT") { hash.update("absent\n"); return; } throw e; }
  if(s.isSymbolicLink()) { hash.update("link\n"+JSON.stringify(fs.readlinkSync(p))+"\n"); try { s=fs.statSync(p); } catch(e) { if(e.code==="ENOENT") { hash.update("dangling\n"); return; } throw e; } }
  if(s.isDirectory()) {
    const real=fs.realpathSync(p); if(ancestors.has(real)) throw Error("cyclic seed source: "+rel);
    const next=new Set(ancestors); next.add(real);
    hash.update("dir\n"); for(const name of fs.readdirSync(p).sort()) walk(path.join(rel,name),next);
  }
  else if(s.isFile()) { hash.update("file\n"+s.mode+"\n"+s.size+"\n"); hash.update(fs.readFileSync(p)); }
  else { throw Error("unsupported seed source: "+rel); }
}
try {
  for(const rel of ["settings.json","CLAUDE.md","RTK.md","commands","skills","hooks","agents","plugins/installed_plugins.json","plugins/known_marketplaces.json","plugins/marketplaces","plugins/claude-hud/config.json","claude-hud.json"]) walk(rel);
  process.stdout.write(hash.digest("hex"));
} catch(e) { console.error("lane mirror fingerprint: "+e.message); process.exit(4); }
'@
  $result = & node -e $FingerprintJs (Join-Path $Seed.HomeDir '.claude')
  if ($LASTEXITCODE -ne 0) { throw 'Failed to fingerprint the seed source' }
  return $result
}

function Copy-LaneSeedConfig($Seed) {
  $ErrorActionPreference = 'Stop'
  $src = Join-Path $Seed.HomeDir '.claude'
  $dir = $Seed.ConfigDir
  try {
    try { Remove-Item -LiteralPath (Join-Path $dir '.seeded') -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { }
    $fingerprint = Get-LaneSeedFingerprint $Seed
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'plugins') | Out-Null
    $settings = Join-Path $src 'settings.json'
    if (Test-Path -LiteralPath $settings) {
      $SanitizerJs = $Seed.SanitizerJs
      & node -e $SanitizerJs $settings (Join-Path $dir 'settings.json')
      if ($LASTEXITCODE -ne 0) { throw 'Failed to sanitize settings.json (node missing/broken?)' }
    } elseif (Test-Path -LiteralPath (Join-Path $dir 'settings.json')) {
      Remove-Item -LiteralPath (Join-Path $dir 'settings.json') -Force
    }
    foreach ($f in 'CLAUDE.md', 'RTK.md') {
      $p = Join-Path $src $f
      $dp = Join-Path $dir $f
      $present = if ($Seed.LeafOnly) { Test-Path -LiteralPath $p -PathType Leaf } else { Test-Path -LiteralPath $p }
      if ($present) { Copy-Item -LiteralPath $p -Destination $dp -Force }
      elseif (Test-Path -LiteralPath $dp) { Remove-Item -LiteralPath $dp -Force }
    }
    $claudeMd = Join-Path $dir 'CLAUDE.md'
    if ($Seed.IdentityStanza -and (Test-Path -LiteralPath $claudeMd -PathType Leaf)) {
      [System.IO.File]::AppendAllText($claudeMd, $Seed.IdentityStanza, (New-Object System.Text.UTF8Encoding($false)))
    }
    foreach ($d in 'commands', 'skills', 'hooks', 'agents', 'plugins/marketplaces') {
      $dst = Join-Path $dir $d
      if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
      $p = Join-Path $src $d
      if (Test-Path -LiteralPath $p -PathType Container) {
        Copy-Item -LiteralPath $p -Destination (Split-Path -Parent $dst) -Recurse -Force
      }
    }
    foreach ($f in 'plugins/installed_plugins.json', 'plugins/known_marketplaces.json', 'plugins/claude-hud/config.json', 'claude-hud.json') {
      $p = Join-Path $src $f
      $dp = Join-Path $dir $f
      if (Test-Path -LiteralPath $p) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dp) | Out-Null
        Copy-Item -LiteralPath $p -Destination $dp -Force
      } elseif (Test-Path -LiteralPath $dp) { Remove-Item -LiteralPath $dp -Force }
    }
    if ((Get-LaneSeedFingerprint $Seed) -ne $fingerprint) { throw 'Source changed during seeding; re-run' }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $dir '.seed-fingerprint'), "$fingerprint`n", $utf8)
    # Preserve Codex's version/model stamp; other lanes retain the empty marker.
    [System.IO.File]::WriteAllText((Join-Path $dir '.seeded'), "$($Seed.Stamp)`n", $utf8)
  } catch {
    [Console]::Error.WriteLine("$($Seed.Lane): FAILED to seed config dir ($($_.Exception.Message)). Refusing to launch with a half-seeded config dir.")
    exit 4
  }
}

function Test-LaneConfigSeedStale($Seed) {
  $sentinel = Join-Path $Seed.ConfigDir '.seeded'
  if ($Seed.StampRequired -and (Test-Path -LiteralPath $sentinel)) {
    $stamp = Get-Content -LiteralPath $sentinel -Raw -ErrorAction SilentlyContinue
    if ($null -eq $stamp -or $stamp.Trim() -ne $Seed.Stamp) { return $true }
  }
  if ($env:CLAUDE_LANE_AUTO_RESEED -eq '0') { return $false }
  try {
    if (-not (Test-Path -LiteralPath $sentinel)) { return $false }
    $time = (Get-Item -Force -LiteralPath $sentinel).LastWriteTimeUtc
    $src = Join-Path $Seed.HomeDir '.claude'
    foreach ($rel in 'settings.json', 'CLAUDE.md', 'RTK.md', 'plugins/installed_plugins.json', 'plugins/known_marketplaces.json', 'plugins/claude-hud/config.json', 'claude-hud.json') {
      $s = Join-Path $src $rel
      $d = Join-Path $Seed.ConfigDir $rel
      if (Test-Path -LiteralPath $s) {
        if ((Get-Item -LiteralPath $s).LastWriteTimeUtc -gt $time) { return $true }
      } elseif (Test-Path -LiteralPath $d) { return $true }
    }
    foreach ($rel in 'commands', 'skills', 'hooks', 'agents', 'plugins/marketplaces') {
      $s = Join-Path $src $rel
      $d = Join-Path $Seed.ConfigDir $rel
      if (Test-Path -LiteralPath $s -PathType Container) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { return $true }
      } elseif (Test-Path -LiteralPath $d -PathType Container) { return $true }
    }
    $previous = Get-Content -LiteralPath (Join-Path $Seed.ConfigDir '.seed-fingerprint') -Raw -ErrorAction Stop
    return ((Get-LaneSeedFingerprint $Seed) -ne $previous.Trim())
  } catch { return $true }
}

function Get-LaneSeedLockIdentity($Seed) {
  $IdentityJs = @'
const fs=require("fs");
try {
  const s=fs.lstatSync(process.argv[1],{bigint:true});
  if(!s.isDirectory() || s.ino===0n) process.exit(1);
  process.stdout.write(s.dev+":"+s.ino);
} catch(e) { process.exit(1); }
'@
  $identity = & node -e $IdentityJs "$($Seed.ConfigDir).seed-lock"
  if ($LASTEXITCODE -ne 0) { return $null }
  return $identity
}

function Move-LaneSeedLockStale($Seed) {
  # Keep a non-empty destination named for the checked inode. Two contenders
  # delayed even after rechecking target the SAME destination; only one rename
  # can succeed. No pre-rename reservation can strand a lock after a crash.
  $RetireJs = @'
const fs=require("fs"), path=require("path"), lock=process.argv[1], identity=process.argv[2];
try {
  if(!/^[0-9]+:[1-9][0-9]*$/.test(identity)) process.exit(1);
  const retired=lock+".stale."+identity.replace(":",".");
  const s=fs.lstatSync(lock,{bigint:true});
  if(!s.isDirectory() || s.dev+":"+s.ino!==identity) process.exit(1);
  // Populate empty legacy locks without overwriting a published owner.
  try { fs.writeFileSync(path.join(lock,"owner"),"retired legacy seed lock\n",{flag:"wx"}); }
  catch(e) { if(e.code!=="EEXIST") throw e; }
  const checked=fs.lstatSync(lock,{bigint:true});
  if(!checked.isDirectory() || checked.dev+":"+checked.ino!==identity) process.exit(1);
  fs.renameSync(lock,retired);
} catch(e) { process.exit(1); }
'@
  & node -e $RetireJs "$($Seed.ConfigDir).seed-lock" $Seed.LockIdentity
  return ($LASTEXITCODE -eq 0)
}

function Test-LaneSeedLockStale($Seed) {
  $Seed.LockIdentity = Get-LaneSeedLockIdentity $Seed
  if (-not $Seed.LockIdentity) { return $false }
  $lock = "$($Seed.ConfigDir).seed-lock"
  if (-not (Test-Path -LiteralPath $lock -PathType Container)) { return $false }
  try {
    $age = ([DateTime]::UtcNow - (Get-Item -Force -LiteralPath $lock).LastWriteTimeUtc).TotalSeconds
    if ($age -lt $Seed.LockStale) { return $false }
    $owner = @()
    try { $owner = @(Get-Content -LiteralPath (Join-Path $lock 'owner') -ErrorAction Stop) } catch { }
    if ($owner.Count -ne 2 -or $owner[0] -notmatch '^[1-9][0-9]*$' -or $owner[1] -notmatch '^ticks:[0-9]+$') {
      [Console]::Error.WriteLine("$($Seed.Lane): reclaiming legacy/unreadable seed lock $lock (age $([int]$age)s).")
      return $true
    }
    $process = Get-Process -Id ([int]$owner[0]) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    return ("ticks:$($process.StartTime.ToUniversalTime().Ticks)" -ne $owner[1])
  } catch { return $false }
}

function Remove-LaneSeedLock($Seed, [string]$Owner) {
  $lock = "$($Seed.ConfigDir).seed-lock"
  $ownerPath = Join-Path $lock 'owner'
  if ((Get-Content -LiteralPath $ownerPath -Raw -ErrorAction SilentlyContinue) -ne $Owner) { return }
  Remove-Item -LiteralPath $ownerPath -Force -ErrorAction Stop
  [System.IO.Directory]::Delete($lock)
}

function Invoke-LaneSeedWithLock($Seed, [bool]$Reseed, [scriptblock]$AfterMirror) {
  $ErrorActionPreference = 'Stop'
  $lock = "$($Seed.ConfigDir).seed-lock"
  $ticks = 0
  $owner = "$PID`nticks:$((Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks)`n"
  $candidate = "$lock.pending.$PID.$([Guid]::NewGuid().ToString('N'))"
  $PublishJs = @'
const fs=require("fs"), candidate=process.argv[1], lock=process.argv[2];
try {
  try { fs.lstatSync(lock); process.exit(1); } catch(e) { if(e.code!=="ENOENT") throw e; }
  fs.renameSync(candidate,lock);
} catch(e) { console.error("lane seed-lock publish: "+e.message); process.exit(1); }
'@
  try {
    New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $candidate 'owner'), $owner, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    [Console]::Error.WriteLine("$($Seed.Lane): FAILED to prepare seed-lock ownership: $($_.Exception.Message)")
    exit 4
  }
  try {
  while ($true) {
    try {
      & node -e $PublishJs $candidate $lock
      if ($LASTEXITCODE -ne 0) { throw 'Seed lock is held or cannot be published' }
      break
    } catch {
      if ((Test-LaneSeedLockStale $Seed) -and (Move-LaneSeedLockStale $Seed)) {
        continue
      }
      if ($ticks -ge ($Seed.LockTimeout * 2)) {
        [Console]::Error.WriteLine("$($Seed.Lane): timed out after $($Seed.LockTimeout)s waiting for the config-dir seed lock ($lock).")
        exit 4
      }
      Start-Sleep -Milliseconds 500
      $ticks++
    }
  }
    if ($Reseed -or (-not (Test-Path -LiteralPath (Join-Path $Seed.ConfigDir '.seeded'))) -or (Test-LaneConfigSeedStale $Seed)) { Copy-LaneSeedConfig $Seed }
    if ($AfterMirror) { & $AfterMirror }
  } catch {
    [Console]::Error.WriteLine("$($Seed.Lane): seed failed: $($_.Exception.Message)")
    exit 4
  } finally {
    try { Remove-LaneSeedLock $Seed $owner }
    catch { [Console]::Error.WriteLine("$($Seed.Lane): WARNING - failed to release seed lock $lock (not empty or busy).") }
    if (Test-Path -LiteralPath $candidate) {
      try {
        Remove-Item -LiteralPath (Join-Path $candidate 'owner') -Force -ErrorAction Stop
        [System.IO.Directory]::Delete($candidate)
      } catch { }
    }
  }
}

Export-ModuleMember -Function Copy-LaneSeedConfig, Test-LaneConfigSeedStale, Invoke-LaneSeedWithLock
