#!/usr/bin/env bash
# .github/scripts/apt-install.sh -- install apt packages on a CI runner so a
# stalled Ubuntu archive mirror cannot kill the job (HIMMEL-2872).
#
# Order, each attempt under its own `timeout`:
#   1. cached .debs  -- `install --no-download` from $APT_ARCHIVES (restored by
#                       actions/cache); skipped when the cache is empty.
#   2. plain install -- against the runner's configured (primary) mirror.
#   3. alternate     -- rewrite the mirror host in the apt sources (or the
#                       mirror+file: list they point at) to $APT_ALT_MIRROR
#                       (default archive.ubuntu.com, us.archive.ubuntu.com when
#                       that is already the primary), refresh the index, retry.
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
# root apt leaves partial/ owned by _apt (0700): the unprivileged cache save
# could not read it, so drop partial/ and lock on every exit path.
trap '$SUDO rm -rf "$ARCHIVES/partial" "$ARCHIVES/lock"' EXIT
opts=(-y --no-install-recommends -o DPkg::Lock::Timeout=60 -o "Dir::Cache::archives=$ARCHIVES")

# Primary mirror: read only live (non-comment) `URIs:` / `deb` lines; the
# cloud-init header of ubuntu.sources carries a help.ubuntu.com link. GitHub's
# ubuntu-24.04 runners point URIs: at `mirror+file:<list>`, so the host is the
# first live URL in that list and the fallback must rewrite the list itself.
live() { grep -Ev '^[[:space:]]*#' "$1"; }
host_of() { grep -Eo 'https?://[^/[:space:]]+' | head -n 1 | sed 's#^https\?://##'; }
primary=""; mlist=""
for f in $SOURCES; do
  [ -f "$f" ] || continue
  uri="$(live "$f" | sed -nE 's/^[[:space:]]*URIs:[[:space:]]*([^[:space:]]+).*/\1/p; s/^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?([^[:space:]]+).*/\3/p' | head -n 1)"
  case "$uri" in
    mirror+file:*) mlist="${uri#mirror+file:}"; [ -f "$mlist" ] && primary="$(live "$mlist" | host_of)" ;;
    *) primary="$(host_of <<<"$uri")" ;;
  esac
  [ -n "$primary" ] && break
done
primary="${primary:-unknown}"
# an alternate identical to the primary would retry the same stalled host
if [ -z "${APT_ALT_MIRROR:-}" ] && [ "$primary" = archive.ubuntu.com ]; then
  ALT=us.archive.ubuntu.com
fi

apt() { $SUDO timeout -k 10 "$1" "$APT_GET" "${@:2}"; }

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
if [ -n "$mlist" ] && [ -f "$mlist" ]; then
  # replace the list with the alternate alone: a priority tie would let apt keep trying the stalled host
  tmp="$(mktemp)" || { echo "apt-install: FAILED mirrors=$primary,$ALT packages=$* (mktemp)" >&2; exit 1; }
  printf 'http://%s/ubuntu/\tpriority:1\n' "$ALT" > "$tmp"
  $SUDO cp "$tmp" "$mlist"; rm -f "$tmp"
fi
for f in $SOURCES; do
  [ -f "$f" ] || continue
  $SUDO sed -i "/^[[:space:]]*#/! s#//${primary//./\\.}#//$ALT#g" "$f"
done
if apt "$T_ALT" update -o Acquire::Retries=1 -o DPkg::Lock::Timeout=60 \
   && apt "$T_ALT" install "${opts[@]}" "$@"; then
  echo "apt-install: installed from alternate mirror $ALT"
  exit 0
fi

echo "apt-install: FAILED mirrors=$primary,$ALT packages=$*" >&2
exit 1
