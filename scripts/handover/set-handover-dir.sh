#!/usr/bin/env bash
# set-handover-dir.sh — idempotently set HANDOVER_DIR in the repo .env (HIMMEL-335).
#
# Writes (create-or-update) the `HANDOVER_DIR=<path>` line in the primary
# checkout's .env so the handover shell tooling (via scripts/lib/load-dotenv.sh)
# and the handover skill resolve state from one configured location instead of
# a hardcoded path. This is the auto-write step behind `/handover-setup`.
#
# Usage:
#   set-handover-dir.sh <handover-dir> [--env-file <path>]
#
#   <handover-dir>   Absolute path to the handover state root (Mode B). Must be
#                    an existing directory (fail-closed — matches the resolver
#                    in scripts/lib/handover-path.sh).
#   --env-file <p>   Target .env (default: <primary-checkout-root>/.env).
#
# Idempotent: re-running with the same value reaches the same end-state (the
# line is rewritten to the same value); a new value replaces the existing line
# in place (file order preserved). Commented example lines (`# HANDOVER_DIR=...`)
# are left untouched — an active line is appended.
#
# Exit codes:
#   0  written (or already correct)
#   1  usage / input error
#   2  handover dir does not exist
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HDIR=""
ENV_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)   ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*) ENV_FILE="${1#--env-file=}"; shift ;;
        -*)           echo "ERR set-handover-dir: unknown flag: $1" >&2; exit 1 ;;
        *)
            if [ -z "$HDIR" ]; then HDIR="$1"; shift
            else echo "ERR set-handover-dir: unexpected arg: $1" >&2; exit 1; fi
            ;;
    esac
done

if [ -z "$HDIR" ]; then
    echo "Usage: set-handover-dir.sh <handover-dir> [--env-file <path>]" >&2
    exit 1
fi

if [ ! -d "$HDIR" ]; then
    echo "ERR set-handover-dir: handover dir does not exist: $HDIR" >&2
    echo "    Create it first (e.g. a 'handovers' dir in your state repo), then re-run." >&2
    exit 2
fi

# Canonicalize (absolute, forward slashes — some Windows bash builds emit
# backslashes from pwd; normalize so the stored value is shell-safe).
# shellcheck disable=SC1003  # '\\' is a literal backslash for tr, not a quote escape
HDIR="$(cd "$HDIR" && pwd | tr '\\' '/')"

# Resolve the target .env: explicit --env-file, else the primary checkout root
# (parent of git-common-dir — finds the real .env from inside a worktree too).
if [ -z "$ENV_FILE" ]; then
    if common=$(git rev-parse --git-common-dir 2>/dev/null); then
        ENV_FILE="$(cd "$common/.." && pwd)/.env"
    else
        ENV_FILE="$SCRIPT_DIR/../../.env"
    fi
fi

if [ ! -e "$ENV_FILE" ]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    : > "$ENV_FILE"
elif [ ! -f "$ENV_FILE" ]; then
    # Exists but is a directory / symlink-to-dir / device — refuse rather than
    # clobber or write into something unexpected.
    echo "ERR set-handover-dir: target is not a regular file: $ENV_FILE" >&2
    exit 1
fi

new_line="HANDOVER_DIR=$HDIR"

if grep -qE '^[[:space:]]*HANDOVER_DIR=' "$ENV_FILE"; then
    tmp="$ENV_FILE.tmp.$$"
    awk -v repl="$new_line" '
        !done && /^[[:space:]]*HANDOVER_DIR=/ { print repl; done=1; next }
        { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
    echo "OK set-handover-dir: updated HANDOVER_DIR in $ENV_FILE"
else
    printf '%s\n' "$new_line" >> "$ENV_FILE"
    echo "OK set-handover-dir: appended HANDOVER_DIR to $ENV_FILE"
fi
