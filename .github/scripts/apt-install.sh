#!/usr/bin/env bash
# .github/scripts/apt-install.sh -- install apt packages on a CI runner so a
# stalled Ubuntu archive mirror cannot kill the job (HIMMEL-2872).
#
# Order, each attempt under its own `timeout`:
#   1. cached .debs  -- `install --no-download` from $APT_ARCHIVES (restored by
#                       actions/cache); skipped when the cache is empty.
#   2. plain install -- against the runner's configured (primary) mirror.
#   3. alternate     -- rewrite the mirror host in the apt sources to
#                       $APT_ALT_MIRROR, refresh the index, install again.
# On final failure prints ONE line naming the mirrors and the packages.
#
# Usage: apt-install.sh <pkg>...      (a pkg may carry a version pin: 'ffmpeg=7:6.1.*')
# Test seams (scripts/ci/test-apt-install.sh): APT_GET, APT_SUDO, APT_ARCHIVES,
# APT_SOURCES_FILES, APT_ALT_MIRROR, APT_T_CACHED, APT_T_PLAIN, APT_T_ALT.
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: apt-install.sh <pkg>..." >&2; exit 2; }

APT_GET="${APT_GET:-apt-get}"
SUDO="${APT_SUDO-sudo}"
ARCHIVES="${APT_ARCHIVES:-$HOME/apt-archives}"
ALT="${APT_ALT_MIRROR:-archive.ubuntu.com}"
SOURCES="${APT_SOURCES_FILES:-/etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list}"
T_CACHED="${APT_T_CACHED:-60}"
T_PLAIN="${APT_T_PLAIN:-120}"
T_ALT="${APT_T_ALT:-180}"

mkdir -p "$ARCHIVES/partial"
opts=(-y --no-install-recommends -o DPkg::Lock::Timeout=60 -o "Dir::Cache::archives=$ARCHIVES")

primary=""
for f in $SOURCES; do
  [ -f "$f" ] || continue
  primary="$(grep -Eo 'https?://[^/ ]+' "$f" | head -n 1 | sed 's#^https\?://##')"
  [ -n "$primary" ] && break
done
primary="${primary:-unknown}"

apt() { $SUDO timeout "$1" "$APT_GET" "${@:2}"; }

if compgen -G "$ARCHIVES/*.deb" > /dev/null; then
  if apt "$T_CACHED" install --no-download "${opts[@]}" "$@"; then
    echo "apt-install: installed from cached debs (mirror not contacted)"
    exit 0
  fi
  echo "apt-install: cached debs incomplete, trying mirror $primary"
fi

if apt "$T_PLAIN" install "${opts[@]}" "$@"; then
  echo "apt-install: installed from $primary"
  exit 0
fi

echo "apt-install: $primary failed or stalled, switching to $ALT"
for f in $SOURCES; do
  [ -f "$f" ] || continue
  $SUDO sed -i "s#//$primary#//$ALT#g" "$f"
done
if apt "$T_ALT" update -o Acquire::Retries=1 -o DPkg::Lock::Timeout=60 \
   && apt "$T_ALT" install "${opts[@]}" "$@"; then
  echo "apt-install: installed from alternate mirror $ALT"
  exit 0
fi

echo "apt-install: FAILED mirrors=$primary,$ALT packages=$*" >&2
exit 1
