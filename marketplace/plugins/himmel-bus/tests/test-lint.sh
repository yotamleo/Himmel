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

hits() { grep -rnE --include='*.mjs' --include='*.js' --include='*.ts' -e "$PATTERN" "$@" 2>/dev/null; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bus-lint.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# Control: each network shape is caught.
i=0
for line in "import http from 'node:http';" "await fetch('https://x.test');" "import net from 'node:net';" "import dgram from 'node:dgram';"; do
  i=$((i+1))
  printf '%s\n' "$line" > "$tmp/planted$i.mjs"
  if [ -n "$(hits "$tmp/planted$i.mjs")" ]; then pass "control $i: planted network use is detected"; else fail "control $i: lint missed: $line"; fi
done

for dir in server lib; do
  found="$(hits "$HERE/$dir")"
  if [ -z "$found" ]; then pass "$dir/ has no network code"; else fail "$dir/ has network code:"; printf '%s\n' "$found"; fi
done

[ "$failures" -eq 0 ] || { echo "FAILED: $failures"; exit 1; }
echo "all passed"
