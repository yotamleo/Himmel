#!/usr/bin/env bash
# backfill-sessions.sh — Render old Claude transcripts into the luna vault.
#
# Usage: bash scripts/luna/backfill-sessions.sh [OPTIONS]
#
# Scope flags (default = current project):
#   --all                  Process every project under ~/.claude/projects
#   --project <path>       Process the project for the given repo path (repeatable)
#   --projects-dir <dir>   Override the projects root (default: ~/.claude/projects)
#
# Filter flags:
#   --include-orphaned     Also import sessions whose cwd no longer exists on disk
#   --only <glob>          Only process projects matching glob (repo path)
#   --exclude <glob>       Exclude projects matching glob (repo path)
#
# Output flags:
#   --dry-run              Print counts only; write nothing (no note, no ledger update)
#   --state-file <path>    Override ledger path (default: ~/.claude/luna-backfill-state.json)
#   --vault-registry <path>  Override vault registry (default: ~/.claude/luna-vaults.json)
#   --luna-vault-path <dir>  Override default vault path (sets LUNA_VAULT_PATH)
#
# bash 3.2-safe; shellcheck-clean; cross-platform (Windows Git Bash / macOS / Linux).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libs
_ST_LIB="$SCRIPT_DIR/../lib/session-transcript.sh"
_SN_LIB="$SCRIPT_DIR/../lib/session-note.sh"
_VR_LIB="$SCRIPT_DIR/../lib/vault-resolve.sh"

for _lib in "$_ST_LIB" "$_SN_LIB" "$_VR_LIB"; do
    # shellcheck source=/dev/null
    . "$_lib" || { printf 'backfill: cannot source %s\n' "$_lib" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DRY_RUN=false
INCLUDE_ORPHANED=false
SCOPE_ALL=false
ONLY_GLOB=""
EXCLUDE_GLOB=""

# Home resolution (cross-platform)
if [ -n "${HOME:-}" ]; then
    _HOME="$HOME"
elif [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
    _HOME="$(cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE")"
else
    _HOME="${USERPROFILE:-/tmp}"
fi

PROJECTS_DIR="$_HOME/.claude/projects"
STATE_FILE="$_HOME/.claude/luna-backfill-state.json"
VAULT_REGISTRY="$_HOME/.claude/luna-vaults.json"

# Project paths to process (newline-separated absolute paths built during arg parse)
EXPLICIT_PROJECTS_LIST=""
PROJECTS_DIR_OVERRIDE=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            SCOPE_ALL=true; shift ;;
        --project)
            shift
            EXPLICIT_PROJECTS_LIST="${EXPLICIT_PROJECTS_LIST}${1}
"
            shift ;;
        --projects-dir)
            shift; PROJECTS_DIR_OVERRIDE="$1"; shift ;;
        --include-orphaned)
            INCLUDE_ORPHANED=true; shift ;;
        --only)
            shift; ONLY_GLOB="$1"; shift ;;
        --exclude)
            shift; EXCLUDE_GLOB="$1"; shift ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --state-file)
            shift; STATE_FILE="$1"; shift ;;
        --vault-registry)
            shift; VAULT_REGISTRY="$1"; shift ;;
        --luna-vault-path)
            shift; LUNA_VAULT_PATH="$1"; export LUNA_VAULT_PATH; shift ;;
        --help|-h)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# *//'
            exit 0
            ;;
        *)
            printf 'backfill: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

[ -n "$PROJECTS_DIR_OVERRIDE" ] && PROJECTS_DIR="$PROJECTS_DIR_OVERRIDE"

