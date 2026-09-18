#!/usr/bin/env bash
# go-gate.sh — shared predicates for the HIMMEL-2919 console-GO merge gate.
#
# Extracted (HIMMEL-3142) so merge-on-green.sh and block-unresolved-cr-merge.sh
# enforce the exact same rule instead of drifting. Before this, only
# merge-on-green.sh consulted `.locks/go/` — a console-spawned leg that ran
# `gh pr merge` directly never consulted it at all, so the console's GO was
# advisory on that path (PR #798 merged with no GO file anywhere).
#
# console_leg() (HIMMEL-3149) closes the outer half: the test for whether the
# caller's session IS a console-spawned leg (HIMMEL_CONSOLE_LEG truthy) was
# hand-copied at merge-on-green.sh's _truthy(), block-unresolved-cr-merge.sh's
# gate 3, and go.sh's own inline check — byte-identical today, but nothing
# kept them that way. go_gate() below is reached only once console_leg() has
# already said yes; call console_leg() first — go_gate() does not re-check it.
#
# Both functions: sourceable from hooks and scripts, `return`-only (never
# `exit`), no `set -e` toggling. bash 3.2-safe.

# console_leg — rc 0 iff HIMMEL_CONSOLE_LEG is truthy (this process IS a
# console-spawned leg, exported by headed-arm-leg.sh). Same five falsy
# spellings every call site used before HIMMEL-3149, case-insensitive,
# whitespace-stripped: empty, 0, false, off, no — anything else is truthy.
console_leg() {
    case "$(printf '%s' "${HIMMEL_CONSOLE_LEG:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}

# go_gate <pr-num> <head-sha> <go-root>
#   Pure: no gh call, no fs write — only a read under <go-root>/.locks/go/.
#   Callers resolve <pr-num>/<head-sha> and <go-root> (handover_root())
#   themselves. A fresh gh query INSIDE this function would let the GO check
#   drift from the exact head the caller already certified — for
#   merge-on-green.sh that is the sha check-ci just certified and
#   --match-head-commit pins on the merge below — which is the TOCTOU this
#   gate exists to prevent, not a convenience worth adding.
#
#   rc 0 = the GO file <go-root>/.locks/go/<pr-num>.<head-sha> exists and
#          carries the line `head=<head-sha>` exactly — the merge is bound.
#   rc 2 = refused; one-line reason on stdout naming the exact GO path, so the
#          leg (or the operator reading its output) can tell which of the
#          three conditions failed — no go-root, no file, or a file for a
#          different (stale) head — never a generic "not allowed".
go_gate() {
    local pr_num="$1" head_sha="$2" go_root="$3"
    local go_file="${go_root:-<unresolved handover root>}/.locks/go/$pr_num.$head_sha"
    if [ -z "$go_root" ] || ! grep -qxF "head=$head_sha" "$go_file" 2>/dev/null; then
        printf 'PR #%s at %s has no console GO (%s) — this is a console-spawned leg; send READY to your console and wait for GO; a GO for an older head is stale, never reuse it.\n' "$pr_num" "$head_sha" "$go_file"
        return 2
    fi
    return 0
}
