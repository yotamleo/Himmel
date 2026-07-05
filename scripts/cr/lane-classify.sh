#!/usr/bin/env bash
# lane-classify — positive cheap-lane provenance classifier (HIMMEL-654 WS7,
# spec D1.1). A branch is a cheap lane IFF it carries a POSITIVE marker:
#   glm/*   → cheap-glm   (spawn-glm PR #843 names glm/<slug>; session meta corroborates)
#   codex/* → cheap-codex (hermes-Codex convention, adopted in harness-compat.md)
# Everything else → claude. Absence is never cheap-lane: an unmarked branch is
# indistinguishable from ordinary Claude work, so it takes the Claude chain
# (D1.1). A known-Codex branch not yet named codex/* is manually flagged cheap
# by the operator/validating session in the D1 verdict PR-body snippet.
# Branch-string-only by design (pure, no I/O): the spec's session-meta
# corroboration happens at the verdict/hook layer, which fails safe (no meta ⇒
# no verdict ⇒ no advance).
# bash 3.2-safe; no .ps1 twin (scripts/cr runs under Git Bash on Windows).
set -euo pipefail

lane_classify() {
  case "$1" in
    glm/*)   printf 'cheap-glm\n' ;;
    codex/*) printf 'cheap-codex\n' ;;
    *)       printf 'claude\n' ;;
  esac
}

# CLI form (not sourced): classify the arg and exit.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -eq 1 ] || { echo "usage: lane-classify.sh <branch>" >&2; exit 1; }
  lane_classify "$1"
fi
