#!/usr/bin/env bash
# live-state.sh — HIMMEL-3987. Renders a console doc's `## Live state` `legs:`
# entries from its fleet manifest (<console doc stem>.fleet.json,
# fleet-manifest.sh) instead of the console hand-editing them on every dispatch
# and wrap.
#
#   live-state.sh <console doc> [--print] [--nonce <label>=<nonce>]... [--pid <label>=<pid>]...
#
# An entry is `<label>:<nonce>:<lock-token>:<pid>` (console-template.md). Where
# each field comes from:
#   label       the manifest's `legs[].label` (leg-identity.sh's N<k>)
#   lock-token  the leg's held queue lock (`queue-lock.sh status <doc>` owner.json
#               `session`): read from the lock on every render, never typed
#   nonce       AUTHORITY-BEARING and console-only: kept from the entry already on
#               the legs: line, or given with --nonce for a leg not yet listed.
#               Never read from the leg doc or the manifest, which a leg or a
#               manifest edit could set
#   pid         informational: kept from the existing entry, else --pid, else the
#               `pid<digits>` suffix of the lock token
# A manifest leg that holds no lock is left out (tick reads a listed leg whose
# lock is gone as livestate=DRIFT); a leg off the manifest drops. A new leg
# with no nonce is refused and the doc is not touched.
#
# Only the legs: block (the `legs:` line plus the lines wrapped under it, ended
# as tick.sh ends it) inside `## Live state` is rewritten, to ONE `legs:` line:
# the entries, then whatever prose the old block carried. Every other line is
# copied through. --print writes nothing and prints the new line.
# tick.sh is unchanged: livestate=DRIFT/MALFORMED and nonces= read the result as
# they read a hand-written line.
#
# Exit: 0 ok; 1 refused (no manifest, no legs: line, new leg without a nonce);
# 2 usage. PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
# shellcheck disable=SC2016  # backtick spans and awk programs are literal, not expansions
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "usage: live-state.sh <console doc> [--print] [--nonce <label>=<nonce>]... [--pid <label>=<pid>]..." >&2
}

[ "$#" -ge 1 ] || { usage; exit 2; }
doc="$1"; shift
print_only=0
nonces=""
pids=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --print) print_only=1; shift ;;
        --nonce|--pid)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            case "$2" in
                [A-Za-z0-9_.-]*=?*) ;;
                *) usage; exit 2 ;;
            esac
            case "$2" in *[[:space:]\`:\\]*) echo "live-state: $1 value must have no whitespace, backtick, colon or backslash: $2" >&2; exit 2 ;; esac
            if [ "$1" = --nonce ]; then nonces="$nonces$2"$'\n'; else pids="$pids$2"$'\n'; fi
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

[ -f "$doc" ] || { echo "live-state: no such console doc: $doc" >&2; exit 1; }
manifest="${doc%.md}.fleet.json"
[ -f "$manifest" ] || { echo "live-state: no fleet manifest: $manifest" >&2; exit 1; }
rows="$(jq -r '.legs[] | [.label, .doc] | @tsv' "$manifest" 2>/dev/null)" \
    || { echo "live-state: unreadable fleet manifest: $manifest" >&2; exit 1; }

# The block tick.sh reads: the same awk, over the same section.
block_awk='
    $0 == "## Live state" { s = 1; next }
    s && /^## / { s = 0 }
    s && /^legs:/ { f = 1; print; next }
    f && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z ]*:/ || /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]]*[>#]/) { f = 0 }
    f { print }'
old_block="$(awk "$block_awk" "$doc")"
[ -n "$old_block" ] || { echo "live-state: no legs: line under '## Live state' in $doc" >&2; exit 1; }

entry_re='`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`'
old_entries="$(printf '%s\n' "$old_block" | grep -oE "$entry_re" | tr -d '`')"

new_entries=""
missing=""
while IFS=$'\t' read -r label ldoc; do
    [ -n "$label" ] || continue
    out="$(bash "$HERE/../queue-lock.sh" status "$ldoc" 2>/dev/null)"; rc=$?
    case "$rc" in
        11|12) ;;
        0) echo "live-state: $label holds no lock, left out" >&2; continue ;;
        *) echo "live-state: $label: lock status failed (rc=$rc), doc not rewritten" >&2; exit 1 ;;
    esac
    token="$(printf '%s\n' "$out" | head -1 | jq -r '.session // empty' 2>/dev/null)"
    [ -n "$token" ] || { echo "live-state: $label: unreadable lock owner, doc not rewritten" >&2; exit 1; }
    # The token is a field of a backtick span tick.sh splits on `:` and rejects on whitespace.
    case "$token" in
        *[:\`[:space:]]*) echo "live-state: $label: lock owner session has a span delimiter (colon, backtick or whitespace), doc not rewritten" >&2; exit 1 ;;
    esac
    old="$(printf '%s\n' "$old_entries" | awk -F: -v l="$label" '$1 == l { print; exit }')"
    nonce="$(printf '%s' "$old" | cut -d: -f2)"
    pid="$(printf '%s' "$old" | cut -d: -f4)"
    [ -n "$nonce" ] || nonce="$(printf '%s' "$nonces" | sed -n "s/^$label=//p" | head -1)"
    [ -z "$pid" ] && pid="$(printf '%s' "$pids" | sed -n "s/^$label=//p" | head -1)"
    [ -z "$pid" ] && pid="$(printf '%s' "$token" | sed -n 's/.*pid\([0-9][0-9]*\)$/\1/p')"
    if [ -z "$nonce" ] || [ -z "$pid" ]; then
        missing="$missing $label"
        continue
    fi
    new_entries="$new_entries\`$label:$nonce:$token:$pid\` "
done <<EOF
$rows
EOF
if [ -n "$missing" ]; then
    echo "live-state: new leg(s) need --nonce <label>=<nonce> (and --pid when the lock token has no pid suffix):$missing" >&2
    exit 1
fi

prose="$(printf '%s\n' "$old_block" | sed -E "s/^legs:[[:space:]]*//; s/$entry_re//g" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/^none$//; s/^none //')"
if [ -n "$new_entries" ]; then new_line="legs: $new_entries$prose"; else new_line="legs: none${prose:+ $prose}"; fi
new_line="$(printf '%s' "$new_line" | sed -E 's/ +$//')"

if [ "$print_only" -eq 1 ]; then
    printf '%s\n' "$new_line"
    exit 0
fi

tmp="$(mktemp "$doc.XXXXXX")" || { echo "live-state: cannot create a temp file next to $doc" >&2; exit 1; }
chmod --reference="$doc" "$tmp" 2>/dev/null  # gnu-ok: Linux-only kit; the rewrite keeps the doc mode
if ! NL="$new_line" awk '
    $0 == "## Live state" { s = 1; print; next }
    s && /^## / { s = 0 }
    s && /^legs:/ { f = 1; print ENVIRON["NL"]; next }
    f && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z ]*:/ || /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]]*[>#]/) { f = 0 }
    f { next }
    { print }' "$doc" > "$tmp" || ! mv -f "$tmp" "$doc"; then
    rm -f "$tmp"
    echo "live-state: cannot write $doc" >&2
    exit 1
fi
