#!/usr/bin/env bash
# end-session-wiki.sh — Claude Code SessionEnd hook (Linux/macOS bash)
#
# Epic #7 — end-session-wiki-hook, tasks #26 (vault-write-integration) +
# #27 (opt-out-and-failure-handling).
#
# Reads SessionEnd JSON payload from stdin, gathers session metadata + a
# verbatim slice of the transcript, renders a Markdown note matching the
# schema in docs/luna/end-session-wiki-schema.md, and PUTs it into the
# Luna Obsidian vault via the Local REST API.
#
# Operational controls (#27): see docs/luna/end-session-wiki.md
#   - Env opt-out:  CLAUDE_END_SESSION_WIKI=0 (or "false") skips silently.
#   - Repo config:  $CLAUDE_PROJECT_DIR/.claude/end-session-wiki.json
#                   { enabled, dry_run, min_duration_seconds }
#   - Dry-run:      renders note to log file instead of vault HTTP PUT.
#   - Min duration: sessions shorter than min_duration_seconds are skipped.
#   - Error isol.:  set +e + EXIT trap; any failure logs + EXITS 0.
#   - Log:          $CLAUDE_PROJECT_DIR/.claude/end-session-wiki.log
#                   Rotates to .log.old at 1 MB.
#
# Failure policy (#27): hook MUST NEVER exit non-zero. See epic success
# criterion #5.

# Platform guard: this hook is the Linux/macOS variant. On Windows the
# companion end-session-wiki.ps1 runs instead. Both are registered in
# .claude/settings.json because Claude Code's `shell` field is an
# interpreter spec, not a platform filter — without this guard both
# would fire on the same platform and the second write would overwrite
# the first (silent vault inconsistency, see PR #56 review).
case "${OSTYPE:-}${OS:-}" in
    msys*|cygwin*|*Windows_NT*) exit 0 ;;
esac

# --- Error isolation: do NOT use `set -e`. We trap ERR/EXIT to log + exit 0.
set +e
set -u 2>/dev/null || true

# Bootstrap log path early so the trap can use it even if anything below blows up.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOG_DIR="${PROJECT_DIR}/.claude"
LOG_PATH="${LOG_DIR}/end-session-wiki.log"
LOG_OLD_PATH="${LOG_DIR}/end-session-wiki.log.old"
CONFIG_PATH="${LOG_DIR}/end-session-wiki.json"

log_msg() {
    local msg="$1"
    # Best-effort: never let logging itself break the hook.
    {
        mkdir -p "$LOG_DIR" 2>/dev/null
        # Rotate at 1 MB (1048576 bytes)
        if [ -f "$LOG_PATH" ]; then
            local size
            size="$(wc -c < "$LOG_PATH" 2>/dev/null | tr -d ' ')"
            if [ -n "$size" ] && [ "$size" -gt 1048576 ] 2>/dev/null; then
                mv -f "$LOG_PATH" "$LOG_OLD_PATH" 2>/dev/null
            fi
        fi
        local stamp
        stamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '[%s] %s\n' "$stamp" "$msg" >> "$LOG_PATH" 2>/dev/null
    } 2>/dev/null
    return 0
}

# write_note_to_file <abs_path> <content> — local-filesystem fallback used when
# the Obsidian Local REST API is unavailable (no API key, or PUT failed).
# Obsidian picks up on-disk changes automatically, so a direct write produces
# the same note without depending on the plugin being running.
write_note_to_file() {
    local path="$1" content="$2" dir
    dir="$(dirname "$path")"
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s' "$content" > "$path" 2>/dev/null || return 1
    return 0
}

# EXIT trap: forces exit code 0 regardless of how we got here.
# We track an explicit $HOOK_OK flag so the trap knows whether to log a FAILED
# message. The trap is fired on:
#   - natural script end (success or any non-zero command since `set -e` is off)
#   - explicit `exit N` from anywhere
#   - signals (where supported)
HOOK_OK=0
# shellcheck disable=SC2317  # invoked indirectly via `trap ... EXIT`
__on_exit() {
    local rc=$?
    if [ "$HOOK_OK" -eq 0 ]; then
        # Only log a generic failure if we never set HOOK_OK=1 (i.e. we exited
        # via an unhandled error path). Specific error paths log their own msg
        # AND set HOOK_OK=1 before exit to avoid double-logging.
        log_msg "FAILED with exit $rc (unhandled - see prior log lines)"
    fi
    # Override the actual exit code: hook MUST NEVER exit non-zero.
    exit 0
}
trap '__on_exit' EXIT

# ---------- 0. Dependencies --------------------------------------------------

for dep in jq curl git; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        log_msg "ERROR: missing required dep: $dep"
        HOOK_OK=1
        exit 0
    fi
done

# ---------- Opt-out: env var ------------------------------------------------

