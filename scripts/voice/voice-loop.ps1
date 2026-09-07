<#
.SYNOPSIS
  Hands-free turn: speak, a Claude run answers, the answer is spoken back.

.DESCRIPTION
  Closes the loop without any pasting or window focus:

      mic -> whisper.cpp -> claude -> speech daemon -> speakers

  This spawns its OWN Claude conversation rather than feeding your open TUI
  session, so it has no access to whatever that session is mid-way through.
  -Continue carries context across voice turns.

  Billing: uses the INTERACTIVE `claude "<prompt>"` form with stdin ignored,
  the same shape the Telegram bridge uses. Deliberately not `-p`/`--print`,
  which bills to a separate bucket and is blocked by the HIMMEL-128 gate.

  Expect ~10-30s per turn. That is Claude's cold start, not the voice layer --
  synthesis is ~1s and transcription is a few hundred ms. Keeping a session
  warm is the only thing that fixes it, and is not solved here.

.EXAMPLE
  .\voice-loop.ps1
  .\voice-loop.ps1 -Continue -Voice myvoice
  .\voice-loop.ps1 -Repeat          # keep taking turns until Ctrl+C
#>
[CmdletBinding()]
param(
    [string]$Voice,
    [string]$Model = $(if ($env:VOICE_CLAUDE_MODEL) { $env:VOICE_CLAUDE_MODEL } else { 'sonnet' }),
    [switch]$Continue,
    [switch]$Repeat,
    # `plan` is the ONLY accepted value, and there is no env override (codex-2,
    # glm-5). The previous version claimed a "structural plan floor" while
    # offering acceptEdits/dontAsk on the command line and any string via an env
    # var — a floor you can opt out of is not a floor, it is a default. Until an
    # action classifier exists to enforce voice-policy.json properly, widening
    # this requires EDITING this file: a deliberate, reviewable act rather than
    # a flag someone reaches for mid-session.
    [ValidateSet('plan')]
    [string]$PermissionMode = 'plan',
    [int]$Port = $(if ($env:VOICE_PORT) { [int]$env:VOICE_PORT } else { 8788 })
)

$ErrorActionPreference = 'Stop'

# claude emits UTF-8; PowerShell decodes native output using the console code
# page, which on Windows is cp1252. Without this an em-dash arrives as "ÔÇö" --
# visible in the transcript AND handed to the TTS, which then tries to say it.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# The spawned session does not know it is being spoken to. Told nothing, it
# answers like a terminal session -- long, markdown-formatted, and insisting it
# has no audio input (true, but useless here: it is handed a transcript).
# This is where "brief, and you can always ask for more" is actually enforced.
$voiceSystemPrompt = @'
You are answering over a VOICE channel. The message you receive is a
speech-to-text transcript of someone talking to you, and your reply is read
aloud by a text-to-speech engine.

- Answer in one to three sentences of plain spoken prose.
- No markdown, no bullet lists, no code blocks, no URLs, no emoji. They are
  read aloud literally and are unusable in speech.
- Lead with the answer. Offer detail rather than delivering it: end with a
  short offer like "want the detail?" when there is more to say.
- The transcript may contain speech-recognition errors. If a request is
  ambiguous because of a likely mishearing, ask a brief clarifying question
  instead of guessing.
- Never say you cannot hear or have no audio input. You are receiving a
  transcript of speech; that is the channel working as designed.
'@

$py     = Join-Path $HOME '.himmel\voice\venv\Scripts\python.exe'
$ptt    = Join-Path $PSScriptRoot 'push-to-talk.py'
$daemon = "http://127.0.0.1:$Port"

function Test-Daemon {
    try   { $null = Invoke-RestMethod -Uri "$daemon/health" -TimeoutSec 3; return $true }
    catch { return $false }
}

