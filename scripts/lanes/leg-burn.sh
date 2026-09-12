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
    echo "usage: leg-burn.sh <transcript.jsonl|session-name>" >&2
}

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    usage
    exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "leg-burn: jq is required" >&2; exit 2; }

ARG="$1"
PROJECTS="${LEG_BURN_PROJECTS_DIR:-$HOME/.claude/projects}"

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
    {calls: 0, ctx: 0, first: 0, out: 0, comp: 0, seen: {}, tooled: {}};
    if ($r.type == "system" and $r.subtype == "compact_boundary") then
      .comp += 1
    elif ($r.type == "assistant" and (($r.message.id // "") != "")) then
      ($r.message.id) as $id
      | (if ([($r.message.content // [])[]? | select(.type? == "tool_use")] | length) > 0
         then .tooled[$id] = true else . end)
      | if (.seen[$id] // false) then .
        else
          .seen[$id] = true
          | ((num($r.message.usage.input_tokens)
              + num($r.message.usage.cache_read_input_tokens)
              + num($r.message.usage.cache_creation_input_tokens))) as $c
          | .calls += 1
          | .ctx += $c
          | .out += num($r.message.usage.output_tokens)
          | (if .calls == 1 then .first = $c else . end)
        end
    else . end
  )
  | [.calls, .ctx, .first, .out, .comp, (.tooled | length)] | @tsv
' "$TRANSCRIPT") || { echo "leg-burn: cannot parse transcript: $TRANSCRIPT" >&2; exit 2; }

CALLS=$(printf '%s' "$SUMMARY" | cut -f1)
CTX=$(printf '%s' "$SUMMARY" | cut -f2)
FIRST=$(printf '%s' "$SUMMARY" | cut -f3)
OUT=$(printf '%s' "$SUMMARY" | cut -f4)
COMP=$(printf '%s' "$SUMMARY" | cut -f5)
TOOLED=$(printf '%s' "$SUMMARY" | cut -f6)

if [ "${CALLS:-0}" -eq 0 ]; then
    echo "leg-burn: no assistant calls in $TRANSCRIPT (the arm never ran)" >&2
    exit 3
fi

TEXT_ONLY=$((CALLS - TOOLED))
AVG=$((CTX / CALLS))

k() { awk -v n="$1" 'BEGIN { printf (n >= 1000 ? "%.1fk" : "%d"), (n >= 1000 ? n / 1000 : n) }'; }

printf 'leg-burn %s: calls=%s avg-ctx=%s first-turn=%s out=%s compactions=%s text-only=%s\n' \
    "$(basename "$TRANSCRIPT")" "$CALLS" "$(k "$AVG")" "$(k "$FIRST")" "$(k "$OUT")" "$COMP" "$TEXT_ONLY"
