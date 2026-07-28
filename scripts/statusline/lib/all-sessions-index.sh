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

# ── Dual-logging dedup, shared jq prelude (HIMMEL-1300) ─────────────────────
# Claude Code writes the same API response into the transcript 2-3 times, so a
# naive per-row sum over-counts 1.9x-3.3x. Mirrors claude-hud transcript.ts
# (457-490): primary key message.id (non-empty string <= 128 chars) against a
# bounded FIFO seen-set (cap 4096, evict-oldest); a row with a missing/invalid
# id falls back to its usage fingerprint vs the IMMEDIATELY PREVIOUS row and
# counts only on change; the fallback key resets on EVERY non-assistant /
# non-usage row. That reset is why the scan runs over the UNFILTERED row
# stream — pre-filtering destroys adjacency and would merge two distinct
# id-less messages. foreach (a reduce that also emits), never group_by /
# unique_by: those reorder the stream, which the consecutive fingerprint
# cannot survive. dedup_usage emits one compact {t,r,w,i,o} record per COUNTED
# message; sum4 folds them into [reads, writes, inputs, outputs]. A WINDOWED
# caller filters the winners on .t between the two — dedup first, then window;
# UNWINDOWED callers apply no timestamp filter at all (rows legitimately carry
# no .timestamp, and filtering them would zero the total).
# Kept byte-identical with the copies in bin/statusline.sh and
# hud-custom-lines.sh (same "do NOT diverge" invariant as the two functions
# below, which test-all-sessions-index-parity.sh enforces by byte-diff).
_HUD_DEDUP_JQ='
def normcount:
  if type != "number" then 0
  elif (isnan or isinfinite) then 0
  else (floor as $f | if $f < 0 then 0 else $f end)
  end;
def normid:
  if (type == "string") and (length > 0) and (length <= 128) then . else null end;
def fp:
  [.input_tokens, .output_tokens, .cache_creation_input_tokens, .cache_read_input_tokens]
  | map(if . == null then "null" else tostring end) | join("|");
