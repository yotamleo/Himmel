#!/usr/bin/env bash
# scripts/statusline/lib/all-sessions-index.sh — the all-sessions economics
# index rebuild, extracted into a sourceable lib (HIMMEL-718 Task 3.2).
#
# WHY this file exists: the spawn-free hud composer (scripts/statusline/
# hud-custom-lines.sh) reads the all-sessions economics cache but must NOT
# rebuild it on the render path (the detached rebuild is the orphaned-bash leak
# class this migration eliminates). The rebuild relocates to the periodic hook
# (scripts/hooks/refresh-statusline-caches-periodic.sh). Both the composer (for
# resolve_window) and the hook (for the rebuild) source this lib.
#
# Extracted VERBATIM from scripts/statusline/bin/statusline.sh (resolve_window +
# rebuild_all_sessions_index) so behaviour is byte-identical. The legacy bar
# keeps its own inline copy until it is decommissioned (plan Task 5.4), at which
# point this lib is the single home. Do NOT diverge the two copies meanwhile —
# the composer-parity test guards the economics output.
#
# Sourceable ONLY (no top-level execution). Idempotent re-source guard.
[ -n "${_ALL_SESSIONS_INDEX_SH:-}" ] && return 0
_ALL_SESSIONS_INDEX_SH=1

# Resolves the bottom cache-row aggregation window for a period. Sets, in the
# CALLER's scope: window_id, window_start (inclusive epoch), window_end
# (exclusive epoch).
#   - all   → window_id "all-stats", unbounded. This keeps the legacy cache
#             filenames (cache-all-stats{,-index}.json) byte-for-byte, so the
#             default path and any external consumer are untouched.
#   - week  → ISO Monday-start (local), 7-day span.
#   - month → calendar month (local), 1st 00:00 to next 1st 00:00.
#   - invalid → falls back to all + a one-line stderr warning.
# `now` is overridable via HIMMEL_STATUSLINE_NOW (epoch) so a test can cross a
# week/month boundary without faking the wall clock (the script otherwise has
# no seam — it calls `date +%s` inline). The per-window filenames also give the
# boundary reset for free: a new window_id is a new file → cache miss → rebuild.
# shellcheck disable=SC2034  # window_id/window_start/window_end are this
# function's OUTPUTS — set in the caller's scope, read by the caller (not here).
resolve_window() {
    local period="$1"
    local now="${HIMMEL_STATUSLINE_NOW:-$(date +%s)}"
    case "$period" in
        week)
            local dow ymd midnight
            dow=$(date -d "@$now" +%u 2>/dev/null || date -r "$now" +%u 2>/dev/null || echo 1)
            ymd=$(date -d "@$now" +%Y-%m-%d 2>/dev/null || date -r "$now" +%Y-%m-%d 2>/dev/null)
            midnight=$(date -d "$ymd 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ymd 00:00:00" +%s 2>/dev/null)
            window_start=$(( midnight - (dow - 1) * 86400 ))
            window_end=$(( window_start + 7 * 86400 ))
            window_id="week-$(date -d "@$window_start" +%Y%m%d 2>/dev/null || date -r "$window_start" +%Y%m%d 2>/dev/null)"
            ;;
        month)
            local ym nextym
            ym=$(date -d "@$now" +%Y-%m 2>/dev/null || date -r "$now" +%Y-%m 2>/dev/null)
            window_start=$(date -d "$ym-01 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$ym-01 00:00:00" +%s 2>/dev/null)
            # Resolve the NEXT month's label first, then re-parse a clean local
            # midnight for the end — adding "+1 month" to a datetime can drift an
            # hour on some date(1) builds, so we never use it as an epoch directly.
            nextym=$(date -d "$ym-01 00:00:00 +1 month" +%Y-%m 2>/dev/null || date -j -v+1m -f "%Y-%m-%d %H:%M:%S" "$ym-01 00:00:00" +%Y-%m 2>/dev/null)
            window_end=$(date -d "$nextym-01 00:00:00" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$nextym-01 00:00:00" +%s 2>/dev/null)
            window_id="month-${ym/-/}"
            ;;
        all)
            window_id="all-stats"; window_start=0; window_end=9999999999
            ;;
        *)
            echo "statusline: invalid HIMMEL_STATUSLINE_PERIOD='$period'; falling back to all" >&2
            window_id="all-stats"; window_start=0; window_end=9999999999
            ;;
    esac
}

