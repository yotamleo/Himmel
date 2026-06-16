#!/usr/bin/env bash
# Resolver for the project's handover directory.
#
# Source this file and call `handover_root` (pure) or
# `handover_root_ensure` (creates inline dir on demand).
#
# Resolution order:
#   1. $HANDOVER_DIR — explicit override. Must resolve to an existing
#      directory; otherwise the resolver fails-closed (rc=2) rather than
#      silently falling back, so a typo or unmounted external repo gets
#      caught immediately instead of writing to the wrong location.
#   2. <repo-root>/handovers — inline default. Used when HANDOVER_DIR is
#      unset.
#
# Mode names (used by diagnostics):
#   A — inline:   HANDOVER_DIR unset, content under <repo>/handovers
#   B — external: HANDOVER_DIR set, content under that path
#
# Return codes:
#   0 — printed an absolute path to stdout
#   2 — HANDOVER_DIR was set but did not resolve to a directory, OR
#       Mode A inline path does not yet exist (use _ensure to create)

# handover_root — PURE resolver.
# Mode B: validates $HANDOVER_DIR exists, prints it.
# Mode A: prints <repo>/handovers ONLY if the dir already exists. Returns
# rc=2 + diagnostic if missing — caller must use handover_root_ensure to
# create. Pure reads (status/doctor) never mutate the filesystem.
handover_root() {
    if [ -n "${HANDOVER_DIR:-}" ]; then
        if [ -d "$HANDOVER_DIR" ]; then
            ( cd "$HANDOVER_DIR" && pwd )
            return 0
        fi
        echo "handover-path: HANDOVER_DIR='$HANDOVER_DIR' is not a directory" >&2
        return 2
    fi

    local repo_root
    if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "handover-path: not inside a git repository and HANDOVER_DIR is unset" >&2
        return 2
    fi

    local inline="$repo_root/handovers"
    if [ ! -d "$inline" ]; then
        echo "handover-path: inline default '$inline' does not exist (call handover_root_ensure to create)" >&2
        return 2
    fi
    ( cd "$inline" && pwd )
}

# handover_root_ensure — like handover_root but creates the Mode A inline
# dir if missing. Use during bootstrap (setup.sh) or before a guaranteed
# write op. Side-effecting on purpose.
handover_root_ensure() {
    if [ -z "${HANDOVER_DIR:-}" ]; then
        local repo_root
        if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
            echo "handover-path: not inside a git repository and HANDOVER_DIR is unset" >&2
            return 2
        fi
        mkdir -p "$repo_root/handovers"
    fi
    handover_root
}

handover_mode() {
    if [ -n "${HANDOVER_DIR:-}" ]; then
        echo "B"
    else
        echo "A"
    fi
}
