# Hermetic tests for reap-mcp-fleet.ps1 (HIMMEL-741).
# Get-CimInstance is NOT mocked: the .ps1 exposes a pure filter, Get-OrphanFleet,
# that takes a synthetic process-records array. We dot-source the script with
# -AsLibrary (defines functions, skips the live scan) and assert the orphan set
# for a hand-built topology that mirrors the real machine grounding.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Helper = Join-Path $ScriptDir 'reap-mcp-fleet.ps1'
$Pass = 0
$Fail = 0
function Pass([string]$Name) { Write-Host "  PASS  $Name"; $script:Pass++ }
function Fail([string]$Name, [string]$Detail = '') { Write-Host "  FAIL  $Name $Detail"; $script:Fail++ }
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Pass $Name } else { Fail $Name $Detail } }

# Load the functions without running the production scan.
. $Helper -AsLibrary

function Rec($procId, $parentId, $name, $cl) {
  [pscustomobject]@{ ProcessId = $procId; ParentProcessId = $parentId; Name = $name; CommandLine = $cl }
}

# Fixture command lines derive from the running user's profile dir (no literal
# home paths in source — the propagation leak scan fail-closes on them). The
# reaper's ownership predicates match username-independent fragments
# (OpenAI\Codex\runtimes, .codex\plugins\cache), so any profile root works.
$UserHome = $env:USERPROFILE
$UserHomeFwd = $UserHome -replace '\\', '/'
$CODEX_RUNTIME = "$UserHome\AppData\Local\OpenAI\Codex\runtimes\cua_node\1b23c930\bin\node_repl.exe"
$BUN_LUNA = "run --cwd $UserHomeFwd/.codex/plugins/cache/himmel/luna-correlate/0.2.0 --shell=bun --silent start"
$BROKER   = "node $UserHome\.claude\plugins\cache\openai-codex\codex\1.0.5\scripts\app-server-broker.mjs serve"

