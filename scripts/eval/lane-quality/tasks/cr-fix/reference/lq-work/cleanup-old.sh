#!/usr/bin/env bash
# cleanup-old.sh DIR DAYS - delete regular files directly in DIR that are older
# than DAYS days. Sub-directories are never touched.
dir="$1"; days="$2"
[ -d "$dir" ] || { echo "cleanup-old: not a directory: $dir" >&2; exit 66; }
case "$days" in
  ''|*[!0-9]*) echo "cleanup-old: DAYS must be a whole number: $days" >&2; exit 64 ;;
esac
find "$dir" -maxdepth 1 -type f -mtime +"$days" -exec rm -f {} +
