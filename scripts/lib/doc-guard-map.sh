#!/usr/bin/env bash
# scripts/lib/doc-guard-map.sh — shared 4-col doc-guard map loader (HIMMEL-587).
#
# Map format: 4-col TSV  strength<TAB>trigger<TAB>path-regex<TAB>required-doc
#   strength ∈ {block, advise}   trigger ∈ {add, modify}
# `block` rows are consumed by check-doc-guard.sh (filtered block+add).
# `advise` rows are consumed by scripts/lib/doc-freshness.sh.
#
# dgm_rows <map-file> <strength> [<trigger>]
#   Emits "<path-regex>\t<required-doc>" for each matching non-comment/non-blank
#   row. When <trigger> is empty/omitted, matches any trigger. Does NOT apply
#   doc-presence inertness — the caller applies its own `[ -f "$doc" ]` check
#   against its own root context. bash 3.2-safe (while-read, no assoc arrays).
dgm_rows() {
    local map="$1" want_strength="$2" want_trigger="${3:-}"
    local strength trigger re doc
    while IFS=$'\t' read -r strength trigger re doc; do
        case "$strength" in ''|\#*) continue;; esac
        if [ -z "$re" ] || [ -z "$doc" ]; then continue; fi
        [ "$strength" = "$want_strength" ] || continue
        if [ -n "$want_trigger" ] && [ "$trigger" != "$want_trigger" ]; then
            continue
        fi
        printf '%s\t%s\n' "$re" "$doc"
    done < "$map"
}