function Wait-ForSilence([int]$TimeoutSec = 120) {
    <#
      Block until the daemon has finished speaking.

      Without this the loop re-opens the mic while the reply is still playing.
      The speakers are in the same room as the microphone, so the assistant's
      own voice is captured and submitted as the operator's next message —
      it talks to itself, and with -Continue that nonsense enters the context.

      /speak returns 202 as soon as the job is queued, so we first wait for
      playback to START (synthesis takes ~1s) and only then wait for it to end.
      Polling only for "not speaking" would pass instantly, before a sound.
    #>
    $begin    = Get-Date
    $deadline = $begin.AddSeconds($TimeoutSec)
    $started  = $false
    $healthFails = 0
    while ((Get-Date) -lt $deadline) {
        # A transient /health blip must not abandon the guard. `catch { return }`
        # returned instantly on ONE failed poll, skipping both the wait and the
        # settle below — so the mic reopened mid-reply and the assistant recorded
        # itself, which is the exact failure this function exists to prevent.
        # Tolerate a few consecutive failures, then give up via `break` so the
        # settle sleep still runs.
        try {
            $h = Invoke-RestMethod -Uri "$daemon/health" -TimeoutSec 3
            $healthFails = 0
        } catch {
            $healthFails++
            if ($healthFails -ge 3) { break }
            Start-Sleep -Milliseconds 150
            continue
        }
        if ($h.speaking) {
            $started = $true
        } elseif ($started) {
            break                                   # started and now finished
        } elseif (((Get-Date) - $begin).TotalSeconds -gt 20) {
            # Never started within 20s. Returning here is NOT enough (CR round 7,
            # [codex-1]): synthesis may still be in flight — a cold model load is
            # the normal way to exceed 20s — and it would then play into the mic
            # this function is about to reopen. That is precisely the self-capture
            # described above, arriving by the one path that skipped the guard.
            # Cancel the job before returning: /stop bumps the daemon's generation
            # counter, and a job whose generation is stale never plays at all.
            try { Invoke-RestMethod -Uri "$daemon/stop" -Method Post -TimeoutSec 3 | Out-Null } catch { }
            break
        }
        Start-Sleep -Milliseconds 150
    }
    # Let the room settle so the tail of the reply is not caught by the mic.
    Start-Sleep -Milliseconds 400
}