# --- topology ----------------------------------------------------------------
$procs = @(
  # LIVE fleet under a live app-server (which the live broker owns).
  (Rec 90  1   'node.exe'      $BROKER)                                   # broker (supervisor, live)
  (Rec 100 90  'codex.exe'     'codex.exe app-server')                    # app-server (supervisor, live)
  (Rec 101 100 'node_repl.exe' $CODEX_RUNTIME)                            # live fleet child -> NOT orphan
  (Rec 102 100 'uvx.exe'       "`"$UserHomeFwd/.local/bin/uvx.exe`" mcp-obsidian") # live fleet child -> NOT orphan

  # ORPHANED fleet: app-server pid 200 is DEAD (absent from the table).
  (Rec 201 200 'node_repl.exe' $CODEX_RUNTIME)                            # codex-owned, parent gone -> ORPHAN
  (Rec 202 200 'bun.exe'       "bun $BUN_LUNA")                           # codex-owned, parent gone -> ORPHAN
  (Rec 203 202 'bun.exe'       'bun server.ts')                           # under codex 202 -> ORPHAN

  # Non-codex MCP servers (Claude-launched) must be untouched.
  (Rec 301 1   'node.exe'      'node claude cli')                         # not a supervisor by our narrow def
  (Rec 300 301 'node.exe'      '"node" @playwright/mcp/cli.js')           # not codex-owned -> NOT orphan

  # Safe under-reap: bun server.ts whose codex launcher parent (211) is ALSO gone.
  (Rec 210 211 'bun.exe'       'bun server.ts')                           # no marker, parent gone -> NOT orphan

  # Kill-safety: codex-owned proc with a FULLY-LIVE chain rooting at PID 0 and
  # no recognized supervisor in it (e.g. launched under an unrecognized
  # supervisor variant). No dead link -> NOT orphan, never reaped.
  (Rec 401 0   'pwsh.exe'      'pwsh -NoProfile -File dev-driver.ps1')    # live non-supervisor root
  (Rec 400 401 'node.exe'      $CODEX_RUNTIME)                            # codex-owned, live chain -> NOT orphan
)

$orphans = @(Get-OrphanFleet -Procs $procs)
$got = @($orphans | ForEach-Object { $_.ProcessId } | Sort-Object)
$want = @(201, 202, 203)

Write-Host "Test 1: exact orphan set = dead-app-server fleet + its server.ts descendant"
Check 'orphan set is {201,202,203}' (($got -join ',') -eq ($want -join ',')) "got=$($got -join ',')"

Write-Host "Test 2: live fleet + supervisors + non-codex + under-reap are all excluded"
Check 'live node_repl 101 excluded'      (-not ($got -contains 101))
Check 'live uvx 102 excluded'            (-not ($got -contains 102))
Check 'app-server 100 never reaped'      (-not ($got -contains 100))
Check 'broker 90 never reaped'           (-not ($got -contains 90))
Check 'non-codex playwright 300 excluded' (-not ($got -contains 300))
Check 'orphan-parent server.ts 210 excluded (safe under-reap)' (-not ($got -contains 210))

Write-Host "Test 3: DeadAncestorPid annotation points at the vanished app-server"
$o201 = $orphans | Where-Object { $_.ProcessId -eq 201 }
Check 'node_repl 201 dead ancestor = 200' ($o201.DeadAncestorPid -eq 200) "got=$($o201.DeadAncestorPid)"

Write-Host "Test 4: empty input yields no orphans (no throw)"
$empty = @(Get-OrphanFleet -Procs @())
Check 'empty input -> 0 orphans' ($empty.Count -eq 0)

Write-Host "Test 5: predicates classify the grounded fingerprints"
Check 'node_repl is codex-owned'   (Test-CodexOwned -Proc (Rec 1 0 'node_repl.exe' $CODEX_RUNTIME))
Check '.codex plugin cache bun is codex-owned' (Test-CodexOwned -Proc (Rec 1 0 'bun.exe' "bun $BUN_LUNA"))
Check 'bare uvx mcp-obsidian NOT codex-owned'  (-not (Test-CodexOwned -Proc (Rec 1 0 'uvx.exe' 'uvx mcp-obsidian')))
Check 'codex.exe is a supervisor'  (Test-FleetSupervisor -Proc (Rec 1 0 'codex.exe' 'codex.exe app-server'))
Check 'broker.mjs is a supervisor' (Test-FleetSupervisor -Proc (Rec 1 0 'node.exe' $BROKER))
Check 'playwright node NOT a supervisor' (-not (Test-FleetSupervisor -Proc (Rec 1 0 'node.exe' '"node" @playwright/mcp/cli.js')))

# --- HIMMEL-1328: Get-DuplicateFleets (duplicate MCP-fleet children under a
# LIVE app-server - the ORPHAN scan is structurally blind to this: every
# process below is fully live throughout, mirroring the 2026-07-28 fleet
# audit that found 5 live luna-correlate instances under one codex.exe and 3
# more under a second, both truthfully reporting "0 orphans".
Write-Host "Test 5b: duplicate MCP-server instances under two DIFFERENT live app-servers are each flagged; singletons and the broker's own multi-app-server children are not"
$dupProcs = @(
  # broker (supervisor) with TWO live app-servers under it - normal topology
  # (see header GROUNDING); must NEVER itself be treated as duplicated.
  (Rec 90  1  'node.exe'  $BROKER)
  (Rec 991 90 'codex.exe' 'codex.exe app-server')
  (Rec 992 90 'codex.exe' 'codex.exe app-server')

  # app-server 991: 5 live luna-correlate instances -> DUPLICATE group.
  (Rec 1001 991 'bun.exe' "bun $BUN_LUNA")
  (Rec 1002 991 'bun.exe' "bun $BUN_LUNA")
  (Rec 1003 991 'bun.exe' "bun $BUN_LUNA")
  (Rec 1004 991 'bun.exe' "bun $BUN_LUNA")
  (Rec 1005 991 'bun.exe' "bun $BUN_LUNA")
  # app-server 991 also has ONE telegram-himmel instance -> not a duplicate.
  (Rec 1006 991 'bun.exe' "bun run --cwd $UserHomeFwd/.codex/plugins/cache/himmel/telegram-himmel/1.0.0 --shell=bun --silent start")
  # and one node_repl -> not a duplicate.
  (Rec 1007 991 'node_repl.exe' $CODEX_RUNTIME)
  # a single uvx mcp-obsidian -> not a duplicate.
  (Rec 1021 991 'uvx.exe'  "`"$UserHomeFwd/.local/bin/uvx.exe`" mcp-obsidian")

  # app-server 992: 3 live luna-correlate instances -> a SEPARATE duplicate
  # group (same identity, different supervisor - grouped independently).
  (Rec 1011 992 'bun.exe' "bun $BUN_LUNA")
  (Rec 1012 992 'bun.exe' "bun $BUN_LUNA")
  (Rec 1013 992 'bun.exe' "bun $BUN_LUNA")
)
$dupGroups = @(Get-DuplicateFleets -Procs $dupProcs)
Check 'exactly 2 duplicate groups found' ($dupGroups.Count -eq 2) "got=$($dupGroups.Count)"
$g991 = $dupGroups | Where-Object { $_.SupervisorPid -eq 991 }
$g992 = $dupGroups | Where-Object { $_.SupervisorPid -eq 992 }
Check 'app-server 991 luna-correlate group has count 5' ($g991.Count -eq 5) "got=$($g991.Count)"
Check 'app-server 991 group identity is luna-correlate' ($g991.Identity -eq 'luna-correlate') "got=$($g991.Identity)"
Check 'app-server 992 luna-correlate group has count 3' ($g992.Count -eq 3) "got=$($g992.Count)"
$totalDupInstances = ($dupGroups | Measure-Object -Property Count -Sum).Sum
Check 'total duplicate instances = 8 (5 + 3)' ($totalDupInstances -eq 8) "got=$totalDupInstances"

Write-Host "Test 5c: Get-ServerIdentity extracts plugin-cache package name, uvx trailing package, and falls back to Name"
Check 'bun luna-correlate identity' ((Get-ServerIdentity -Proc (Rec 1 0 'bun.exe' "bun $BUN_LUNA")) -eq 'luna-correlate')
Check 'uvx mcp-obsidian identity' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' "`"$UserHomeFwd/.local/bin/uvx.exe`" mcp-obsidian")) -eq 'mcp-obsidian')
Check 'node_repl falls back to Name' ((Get-ServerIdentity -Proc (Rec 1 0 'node_repl.exe' $CODEX_RUNTIME)) -eq 'node_repl.exe')
$CMD_NPX = 'cmd.exe /e:ON /v:OFF /d /c ""C:\Program Files\nodejs\npx.cmd" -y @upstash/context7-mcp"'
Check 'cmd.exe-wrapped npx identity is the package, not "cmd.exe"' ((Get-ServerIdentity -Proc (Rec 1 0 'cmd.exe' $CMD_NPX)) -eq '@upstash/context7-mcp') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'cmd.exe' $CMD_NPX))"
Check 'two DIFFERENT cmd.exe-wrapped npx packages are NOT grouped together' ((Get-ServerIdentity -Proc (Rec 1 0 'cmd.exe' $CMD_NPX)) -ne (Get-ServerIdentity -Proc (Rec 1 0 'cmd.exe' 'cmd.exe /c npx -y @other/mcp-server')))
# Panel review (HIMMEL-1328, codex-2): the package name is the LEADING
# positional argument in uvx/npx CLI convention, not the trailing one - a
# server invoked with its OWN positional/flag args after the package name
# must still resolve to the package, not to that trailing argument.
$UVX_WITH_ARGS = '"' + $UserHomeFwd + '/.local/bin/uvx.exe" mcp-obsidian --extra positional-project-name'
Check 'uvx package with a trailing positional arg still identifies as the package' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' $UVX_WITH_ARGS)) -eq 'mcp-obsidian') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' $UVX_WITH_ARGS))"
# Codex adversarial review, round 5 (HIMMEL-1328): a value-taking flag's own
# VALUE (not the flag name itself) survived the filter, so `uvx --python
# 3.12 server-a` and `uvx --python 3.12 server-b` both resolved to `3.12` -
# reproduced directly before fixing. A bare version-number-shaped token is
# now excluded (a package is never itself named e.g. `3.12`).
Check 'uvx --python <version> <package> resolves to the package, not the version' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --python 3.12 server-a')) -eq 'server-a') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --python 3.12 server-a'))"
Check 'two DIFFERENT packages behind the same --python version are NOT grouped together' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --python 3.12 server-a')) -ne (Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --python 3.12 server-b')))
# Codex adversarial review, round 6 (HIMMEL-1328): the SAME class of bug,
# generalized - any value-taking flag (not just --python) leaves its value
# as the mistaken identity. `uvx --from ./local-pkg mcp-server` resolved to
# `./local-pkg` - reproduced directly before fixing. The walk now skips a
# KNOWN value-taking flag's value along with the flag itself.
Check 'uvx --from <path> <package> resolves to the package, not the --from value' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --from ./local-pkg mcp-server')) -eq 'mcp-server') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --from ./local-pkg mcp-server'))"
Check 'uvx --with <path> <package> resolves to the package, not the --with value' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --with ./extra-dep mcp-server')) -eq 'mcp-server') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --with ./extra-dep mcp-server'))"
Check 'a boolean/unknown flag (e.g. -y) is still skipped without consuming a value' ((Get-ServerIdentity -Proc (Rec 1 0 'npx.exe' 'npx.exe -y mcp-server')) -eq 'mcp-server') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'npx.exe' 'npx.exe -y mcp-server'))"
# CodeRabbit App review, HIMMEL-1328: the raw-token split (`-split '["\s]+'`)
# splits on quotes AND whitespace, so a QUOTED, space-containing value for a
# value-taking flag fragments into multiple tokens - the `$i += 2` skip only
# consumes the first fragment, leaving the rest to reach the candidate filter
# and get mistaken for the identity. `uvx --with "some dir" mcp-server` must
# still resolve to `mcp-server`, not to the leaked `dir` fragment.
Check 'uvx --with "<quoted value with a space>" <package> resolves to the package, not a leaked fragment of the value' ((Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --with "some dir" mcp-server')) -eq 'mcp-server') "got=$(Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --with "some dir" mcp-server'))"

