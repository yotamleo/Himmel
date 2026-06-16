# onboard-telegram.ps1 — Telegram-bridge + Warp onboarding for a fresh machine
# (HIMMEL-227). PowerShell counterpart of onboard-telegram.sh; called from
# scripts/setup.ps1, also safe standalone:
#   pwsh -File scripts/setup/onboard-telegram.ps1
#
# SCAFFOLD-ONLY, by design (mirror of the bash sibling):
#   - Creates ~/.claude/channels/telegram/ and a TELEGRAM_BOT_TOKEN .env
#     template if missing. Never overwrites an existing .env.
#   - NEVER writes access.json (pairing is operator-managed: injection
#     surface + the live bridge must be operator-restarted after edits).
#   - NEVER starts or stops the bridge process (single getUpdates owner —
#     a blind start could 409-conflict a live poller).
#
# Env overrides (tests): $env:TELEGRAM_CHANNEL_DIR, $env:WARP_EXE
#
# Exit codes: 0 = ok (missing token/pairing is a reported next-step);
#             1 = hard failure (cannot create the channel dir / write the
#                 .env template).

[CmdletBinding()]
param()

$ChannelDir = if ($env:TELEGRAM_CHANNEL_DIR) { $env:TELEGRAM_CHANNEL_DIR }
              else { Join-Path $HOME '.claude\channels\telegram' }

Write-Host "-- Telegram bridge onboarding (scaffold-only) --"

# 1. channel dir
try {
    New-Item -ItemType Directory -Force $ChannelDir -ErrorAction Stop | Out-Null
} catch {
    Write-Error "onboard-telegram: cannot create ${ChannelDir}: $_"
    exit 1
}
Write-Host "  channel dir: $ChannelDir"

# 2. .env (bot token) — template if absent; never touched if present
$EnvFile = Join-Path $ChannelDir '.env'
if (Test-Path $EnvFile) {
    $hasToken = Select-String -Path $EnvFile -Pattern '^TELEGRAM_BOT_TOKEN=..*' -Quiet
    if ($hasToken) {
        Write-Host "  .env: present (token set)"
    } else {
        Write-Host "  .env: present but TELEGRAM_BOT_TOKEN is empty -- fill it (token from @BotFather)"
    }
} else {
    try {
        @'
# Telegram bot token for the himmel bun bridge
# (see docs/internals/telegram-bridge.md). Get one from @BotFather, then fill:
TELEGRAM_BOT_TOKEN=
'@ | Set-Content -NoNewline:$false -Path $EnvFile -ErrorAction Stop
    } catch {
        Write-Error "onboard-telegram: cannot write ${EnvFile}: $_"
        exit 1
    }
    Write-Host "  .env: created template -- fill TELEGRAM_BOT_TOKEN before starting the bridge"
}

# 3. access.json — REPORT ONLY. Operator-managed; this script never writes it.
$AccessFile = Join-Path $ChannelDir 'access.json'
if (Test-Path $AccessFile) {
    Write-Host "  access.json: present (pairing configured)"
} else {
    Write-Host "  access.json: MISSING -- pairing is an operator step (never written by setup):"
    Write-Host "    create $AccessFile with:"
    Write-Host '      {"allowFrom":["<your-telegram-user-id>"]}'
    Write-Host "    The allowlist is an injection surface; restart the bridge yourself after edits."
}

# 4. bun (bridge runtime)
if (Get-Command bun -ErrorAction SilentlyContinue) {
    $bunVer = & bun --version 2>$null
    Write-Host "  bun: $bunVer"
} else {
    Write-Host "  bun: MISSING -- bridge runtime. Install: https://bun.sh"
}

# 5. bridge bring-up — documented, never executed here (single-poller rule)
Write-Host "  bridge bring-up (run yourself once token + pairing are in place):"
Write-Host "    pwsh -File scripts/telegram/restart-bridge.ps1"
Write-Host "    reboot persistence (optional logon task, operator-run once):"
Write-Host "      pwsh -File scripts/telegram/install-logon-task.ps1"

Write-Host ""
Write-Host "-- Warp integration --"
Write-Host "  skills: /open-warp + /oz-offload are repo-local (.claude/commands/) -- ship with the clone"
Write-Host "  plugin: warp@claude-code-warp installs via scripts/machine-setup/install-plugins.ps1"
$WarpExe = if ($env:WARP_EXE) { $env:WARP_EXE }
           else { Join-Path $env:LOCALAPPDATA 'Programs\Warp\warp.exe' }
if (Get-Command warp -ErrorAction SilentlyContinue) {
    Write-Host "  warp binary: $((Get-Command warp).Source)"
} elseif (Test-Path $WarpExe) {
    Write-Host "  warp binary: $WarpExe"
} else {
    Write-Host "  warp binary: MISSING -- install from https://www.warp.dev (warp skills no-op without it)"
}

exit 0
