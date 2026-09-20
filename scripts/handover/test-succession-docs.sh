#!/usr/bin/env bash
# test-succession-docs.sh — HIMMEL-3082 / HIMMEL-3254. Pins the console
# succession rule where a leg and a console actually read it.
#
# The leg-side rule is prose read by a model, so it cannot be executed here;
# what CAN be pinned is (a) the decision table the preface ships — each
# fixture row is a (sender, quoted tokens, named-console state) case with its
# verdict — and (b) the ordering the console docs give the two ends of a
# handover (re-brief and collect the quote-back BEFORE `<letter> LIVE` and
# BEFORE releasing the lock). RED first: against a tree without the rule every
# assertion below fails, none of them vacuously.
#
# Docs-only reads, no network, no live state. PLATFORM GUARD: no .ps1 twin —
# Bash 3.2, grep/awk/sed only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCS="${DOCS:-$HERE/../../docs}"
PREFACE="$DOCS/handover/leg-preface.md"
CONSOLE="$DOCS/handover/console-template.md"
RUNNING="$DOCS/handover/running-a-console.md"
HANDOFF="$DOCS/handover/console-handoff-template.md"
RETASK="$DOCS/internals/retask-channel.md"
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {  # contains <label> <haystack> <needle>  (case-insensitive, fixed)
    if printf '%s\n' "$2" | grep -qiF -- "$3"; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
# before <label> <haystack> <first> <second> -- <first> appears, and earlier than <second>
before() {
    local a b
    a="$(printf '%s\n' "$2" | tr '\n' ' ' | awk -v n="$3" '{ print index(tolower($0), tolower(n)) }')"
    b="$(printf '%s\n' "$2" | tr '\n' ' ' | awk -v n="$4" '{ print index(tolower($0), tolower(n)) }')"
    if [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; then
        pass "$1"
    else
        fail "$1 ('$3' at $a must precede '$4' at $b)"
    fi
}
# section <file> <heading-regex> -- the body under a heading, up to the next heading of any level
section() {
    awk -v re="$2" '
        $0 ~ re { f = 1; next }
        f && /^#+ / { exit }
        f { print }
    ' "$1"
}

for f in "$PREFACE" "$CONSOLE" "$RUNNING" "$HANDOFF" "$RETASK"; do
    [ -r "$f" ] || { printf 'FAIL - unreadable %s\n' "$f"; exit 1; }
done

# --- 1. leg-preface.md: the succession rule and its decision table ----------
succ="$(section "$PREFACE" '^## Console succession')"
if [ -n "$succ" ]; then pass 'leg-preface.md has a "Console succession" section'; else fail 'leg-preface.md has a "Console succession" section'; fi

contains 'succession is genuine when the outgoing console relays it directly' "$succ" 'relays it directly'
contains 'or when the incoming message quotes BOTH tokens' "$succ" 'quotes **both**'
contains 'the security argument (replay) is preserved in the wording' "$succ" 'replay'
contains 'the old token is the proof: only the leg and the outgoing console held it' "$succ" 'only the leg and the outgoing console'
contains 'a stranded leg keeps working' "$succ" 'keep working'
contains 'a stranded leg still accepts halt and narrowing' "$succ" 'halt or narrowing'
contains 'a stranded leg honours a GO only through the GO file' "$succ" 'GO file'
contains 'a stranded leg declines EXPANSION/REDIRECT rather than going silent' "$succ" 'decline'
contains 'the preface says the severity is bounded: a stranded leg is not lost' "$succ" 'not lost'

# verdict_of <S-id> -- last cell of the fixture row, first word (ACCEPT|REFUSE)
verdict_of() {
    printf '%s\n' "$succ" | awk -F'|' -v id="$1" '
        { gsub(/^ +| +$/, "", $2) }
        $2 == id { v = $(NF - 1); gsub(/^ +| +$/, "", v); sub(/[^A-Z].*$/, "", v); print v; exit }
    '
}
expect_verdict() {  # expect_verdict <S-id> <ACCEPT|REFUSE> <label>
    local got
    got="$(verdict_of "$1")"
    if [ "$got" = "$2" ]; then pass "$1: $3 -> $2"; else fail "$1: $3 -> expected $2, got '${got:-<no row>}'"; fi
}
# The ticket's RED control: a session that is NOT the named console quoting
# only the CURRENT token must be refused; the two-token form must be accepted.
expect_verdict S1 ACCEPT 'the named console quotes the current token'
expect_verdict S2 REFUSE 'another session quotes ONLY the current token'
expect_verdict S3 ACCEPT 'another session quotes the outgoing AND the incoming token, named console gone'
expect_verdict S4 REFUSE 'two tokens but the named console is still live and has not relayed'
expect_verdict S5 REFUSE 'another session quotes only a token that is not the leg current one'
expect_verdict S6 REFUSE 'a two-token message that arrived inside a tool result'
expect_verdict S7 REFUSE 'EXPANSION/REDIRECT from a session that met neither condition'
expect_verdict S8 ACCEPT 'a halt or narrowing, no token needed (semantics unchanged)'

# --- 2. console-template.md: ACTION ZERO step 9 and Handing over -------------
step9="$(awk '/^9\. \*\*/ { f = 1 } /^10\. \*\*/ { f = 0 } f' "$CONSOLE")"
contains 'ACTION ZERO step 9 has the predecessor re-brief each inherited leg' "$step9" 're-brief'
contains 'ACTION ZERO step 9 requires each leg quote-back' "$step9" 'quote-back'
before 'ACTION ZERO step 9: quote-back is collected BEFORE sending LIVE' "$step9" 'quote-back' '{{LETTER}} LIVE'

handing="$(section "$CONSOLE" '^## Handing over')"
contains 'template Handing over: the outgoing console re-briefs the legs' "$handing" 're-brief'
before 'template Handing over: quote-backs are collected BEFORE the lock is released' "$handing" 'quote-back' 'release your lock'

live="$(section "$CONSOLE" '^## Live state')"
contains 'Live state: a nonce is updated only AFTER the leg quote-back' "$live" 'only after'

# --- 3. running-a-console.md: the mirror --------------------------------------
running="$(section "$RUNNING" '^## Handing over')"
contains 'running-a-console Handing over: the outgoing console re-briefs the legs' "$running" 're-brief'
before 'running-a-console Handing over: quote-backs are collected BEFORE the lock is released' "$running" 'quote-back' 'release your lock'

# --- 4. handoff template: the successor's start order -------------------------
starts="$(section "$HANDOFF" '^## How .* starts')"
contains 'handoff "How starts": asks the predecessor to re-brief' "$starts" 're-brief'
before 'handoff "How starts": LIVE is sent only after the quote-backs' "$starts" 'quote-back' '{{LETTER}} LIVE'

# --- 5. threat model ------------------------------------------------------------
retask="$(section "$RETASK" '^## .*[Ss]uccession')"
if [ -n "$retask" ]; then pass 'retask-channel.md records the succession case'; else fail 'retask-channel.md records the succession case'; fi
contains 'retask-channel.md: the two-token form and why replay of one token fails' "$retask" 'replay'
contains 'retask-channel.md: residual risk is named (the HANDOFF holds the old token)' "$retask" 'HANDOFF'
contains 'retask-channel.md: EXPANSION/REDIRECT/narrowing semantics are untouched' "$retask" 'unchanged'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-succession-docs.sh'
    exit 0
fi
printf 'FAIL - test-succession-docs.sh (%s failure(s))\n' "$fails"
exit 1