Write-Host "Test 5d: broker's multiple live app-servers are never flagged as duplicates (Test-AppServerSupervisor excludes the broker)"
$brokerOnly = @(
  (Rec 90  1  'node.exe'  $BROKER)
  (Rec 991 90 'codex.exe' 'codex.exe app-server')
  (Rec 992 90 'codex.exe' 'codex.exe app-server')
)
$brokerDupGroups = @(Get-DuplicateFleets -Procs $brokerOnly)
Check 'broker with 2 live app-servers yields 0 duplicate groups' ($brokerDupGroups.Count -eq 0) "got=$($brokerDupGroups.Count)"

Write-Host "Test 5e: empty input yields no duplicate groups (no throw)"
$emptyDup = @(Get-DuplicateFleets -Procs @())
Check 'empty input -> 0 duplicate groups' ($emptyDup.Count -eq 0)

# Panel + codex adversarial review (HIMMEL-1328): a bare `cmd.exe` (or other
# generic shell wrapper) child that is NOT wrapping npx has no identity more
# specific than its own Name - grouping repeats of it as a "duplicate MCP
# server" would be a false positive with no real server behind it. Two such
# processes must be EXCLUDED from grouping entirely, not lumped together.
Write-Host "Test 5f: bare (non-npx) cmd.exe/powershell.exe children are excluded from grouping - never reported as a false-positive duplicate"
Check 'bare cmd.exe (not wrapping npx) has no resolved identity' ($null -eq (Get-ServerIdentity -Proc (Rec 1 0 'cmd.exe' 'cmd.exe /c dir')))
Check 'bare powershell.exe has no resolved identity' ($null -eq (Get-ServerIdentity -Proc (Rec 1 0 'powershell.exe' 'powershell.exe -Command Get-Process')))
$shellNoiseProcs = @(
  (Rec 993 90 'codex.exe' 'codex.exe app-server')
  (Rec 1031 993 'cmd.exe' 'cmd.exe /c dir')          # NOT npx - unidentified, must be excluded
  (Rec 1032 993 'cmd.exe' 'cmd.exe /c dir')          # a 2nd one - still must NOT form a duplicate group
  (Rec 1033 993 'bun.exe' "bun $BUN_LUNA")           # a REAL duplicate must still be caught alongside the noise
  (Rec 1034 993 'bun.exe' "bun $BUN_LUNA")
)
$shellNoiseGroups = @(Get-DuplicateFleets -Procs $shellNoiseProcs)
Check 'bare cmd.exe pair produces 0 groups for it (false positive avoided)' (-not ($shellNoiseGroups | Where-Object { $_.Identity -eq 'cmd.exe' }))
# CodeRabbit round 5 (HIMMEL-1328): the per-identity checks below name the
# identities they expect, so a regression that leaked an EXTRA group under a
# $null or otherwise unforeseen identity would satisfy every one of them. Only
# asserting the TOTAL group set closes that - it names no identity, so it
# rejects a leak this fixture never anticipated.
Check 'only the real shell-noise group remains (no leaked $null/other identity)' ($shellNoiseGroups.Count -eq 1) "groups got=$($shellNoiseGroups.Count)"
# Assert group cardinality (exactly one group) and member count (both
# instances) SEPARATELY. `.Count` on the filtered pipeline collapsed two
# meanings - one group whose own .Count is 2, vs an array of two singletons -
# so a grouping regression to one-group-per-process would still read 2 and
# pass for the wrong reason. Materialise first, then check both independently.
$lunaShellNoiseGroups = @($shellNoiseGroups | Where-Object { $_.Identity -eq 'luna-correlate' })
$shellNoiseMembers = if ($lunaShellNoiseGroups.Count -ge 1) { $lunaShellNoiseGroups[0].Count } else { 0 }
Check 'the real luna-correlate duplicate is still caught alongside the excluded noise' ($lunaShellNoiseGroups.Count -eq 1) "groups got=$($lunaShellNoiseGroups.Count)"
Check 'that luna-correlate group holds both duplicate instances' ($lunaShellNoiseGroups.Count -eq 1 -and $shellNoiseMembers -eq 2) "members got=$shellNoiseMembers"

