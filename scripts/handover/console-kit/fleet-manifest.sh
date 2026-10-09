#!/usr/bin/env bash
# fleet-manifest.sh — HIMMEL-3748. The one writer for a console's fleet
# manifest: the JSON file `tick.sh --legs-from` (and so console-wait.sh) reads
# on every sample, so a dispatch or a wrap edits one file instead of the console
# restarting its waiter with a new 10-15 path --legs argv.
#
#   fleet-manifest.sh add    <manifest> <leg doc>... [--lane <lane>] [--lockless]
#   fleet-manifest.sh remove <manifest> <leg doc | label>...
#   fleet-manifest.sh list   <manifest>                      one doc per line
#
# Location: next to the console doc, named after it —
# <console doc stem>.fleet.json.
#
# Schema 1:
#   {"schema": 1,
#    "legs": [{"doc": "<absolute leg doc>", "label": "N<k>", "added": "<ISO-8601>"}]}
# HIMMEL-5074: add also stores `lane` (native|claudex|deepseek|api|...; a missing
# --lane is stored `unknown`, never guessed) and, with --lockless, `lockless: true`
# (an eval/pilot row that holds no queue lock: tick reports NOLOCK and judges it by
# tail marker only). A manifest written before this carries neither key and reads
# as lane `unknown`, not lockless. A doc already listed is left alone, flags and all.
# Only `legs[].doc` drives tick; label (leg-identity.sh's N<k>) is what remove
# matches and what a human reads. Any other key, top-level or per leg, is
# carried through every rewrite untouched, so HIMMEL-1873's wider leg manifest
# (chains, lanes, write-sets) can grow in the same object.
#
# add is idempotent (a doc already listed is left alone); removing a leg that is
# not listed is not an error. A doc must be absolute: tick resolves a relative
# one against the handover root, the writer's cwd would be a different one. It
# must also carry no whitespace or glob character, which tick's word-split leg
# list cannot hold.
#
# Writes hold an exclusive flock on <manifest>.lock and replace the file with a
# temp file renamed into place in the same directory (the inbox-send.sh
# pattern), so two dispatches at once lose no entry and a reader never sees a
# torn file. An existing manifest that is not valid schema-1 JSON is refused,
# never overwritten.
#
# Exit: 0 ok; 1 missing/invalid manifest, lock or write failure; 2 usage.
#
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only
# (util-linux flock). bash 3.2-safe; needs jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/leg-identity.sh
. "$HERE/../../lib/leg-identity.sh"

usage() {
    cat <<'USAGE'
usage: fleet-manifest.sh add    <manifest> <leg doc>... [--lane <lane>] [--lockless]
       fleet-manifest.sh remove <manifest> <leg doc | label>...
       fleet-manifest.sh list   <manifest>
USAGE
}

# Every leg's doc is an absolute path with no whitespace or glob character:
# tick word-splits its leg list, so anything else would silently shrink the
# fleet it judges. Run with `jq -s`: the file must hold exactly one top-level
# value (HIMMEL-3981) — jq reads a stream, so two concatenated objects would
# otherwise pass per value and list/add would act on a multi-object file.
VALID='length == 1 and (.[0] | type == "object" and .schema == 1 and (.legs | type == "array")
    and all(.legs[]; type == "object" and (.doc | type == "string" and test("^/[^[:space:]*?\\[]+$"))))'

[ "$#" -ge 2 ] || { usage >&2; exit 2; }
verb="$1"; manifest="$2"; shift 2

case "$verb" in
    list)
        [ "$#" -eq 0 ] || { usage >&2; exit 2; }
        if ! jq -e -s "$VALID" "$manifest" >/dev/null 2>&1; then
            echo "fleet-manifest: not a schema-1 fleet manifest: $manifest" >&2
            exit 1
        fi
        jq -r '.legs[].doc' "$manifest"
        exit $?
        ;;
    add|remove) [ "$#" -ge 1 ] || { usage >&2; exit 2; } ;;
    *) usage >&2; exit 2 ;;
esac

lane=unknown; lockless=false
if [ "$verb" = add ]; then
    # --lane/--lockless may sit anywhere among the docs; the docs are re-collected
    # one per line so a doc with whitespace is refused below, not word-split.
    docs_only=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --lane)
                [ "$#" -ge 2 ] || { usage >&2; exit 2; }
                case "$2" in
                    ''|[!a-z0-9]*|*[!a-z0-9._-]*) echo "fleet-manifest: --lane must be a lowercase word (native, claudex, deepseek, api, ...): $2" >&2; exit 2 ;;
                esac
                lane="$2"; shift 2 ;;
            --lockless) lockless=true; shift ;;
            *) docs_only="$docs_only$1"$'\n'; shift ;;
        esac
    done
    set --
    while IFS= read -r d; do [ -z "$d" ] || set -- "$@" "$d"; done <<EOD
$docs_only
EOD
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    for doc in "$@"; do
        case "$doc" in
            /*) ;;
            *) echo "fleet-manifest: leg doc must be an absolute path: $doc" >&2; exit 2 ;;
        esac
        case "$doc" in
            *[[:space:]]*|*'*'*|*'?'*|*'['*)
                echo "fleet-manifest: leg doc must not contain whitespace or a glob character (tick word-splits it): $doc" >&2
                exit 2 ;;
        esac
    done
fi

if ! exec 9>>"$manifest.lock" || ! flock -x -w 30 9; then  # gnu-ok: Linux-only kit (util-linux flock, PLATFORM GUARD)
    echo "fleet-manifest: cannot lock $manifest.lock" >&2
    exit 1
fi

if [ -e "$manifest" ]; then
    if ! jq -e -s "$VALID" "$manifest" >/dev/null 2>&1; then
        echo "fleet-manifest: refusing to rewrite an invalid manifest: $manifest" >&2
        exit 1
    fi
    cur="$(cat "$manifest")" || exit 1
else
    cur='{"schema":1,"legs":[]}'
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for arg in "$@"; do
    if [ "$verb" = add ]; then
        label="$(leg_label "$arg")"
        cur="$(printf '%s\n' "$cur" | jq --arg d "$arg" --arg l "$label" --arg t "$now" --arg ln "$lane" --argjson ll "$lockless" \
            'if any(.legs[]; .doc == $d) then . else .legs += [{doc: $d, label: $l, added: $t, lane: $ln} + (if $ll then {lockless: true} else {} end)] end')" || exit 1
    else
        cur="$(printf '%s\n' "$cur" | jq --arg a "$arg" \
            '.legs |= map(select(.doc != $a and .label != $a))')" || exit 1
    fi
done

tmp="$(mktemp "$manifest.XXXXXX")" || { echo "fleet-manifest: cannot create a temp file next to $manifest" >&2; exit 1; }
if ! printf '%s\n' "$cur" > "$tmp" || ! mv -f "$tmp" "$manifest"; then
    rm -f "$tmp"
    echo "fleet-manifest: cannot write $manifest" >&2
    exit 1
fi
