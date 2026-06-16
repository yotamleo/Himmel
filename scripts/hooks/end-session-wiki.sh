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

FIRST_TS=""
LAST_ASSISTANT=""
COMMANDS=""
TRANSCRIPT_READABLE=1

if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    # First timestamp (earliest line with .timestamp)
    FIRST_TS="$(jq -r 'select(.timestamp) | .timestamp' "$TRANSCRIPT_PATH" 2>/dev/null | head -n1)"
    # Last assistant turn text (concat text blocks). Supports both top-level
    # role/content and nested message.role/message.content shapes.
    LAST_ASSISTANT="$(
        jq -r '
            . as $line
            | (
                (if .role then {role:.role, content:.content} else null end) //
                (if .message and .message.role then {role:.message.role, content:.message.content} else null end)
              )
            | select(. != null and .role == "assistant")
            | (if (.content|type) == "string"
               then .content
               else (.content // [] | map(select(.type=="text") | .text) | join("\n"))
              end)
            | select(length > 0)
        ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 200
    )"
    # Bash/PowerShell tool commands (in chronological order)
    COMMANDS="$(
        jq -r '
            . as $line
            | (
                (if .role then .content else null end) //
                (if .message then .message.content else null end)
              )
            | select(. != null and (type == "array"))
            | .[]?
            | select(.type == "tool_use" and (.name == "Bash" or .name == "PowerShell"))
            | .input.command // empty
        ' "$TRANSCRIPT_PATH" 2>/dev/null
    )"
else
    TRANSCRIPT_READABLE=0
fi

# Compute duration_seconds + duration_minutes (UTC now - first_ts)
NOW_EPOCH="$(date -u +%s)"
NOW_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DURATION_SECONDS=0
DURATION_MINUTES=0
if [ -n "$FIRST_TS" ]; then
    # GNU date understands ISO 8601 with Z; fall back to 0 on failure
    START_EPOCH="$(date -u -d "$FIRST_TS" +%s 2>/dev/null || echo "")"
    if [ -n "$START_EPOCH" ] && [ "$START_EPOCH" -gt 0 ]; then
        DELTA=$(( NOW_EPOCH - START_EPOCH ))
        [ "$DELTA" -lt 0 ] && DELTA=0
        DURATION_SECONDS="$DELTA"
        DIFF=$(( (DELTA + 30) / 60 ))
        [ "$DIFF" -lt 0 ] && DIFF=0
        DURATION_MINUTES="$DIFF"
    fi
fi

# Min-duration skip (only when we have a transcript timestamp; otherwise we
# can't compute duration and the cautious choice is to capture rather than drop).
if [ -n "$FIRST_TS" ] && [ "$DURATION_SECONDS" -lt "$CFG_MIN_DUR" ] 2>/dev/null; then
    log_msg "skipped: duration ${DURATION_SECONDS}s < min ${CFG_MIN_DUR}s"
    HOOK_OK=1
    exit 0
fi

# Filter trivial commands and cap at last 20
KEPT_COMMANDS=""
if [ -n "$COMMANDS" ]; then
    KEPT_COMMANDS="$(printf '%s\n' "$COMMANDS" \
        | grep -Ev '^(ls|cd|pwd|echo)( |$)' \
        | tail -n 20 || true)"
fi

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

VAULT_ROOT="${LUNA_VAULT_PATH:-$HOME/Documents/luna/luna}"
if [ ! -d "$VAULT_ROOT" ] && [ -n "${USERPROFILE:-}" ]; then
    # Windows-via-Git-Bash fallback: derive the Windows home generically.
    VAULT_ROOT_WIN="$(cygpath -u "$USERPROFILE" 2>/dev/null)/Documents/luna/luna"
    [ -d "$VAULT_ROOT_WIN" ] && VAULT_ROOT="$VAULT_ROOT_WIN"
fi

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

# Summary: first 4 non-empty lines of last assistant turn
SUMMARY=""
if [ -n "$LAST_ASSISTANT" ]; then
    SUMMARY="$(printf '%s\n' "$LAST_ASSISTANT" | awk 'NF' | head -n 4)"
fi
if [ -z "$SUMMARY" ]; then
    SUMMARY="_Transcript unavailable; auto-summary not generated._ (speculation)"
fi

PREAMBLE="Auto-captured Claude Code session in repo [[${REPO_NAME}]] on branch \`${BRANCH}\`. Filed by the end-session-wiki hook (epic #7 / task #26)."

# Files section
if [ "$FILES_COUNT" -eq 0 ]; then
    FILES_SECTION="_None._"
else
    # shellcheck disable=SC2016  # the backticks are literal markdown, not command subs
    SHOWN="$(printf '%s\n' "$FILES_RAW" | head -n 50 | sed 's/^/- `/; s/$/`/')"
    FILES_SECTION="$SHOWN"
    if [ "$FILES_COUNT" -gt 50 ]; then
        REMAIN=$((FILES_COUNT - 50))
        FILES_SECTION="${FILES_SECTION}
- _+${REMAIN} more (use git log to inspect)_"
    fi
fi

# Commands fenced block
CMDS_SECTION='```bash'
if [ -n "$KEPT_COMMANDS" ]; then
    CMDS_SECTION="${CMDS_SECTION}
${KEPT_COMMANDS}"
fi
CMDS_SECTION="${CMDS_SECTION}
\`\`\`"

# Raw conversation callout
if [ "$TRANSCRIPT_READABLE" -eq 1 ] && [ -n "$LAST_ASSISTANT" ]; then
    RAW_BODY="$(printf '%s\n' "$LAST_ASSISTANT" | sed 's/^/> /')"
    RAW_SECTION="> [!note]- Raw conversation
${RAW_BODY}"
else
    RAW_SECTION="> [!note]- Raw conversation
> _Transcript unavailable._"
fi

# Normalize separators defensively: on *nix this is a no-op (path already uses
# `/`). Paranoia for the case where bash runs on a Windows-format path despite
# the platform guard above. PS variant does the inverse (`/` -> `\`) so the
# `worktree` frontmatter field is deterministic regardless of which hook fires.
WORKTREE_ABS="${SESSION_CWD//\\//}"

MARKDOWN="$(cat <<EOF
---
date: ${NOW_ISO}
type: session
repo: ${REPO_NAME}
branch: ${BRANCH}
worktree: ${WORKTREE_ABS}
duration_minutes: ${DURATION_MINUTES}
files_touched: ${FILES_COUNT}
tags:
  - session
  - autocapture
ai-first: true
---

${PREAMBLE}

## Summary

${SUMMARY}

## Decisions

_None._

## Files Touched

${FILES_SECTION}

## Commands

${CMDS_SECTION}

## Follow-ups

_None._

## Raw Conversation

${RAW_SECTION}
EOF
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
    log_msg "ERROR: no API key (set OBSIDIAN_API_KEY or install Obsidian Local REST API)"
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
    log_msg "ERROR: PUT $ENDPOINT returned HTTP $HTTP_CODE"
    HOOK_OK=1
    exit 0
fi

log_msg "wrote ${REL_PATH} (${ELAPSED}ms)"
HOOK_OK=1
exit 0
