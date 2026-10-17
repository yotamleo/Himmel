#!/usr/bin/env bash
# console-budget.sh - the console's handover budget. Prints one line
#   budget turns=<n> cache_read=<M>M verdict=OK|HANDOVER
# HANDOVER when turns >= CONSOLE_TURN_BUDGET (default 150) or cumulative
# cache-read >= CONSOLE_CACHE_READ_BUDGET_M million tokens (default 30): past
# either, every further turn re-reads the largest context for less than a
# fresh console would cost. A turn is one assistant API call, deduped by
# requestId (message.id when absent); sidechain (subagent) rows are not turns.
#
# usage: console-budget.sh [--title <console session name>]
# Session: CONTEXT_FILL_TRANSCRIPT, else --title (newest transcript whose
# customTitle matches), else CLAUDE_CODE_SESSION_ID - as context-fill.sh does.
# Exit: 0 OK, 3 HANDOVER, 2 the transcript cannot be read or holds no usage
# row. Never prints verdict=OK for a transcript it could not measure.
#
# Run it in an ordinary Bash call, not inside a Monitor (same as context-fill.sh).
# Platform guard (gitbash-only): POSIX bash 3.2+, no mapfile.
set -uo pipefail

num_env() { # <name> <default> - a bad value warns and falls back, never disables the budget
  local v="${!1:-$2}"
  case "$v" in
    ''|*[!0-9]*|???????*) v="" ;;
    *) v="$((10#$v))" ;;  # 10#: a leading zero (08) is not octal
  esac
  if [ -z "$v" ] || [ "$v" -eq 0 ]; then
    printf 'console-budget: ignoring %s=%s - using %s\n' "$1" "${!1:-$2}" "$2" >&2; v="$2"
  fi
  printf '%s\n' "$v"
}
TURN_BUDGET="$(num_env CONSOLE_TURN_BUDGET 150)"
CR_BUDGET_M="$(num_env CONSOLE_CACHE_READ_BUDGET_M 30)"

title=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title) [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "console-budget: --title needs a non-empty value" >&2; exit 2; }; title="$2"; shift 2 ;;
    *) echo "usage: console-budget.sh [--title <console session name>]" >&2; exit 2 ;;
  esac
done

config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

resolve_transcript() {
  local f
  if [ -n "${CONTEXT_FILL_TRANSCRIPT:-}" ]; then
    printf '%s\n' "$CONTEXT_FILL_TRANSCRIPT"; return 0
  fi
  if [ -n "$title" ]; then
    # a renamed session keeps its old title rows: only the LAST customTitle counts;
    # a reused name keeps the newest transcript
    local best=""
    while IFS= read -r f; do
      [ "$(grep -o '"customTitle":"[^"]*"' "$f" | tail -n 1)" = "\"customTitle\":\"$title\"" ] || continue
      if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
    done < <(find "$config_dir/projects" -name '*.jsonl' -mtime -3 -exec grep -lF "\"customTitle\":\"$title\"" {} + 2>/dev/null)
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"; return 0
  fi
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 1
  for f in "$config_dir"/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

transcript="$(resolve_transcript)" || { echo "console-budget: cannot resolve the console session (set CONTEXT_FILL_TRANSCRIPT, --title, or CLAUDE_CODE_SESSION_ID)" >&2; exit 2; }
if [ ! -r "$transcript" ] || [ ! -f "$transcript" ]; then echo "console-budget: cannot read transcript $transcript" >&2; exit 2; fi
command -v node >/dev/null 2>&1 || { echo "console-budget: node not found" >&2; exit 2; }

# <turns> <cache_read tokens>, last row per request wins (streamed rows repeat the id)
counts="$(node - "$transcript" <<'NODE'
const fs = require('fs');
const seen = new Map();
for (const line of fs.readFileSync(process.argv[2], 'utf8').split('\n')) {
  if (!line) continue;
  let row;
  try { row = JSON.parse(line); } catch { continue; }
  if (!row || row.type !== 'assistant' || row.isSidechain) continue;
  const usage = row.message && row.message.usage;
  const id = row.requestId || (row.message && row.message.id);
  if (!id || !usage || typeof usage !== 'object') continue;
  const cr = usage.cache_read_input_tokens;
  seen.set(id, Number.isSafeInteger(cr) && cr >= 0 ? cr : 0);
}
let sum = 0;
for (const v of seen.values()) sum += v;
process.stdout.write(`${seen.size} ${sum}\n`);
NODE
)" || { echo "console-budget: cannot parse $transcript" >&2; exit 2; }

turns="${counts%% *}"
cr="${counts##* }"
[ "$turns" -gt 0 ] 2>/dev/null || { echo "console-budget: no assistant usage rows in $transcript" >&2; exit 2; }

m="$(awk -v c="$cr" 'BEGIN{printf "%.1f", c / 1000000}')"
if [ "$turns" -ge "$TURN_BUDGET" ] || [ "$cr" -ge $((CR_BUDGET_M * 1000000)) ]; then
  printf 'budget turns=%s cache_read=%sM verdict=HANDOVER\n' "$turns" "$m"
  exit 3
fi
printf 'budget turns=%s cache_read=%sM verdict=OK\n' "$turns" "$m"