if [ -n "${CLAUDE_END_SESSION_WIKI:-}" ]; then
    env_lower="$(printf '%s' "$CLAUDE_END_SESSION_WIKI" | tr '[:upper:]' '[:lower:]')"
    if [ "$env_lower" = "0" ] || [ "$env_lower" = "false" ]; then
        log_msg "skipped: env opt-out (CLAUDE_END_SESSION_WIKI=$CLAUDE_END_SESSION_WIKI)"
        HOOK_OK=1
        exit 0
    fi
fi

# ---------- Repo-local config -----------------------------------------------

CFG_ENABLED="true"
CFG_DRY_RUN="false"
CFG_MIN_DUR=60
# vault_path / vault are read by resolve_vault_root (scripts/lib/vault-resolve.sh),
# not here, so the shared @tsv parse stays focused on the gate fields.
if [ -r "$CONFIG_PATH" ]; then
    # Use `has(...)` instead of `//` because jq treats `false` and `0` as falsy,
    # so `.enabled // true` would return `true` when the user set `false`.
    parsed="$(jq -r '
        [
            (if has("enabled") then .enabled else true end | tostring),
            (if has("dry_run") then .dry_run else false end | tostring),
            (if has("min_duration_seconds") then .min_duration_seconds else 60 end | tostring)
        ] | @tsv
    ' "$CONFIG_PATH" 2>/dev/null)"
    if [ -n "$parsed" ]; then
        CFG_ENABLED="$(printf '%s' "$parsed" | cut -f1)"
        CFG_DRY_RUN="$(printf '%s' "$parsed" | cut -f2)"
        CFG_MIN_DUR="$(printf '%s' "$parsed" | cut -f3)"
    else
        log_msg "config parse failed (using defaults): $CONFIG_PATH"
    fi
fi

if [ "$CFG_ENABLED" = "false" ]; then
    log_msg "skipped: config disabled"
    HOOK_OK=1
    exit 0
fi

# ---------- 1. Read SessionEnd payload from stdin ----------------------------

PAYLOAD="$(cat)"
if [ -z "$PAYLOAD" ]; then
    log_msg "ERROR: empty stdin payload"
    HOOK_OK=1
    exit 0
fi

if ! echo "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
    log_msg "ERROR: invalid JSON on stdin"
    HOOK_OK=1
    exit 0
fi

TRANSCRIPT_PATH="$(echo "$PAYLOAD" | jq -r '.transcript_path // empty')"
SESSION_CWD="$(echo "$PAYLOAD"     | jq -r '.cwd // empty')"
# session_id and reason are part of the SessionEnd contract; read for parity
# with the .ps1 implementation and to make them available for future use.
# shellcheck disable=SC2034
SESSION_ID="$(echo "$PAYLOAD"      | jq -r '.session_id // empty')"
# shellcheck disable=SC2034
REASON="$(echo "$PAYLOAD"          | jq -r '.reason // "other"')"

if [ -z "$SESSION_CWD" ]; then
    log_msg "ERROR: payload missing 'cwd'"
    HOOK_OK=1
    exit 0
fi

# ---------- 2. Gather git / fs metadata --------------------------------------

git_or_empty() { git -C "$SESSION_CWD" "$@" 2>/dev/null || true; }

REPO_TOPLEVEL="$(git_or_empty rev-parse --show-toplevel)"
[ -z "$REPO_TOPLEVEL" ] && REPO_TOPLEVEL="$SESSION_CWD"

REMOTE_URL="$(git_or_empty remote get-url origin)"
if [ -n "$REMOTE_URL" ]; then
    REPO_NAME="$(basename "$REMOTE_URL" .git)"
else
    REPO_NAME="$(basename "$SESSION_CWD")"
fi
[ -z "$REPO_NAME" ] && REPO_NAME="unknown-repo"

BRANCH="$(git_or_empty branch --show-current)"
[ -z "$BRANCH" ] && BRANCH="detached"

# files_touched = uncommitted+staged diff (pragmatic stand-in for session-window)
FILES_RAW="$(git_or_empty diff --name-only HEAD)"
FILES_COUNT=0
if [ -n "$FILES_RAW" ]; then
    FILES_COUNT="$(printf '%s\n' "$FILES_RAW" | grep -c '.')"
fi

# ---------- 3. Read transcript ----------------------------------------------

_ST_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/session-transcript.sh"
# shellcheck source=/dev/null
. "$_ST_LIB"

parse_session_transcript "$TRANSCRIPT_PATH"

# Compute duration_seconds + duration_minutes (UTC now - first_ts)
NOW_EPOCH="$(date -u +%s)"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

compute_duration "$FIRST_TS" "$NOW_EPOCH"

