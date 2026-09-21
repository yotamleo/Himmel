#!/usr/bin/env bash
# clean-sandbox.sh — the ONE sanctioned way to observe a command against a
# clean environment (HIMMEL-3321).
#
# Usage: clean-sandbox.sh [--keep VAR]... [--allow-handover-dir] [--scratch DIR] -- cmd args...
#
# WHY: a hand-rolled `HOME=... PATH=... cmd` keeps EVERY other operator variable
# (HANDOVER_DIR, JIRA_*, CODEX_HOME, CLAUDE_*, HIMMEL_*, HIMMELCTL_*), so a
# "clean install" observation was read against the operator's real state (2 red
# vs 3 red when truly clean). This starts from `env -i`, passes ONLY the
# launcher-owned scratch vars plus an explicit --keep allowlist, and prints the
# environment it actually passed before exec.
#
# Launcher-owned (cannot be --keep'd), all under the scratch dir:
#   HOME=<scratch>/home  HIMMEL_PROVENANCE_DIR=<scratch>/prov
#   HIMMELCTL_CACHE_DIR=<scratch>/cache  TMPDIR=<scratch>/tmp
#   PATH=/usr/local/bin:/usr/bin:/bin
# --keep VAR copies VAR from the caller's env when it is set there (an unset one
#   is reported and not passed). --keep HANDOVER_DIR needs --allow-handover-dir.
# --scratch DIR uses DIR (created if missing); without it a fresh mktemp dir under
#   $TMPDIR is made. The launcher execs the command, so it cannot clean up: an
#   auto-created scratch dir is left in place and its path is printed.
# The printed env masks the value of any name matching TOKEN|KEY|SECRET|PASS
#   (case-insensitive) as ***; the child still receives the real value.
#
# ponytail: the PATH is fixed at the common Linux/macOS system dirs, so a tool
# installed elsewhere (Homebrew under /opt/homebrew, nvm, ~/.local/bin) is NOT
# found in the sandbox; pass a full path to it, or --keep PATH is refused on
# purpose (the point is not to inherit the operator's PATH).
#
# Platform guard (linux/macos-only): POSIX bash 3.2+ (no associative arrays, no
# ${var,,}), like headed-arm-leg.sh - no .ps1 twin; on Windows the observation
# has no equivalent (os.homedir() reads USERPROFILE - see
# scripts/himmelctl/test/_hermetic-home.sh).
#
# Exit: 2 usage/refusal; otherwise the child's own status (exec).
set -uo pipefail

SANDBOX_PATH="/usr/local/bin:/usr/bin:/bin"

die() { echo "clean-sandbox: $*" >&2; exit 2; }

keep=""
allow_handover=0
scratch=""
while [ $# -gt 0 ]; do
    case "$1" in
        --keep)
            [ $# -ge 2 ] || die "--keep needs a VAR name"
            case "$2" in
                ''|[0-9]*|*[!A-Za-z0-9_]*) die "--keep: '$2' is not a valid variable name" ;;
            esac
            case "$2" in
                HOME|PATH|TMPDIR|HIMMEL_PROVENANCE_DIR|HIMMELCTL_CACHE_DIR)
                    die "--keep $2: launcher-owned (set to a scratch value), cannot be kept" ;;
            esac
            keep="$keep $2"
            shift 2
            ;;
        --allow-handover-dir) allow_handover=1; shift ;;
        --scratch)
            [ $# -ge 2 ] || die "--scratch needs a DIR"
            scratch="$2"
            shift 2
            ;;
        --) shift; break ;;
        *) die "unknown argument '$1' (usage: clean-sandbox.sh [--keep VAR]... [--allow-handover-dir] [--scratch DIR] -- cmd args...)" ;;
    esac
done
[ $# -ge 1 ] || die "no command given (expected '-- cmd args...')"

for v in $keep; do
    if [ "$v" = HANDOVER_DIR ] && [ "$allow_handover" -ne 1 ]; then
        die "--keep HANDOVER_DIR refused: it points the child at the operator's real handover state; add --allow-handover-dir if that is the intent"
    fi
done

if [ -z "$scratch" ]; then
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/clean-sandbox.XXXXXX") || die "could not create a scratch dir under ${TMPDIR:-/tmp}"
fi
mkdir -p "$scratch/home" "$scratch/prov" "$scratch/cache" "$scratch/tmp" || die "could not create scratch subdirs under $scratch"

envargs=(
    "HOME=$scratch/home"
    "PATH=$SANDBOX_PATH"
    "HIMMEL_PROVENANCE_DIR=$scratch/prov"
    "HIMMELCTL_CACHE_DIR=$scratch/cache"
    "TMPDIR=$scratch/tmp"
)
notes=""
for v in $keep; do
    if printenv "$v" >/dev/null 2>&1; then
        envargs+=("$v=$(printenv "$v")")
    else
        notes="$notes $v"
    fi
done

{
    echo "clean-sandbox: scratch=$scratch"
    echo "clean-sandbox: env passed to the child (env -i; nothing else is inherited):"
    for kv in "${envargs[@]}"; do
        name=${kv%%=*}
        value=${kv#*=}
        case $(printf '%s' "$name" | tr '[:lower:]' '[:upper:]') in
            *TOKEN*|*KEY*|*SECRET*|*PASS*) value='***' ;;
        esac
        printf '  %s=%s\n' "$name" "$value"
    done
    for v in $notes; do
        echo "clean-sandbox: --keep $v: not set in the caller, not passed"
    done
} >&2

exec env -i "${envargs[@]}" "$@"
