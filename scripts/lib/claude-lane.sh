#!/usr/bin/env bash
# claude-lane.sh — HIMMEL-4082 lane seam for headless `claude` spawn sites.
# Source it, then: claude_lane_resolve <repo-root>
# Sets CLAUDE_LANE_CMD (array) to the command a site execs in place of `claude`:
#   HIMMEL_CLAUDE_LANE unset / empty / native -> claude            (today's argv, unchanged)
#   openrouter                                -> <repo>/scripts/claude-openrouter
#   claudex                                   -> <repo>/scripts/claude-codex
# Anything else refuses (rc 2) — never a silent fallback to native. The lane
# launchers exec `claude "$@"`, so a site keeps its own flags, permission mode
# and --output-format json parsing. Each launcher consults the egress matrix
# itself; a site must still only opt in where the data it sends is allowed.
# bash 3.2-safe.
# shellcheck disable=SC2034  # CLAUDE_LANE_CMD is read by the sourcing site
claude_lane_resolve() {
  local root="${1:?claude_lane_resolve: repo root required}"
  case "${HIMMEL_CLAUDE_LANE:-native}" in
    native)     CLAUDE_LANE_CMD=(claude) ;;
    openrouter) CLAUDE_LANE_CMD=("$root/scripts/claude-openrouter") ;;
    claudex)    CLAUDE_LANE_CMD=("$root/scripts/claude-codex") ;;
    *)
      echo "claude-lane: unknown HIMMEL_CLAUDE_LANE='${HIMMEL_CLAUDE_LANE}' (valid: native, openrouter, claudex) - refusing, no fallback" >&2
      return 2 ;;
  esac
}
