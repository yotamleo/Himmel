#!/usr/bin/env bash
# Prune merged-PR / [gone] worktrees. Companion to scripts/worktree.sh.
#
# Thin wrapper over clean-garden.sh in --prune-only mode so the slash
# command surface (`/clean`, `/worktree`, `/clean_garden`) maps 1:1 to
# scripts and the orchestrator (`clean-garden.sh`) stays the single
# source of truth for prune logic.
#
# Forwards all args (--dry-run, --verbose). --no-install has no effect
# in prune-only mode (silently ignored — create phase is skipped before
# install runs); --no-prune is rejected by the orchestrator as
# mutually exclusive with --prune-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/clean-garden.sh" --prune-only "$@"
