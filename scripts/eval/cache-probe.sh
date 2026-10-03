#!/usr/bin/env bash
# scripts/eval/cache-probe.sh - measure prompt-cache behaviour from session
# transcripts (HIMMEL-3837). READ-ONLY: it only reads the JSONL files you give
# it, prints a deterministic report, and exits with a verdict code. It is the
# check behind docs/internals/prompt-cache.md - a cache claim is not TRUE until
# one of these modes (or a fixture scenario in test-cache-probe.sh) shows it.
#
# Usage:
#   cache-probe.sh invalidation --event <epoch|YYYY-MM-DDTHH:MM:SSZ|@file> \
#                  [--turns N] [--min-turns N] <session.jsonl>...
#       Did the event invalidate the prompt cache of the sessions live across
#       it? Per session: cache_read vs cache_creation for the N turns before
#       and after; only the FIRST transition after the event is judged (a
#       prefix change shows on the next turn, so a later rewrite is unrelated).
#       A transition is a full-prefix REWRITE when cache_read
#       collapses (< half the previous turn's) while cache_creation carries the
#       load; a rewrite is then explained away as `compacted` (a
#       compact_boundary row between the turns, or the context shrank > 25%)
#       or `ttl` (the gap to the previous turn reached the session's cache TTL),
#       and only an unexplained one is `invalidated`.
#         exit 0 not-invalidated (>= 1 kept session, no invalidated one)
#         exit 1 invalidated     (any session invalidated)
#         exit 2 inconclusive    (no session both sides of the event, or every
#                                 live one was explained by compaction/ttl)
#   cache-probe.sh idle-gap <session.jsonl>...
#       Does an idle gap past the TTL re-pay the prefix, and a shorter one not?
#       The TTL is per session: 3600s when any cache write used the 1h tier
#       (usage.cache_creation.ephemeral_1h_input_tokens), else 300s.
#         exit 0 ttl-consistent | 1 ttl-inconsistent | 2 inconclusive
#   cache-probe.sh first-turn <session.jsonl>...
#       Does a session's first request read a warm shared prefix
#       (cache_read_input_tokens > 0), or start cold?
#         exit 0 warm-start (>= half the sessions) | 1 cold-start | 2 no sessions
#   exit 64 = usage error (bad mode/flag/event, unreadable file).
#
# Every mode ends with `verdict: <word> <counts>` and a `read-ratio:` line
# (cache_read / (input + cache_read + cache_creation) over the turns used).
# Rows are deduplicated by message.id (a message streams as several rows that
# repeat one usage object) and sorted by timestamp. Needs bash 3.2+ and jq.
#
# ponytail: the rewrite test is two fixed thresholds (read < 0.5x previous,
# create > read) and the compaction test a fixed 0.75x context drop, chosen to
# separate the fixture shapes and the 2026-09-29 measurements; a workload with
# a much smaller prefix could sit near them. Upgrade path: make them flags when
# a real run lands within 10% of a threshold (HIMMEL-3837 follow-up).
# ponytail: timestamps are read to whole seconds (fractions dropped), so a gap
# is +-1s; TTL tiers are inferred from usage, not from the request.
# ponytail: usage rows only exist for main-thread and sidechain calls written
# to the given file; a session's untracked helper calls (title generation) are
# invisible, so `first-turn` can read warm from a call the file never shows.

set -u

usage() {
  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 64
}
die() { echo "cache-probe: $*" >&2; exit 64; }

command -v jq >/dev/null 2>&1 || die "jq is required"

[ $# -ge 1 ] || usage
MODE="$1"; shift
case "$MODE" in invalidation|idle-gap|first-turn) ;; -h|--help) usage ;; *) die "unknown mode '$MODE' (invalidation|idle-gap|first-turn)" ;; esac

EVENT_RAW=""; TURNS=3; MIN_TURNS=2; FILES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event) [ $# -ge 2 ] || die "--event needs a value"; EVENT_RAW="$2"; shift 2 ;;
    --turns) [ $# -ge 2 ] || die "--turns needs a value"; TURNS="$2"; shift 2 ;;
    --min-turns) [ $# -ge 2 ] || die "--min-turns needs a value"; MIN_TURNS="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*) die "unknown flag '$1'" ;;
    *) [ -r "$1" ] || die "cannot read '$1'"; FILES="$FILES
$1"; shift ;;
  esac
