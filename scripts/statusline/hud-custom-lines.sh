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
#   3. all-sessions  : <all|week|month>  r:<r>  w:<w>  hit:<h>%  net <±>$<n>
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
# Sets read_savings_rate and write_overhead_rate (USD per token, float).
get_model_savings_rate() {
    local model_id="${1:-claude-sonnet}"
    local input_price cache_read_price cache_write_price
    case "$model_id" in
        claude-fable*)  input_price=10.00; cache_read_price=1.00;  cache_write_price=20.00 ;;
        claude-mythos*) input_price=10.00; cache_read_price=1.00;  cache_write_price=20.00 ;;
        claude-opus*)   input_price=5.00;  cache_read_price=0.50;  cache_write_price=10.00 ;;
        claude-haiku*)  input_price=1.00;  cache_read_price=0.10;  cache_write_price=2.00  ;;
        claude-sonnet*) input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ;;
        glm-*)          input_price=1.40;  cache_read_price=0.26;  cache_write_price=1.40  ;;
        gpt-5*)         input_price=5.00;  cache_read_price=0.50;  cache_write_price=5.00  ;;
        *)              input_price=3.00;  cache_read_price=0.30;  cache_write_price=6.00  ;;
    esac
    read_savings_rate=$(awk  -v i="$input_price" -v r="$cache_read_price"  'BEGIN{printf "%.8f",(i-r)/1000000}')
    write_overhead_rate=$(awk -v w="$cache_write_price" -v i="$input_price" 'BEGIN{printf "%.8f",(w-i)/1000000}')
}
# Reads session cache stats from transcript JSONL. Sets: sess_reads sess_writes
# sess_inputs (last_5m/last_1h timestamps are the TTL lines' concern — hud
# native promptCache — so we do NOT read them here).
read_session_cache_stats() {
    local transcript="$1"
    sess_reads=0; sess_writes=0; sess_inputs=0
    [ -z "$transcript" ] || [ ! -f "$transcript" ] && return
    local stats US=$'\037'
    stats=$(jq -rs --arg sep "$US" '[
        ([.[] | select(.type == "assistant") | .message.usage.cache_read_input_tokens   // 0] | add // 0),
        ([.[] | select(.type == "assistant") | .message.usage.cache_creation_input_tokens // 0] | add // 0),
        ([.[] | select(.type == "assistant") | .message.usage.input_tokens              // 0] | add // 0)
    ] | map(tostring) | join($sep)' "$transcript" 2>/dev/null) || return
    [ -n "$stats" ] || return
    IFS="$US" read -r sess_reads sess_writes sess_inputs <<EOF
$stats
EOF
    [ -n "$sess_reads" ]  || sess_reads=0
    [ -n "$sess_writes" ] || sess_writes=0
    [ -n "$sess_inputs" ] || sess_inputs=0
}
# Formats one economics row (plain text). Args: $1=label $2=reads $3=writes
# $4=inputs. Uses the model rates already set by get_model_savings_rate.
format_econ_line() {
    local label="$1" reads="$2" writes="$3" inputs="$4"
    local r_fmt w_fmt hit denom net abs sign
    r_fmt=$(format_tokens "$reads")
    w_fmt=$(format_tokens "$writes")
    denom=$(( inputs + reads ))
    [ "$denom" -gt 0 ] && hit=$(( reads * 100 / denom )) || hit=0
    net=$(awk -v r="$reads" -v w="$writes" -v rs="$read_savings_rate" -v wo="$write_overhead_rate" \
          'BEGIN{printf "%.4f", r*rs - w*wo}')
    abs=$(format_usd "$(awk -v n="$net" 'BEGIN{if(n<0)n=-n; printf "%.4f",n}')")
    if awk -v n="$net" 'BEGIN{exit !(n >= 0)}'; then sign="+"; else sign="-"; fi
    # Pad the label to 7 cols (= "session") so the r: columns of the session and
    # all-sessions rows align, matching the legacy bar's 9-col label gutter.
    printf '%-7s  r:%s  w:%s  hit:%s%%  net %s$%s' "$label" "$r_fmt" "$w_fmt" "$hit" "$sign" "$abs"
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
append "$(format_econ_line "session" "$sess_reads" "$sess_writes" "$sess_inputs")"

# All-sessions: resolve the window for the active period, READ its pre-computed
# cache (never rebuild — that's the hook's job), format the row.
# shellcheck source=scripts/statusline/lib/all-sessions-index.sh
. "$SD/lib/all-sessions-index.sh" 2>/dev/null || true
period="${HIMMEL_STATUSLINE_PERIOD:-all}"
all_reads=0 all_writes=0 all_inputs=0 all_label="all"
if command -v resolve_window >/dev/null 2>&1; then
    # resolve_window sets window_id (+ window_start/window_end, unused on the
    # read path — only the hook's rebuild needs the bounds).
    window_id="all-stats"
    resolve_window "$period"
    case "$period" in week) all_label="week" ;; month) all_label="month" ;; *) all_label="all" ;; esac
    all_cache="${CLAUDE_ALL_SESSIONS_CACHE_DIR:-/tmp/claude}/cache-${window_id}.json"
    if [ -f "$all_cache" ]; then
        joined="$(jq -r '[(.reads // 0),(.writes // 0),(.inputs // 0)] | map(tostring) | join("")' "$all_cache" 2>/dev/null || true)"
        if [ -n "$joined" ]; then
            IFS=$'\037' read -r all_reads all_writes all_inputs <<EOF
$joined
EOF
        fi
    fi
fi
[ -n "$all_reads" ]  || all_reads=0
[ -n "$all_writes" ] || all_writes=0
[ -n "$all_inputs" ] || all_inputs=0
append "$(format_econ_line "$all_label" "$all_reads" "$all_writes" "$all_inputs")"

printf '%s\n' "$lines"
exit 0
