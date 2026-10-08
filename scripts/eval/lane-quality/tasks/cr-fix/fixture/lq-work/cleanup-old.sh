#!/usr/bin/env bash
# cleanup-old.sh DIR DAYS - delete regular files directly in DIR that are older
# than DAYS days. Sub-directories are never touched.
dir="$1"; days="$2"
[ -d "$dir" ] || { echo "cleanup-old: not a directory: $dir" >&2; exit 66; }
# shellcheck disable=SC2044
for f in $(find "$dir" -maxdepth 1 -type f -mtime +"$days"); do
  rm -f "$f"
done