# ---------------------------------------------------------------------------
# Temp files (cleaned up on exit)
# ---------------------------------------------------------------------------
TMP_JSONL_LIST="$(mktemp 2>/dev/null)" || TMP_JSONL_LIST="/tmp/backfill-jl-$$"
TMP_SEEN="$(mktemp 2>/dev/null)"       || TMP_SEEN="/tmp/backfill-seen-$$"
_cleanup() {
    rm -f "$TMP_JSONL_LIST" "$TMP_SEEN" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Path-to-project-slug (mirrors Claude Code's path->slug encoding)
# On Windows (cygpath available): convert POSIX -> Windows form first.
# Then replace : \ / with - and strip leading -.
# ---------------------------------------------------------------------------
_path_to_slug() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    printf '%s' "$p" | awk '{gsub(/[:\\\/]/, "-"); gsub(/^-+/, ""); print}'
}

# ---------------------------------------------------------------------------
# Enumerate JSONL files in a project directory (portable glob)
# ---------------------------------------------------------------------------
_jsonl_in_dir() {
    local pd="$1"
    [ -d "$pd" ] || return 0
    local f
    for f in "$pd"/*.jsonl; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
}

# ---------------------------------------------------------------------------
# Collect all JSONL paths into TMP_JSONL_LIST (avoids pipe-subshell problem)
# ---------------------------------------------------------------------------
_collect_jsonl_paths() {
    if [ -n "$EXPLICIT_PROJECTS_LIST" ]; then
        printf '%s' "$EXPLICIT_PROJECTS_LIST" | while IFS= read -r repo_path; do
            [ -n "$repo_path" ] || continue
            local slug pdir
            slug="$(_path_to_slug "$repo_path")"
            pdir="$PROJECTS_DIR/$slug"
            if [ -d "$pdir" ]; then
                _jsonl_in_dir "$pdir"
            else
                printf 'backfill: warning: no project dir for %s (slug=%s)\n' \
                    "$repo_path" "$slug" >&2
            fi
        done
    elif [ "$SCOPE_ALL" = "true" ]; then
        local d
        for d in "$PROJECTS_DIR"/*/; do
            [ -d "$d" ] && _jsonl_in_dir "${d%/}"
        done
    else
        local current_repo slug pdir
        current_repo="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
        slug="$(_path_to_slug "$current_repo")"
        pdir="$PROJECTS_DIR/$slug"
        if [ -d "$pdir" ]; then
            _jsonl_in_dir "$pdir"
        else
            printf 'backfill: warning: no project dir for current repo (slug=%s)\n' \
                "$slug" >&2
        fi
    fi
}

# ---------------------------------------------------------------------------
# Cross-platform ISO 8601 -> Unix epoch (jq; bash 3.2-safe)
# ---------------------------------------------------------------------------
_ts_to_epoch() {
    local ts="$1"
    [ -z "$ts" ] && { printf '0'; return; }
    printf '%s' "$ts" \
        | jq -Rr 'gsub("[.][0-9]+Z$";"Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime' \
        2>/dev/null \
    || printf '0'
}

# Compute DURATION_SECONDS / DURATION_MINUTES from first+last timestamps
_compute_backfill_duration() {
    local first_ts="$1" last_ts="$2"
    DURATION_SECONDS=0
    DURATION_MINUTES=0
    [ -z "$first_ts" ] && return
    [ -z "$last_ts" ]  && return
    local fe le delta
    fe="$(_ts_to_epoch "$first_ts")"
    le="$(_ts_to_epoch "$last_ts")"
    [ "$fe" = "0" ] && return
    [ "$le" = "0" ] && return
    delta=$(( le - fe ))
    [ "$delta" -lt 0 ] && delta=0
    DURATION_SECONDS="$delta"
    DURATION_MINUTES=$(( (delta + 30) / 60 ))
}

# ---------------------------------------------------------------------------
# Portable sha256 helper (sha256sum on Linux/Windows; shasum -a 256 on macOS)
# ---------------------------------------------------------------------------
_sha256() {
    sha256sum "$@" 2>/dev/null || shasum -a 256 "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Ledger helpers — flat file: one "<vault_hash>:<session_id>" line per entry
# ---------------------------------------------------------------------------
_vault_hash() {
    local h
    h="$(printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | awk '{print substr($1,1,16)}')"
    if [ -z "$h" ]; then
        printf 'backfill: FATAL: no sha256 tool found (need sha256sum or shasum)\n' >&2
        exit 1
    fi
    printf '%s' "$h"
}

_ledger_has() {
    local vault_root="$1" session_id="$2"
    [ -f "$STATE_FILE" ] || return 1
    local vhash
    vhash="$(_vault_hash "$vault_root")"
    grep -qF "${vhash}:${session_id}" "$STATE_FILE" 2>/dev/null
}

_ledger_add() {
    local vault_root="$1" session_id="$2"
    [ "$DRY_RUN" = "true" ] && return
    local vhash
    vhash="$(_vault_hash "$vault_root")"
    printf '%s\n' "${vhash}:${session_id}" >> "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Slugify for filenames (bash 3.2-safe via awk)
# ---------------------------------------------------------------------------
_slugify() {
    printf '%s' "$1" | awk '{
        v = tolower($0)
        gsub(/[^a-z0-9]+/, "-", v)
        gsub(/^-+/, "", v)
        gsub(/-+$/, "", v)
        print v
    }'
}

# Parse first non-null cwd from JSONL
_parse_first_cwd() {
    jq -r 'select(.cwd != null and .cwd != "") | .cwd' "$1" 2>/dev/null | head -n1
}

# Normalize path separators to /
_norm_path() {
    printf '%s' "$1" | awk '{gsub(/\\/, "/"); print}'
}

# Get min_duration_seconds from config (default 60)
_get_min_duration() {
    local config="$1"
    local val=60
    if [ -r "$config" ]; then
        local parsed
        parsed="$(jq -r 'if has("min_duration_seconds") then .min_duration_seconds else 60 end' \
            "$config" 2>/dev/null)"
        case "$parsed" in [0-9]*) val="$parsed" ;; esac
    fi
    printf '%s' "$val"
}

# --only / --exclude glob check (patterns are intentionally unquoted globs)
_should_include_repo() {
    local repo_path="$1"
    if [ -n "$ONLY_GLOB" ]; then
        # shellcheck disable=SC2254  # glob pattern — intentionally unquoted
        case "$repo_path" in $ONLY_GLOB) : ;; *) return 1 ;; esac
    fi
    if [ -n "$EXCLUDE_GLOB" ]; then
        # shellcheck disable=SC2254  # glob pattern — intentionally unquoted
        case "$repo_path" in $EXCLUDE_GLOB) return 1 ;; esac
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Counters (must live in the main shell, not a pipe subshell)
# ---------------------------------------------------------------------------
CNT_NEW=0
CNT_LEDGER=0
CNT_OPTOUT=0
CNT_ORPHANED=0
CNT_UNDERMIN=0