# Rebuilds the all-sessions cache incrementally. Sets nothing; writes totals
# to $2 (cache_file) and a per-file sums index to $3 (index_file), atomically.
# Optional $4/$5 (win_start/win_end epochs) switch on WINDOWED mode: files whose
# mtime predates win_start are dropped (they can hold no in-window messages —
# bounds the scan), and surviving files are re-summed per-message on
# `.timestamp ∈ [win_start,win_end)`. Per-window-id per-file sums are still
# immutable (a fixed week/month + an unchanged file = a fixed sum), so the same
# `-newer` memoization stays valid within a window. With no win args the path is
# the legacy unbounded immutable-per-file index, byte-identical to before.
#
# Why this is not a one-line glob: the old version ran
#   cat "$HOME/.claude/projects"/*/*.jsonl | timeout 10 jq -s ...
# which has two fatal flaws once a few hundred sessions accumulate:
#   1. The glob expands to hundreds of paths — on Windows/MSYS that overflows
#      the ~32KB argv limit, so `cat` dies with "Argument list too long",
#      stderr is swallowed, jq slurps empty input, and every field sums to 0
#      (the "all = 0" bug).
#   2. Even on Linux/macOS it re-reads the entire, ever-growing history (100s
#      of MB) every refresh — far slower than the 10s timeout, which then
#      kills it and again writes 0.
# This version scans with `find` (streams, no argv limit), recomputes only the
# files changed since the last index (`-newer`), and memoizes per-file sums so
# steady-state refreshes touch just the active session. All bulk data flows
# through temp files / stdin, never jq args, to stay under the argv limit.
rebuild_all_sessions_index() {
    local proj_root="$1" cache_file="$2" index_file="$3"
    local win_start="${4:-}" win_end="${5:-}"
    local old_index all_paths recompute_paths recomputed out
    local tmp_old tmp_all tmp_rc tmp

    old_index=$(cat "$index_file" 2>/dev/null)
    echo "$old_index" | jq -e 'type == "object"' >/dev/null 2>&1 || old_index='{}'

    # Current transcripts (one dir level down). `find` streams paths, so this
    # never hits the argv limit the glob did.
    all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null)
    [ -z "$all_paths" ] && return

    # Windowed mode: drop files whose mtime predates the window start — none of
    # their messages can fall in [start,end), so this only bounds the scan, it
    # never changes the result. The `all` path skips this and keeps every file.
    #
    # The mtime filter MUST run inside a single `find`, not a bash stat-per-file
    # loop: each `stat` is a separate process, and on a large history (1000+
    # transcripts) that is 1000+ process spawns — on Git-Bash/Windows that alone
    # overruns the render timeout, so the backgrounded rebuild never finishes and
    # the per-window cache stays at 0 (the "week/month row renders 0" bug). We
    # use a reference file + POSIX `-newer` (portable GNU/BSD) rather than the
    # GNU-only `-newermt`; the reference mtime is win_start-1 so the boundary
    # stays inclusive (>=), matching the per-message [start,end) test below.
    if [ -n "$win_start" ]; then
        local _ref="" _reffail=""
        _ref=$(mktemp 2>/dev/null) || _reffail=1
        if [ -z "$_reffail" ]; then
            touch -d "@$(( win_start - 1 ))" "$_ref" 2>/dev/null \
                || touch -t "$(date -r "$(( win_start - 1 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$_ref" 2>/dev/null \
                || _reffail=1
        fi
        if [ -z "$_reffail" ]; then
            all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$_ref" 2>/dev/null)
        fi
        # If the reference file could not be built, all_paths keeps the unbounded
        # list: the per-message jq still yields a correct windowed sum, only the
        # scan is unbounded — a slow-but-correct render beats a 0.
        [ -n "$_ref" ] && rm -f "$_ref" 2>/dev/null
        [ -z "$all_paths" ] && return
    fi

    # Files to recompute: those modified since the last index write (so the
    # active session and any new files), or everything on a cold first run.
    #
    # PLUS a bounded backfill of transcripts ABSENT from the carried-forward
    # index (HIMMEL-698). A file that predates the index's first write and was
    # never itself the freshly-written active transcript is never `-newer`, so
    # without this it is never recomputed and — because it never entered
    # $oldidx either — is permanently dropped from the aggregate: the reduce
    # below skips any path that is neither in $rc nor $oldidx. On a large
    # history whose cold full-scan never completed, the "all" row then reflects
    # only the handful of files that happened to be the active transcript at a
    # render (observed: 6 of 1812 files → a stuck, implausibly-low total).
    # The backfill is BOUNDED per rebuild (default 400, override
    # HIMMEL_STATUSLINE_BACKFILL_MAX) so a single refresh can't exceed the
    # stale-lock reaper window on a huge back-catalogue; the index grows
    # monotonically (a backfilled file's mtime predates the new index write, so
    # it is carried forward, not re-scanned), so the aggregate heals over
    # successive renders. Cold start (no index) is unchanged — it already scans
    # every file — so this only affects the incremental path.
    if [ -f "$index_file" ]; then
        recompute_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$index_file" 2>/dev/null)
        local backfill_max="${HIMMEL_STATUSLINE_BACKFILL_MAX:-400}"
        case "$backfill_max" in ''|*[!0-9]*) backfill_max=400 ;; esac
        if [ "$backfill_max" -gt 0 ]; then
            local tmp_known missing
            tmp_known=$(mktemp 2>/dev/null) || tmp_known=""
            if [ -n "$tmp_known" ]; then
                # Known = paths already in the index. Any all_paths entry not in
                # it is a never-scanned historical file → backfill up to N.
                printf '%s\n' "$old_index" | jq -r 'keys[]?' 2>/dev/null \
                    | LC_ALL=C sort -u > "$tmp_known"
                missing=$(printf '%s\n' "$all_paths" | grep -v '^$' | LC_ALL=C sort -u \
                    | LC_ALL=C comm -23 - "$tmp_known" | head -n "$backfill_max")
                rm -f "$tmp_known" 2>/dev/null
                if [ -n "$missing" ]; then
                    recompute_paths=$(printf '%s\n%s' "$recompute_paths" "$missing" \
                        | grep -v '^$' | LC_ALL=C sort -u)
                fi
            fi
        fi
    else
        recompute_paths="$all_paths"
    fi

    # Recompute changed files one at a time → path<TAB>reads<TAB>writes<TAB>inputs.
    # Cheap in steady state (usually just the active transcript).
    recomputed=""
    if [ -n "$recompute_paths" ]; then
        local fpath sums line
        while IFS= read -r fpath; do
            [ -z "$fpath" ] && continue
            if [ -n "$win_start" ]; then
                # Windowed: keep only assistant messages whose timestamp falls
                # in [win_start, win_end). Fractional ".000Z" is stripped before
                # fromdateiso8601; an unparseable timestamp → -1 → excluded.
                sums=$(jq -rs --argjson s "$win_start" --argjson e "$win_end" \
                    '[ .[] | select(.type == "assistant")
                           | ((.timestamp // "") | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601? // -1) as $te
                           | select($te >= $s and $te < $e) ]
                     | [ ([.[] | .message.usage.cache_read_input_tokens   // 0] | add // 0),
                         ([.[] | .message.usage.cache_creation_input_tokens // 0] | add // 0),
                         ([.[] | .message.usage.input_tokens               // 0] | add // 0)
                       ] | @tsv' "$fpath" 2>/dev/null)
            else
                sums=$(jq -rs '[ ([.[] | select(.type == "assistant") | .message.usage.cache_read_input_tokens   // 0] | add // 0),
                                 ([.[] | select(.type == "assistant") | .message.usage.cache_creation_input_tokens // 0] | add // 0),
                                 ([.[] | select(.type == "assistant") | .message.usage.input_tokens               // 0] | add // 0)
                               ] | @tsv' "$fpath" 2>/dev/null)
            fi
            [ -z "$sums" ] && sums=$(printf '0\t0\t0')
            line=$(printf '%s\t%s' "$fpath" "$sums")
            recomputed="${recomputed}${line}"$'\n'
        done <<EOF
$recompute_paths
EOF
    fi

    # Assemble the new index (recomputed entries override carried-forward ones,
    # deleted files drop out because we only iterate current paths) and the
    # totals. Everything large goes through temp files, never jq args.
    tmp_old=$(mktemp 2>/dev/null) || return
    tmp_all=$(mktemp 2>/dev/null) || { rm -f "$tmp_old"; return; }
    tmp_rc=$(mktemp  2>/dev/null) || { rm -f "$tmp_old" "$tmp_all"; return; }
    printf '%s'   "$old_index"   > "$tmp_old"
    printf '%s\n' "$all_paths"   > "$tmp_all"
    printf '%s'   "$recomputed"  > "$tmp_rc"

    out=$(jq -n --rawfile old "$tmp_old" --rawfile allp "$tmp_all" --rawfile recomp "$tmp_rc" '
        ($old | fromjson? // {}) as $oldidx
        | ($recomp | split("\n") | map(select(length > 0) | split("\t"))
            | map({ key: .[0], value: { reads:  (.[1] | tonumber? // 0),
                                        writes: (.[2] | tonumber? // 0),
                                        inputs: (.[3] | tonumber? // 0) } })
            | from_entries) as $rc
        | ($allp | split("\n") | map(select(length > 0))) as $files
        | reduce $files[] as $p
            ({ index: {}, reads: 0, writes: 0, inputs: 0 };
             ($rc[$p] // $oldidx[$p] // null) as $e
             | if $e == null then .
               else .index[$p] = { reads: $e.reads, writes: $e.writes, inputs: $e.inputs }
                  | .reads  += $e.reads
                  | .writes += $e.writes
                  | .inputs += $e.inputs
               end)' 2>/dev/null)
    rm -f "$tmp_old" "$tmp_all" "$tmp_rc"
    [ -z "$out" ] && return

    # Atomic tmp+mv so a concurrent reader never sees a torn file.
    tmp="${index_file}.$$.tmp"
    if echo "$out" | jq -c '.index' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$index_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    tmp="${cache_file}.$$.tmp"
    if echo "$out" | jq -c '{ reads, writes, inputs }' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
