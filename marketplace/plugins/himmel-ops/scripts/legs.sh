#!/usr/bin/env bash
# legs.sh — TRANSPORT ONLY (HIMMEL-444). Locates the himmel checkout and
# re-execs the single-source leg resolver (scripts/lib/initiative-legs.sh), so
# the leg `case` lives in exactly one place. This wrapper holds ZERO leg logic.
#
# minerva (a plugin) cannot relative-path to the himmel checkout when installed
# outside it, so we resolve the repo by, in order: $HIMMEL_REPO override → the
# git toplevel of the current dir (himmel-dev sessions run with cwd in the
# checkout) → the git toplevel of this wrapper's own dir (plugin loaded from the
# repo's marketplace/). If none yields the resolver, fail open (empty, exit 0) —
# minerva then keeps its prose hand-off, never erroring on a missing resolver.
set -u

_find_repo() {
  local cand
  if [ -n "${HIMMEL_REPO:-}" ] && [ -f "${HIMMEL_REPO}/scripts/lib/initiative-legs.sh" ]; then
    printf '%s' "$HIMMEL_REPO"; return 0
  fi
  cand="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cand" ] && [ -f "$cand/scripts/lib/initiative-legs.sh" ]; then
    printf '%s' "$cand"; return 0
  fi
  cand="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cand" ] && [ -f "$cand/scripts/lib/initiative-legs.sh" ]; then
    printf '%s' "$cand"; return 0
  fi
  return 1
}

repo="$(_find_repo)" || { printf ''; exit 0; }   # fail-open: no reachable resolver
# shellcheck source=/dev/null
. "$repo/scripts/lib/initiative-legs.sh"
resolve_legs "${HIMMEL_INITIATIVE:-}" "${HIMMEL_INITIATIVE_OVERNIGHT:-}" "${HIMMEL_OVERNIGHT:-}"
