#!/usr/bin/env bash
# scripts/lib/doc-freshness.sh — advisory doc/llms.txt freshness detector (HIMMEL-587).
#
# ADVISORY ONLY. Always exits 0 — never blocks. The sole blocking gate is
# scripts/hooks/check-doc-guard.sh. Emits "advise" findings for docs whose
# mapped source changed in a commit range without the doc itself being updated.
#
# Double-filtered for signal: changelog scoping (only files touched by a
# feat/fix commit in range) + doc-presence suppression (skip when the doc
# itself changed in range). Project-relative — map + doc targets resolve from
# the host repo root, so adopters check THEIR docs against THEIR code.
#
# SAFE UNDER `set -e`: the consumers (inject-doc-freshness.sh,
# generate-morning-briefing.sh) source this under `set -euo pipefail`, so every
# command-substitution whose pipeline can legitimately match nothing is guarded
# with `|| true`/`|| x=""` — otherwise pipefail would abort the loop mid-way and
# silently drop later rows (critic #1).
#
# Library API:
#   df_leg_active <advise|session|morning>   rc 0 if that leg is on
#   df_detect <range> [<map>] [<root>]       prints findings, returns 0
# CLI:
#   bash scripts/lib/doc-freshness.sh <range>   prints findings, exits 0

# --- leg gate (HIMMEL_DOC_FRESHNESS; grammar mirrors HIMMEL_INITIATIVE) ------
_df_norm() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }
df_leg_active() {
    local want="$1" norm
    norm="$(_df_norm "${HIMMEL_DOC_FRESHNESS:-}")"
    case "$norm" in
        ''|0|false|off|no) return 1 ;;
        1|true|on|yes|all) return 0 ;;
    esac
    case ",$norm," in *",$want,"*) return 0 ;; esac
    return 1
}

# --- changelog scoping: files touched by a feat/fix commit in range ---------
# _df_inscope <root> <range> → newline list of in-scope changed files (sorted -u).
_df_inscope() {
    local root="$1" range="$2" h s
    {
        while IFS=$'\t' read -r h s; do
            [ -n "$h" ] || continue
            case "$(cc_classify "$s")" in
                feat|fix) git -C "$root" diff-tree --no-commit-id --name-only -r "$h" 2>/dev/null || true ;;
            esac
        done < <(git -C "$root" log --no-merges --format='%H%x09%s' "$range" 2>/dev/null || true)
    } | sort -u
}

# --- detector ---------------------------------------------------------------
df_detect() {
    local range="$1" map="${2:-}" root="${3:-}"
    [ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$root" ] || return 0
    [ -n "$map" ]  || map="$root/scripts/hooks/doc-guard-map.tsv"
    [ -f "$map" ]  || return 0     # no map → detector inert

    local _df_libdir
    _df_libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    . "$_df_libdir/doc-guard-map.sh"
    # shellcheck disable=SC1091
    . "$_df_libdir/commit-class.sh"

    local changed inscope
    changed="$(git -C "$root" diff --name-only "$range" 2>/dev/null || true)"
    inscope="$(_df_inscope "$root" "$range")" || inscope=""
    # Intersect: a file is in-scope iff it is BOTH changed in this range AND
    # touched by a feat/fix commit (critic F-B: in-scope ⊆ changed). This matters
    # for THREE-dot ranges (SessionStart origin/main...HEAD, /pr-check $db...HEAD):
    # `git log A...B` is the symmetric difference (can include main-side feat/fix
    # commits when the branch is behind main) while `git diff A...B` is merge-base
    # (branch-only). Without the intersection, main-side files would surface as
    # false-positive nudges — eroding goal #5 near-zero-FP (round-2 critic #3).
    if [ -n "$inscope" ] && [ -n "$changed" ]; then
        inscope="$(printf '%s\n' "$inscope" | grep -Fxf <(printf '%s\n' "$changed") 2>/dev/null)" || inscope=""
    else
        inscope=""
    fi

    local live_rows=0 re doc hit
    while IFS=$'\t' read -r re doc; do
        [ -n "$re" ] || continue
        [ -f "$root/$doc" ] || continue          # per-row inertness: target doc absent
        live_rows=$((live_rows + 1))
        # doc-presence suppression: doc itself changed in range → already updated.
        if printf '%s\n' "$changed" | grep -qxF "$doc"; then continue; fi
        # in-scope (feat/fix-touched) changed file matching this row's regex?
        # `|| hit=""` is load-bearing under set -e: a non-matching row must NOT
        # abort the loop and drop later rows (critic #1).
        hit="$(printf '%s\n' "$inscope" | grep -E "$re" | head -1)" || hit=""
        [ -n "$hit" ] || continue
        printf '%s\t%s\t%s\n' "$hit" "$doc" "source changed without updating doc"
    done < <(dgm_rows "$map" advise)

    if [ "$live_rows" -eq 0 ]; then
        echo "→ doc-freshness: map present but no live advise rows (targets missing?) — inert" >&2
    fi
    return 0
}

# CLI mode when executed directly.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    df_detect "${1:?usage: doc-freshness.sh <range>}"
fi