def dedup_usage:
  [ foreach .[] as $msg (
      { seen: {}, queue: [], lastKey: null, hit: false };
      if ($msg.type == "assistant") and ($msg.message.usage != null) then
        ($msg.message.id | normid) as $mid
        | if $mid != null then
            ( if (.seen[$mid] // false) then .hit = false
              else ( if (.queue | length) >= 4096
                     then (.queue[0]) as $old | .seen |= del(.[$old]) | .queue |= .[1:]
                     else . end )
                   | .seen[$mid] = true | .queue += [$mid] | .hit = true
              end )
            | .lastKey = null
          else
            ($msg.message.usage | fp) as $f
            | .hit = ($f != .lastKey) | .lastKey = $f
          end
      else .hit = false | .lastKey = null
      end;
      if .hit then
        { t: ($msg.timestamp // ""),
          r: ($msg.message.usage.cache_read_input_tokens     | normcount),
          w: ($msg.message.usage.cache_creation_input_tokens | normcount),
          i: ($msg.message.usage.input_tokens                | normcount),
          o: ($msg.message.usage.output_tokens               | normcount) }
      else empty end ) ];
def sum4:
  [ ([.[].r] | add // 0), ([.[].w] | add // 0),
    ([.[].i] | add // 0), ([.[].o] | add // 0) ];
'

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

# Removes every temp file the current rebuild pass registered in
# $_HUD_RB_TMPFILES (newline-separated; empty entries skipped) and clears the
# register. Called on every exit path of rebuild_all_sessions_index — and, per
# HIMMEL-1300 R3-4, ALSO from the periodic hook's kill-path trap, because a hook
# timeout-kill never reaches the rebuild's own cleanup and would otherwise leave
# three mktemps per killed pass behind (kills are the NORMAL termination mode
# while the index heals).
_hud_rb_rmtemps() {
    local _t
    [ -n "${_HUD_RB_TMPFILES:-}" ] || return 0
    while IFS= read -r _t; do
        [ -n "$_t" ] && rm -f "$_t" 2>/dev/null
    done <<EOF
$_HUD_RB_TMPFILES
EOF
    _HUD_RB_TMPFILES=""
    return 0
}
# Assembles + atomically publishes BOTH the per-file index ($2) and the totals
# cache ($1) from the CALLER's $recomputed via the caller's $tmp_old/$tmp_all/
# $tmp_rc transport (bash dynamic scoping — those strings run to hundreds of KB
# and must never cross an argv boundary).
# Args: $1=cache_file  $2=index_file  $3=ref_file ("" when none).
#
# HIMMEL-1300 R3-5: hoisted out of rebuild_all_sessions_index's tail so it can
# run every N files as a CHECKPOINT, not only once at the end. A pass killed by
# the hook timeout previously wrote NOTHING, so on a history whose full scan
# cannot finish inside the timeout, progress was zero forever. It publishes BOTH
# files on purpose: an index-only checkpoint would leave the totals (and
# `pending`) frozen exactly while the index churns. Mid-pass totals are as valid
# as terminal ones — the reduce carries $oldidx forward for unprocessed files.
#
# HIMMEL-1300 R3-1: after each publish the index mtime is pinned BACK to the
# pass-start reference. The next pass's recompute set is `find -newer
# "$index_file"`, so an advancing mtime would make a file that is (a) already
# v-current, (b) modified during this pass and (c) not yet reached when the pass
# is killed invisible to every later pass — neither -newer, nor missing, nor
# stale-schema — freezing it at its pre-modification sums indefinitely. Pinning
# is conservative: such a file is merely re-scanned once.
# shellcheck disable=SC2154  # $recomputed/$tmp_old/$tmp_all/$tmp_rc are the
# caller's locals, visible here by bash dynamic scoping (see above).
_hud_write_index_checkpoint() {
    local cache_file="$1" index_file="$2" ref_file="$3"
    local out tmp
    printf '%s' "$recomputed" > "$tmp_rc"

    # Entry schema v2 (HIMMEL-1300): { reads, writes, inputs, outputs, v }
    # (+ `attempts` while a file is failing). `outputs` rides THIS bump on
    # purpose — adding it later would force a v3 and a second full re-migration.
    # `pending` (R3-5 / §3.5) counts the work still owed: paths with no entry at
    # all, plus carried entries whose `v` is not current — EXCLUDING the v:-1
    # permanently-parked failures, which is what lets the composer's `all~`
    # marker eventually disappear.
    out=$(jq -n --rawfile old "$tmp_old" --rawfile allp "$tmp_all" --rawfile recomp "$tmp_rc" '
        2 as $schema
        | 3 as $maxattempts
        | ($old | fromjson? // {}) as $oldidx
        | ($recomp | split("\n") | map(select(length > 0) | split("\t"))
            | map(if (length >= 5)
                  then { key: .[0], value: { ok: true,
                                             reads:   (.[1] | tonumber? // 0),
                                             writes:  (.[2] | tonumber? // 0),
                                             inputs:  (.[3] | tonumber? // 0),
                                             outputs: (.[4] | tonumber? // 0) } }
                  else { key: .[0], value: { ok: false } }
                  end)
            | from_entries) as $rc
        | ($allp | split("\n") | map(select(length > 0))) as $files
        | reduce $files[] as $p
            ({ index: {}, reads: 0, writes: 0, inputs: 0, outputs: 0, pending: 0 };
             ($oldidx[$p] // null) as $o
             | ($rc[$p] // null) as $r
             | (if $r == null then
                  # Untouched this pass: carry the old entry (and its v) forward.
                  (if $o == null then null
                   else { reads:   ($o.reads   // 0), writes:  ($o.writes  // 0),
                          inputs:  ($o.inputs  // 0), outputs: ($o.outputs // 0),
                          v: ($o.v // 1) }
                        + (if ($o.attempts // 0) > 0 then { attempts: $o.attempts } else {} end)
                   end)
                elif ($r.ok) then
                  # Success: stamp the current schema, clear any attempt count.
                  { reads: $r.reads, writes: $r.writes, inputs: $r.inputs,
                    outputs: $r.outputs, v: $schema }
                else
                  # Failure sentinel: old sums (zeros if never indexed), one more
                  # attempt, and NO current v — so the known-set filter keeps
                  # retrying it. After $maxattempts consecutive failures park it
                  # at v:-1: known (never re-enters the recompute set) but flagged.
                  { reads:   ($o.reads   // 0), writes:  ($o.writes  // 0),
                    inputs:  ($o.inputs  // 0), outputs: ($o.outputs // 0),
                    attempts: (($o.attempts // 0) + 1) }
                  | if .attempts >= $maxattempts then . + { v: -1 } else . end
                end) as $e
             | if $e == null then .pending += 1
               else .index[$p] = $e
                  | .reads   += $e.reads
                  | .writes  += $e.writes
                  | .inputs  += $e.inputs
                  | .outputs += $e.outputs
                  | (($e.v // 1) as $ev
                     | if $ev == $schema or $ev == -1 then . else .pending += 1 end)
               end)' 2>/dev/null)
    [ -z "$out" ] && return 0

    # Atomic tmp+mv so a concurrent reader never sees a torn file.
    tmp="${index_file}.$$.tmp"
    if echo "$out" | jq -c '.index' > "$tmp" 2>/dev/null; then
        if mv -f "$tmp" "$index_file" 2>/dev/null; then
            # R3-1 mtime pin — see the header. Best-effort: a touch(1) without
            # -r just leaves the natural (later) mtime, i.e. today's behaviour.
            [ -n "$ref_file" ] && touch -r "$ref_file" "$index_file" 2>/dev/null
        else
            rm -f "$tmp" 2>/dev/null
        fi
    else
        rm -f "$tmp" 2>/dev/null
    fi
    tmp="${cache_file}.$$.tmp"
    if echo "$out" | jq -c '{ reads, writes, inputs, outputs, pending }' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
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
    local old_index all_paths recompute_paths recomputed ref_file
    local tmp_old tmp_all tmp_rc

    old_index=$(cat "$index_file" 2>/dev/null)
    echo "$old_index" | jq -e 'type == "object"' >/dev/null 2>&1 || old_index='{}'

    # HIMMEL-1300 R3-1: the pass-start mtime reference, touched into existence
    # BEFORE the first `find` below. _hud_write_index_checkpoint pins
    # $index_file back to it after every publish — see that function's header
    # for why an advancing index mtime silently freezes files modified mid-pass.
    # Registered in $_HUD_RB_TMPFILES so a caller killed mid-pass (the periodic
    # hook's timeout) can still reap it.
    ref_file=$(mktemp 2>/dev/null) || ref_file=""
    _HUD_RB_TMPFILES="$ref_file"

    # Current transcripts (one dir level down). `find` streams paths, so this
    # never hits the argv limit the glob did.
    all_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null)
    if [ -z "$all_paths" ]; then
        _hud_rb_rmtemps
        return 0
    fi

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
        if [ -z "$all_paths" ]; then
            _hud_rb_rmtemps
            return 0
        fi
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
    # The backfill is BOUNDED per rebuild (override
    # HIMMEL_STATUSLINE_BACKFILL_MAX); the index grows monotonically (a
    # backfilled file's mtime predates the new index write, so it is carried
    # forward, not re-scanned), so the aggregate heals over successive passes.
    # HIMMEL-1300 §3.4 retunes the default 400 -> 50: at a measured 71ms/file
    # that is ~3.5s, ~35% of a 10s hook, where 400 was 28.4s (2.8x over) and
    # therefore never completed. With checkpointing this is a latency knob, not
    # a correctness one.
    #
    # HIMMEL-1300 §3.4 also bounds COLD START: the recompute set starts EMPTY
    # (it used to be `$all_paths`, unbounded), and the backfill below is hoisted
    # OUT of the `-f "$index_file"` guard so it runs unconditionally. The old
    # cold scan could not finish inside the hook timeout, was killed, wrote
    # nothing, and so left the next pass cold too — a permanent 0. Cold start is
    # now simply "empty index + BACKFILL_MAX files per pass".
    recompute_paths=""
    if [ -f "$index_file" ]; then
        recompute_paths=$(find "$proj_root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$index_file" 2>/dev/null)
    fi
    local backfill_max="${HIMMEL_STATUSLINE_BACKFILL_MAX:-50}"
    case "$backfill_max" in ''|*[!0-9]*) backfill_max=50 ;; esac
    if [ "$backfill_max" -gt 0 ]; then
        local tmp_known missing
        tmp_known=$(mktemp 2>/dev/null) || tmp_known=""
        # Registered like every other mktemp in this function: the jq/sort/comm
        # window below is long enough to be killed through, and a timeout-kill
        # IS the normal termination mode while the index heals — so the inline
        # `rm -f` after the pipeline is not sufficient on its own.
        [ -n "$tmp_known" ] && _HUD_RB_TMPFILES="$ref_file
$tmp_known"
        if [ -n "$tmp_known" ]; then
            # Known = paths already in the index AT THE CURRENT SCHEMA.
            # HIMMEL-1300 stamps `v` INSIDE each entry value (so `keys[]` is
            # never polluted): v=2 = deduped accounting, v=-1 = a file that
            # failed to parse N times running (permanently parked). Anything
            # else — a pre-dedup v=1 entry, or a failure sentinel with no v —
            # is deliberately NOT known, so `comm -23` classifies it as
            # missing and it re-enters the SAME bounded backfill machinery.
            # That one query line is the whole re-migration.
            # `tr -d` strips CR: a native-Windows jq (jq-1.8.2 via winget)
            # writes CRLF, and unlike a single-line `$(…)` — where bash eats
            # the trailing \r\n — a multi-line pipeline keeps a \r on EVERY
            # line. `comm -23` then matches nothing, so every path looks
            # missing and the backfill re-scans BACKFILL_MAX files every
            # pass forever. Pre-existing (the old `keys[]?` had it too) and
            # invisible because "recompute everything" is merely slow, not
            # wrong — but it would make the schema filter above a no-op.
            printf '%s\n' "$old_index" \
                | jq -r 'to_entries[]?
                         | (.value | if type == "object" then (.v // 1) else 1 end) as $v
                         | select($v == 2 or $v == -1) | .key' 2>/dev/null \
                | tr -d '\r' | LC_ALL=C sort -u > "$tmp_known"
            missing=$(printf '%s\n' "$all_paths" | grep -v '^$' | LC_ALL=C sort -u \
                | LC_ALL=C comm -23 - "$tmp_known" | head -n "$backfill_max")
            rm -f "$tmp_known" 2>/dev/null
            if [ -n "$missing" ]; then
                recompute_paths=$(printf '%s\n%s' "$recompute_paths" "$missing" \
                    | grep -v '^$' | LC_ALL=C sort -u)
            fi
        fi
    fi

    # Assemble/publish transport. Created BEFORE the recompute loop (it used to
    # sit after it) because the loop now CHECKPOINTS through
    # _hud_write_index_checkpoint every N files, and each checkpoint re-runs the
    # assemble jq over these same three files. Everything large flows through
    # them, never through jq args.
    tmp_old=$(mktemp 2>/dev/null) || tmp_old=""
    tmp_all=$(mktemp 2>/dev/null) || tmp_all=""
    tmp_rc=$(mktemp  2>/dev/null) || tmp_rc=""
    _HUD_RB_TMPFILES="$ref_file
$tmp_old
$tmp_all
$tmp_rc"
    if [ -z "$tmp_old" ] || [ -z "$tmp_all" ] || [ -z "$tmp_rc" ]; then
        _hud_rb_rmtemps
        return 0
    fi
    printf '%s'   "$old_index" > "$tmp_old"
    printf '%s\n' "$all_paths" > "$tmp_all"

    # Recompute changed files one at a time →
    # path<TAB>reads<TAB>writes<TAB>inputs<TAB>outputs (5 fields), or the
    # 2-field failure sentinel path<TAB>FAIL. Cheap in steady state (usually
    # just the active transcript).
    #
    # CHECKPOINT every $ckpt_every files (HIMMEL-1300 R3-5, override
    # HIMMEL_STATUSLINE_CHECKPOINT_EVERY): the pass is normally terminated by
    # the hook's timeout kill, and a single terminal `mv` meant such a pass
    # persisted NOTHING. Checkpointing makes progress monotonic regardless of
    # how the budget compares to the timeout.
    recomputed=""
    if [ -n "$recompute_paths" ]; then
        local fpath sums line ckpt_every processed
        ckpt_every="${HIMMEL_STATUSLINE_CHECKPOINT_EVERY:-25}"
        case "$ckpt_every" in ''|*[!0-9]*) ckpt_every=25 ;; esac
        processed=0
        while IFS= read -r fpath; do
            [ -z "$fpath" ] && continue
            # LIVENESS HEARTBEAT (HIMMEL-1300). A caller holding a lock over
            # this rebuild — scripts/hooks/refresh-statusline-caches-periodic.sh
            # — defines _hud_rb_heartbeat to re-stamp its lock. Without it a pass
            # that legitimately runs past that reaper's age threshold looks
            # exactly like a leaked lock and gets reaped out from under itself,
            # letting a second refresher start on top of the first. Called
            # per-file rather than per-checkpoint on purpose: a pass with fewer
            # files than $ckpt_every never checkpoints at all, so a
            # checkpoint-only heartbeat would go quiet in precisely the
            # slow-and-few case the reap protects against. The contract on the
            # callback is that it must be SPAWN-FREE (builtin write, no touch(1))
            # — this runs once per file inside the hot path. Optional by design:
            # the legacy bar defines no such function and the `command -v` guard
            # makes it a no-op there.
            command -v _hud_rb_heartbeat >/dev/null 2>&1 && _hud_rb_heartbeat
            if [ -n "$win_start" ]; then
                # Windowed: dedup over the FULL row stream FIRST (the
                # consecutive-fingerprint fallback needs the original row
                # adjacency; filtering first would fuse two distinct id-less
                # messages), then keep the winners whose timestamp falls in
                # [win_start, win_end). Fractional ".000Z" is stripped before
                # fromdateiso8601; an unparseable timestamp → -1 → excluded.
                sums=$(jq -rs --argjson s "$win_start" --argjson e "$win_end" \
                    "$_HUD_DEDUP_JQ"' dedup_usage
                     | map(select((.t | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601? // -1) as $te
                                  | $te >= $s and $te < $e))
                     | sum4 | @tsv' "$fpath" 2>/dev/null)
            else
                # Unwindowed: dedup ONLY, no timestamp filter. Rows here
                # legitimately carry no `.timestamp`, and a winner-filter would
                # silently drop every one of them (→ a 0 total).
                sums=$(jq -rs "$_HUD_DEDUP_JQ"' dedup_usage | sum4 | @tsv' "$fpath" 2>/dev/null)
            fi
            # jq failure (corrupt/oversized file, or a torn read of the live
            # transcript mid-append) → a SENTINEL row, never a zero row: a zero
            # entry OVERRIDES the carried-forward value and drags the aggregate
            # below true. The assemble below carries the old sums and bumps
            # `attempts` instead; `attempts` resets on the next success.
            [ -z "$sums" ] && sums="FAIL"
            line=$(printf '%s\t%s' "$fpath" "$sums")
            recomputed="${recomputed}${line}"$'\n'
            processed=$(( processed + 1 ))
            if [ "$ckpt_every" -gt 0 ] && [ $(( processed % ckpt_every )) -eq 0 ]; then
                _hud_write_index_checkpoint "$cache_file" "$index_file" "$ref_file"
            fi
        done <<EOF
$recompute_paths
EOF
    fi

    # Final publish. Also the ONLY publish when nothing was recomputed —
    # deletions and carried-forward entries still have to reach the index and
    # the totals — and the one that lands the tail of a chunk shorter than
    # $ckpt_every.
    _hud_write_index_checkpoint "$cache_file" "$index_file" "$ref_file"
    _hud_rb_rmtemps
    return 0
}
