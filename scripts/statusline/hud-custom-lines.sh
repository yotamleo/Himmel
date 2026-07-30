#!/usr/bin/env bash
# scripts/statusline/hud-custom-lines.sh — the SPAWN-FREE composer for himmel's
# custom statusline lines under claude-hud (HIMMEL-718 Task 3.2).
#
# This is the command claude-hud's forked `display.customLineCommand` runs each
# render (see marketplace/plugins/claude-hud/src/custom-line-cmd.ts): hud pipes
# the session stdin JSON in, runs us in the session CWD, bounds us at 3s, caps
# output at 10 lines / 10KB, and STRIPS ANSI escapes from every line
# (utils/sanitize.ts). So this composer emits PLAIN TEXT — colour is hud's job
# on its native lines; our custom lines are colourless (an accepted cosmetic
# delta from the legacy bar, like the 3.1 label deltas).
#
# It emits, multiline, the lines hud has NO native equivalent for
# (§Decisions render-native-map — CUSTOM set):
#   1. where-are-we  : ⎇ <KEY>[ 📋][ <ledger-status>][ · <EPIC> <done>/<total>]
#   2. session econ  : session  r:<r>  w:<w>  hit:<h>%  net <±>$<n>
#                      (HIMMEL-797: renders `session~ r:? w:? hit:?% net ?`
#                      when the transcript is missing or its per-render parse
#                      couldn't complete — see read_session_cache_stats. A
#                      silent zero there is indistinguishable from a session
#                      that genuinely has no usage yet.)
#   3. all-sessions  : <all[~]|week|month>  r:<r>  w:<w>  hit:<h>%  net <±>$<n>
#                      (the `~` is the HIMMEL-1300 healing marker — see §3.5)
#   4. token volume  : total  cache:<read+creation>  used:<in+read+creation+out>
# hud renders natively (so we do NOT emit): model/ctx/git/duration/effort,
# 5h/7d usage, credits (balance_label), prompt-cache countdown, session cost.
#
# SPAWN-FREE (the whole point of the epic): reads pre-computed caches + the
# session transcript ONLY. It NEVER rebuilds the all-sessions economics index
# (that detached rebuild — the orphaned-bash leak class — relocates to the
# periodic hook scripts/hooks/refresh-statusline-caches-periodic.sh). The one
# child it runs is the where-are-we segment, SYNCHRONOUSLY and timeout-bounded
# (reaped, not detached) — no `& disown` / `( … & )` here (static-no-spawn gate).
#
# FAIL-OPEN everywhere: any error omits only its own line; never errors/hangs.
#
# Env knobs (relocated onto this composer from the legacy bar):
#   HIMMEL_WHERE_ARE_WE            off (0|false|off|no) → suppress the WAW line.
#   HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT  seconds to bound the segment call (default 3).
#   HIMMEL_STATUSLINE_PERIOD      all|week|month → the all-sessions line window.
#   HIMMEL_STATUSLINE_BACKFILL_MAX / *_NOW → passed through to the lib (unused on
#                                 the read path; honoured by the hook's rebuild).
set -uo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/.." && pwd)"

# Drain stdin (the Claude Code JSON) so the caller's pipe never blocks.
input=""
if [ ! -t 0 ]; then input="$(cat 2>/dev/null || true)"; fi

