#!/usr/bin/env bash
# scripts/lanes/leg-burn.sh - what one leg actually cost (HIMMEL-2830 /
# HIMMEL-2928 lever 1).
#
# WHY. "The leg floor is ~75k" was folklore until it was measured, and every
# lever this ticket adds (a plugin profile, quiet SessionStart hooks, a preface
# out of the brief) is only worth what it removes from that number. This is the
# meter: point it at a leg's transcript and it prints one line you can paste
# into a Results bullet or a PR body.
#
# Usage:
#   scripts/lanes/leg-burn.sh <transcript.jsonl>      # an explicit file
#   scripts/lanes/leg-burn.sh <session-name>          # e.g. HIMMEL-2890-...-legN158-...
#   scripts/lanes/leg-burn.sh --raw <transcript.jsonl|session-name>
#                                                      # out=/cache-read=/
#                                                      # cache-create=/input=
#                                                      # as exact integers
#                                                      # (LEG_BURN_RAW=1 is
#                                                      # the env equivalent)
#
# A bare name is resolved by scanning the Claude Code project transcripts for a
# `custom-title` row carrying that exact name; the most recently MODIFIED match
# wins (a resumed leg writes several).
#
# What the fields mean, and why each one is here:
#   calls        API calls, DEDUPED BY MESSAGE ID. A transcript writes one row
#                per content block, so a turn with three tool calls is four
#                rows and ONE call. Counting rows overstates a leg's cost by
#                roughly 3x - that error is the reason this script exists.
#   avg-ctx      mean input context per call = input + cache_read +
#                cache_creation. This is the number that gets re-paid on every
#                single call, so it, not the total, is what a profile moves.
#   first-turn   the context of the very FIRST call: the fixed floor, before
#                the leg has read anything. The one number to compare across
#                profiles.
#   out          output tokens over the whole session.
#   compactions  `compact_boundary` events. Each one is a mid-flight context
#                rebuild that a lower floor postpones.
#   text-only    calls that produced NO tool_use block. A leg narrating between
#                tool calls pays a full context re-read for prose nobody reads;
#                this is the token-discipline counter.
#
# HIMMEL-2987 price-weighted fields - avg-ctx x calls overstates cost ~10x
# because most context tokens are prompt-cache READS, priced far below a
# fresh input token. Weights live in lib/burn-weights.sh (overridable by env)
# so agg-burn.sh can reuse the same numbers.
#   cache-read       sum of cache_read_input_tokens across all calls.
#   cache-create     sum of cache_creation_input_tokens across all calls.
#   input            sum of input_tokens across all calls.
#   cache-health     cache-read / (input + cache-read) * 100 - the standard
#                    prompt-cache hit-ratio: what share of input-side tokens
#                    (excluding output) were served from cache vs. paid fresh.
#                    Distinct from floor-share, which measures how much of
#                    cache-read is the fixed per-call floor re-warming.
#   cost-eq          input*W_INPUT + cache-read*W_CACHE_READ +
#                    cache-create*W_CACHE_CREATE + out*W_OUTPUT - the
#                    price-weighted token-equivalent total.
#   floor-share      first-turn * calls / cache-read * 100 - the fraction of
#                    all cache reads spent re-reading the fixed per-call floor.
#   compaction-rewarm compactions * the mean context of the first call after
#                    each compact_boundary - the re-warm cost compactions add.
#
# HIMMEL-2996 --raw / LEG_BURN_RAW=1: out=, cache-read=, cache-create= and
# input= print as plain integers instead of the %.1fk-rounded default, so a
# caller that sums across sessions (agg-burn.sh) can sum exact tokens instead
# of compounding per-session 0.1k rounding. Default stdout is unchanged.
#
# Exit: 0 with the line, 2 on a bad/missing/unresolvable argument, 3 if the
# transcript holds no assistant calls at all (an arm that never ran - a real
# and easily-missed outcome, so it gets its own code rather than 0/0/0).
#
# Seam: LEG_BURN_PROJECTS_DIR overrides the transcript root that a bare session
# name is resolved against (default: ~/.claude/projects).
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ plus jq, and the
# thing it reads is a Claude Code transcript, which is the same JSONL on every
# platform - it runs under git bash unchanged; only the default transcript root
# is Linux/macOS-shaped, and LEG_BURN_PROJECTS_DIR overrides that.
set -u