# ---------------------------------------------------------------------------
# Process one JSONL file (called from main shell loop — counters propagate)
# ---------------------------------------------------------------------------
_process_one() {
    local jl="$1"
    local session_id
    session_id="$(basename "$jl" .jsonl)"

    # Parse transcript (sets FIRST_TS, LAST_TS, LAST_ASSISTANT, COMMANDS, TRANSCRIPT_READABLE)
    parse_session_transcript "$jl"
    # shellcheck disable=SC2153  # globals set by the sourced session-transcript.sh lib
    local first_ts="$FIRST_TS" last_ts="$LAST_TS"
    # shellcheck disable=SC2153
    local last_assistant="$LAST_ASSISTANT" commands="$COMMANDS"
    # shellcheck disable=SC2153
    local transcript_readable="$TRANSCRIPT_READABLE"

    # Parse cwd
    local cwd_raw cwd
    cwd_raw="$(_parse_first_cwd "$jl")"
    cwd="$(_norm_path "$cwd_raw")"

    # Resolve repo context
    local repo_path="" repo_config="" repo_name="" worktree_abs=""
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
        repo_path="$cwd"
        repo_name="$(git -C "$cwd" remote get-url origin 2>/dev/null \
            | awk -F'/' '{p=$NF; sub(/\.git$/, "", p); print p}' || true)"
        [ -z "$repo_name" ] && repo_name="$(basename "$cwd")"
        repo_config="$cwd/.claude/end-session-wiki.json"
        worktree_abs="$cwd"
    else
        # Orphaned cwd
        if [ "$INCLUDE_ORPHANED" = "false" ]; then
            CNT_ORPHANED=$((CNT_ORPHANED + 1))
            return 0
        fi
        repo_name="$(printf '%s' "$cwd_raw" | awk -F'[/\\\\]' '{print $NF}')"
        [ -z "$repo_name" ] && repo_name="orphaned"
        repo_config=""
        worktree_abs=""
    fi

    # --only / --exclude
    if [ -n "$repo_path" ] && ! _should_include_repo "$repo_path"; then
        return 0
    fi

    # Opt-out: enabled:false
    if [ -n "$repo_config" ] && [ -r "$repo_config" ]; then
        local enabled
        enabled="$(jq -r 'if has("enabled") then .enabled else true end' \
            "$repo_config" 2>/dev/null)"
        if [ "$enabled" = "false" ]; then
            CNT_OPTOUT=$((CNT_OPTOUT + 1))
            return 0
        fi
    fi

    # Vault resolution.
    # Pass the config path only when it points at a real readable file — the
    # resolver is fail-closed on a readable-but-empty path (like /dev/null).
    # For orphaned sessions (no config) use a non-existent path so the resolver
    # falls through to LUNA_VAULT_PATH / registry default.
    local cfg_arg="/backfill-no-config-placeholder"
    [ -n "$repo_config" ] && [ -r "$repo_config" ] && cfg_arg="$repo_config"
    local vault_root
    vault_root="$(resolve_vault_root "$cfg_arg" "$VAULT_REGISTRY" "$DRY_RUN")"
    if [ -z "$vault_root" ]; then
        printf 'backfill: skipped %s (vault unresolved)\n' "$session_id" >&2
        return 0
    fi
    # Expand leading ~/
    # shellcheck disable=SC2088
    case "$vault_root" in "~/"*) vault_root="$_HOME/${vault_root#\~/}" ;; esac

    # Idempotency
    if _ledger_has "$vault_root" "$session_id"; then
        CNT_LEDGER=$((CNT_LEDGER + 1))
        return 0
    fi

    # Min-duration
    local min_dur
    min_dur="$(_get_min_duration "${repo_config:-}")"
    _compute_backfill_duration "$first_ts" "$last_ts"
    if [ -n "$first_ts" ] && [ "$DURATION_SECONDS" -lt "$min_dur" ] 2>/dev/null; then
        CNT_UNDERMIN=$((CNT_UNDERMIN + 1))
        return 0
    fi

    # First-run warning (once per vault per invocation; skip under --dry-run)
    local vhash
    vhash="$(_vault_hash "$vault_root")"
    if [ "$DRY_RUN" != "true" ] && ! grep -qF "$vhash" "$TMP_SEEN" 2>/dev/null; then
        printf '%s\n' "$vhash" >> "$TMP_SEEN"
        printf '\nWARNING: backfilling into vault: %s\n' "$vault_root"
        printf 'Live-captured sessions may produce duplicate notes for sessions already in the vault.\n'
        printf 'Review sessions/<YEAR>/<MONTH>/ after backfilling.\n\n'
    fi

    # Count new
    CNT_NEW=$((CNT_NEW + 1))
    [ "$DRY_RUN" = "true" ] && return 0

    # Compute output path
    local date_str year_str month_str hhmm_str
    date_str="$(printf '%s' "$first_ts" | awk -F'T' '{print $1}')"
    year_str="$(printf '%s' "$date_str" | awk -F'-' '{print $1}')"
    month_str="$(printf '%s' "$date_str" | awk -F'-' '{print $2}')"
    hhmm_str="$(printf '%s' "$first_ts" | awk -F'T' '{print $2}' | awk -F':' '{print $1$2}')"
    if [ -z "$year_str" ] || [ -z "$month_str" ]; then
        date_str="$(date -u +%Y-%m-%d)"
        year_str="$(date -u +%Y)"
        month_str="$(date -u +%m)"
        hhmm_str="$(date -u +%H%M)"
    fi

    local raw_slug
    raw_slug="$(_slugify "$repo_name")"
    if [ "${#raw_slug}" -gt 80 ]; then
        local cut
        cut="$(printf '%s' "$raw_slug" | awk '{print substr($0,1,80)}')"
        local last_dash="${cut%-*}"
        if [ -n "$last_dash" ] && [ "${#last_dash}" -gt 0 ]; then
            raw_slug="$last_dash"
        else
            raw_slug="$cut"
        fi
    fi

    local rel_dir="sessions/${year_str}/${month_str}"
    local base_name="${date_str}-${hhmm_str}-${raw_slug}"
    local abs_path="${vault_root}/${rel_dir}/${base_name}.md"

    # CREATE-only — resolve filename collision with suffix-dedup loop.
    # If the candidate path already exists, check whether it belongs to THIS
    # session (grep for "session_id: <id>" in the frontmatter).  If it does,
    # treat it as already-imported (don't write).  If it belongs to a DIFFERENT
    # session (or has no session_id line), advance to -2, -3, … (up to 100)
    # just like end-session-wiki.sh, so two sessions that share the same
    # date+minute don't silently lose one note.
    local suffix=2
    while [ -e "$abs_path" ]; do
        if grep -q "^session_id: ${session_id}$" "$abs_path" 2>/dev/null; then
            # This file already contains our session — genuinely already imported.
            _ledger_add "$vault_root" "$session_id"
            CNT_NEW=$((CNT_NEW - 1))
            CNT_LEDGER=$((CNT_LEDGER + 1))
            return 0
        fi
        # Different session occupies this path — try the next suffix.
        local suffix_str="-${suffix}"
        local max_slug
        max_slug=$(( 80 - ${#suffix_str} ))
        local slug_c="$raw_slug"
        if [ "${#slug_c}" -gt "$max_slug" ]; then
            local cut_c
            cut_c="$(printf '%s' "$slug_c" | awk -v n="$max_slug" '{print substr($0,1,n)}')"
            local last_dash="${cut_c%-*}"
            if [ -n "$last_dash" ] && [ "${#last_dash}" -lt "$max_slug" ]; then
                slug_c="$last_dash"
            else
                slug_c="$cut_c"
            fi
        fi
        abs_path="${vault_root}/${rel_dir}/${date_str}-${hhmm_str}-${slug_c}${suffix_str}.md"
        suffix=$((suffix + 1))
        if [ "$suffix" -gt 100 ]; then
            printf 'backfill: ERROR: >100 collisions for %s, skipping\n' "$session_id" >&2
            CNT_NEW=$((CNT_NEW - 1))
            return 0
        fi
    done

    filter_commands "$commands"

    local markdown
    markdown="$(
        REPO_NAME="$repo_name" \
        BRANCH="" \
        WORKTREE_ABS="$worktree_abs" \
        FILES_COUNT=0 \
        FILES_RAW="" \
        NOW_ISO="${first_ts}" \
        DURATION_MINUTES="$DURATION_MINUTES" \
        SESSION_ID="$session_id" \
        SOURCE="claude-backfill" \
        LAST_ASSISTANT="$last_assistant" \
        TRANSCRIPT_READABLE="$transcript_readable" \
        KEPT_COMMANDS="${KEPT_COMMANDS:-}" \
        render_session_note
    )"

    mkdir -p "${vault_root}/${rel_dir}" 2>/dev/null || true
    if printf '%s' "$markdown" > "$abs_path"; then
        _ledger_add "$vault_root" "$session_id"
    else
        printf 'backfill: ERROR: write failed: %s\n' "$abs_path" >&2
        CNT_NEW=$((CNT_NEW - 1))
    fi
}

# ---------------------------------------------------------------------------
# Main: collect paths to temp file, then loop in main shell (no pipe!)
# ---------------------------------------------------------------------------
_collect_jsonl_paths > "$TMP_JSONL_LIST"

while IFS= read -r jl; do
    [ -n "$jl" ] || continue
    _process_one "$jl"
done < "$TMP_JSONL_LIST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf 'backfill: new=%d already-in-ledger=%d opt-out-skip=%d orphaned-skip=%d under-min=%d\n' \
    "$CNT_NEW" "$CNT_LEDGER" "$CNT_OPTOUT" "$CNT_ORPHANED" "$CNT_UNDERMIN"
