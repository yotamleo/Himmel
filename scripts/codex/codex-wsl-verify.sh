#!/usr/bin/env bash
# scripts/codex/codex-wsl-verify.sh - in-distro clone verification for the
# codex WSL lane (HIMMEL-999 B2.3). Shipped across the boundary by
# dispatch-codex-wsl.sh via `bash -s -- <clone> [root]` so the SAME file is
# locally unit-testable (test-dispatch-codex-wsl.sh runs it directly).
#
# Args: $1 = clone path (absolute), $2 = containment root (optional;
#       defaults to $HOME/work resolved HERE, i.e. in-distro).
# Prints the physical path on success.
# Exit: 0 ok | 3 cd/pwd failure | 4 containment violation | 5 not a git work tree
set -u
clone="${1:?usage: codex-wsl-verify.sh <clone> [root]}"
root="${2:-}"
[ -n "$root" ] || root="$HOME/work"
# Resolve the root PHYSICALLY too - p is symlink-resolved (pwd -P), so a
# symlinked component in root (macOS /var->/private/var, a linked $HOME)
# would otherwise never prefix-match p.
root="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "cannot resolve clone root: ${2:-\$HOME/work}" >&2; exit 3; }
cd "$clone" 2>/dev/null || { echo "cannot cd into clone: $clone" >&2; exit 3; }
p="$(pwd -P)" || { echo "cannot resolve physical path for: $clone" >&2; exit 3; }
case "$p" in
    /mnt/*) echo "physical path under /mnt: $p" >&2; exit 4 ;;
    "$root"/*) ;;
    *) echo "physical path $p outside clone root $root" >&2; exit 4 ;;
esac
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || { echo "not a git work tree: $p" >&2; exit 5; }
printf '%s\n' "$p"
