#!/usr/bin/env bash
# Sourceable cadence observability-registry merge helper (HIMMEL-1680).
# Registration is bookkeeping: every failure warns and returns success so an
# otherwise-good scheduler arm/disarm is never blocked by monitoring state.

observability_registry_path() {
    if [ -n "${HIMMEL_OBSERVABILITY_CONFIG:-}" ]; then
        printf '%s\n' "$HIMMEL_OBSERVABILITY_CONFIG"
        return 0
    fi
    local home="${HOME:-}"
    printf '%s/.himmel/observability.json\n' "$home"
}

_observability_registry_warn() {
    printf 'WARN observability-registry: %s\n' "$1" >&2
}

# mkdir-based mutex around the read-modify-write below (codex-2, HIMMEL-1680
# CR): two concurrent arms (e.g. codex-sweep + graphmap racing at boot)
# without this could both read the same generation and one's merge would
# clobber the other's. mkdir is atomic; ~2s of retries then gives up and
# proceeds UNLOCKED rather than blocking an otherwise-good arm/disarm
# forever -- registration stays best-effort by contract, a lost race here
# just means a retry (the next arm/disarm) merges cleanly.
_observability_registry_lock() {
    local lockdir="$1.lock" tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -ge 20 ] && return 1
        sleep 0.1
    done
    return 0
}

_observability_registry_unlock() {
    rmdir "$1.lock" 2>/dev/null || true
}

# _observability_registry_update_body <action> <flow> <cadence> <task>
# <registry> <registry_dir> -- does the actual read-merge-write. Split out
# from _observability_registry_update (codex-1, CR round 2 fix-of-a-fix): a
# bash RETURN trap is NOT scoped to one call -- it stays installed after this
# function returns and fires on every LATER function return anywhere in the
# process, referencing a $registry local that no longer exists (observed:
# "registry: unbound variable" on the very next call). A single call site
# with ONE unlock right after it, instead of a trap or per-branch
# annotations, sidesteps that trap-lifetime foot-gun entirely.
_observability_registry_update_body() {
    local action="$1" flow="$2" cadence="$3" task="$4" registry="$5" registry_dir="$6"
    local input tmp

    input="$registry"
    if [ ! -f "$input" ]; then
        # codex-2 (CR round 2): `|| input=""` keeps a failing mktemp from
        # tripping a caller's `set -e` -- without it the whole assignment
        # statement's nonzero exit would abort the caller's shell instead of
        # reaching this warn-and-return-0 path.
        input=$(mktemp "$registry_dir/.observability-empty.XXXXXX") || input=""
        if [ -z "$input" ]; then
            _observability_registry_warn "could not create initial registry input"
            return 0
        fi
        printf '{}\n' > "$input"
    fi

    tmp=$(mktemp "$registry_dir/.observability.json.XXXXXX") || tmp=""
    if [ -z "$tmp" ]; then
        [ "$input" = "$registry" ] || rm -f "$input"
        _observability_registry_warn "could not create registry temp file"
        return 0
    fi

    if [ "$action" = "register" ]; then
        if ! jq --arg flow "$flow" --argjson cadence "$cadence" --arg task "$task" '
            .flows = ((.flows // []) as $flows
                | if any($flows[]?; .name == $flow)
                  then $flows | map(if .name == $flow then .cadence_seconds = $cadence else . end)
                  else $flows + [{name: $flow, cadence_seconds: $cadence}]
                  end)
            | .expected_tasks = ((.expected_tasks // []) + [$task] | unique)
        ' "$input" > "$tmp"; then
            rm -f "$tmp"
            [ "$input" = "$registry" ] || rm -f "$input"
            _observability_registry_warn "could not merge cadence '$flow' into $registry"
            return 0
        fi
    else
        if ! jq --arg flow "$flow" --arg task "$task" '
            .flows = [(.flows // [])[] | select(.name != $flow)]
            | .expected_tasks = [(.expected_tasks // [])[] | select(. != $task)]
        ' "$input" > "$tmp"; then
            rm -f "$tmp"
            [ "$input" = "$registry" ] || rm -f "$input"
            _observability_registry_warn "could not remove cadence '$flow' from $registry"
            return 0
        fi
    fi

    [ "$input" = "$registry" ] || rm -f "$input"
    if [ -f "$registry" ] && cmp -s "$tmp" "$registry"; then
        rm -f "$tmp"
        return 0
    fi
    if ! mv -f "$tmp" "$registry"; then
        rm -f "$tmp"
        _observability_registry_warn "could not publish registry update to $registry"
    fi
    return 0
}

_observability_registry_update() {
    local action="$1" flow="$2" cadence="$3" task="$4"
    local registry registry_dir locked=0 rc

    command -v jq >/dev/null 2>&1 || {
        _observability_registry_warn "jq not on PATH; cadence registration unchanged"
        return 0
    }

    registry=$(observability_registry_path)
    registry_dir=$(dirname "$registry")
    if ! mkdir -p "$registry_dir"; then
        _observability_registry_warn "could not create registry directory: $registry_dir"
        return 0
    fi

    if _observability_registry_lock "$registry"; then
        locked=1
    else
        _observability_registry_warn "could not lock $registry (held >2s) -- proceeding unlocked, a concurrent writer could race"
    fi

    rc=0
    _observability_registry_update_body "$action" "$flow" "$cadence" "$task" "$registry" "$registry_dir" || rc=$?
    [ "$locked" -eq 1 ] && _observability_registry_unlock "$registry"
    return "$rc"
}

observability_register_cadence() {
    _observability_registry_update register "$1" "$2" "$3"
}

observability_unregister_cadence() {
    _observability_registry_update unregister "$1" 0 "$2"
}
