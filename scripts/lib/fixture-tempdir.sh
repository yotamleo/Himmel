#!/usr/bin/env bash
# Shared guards for shell-test fixtures that create and enter temporary git repos.

fixture_mktemp_dir() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/himmel-fixture.XXXXXX") || {
        echo "FAIL: fixture mktemp -d failed" >&2
        return 1
    }
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "FAIL: fixture mktemp -d returned no directory" >&2
        return 1
    fi
    # A genuinely fresh mktemp -d result is always empty. Rejecting a
    # non-empty result closes the gap the git-repo check alone misses: a
    # broken or PATH-shadowed mktemp (this guard's own threat model, see the
    # no-rm-rf note below) could return an existing, non-empty, non-git
    # directory, which the git-dir check would wave through as safe.
    if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        echo "FAIL: fixture temp directory is not empty" >&2
        return 1
    fi
    # --git-dir (not --show-toplevel) so this also rejects a BARE repository
    # or a location already inside a .git directory: --show-toplevel fails
    # (rc!=0) in both of those, which would let them slip through as
    # "not a git context" and reach callers that `git init` on top of them
    # (HIMMEL-1673 CR round 5).
    if (cd "$dir" && git rev-parse --git-dir >/dev/null 2>&1); then
        # Deliberately do NOT rm -rf "$dir" here: a broken or PATH-shadowed
        # mktemp (the exact threat model this guard defends against) could
        # return an existing, non-empty directory rather than a genuinely
        # fresh one. Removing it on the strength of "mktemp said this path"
        # would turn a safe fail-closed rejection into a destructive delete
        # of whatever that path actually is. A leaked empty temp directory
        # on this narrow guard-reject path is an acceptable tradeoff against
        # that risk.
        echo "FAIL: fixture temp directory is inside an existing git repository" >&2
        return 1
    fi
    printf '%s\n' "$dir"
}

fixture_enter_git_init_dir() {
    local dir="${1-}" existing_root
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        echo "FAIL: fixture temp directory is empty or missing; refusing to run in cwd" >&2
        return 1
    fi
    cd "$dir" || {
        echo "FAIL: cannot enter fixture temp directory: $dir" >&2
        return 1
    }
    # Same non-empty rejection as fixture_mktemp_dir: a directory this
    # function is trusted to `git init` into should always be one the
    # caller just created (mktemp/mkdir), never pre-existing content.
    if [ -n "$(ls -A . 2>/dev/null)" ]; then
        echo "FAIL: fixture temp directory is not empty: $dir" >&2
        return 1
    fi
    # --git-dir (not --show-toplevel), same reasoning as fixture_mktemp_dir
    # above: --show-toplevel fails inside a bare repository or a .git
    # directory, which would let either slip past this guard.
    if existing_root=$(git rev-parse --git-dir 2>/dev/null); then
        echo "FAIL: fixture temp directory is inside an existing git repository: $existing_root" >&2
        return 1
    fi
}
