#!/usr/bin/env bash
# test-ship-jira-transition-docs.sh — HIMMEL-3271. Pins that the leg-facing ship
# sequence names `--jira-transition` and states BOTH halves of the rule.
#
# `merge-on-green.sh` makes the Jira auto-transition opt-in (HIMMEL-3143), so a
# leg whose PR completes its ticket must ask for it; a leg whose ticket spans
# further PRs must NOT (closing a sliced ticket on its first slice is the
# HIMMEL-3059 regression). A doc that only says "pass the flag" recreates
# HIMMEL-3143, so every assertion set below checks the omit branch too.
#
# The rule is prose read by a model, so what can be pinned is that it is there,
# in every site a leg or a console reads the ship sequence, and that the sites
# agree on the `completes-ticket:` vocabulary. RED first: against a tree
# without the rule every assertion below fails, none of them vacuously.
#
# Docs-only reads, no network, no live state. PLATFORM GUARD: no .ps1 twin —
# Bash 3.2, grep/awk/sed/tr only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCS="${DOCS:-$HERE/../../docs}"
PREFACE="$DOCS/handover/leg-preface.md"
BRIEF="$DOCS/handover/leg-brief-template.md"
CONSOLE="$DOCS/handover/console-template.md"
RUNNING="$DOCS/handover/running-a-console.md"
CLAUDEX="$DOCS/handover/leg-preface-claudex.md"
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
flat() { tr '\n' ' ' | tr -s ' '; }
contains() {  # contains <label> <haystack> <needle>  (case-insensitive, fixed, whitespace-flattened)
    if printf '%s\n' "$2" | flat | grep -iF -- "$3" > /dev/null; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
absent() {  # absent <label> <haystack> <needle>
    if printf '%s\n' "$2" | flat | grep -iF -- "$3" > /dev/null; then fail "$1 (found '$3')"; else pass "$1"; fi
}
# section <file> <heading-regex> -- the body under a heading, up to the next heading of any level
section() {
    awk -v re="$2" '
        $0 ~ re { f = 1; next }
        f && /^#+ / { exit }
        f { print }
    ' "$1"
}

for f in "$PREFACE" "$BRIEF" "$CONSOLE" "$RUNNING" "$CLAUDEX"; do
    [ -r "$f" ] || { printf 'FAIL - unreadable %s\n' "$f"; exit 1; }
done

# --- 1. leg-preface.md § Shipping: the rule, both branches -------------------
ship="$(section "$PREFACE" '^## Shipping')"
[ -n "$ship" ] || fail 'leg-preface.md has a "## Shipping" section'
contains 'preface Shipping names the merge script the flag belongs to' "$ship" 'merge-on-green.sh'
contains 'preface Shipping names --jira-transition' "$ship" '--jira-transition'
contains 'preface Shipping says the transition is opt-in, so a bare merge closes nothing' "$ship" 'opt-in'
contains 'preface Shipping: completes-ticket: yes -> pass the flag' "$ship" 'completes-ticket: yes'
contains 'preface Shipping: completes-ticket: no -> omit the flag' "$ship" 'completes-ticket: no'
contains 'preface Shipping states the omit branch in words' "$ship" 'omit the flag'
contains 'preface Shipping says never to turn the flag on by default' "$ship" 'never turn it on by default'
contains 'preface Shipping names the sliced-ticket regression the default would recreate' "$ship" 'HIMMEL-3059'
contains 'preface Shipping: the flag closes only the FIRST [KEY] of the PR title' "$ship" "\`[KEY]\` of the PR title"
contains 'preface Shipping keeps the post-merge re-read' "$ship" 're-read the ticket after merge'
contains 'preface Shipping tells a leg with no completes-ticket line to decide it itself' "$ship" 'decide it yourself'

# --- 2. leg-preface.md § Wrapping up agrees ---------------------------------
wrap="$(section "$PREFACE" '^## Wrapping up')"
contains 'preface Wrapping up: a ticket --jira-transition already closed is not closed twice' "$wrap" '--jira-transition'
absent 'preface Wrapping up no longer tells every leg to close the ticket out unconditionally' "$wrap" 'close the ticket out with the PR number'

# --- 3. leg-brief-template.md: the console fills the decision in ------------
brief="$(cat "$BRIEF")"
contains 'brief template Ship contract carries a completes-ticket: yes|no line' "$brief" 'completes-ticket: yes|no'
contains 'brief template: yes means the leg passes --jira-transition' "$brief" '--jira-transition'
contains 'brief template: no means the ticket spans further PRs' "$brief" 'further PRs'
contains 'brief template explains why the line is load-bearing (HIMMEL-3271)' "$brief" 'HIMMEL-3271'

# --- 4. the console docs restate the merge: keep them in step ---------------
for pair in "console-template.md Merges:$CONSOLE" "running-a-console.md Merges:$RUNNING"; do
    label="${pair%%:*}"; file="${pair#*:}"
    merges="$(section "$file" '^## Merges')"
    contains "$label names completes-ticket" "$merges" 'completes-ticket'
    contains "$label names --jira-transition" "$merges" '--jira-transition'
    contains "$label keeps the post-merge re-read of a multi-key PR" "$merges" 're-read'
done

# --- 5. sweep: the claudex preface must not fork the rule -------------------
# It is concatenated after leg-preface.md (headed-arm-leg.sh), overriding only
# the coordination channel, so it must neither restate nor contradict the rule.
absent 'claudex preface does not restate the flag (leg-preface.md is the one site)' "$(cat "$CLAUDEX")" '--jira-transition'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-ship-jira-transition-docs.sh'
    exit 0
fi
printf 'FAIL - test-ship-jira-transition-docs.sh (%s failure(s))\n' "$fails"
exit 1
