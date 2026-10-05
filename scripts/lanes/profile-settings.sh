#!/usr/bin/env bash
# scripts/lanes/profile-settings.sh - resolve a named plugin profile to a stable
# settings file and print its absolute path (HIMMEL-4013).
#
# For launch paths that are NOT headed-arm-leg.sh (console arm, arm-resume,
# hop, schedule-resume, the CR critic, the morning-briefing --llm call): they
# need `claude --settings <file>` and cannot run the per-leg resolution
# headed-arm-leg.sh does. The file is written atomically to a per-user dir that
# outlives the arming process (an `at`/cron relaunch fires hours later), so it
# is NOT under /tmp.
#
# The file is content-addressed (HIMMEL-4033): <dir>/<sha256-12 of the resolved
# JSON>/<profile>.json. Two checkouts whose plugin-profiles.json differ resolve
# to different paths, so neither can rewrite the settings an armed relaunch
# already points at; identical content reuses one path. Old files are left alone.
#
# Usage: profile-settings.sh <profile>
#   stdout: absolute path of <hash>/<profile>.json; rc 0
#   rc 2:   FAIL CLOSED - unknown profile / resolver failure / unwritable dir.
#           A launch that silently runs with the full plugin set is exactly the
#           gap this exists to close, so callers must refuse on rc != 0.
# Env: HIMMEL_PROFILE_SETTINGS_DIR (default $HOME/.himmel/launch-profiles),
#      HIMMEL_PROFILE_REPO (resolve cwd; default this checkout).
# Platform: POSIX bash 3.2+, node. No .ps1 twin: Windows launchers resolve the
# profile through plugin-profiles.mjs directly.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE="${1:-}"
case "$PROFILE" in
    ''|*[!A-Za-z0-9._-]*) echo "profile-settings: usage: profile-settings.sh <profile> (got '${PROFILE}')" >&2; exit 2 ;;
esac
DIR="${HIMMEL_PROFILE_SETTINGS_DIR:-${HOME:-/tmp}/.himmel/launch-profiles}"
CWD="${HIMMEL_PROFILE_REPO:-$HERE/../..}"
mkdir -p "$DIR" 2>/dev/null || { echo "profile-settings: cannot create $DIR" >&2; exit 2; }
if ! JSON="$(cd "$CWD" && node "$HERE/plugin-profiles.mjs" "$PROFILE" 2>&1)" || [ -z "$JSON" ]; then
    echo "profile-settings: profile '$PROFILE' did not resolve: $JSON" >&2
    exit 2
fi
case "$JSON" in '{'*) ;; *) echo "profile-settings: profile '$PROFILE' resolver output is not JSON: $JSON" >&2; exit 2 ;; esac
if command -v sha256sum >/dev/null 2>&1; then HASH="$(printf '%s\n' "$JSON" | sha256sum | cut -c1-12)"
elif command -v shasum >/dev/null 2>&1; then HASH="$(printf '%s\n' "$JSON" | shasum -a 256 | cut -c1-12)"
else HASH=""; fi
case "$HASH" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "profile-settings: no sha256 tool to content-address the settings file" >&2; exit 2 ;;
esac
DIR="$DIR/$HASH"
mkdir -p "$DIR" 2>/dev/null || { echo "profile-settings: cannot create $DIR" >&2; exit 2; }
OUT="$DIR/$PROFILE.json"
TMP="$OUT.tmp.$$"
if ! printf '%s\n' "$JSON" > "$TMP" || ! mv -f "$TMP" "$OUT"; then
    rm -f "$TMP"
    echo "profile-settings: cannot write $OUT" >&2
    exit 2
fi
printf '%s\n' "$(cd "$DIR" && pwd)/$PROFILE.json"
