#!/usr/bin/env bash
# telegram-notification.sh — Claude Code Notification hook (HIMMEL-1250 Increment 1).
#
# Fires when Claude Code needs the operator's attention while unattended
# (a permission prompt, an idle-wait timeout, an AskUserQuestion / elicitation
# dialog). Fire-and-forget by contract (exit code ignored) — this hook mirrors
# that posture and additionally detaches so it never adds latency before the
# operator-facing prompt renders.
#
# Silent no-op (hard requirement): TELEGRAM_GROUP_CHAT_ID unset/blank -> exit
# 0, nothing sent.
#
# Salus/PHI guard: if the session's repo NAME matches /salus/i, the
# notification message text is NEVER forwarded to the relay (cleared before
# it leaves this process). session-status.ts re-applies the same check on the
# repo name it receives (defense-in-depth, not the only guard).
#
# Wiring: himmel-ops plugin hooks.json Notification (exec-if-exists) — see
# marketplace/plugins/CLAUDE.md; .claude/settings.json is NOT touched.
#
# No .ps1 twin — same rationale as telegram-session-end.sh / jira-nudge-on-end.sh.

set +e
set -u 2>/dev/null || true
trap 'exit 0' EXIT

if [ "${1:-}" != "__himmel_detached" ]; then
    PAYLOAD=""
    if [ -t 0 ]; then :; else PAYLOAD="$(cat 2>/dev/null || true)"; fi
    [ -n "$PAYLOAD" ] || exit 0
    _tmp="$(mktemp "${TMPDIR:-/tmp}/telegram-notification-payload.XXXXXX" 2>/dev/null)" || exit 0
    printf '%s' "$PAYLOAD" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; exit 0; }
    _dlib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/detach.sh"
    if [ -r "$_dlib" ]; then
        # shellcheck source=/dev/null
        . "$_dlib"
        detach_run bash "${BASH_SOURCE[0]}" __himmel_detached "$_tmp"
    else
        rm -f "$_tmp"
    fi
    exit 0
fi

# === Detached child: the real work (parent already returned 0) ==============

PAYLOAD="$(cat "${2:-}" 2>/dev/null || true)"
rm -f "${2:-}" 2>/dev/null || true

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib"
ROOT="$(cd "$HOOK_LIB/.." && pwd)"
# shellcheck source=/dev/null
[ -r "$HOOK_LIB/detach.sh" ] && . "$HOOK_LIB/detach.sh"

command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v bun >/dev/null 2>&1 || exit 0

[ -n "$PAYLOAD" ] || exit 0
printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1 || exit 0

SESSION_CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')"
NOTIFICATION_TYPE="$(printf '%s' "$PAYLOAD" | jq -r '.notification_type // empty')"
MESSAGE="$(printf '%s' "$PAYLOAD" | jq -r '.message // empty')"
[ -n "$SESSION_CWD" ] || exit 0
[ -d "$SESSION_CWD" ] || exit 0

# --- Resolve the session repo's .env root (worktree-safe, like the jira CLI) -
ENV_ROOT="$( cd "$SESSION_CWD" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd )"
[ -n "$ENV_ROOT" ] || ENV_ROOT="$SESSION_CWD"

if [ -r "$HOOK_LIB/load-dotenv.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_LIB/load-dotenv.sh"
    load_dotenv --root "$ENV_ROOT" TELEGRAM_GROUP_CHAT_ID 2>/dev/null || true
fi

# --- Silent no-op gate: unset/blank TELEGRAM_GROUP_CHAT_ID -------------------
[ -n "${TELEGRAM_GROUP_CHAT_ID:-}" ] || exit 0

# --- repo name (read-only; never `git fetch`) --------------------------------
REMOTE_URL="$(git -C "$SESSION_CWD" remote get-url origin 2>/dev/null || true)"
if [ -n "$REMOTE_URL" ]; then
    REPO_NAME="$(basename "$REMOTE_URL" .git)"
else
    REPO_NAME="$(basename "$SESSION_CWD")"
fi
[ -n "$REPO_NAME" ] || REPO_NAME="unknown-repo"

# --- Salus/PHI guard: never forward the notification message for salus ------
case "$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')" in
    *salus*) MESSAGE="" ;;
esac

# --- Relay via session-status.ts (reuses sendMessage — never reinvents the
# HTTP client). Detached so it never delays the operator-facing prompt.
detach_run env \
    TG_REPO_NAME="$REPO_NAME" TG_NOTIFICATION_TYPE="$NOTIFICATION_TYPE" TG_MESSAGE="$MESSAGE" \
    TELEGRAM_GROUP_CHAT_ID="$TELEGRAM_GROUP_CHAT_ID" \
    bun run "$ROOT/scripts/telegram/session-status.ts" notification

exit 0
