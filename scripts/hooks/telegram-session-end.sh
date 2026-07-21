#!/usr/bin/env bash
# telegram-session-end.sh — Claude Code SessionEnd hook (HIMMEL-1250 Increment 1).
#
# Fires once per session (SessionEnd, NOT per-turn Stop — Stop fires on every
# assistant turn and can block session flow via exit code 2; SessionEnd is
# fire-and-forget and matches this repo's existing "notify operator at session
# end" convention alongside end-session-wiki.sh / jira-nudge-on-end.sh /
# refresh-where-are-we-on-end.sh). Composes a CONCISE status (repo/branch, a
# best-effort last-assistant summary, any /mergepub line) and relays it to the
# operator's Telegram GROUP via TELEGRAM_GROUP_CHAT_ID + the existing
# sendMessage() HTTP client (scripts/telegram/telegram-api.ts, via
# scripts/telegram/session-status.ts) — never reinvents the HTTP client.
#
# Silent no-op (hard requirement): TELEGRAM_GROUP_CHAT_ID unset/blank -> exit
# 0, nothing sent. Never errors, never blocks session teardown — same failure
# posture as every other SessionEnd hook in this repo.
#
# Salus/PHI guard: if the session's repo NAME matches /salus/i (the operator's
# medical vault/repo), transcript content (last-assistant text) is NEVER READ
# at all — the guard trips BEFORE extraction, not after, so no PHI-shaped text
# ever leaves this process. session-status.ts re-applies the same check on the
# repo name it receives (defense-in-depth, not the only guard).
#
# Wiring: himmel-ops plugin hooks.json SessionEnd (exec-if-exists) — see
# marketplace/plugins/CLAUDE.md; .claude/settings.json is NOT touched (editing
# it directly is a guarded self-mod).
#
# This hook runs under bash on every platform (no .ps1 twin — same rationale
# as jira-nudge-on-end.sh: it does no OS-specific path work, so Git Bash on
# Windows runs this file directly).
#
# Full-body detach pattern: HIMMEL-661 (extends HIMMEL-636/623). Even the
# gate-off fast path costs real process-spawn time on Windows Git Bash, which
# loses the race against Claude Code's SessionEnd teardown — so the ENTIRE
# body (payload parse, dotenv load, transcript scan, relay) runs in a detached
# child; the parent returns ~instantly.

set +e
set -u 2>/dev/null || true
trap 'exit 0' EXIT

if [ "${1:-}" != "__himmel_detached" ]; then
    PAYLOAD=""
    if [ -t 0 ]; then :; else PAYLOAD="$(cat 2>/dev/null || true)"; fi
    [ -n "$PAYLOAD" ] || exit 0
    _tmp="$(mktemp "${TMPDIR:-/tmp}/telegram-session-end-payload.XXXXXX" 2>/dev/null)" || exit 0
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
TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty')"
REASON="$(printf '%s' "$PAYLOAD" | jq -r '.reason // "other"')"
[ -n "$SESSION_CWD" ] || exit 0
[ -d "$SESSION_CWD" ] || exit 0

# --- Resolve the session repo's .env root (worktree-safe, like the jira CLI) -
# The gitignored .env lives in the PRIMARY checkout, not the worktree.
ENV_ROOT="$( cd "$SESSION_CWD" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd )"
[ -n "$ENV_ROOT" ] || ENV_ROOT="$SESSION_CWD"

if [ -r "$HOOK_LIB/load-dotenv.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_LIB/load-dotenv.sh"
    load_dotenv --root "$ENV_ROOT" TELEGRAM_GROUP_CHAT_ID 2>/dev/null || true
fi

# --- Silent no-op gate: unset/blank TELEGRAM_GROUP_CHAT_ID -------------------
[ -n "${TELEGRAM_GROUP_CHAT_ID:-}" ] || exit 0

# --- repo name / branch (read-only; never `git fetch`) ----------------------
REMOTE_URL="$(git -C "$SESSION_CWD" remote get-url origin 2>/dev/null || true)"
if [ -n "$REMOTE_URL" ]; then
    REPO_NAME="$(basename "$REMOTE_URL" .git)"
else
    REPO_NAME="$(basename "$SESSION_CWD")"
fi
[ -n "$REPO_NAME" ] || REPO_NAME="unknown-repo"
BRANCH="$(git -C "$SESSION_CWD" branch --show-current 2>/dev/null || true)"

# --- Salus/PHI guard: trips BEFORE any transcript content is read -----------
IS_SALUS=0
case "$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')" in
    *salus*) IS_SALUS=1 ;;
esac

LAST_ASSISTANT=""
MERGEPUB_LINE=""
if [ "$IS_SALUS" = "0" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    # Single lightweight jq scan for the LAST assistant text turn (HIMMEL-636
    # style single-pass extraction — deliberately NOT the full 4-scan
    # session-transcript.sh lib; a concise status doesn't need it).
    LAST_ASSISTANT="$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1)"
    # Best-effort /mergepub line, if the operator issued one this session.
    MERGEPUB_LINE="$(grep -o '/mergepub[^"\\]*' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1)"
fi

# --- Relay via session-status.ts (reuses sendMessage — never reinvents the
# HTTP client). Detached again: the network call must not risk being reaped
# before it completes (same double-detach pattern as jira-nudge-on-end.sh's
# relay_nudge()).
detach_run env \
    TG_REPO_NAME="$REPO_NAME" TG_BRANCH="$BRANCH" TG_REASON="$REASON" \
    TG_LAST_ASSISTANT="$LAST_ASSISTANT" TG_MERGEPUB_LINE="$MERGEPUB_LINE" \
    TELEGRAM_GROUP_CHAT_ID="$TELEGRAM_GROUP_CHAT_ID" \
    bun run "$ROOT/scripts/telegram/session-status.ts" sessionend

exit 0
