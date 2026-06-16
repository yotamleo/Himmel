#!/usr/bin/env bash
# Resolver for the project's handover directory.
#
# Source this file and call `handover_root` (PURE, no fs mutation) or
# `handover_root_ensure` (creates the Mode A inline dir on demand).
#
# Resolution order:
#   1. $HANDOVER_DIR — explicit override. Must resolve to an existing
#      directory; otherwise the resolver fails-closed (rc=2) rather than
#      silently falling back, so a typo or unmounted external repo gets
#      caught immediately instead of writing to the wrong location.
#   2. <repo-root>/handovers — inline default. Used when HANDOVER_DIR is
#      unset.
#
# Mode names (used by /handover-link diagnostics):
#   A — inline:   HANDOVER_DIR unset, content under <repo>/handovers
#   B — external: HANDOVER_DIR set, content under that path
#
# Return codes:
#   0 — printed an absolute path to stdout
#   2 — HANDOVER_DIR was set but did not resolve to a directory, OR
#       Mode A inline path does not yet exist (pure `handover_root` only —
#       use `handover_root_ensure` if you need the dir created)
#
# Pure / side-effecting split (HIMMEL-150 — back-port from luna-brain):
#   - `handover_root` is now PURE — never mkdirs. Status/doctor/read-only
#     callers cannot trigger filesystem mutation as a side effect of a
#     read. Returns rc=2 with diagnostic when the Mode A inline dir is
#     missing.
#   - `handover_root_ensure` mkdirs the Mode A inline dir if missing, then
#     delegates to `handover_root`. Direct callers in himmel:
#     `scripts/handover/auto-commit.sh`,
#     `scripts/overnight/morning-report.sh` and
#     `scripts/handover/generate-morning-briefing.sh` — write-op sites that
#     legitimately need the dir to exist. (setup.sh + flush.sh do NOT call
#     _ensure directly: setup.sh shells out to handover-link.sh doctor
#     which uses pure; flush.sh refuses Mode A explicitly and only runs
#     in Mode B where pure and _ensure behave identically.)
#
# Post-HIMMEL-124 deployment guidance:
#   All personal handover state has been centralized in the yotam_docs
#   repo (see yotam_docs/README.md). The inline default (Mode A) in this
#   resolver still works for any script that lives in himmel, but it
#   now points at a near-empty himmel/handovers/ — only the README stub
#   that points at yotam_docs remains there. To get the migrated
#   content, set HANDOVER_DIR to yotam_docs/handovers in the shell that
#   launches Claude:
#
#       export HANDOVER_DIR="$HOME/Documents/github/yotam_docs/handovers"
#
#   HIMMEL-129 (done 2026-05-25) shipped the bucket-layout layer that
#   splits <state-root>/ into per-repo subfolders
#   (`cross/`, `himmel/`, `luna/`, `luna_brain/`). The v2 handover skill
#   auto-detects the layer when any bucket dir exists. This resolver
#   stays single-root; the bucket layer is applied by callers (skill +
#   handover/*.sh) on top of the resolved root.

# PURE resolver. No filesystem mutation. Returns rc=2 if Mode A inline
# dir doesn't yet exist — callers that legitimately need the dir
# created (bootstrap, write ops) should use `handover_root_ensure`.
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

# Side-effecting variant. mkdirs the Mode A inline dir if missing, then
# delegates to handover_root. No-op in Mode B (HANDOVER_DIR set).
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