# --- Parse the native session fields from stdin (same paths as the legacy bar)
model_id="claude-sonnet" transcript_path="" cwd=""
if [ -n "$input" ]; then
    read_vals="$(printf '%s' "$input" | jq -r '
        [ (.model.id // "claude-sonnet"),
          (.transcript_path // ""),
          (.cwd // "") ] | @tsv' 2>/dev/null || true)"
    if [ -n "$read_vals" ]; then
        IFS=$'\t' read -r model_id transcript_path cwd <<EOF
$read_vals
EOF
    fi
fi
[ -n "$model_id" ] || model_id="claude-sonnet"
[ -n "$cwd" ] || cwd="$PWD"

# ── Economics helpers ───────────────────────────────────────────────────────
# Duplicated (pure functions) from scripts/statusline/bin/statusline.sh so the
# composer's numbers are byte-identical to the legacy bar. The legacy bar keeps
# its own copy until it is decommissioned (plan Task 5.4); the composer-parity
# test guards against the two diverging meanwhile.
format_tokens() {
    local n="${1:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if   [ "$n" -ge 1000000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fB", n/1000000000}'
    elif [ "$n" -ge 1000000 ];    then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
    elif [ "$n" -ge 1000 ];       then awk -v n="$n" 'BEGIN{printf "%.0fk", n/1000}'
    else printf "%s" "$n"
    fi
}
# Humanize a positive USD amount: K/M/B once it reaches $1000, else raw %.4f.
# Returns the number WITHOUT a leading $ (caller adds it); sign handled separately.
format_usd() {
    local n="${1:-0}"
    awk -v n="$n" 'BEGIN{
        if      (n >= 1000000000) printf "%.1fB", n/1000000000;
        else if (n >= 1000000)    printf "%.1fM", n/1000000;
        else if (n >= 1000)       printf "%.1fK", n/1000;
        else                      printf "%.4f", n;
    }'
}
# Sets read_savings_rate and write_overhead_rate (USD per token, float) and
# model_rate_known (1 = an explicit rate card matched; 0 = the *) fallback,
# priced at Sonnet rates as a guess). The 0 flags the guess so a `?` is shown
# on the net (HIMMEL-1316) instead of the operator reading a guess as a fact.
get_model_savings_rate() {
    local model_id="${1:-claude-sonnet}"
    local input_price cache_read_price cache_write_price
    model_rate_known=1
    case "$model_id" in
        claude-fable*)  input_price=10.00; cache_read_price=1.00;  cache_write_price=20.00 ;;
        claude-mythos*) input_price=10.00; cache_read_price=1.00;  cache_write_price=20.00 ;;
        claude-opus*)   input_price=5.00;  cache_read_price=0.50;  cache_write_price=10.00 ;;
        claude-haiku*)  input_price=1.00;  cache_read_price=0.10;  cache_write_price=2.00  ;;
        claude-sonnet*) input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ;;
        glm-*)          input_price=1.40;  cache_read_price=0.26;  cache_write_price=1.40  ;;
        gpt-5*)         input_price=5.00;  cache_read_price=0.50;  cache_write_price=5.00  ;;
        *)              input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ; model_rate_known=0 ;;
    esac
    read_savings_rate=$(awk  -v i="$input_price" -v r="$cache_read_price"  'BEGIN{printf "%.8f",(i-r)/1000000}')
    write_overhead_rate=$(awk -v w="$cache_write_price" -v i="$input_price" 'BEGIN{printf "%.8f",(w-i)/1000000}')
}
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
# Reads session cache stats from transcript JSONL. Sets: sess_reads sess_writes
# sess_inputs sess_outputs sess_unknown (last_5m/last_1h timestamps are the TTL
# lines' concern — hud native promptCache — so we do NOT read them here).
# Deduped per _HUD_DEDUP_JQ; UNWINDOWED, so no timestamp filter.
#
# sess_unknown=1 means "could not be determined" (missing transcript, or the
# jq parse below failed/timed out) — DISTINCT from a successful parse that
# legitimately sums to zero (a brand-new session with no assistant turns yet).
# The caller renders an explicit marker for the former; the latter still shows
# real (zero) numbers, because they ARE real.
read_session_cache_stats() {
    local transcript="$1"
    sess_reads=0; sess_writes=0; sess_inputs=0; sess_outputs=0; sess_unknown=0
    if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
        sess_unknown=1
        return
    fi
    local stats US=$'\037' rc
    # BOUNDED (HIMMEL-797): unlike the all-sessions index, this jq -rs slurps
    # the WHOLE transcript fresh on EVERY render — there is no per-session
    # cache. On a large/long-running transcript (tens of MB) that alone
    # measured 6-30s+ on this machine, which blows past hud's OWN 3s render
    # budget (custom-line-cmd.ts TIMEOUT_MS=3000 — discards ALL stdout on
    # timeout, see file header). Left unbounded, one slow session silently
    # blanked the ENTIRE render — including the all/total rows below, which
    # read a cheap pre-computed cache and have nothing to do with the slow
    # parse. Bounding it here, well under hud's external budget, converts
    # "everything vanishes" into "only the session row shows the unknown
    # marker" — same timeout/gtimeout seam as seg_timeout/prod_timeout above.
    local sess_timeout="${HIMMEL_SESSION_CACHE_TIMEOUT:-2}"
    case "$sess_timeout" in ''|*[!0-9]*) sess_timeout=2 ;; esac
    # CR #1474: GNU `timeout 0` DISABLES the limit — a 0 (or 00) here would
    # silently reopen the unbounded-parse hole this seam exists to close.
    [ "$sess_timeout" -gt 0 ] || sess_timeout=2
    local sess_to=""
    # CR #1474: validate with --version so a PATH that resolves `timeout` to
    # Windows' native timeout.exe (no GNU semantics; errors on this shape) is
    # never used as the seam — GNU coreutils passes, timeout.exe fails and we
    # fall through to gtimeout/unbounded exactly like a missing binary.
    if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then sess_to="timeout $sess_timeout"
    elif command -v gtimeout >/dev/null 2>&1; then sess_to="gtimeout $sess_timeout"; fi
    # shellcheck disable=SC2086  # sess_to is the intentional "timeout N" seam word-split
    stats=$($sess_to jq -rs --arg sep "$US" "$_HUD_DEDUP_JQ"'
        (dedup_usage | sum4) | map(tostring) | join($sep)' "$transcript" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$stats" ]; then
        sess_unknown=1
        return
    fi
    IFS="$US" read -r sess_reads sess_writes sess_inputs sess_outputs <<EOF
$stats
EOF
    [ -n "$sess_reads" ]   || sess_reads=0
    [ -n "$sess_writes" ]  || sess_writes=0
    [ -n "$sess_inputs" ]  || sess_inputs=0
    [ -n "$sess_outputs" ] || sess_outputs=0
}
# Formats one economics row (plain text). Args: $1=label $2=reads $3=writes
# $4=inputs. Uses the model rates already set by get_model_savings_rate.
format_econ_line() {
    local label="$1" reads="$2" writes="$3" inputs="$4"
    local r_fmt w_fmt hit denom net abs sign qmark
    r_fmt=$(format_tokens "$reads")
    w_fmt=$(format_tokens "$writes")
    denom=$(( inputs + reads ))
    [ "$denom" -gt 0 ] && hit=$(( reads * 100 / denom )) || hit=0
    net=$(awk -v r="$reads" -v w="$writes" -v rs="$read_savings_rate" -v wo="$write_overhead_rate" \
          'BEGIN{printf "%.4f", r*rs - w*wo}')
    abs=$(format_usd "$(awk -v n="$net" 'BEGIN{if(n<0)n=-n; printf "%.4f",n}')")
    if awk -v n="$net" 'BEGIN{exit !(n >= 0)}'; then sign="+"; else sign="-"; fi
    # HIMMEL-1316: a trailing `?` after the net flags a model priced by the *)
    # fallback (Sonnet rates as a guess). Recognised models render unchanged —
    # model_rate_known defaults to 1, so qmark stays empty. Fail-safe default so
    # an unset flag never spuriously marks a recognised model.
    qmark=""
    [ "${model_rate_known:-1}" -eq 0 ] && qmark="?"
    # Pad the label to 7 cols (= "session") so the r: columns of the session and
    # all-sessions rows align, matching the legacy bar's 9-col label gutter.
    printf '%-7s  r:%s  w:%s  hit:%s%%  net %s$%s%s' "$label" "$r_fmt" "$w_fmt" "$hit" "$sign" "$abs" "$qmark"
}
# HIMMEL-797: explicit-unknown counterpart to format_econ_line, for when a
# row's own figures could not be determined (see read_session_cache_stats'
# sess_unknown). Renders "?" placeholders rather than silently-zero numbers,
# which are visually indistinguishable from a row that genuinely computed to
# zero. Reuses the same 7-col label gutter; the caller passes a `~`-suffixed
# label, the same "not fully known" marker the all-sessions row already uses
# for its own pending state (§HIMMEL-1300 3.5).
format_econ_unknown_line() {
    local label="$1"
    printf '%-7s  r:?  w:?  hit:?%%  net ?' "$label"
}
# Formats the token-volume row (plain text) for the ACTIVE all-sessions window.
# Args: $1=reads $2=writes $3=inputs $4=outputs.
#   total cache = cache_read + cache_creation
#   total used  = input + cache_read + cache_creation + output
# (HIMMEL-1300 §3.6, operator-requested.) It lands on its OWN row rather than
# extending the session / all rows: both of those are pinned as regression nets
# — test-hud-composer-parity.sh case 3 is END-ANCHORED on the all row, and
# test/golden-all-row.txt is a byte-exact capture of the legacy bar's two rows —
# and neither should be moved for a display addition. Same 7-col `%-7s` gutter
# as format_econ_line, so `cache:` lines up under the rows' `r:`.
format_totals_line() {
    local reads="$1" writes="$2" inputs="$3" outputs="$4"
    local total_cache total_used
    [[ "$reads"   =~ ^[0-9]+$ ]] || reads=0
    [[ "$writes"  =~ ^[0-9]+$ ]] || writes=0
    [[ "$inputs"  =~ ^[0-9]+$ ]] || inputs=0
    [[ "$outputs" =~ ^[0-9]+$ ]] || outputs=0
    total_cache=$(( reads + writes ))
    total_used=$(( inputs + reads + writes + outputs ))
    printf '%-7s  cache:%s  used:%s' "total" \
        "$(format_tokens "$total_cache")" "$(format_tokens "$total_used")"
}

