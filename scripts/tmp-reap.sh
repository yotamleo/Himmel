#!/usr/bin/env bash
# scripts/tmp-reap.sh - preserve-then-reap for the /tmp tmpfs (HIMMEL-4224).
#
#   tmp-reap.sh            dry-run (default): print the KEEP / REAP list with sizes
#   tmp-reap.sh --apply    archive what is worth keeping, then reap
#
# Scanned (TMP_REAP_TMP_ROOT, default /tmp):
#   <root>/claude-<uid>/<project>/<session-uuid>   per-session scratch
#   <root>/claude-<uid>/j<NNNN>[a-z]               judge dirs
#   <root>/<fixture family>.*                      leaked test fixtures
# Overrides (tests use them and never touch the real paths):
#   TMP_REAP_TMP_ROOT, TMP_REAP_ARCHIVE_ROOT (default ~/.himmel/eval/archive),
#   TMP_REAP_SESSIONS_DIR (default ~/.claude/sessions).
#
# Preserve first: a whitelist copy (self-eval corpora and per-PR verdicts, under
# 5 MB, never a checkout dir) into <archive>/<YYYY-MM>/<kind>/<id>/ plus one
# MANIFEST.jsonl row per file. A session/judge dir whose preserve pass wrote no
# manifest row is never reaped. Never guess: when unsure, keep.
# Delete order: fixtures, then judge dirs, then dead-session scratch by size.
#
# ponytail: liveness sees same-uid processes only (/proc of other users is
# unreadable), and the whitelist is name-based; widen if a kind goes missing
# (HIMMEL-4224 follow-ups). A dry-run over ~50k leaked dirs takes ~10 min (a du
# and a stat per dir); batch them if the leak is not fixed at the callers.
# shellcheck disable=SC2086  # word-splitting a /proc line and a jq row into positionals is the point
set -u

usage() { echo "usage: tmp-reap.sh [--dry-run|--apply]" ; }
APPLY=0
case "${1:-}" in
    ''|--dry-run) ;;
    --apply) APPLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "tmp-reap: jq is required" >&2; exit 2; }

TMP_ROOT="${TMP_REAP_TMP_ROOT:-/tmp}"
CLAUDE_ROOT="$TMP_ROOT/claude-$(id -u)"
ARCHIVE="${TMP_REAP_ARCHIVE_ROOT:-$HOME/.himmel/eval/archive}"
SESSIONS="${TMP_REAP_SESSIONS_DIR:-$HOME/.claude/sessions}"
MANIFEST="$ARCHIVE/MANIFEST.jsonl"
JUDGE_AGE=21600     # 6 h
FIXTURE_AGE=3600    # 1 h
SESSION_AGE=3600    # 1 h floor on a dead session dir: a just-created dir may predate its sessions file
MAX_BYTES=5242880
NOW="$(date +%s)"
MONTH="$(date +%Y-%m)"
FAMILIES="mog-run.* mog-home.* himmel-git-empty-template.* himmel-fixture.* himmel-prov.* capguard-* poller-* cr-floor-probe-* clean-sandbox.* rt-tarball-out.*"

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$NOW"; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }
size_kb() { du -sk "$1" 2>/dev/null | cut -f1; }

# /proc/<pid>/stat field 22 (starttime), taken after the last ')' so a comm with spaces cannot shift it.
proc_start() {
    local s
    s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    s="${s##*) }"
    set -f; set -- $s; set +f
    [ "$#" -ge 20 ] || return 1
    shift 19
    echo "$1"
}

