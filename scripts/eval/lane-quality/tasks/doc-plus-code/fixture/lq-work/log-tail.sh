#!/usr/bin/env bash
# log-tail.sh - print the last N lines of a log file.
# Usage: log-tail.sh [-n N] FILE
set -u
n=10
while [ $# -gt 0 ]; do
  case "$1" in
    -n) [ $# -ge 2 ] || { echo "log-tail: -n needs a value" >&2; exit 64; }; n="$2"; shift 2 ;;
    -*) echo "log-tail: unknown option $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { echo "usage: log-tail.sh [-n N] FILE" >&2; exit 64; }
case "$n" in ''|*[!0-9]*) echo "log-tail: -n must be a non-negative integer" >&2; exit 64 ;; esac
[ -r "$1" ] || { echo "log-tail: cannot read $1" >&2; exit 66; }
tail -n "$n" -- "$1"