# Min-duration skip (only when we have a transcript timestamp; otherwise we
# can't compute duration and the cautious choice is to capture rather than drop).
if [ -n "$FIRST_TS" ] && [ "$DURATION_SECONDS" -lt "$CFG_MIN_DUR" ] 2>/dev/null; then
    log_msg "skipped: duration ${DURATION_SECONDS}s < min ${CFG_MIN_DUR}s"
    HOOK_OK=1
    exit 0
fi

filter_commands "$COMMANDS"

# ---------- 4. Compute path --------------------------------------------------

slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

RAW_SLUG="$(slugify "${REPO_NAME}-${BRANCH}")"
# Cap at 80, prefer dash boundary
if [ "${#RAW_SLUG}" -gt 80 ]; then
    CUT="${RAW_SLUG:0:80}"
    LAST_DASH="${CUT%-*}"
    if [ -n "$LAST_DASH" ] && [ "${#LAST_DASH}" -gt 0 ] && [ "${#LAST_DASH}" -lt 80 ]; then
        RAW_SLUG="$LAST_DASH"
    else
        RAW_SLUG="$CUT"
    fi
fi

DATE_STR="$(date -u +%Y-%m-%d)"
HHMM="$(date -u +%H%M)"
YEAR="$(date -u +%Y)"
MONTH="$(date -u +%m)"

# Vault root: resolved by scripts/lib/vault-resolve.sh (HIMMEL-403).
# Precedence: config.vault_path > validated config.vault NAME (operator registry
# ~/.claude/luna-vaults.json -> ~/Documents/<name> w/ .obsidian marker) >
# LUNA_VAULT_PATH > default luna. An empty result means a vault was declared but
# could not be resolved (invalid/missing) -> skip the capture (fail-closed).
_VR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/vault-resolve.sh"
# shellcheck source=/dev/null
. "$_VR_LIB"
VAULT_ROOT="$(resolve_vault_root "$CONFIG_PATH" "$HOME/.claude/luna-vaults.json" "$CFG_DRY_RUN")"
if [ -z "$VAULT_ROOT" ]; then
    log_msg "skipped: vault unresolved (invalid name / no real vault / unparseable config) — no write"
    HOOK_OK=1   # clean intentional skip — keep the EXIT trap from logging a phantom FAILED
    exit 0
fi
# Windows-via-Git-Bash fallback for the DEFAULT location only (unchanged intent).
if [ ! -d "$VAULT_ROOT" ] && [ "$VAULT_ROOT" = "$HOME/Documents/luna" ] && [ -n "${USERPROFILE:-}" ]; then
    VAULT_ROOT_WIN="$(cygpath -u "$USERPROFILE" 2>/dev/null)/Documents/luna"
    [ -d "$VAULT_ROOT_WIN" ] && VAULT_ROOT="$VAULT_ROOT_WIN"
fi
# Expand a leading ~/ (a JSON config value can't rely on shell tilde expansion).
# shellcheck disable=SC2088  # the "~/" here is a literal case-pattern match, not an expansion
case "$VAULT_ROOT" in "~/"*) VAULT_ROOT="$HOME/${VAULT_ROOT#\~/}" ;; esac

REL_DIR="sessions/${YEAR}/${MONTH}"
BASE_NAME="${DATE_STR}-${HHMM}-${RAW_SLUG}"
REL_PATH="${REL_DIR}/${BASE_NAME}.md"
ABS_PATH="${VAULT_ROOT}/${REL_PATH}"

