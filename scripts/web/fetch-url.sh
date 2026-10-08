#!/usr/bin/env bash
# fetch-url.sh <url> — fetch a pasted link as text (HIMMEL-4908).
# X / Instagram links (hosts in scripts/web/walled-hosts.conf) go through the
# Scrapling stealth fetcher with no cookies; any other host is a plain GET.
# Exit: 0 ok, 2 usage, 3 scrapling venv missing (install hint on stderr),
# 4 fetch failed (status on stderr).
# Platform guard (gitbash-only): bash + python only; a .ps1 twin is not needed.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
py="${HOME}/.himmel/scrapling-venv/bin/python"
[ -x "$py" ] || py="$(command -v python3 || command -v python)" || { echo "python not found" >&2; exit 3; }
exec "$py" -I "$here/fetch_url.py" "$@"