usage() {
    echo "usage: leg-burn.sh [--raw] <transcript.jsonl|session-name>" >&2
}

RAW=0
if [ "${1:-}" = "--raw" ]; then
    RAW=1
    shift
fi
[ "${LEG_BURN_RAW:-0}" = "1" ] && RAW=1

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    usage
    exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "leg-burn: jq is required" >&2; exit 2; }

LEG_BURN_HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/burn-weights.sh
. "$LEG_BURN_HERE/lib/burn-weights.sh"

ARG="$1"
PROJECTS="${LEG_BURN_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"

if [ -f "$ARG" ]; then
    TRANSCRIPT="$ARG"
else
    case "$ARG" in
        */*|*.jsonl)
            echo "leg-burn: no such transcript: $ARG" >&2
            exit 2 ;;
    esac
    if [ ! -d "$PROJECTS" ]; then
        echo "leg-burn: no transcript root to search: $PROJECTS (set LEG_BURN_PROJECTS_DIR)" >&2
        exit 2
    fi
    # Newest match wins: a resumed leg leaves several transcripts under one
    # name and the last one is the session the caller means.
    TRANSCRIPT=""
    NEWEST=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # GNU `date -r <file>` on Linux/git-bash; BSD `date -r` wants epoch
        # SECONDS, not a path, so macOS falls through to BSD stat. Without the
        # pair every mt is 0 and the LAST grep hit wins instead of the newest.
        mt=$(date -r "$f" +%s 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
        if [ "$mt" -ge "$NEWEST" ]; then NEWEST="$mt"; TRANSCRIPT="$f"; fi
    done <<EOF
$(grep -rlF "\"customTitle\":\"$ARG\"" "$PROJECTS" 2>/dev/null)
EOF
    if [ -z "$TRANSCRIPT" ]; then
        echo "leg-burn: no transcript found for session name: $ARG (searched $PROJECTS)" >&2
        exit 2
    fi
fi

# One streaming pass. `inputs` reads row by row, so a multi-hundred-MB
# transcript never lands in memory whole.
SUMMARY=$(jq -nr '
  def num(x): (x // 0);
  reduce inputs as $r (
    {calls: 0, ctx: 0, first: 0, out: 0, comp: 0, seen: {}, tooled: {},
     cr: 0, cc: 0, inp: 0, rewarmSum: 0, rewarmN: 0, afterComp: false};
    if ($r.type == "system" and $r.subtype == "compact_boundary") then
      .comp += 1 | .afterComp = true
    elif ($r.type == "assistant" and (($r.message.id // "") != "")) then
      ($r.message.id) as $id
      | (if ([($r.message.content // [])[]? | select(.type? == "tool_use")] | length) > 0
         then .tooled[$id] = true else . end)
      | if (.seen[$id] // false) then .
        else
          .seen[$id] = true
          | (num($r.message.usage.input_tokens)) as $i
          | (num($r.message.usage.cache_read_input_tokens)) as $crv
          | (num($r.message.usage.cache_creation_input_tokens)) as $ccv
          | ($i + $crv + $ccv) as $c
          | .calls += 1
          | .ctx += $c
          | .inp += $i
          | .cr += $crv
          | .cc += $ccv
          | .out += num($r.message.usage.output_tokens)
          | (if .calls == 1 then .first = $c else . end)
          | (if .afterComp then (.rewarmSum += $c | .rewarmN += 1 | .afterComp = false) else . end)
        end
    else . end
  )
  | [.calls, .ctx, .first, .out, .comp, (.tooled | length), .cr, .cc, .inp, .rewarmSum, .rewarmN] | @tsv
' "$TRANSCRIPT") || { echo "leg-burn: cannot parse transcript: $TRANSCRIPT" >&2; exit 2; }

CALLS=$(printf '%s' "$SUMMARY" | cut -f1)
CTX=$(printf '%s' "$SUMMARY" | cut -f2)
FIRST=$(printf '%s' "$SUMMARY" | cut -f3)
OUT=$(printf '%s' "$SUMMARY" | cut -f4)
COMP=$(printf '%s' "$SUMMARY" | cut -f5)
TOOLED=$(printf '%s' "$SUMMARY" | cut -f6)
CR=$(printf '%s' "$SUMMARY" | cut -f7)
CC=$(printf '%s' "$SUMMARY" | cut -f8)
INP=$(printf '%s' "$SUMMARY" | cut -f9)
REWARM_SUM=$(printf '%s' "$SUMMARY" | cut -f10)
REWARM_N=$(printf '%s' "$SUMMARY" | cut -f11)

if [ "${CALLS:-0}" -eq 0 ]; then
    echo "leg-burn: no assistant calls in $TRANSCRIPT (the arm never ran)" >&2
    exit 3
fi

TEXT_ONLY=$((CALLS - TOOLED))
AVG=$((CTX / CALLS))

k() { awk -v n="$1" 'BEGIN { printf (n >= 1000 ? "%.1fk" : "%d"), (n >= 1000 ? n / 1000 : n) }'; }
kf() { awk -v n="$1" 'BEGIN { printf (n >= 1000 ? "%.1fk" : "%.0f"), (n >= 1000 ? n / 1000 : n) }'; }
# HIMMEL-2996: the four cost-eq inputs go through kr() instead of k()/kf()
# directly, so --raw/LEG_BURN_RAW=1 can swap in the exact integer while the
# default path (RAW=0) delegates to the same formatter as before.
kr() { if [ "$RAW" -eq 1 ]; then awk -v n="$1" 'BEGIN { printf "%.0f", n }'; else "$2" "$1"; fi; }

COST_EQ=$(awk -v i="$INP" -v cr="$CR" -v cc="$CC" -v o="$OUT" \
    -v wi="$LEG_BURN_W_INPUT" -v wcr="$LEG_BURN_W_CACHE_READ" -v wcc="$LEG_BURN_W_CACHE_CREATE" -v wo="$LEG_BURN_W_OUTPUT" \
    'BEGIN { printf "%.10g", i*wi + cr*wcr + cc*wcc + o*wo }')
FLOOR_SHARE=$(awk -v first="$FIRST" -v calls="$CALLS" -v cr="$CR" \
    'BEGIN { printf "%.1f", (cr > 0 ? first * calls / cr * 100 : 0) }')
CACHE_HEALTH=$(awk -v cr="$CR" -v inp="$INP" \
    'BEGIN { t = cr + inp; printf "%.1f", (t > 0 ? cr / t * 100 : 0) }')
COMPACTION_REWARM=$(awk -v n="$REWARM_N" -v s="$REWARM_SUM" -v comp="$COMP" \
    'BEGIN { printf "%.10g", (n > 0 ? comp * (s / n) : 0) }')

printf 'leg-burn %s: calls=%s avg-ctx=%s first-turn=%s out=%s compactions=%s text-only=%s cache-read=%s cache-create=%s input=%s cache-health=%s%% cost-eq=%s floor-share=%s%% compaction-rewarm=%s\n' \
    "$(basename "$TRANSCRIPT")" "$CALLS" "$(k "$AVG")" "$(k "$FIRST")" "$(kr "$OUT" k)" "$COMP" "$TEXT_ONLY" \
    "$(kr "$CR" kf)" "$(kr "$CC" kf)" "$(kr "$INP" kf)" "$CACHE_HEALTH" "$(kf "$COST_EQ")" "$FLOOR_SHARE" "$(kf "$COMPACTION_REWARM")"
