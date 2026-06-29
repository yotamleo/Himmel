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
# Reheal mode (HIMMEL-576):
#   --reheal               Instead of importing transcripts, scan the resolved
#                          vault's sessions/**/*.md for husk notes (crystallized
#                          != true AND "_Transcript unavailable._" AND Files
#                          Touched "_None._"), locate the matching transcript by
#                          session_id, and overwrite the note in place via the
#                          crystallizer (or a mechanical re-render when `claude`
#                          is unavailable). Inert husks (contentless / missing
#                          transcript) are left as-is. Idempotent. Honours
#                          --dry-run and --vault-registry/--luna-vault-path.
#
# Recrystallize mode (HIMMEL-620):
#   --recrystallize        Like --reheal, but the broader predicate: crystallize
#                          ANY note with crystallized != true that has a
#                          recoverable (content-bearing) transcript — NOT just
#                          husks. Covers content-bearing-but-uncrystallized notes
#                          that --reheal skips (an F1-affected live note, or a
#                          backfilled prose-session note). LLM-only (no claude ->
#                          skip; a mechanical re-render does not crystallize).
#                          Idempotent; honours --dry-run + the vault flags.
#   --limit <N>            Cap real crystallizations per run (token-cost guard;
#                          0 = unbounded). --dry-run reports the FULL count so you
#                          can size batches. Remaining notes recover on a later run.
#                          RUN --recrystallize --dry-run FIRST to see the scale —
#                          it is one real `claude` run per note.
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
REHEAL=false
RECRYSTALLIZE=false
RECRYS_LIMIT=0

# Progress cadence (HIMMEL-627): print a periodic scan heartbeat to stderr every
# N notes during the reheal/recrystallize loop so a long run on a large vault
# (~800+ candidate notes, each globbing ~188 project dirs in _find_transcript) is
# observably-working, not silent-for-minutes. Overridable for tests only.
PROGRESS_EVERY="${BACKFILL_PROGRESS_EVERY:-50}"

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
        --reheal)
            REHEAL=true; shift ;;
        --recrystallize)
            RECRYSTALLIZE=true; shift ;;
        --limit)
            shift
            case "$1" in [0-9]*) RECRYS_LIMIT="$1" ;; *) printf 'backfill: --limit needs a number\n' >&2; exit 1 ;; esac
            shift ;;
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
# Then replace EVERY non-alphanumeric char with - and strip leading -.
# Claude Code encodes a project dir as the cwd with every [^a-zA-Z0-9] char
# mapped to '-' (verified empirically against ~/.claude/projects: '.claude' ->
# '-claude', 'work_notes' -> 'work-notes'). Mapping only : \ / (the old
# behaviour) produced the wrong slug for any path containing a dot / underscore
# / space, so the project dir was never found and the whole project was silently
# skipped (HIMMEL-588).
# ---------------------------------------------------------------------------
_path_to_slug() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    printf '%s' "$p" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}'
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
CNT_HUSK=0

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
    # shellcheck disable=SC2153
    local has_content="$HAS_CONTENT"

    # Husk-skip gate (HIMMEL-576): a transcript with no salvageable content would
    # render a content-free "Transcript unavailable" husk note (FILES_COUNT is
    # always 0 in backfill, so the live hook's files_touched term doesn't apply).
    # Skip it — this is what kills the same-minute collision flood.
    if [ "${has_content:-0}" -eq 0 ]; then
        CNT_HUSK=$((CNT_HUSK + 1))
        return 0
    fi

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

# ===========================================================================
# Reheal mode (HIMMEL-576 Phase 3) — recover husk notes already in the vault.
# ===========================================================================
CNT_REHEAL=0
CNT_REHEAL_INERT=0
CNT_REHEAL_SKIP=0
CNT_RECRYS=0
CNT_RECRYS_SKIP=0

