#!/usr/bin/env bash
# leg-identity.sh — the ONE derivation of a leg's identity (HIMMEL-3277).
#
# A console files a leg's brief as a handover doc and launches the leg under a
# session name (`claude -n <session>`). Every instrument that joins the two --
# tick.sh's legs=/procs=/models=/livestate=, and any later reader that maps a
# leg doc to a live session -- must derive the mapping HERE, never re-guess it
# with a local regex: a guess that silently matches nothing reads as a
# confident zero (HIMMEL-3145, HIMMEL-3269, HIMMEL-3277).
#
# Canonical (docs/handover/leg-brief-template.md):
#   doc     <TICKET>-N<k>-<slug>-<date>-RESUME.md      (the -RESUME and the
#   session <TICKET>-N<k>-<slug>                        -<date> are both optional)
#   label   N<k>   -- the token docs/handover/console-template.md tells a console
#                     to write in its `## Live state` legs: line.
# Also accepted, because live and archived docs carry it: the legacy family
#   <TICKET>[-<slug>]-leg[N]<k>-<date>-RESUME.md
# (the pre-HIMMEL-3277 template spelled it -leg<k>-, older consoles -legN<k>-).
# It yields the same N<k> label, and the session name the console derives
# for it: <TICKET>-N<k>[-<slug>]. Anything else falls back to the whole stem as
# its own label, which is self-consistent but joins to no session.
#
# Source this file; it defines functions and one constant, runs nothing.
# Bash 3.2-compatible (no arrays beyond BASH_REMATCH, no mapfile).

# Characters a label may contain. tick.sh builds its `legs:` span parser from the
# same class, so a label this file emits is always one the parser accepts.
LEG_LABEL_CLASS='A-Za-z0-9_.-'

# leg_identity <leg doc path or stem>
# Prints ONE line: <label><TAB><name>[,<name>...]
# <name>s are every session name the leg may be running under (stem without
# -RESUME, the same without its trailing date, and the derived session for a
# legacy-family doc); a census row matching any of them belongs to this leg.
leg_identity() {
    local stem="$1" session undated sfx derived="" label=""
    local re_canon='^[A-Za-z][A-Za-z]*-[0-9]+-(N[0-9]+)(-.*)?$'
    local re_legacy='^([A-Za-z][A-Za-z]*-[0-9]+)(-(.*))?-leg(N?)([0-9]+)(-.*)?$'
    stem="${stem##*/}"
    stem="${stem%.md}"
    session="${stem%-RESUME}"
    undated="$(printf '%s' "$session" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}$//')"
    if [[ $stem =~ $re_canon ]]; then
        label="${BASH_REMATCH[1]}"
    elif [[ $stem =~ $re_legacy ]]; then
        label="N${BASH_REMATCH[5]}"
        # A slug AFTER the leg token (-legN3-worker-<date>) belongs in the session
        # too; the trailing -RESUME and -<date> do not.
        sfx="${BASH_REMATCH[6]%-RESUME}"
        sfx="$(printf '%s' "$sfx" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}$//')"
        derived="${BASH_REMATCH[1]}-${label}${BASH_REMATCH[3]:+-${BASH_REMATCH[3]}}${sfx}"
    else
        label="$stem"
    fi
    label="$(printf '%s' "$label" | tr -c "$LEG_LABEL_CLASS" '_')"
    local names="$session"
    [ "$undated" = "$session" ] || names="$names,$undated"
    [ -z "$derived" ] || names="$names,$derived"
    printf '%s\t%s\n' "$label" "$names"
}

# leg_label <leg doc path or stem> -- just the label, for callers that need no names.
leg_label() {
    local ident
    ident="$(leg_identity "$1")"
    printf '%s' "${ident%%$'\t'*}"
}