lines=""
append() { [ -n "$1" ] && { [ -n "$lines" ] && lines="$lines
$1" || lines="$1"; }; }

# ── Drive the single-writer usage producer (HIMMEL-718 Task 2.3) ─────────────
# The producer (usage-cache-producer.sh) mirrors THIS render's rate_limits into
# the cap-guard consumer cache ($CLAUDE_USAGE_CACHE) + the hud snapshot, and
# throttled-queries OAuth credits. It is the SINGLE writer of both (hud only
# READS externalUsagePath; we never set externalUsageWritePath — no two-writer
# race). It MUST run here, render-timed: rate_limits live ONLY in the statusline
# stdin, which the SessionStart/UserPromptSubmit hooks don't get (§Decisions
# hud-usage-schema; plan Task 2.3 decision gate = "composer receives stdin →
# drive the producer from the composer"). SYNCHRONOUS (reaped by hud's
# customLineCommand tree-kill → no detached fork, no orphan). To keep render-path
# process churn down — the whole point of the epic — we gate the producer SPAWN
# on the consumer cache's own freshness (a cheap stat, no fork), so it forks the
# producer only when the cache is actually stale (~once per USAGE_CACHE_TTL), not
# every render. Fail-open: never blocks the render.
# Producer path is a test seam (HIMMEL_USAGE_PRODUCER) so a stub can observe the
# freshness-gated fork.
producer="${HIMMEL_USAGE_PRODUCER:-$SD/usage-cache-producer.sh}"
usage_cache="${CLAUDE_USAGE_CACHE:-/tmp/claude/statusline-usage-cache.json}"
usage_ttl="${USAGE_CACHE_TTL:-300}"
case "$usage_ttl" in ''|*[!0-9]*) usage_ttl=300 ;; esac
# BOUND the producer drive BELOW hud's whole-composer budget (custom-line-cmd.ts
# TIMEOUT_MS=3000, which discards ALL stdout on timeout). The producer's OAuth
# branch curls with --max-time 5; without this cap a slow OAuth round-trip would
# blank the composer's OWN lines (WAW + econ), not just the usage side-effect.
# Default 2s leaves ≥1s for the render's own (fast, cache-only) lines.
prod_timeout="${HIMMEL_USAGE_PRODUCER_TIMEOUT:-2}"
case "$prod_timeout" in ''|*[!0-9]*) prod_timeout=2 ;; esac
prod_to=""
if command -v timeout >/dev/null 2>&1; then prod_to="timeout $prod_timeout"
elif command -v gtimeout >/dev/null 2>&1; then prod_to="gtimeout $prod_timeout"; fi
if [ -f "$producer" ] && [ -n "$input" ]; then
    prod_stale=1
    if [ -f "$usage_cache" ]; then
        um=$(stat -c %Y "$usage_cache" 2>/dev/null || stat -f %m "$usage_cache" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - um ))
        # age>=0 guards a clock-skewed FUTURE mtime (would else read as fresh).
        [ "$age" -ge 0 ] && [ "$age" -lt "$usage_ttl" ] && prod_stale=0
    fi
    if [ "$prod_stale" -eq 1 ]; then
        # shellcheck disable=SC2086  # prod_to is the intentional "timeout N" seam word-split
        printf '%s' "$input" | $prod_to bash "$producer" >/dev/null 2>&1 || true
    fi