# Panel review, round 2 (glm-3, HIMMEL-1328): a GENERIC language-runtime
# launcher (node.exe/bun.exe/uvx.exe/npx.exe) whose command line does NOT
# resolve to a more specific identity (no plugin-cache path match; a
# uvx/npx invocation with no extractable package token) says nothing about
# what it is running - same false-positive risk as the shell wrappers above.
Write-Host "Test 5g: a bare node.exe/bun.exe (no plugin-cache path) or a token-less uvx.exe has no resolved identity - excluded from grouping"
Check 'bare bun.exe (no plugin-cache path) has no resolved identity' ($null -eq (Get-ServerIdentity -Proc (Rec 1 0 'bun.exe' 'bun.exe run /some/other/script.ts')))
Check 'bare node.exe has no resolved identity' ($null -eq (Get-ServerIdentity -Proc (Rec 1 0 'node.exe' 'node.exe /some/other/script.js')))
Check 'uvx.exe with zero extractable tokens has no resolved identity' ($null -eq (Get-ServerIdentity -Proc (Rec 1 0 'uvx.exe' 'uvx.exe --help')))
$runtimeNoiseProcs = @(
  (Rec 994 90 'codex.exe' 'codex.exe app-server')
  (Rec 1041 994 'bun.exe' 'bun.exe run /project-a/build.ts')   # different script - must NOT be lumped with the one below
  (Rec 1042 994 'bun.exe' 'bun.exe run /project-b/build.ts')   # a DIFFERENT unrelated bun invocation
  (Rec 1043 994 'bun.exe' "bun $BUN_LUNA")                     # a REAL duplicate must still be caught
  (Rec 1044 994 'bun.exe' "bun $BUN_LUNA")
)
$runtimeNoiseGroups = @(Get-DuplicateFleets -Procs $runtimeNoiseProcs)
Check 'bare bun.exe pair (different scripts) produces 0 false-positive group' (-not ($runtimeNoiseGroups | Where-Object { $_.Identity -eq 'bun.exe' }))
# Same total-set guard as the shell-noise fixture above (CodeRabbit round 5).
Check 'only the real runtime-noise group remains (no leaked $null/other identity)' ($runtimeNoiseGroups.Count -eq 1) "groups got=$($runtimeNoiseGroups.Count)"
$lunaRuntimeNoiseGroups = @($runtimeNoiseGroups | Where-Object { $_.Identity -eq 'luna-correlate' })
$runtimeNoiseMembers = if ($lunaRuntimeNoiseGroups.Count -ge 1) { $lunaRuntimeNoiseGroups[0].Count } else { 0 }
Check 'the real luna-correlate duplicate is still caught alongside the excluded runtime noise' ($lunaRuntimeNoiseGroups.Count -eq 1) "groups got=$($lunaRuntimeNoiseGroups.Count)"
Check 'that luna-correlate group holds both duplicate instances' ($lunaRuntimeNoiseGroups.Count -eq 1 -and $runtimeNoiseMembers -eq 2) "members got=$runtimeNoiseMembers"

