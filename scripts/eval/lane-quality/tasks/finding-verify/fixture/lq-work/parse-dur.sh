#!/usr/bin/env bash
# parse-dur.sh - convert a duration such as 1h30m or 45s to whole seconds.
# Usage: parse-dur.sh DURATION
set -u
[ $# -eq 1 ] || { echo "usage: parse-dur.sh DURATION" >&2; exit 64; }
in="$1"; total=0
[ -n "$in" ] || { echo "parse-dur: empty duration" >&2; exit 64; }
while [ -n "$in" ]; do
  num="${in%%[!0-9]*}"
  [ -n "$num" ] || { echo "parse-dur: bad duration '$1'" >&2; exit 64; }
  in="${in#"$num"}"
  unit="${in:0:1}"
  in="${in:1}"
  case "$unit" in
    h) total=$((total + 10#$num * 3600)) ;;
    m) total=$((total + 10#$num * 60)) ;;
    s) total=$((total + 10#$num * 60)) ;;
    *) echo "parse-dur: bad unit in '$1'" >&2; exit 64 ;;
  esac
done
echo "$total"
