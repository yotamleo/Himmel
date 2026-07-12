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
# Nudge surface: the Telegram relay when configured (the only operator-reaching
# channel unattended). The stdout print survives only for direct CHILD-MODE
# invocation — `bash jira-nudge-on-end.sh __himmel_detached <payload-file>`
# (tests, or a manual debug run reproducing that contract); a plain manual
# invocation goes through the detaching parent and produces no stdout, since in
# production the whole body runs full-body DETACHED (HIMMEL-661, see below).
# Best-effort. NOTE: since HIMMEL-661 the hook depends on lib/detach.sh to do
# anything at all (pre-661 a missing detach.sh only degraded the relay).
#
# Wiring: himmel-ops plugin hooks.json SessionEnd (exec-if-exists), default OFF.
# Test seams:
#   JIRA_NUDGE_RELAY_CMD    override the relay command (default Telegram curl);
#                           used by test-jira-nudge-on-end.sh AND
#                           test-codex-stop-hooks.sh.
#   JIRA_NUDGE_TEST_DELAY   (test-jira-nudge-on-end.sh only) sleep N seconds at
#                           the START of the detached child body. Proves the
#                           full-body detach keeps the PARENT fast: a regression
#                           that un-detaches the body would make this delay
#                           block teardown.

# This hook runs under bash on every platform (no .ps1 twin), so do NOT add a
# msys/cygwin guard — that would silence the nudge on Windows/Git-Bash.

# Error isolation: do NOT use `set -e`/`pipefail` + an ERR trap — the many
# best-effort probes below (jq pipelines, `git log`, the `|| exit 0`
# short-circuits) routinely return non-zero on a content-free transcript or a
# missing tool, which an ERR trap would mistake for a fatal error. Instead run
# with set +e and force a clean exit via the EXIT trap (a SessionEnd advisory
# hook must NEVER block teardown, regardless of how it got here).
set +e
set -u 2>/dev/null || true
trap 'exit 0' EXIT

# --- Full-body detach (HIMMEL-661, extends the HIMMEL-636 pattern) -----------
# Re-exec ourselves DETACHED with the SessionEnd payload parked in a temp file,
# and return 0 instantly. Even the gate-off fast path costs ~1.7s of process
# spawns on Windows Git Bash (payload jq, git rev-parse, dotenv) — all BEFORE
# the gate check — which loses the race against Claude Code's SessionEnd
# teardown: the recurring "Hook cancelled" that HIMMEL-635 (relay detach) and
# HIMMEL-636 (single-scan transcript parse) shaved but did not eliminate. The
# sibling refresh-where-are-we-on-end.sh returns in ~0.1s with this same
# full-body detach and no longer errors. The stdout nudge surface this hook
# previously stayed synchronous to preserve was already unreliable (a cancelled
# hook loses stdout AND relay); after this change the (already-detached) relay
# is the operator-reaching surface, and stdout survives for direct child-mode
# invocation only.
if [ "${1:-}" != "__himmel_detached" ]; then
    # Drain stdin (SessionEnd pipes a JSON payload) so the contract doesn't break.
    PAYLOAD=""
    if [ -t 0 ]; then :; else PAYLOAD="$(cat 2>/dev/null || true)"; fi
    [ -n "$PAYLOAD" ] || exit 0
    _tmp="$(mktemp "${TMPDIR:-/tmp}/jira-nudge-payload.XXXXXX" 2>/dev/null)" || exit 0
    printf '%s' "$PAYLOAD" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; exit 0; }
    # Guarded source: unlike the pre-661 flow (where a missing detach.sh only
    # degraded the relay), the parent now depends on it for the hook to do
    # ANYTHING — so on failure, clean up our own temp file instead of leaking
    # one per session with no child to delete it.
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

# === Detached child: detection + nudge (parent already returned 0) ===========

# Test-only child-latency seam (see header). if-guarded so an unset value is a
# clean no-op.
if [ -n "${JIRA_NUDGE_TEST_DELAY:-}" ]; then
    sleep "$JIRA_NUDGE_TEST_DELAY"
fi

# Recover the payload the parent parked; delete it whatever happens next.
PAYLOAD="$(cat "${2:-}" 2>/dev/null || true)"
rm -f "${2:-}" 2>/dev/null || true

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
# Only the FIRST timestamp is needed. Extract it directly rather than via
# parse_session_transcript(), which runs FOUR full-file jq scans
# (FIRST_TS/LAST_TS/LAST_ASSISTANT/COMMANDS) — three of which this hook never
# uses (HIMMEL-636). We now run detached (HIMMEL-661) so teardown no longer
# races this scan, but keep the single-scan path — the detached child should
# still be cheap on a long transcript.
FIRST_TS=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    FIRST_TS="$(jq -r 'select(.timestamp) | .timestamp' "$TRANSCRIPT_PATH" 2>/dev/null | head -n1)"
fi
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
        # Detach the relay (HIMMEL-635, extends the HIMMEL-623 detach pattern):
        # a synchronous `curl -m 10` can block
        # session teardown up to 10s and trip the SessionEnd hook budget (the
        # recurring "Hook cancelled"). The relay is best-effort and its result is
        # irrelevant to the ending session, so fire it in a setsid/disown child
        # (lib/detach.sh) and return immediately. detach_run already redirects the
        # child's std{in,out,err} to /dev/null, so it never holds the hook's pipes.
        # shellcheck source=/dev/null
        . "$HOOK_LIB/detach.sh"
        detach_run curl -sS -m 10 -o /dev/null \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    fi
}
relay_nudge "$NUDGE"

exit 0