# Codex adversarial review, round 4 (HIMMEL-1328): Windows does not clear a
# process's recorded ParentProcessId when its true parent exits, so a
# long-dead-parent process whose PPID happens to alias onto a FRESHLY
# started supervisor's newly-assigned pid (pid reuse) could otherwise be
# miscounted as that supervisor's child, inflating a duplicate group with a
# phantom instance. Mirrors reap-superseded-fleets.ps1's
# Select-VerifiedDescendants convention (2s creation-time tolerance).
Write-Host "Test 5h: a child whose CreationDate predates the supervisor's own (stale PPID / pid reuse) is excluded from grouping"
$now = Get-Date
$staleProcs = @(
  (Rec 995 90 'codex.exe' 'codex.exe app-server')
)
$staleProcs[0] | Add-Member -NotePropertyName CreationDate -NotePropertyValue $now -Force
$staleChild1 = Rec 1051 995 'bun.exe' "bun $BUN_LUNA"
$staleChild1 | Add-Member -NotePropertyName CreationDate -NotePropertyValue $now.AddMinutes(1) -Force   # genuinely spawned AFTER the supervisor
$staleChild2 = Rec 1052 995 'bun.exe' "bun $BUN_LUNA"
$staleChild2 | Add-Member -NotePropertyName CreationDate -NotePropertyValue $now.AddMinutes(-30) -Force  # predates the supervisor - stale PPID, not a real child
$staleProcs += $staleChild1, $staleChild2
$staleGroups = @(Get-DuplicateFleets -Procs $staleProcs)
Check 'stale-PPID child excluded - only 1 verified child remains, so no duplicate group forms' (-not ($staleGroups | Where-Object { $_.Identity -eq 'luna-correlate' })) "got=$($staleGroups.Count) group(s)"