# Session ids whose pid is alive AND whose start time matches procStart (guards pid reuse).
LIVE_IDS=""
if [ -d "$SESSIONS" ]; then
    for f in "$SESSIONS"/*.json; do
        [ -f "$f" ] || continue
        row="$(jq -r '[.sessionId // "", (.pid // "" | tostring), (.procStart // "" | tostring)] | join(" ")' "$f" 2>/dev/null)" || continue
        set -f; set -- $row; set +f
        [ "$#" -eq 3 ] || continue
        [ -d "/proc/$2" ] || continue
        [ "$(proc_start "$2")" = "$3" ] && LIVE_IDS="$LIVE_IDS
$1"
    done
fi
session_live() { case "$LIVE_IDS
" in *"
$1
"*) return 0 ;; esac; return 1; }

# Every cwd / open-fd path of a process, filtered to the scanned roots once.
OPEN_PATHS="$(
    for p in /proc/[0-9]*; do
        readlink "$p/cwd" 2>/dev/null
        for fd in "$p"/fd/*; do [ -e "$fd" ] && readlink "$fd" 2>/dev/null; done
    done | grep -F "$TMP_ROOT/" | sort -u
)"
in_use() { # a process cwd or open fd at or under $1
    local p
    [ -n "$OPEN_PATHS" ] || return 1
    while IFS= read -r p; do
        case "$p" in "$1"|"$1"/*) return 0 ;; esac
    done <<EOF
$OPEN_PATHS
EOF
    return 1
}

# kind of a whitelisted file name, or empty
file_kind() {
    case "$1" in
        suite-verdicts.txt|commit.txt|pr-title.txt|pr-body.md) echo pr-verdicts ;;
        corpus*.jsonl|res-*.jsonl|hist.jsonl|adv*.jsonl|all.jsonl|rec-*.log|diff-suite.txt|f[0-9]*.out) echo judge-corpus ;;
    esac
}

whitelist_files() { # <dir>: files worth keeping, never inside a checkout/fixture dir
    find "$1" \( -type d \( -name base -o -name head -o -name fx -o -name tree -o -name stub -o -name exp \
        -o -name probe -o -name cwd -o -name home -o -name hh -o -name fxrepo -o -name .git -o -name node_modules \) -prune \) \
        -o -type f -size -$((MAX_BYTES / 1024))k -print 2>/dev/null
}

manifest_row() { # src dest sha bytes id kind
    jq -cn --arg src "$1" --arg dest "$2" --arg sha "$3" --argjson bytes "$4" --arg id "$5" --arg kind "$6" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{src:$src,dest:$dest,sha256:$sha,bytes:$bytes,id:$id,kind:$kind,archived_at:$at}' >> "$MANIFEST"
}

preserve() { # <dir> <id>; 0 only when every copy verified and a manifest row exists for <id>
    local dir="$1" id="$2" f rel k dest sum n=0
    mkdir -p "$ARCHIVE" 2>/dev/null && : >> "$MANIFEST" 2>/dev/null || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        k="$(file_kind "${f##*/}")"; [ -n "$k" ] || continue
        rel="${f#"$dir"/}"
        dest="$ARCHIVE/$MONTH/$k/$id/$rel"
        mkdir -p "${dest%/*}" && cp -p "$f" "$dest" && cmp -s "$f" "$dest" || return 1
        sum="$(sha "$dest")"
        manifest_row "$f" "$dest" "$sum" "$(wc -c < "$dest" | tr -d ' ')" "$id" "$k" || return 1
        n=$((n+1))
    done <<EOF
$(whitelist_files "$dir")
EOF
    # nothing worth keeping is still a completed preserve pass: record it, so the refusal rule has a row to check
    [ "$n" -gt 0 ] || manifest_row "$dir" "" "" 0 "$id" none || return 1
    grep -qF "\"id\":\"$id\"" "$MANIFEST"
}

