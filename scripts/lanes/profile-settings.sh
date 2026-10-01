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
# Usage: profile-settings.sh <profile>
#   stdout: absolute path of <profile>.json; rc 0
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
OUT="$DIR/$PROFILE.json"
TMP="$OUT.tmp.$$"
if ! printf '%s\n' "$JSON" > "$TMP" || ! mv -f "$TMP" "$OUT"; then
    rm -f "$TMP"
    echo "profile-settings: cannot write $OUT" >&2
    exit 2
fi
printf '%s\n' "$(cd "$DIR" && pwd)/$PROFILE.json"