done
[ -n "$FILES" ] || die "no session files given"
case "$TURNS$MIN_TURNS" in *[!0-9]*) die "--turns/--min-turns must be integers" ;; esac
if [ "${TURNS:-0}" -lt 1 ] || [ "${MIN_TURNS:-0}" -lt 1 ]; then die "--turns/--min-turns must be >= 1"; fi

EVENT=0
if [ "$MODE" = invalidation ]; then
  [ -n "$EVENT_RAW" ] || die "invalidation needs --event <epoch|ISO-Z|@file>"
  case "$EVENT_RAW" in
    @*) f="${EVENT_RAW#@}"; [ -e "$f" ] || die "event file '$f' not found"
        EVENT=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || die "cannot stat '$f'" ;;
    *[!0-9]*) EVENT=$(jq -nr --arg e "$EVENT_RAW" '$e | fromdateiso8601' 2>/dev/null) || die "unparseable --event '$EVENT_RAW' (use epoch seconds or YYYY-MM-DDTHH:MM:SSZ)" ;;
    *) EVENT="$EVENT_RAW" ;;
  esac
  [ -n "$EVENT" ] || die "unparseable --event '$EVENT_RAW'"
fi

# The per-session program. Input: the whole JSONL slurped. Output: one TSV row
# per session (fields differ per mode, see the awk below).
read -r -d '' JQ_PROG <<'JQ'
def secs: (.timestamp // "" | sub("\\.[0-9]+Z$"; "Z")) as $s
          | try ($s | fromdateiso8601) catch null;
def ctx: .in + .cr + .cc;
def rewrite($p; $c): $p.cr > 0 and ($c.cr < 0.5 * $p.cr) and ($c.cc > $c.cr);
def cls($p; $c; $comp; $ttl):
  if (rewrite($p; $c) | not) then "kept"
  elif $comp or (($c | ctx) < 0.75 * ($p | ctx)) then "compacted"
  elif ($c.t - $p.t) >= $ttl then "ttl"
  else "invalidated" end;
def mean(k): if length == 0 then 0 else ((map(.[k]) | add) / length | floor) end;

[ .[] | select(.type == "assistant" and .message.usage != null and .message.id != null)
  | select(.message.model != "<synthetic>" and any(.message.usage | .input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, .cache_creation; . != null))
  | { id: .message.id, t: secs,
      in: (.message.usage.input_tokens // 0),
      cr: (.message.usage.cache_read_input_tokens // 0),
      cc: (.message.usage.cache_creation_input_tokens // 0),
      h1: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) }
  | select(.t != null) ] as $rows
| ($rows | group_by(.id) | map(.[0]) | sort_by(.t, .id)) as $T
| ([ .[] | select(.type == "system" and .subtype == "compact_boundary") | secs | select(. != null) ]) as $C
| (if ($T | map(.h1) | add // 0) > 0 then 3600 else 300 end) as $ttl  # ponytail: one tier per session, over-flags a mixed-tier one; take the tier from the last write turn (HIMMEL-3837 follow-up)
| ($T | map(.cr) | add // 0) as $sumcr
| ($T | map(.in + .cr + .cc) | add // 0) as $sumall
| def comp($p; $c): any($C[]; . > $p.t and . <= $c.t);
  if $mode == "first-turn" then
    ($T | first // null) as $f
    | if $f == null then empty
      else [ $sid, (if $f.cr > 0 then "warm" else "cold" end), $f.in, $f.cr, $f.cc, $sumcr, $sumall ] | @tsv end
  elif $mode == "idle-gap" then
    ([ range(1; $T | length) as $i | { p: $T[$i - 1], c: $T[$i] } ]
      | map(. + { gap: (.c.t - .p.t), comp: (comp(.p; .c) or ((.c | ctx) < 0.75 * (.p | ctx))) } | select(.comp | not))) as $P
    | ($P | map(select(.gap >= $ttl))) as $cold
    | ($P | map(select(.gap >= 60 and .gap < $ttl))) as $warm
    | [ $sid, $ttl, ($cold | length), ($cold | map(select(rewrite(.p; .c))) | length),
        ($warm | length), ($warm | map(select(rewrite(.p; .c))) | length), $sumcr, $sumall ] | @tsv
  else
    ($T | map(select(.t < $event)) | .[-$n:]) as $B
    | ($T | map(select(.t >= $event)) | .[:$n]) as $A
    | if ($B | length) == 0 or ($A | length) == 0 then empty
      else
        ([ ($B | last) ] + $A) as $seq
        | ([ cls($seq[0]; $seq[1]; comp($seq[0]; $seq[1]); $ttl) ]) as $K
        | (if ($B | length) < $min or ($A | length) < $min then "inconclusive"
           elif ($K | index("invalidated")) != null then "invalidated"
           elif ($K | index("compacted")) != null then "compacted"
           elif ($K | index("ttl")) != null then "ttl"
           else "kept" end) as $class
        | [ $sid, $class, ($B | length), ($A | length),
            ($B | mean("cr")), ($B | mean("cc")), ($A | mean("cr")), ($A | mean("cc")),
            (($A | first).t - ($B | last).t), (($B + $A) | map(.cr) | add // 0),
            (($B + $A) | map(.in + .cr + .cc) | add // 0) ] | @tsv
      end
  end
JQ

ROWS=""
OLDIFS=$IFS; IFS='
'
for f in $(printf '%s\n' "$FILES" | sed '/^$/d' | LC_ALL=C sort); do
  sid=$(basename "$f" .jsonl)
  # `-s` on a malformed line fails the whole file: treat as a usage error, not
  # as silently-empty evidence.
  row=$(jq -rs --arg mode "$MODE" --arg sid "$sid" --argjson event "$EVENT" \
        --argjson n "$TURNS" --argjson min "$MIN_TURNS" "$JQ_PROG" "$f") || { IFS=$OLDIFS; die "cannot parse '$f' as JSONL"; }
  [ -n "$row" ] && ROWS="$ROWS$row
"
done
IFS=$OLDIFS

case "$MODE" in
  invalidation)
    echo "cache-probe invalidation event=$EVENT turns=$TURNS min-turns=$MIN_TURNS"
    printf 'session\tclass\tturns_before\tturns_after\tcr_before\tcc_before\tcr_after\tcc_after\tgap_s\n'
    printf '%s' "$ROWS" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 }'
    printf '%s' "$ROWS" | awk -F'\t' '
      NF { n[$2]++; cr += $10; all += $11 }
      END {
        k = n["kept"] + 0; v = n["invalidated"] + 0; c = n["compacted"] + 0; t = n["ttl"] + 0; i = n["inconclusive"] + 0
        word = (v > 0) ? "invalidated" : (k > 0 ? "not-invalidated" : "inconclusive")
        printf "read-ratio: %.1f%% over %.0f tokens\n", (all > 0 ? 100 * cr / all : 0), all
        printf "verdict: %s kept=%d invalidated=%d compacted=%d ttl=%d inconclusive=%d\n", word, k, v, c, t, i
        exit (word == "invalidated") ? 1 : (word == "inconclusive" ? 2 : 0)
      }'
    exit $? ;;
  idle-gap)
    echo "cache-probe idle-gap (cold expected at gap >= session TTL, warm expected at 60s <= gap < TTL)"
    printf 'session\tttl_s\tcold_expected\tcold_rewrote\twarm_expected\twarm_rewrote\n'
    printf '%s' "$ROWS" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }'
    printf '%s' "$ROWS" | awk -F'\t' '
      NF { ce += $3; cw += $4; we += $5; ww += $6; cr += $7; all += $8 }
      END {
        # consistent: >= 80% of expected-cold gaps rewrote and <= 20% of expected-warm did
        if (ce == 0) word = "inconclusive"
        else if (cw >= 0.8 * ce && (we == 0 || ww <= 0.2 * we)) word = "ttl-consistent"
        else word = "ttl-inconsistent"
        printf "read-ratio: %.1f%% over %.0f tokens\n", (all > 0 ? 100 * cr / all : 0), all
        printf "verdict: %s cold-expected=%d cold-rewrote=%d warm-expected=%d warm-rewrote=%d\n", word, ce, cw, we, ww
        exit (word == "ttl-consistent") ? 0 : (word == "ttl-inconsistent" ? 1 : 2)
      }'
    exit $? ;;
  first-turn)
    echo "cache-probe first-turn"
    printf 'session\tstart\tinput\tcache_read\tcache_create\n'
    printf '%s' "$ROWS" | awk -F'\t' 'NF { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }'
    printf '%s' "$ROWS" | awk -F'\t' '
      NF { n++; if ($2 == "warm") w++; cr += $6; all += $7 }
      END {
        word = (n == 0) ? "inconclusive" : (2 * w >= n ? "warm-start" : "cold-start")
        printf "read-ratio: %.1f%% over %.0f tokens\n", (all > 0 ? 100 * cr / all : 0), all
        printf "verdict: %s warm=%d cold=%d\n", word, w + 0, n - w
        exit (word == "warm-start") ? 0 : (word == "cold-start" ? 1 : 2)
      }'
    exit $? ;;
esac
