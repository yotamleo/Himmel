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
#   TMP_REAP_SESSIONS_DIR (default ~/.claude/sessions),
#   TMP_REAP_PROC (default /proc, the census walk root),
#   TMP_REAP_UID (default $(id -u), the uid census compares /proc owners against).
#
# Preserve first: a whitelist copy (self-eval corpora and per-PR verdicts, under
# 5 MB, never a checkout dir) into <archive>/<YYYY-MM>/<kind>/<id>/ plus one
# MANIFEST.jsonl row per file. A session/judge dir whose preserve pass wrote no
# manifest row is never reaped. Never guess: when unsure, keep.
# Delete order: fixtures, then judge dirs, then dead-session scratch by size.
#
# ponytail: a dir held only by an other-uid process (e.g. root) is still invisible
# to the census (an unreadable same-uid /proc entry refuses --apply, other-uid ones
# only warn); add a privileged census if a root-held dir is ever reaped. The
# whitelist is name-based; widen if a kind goes missing (HIMMEL-4224 follow-ups).
# Fixture names with whitespace are not handled (the families are mktemp names);
# session/judge dirs still cost a du and stat each.
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
# liveness is read from /proc: without it nothing can be proven dead, so never apply
if [ "$APPLY" = 1 ] && [ ! -r /proc/self/stat ]; then echo "tmp-reap: /proc is unreadable, refusing --apply" >&2; exit 2; fi

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
sha() { # sha256 hex of a file, non-zero when neither tool can read it
    local s
    s="$(sha256sum "$1" 2>/dev/null)" || s="$(shasum -a 256 "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${s%% *}"
}
owner() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }
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

# Every cwd / open-fd path of a process, filtered to the scanned roots once. A pid
# whose cwd cannot be read is counted by owner: an unreadable same-uid entry could
# hide a live dir, so --apply refuses; other-uid ones only warn. A zombie holds no cwd.
CENSUS_WARNED=0
census() {
    local proc="${TMP_REAP_PROC:-/proc}" me="${TMP_REAP_UID:-$(id -u)}" raw same other o st
    if [ ! -d "$proc" ] || [ ! -r "$proc" ] || [ ! -x "$proc" ]; then   # no readable census root = no liveness snapshot at all
        echo "tmp-reap: census root $proc is not a readable directory; refusing" >&2
        [ "$APPLY" = 1 ] && exit 2
    fi
    raw="$(
        for p in "$proc"/[0-9]*; do
            if ! readlink "$p/cwd" 2>/dev/null; then
                [ -d "$p" ] || continue   # exited mid-walk
                st="$(cat "$p/stat" 2>/dev/null)"; st="${st##*) }"   # state follows the LAST ')' (a comm may hold ') Z ')
                case "$st" in "Z "*) continue ;; esac
                o="$(owner "$p")"
                [ -n "$o" ] || [ -d "$p" ] || continue   # exited between the checks
                # an unknown owner counts as same-uid: unknown is never safe
                case "$o" in ''|*[!0-9]*) o="$me" ;; esac   # non-numeric (a stat -f fallback's fs report) is unknown too
                if [ "$o" = "$me" ]; then echo '@@unread same'; else echo '@@unread other'; fi
            fi
            for fd in "$p"/fd/*; do [ -e "$fd" ] && readlink "$fd" 2>/dev/null; done
        done
    )"
    same="$(printf '%s\n' "$raw" | grep -c '^@@unread same$')"
    other="$(printf '%s\n' "$raw" | grep -c '^@@unread other$')"
    OPEN_PATHS="$(printf '%s\n' "$raw" | grep -v '^@@unread ' | grep -F "$TMP_ROOT/" | sort -u)"
    if [ "$other" -gt 0 ] && [ "$CENSUS_WARNED" = 0 ]; then
        echo "WARN tmp-reap: $other other-uid /proc entries unreadable (expected on a multi-user host; not checked)" >&2
    fi
    if [ "$same" -gt 0 ]; then
        if [ "$APPLY" = 1 ]; then
            echo "tmp-reap: $same same-uid /proc entr(ies) unreadable: a live dir could be held by one; refusing --apply" >&2
            exit 2
        fi
        [ "$CENSUS_WARNED" = 1 ] || echo "WARN tmp-reap: $same same-uid /proc entr(ies) unreadable; --apply would refuse" >&2
    fi
    CENSUS_WARNED=1
}
census
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
    local dir="$1" id="$2" f rel k dest sum n=0 files
    mkdir -p "$ARCHIVE" 2>/dev/null && : >> "$MANIFEST" 2>/dev/null || return 1
    # a failed or partial scan must not read as "nothing left to keep"
    files="$(whitelist_files "$dir")" || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        k="$(file_kind "${f##*/}")"; [ -n "$k" ] || continue
        rel="${f#"$dir"/}"
        dest="$ARCHIVE/$MONTH/$k/$id/$rel"
        # never overwrite an earlier, different copy (a reused judge id): refuse, so the dir is kept
        if [ -e "$dest" ] && ! cmp -s "$f" "$dest"; then return 1; fi
        mkdir -p "${dest%/*}" && cp -p "$f" "$dest" && cmp -s "$f" "$dest" || return 1
        sum="$(sha "$dest")" && [ -n "$sum" ] || return 1
        manifest_row "$f" "$dest" "$sum" "$(wc -c < "$dest" | tr -d ' ')" "$id" "$k" || return 1
        n=$((n+1))
    done <<EOF