# Read a frontmatter field's value from a note (between the first two `---`
# lines). Echoes the value (may be empty); nothing if the key is absent.
_note_fm() { # <field> <note>
    awk -v key="$1" '
        /^---$/ { c++; if (c==2) exit; next }
        c==1 && $0 ~ "^"key":" { sub("^"key": ?", "", $0); print; exit }
    ' "$2" 2>/dev/null
}

# Husk-note predicate (note-level, distinct from the transcript-level
# HAS_CONTENT gate): crystallized is NOT true AND the Raw Conversation carries
# the literal "_Transcript unavailable._" AND the Files Touched section is
# exactly "_None._".  Returns 0 (husk) / 1 (not a husk).
_is_husk_note() { # <note>
    local f="$1"
    grep -q '^crystallized: true$' "$f" 2>/dev/null && return 1
    grep -qF '_Transcript unavailable._' "$f" 2>/dev/null || return 1
    local files_body
    files_body="$(awk '
        /^## / { if (ins) exit; if ($0 == "## Files Touched") ins=1; next }
        ins { print }
    ' "$f" 2>/dev/null | awk 'NF')"
    [ "$files_body" = "_None._" ] || return 1
    return 0
}

# Locate the transcript JSONL for a session_id under PROJECTS_DIR/*/<id>.jsonl.
# Echoes the first match; nothing if none.
_find_transcript() { # <session_id>
    local sid="$1" d cand
    [ -n "$sid" ] || return 1
    for d in "$PROJECTS_DIR"/*/; do
        cand="${d}${sid}.jsonl"
        [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    return 1
}

# Is a `claude` binary reachable (real or test stub)?  Mirrors crystallize-note.sh.
_claude_available() {
    [ -n "${CRYSTALLIZE_CLAUDE_BIN:-}" ] && return 0
    command -v claude >/dev/null 2>&1 && return 0
    return 1
}

# Mechanical re-render fallback (no claude): overwrite the husk note in place
# from the now-content-bearing transcript, preserving the note's identity
# frontmatter.  Stays crystallized: false (no LLM synthesis).
_mechanical_reheal() { # <note> <transcript>
    local note="$1" jl="$2"
    parse_session_transcript "$jl"
    # shellcheck disable=SC2153  # globals set by the sourced session-transcript.sh lib
    filter_commands "$COMMANDS"

    local repo branch worktree date_iso src dur sid
    repo="$(_note_fm repo "$note")"
    branch="$(_note_fm branch "$note")"
    worktree="$(_note_fm worktree "$note")"
    date_iso="$(_note_fm date "$note")"
    src="$(_note_fm source "$note")"
    dur="$(_note_fm duration_minutes "$note")"
    sid="$(_note_fm session_id "$note")"
    [ -n "$dur" ] || dur=0

    local markdown
    markdown="$(
        REPO_NAME="$repo" \
        BRANCH="$branch" \
        WORKTREE_ABS="$worktree" \
        FILES_COUNT=0 \
        FILES_RAW="" \
        NOW_ISO="$date_iso" \
        DURATION_MINUTES="$dur" \
        SESSION_ID="$sid" \
        SOURCE="$src" \
        LAST_ASSISTANT="$LAST_ASSISTANT" \
        TRANSCRIPT_READABLE="$TRANSCRIPT_READABLE" \
        KEPT_COMMANDS="${KEPT_COMMANDS:-}" \
        CRYSTALLIZED="false" \
        CRYSTALLIZED_AT="" \
        render_session_note
    )"
    # Guarded, atomic overwrite (this clobbers an existing note, unlike the
    # create path): refuse an empty render, write to a temp, and promote with
    # mv only on success — a failed/partial write never truncates the husk.
    [ -n "$markdown" ] || return 1
    local tmp="${note}.reheal.$$"
    if printf '%s' "$markdown" > "$tmp" 2>/dev/null && mv -f "$tmp" "$note" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# Reheal one note: skip non-husks; for a husk, find its transcript, and if that
# transcript now has content, heal it (crystallizer or mechanical re-render);
# otherwise leave it as-is (inert).
_reheal_one() { # <note>
    local note="$1"
    if ! _is_husk_note "$note"; then
        CNT_REHEAL_SKIP=$((CNT_REHEAL_SKIP + 1))
        return 0
    fi

    local sid jl
    sid="$(_note_fm session_id "$note")"
    jl="$(_find_transcript "$sid")"
    if [ -z "$jl" ]; then
        # Transcript gone — cannot recover.
        CNT_REHEAL_INERT=$((CNT_REHEAL_INERT + 1))
        return 0
    fi

    parse_session_transcript "$jl"
    # shellcheck disable=SC2153  # global set by the sourced lib
    if [ "${HAS_CONTENT:-0}" -eq 0 ]; then
        # Genuinely contentless transcript — leave the husk as-is.
        CNT_REHEAL_INERT=$((CNT_REHEAL_INERT + 1))
        return 0
    fi

    # Recoverable in principle (a content-bearing transcript). In dry-run this is
    # the count the operator wants — how many husks could be lifted.
    if [ "$DRY_RUN" = "true" ]; then
        CNT_REHEAL=$((CNT_REHEAL + 1))
        return 0
    fi

    # Apply. The husk predicate clears only two ways:
    #   * the LLM crystallizer sets `crystallized: true`, OR
    #   * a mechanical re-render produces a real Raw Conversation, which needs a
    #     non-empty final assistant turn (a tool/thinking-only transcript still
    #     renders "_Transcript unavailable._", so a mechanical pass cannot lift
    #     it out of husk-hood — only the crystallizer can).
    local healed=0
    # shellcheck disable=SC2153  # LAST_ASSISTANT set by parse_session_transcript
    if _claude_available; then
        # Trust the crystallizer when claude is available. Synchronous (not
        # detached): reheal is a batch op, one note at a time; crystallize-note.sh
        # is idempotent and fail-open. If it does NOT clear the husk (cap / race /
        # error), LEAVE the note as-is for a later run — never mechanically
        # overwrite after a claude attempt, which could clobber a partial LLM edit.
        bash "$SCRIPT_DIR/crystallize-note.sh" "$note" "$jl" || true
        _is_husk_note "$note" || healed=1
    elif [ -n "${LAST_ASSISTANT:-}" ]; then
        # No claude: a mechanical re-render recovers a real Summary/Commands and
        # clears the husk (the prose turn fills Raw Conversation). Guarded write —
        # only counts healed when the overwrite actually succeeds.
        if _mechanical_reheal "$note" "$jl"; then healed=1; fi
    fi
    if [ "$healed" -eq 1 ]; then
        CNT_REHEAL=$((CNT_REHEAL + 1))
        # Per-note line (HIMMEL-627): show each heal as it lands on a real run.
        printf 'reheal: healed %s (%d)\n' "$(basename "$note")" "$CNT_REHEAL" >&2
    else
        # Couldn't clear the husk this run (crystallizer unavailable/failed, or
        # no claude AND no prose turn). Left byte-unchanged — idempotent; a later
        # run with claude available can still crystallize it.
        CNT_REHEAL_INERT=$((CNT_REHEAL_INERT + 1))
    fi
}

# ===========================================================================
# Recrystallize mode (HIMMEL-620) — crystallize ANY note with crystallized != true
# that has a recoverable (content-bearing) transcript, NOT just husks. --reheal is
# husk-only (crystallized!=true AND "_Transcript unavailable._" AND Files None), so
# it SKIPS content-bearing-but-uncrystallized notes — which is the common shape of
# both an F1-affected live note and a backfilled prose-session note. This mode
# closes that gap. Crystallization needs the LLM (a mechanical re-render stays
# crystallized:false), so a missing `claude` skips rather than degrades.
# ===========================================================================
_recrystallize_one() { # <note>
    local note="$1"
    # Already crystallized -> nothing to do (idempotent).
    if grep -q '^crystallized: true$' "$note" 2>/dev/null; then
        CNT_RECRYS_SKIP=$((CNT_RECRYS_SKIP + 1))
        return 0
    fi
    local sid jl
    sid="$(_note_fm session_id "$note")"
    jl="$(_find_transcript "$sid")"
    if [ -z "$jl" ]; then
        CNT_RECRYS_SKIP=$((CNT_RECRYS_SKIP + 1))   # transcript gone — can't crystallize
        return 0
    fi
    parse_session_transcript "$jl"
    # shellcheck disable=SC2153  # global set by the sourced lib
    if [ "${HAS_CONTENT:-0}" -eq 0 ]; then
        CNT_RECRYS_SKIP=$((CNT_RECRYS_SKIP + 1))   # no salvageable content to distil
        return 0
    fi
    if ! _claude_available; then
        CNT_RECRYS_SKIP=$((CNT_RECRYS_SKIP + 1))   # recrystallize is LLM-only
        return 0
    fi
    # Dry-run reports the FULL recoverable count (limit not applied) so the operator
    # can size --limit batches against the real token cost.
    if [ "$DRY_RUN" = "true" ]; then
        CNT_RECRYS=$((CNT_RECRYS + 1))
        return 0
    fi
    # --limit caps real crystallizations (token-cost guard); remaining are skipped
    # and recoverable on a later run (idempotent).
    if [ "$RECRYS_LIMIT" -gt 0 ] && [ "$CNT_RECRYS" -ge "$RECRYS_LIMIT" ]; then
        CNT_RECRYS_SKIP=$((CNT_RECRYS_SKIP + 1))
        return 0
    fi
    # Synchronous (not detached): batch op, one note at a time; crystallize-note.sh
    # is idempotent + fail-open. Count crystallized only when the flag actually flips.
    bash "$SCRIPT_DIR/crystallize-note.sh" "$note" "$jl" || true
    if grep -q '^crystallized: true$' "$note" 2>/dev/null; then
        CNT_RECRYS=$((CNT_RECRYS + 1))
        # Per-note line (HIMMEL-627): on a real run, show each crystallization as
        # it lands so --limit chunk progress is visible note-by-note. stderr only;
        # the machine-parseable summary stays on stdout.
        printf 'recrystallize: crystallized %s (%d)\n' "$(basename "$note")" "$CNT_RECRYS" >&2
    else
        CNT_RECRYS_SKIP=$((CNT_RECRYS_SKIP + 1))   # cap/race/error — left for a later run
    fi
}

# Enumerate husk-candidate notes (all sessions/**/*.md) into TMP_JSONL_LIST.
_run_reheal() {
    local vault_root
    vault_root="$(resolve_vault_root "/reheal-no-config-placeholder" "$VAULT_REGISTRY" "$DRY_RUN")"
    if [ -z "$vault_root" ]; then
        printf 'backfill: reheal: vault unresolved (set --luna-vault-path or a registry default)\n' >&2
        exit 1
    fi
    # shellcheck disable=SC2088
    case "$vault_root" in "~/"*) vault_root="$_HOME/${vault_root#\~/}" ;; esac

    local mode="reheal"
    [ "$RECRYSTALLIZE" = "true" ] && mode="recrystallize"

    local sessions_dir="$vault_root/sessions"
    if [ ! -d "$sessions_dir" ]; then
        printf 'backfill: %s: no sessions/ under %s\n' "$mode" "$vault_root" >&2
        if [ "$mode" = "recrystallize" ]; then
            printf 'recrystallize: crystallized=0 skipped=0\n'
        else
            printf 'reheal: healed=0 inert=0 non-husk-skip=0\n'
        fi
        return 0
    fi

    # Collect note paths first (avoid the pipe-subshell counter problem).
    find "$sessions_dir" -type f -name '*.md' 2>/dev/null > "$TMP_JSONL_LIST"

    # Total candidate count drives the X/total heartbeat below. Perf follow-up
    # (HIMMEL-627, NOT built here): _find_transcript globs all ~188 project dirs
    # per note -> the scan is O(notes * projectdirs); a one-time project-dir index
    # (session_id -> path) would cut it to O(N + projectdirs).
    local total scanned=0
    total="$(awk 'END{print NR}' "$TMP_JSONL_LIST" 2>/dev/null)"
    [ -n "$total" ] || total=0

    while IFS= read -r note; do
        [ -n "$note" ] || continue
        scanned=$((scanned + 1))
        if [ "$mode" = "recrystallize" ]; then
            _recrystallize_one "$note"
        else
            _reheal_one "$note"
        fi
        # Periodic heartbeat to stderr (HIMMEL-627): every PROGRESS_EVERY notes,
        # report scanned X/total + running counts so a multi-minute run is
        # observably alive. Summary line (stdout) is unaffected.
        if [ "$PROGRESS_EVERY" -gt 0 ] && [ $((scanned % PROGRESS_EVERY)) -eq 0 ]; then
            if [ "$mode" = "recrystallize" ]; then
                printf 'recrystallize: scanned %d/%d (crystallized %d, skipped %d)\n' \
                    "$scanned" "$total" "$CNT_RECRYS" "$CNT_RECRYS_SKIP" >&2
            else
                printf 'reheal: scanned %d/%d (healed %d, inert %d, non-husk-skip %d)\n' \
                    "$scanned" "$total" "$CNT_REHEAL" "$CNT_REHEAL_INERT" "$CNT_REHEAL_SKIP" >&2
            fi
        fi
    done < "$TMP_JSONL_LIST"

    if [ "$mode" = "recrystallize" ]; then
        printf 'recrystallize: crystallized=%d skipped=%d' "$CNT_RECRYS" "$CNT_RECRYS_SKIP"
        [ "$RECRYS_LIMIT" -gt 0 ] && printf ' (--limit %d)' "$RECRYS_LIMIT"
        printf '\n'
    else
        printf 'reheal: healed=%d inert=%d non-husk-skip=%d\n' \
            "$CNT_REHEAL" "$CNT_REHEAL_INERT" "$CNT_REHEAL_SKIP"
    fi
}

