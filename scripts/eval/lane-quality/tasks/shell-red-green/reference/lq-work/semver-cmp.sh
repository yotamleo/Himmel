#!/usr/bin/env bash
# Reference solution (HIMMEL-4090 lane-quality task shell-red-green).
set -u
[ $# -eq 2 ] || { echo "usage: semver-cmp.sh A B" >&2; exit 64; }
for v in "$1" "$2"; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "semver-cmp: malformed version '$v'" >&2; exit 64; }
done
IFS=. read -r -a a <<<"$1"
IFS=. read -r -a b <<<"$2"
for i in 0 1 2; do
  if ((10#${a[$i]} < 10#${b[$i]})); then echo -1; exit 0; fi
  if ((10#${a[$i]} > 10#${b[$i]})); then echo 1; exit 0; fi
done
echo 0