$files
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
# Fixtures: one find per family (no per-dir process) and one batched du. An old
# fixture with a process cwd/fd under it is kept.
[ "$APPLY" = 1 ] && census   # fresh view: session classification above may have taken a while
fix_total=0; fix_reaped=0; fix_failed=0
# no pathname expansion: a family like mog-run.* must not glob against the caller's cwd
set -f
for fam in $FAMILIES; do
    list=""; n=0
    # shellcheck disable=SC2044  # mktemp family names carry no whitespace (see ponytail above)
    for d in $(find "$TMP_ROOT" -maxdepth 1 -type d -name "$fam" -user "$(id -un)" -mmin +$((FIXTURE_AGE / 60)) 2>/dev/null); do
        in_use "$d" && continue
        list="$list$d
"
        n=$((n+1))
    done
    all="$(find "$TMP_ROOT" -maxdepth 1 -type d -name "$fam" -user "$(id -un)" 2>/dev/null | wc -l | tr -d ' ')"
    kept=$((all - n))
    if [ "$n" -eq 0 ]; then
        [ "$kept" -eq 0 ] || printf 'KEEP fixture  %s: %d kept (young or in use)\n' "$fam" "$kept"
        continue
    fi
    kb="$(printf '%s' "$list" | tr '\n' '\0' | xargs -0 du -sck 2>/dev/null | tail -1 | cut -f1)"
    fix_total=$((fix_total + ${kb:-0}))
    if [ "$APPLY" = 1 ]; then
        # a fixture can leave a non-writable sub/ dir; same uid (find -user above), so make it writable first
        printf '%s' "$list" | tr '\n' '\0' | xargs -0 chmod -R u+rwX -- 2>/dev/null || :
        if printf '%s' "$list" | tr '\n' '\0' | xargs -0 rm -rf --; then
            fix_reaped=$((fix_reaped + n))
            printf 'REAP fixture  %s: %d dir(s), %sK; %d kept\n' "$fam" "$n" "${kb:-0}" "$kept"
        else
            fix_failed=$((fix_failed + 1))
            printf 'SKIP fixture  %s: rm failed for some of %d dir(s), not counted as reaped\n' "$fam" "$n"
        fi
    else
        printf 'REAP fixture  %s: %d dir(s), %sK; %d kept (dry-run)\n' "$fam" "$n" "${kb:-0}" "$kept"
    fi
done
set +f

# fixtures, then judge dirs, then session scratch; biggest first inside a tier
SORTED="$(printf '%s\n' "$CANDS" | grep -v '^$' | sort -k1,1n -k2,2nr)"
# classification took minutes on a big /tmp: re-take the cwd/fd view once before deleting.
# ponytail: a full /proc walk costs ~10 s, so it is once per run, not per dir; a dir that
# goes live within the archive loop itself is not re-checked (HIMMEL-4224 follow-up).
[ "$APPLY" = 1 ] && census
total=$fix_total; reaped=$fix_reaped; failed=$fix_failed
while read -r tier kb kind id path; do
    [ -n "$path" ] || continue
    total=$((total + kb))
    if [ "$APPLY" = 0 ]; then
        printf 'REAP %-8s %8sK %s (dry-run)\n' "$kind" "$kb" "$path"
        continue
    fi
    if in_use "$path"; then
        printf 'SKIP %-8s %8sK %s (became active, kept)\n' "$kind" "$kb" "$path"
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
        if ! { mkdir -p "${dest%/*}" 2>/dev/null && cp -p "$f" "$dest" 2>/dev/null && manifest_row "$f" "$dest" "$(sha "$dest")" "$(wc -c < "$dest" | tr -d ' ')" "$id" cache-break; }; then
            printf 'SKIP cache-break %s (archive failed)\n' "$f"; failed=$((failed+1))
        fi
    done
fi

if [ "$APPLY" = 1 ]; then
    printf 'tmp-reap: reaped %d dir(s), %d skipped, %dK considered\n' "$reaped" "$failed" "$total"
    [ "$failed" -eq 0 ]
else
    printf 'tmp-reap: dry-run, %dK reapable (re-run with --apply to archive then reap)\n' "$total"
fi
