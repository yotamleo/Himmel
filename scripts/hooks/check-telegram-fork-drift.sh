#!/usr/bin/env bash
# Flags when upstream telegram@claude-plugins-official has drifted from the
# version the telegram-himmel fork is pinned to. Fail-open if upstream isn't
# installed locally (so CI / fresh clones don't break); fail-closed on drift.
set -euo pipefail
PIN="marketplace/plugins/telegram-himmel/UPSTREAM_PIN"
CACHE="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"

[ -f "$PIN" ] || { echo "drift-check: $PIN missing — skipping"; exit 0; }
version="$(sed -n 's/^version=//p' "$PIN" | head -1)"
want_sha="$(sed -n 's/^server_sha256=//p' "$PIN" | head -1)"

[ -d "$CACHE" ] || { echo "drift-check: upstream telegram not installed locally — skipping"; exit 0; }

pinned_dir="$CACHE/$version"
if [ ! -d "$pinned_dir" ]; then
  echo "ERR drift-check: pinned upstream telegram v$version no longer in cache." >&2
  # shellcheck disable=SC2012  # display-only listing of version dirs (alnum names); find adds no value here
  echo "    Available now: $(ls "$CACHE" 2>/dev/null | tr '\n' ' ')" >&2
  echo "    Upstream bumped — re-sync the fork (marketplace/plugins/telegram-himmel/README.md)" >&2
  echo "    then update UPSTREAM_PIN. To commit unrelated work meanwhile:" >&2
  echo "      SKIP=telegram-fork-drift git commit ..." >&2
  exit 1
fi

got_sha="$(sha256sum "$pinned_dir/server.ts" | awk '{print $1}')"
if [ "$got_sha" != "$want_sha" ]; then
  echo "ERR drift-check: upstream telegram v$version server.ts changed in place." >&2
  echo "    pinned=$want_sha" >&2
  echo "    actual=$got_sha" >&2
  echo "    Re-sync the fork + update UPSTREAM_PIN. Bypass: SKIP=telegram-fork-drift git commit ..." >&2
  exit 1
fi

echo "drift-check: telegram-himmel in sync with upstream v$version"
