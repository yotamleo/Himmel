#!/usr/bin/env bash
# set-env-var.sh — idempotently set KEY=VALUE in a .env file (HIMMEL-758).
#
# Generic sibling of set-handover-dir.sh's own create-or-update upsert logic
# (that script stays HANDOVER_DIR-specific and untouched) — extracted as a
# reusable primitive so `himmelctl config set` never hand-rolls its own
# .env mutation. Idempotent (re-running with the same value reaches the same
# end-state), atomic (temp file + mv), non-destructive (every other line
# preserved, file order preserved for an updated key).
#
# Usage:
#   set-env-var.sh <KEY> <VALUE> [--env-file <path>]
#
#   <KEY>            [A-Za-z_][A-Za-z0-9_]* — a shell-safe env var name.
#   <VALUE>          May be empty (an explicit "unset this leg set" write is a
#                     legitimate end-state, not an error).
#   --env-file <p>   Target .env (default: <primary-checkout-root>/.env).
#
# Exit codes:
#   0  written (or already correct)
#   1  usage / input error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY=""
VALUE=""
VALUE_SET=0
ENV_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)   ENV_FILE="${2:-}"; shift 2 ;;
        --env-file=*) ENV_FILE="${1#--env-file=}"; shift ;;
        -*)           echo "ERR set-env-var: unknown flag: $1" >&2; exit 1 ;;
        *)
            if [ -z "$KEY" ]; then KEY="$1"; shift
            elif [ "$VALUE_SET" -eq 0 ]; then VALUE="$1"; VALUE_SET=1; shift
            else echo "ERR set-env-var: unexpected arg: $1" >&2; exit 1; fi
            ;;
    esac
done

if [ -z "$KEY" ] || [ "$VALUE_SET" -eq 0 ]; then
    echo "Usage: set-env-var.sh <KEY> <VALUE> [--env-file <path>]" >&2
    exit 1
fi

case "$KEY" in
    [A-Za-z_]*) ;;
    *) echo "ERR set-env-var: KEY must start with a letter or underscore: $KEY" >&2; exit 1 ;;
esac
case "$KEY" in
    *[!A-Za-z0-9_]*) echo "ERR set-env-var: KEY must be [A-Za-z_][A-Za-z0-9_]*: $KEY" >&2; exit 1 ;;
esac

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
    echo "ERR set-env-var: target is not a regular file: $ENV_FILE" >&2
    exit 1
fi

new_line="$KEY=$VALUE"

if grep -qE "^[[:space:]]*${KEY}=" "$ENV_FILE"; then
    # Create the replacement via mktemp in the SAME dir (not a predictable
    # "$ENV_FILE.tmp.$$" — that name permits a symlink race, and a `>`
    # redirect would create it under the current umask, silently broadening a
    # 0600 .env to 0644 after the mv). mktemp yields a 0600 file with an
    # unpredictable name; we then copy the ORIGINAL .env's mode onto it so the
    # upsert preserves (never widens) the file's permissions.
    tmp=$(mktemp "$ENV_FILE.XXXXXX") || { echo "ERR set-env-var: mktemp failed for $ENV_FILE" >&2; exit 1; }
    trap 'rm -f "$tmp"' EXIT
    perm=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo '')
    if [ -n "$perm" ]; then chmod "$perm" "$tmp" 2>/dev/null || true; fi
    # Replace the FIRST matching assignment and DROP every later duplicate, so
    # exactly one assignment of KEY remains. Otherwise a stale later line would
    # win when the file is sourced, and the command would report success
    # without changing the effective value.
    awk -v repl="$new_line" -v key="$KEY" '
        $0 ~ "^[[:space:]]*" key "=" { if (!done) { print repl; done=1 } ; next }
        { print }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
    trap - EXIT
    echo "OK set-env-var: updated $KEY in $ENV_FILE"
else
    printf '%s\n' "$new_line" >> "$ENV_FILE"
    echo "OK set-env-var: appended $KEY to $ENV_FILE"
fi