fi

# ── Line 1: where-are-we (reuse the tested segment; cache-only, reaped) ──────
# Early-gate on HIMMEL_WHERE_ARE_WE (0|false|off|no): the segment self-gates too,
# but checking here skips the segment subprocess entirely when WAW is off —
# honouring the header's documented opt-out at the composer level, not just via
# the child, and avoiding a wasted spawn on the render path.
_waw_enabled() {
    case "$(printf '%s' "${HIMMEL_WHERE_ARE_WE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}
seg_timeout="${HIMMEL_WHERE_ARE_WE_SEG_TIMEOUT:-3}"
case "$seg_timeout" in ''|*[!0-9]*) seg_timeout=3 ;; esac
seg="$ROOT/where-are-we/statusline-segment.sh"
if _waw_enabled && [ -f "$seg" ]; then
    seg_to=""
    if command -v timeout >/dev/null 2>&1; then seg_to="timeout $seg_timeout"
    elif command -v gtimeout >/dev/null 2>&1; then seg_to="gtimeout $seg_timeout"; fi
    # shellcheck disable=SC2086  # seg_to is the intentional "timeout N" seam word-split
    waw="$(printf '%s' "$input" | $seg_to bash "$seg" --cwd "$cwd" 2>/dev/null || true)"
    append "$waw"
