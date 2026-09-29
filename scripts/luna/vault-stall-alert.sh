#!/usr/bin/env bash
# scripts/luna/vault-stall-alert.sh — the operator alert sink for the luna
# vault's auto-commit STALL (HIMMEL-3851).
#
# vault-autosync.sh (templates/luna-second-brain/scripts/) is generic and ships
# to the public luna-brain repo, so it carries no Telegram code: it calls the
# executable named by LUNA_VAULT_ALERT_CMD with one argument, the message. Point
# that at this script and the alert rides the SAME path every other operator DM
# uses (merge-block-alert.sh -> console-route.ts reply -> the bridge outbox).
#
#   LUNA_VAULT_ALERT_CMD=<repo>/scripts/luna/vault-stall-alert.sh
#
#   vault-stall-alert.sh <message...>
#
# Exit 0 = delivered; non-zero = not delivered (autosync then retries next run
# instead of marking the stall episode alerted). Seams are merge-block-alert.sh's
# own: MERGE_BLOCK_ALERT_CMD (replaces the sender, `$CMD <chat_id> <text>`) and
# TELEGRAM_ACCESS_PATH (access.json holding the operator id).
set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/merge-block-alert.sh
. "$_here/../lib/merge-block-alert.sh"

msg="$*"
if [ -z "$msg" ]; then
    echo "vault-stall-alert: no message given" >&2
    exit 2
fi

chat="$(_mba_operator_chat)" || chat=""
if [ -z "$chat" ]; then
    echo "vault-stall-alert: no operator chat id readable - not delivered" >&2
    exit 1
fi
_mba_send "$chat" "$msg" || {
    echo "vault-stall-alert: delivery failed" >&2
    exit 1
}