Write-Host "Test 5i: CreationDate check is best-effort - a fixture with no CreationDate at all (existing tests) is unaffected, and a genuine duplicate both created just now still groups"
$freshChild1 = Rec 1061 995 'bun.exe' "bun $BUN_LUNA"
$freshChild1 | Add-Member -NotePropertyName CreationDate -NotePropertyValue $now.AddSeconds(1) -Force
$freshChild2 = Rec 1062 995 'bun.exe' "bun $BUN_LUNA"
$freshChild2 | Add-Member -NotePropertyName CreationDate -NotePropertyValue $now.AddSeconds(2) -Force
$freshGroups = @(Get-DuplicateFleets -Procs @($staleProcs[0], $freshChild1, $freshChild2))
$lunaFreshGroups = @($freshGroups | Where-Object { $_.Identity -eq 'luna-correlate' })
$freshMembers = if ($lunaFreshGroups.Count -ge 1) { $lunaFreshGroups[0].Count } else { 0 }
Check 'two genuinely-post-supervisor children still form a duplicate group' ($lunaFreshGroups.Count -eq 1) "groups got=$($lunaFreshGroups.Count)"
Check 'that luna-correlate group holds both duplicate instances' ($lunaFreshGroups.Count -eq 1 -and $freshMembers -eq 2) "members got=$freshMembers"

# --- HIMMEL-840: Get-DescendantPids (codex-exec CLI sandbox fleet) -----------
# The codex-exec CLI sandbox spawns npx/node MCP servers under a cmd.exe
# wrapper with NO codex path marker of their own once codex.exe is gone -
# structurally invisible to Test-CodexOwned/Get-OrphanFleet above. The ONLY
# way to identify them is the descendant-of-a-registered-root-pid walk this
# primitive performs (dispatch-codex-exec.sh registers the codex child's pid
# right after launch and calls this on its own EXIT).
Write-Host "Test 6: codex-exec CLI sandbox fleet (dead registered root) reaped via descendant walk; a live-claude MCP fleet (same table, same process shapes) is spared"
$sandboxProcs = @(
  # dead codex-exec CLI root (pid 500) - ALREADY GONE from the table (simulates
  # 'codex_pid dead': dispatch-codex-exec.sh's own child already exited).
  (Rec 501 500 'cmd.exe'  'cmd.exe /c npx @upstash/context7-mcp')          # direct child of dead root -> descendant
  (Rec 502 501 'node.exe' 'node C:\...\npx-cli.js @upstash/context7-mcp')  # grandchild, no codex marker -> descendant
  (Rec 503 502 'node.exe' 'node mcp-server.js')                            # great-grandchild -> descendant

  # live-claude session's OWN MCP servers - siblings under a DIFFERENT, LIVE
  # parent (pid 700), same process shapes (cmd.exe/npx, node) as the sandbox
  # fleet above. They must be spared because they are not descendants of 500,
  # not because they look different.
  (Rec 700 1   'node.exe' 'node claude cli')                               # live claude parent
  (Rec 701 700 'node.exe' 'node qmd-mcp-server.js')                        # live sibling MCP
  (Rec 702 700 'cmd.exe'  'cmd.exe /c npx @some/other-mcp')                # live sibling MCP, same shape as 501
)
$descPids = @(Get-DescendantPids -Procs $sandboxProcs -RootPid 500)
$gotDescPids = @($descPids | Sort-Object)
Check 'sandbox fleet {501,502,503} found via descendant walk' (($gotDescPids -join ',') -eq '501,502,503') "got=$($gotDescPids -join ',')"
Check 'live-claude MCP 701 spared (not a descendant of 500)' (-not ($gotDescPids -contains 701))
Check 'live-claude MCP 702 spared (same process shape as 501, still not a descendant)' (-not ($gotDescPids -contains 702))
Check 'dead root pid 500 itself is not returned (only its descendants)' (-not ($gotDescPids -contains 500))

