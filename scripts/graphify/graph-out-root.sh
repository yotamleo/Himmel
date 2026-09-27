#!/usr/bin/env bash
# graph-out-root.sh — ONE resolver for "where does this corpus's promoted
# graphify-out/ live" (HIMMEL-3718). Sourced by every in-tree caller that
# invokes refresh-graph-map.sh for luna (graph-refresh.sh, graphmap-cadence.sh)
# so the out-of-corpus destination is a single fact, not N copies of a path.
#
# WHY out-of-corpus at all: luna's graphify-out/ (~21k files, mostly the
# per-file extraction cache/) sat inside the vault; Obsidian watches every
# vault file (gitignored ones included) and hung on the nightly refresh churn.
# himmel's OWN corpus is unaffected — its graphify-out/ is a tracked, shared
# artifact (HIMMEL-1123) and must stay in-corpus, so this resolver returns
# empty for it (empty = refresh-graph-map.sh's existing in-corpus default,
# unchanged).
#
# Usage: . graph-out-root.sh; out_root="$(graphify_out_root_for luna)"
# Empty stdout means "no override" — pass nothing (omit --out-root) to
# refresh-graph-map.sh in that case; do not pass an empty --out-root value.
graphify_out_root_for() {
  case "$1" in
    luna) printf '%s' "${GRAPHIFY_LUNA_OUT_ROOT:-$HOME/.local/share/himmel/graphify/luna}" ;;
    *) printf '' ;;
  esac
}
