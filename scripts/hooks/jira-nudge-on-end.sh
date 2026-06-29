#!/usr/bin/env bash
# jira-nudge-on-end.sh — Claude Code SessionEnd hook (HIMMEL-618).
#
# If a session committed work clearly tied to a Jira ticket but made NO Jira
# mutation this session, emit ONE advisory nudge so the operator keeps the
# tracker in sync. ADVISORY ONLY — it never performs a Jira write and never
# blocks session teardown.
#
# Detection (all must hold, else silent exit 0 — no nudge):
#   1. Gate HIMMEL_JIRA_NUDGE is truthy (default OFF; HIMMEL-425 convention).
#   2. The `ticket` initiative leg is NOT active (when ON it already injects the
#      same reminder at SessionStart — suppress to avoid a double-nudge).
#   3. The transcript yields a parseable first-timestamp (session-start epoch).
#   4. git committed at least one commit in the session window (read-only
#      sessions never nudge).
#   5. JIRA_PROJECT_KEY resolves from the session repo's .env.
#   6. The branch name OR an in-window commit subject references <KEY>-<N>.
#   7. NO jira-mutation breadcrumb exists with epoch >= session start
#      (scripts/jira/src/breadcrumb.ts drops these on every mutating verb).
#
# Nudge surface: stdout (transcript) + relay via the Telegram bridge when
# configured (the only operator-reaching channel unattended). Best-effort.
#
# Wiring: himmel-ops plugin hooks.json SessionEnd (exec-if-exists), default OFF.
# Test seams (used only by test-jira-nudge-on-end.sh):
#   JIRA_NUDGE_RELAY_CMD   override the relay command (default Telegram curl)

# This hook runs under bash on every platform (no .ps1 twin), so do NOT add a
# msys/cygwin guard — that would silence the nudge on Windows/Git-Bash.

# Error isolation: do NOT use `set -e`/`pipefail` + an ERR trap — the sourced
# parse_session_transcript() returns non-zero on a content-free transcript (its
# last `&&` short-circuits), which an ERR trap would mistake for a fatal error.
# Instead run with set +e and force a clean exit via the EXIT trap (a SessionEnd
# advisory hook must NEVER block teardown, regardless of how it got here).
set +e
set -u 2>/dev/null || true
trap 'exit 0' EXIT

# Drain stdin (SessionEnd pipes a JSON payload).
PAYLOAD=""
if [ -t 0 ]; then :; else PAYLOAD="$(cat 2>/dev/null || true)"; fi

# Need jq + git to decide anything; absent → fail-safe (no nudge).
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

[ -n "$PAYLOAD" ] || exit 0
printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1 || exit 0

TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty')"
SESSION_CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty')"
[ -n "$SESSION_CWD" ] || exit 0
[ -d "$SESSION_CWD" ] || exit 0

HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib"

# --- Resolve the session repo's .env root (worktree-safe, like the jira CLI) --
# The gitignored .env lives in the PRIMARY checkout, not the worktree, so resolve
# the git-common-dir parent rather than $SESSION_CWD literally.
ENV_ROOT="$( cd "$SESSION_CWD" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd )"
[ -n "$ENV_ROOT" ] || ENV_ROOT="$SESSION_CWD"

