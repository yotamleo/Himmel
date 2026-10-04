#!/bin/bash -p
# scripts/lanes/leg-claude-launcher-consult.sh - the launcher a --consult hands
# headed-arm.sh instead of leg-claude-launcher.sh (HIMMEL-4152).
#
# headed-arm.sh execs its launcher through `env ... "$LAUNCHER"`, so the
# shim's own `#!/usr/bin/env bash` would let PATH pick the interpreter, and a
# bash started that way honours the startup file and exported functions the
# caller left in the environment. This entry closes both for a consult only:
#  - the interpreter is absolute (the kernel reads this shebang, no PATH), and
#    `-p` makes this bash skip the startup file, the option imports and the
#    exported functions;
#  - it strips those variables from the environment and execs the real shim
#    on the pinned absolute bash, again with -p, on the pinned PATH.
# The shim then does its own consult work (pinned claude, `--setting-sources ""`).
#
# headed-arm-leg.sh exports this file's CANONICAL path as the launcher, so
# BASH_SOURCE names the in-repo directory and the shim beside it.
#
# Platform: /bin/bash (macOS ships 3.2 there; Linux has it on every
# distribution this kit supports). No .ps1 twin: the consult launcher is
# Linux/KDE-only, like headed-arm.sh.
set -u

_lcc_dir="${BASH_SOURCE[0]%/*}"
case "$_lcc_dir" in
    /*) ;;
    *) echo "leg-claude-launcher-consult: refusing to launch: not invoked by an absolute path (${BASH_SOURCE[0]})" >&2; exit 2 ;;
esac
# shellcheck source=consult-env.sh
. "$_lcc_dir/consult-env.sh" || { echo "leg-claude-launcher-consult: refusing to launch: cannot load $_lcc_dir/consult-env.sh" >&2; exit 2; }

if ! _lcc_bash="$(consult_pin_bash)"; then
    echo "leg-claude-launcher-consult: refusing to launch: no /usr/bin/bash or /bin/bash" >&2
    exit 2
fi
_lcc_path="$(consult_pin_path)"
consult_scrub_args

exec /usr/bin/env "${CONSULT_SCRUB[@]}" PATH="$_lcc_path" LEG_PROFILE_NO_SETTING_SOURCES=1 \
    "$_lcc_bash" -p "$_lcc_dir/leg-claude-launcher.sh" "$@"