if [ "$REHEAL" = "true" ] || [ "$RECRYSTALLIZE" = "true" ]; then
    _run_reheal
    exit 0
fi

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
printf 'backfill: new=%d already-in-ledger=%d opt-out-skip=%d orphaned-skip=%d under-min=%d husk-skip=%d\n' \
    "$CNT_NEW" "$CNT_LEDGER" "$CNT_OPTOUT" "$CNT_ORPHANED" "$CNT_UNDERMIN" "$CNT_HUSK"

# Crystallization nudge (HIMMEL-590 F3 / HIMMEL-620): plain backfill writes
# MECHANICAL notes (crystallized: false) — only the live end-session hook and the
# crystallize passes run the LLM crystallizer. Auto-spawning it per imported note
# during a bulk `--all` import would fan out an unbounded number of billed
# `claude` runs, so backfill deliberately does NOT; instead it points the operator
# at the explicit, concurrency-capped, idempotent pass. A backfilled prose-session
# note is content-bearing (NOT a husk), so `--recrystallize` (not `--reheal`,
# which is husk-only) is the mode that crystallizes it. Printed only when notes
# landed.
if [ "$DRY_RUN" != "true" ] && [ "$CNT_NEW" -gt 0 ]; then
    printf '\nbackfill: %d new note(s) are mechanical (crystallized: false).\n' "$CNT_NEW"
    printf 'backfill: preview the crystallize cost, then run it (one real claude run per note):\n'
    printf '    bash scripts/luna/backfill-sessions.sh --recrystallize --dry-run   # count\n'
    printf '    bash scripts/luna/backfill-sessions.sh --recrystallize [--limit N] # apply\n'
    printf 'backfill: (add the same --all / --luna-vault-path / --vault-registry scope you used here).\n'
fi