# --- classify -----------------------------------------------------------------
CANDS=""   # "<tier> <size_kb> <kind> <id> <path>" for every dir that is reapable
note_keep() { printf 'KEEP %-8s %8sK %s (%s)\n' "$1" "$2" "$3" "$4"; }
add_reap() { CANDS="$CANDS
$1 $2 $3 $4 $5"; }
consider() { # <tier> <kind> <id> <path> <min_age_s> <live:0|1>
    local tier="$1" kind="$2" id="$3" path="$4" min_age="$5" live="$6" kb age
    [ -d "$path" ] && [ ! -L "$path" ] || return 0
    kb="$(size_kb "$path")"
    if [ "$live" = 1 ]; then note_keep "$kind" "$kb" "$path" "live session"; return 0; fi
    if in_use "$path"; then note_keep "$kind" "$kb" "$path" "process cwd/fd under it"; return 0; fi
    age=$((NOW - $(mtime "$path")))
    if [ "$age" -lt "$min_age" ]; then note_keep "$kind" "$kb" "$path" "younger than ${min_age}s"; return 0; fi
    add_reap "$tier" "$kb" "$kind" "$id" "$path"
}

if [ -d "$CLAUDE_ROOT" ]; then
    for d in "$CLAUDE_ROOT"/-*/*; do
        # only <project>/<uuid>; judge dirs, bash-edit-diff/ and s/ are not sessions
        [ -d "$d" ] || continue
        id="${d##*/}"
        printf '%s\n' "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || continue
        live=0; session_live "$id" && live=1
        consider 3 session "$id" "$d" "$SESSION_AGE" "$live"
    done
    for d in "$CLAUDE_ROOT"/j[0-9]*; do
        consider 2 judge "${d##*/}" "$d" "$JUDGE_AGE" 0
    done
fi
for fam in $FAMILIES; do
    for d in "$TMP_ROOT"/$fam; do
        [ -O "$d" ] || continue
        consider 1 fixture "${d##*/}" "$d" "$FIXTURE_AGE" 0
    done
done

# fixtures, then judge dirs, then session scratch; biggest first inside a tier
SORTED="$(printf '%s\n' "$CANDS" | grep -v '^$' | sort -k1,1n -k2,2nr)"
total=0; reaped=0; failed=0
while read -r tier kb kind id path; do
    [ -n "$path" ] || continue
    total=$((total + kb))
    if [ "$APPLY" = 0 ]; then
        printf 'REAP %-8s %8sK %s (dry-run)\n' "$kind" "$kb" "$path"
        continue
    fi
    if [ "$kind" != fixture ] && ! preserve "$path" "$id"; then
        printf 'SKIP %-8s %8sK %s (preserve failed, not reaped)\n' "$kind" "$kb" "$path"
        failed=$((failed+1)); continue
    fi
    if rm -rf -- "$path"; then
        printf 'REAP %-8s %8sK %s\n' "$kind" "$kb" "$path"; reaped=$((reaped+1))
    else
        printf 'SKIP %-8s %8sK %s (rm failed)\n' "$kind" "$kb" "$path"; failed=$((failed+1))
    fi
done <<EOF
$SORTED
EOF

# cache-break state is tiny and has no uuid dir: copy-only, never reaped
if [ "$APPLY" = 1 ] && [ -d "$CLAUDE_ROOT" ]; then
    for f in "$CLAUDE_ROOT"/cache-break-state-*.json; do
        [ -f "$f" ] || continue
        id="${f##*/cache-break-state-}"; id="${id%.json}"
        dest="$ARCHIVE/$MONTH/cache-break/$id/${f##*/}"
        [ -f "$dest" ] && continue
        mkdir -p "${dest%/*}" 2>/dev/null && cp -p "$f" "$dest" 2>/dev/null && manifest_row "$f" "$dest" "$(sha "$dest")" "$(wc -c < "$dest" | tr -d ' ')" "$id" cache-break
    done
fi

if [ "$APPLY" = 1 ]; then
    printf 'tmp-reap: reaped %d dir(s), %d skipped, %dK considered\n' "$reaped" "$failed" "$total"
    [ "$failed" -eq 0 ]
else
    printf 'tmp-reap: dry-run, %dK reapable (re-run with --apply to archive then reap)\n' "$total"
fi
