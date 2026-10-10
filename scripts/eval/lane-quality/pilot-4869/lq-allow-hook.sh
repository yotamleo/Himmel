#!/usr/bin/env bash
# HIMMEL-5077: jail-only PreToolUse hook for the claudex eval rows. Usage (registered
# by sandbox.sh): lq-allow-hook.sh <jwt> <wt>, tool-call JSON on stdin.
# Allows one shape only: `bash <base>/lq-work/test-*.sh`, <base> one of the two mounts
# of the row worktree, nothing chained, no `..` segment, a regular non-symlink file
# directly in a non-symlink lq-work. Anything else: no output, exit 0 (no opinion, so
# the permission rules and the classifier decide as before). Never denies.
set -u
cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
case "$cmd" in "bash "?*) ;; *) exit 0 ;; esac
p="${cmd#bash }"
# one plain path: no space, quote, glob, $, ;, &, |, <, >, backtick, newline
case "$p" in *[!A-Za-z0-9_./+-]*) exit 0 ;; esac
case "/$p/" in */../*) exit 0 ;; esac
name="${p##*/}"
case "$name" in test-*.sh) ;; *) exit 0 ;; esac
dir="${p%/*}"
for base in "${1:-}" "${2:-}"; do
  [ -n "$base" ] && [ "$dir" = "$base/lq-work" ] || continue
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$p" ] && [ ! -L "$p" ] || exit 0
  [ "$(realpath -- "$p")" = "$(realpath -- "$base")/lq-work/$name" ] || exit 0
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"HIMMEL-5077: the eval row'"'"'s own lq-work test script"}}'
  exit 0
done
exit 0