fi

# ── Lines 2-3: session + all-sessions economics (cache/transcript reads only) ─
get_model_savings_rate "$model_id"
read_session_cache_stats "$transcript_path"
if [ "$sess_unknown" = "1" ]; then
    append "$(format_econ_unknown_line "session~")"
else
    append "$(format_econ_line "session" "$sess_reads" "$sess_writes" "$sess_inputs")"
fi

# All-sessions: resolve the window for the active period, READ its pre-computed
# cache (never rebuild — that's the hook's job), format the row.
# shellcheck source=scripts/statusline/lib/all-sessions-index.sh
. "$SD/lib/all-sessions-index.sh" 2>/dev/null || true
period="${HIMMEL_STATUSLINE_PERIOD:-all}"
all_reads=0 all_writes=0 all_inputs=0 all_outputs=0 all_pending=0 all_label="all"
if command -v resolve_window >/dev/null 2>&1; then
    # resolve_window sets window_id (+ window_start/window_end, unused on the
    # read path — only the hook's rebuild needs the bounds).
    window_id="all-stats"
    resolve_window "$period"
    case "$period" in week) all_label="week" ;; month) all_label="month" ;; *) all_label="all" ;; esac
    all_cache="${CLAUDE_ALL_SESSIONS_CACHE_DIR:-/tmp/claude}/cache-${window_id}.json"
    if [ -f "$all_cache" ]; then
        # `.outputs` and `.pending` are NEW reads (HIMMEL-1300) — the pre-1300 jq
        # selected reads/writes/inputs only. `outputs` feeds the total-used
        # figure on the totals row; `pending` drives the `all~` healing marker.
        # Both are `// 0`, so a cache written by an older producer still parses.
        # The US (\037) separator comes in via --arg rather than a literal
        # control byte in the program text.
        us=$'\037'
        joined="$(jq -r --arg sep "$us" '[(.reads // 0),(.writes // 0),(.inputs // 0),(.outputs // 0),(.pending // 0)] | map(tostring) | join($sep)' "$all_cache" 2>/dev/null || true)"
        if [ -n "$joined" ]; then
            IFS="$us" read -r all_reads all_writes all_inputs all_outputs all_pending <<EOF