# Collision -> -2, -3, ...  (skip in dry-run; we don't actually write to vault)
if [ "$CFG_DRY_RUN" != "true" ]; then
    SUFFIX=2
    while [ -e "$ABS_PATH" ]; do
        SUFFIX_STR="-${SUFFIX}"
        MAX_SLUG=$(( 80 - ${#SUFFIX_STR} ))
        SLUG_C="$RAW_SLUG"
        if [ "${#SLUG_C}" -gt "$MAX_SLUG" ]; then
            CUT="${SLUG_C:0:$MAX_SLUG}"
            LAST_DASH="${CUT%-*}"
            if [ -n "$LAST_DASH" ] && [ "${#LAST_DASH}" -lt "$MAX_SLUG" ]; then
                SLUG_C="$LAST_DASH"
            else
                SLUG_C="$CUT"
            fi
        fi
        BASE_NAME="${DATE_STR}-${HHMM}-${SLUG_C}${SUFFIX_STR}"
        REL_PATH="${REL_DIR}/${BASE_NAME}.md"
        ABS_PATH="${VAULT_ROOT}/${REL_PATH}"
        SUFFIX=$((SUFFIX + 1))
        [ "$SUFFIX" -gt 100 ] && break
    done
fi

# ---------- 5. Render markdown ----------------------------------------------

_SN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/session-note.sh"
# shellcheck source=/dev/null
. "$_SN_LIB"

# Normalize separators defensively: on *nix this is a no-op (path already uses
# `/`). Paranoia for the case where bash runs on a Windows-format path despite
# the platform guard above. PS variant does the inverse (`/` -> `\`) so the
# `worktree` frontmatter field is deterministic regardless of which hook fires.
WORKTREE_ABS="${SESSION_CWD//\\//}"

MARKDOWN="$(
    REPO_NAME="$REPO_NAME" \
    BRANCH="$BRANCH" \
    WORKTREE_ABS="$WORKTREE_ABS" \
    FILES_COUNT="$FILES_COUNT" \
    FILES_RAW="$FILES_RAW" \
    NOW_ISO="$NOW_ISO" \
    DURATION_MINUTES="$DURATION_MINUTES" \
    SESSION_ID="$SESSION_ID" \
    SOURCE="live" \
    LAST_ASSISTANT="$LAST_ASSISTANT" \
    TRANSCRIPT_READABLE="$TRANSCRIPT_READABLE" \
    KEPT_COMMANDS="$KEPT_COMMANDS" \
    render_session_note
)"

# ---------- 6. Dry-run short-circuit ----------------------------------------

if [ "$CFG_DRY_RUN" = "true" ]; then
    RENDERED_LEN=${#MARKDOWN}
    # Trigger rotation via log_msg first (it checks size + rotates) before
    # dumping the rendered note, so a single dry-run can't push the log to ~2x
    # the cap before the next invocation notices.
    log_msg "dry_run: rendered ${RENDERED_LEN} chars (path=${REL_PATH})"
    SEP="=============================================================================="
    {
        printf '%s\n' "$SEP"
        printf 'DRY-RUN RENDERED NOTE  path=%s  bytes=%d\n' "$REL_PATH" "$RENDERED_LEN"
        printf '%s\n' "$SEP"
        printf '%s\n' "$MARKDOWN"
        printf '%s\n' "$SEP"
    } >> "$LOG_PATH" 2>/dev/null
    HOOK_OK=1
    exit 0
fi

# ---------- 7. Token discovery + PUT ----------------------------------------

API_KEY="${OBSIDIAN_API_KEY:-}"
if [ -z "$API_KEY" ]; then
    PLUGIN_DATA="${VAULT_ROOT}/.obsidian/plugins/obsidian-local-rest-api/data.json"
    if [ -r "$PLUGIN_DATA" ]; then
        API_KEY="$(jq -r '.apiKey // empty' "$PLUGIN_DATA" 2>/dev/null || true)"
    fi
fi
if [ -z "$API_KEY" ]; then
    # No REST API key — fall back to a direct on-disk write into the vault.
    if write_note_to_file "$ABS_PATH" "$MARKDOWN"; then
        log_msg "wrote (local fs, no api key) ${REL_PATH}"
    else
        log_msg "ERROR: local fs write failed: $ABS_PATH"
    fi
    HOOK_OK=1
    exit 0
fi

BASE_URL="${OBSIDIAN_API_URL:-https://127.0.0.1:27124}"

# URL-encode each path segment (preserve / separators)
ENCODED_REL=""
IFS='/' read -ra SEGMENTS <<< "$REL_PATH"
for seg in "${SEGMENTS[@]}"; do
    enc="$(jq -rn --arg v "$seg" '$v|@uri')"
    if [ -z "$ENCODED_REL" ]; then
        ENCODED_REL="$enc"
    else
        ENCODED_REL="${ENCODED_REL}/${enc}"
    fi
done
ENDPOINT="${BASE_URL}/vault/${ENCODED_REL}"

# -k: self-signed cert on loopback is acceptable here (security note: 127.0.0.1
# only; any local process can already read the vault directly).
START_MS="$(date +%s%3N 2>/dev/null || echo 0)"
HTTP_CODE="$(curl -sk -o /dev/null -w '%{http_code}' \
    -X PUT \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: text/markdown" \
    --data-binary "$MARKDOWN" \
    "$ENDPOINT" 2>/dev/null || echo "000")"
END_MS="$(date +%s%3N 2>/dev/null || echo 0)"
ELAPSED=$((END_MS - START_MS))

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "204" ]; then
    # REST PUT failed (e.g. Obsidian not running) — fall back to on-disk write.
    if write_note_to_file "$ABS_PATH" "$MARKDOWN"; then
        log_msg "PUT $ENDPOINT returned HTTP $HTTP_CODE; wrote (local fs fallback) ${REL_PATH}"
    else
        log_msg "ERROR: PUT $ENDPOINT HTTP $HTTP_CODE and local fs fallback failed: $ABS_PATH"
    fi
    HOOK_OK=1
    exit 0
fi

log_msg "wrote ${REL_PATH} (${ELAPSED}ms)"
HOOK_OK=1
exit 0