function Invoke-Speak([string]$Text) {
    $payload = @{ text = $Text }
    if ($Voice) { $payload.voice = $Voice }
    try {
        Invoke-RestMethod -Uri "$daemon/speak" -Method Post -TimeoutSec 15 `
            -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Compress) | Out-Null
    } catch {
        Write-Warning "speech daemon unreachable: $_"
    }
}

if (-not (Test-Daemon)) {
    Write-Warning "No speech daemon on $daemon - the answer will print but not be spoken."
    Write-Host   "  start it:  & '$py' '$(Join-Path $PSScriptRoot 'speech-daemon.py')'" -ForegroundColor DarkGray
}

$logPath = Join-Path $HOME '.himmel\voice\loop.log'
$errLog  = Join-Path $HOME '.himmel\voice\claude-stderr.log'
# This log holds spoken transcripts and full replies, i.e. whatever was said in
# the room. Unbounded, it becomes an indefinite record of that. Bounded in both
# directions: each entry is truncated, and the file rotates at 1 MB keeping one
# previous generation, so retention stays roughly a few thousand recent turns
# instead of forever. Deleting both files is safe at any time.
$LogMaxChars = 300
$LogMaxBytes = 1MB
function Write-Log([string]$Stage, [string]$Text) {
    $flat = ($Text -replace "`r?`n", ' ')
    if ($flat.Length -gt $LogMaxChars) {
        $flat = $flat.Substring(0, $LogMaxChars) + "...[truncated $($flat.Length - $LogMaxChars) chars]"
    }
    try {
        $existing = Get-Item -LiteralPath $logPath -ErrorAction Stop
        if ($existing.Length -gt $LogMaxBytes) {
            Move-Item -LiteralPath $logPath -Destination "$logPath.1" -Force -ErrorAction Stop
        }
    } catch { }   # no log yet, or rotation lost a race -- neither is worth failing a turn over
    $line = "{0}`t{1}`t{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Stage, $flat
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}
Write-Host "log: $logPath" -ForegroundColor DarkGray

# VOICE-OWNED SESSION (CR round 6, [codex-adv-3]). `-Continue` used to pass
# claude's bare `--continue`, which resumes the most recent conversation IN THIS
# DIRECTORY -- not necessarily a voice one. On the first voice turn, or any time
# a typed session ran between turns, an unauthenticated speaker would resume the
# OPERATOR's session and could have its context summarized aloud. Note what that
# defeats: no file is read on that path, so every read-side deny in
# voice-permissions.json is simply irrelevant to it. The loop now owns a UUID
# and resumes only that exact session.
#
# Deliberate consequence: -Continue now carries context across turns of THIS
# invocation, not across separate runs of the script. Directory-global
# continuation is the vulnerability, so it is not coming back.
$voiceSessionId = [guid]::NewGuid().ToString()
$voiceSessionStarted = $false

do {
    # 1. LISTEN.
    #
    # The recorder's own progress goes to stderr, which is suppressed here so it
    # cannot contaminate the transcript on stdout. That silence made the script
    # look hung while it was simply waiting to be spoken to, so the prompt and
    # the beep are OURS -- without them there is no sign anything is happening.
    # No beep here on purpose. The audible cue is emitted by push-to-talk.py
    # once the mic stream is open and settled — beeping from this side fired
    # before python had even imported, so the first word was spoken into a
    # device that was not yet listening.
    Write-Host ''
    Write-Host '  [starting capture]' -ForegroundColor DarkGray

    # Run the recorder with a PLAIN inherited console — no pipe, no stderr
    # redirect — and collect the transcript from a file.
    #
    # Piping its stdout was what broke ENTER-to-send: a piped child gets console
    # handles the keyboard check cannot poll. It also hid the "listening" prompt,
    # which lives on the stderr the pipe discarded. Both problems disappear once
    # the result comes back through a file instead of the pipeline.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ptt-" + [Guid]::NewGuid().ToString('N') + ".txt")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # Bare call: ANY pipeline here (even | Out-Null) re-creates the redirected
    # console that broke ENTER in the first place. With --out, stdout carries
    # nothing anyway and stderr shows the prompts.
    & $py $ptt --out $tmp
    $sw.Stop()
    $said = if (Test-Path $tmp) { (Get-Content -LiteralPath $tmp -Raw -Encoding utf8).Trim() } else { '' }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

    if (-not $said) {
        Write-Host '  nothing heard' -ForegroundColor DarkGray
        Write-Log 'empty' ''
        if ($Repeat) { continue } else { exit 1 }
    }
    Write-Host "you: $said" -ForegroundColor Cyan
    Write-Log 'heard' "($([int]$sw.Elapsed.TotalSeconds)s) $said"

    # 2. ASK. Interactive form, stdin ignored so it cannot block waiting on input.
    # Voice runs in `plan` permission mode (HIMMEL-1522) — same reasoning as
    # jarvis.py: voice-policy.json's deny tier was documented but not enforced,
    # and full enforcement needs an action classifier (ticketed). `plan` makes
    # the harness itself refuse writes, so the deny tier holds now. Stricter
    # than the policy on purpose: an unauthenticated channel should fail toward
    # "cannot act". Widening it means EDITING this file: -PermissionMode is
    # [ValidateSet('plan')], so every other value is a parse error, not an
    # override (glm-3 — this comment used to promise an override the parameter
    # does not offer).
    # --strict-mcp-config with NO --mcp-config = zero MCP servers (CR round 6,
    # [codex-adv-1]). A bare `claude` inherits the user/project MCP fleet, and an
    # MCP tool is not Read/Bash/Grep -- so NO pattern in voice-permissions.json
    # can reach it. Probed: a voice spawn without this flag reported
    # `mcp__tokensave__tokensave_read` available, a file reader entirely outside
    # the deny tier. A read-side control is only as good as the set of tools it
    # can name, and MCP tools are named by the server, not by us.
    $claudeArgs = @('--model', $Model, '--permission-mode', $PermissionMode, '--strict-mcp-config')
    # plan mode covers WRITES; this settings profile covers READS (secrets,
    # salus) — the policy's `hard` rules are all read-side, so plan mode alone
    # left them inert.
    # FAIL CLOSED, same reasoning as jarvis.py: warning and continuing is
    # fail-OPEN on a security control, and this loop suppresses stderr anyway,
    # so the warning nobody sees was the only thing standing between a spoken
    # request and a credential read aloud.
    $voiceSettings = Join-Path $PSScriptRoot 'voice-permissions.json'
    if (-not (Test-Path $voiceSettings)) {
        throw "voice-permissions.json missing at $voiceSettings - refusing to run a voice session without the read-side denies"
    }
    $claudeArgs += @('--settings', $voiceSettings)
    $claudeArgs += @('--append-system-prompt', $voiceSystemPrompt)
    if ($Continue) {
        # Resume ONLY this loop's own session -- never claude's directory-global
        # `--continue`. First turn creates it; later turns resume it by id.
        if ($voiceSessionStarted) { $claudeArgs += @('--resume', $voiceSessionId) }
        else                      { $claudeArgs += @('--session-id', $voiceSessionId) }
    }
    # `--` terminates option parsing (CR round 6, [codex-1]). The transcript is
    # attacker-influenced text on the SAME argv that carries the permission
    # floor: without the terminator a transcript starting `--permission-mode` or
    # `--settings` is parsed as a flag rather than as the prompt. Whisper
    # emitting a literal `--flag` is unlikely, but this channel cannot
    # authenticate its speaker and the fix is one token.
    $claudeArgs += '--'
    $claudeArgs += $said

    # A cold claude start is 10-30s of total silence. Say so, or this looks
    # hung too -- the same failure the LISTENING prompt above exists to prevent.
    Write-Host "  [THINKING] $Model, cold start is 10-30s..." -ForegroundColor DarkGray
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # Pipe $null rather than `< $null`: PowerShell has no '<' redirection
    # operator (it is reserved and fails to parse). An empty pipeline gives the
    # child a closed stdin, which is what stops claude waiting on input.
    # claude's stderr goes to the LOG, not to $null (glm-3). Discarding it meant
    # that when a turn came back empty the operator saw only "claude returned
    # nothing" — with the permission refusal or startup error that explained it
    # thrown away. It must not reach stdout either, or the daemon would try to
    # pronounce it, hence a file rather than the console.
    # Rotate claude-stderr.log the same way loop.log rotates: at 1 MB keeping
    # one previous generation. The native `2>>` append below cannot bound
    # itself, so the cap is applied here, once per turn, before the next append.
    try {
        $errExisting = Get-Item -LiteralPath $errLog -ErrorAction Stop
        if ($errExisting.Length -gt $LogMaxBytes) {
            Move-Item -LiteralPath $errLog -Destination "$errLog.1" -Force -ErrorAction Stop
        }
    } catch { }   # no log yet, or rotation lost a race -- neither fails a turn
    $reply = ($null | & claude @claudeArgs 2>>$errLog | Out-String)
    $sw.Stop()
    # Strip ANSI colour so the daemon does not try to pronounce escape codes.
    $reply = ([regex]::Replace($reply, "\x1b\[[0-9;?]*[a-zA-Z]", '')).Trim()

    # Only now is the session known to exist, so only now may a later turn
    # --resume it. Flipping this before the call would make the next turn resume
    # an id claude never created, if this one failed outright.
    if ($reply) { $voiceSessionStarted = $true }

    if (-not $reply) {
        Write-Warning 'claude returned nothing'
        Write-Log 'no-reply' "($([int]$sw.Elapsed.TotalSeconds)s)"
        if ($Repeat) { continue } else { exit 1 }
    }

    Write-Host "claude: $reply" -ForegroundColor Green
    Write-Log 'reply' "($([int]$sw.Elapsed.TotalSeconds)s) $reply"
    Write-Host '  [SPEAKING]' -ForegroundColor DarkGray

    # 3. SPEAK. The daemon normalises markdown/code and caps length itself, so
    #    the full text stays on screen while only a speakable version is heard.
    Invoke-Speak $reply

    # Mic and speakers share a room. Re-opening capture now would record the
    # reply and submit it as the next turn, so hold until playback is done.
    if ($Repeat) { Wait-ForSilence }

} while ($Repeat)
