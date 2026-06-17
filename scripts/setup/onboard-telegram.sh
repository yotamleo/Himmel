#!/usr/bin/env bash
# onboard-telegram.sh — Telegram-bridge onboarding for a fresh machine
# (HIMMEL-227; Warp split out into onboard-warp.sh per HIMMEL-360). Called from
# scripts/setup.sh as the onboarding step; also safe to run standalone:
#   bash scripts/setup/onboard-telegram.sh
#
# SCAFFOLD-ONLY, by design:
#   - Creates ~/.claude/channels/telegram/ and a TELEGRAM_BOT_TOKEN .env
#     template if missing. Never overwrites an existing .env.
#   - NEVER writes access.json. Pairing is operator-managed: the allowlist is
#     a prompt-injection surface, and the live bridge must be restarted BY THE
#     OPERATOR after any access.json change. This script only reports presence
#     and prints the pairing instructions.
#   - NEVER starts or stops the bridge process. Telegram allows exactly one
#     getUpdates consumer per token — a blind start from setup could
#     409-conflict a live poller (see docs/internals/telegram-bridge.md).
#
# Env overrides (tests):
#   TELEGRAM_CHANNEL_DIR — default $HOME/.claude/channels/telegram
#
# Exit codes:
#   0 — ok (a missing token / missing pairing is EXPECTED on a fresh machine:
#       reported as a next-step, not failed on)
#   1 — hard failure (cannot create the channel dir / write the .env template)
set -uo pipefail

CHANNEL_DIR="${TELEGRAM_CHANNEL_DIR:-$HOME/.claude/channels/telegram}"

echo "-- Telegram bridge onboarding (scaffold-only) --"

# 1. channel dir
if ! mkdir -p "$CHANNEL_DIR"; then
  echo "ERR onboard-telegram: cannot create $CHANNEL_DIR" >&2
  exit 1
fi
echo "  channel dir: $CHANNEL_DIR"

# 2. .env (bot token) — template if absent; never touched if present
if [ -f "$CHANNEL_DIR/.env" ]; then
  if grep -qE '^TELEGRAM_BOT_TOKEN=..*' "$CHANNEL_DIR/.env" 2>/dev/null; then
    echo "  .env: present (token set)"
  else
    echo "  .env: present but TELEGRAM_BOT_TOKEN is empty — fill it (token from @BotFather)"
  fi
else
  if ! cat > "$CHANNEL_DIR/.env" <<'ENV_TMPL'
# Telegram bot token for the himmel bun bridge
# (see docs/internals/telegram-bridge.md). Get one from @BotFather, then fill:
TELEGRAM_BOT_TOKEN=
ENV_TMPL
  then
    echo "ERR onboard-telegram: cannot write $CHANNEL_DIR/.env" >&2
    exit 1
  fi
  echo "  .env: created template — fill TELEGRAM_BOT_TOKEN before starting the bridge"
fi

# 3. access.json — REPORT ONLY. Operator-managed; this script never writes it.
if [ -f "$CHANNEL_DIR/access.json" ]; then
  echo "  access.json: present (pairing configured)"
else
  echo "  access.json: MISSING — pairing is an operator step (never written by setup):"
  echo "    create $CHANNEL_DIR/access.json with:"
  echo '      {"allowFrom":["<your-telegram-user-id>"]}'
  echo "    The allowlist is an injection surface; restart the bridge yourself after edits."
fi

# 4. bun (bridge runtime)
if command -v bun >/dev/null 2>&1; then
  echo "  bun: $(bun --version 2>/dev/null || echo present)"
else
  echo "  bun: MISSING — bridge runtime. Install: https://bun.sh"
fi

# 5. bridge bring-up — documented, never executed here (single-poller rule)
echo "  bridge bring-up (run yourself once token + pairing are in place):"
echo "    Windows:     pwsh -File scripts/telegram/restart-bridge.ps1"
echo "    Linux/macOS: (cd scripts/telegram && bun supervisor.ts)"
echo "    reboot persistence (optional logon task): scripts/telegram/README.md"

exit 0
