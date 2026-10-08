#!/usr/bin/env bash
# himmel-bus has no network code in server/ or lib/ (threat model T7-2): rulings
# and tokens must not leave the station. Includes a planted-violation control so
# the lint cannot pass vacuously.
#
# Usage: bash marketplace/plugins/himmel-bus/tests/test-lint.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PATTERN='node:(http|https|http2|net|dgram|tls|dns)|fetch\(|XMLHttpRequest|WebSocket|from .(http|https|net|dgram|tls|dns).'

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

hits() { grep -rnE --include='*.mjs' --include='*.js' --include='*.ts' -e "$PATTERN" "$@"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bus-lint.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# Control: each network shape is caught.
i=0
for line in "import http from 'node:http';" "await fetch('https://x.test');" "import net from 'node:net';" "import dgram from 'node:dgram';"; do
  i=$((i+1))
  printf '%s\n' "$line" > "$tmp/planted$i.mjs"
  if [ -n "$(hits "$tmp/planted$i.mjs")" ]; then pass "control $i: planted network use is detected"; else fail "control $i: lint missed: $line"; fi
done

# scan_dir <dir>: 0 clean, 1 network code found, 2 the scan itself failed.
scan_dir() {
  local found rc
  found="$(hits "$1")"; rc=$?
  if [ "$rc" -gt 1 ]; then return 2; fi
  [ -z "$found" ]
}

# Control: a scan error (unreadable source) is never a pass. Skipped as root,
# which reads every file.
if [ "$(id -u)" -ne 0 ]; then
  mkdir "$tmp/unreadable"; printf 'const a = 1;\n' > "$tmp/unreadable/a.mjs"; chmod 000 "$tmp/unreadable/a.mjs"
  scan_dir "$tmp/unreadable" 2>/dev/null; rc=$?
  chmod 600 "$tmp/unreadable/a.mjs"
  if [ "$rc" -eq 2 ]; then pass "control: an unreadable source is a scan failure"; else fail "control: an unreadable source scanned as rc=$rc"; fi
fi

for dir in server lib; do
  if [ -z "$(find "$HERE/$dir" -name '*.mjs' -print -quit 2>/dev/null)" ]; then fail "$dir/ has no sources to scan"; continue; fi
  scan_dir "$HERE/$dir"; rc=$?
  case "$rc" in
    0) pass "$dir/ has no network code" ;;
    2) fail "$dir/ scan failed" ;;
    *) fail "$dir/ has network code:"; hits "$HERE/$dir" ;;
  esac
done

[ "$failures" -eq 0 ] || { echo "FAILED: $failures"; exit 1; }
echo "all passed"