$joined
EOF
        fi
    fi
fi
# Numeric guards, not merely non-empty ones: every one of these five feeds an
# arithmetic context downstream (format_econ_line / format_totals_line, and the
# `-gt 0` test below). A cache written by hand, truncated mid-write, or carrying
# a jq-stringified float ("1e+30") would otherwise reach `$(( ))` as a syntax
# error under `set -u`-adjacent strictness. Clamp anything non-integral to 0 —
# a 0 row is a visibly-wrong number the operator can act on; a broken composer
# takes the whole statusline down.
#
# Matched on the RAW value, never `${x:-0}`: the default would expand an empty
# var to the literal "0", which matches NEITHER pattern, so the assignment is
# skipped and the variable stays empty — the exact case the guard exists for.
# All five are initialised above, so there is no unbound-variable exposure.
case "$all_reads"   in ''|*[!0-9]*) all_reads=0   ;; esac
case "$all_writes"  in ''|*[!0-9]*) all_writes=0  ;; esac
case "$all_inputs"  in ''|*[!0-9]*) all_inputs=0  ;; esac
case "$all_outputs" in ''|*[!0-9]*) all_outputs=0 ;; esac
case "$all_pending" in ''|*[!0-9]*) all_pending=0 ;; esac

# HIMMEL-1300 §3.5: while the index still owes work — transcripts it has never
# indexed, plus carried entries at a stale schema, EXCLUDING the permanently
# parked v:-1 failures — the `all` row is still MOVING, so it renders as `all~`.
# The tilde vanishes permanently at pending == 0. `all~` is 4 cols and still
# fits format_econ_line's 7-col `%-7s` gutter, so nothing realigns. Gated to the
# `all` period on purpose (spec OQ4): week/month indexes rotate and self-heal
# within <=7/<=31 days. The legacy bar deliberately gets NO marker — it never
# renders post-cutover and its row uses a different 9-col gutter.
all_row_label="$all_label"
if [ "$all_label" = "all" ] && [ "$all_pending" -gt 0 ]; then
    all_row_label="all~"
fi
append "$(format_econ_line "$all_row_label" "$all_reads" "$all_writes" "$all_inputs")"

# ── Line 4: token volume — total cache / total used (HIMMEL-1300 §3.6) ───────
append "$(format_totals_line "$all_reads" "$all_writes" "$all_inputs" "$all_outputs")"

printf '%s\n' "$lines"
exit 0
