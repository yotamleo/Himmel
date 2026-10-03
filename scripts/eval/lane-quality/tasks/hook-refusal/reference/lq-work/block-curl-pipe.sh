#!/usr/bin/env bash
# Reference solution (HIMMEL-4090 lane-quality task hook-refusal).
set -u
ev="$(cat)"
tool="$(printf '%s' "$ev" | jq -er '.tool_name // ""' 2>/dev/null)" || {
  echo "block-curl-pipe: unparseable hook input, refusing" >&2; exit 2; }
[ "$tool" = Bash ] || exit 0
cmd="$(printf '%s' "$ev" | jq -r '.tool_input.command // ""')"
re='(^|[^[:alnum:]_-])(curl|wget)([[:space:]][^|]*)?\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|dash)([^[:alnum:]_.-]|$)'
if [[ "$cmd" =~ $re ]]; then
  echo "block-curl-pipe: piping a download into a shell is refused" >&2
  exit 2
fi
exit 0
