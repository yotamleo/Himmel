#!/usr/bin/env bash
# normalize-worktree-acl.sh - Windows-only wrapper for normalize-worktree-acl.ps1.
# Non-Windows platforms do not have the Codex Windows sandbox ACL failure mode, so
# this wrapper exits 0 without side effects there.
set -u

case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) exit 0 ;;
esac

if [ "$#" -ne 1 ]; then
    echo "usage: normalize-worktree-acl.sh <worktree-path>" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
ps1="$script_dir/normalize-worktree-acl.ps1"

# shellcheck source=/dev/null
. "$script_dir/../lib/resolve-powershell.sh"

if ps_bin=$(resolve_powershell); then
    exec "$ps_bin" -NoProfile -ExecutionPolicy Bypass -File "$ps1" "$1"
fi

echo "normalize-worktree-acl.sh: PowerShell not found" >&2
exit 1