Write-Host "Test 7: StartedAt >= CreationDate pid-reuse guard"
$now = Get-Date
$reused = @(
  (Rec 511 510 'cmd.exe' 'cmd.exe /c npx old-unrelated-mcp')  # created well before our job started
)
$reused[0] | Add-Member -NotePropertyName CreationDate -NotePropertyValue ($now.AddMinutes(-60)) -Force
$jobStartedEpoch = [long][DateTimeOffset]::new($now.ToUniversalTime()).ToUnixTimeSeconds()
$descGuarded = @(Get-DescendantPids -Procs $reused -RootPid 510 -StartedAtEpoch $jobStartedEpoch)
Check 'guard excludes a descendant that predates StartedAt (pid-reuse)' ($descGuarded.Count -eq 0) "got count=$($descGuarded.Count)"
$descUnguarded = @(Get-DescendantPids -Procs $reused -RootPid 510)
Check 'without StartedAt the same descendant IS found' ($descUnguarded.Count -eq 1 -and $descUnguarded[0] -eq 511)

Write-Host "Test 8: empty/absent-root inputs do not throw"
$emptyDesc = @(Get-DescendantPids -Procs @() -RootPid 999)
Check 'empty proc table -> 0 descendants' ($emptyDesc.Count -eq 0)
$noChildren = @(Get-DescendantPids -Procs $sandboxProcs -RootPid 999999)
Check 'root pid with no children in the table -> 0 descendants' ($noChildren.Count -eq 0)

Write-Host "Test 9: malformed argv - missing value for -RootPid/-StartedAt fails fast (no hang)"
# The .sh twin's option-parsing loop had a `shift 2` no-op bug (HIMMEL-840
# Fix 2) that spun forever on a missing value; PowerShell's own typed-param
# binding already fails fast on this, but the coverage closes the parity gap
# on both twins. Invokes the real script as a genuine subprocess (never the
# dot-sourced -AsLibrary functions) so a regression would show up as an
# actual hang, not just an in-process exception. Stdin is redirected from an
# empty file so a would-be interactive prompt gets immediate EOF instead of
# blocking.
function Test-FailsFast([string[]]$ExtraArgs, [string]$Name) {
  $inFile = [System.IO.Path]::GetTempFileName()
  $outFile = [System.IO.Path]::GetTempFileName()
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Helper) + $ExtraArgs
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $psArgs `
      -NoNewWindow -PassThru -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $finished = $proc.WaitForExit(10000)
    if (-not $finished) {
      try { $proc.Kill() } catch {}
      Fail $Name 'timed out after 10s (hang)'
    } else {
      Check $Name ($proc.ExitCode -ne 0) "exit=$($proc.ExitCode)"
    }
  } finally {
    Remove-Item -Path $inFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}
Test-FailsFast @('-RootPid') 'missing -RootPid value fails fast (no hang)'
Test-FailsFast @('-RootPid', '123', '-StartedAt') 'missing -StartedAt value fails fast (no hang)'

Write-Host "Results: $Pass passed, $Fail failed"
if ($Fail -ne 0) { exit 1 }
exit 0
