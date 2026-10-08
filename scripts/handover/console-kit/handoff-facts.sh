#!/usr/bin/env bash
# handoff-facts.sh — HIMMEL-4902. The mechanical half of a console HANDOFF.
#
#   handoff-facts.sh <field> <console doc> [--repo <path>]
#
# `console.sh next` calls this once per field to pre-fill the predecessor's
# HANDOFF, so the outgoing console writes only its judgement notes (one Edit)
# instead of deriving each of these by hand over ~18 turns (measured, HIMMEL-4902).
# Read-only: it never writes a file, takes a lock or contacts a leg.
#
# Fields:
#   head     `<sha>` on `<branch>` at `<repo>`, remote `<url>`
#   bank     5-hour / 7-day utilisation (bank-preflight.sh)
#   legs     one line per fleet-manifest leg: label, last marker, last bullet
#            (backtick spans stripped: a leg bullet may quote a token)
#   prs      the open PR set (gh); `unavailable` when gh fails
#   summary  the console's last HANDOFF_FACTS_BULLETS (12) Results bullets
#   queue    the Live state `queue:` line
#   lastgo   the Live state `last GO:` line
#
# Every field fails open to a line starting `unavailable`, which the handoff
# shows as-is: the successor re-derives that one by hand, nothing else breaks.
# Seams (tests): HANDOFF_FACTS_BANK, HANDOFF_FACTS_PRS replace the bank and
# PR commands.
#
# Exit: 0 ok; 2 usage. PLATFORM GUARD: Linux-only kit, bash 3.2-safe; needs jq.
# shellcheck disable=SC2016  # the backticks are literal markdown code spans
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DEFAULT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../lib/leg-tail-status.sh
. "$HERE/../../lib/leg-tail-status.sh"

usage() { echo "usage: handoff-facts.sh <head|bank|legs|prs|summary|queue|lastgo> <console doc> [--repo <path>]" >&2; exit 2; }
[ "$#" -ge 2 ] || usage
field="$1"; doc="$2"; shift 2
repo="$REPO_DEFAULT"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        *) usage ;;
    esac
done

live_line() { # <field name> — one `name: value` line of the doc's ## Live state
    awk -v f="$1" '
        $0 == "## Live state" { s = 1; next }
        s && /^## / { exit }
        s && index($0, f ":") == 1 { print; exit }
    ' "$doc"
}

case "$field" in
    head)
        sha="$(git -C "$repo" log -1 --format=%H 2>/dev/null)" || sha=""
        [ -n "$sha" ] || { echo "unavailable — git log failed at $repo"; exit 0; }
        branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        remote="$(git -C "$repo" remote get-url origin 2>/dev/null)"
        printf '`%s` on `%s` at `%s`, remote `%s`.\n' "$sha" "$branch" "$repo" "${remote:-none}"
        ;;
    bank)
        if [ -n "${HANDOFF_FACTS_BANK:-}" ]; then
            out="$(bash "$HANDOFF_FACTS_BANK" 2>/dev/null)" || out=""
        else
            out="$(CADENCE_BANK_LAUNCH='' CADENCE_BANK_LEDGER=/dev/null timeout -k 5 60 bash "$repo/scripts/lib/bank-preflight.sh" 2>/dev/null)" || out=""  # gnu-ok: Linux-only kit
        fi
        five="$(printf '%s\n' "$out" | tr ' ' '\n' | sed -n 's/^five_hour=//p' | head -n 1)"
        seven="$(printf '%s\n' "$out" | tr ' ' '\n' | sed -n 's/^seven_day=//p' | head -n 1)"
        verdict="$(printf '%s\n' "$out" | tail -n 1)"
        if [ -n "$five" ] && [ -n "$seven" ]; then
            printf '5-hour %s %%, 7-day %s %% (%s).\n' "$five" "$seven" "$verdict"
        else
            echo "unavailable — run bank-preflight.sh"
        fi
        ;;
    legs)
        manifest="${doc%.md}.fleet.json"
        if [ ! -f "$manifest" ]; then echo "none — no fleet manifest"; exit 0; fi
        n=0
        while IFS="$(printf '\t')" read -r label ldoc; do
            [ -n "$ldoc" ] || continue
            n=$((n + 1))
            marker="$(leg_tail_status "$ldoc")"
            last="$(sed -nE '/^- /p' "$ldoc" 2>/dev/null | tail -n 1 | sed 's/`[^`]*`/`…`/g' | cut -c1-200)"
            printf -- '- %s: %s — %s (%s)\n' "$label" "${marker:-no marker}" "$last" "$(basename "$ldoc")"
        done < <(jq -r '.legs[] | "\(.label)\t\(.doc)"' "$manifest" 2>/dev/null)
        [ "$n" -gt 0 ] || echo "none — manifest lists no legs"
        ;;
    prs)
        if [ -n "${HANDOFF_FACTS_PRS:-}" ]; then
            out="$(bash "$HANDOFF_FACTS_PRS" 2>/dev/null)" || out=""
        else
            out="$(cd "$repo" && timeout -k 2 30 gh pr list --state open --limit 30 --json number,title,headRefName --jq '.[] | "#\(.number) \(.title) (\(.headRefName))"' 2>/dev/null)" || out=""  # gnu-ok: Linux-only kit
        fi
        if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "unavailable or none — run gh pr list"; fi
        ;;
    summary)
        awk '/^## Results/ { s = 1; next } s && /^## / { exit } s && /^- / { print }' "$doc" \
            | tail -n "${HANDOFF_FACTS_BULLETS:-12}" | sed 's/`[^`]*`/`…`/g' | cut -c1-240
        ;;
    queue) live_line queue ;;
    lastgo) live_line "last GO" ;;
    *) usage ;;
esac