# Load gate + key + relay config from .env (non-clobbering; live env wins).
if [ -r "$HOOK_LIB/load-dotenv.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_LIB/load-dotenv.sh"
    load_dotenv --root "$ENV_ROOT" \
        HIMMEL_JIRA_NUDGE HIMMEL_INITIATIVE HIMMEL_INITIATIVE_OVERNIGHT \
        HIMMEL_OVERNIGHT JIRA_PROJECT_KEY TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
        2>/dev/null || true
fi

# --- Gate: OFF unless HIMMEL_JIRA_NUDGE is truthy ---------------------------
_truthy() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ""|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
_truthy "${HIMMEL_JIRA_NUDGE:-}" || exit 0

# --- Suppress when the `ticket` initiative leg is already active -------------
if [ -r "$HOOK_LIB/initiative-legs.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOK_LIB/initiative-legs.sh"
    LEGS="$(resolve_legs "${HIMMEL_INITIATIVE:-}" "${HIMMEL_INITIATIVE_OVERNIGHT:-}" "${HIMMEL_OVERNIGHT:-}")"
    case " $LEGS " in *" ticket "*) exit 0 ;; esac
fi

# --- Session-start epoch from the transcript's first timestamp --------------
# shellcheck source=/dev/null
. "$HOOK_LIB/session-transcript.sh"
parse_session_transcript "$TRANSCRIPT_PATH"
[ -n "${FIRST_TS:-}" ] || exit 0
START_EPOCH="$(date -u -d "$FIRST_TS" +%s 2>/dev/null || echo "")"
if [ -z "$START_EPOCH" ]; then
    # BSD/macOS `date` has no `-d`; parse the ISO-8601 (UTC) timestamp explicitly.
    _ts="${FIRST_TS%%.*}"   # strip fractional seconds
    _ts="${_ts%Z}"          # strip trailing Z
    START_EPOCH="$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$_ts" +%s 2>/dev/null || echo "")"
fi
case "$START_EPOCH" in ''|*[!0-9]*) exit 0 ;; esac
[ "$START_EPOCH" -gt 0 ] 2>/dev/null || exit 0

# --- Committed-work gate: at least one commit in the session window ----------
COMMITS="$(git -C "$SESSION_CWD" log --since=@"$START_EPOCH" --format=%s 2>/dev/null)"
[ -n "$COMMITS" ] || exit 0

# --- Ticket reference: JIRA_PROJECT_KEY from .env, matched on branch/commits -
KEY="${JIRA_PROJECT_KEY:-}"
[ -n "$KEY" ] || exit 0
BRANCH="$(git -C "$SESSION_CWD" branch --show-current 2>/dev/null)"
TICKETS="$(printf '%s\n%s\n' "$BRANCH" "$COMMITS" | grep -oE "${KEY}-[0-9]+" | sort -u)"
[ -n "$TICKETS" ] || exit 0

# --- No-mutation check: any breadcrumb with epoch >= session start? ----------
# shellcheck source=/dev/null
. "$HOOK_LIB/jira-breadcrumb.sh"
if breadcrumb_mutated_since "$SESSION_CWD" "$START_EPOCH"; then
    exit 0   # a jira mutation already happened this session — nothing to nudge
fi

# --- Emit ONE nudge ----------------------------------------------------------
TICKET_LIST="$(printf '%s' "$TICKETS" | paste -sd ',' - 2>/dev/null)"
[ -n "$TICKET_LIST" ] || TICKET_LIST="$(printf '%s' "$TICKETS" | tr '\n' ',' | sed 's/,$//')"
FIRST_TICKET="$(printf '%s\n' "$TICKETS" | head -n1)"

NUDGE="[jira-nudge] Session committed work referencing ${TICKET_LIST} but made no Jira update this session. Consider syncing the tracker, e.g.: node scripts/jira/dist/index.js transition ${FIRST_TICKET} \"In Progress\" (or comment/transition as appropriate)."

printf '%s\n' "$NUDGE"

# --- Relay via the Telegram bridge when configured --------------------------
relay_nudge() {
    local msg="$1"
    if [ -n "${JIRA_NUDGE_RELAY_CMD:-}" ]; then
        "$JIRA_NUDGE_RELAY_CMD" "$msg" >/dev/null 2>&1 || true
        return 0
    fi
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] \
        && command -v curl >/dev/null 2>&1; then
        curl -sS -m 10 -o /dev/null \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            >/dev/null 2>&1 || true
    fi
}
relay_nudge "$NUDGE"

exit 0
