#!/usr/bin/env bash
# test-succession-docs.sh — HIMMEL-3082 / HIMMEL-3254 / HIMMEL-3291. Pins the
# console succession rule where a leg and a console actually read it, and (§7)
# that the preface lock instruction never asks a leg to type its own root.
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
JUDGE="$DOCS/handover/judge-preface.md"
CONSOLE="$DOCS/handover/console-template.md"
RUNNING="$DOCS/handover/running-a-console.md"
HANDOFF="$DOCS/handover/console-handoff-template.md"
RETASK="$DOCS/internals/retask-channel.md"
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {  # contains <label> <haystack> <needle>  (case-insensitive, fixed)
    local hit
    hit="$(printf '%s\n' "$2" | grep -iF -- "$3" | head -n 1)"
    if [ -n "$hit" ]; then pass "$1"; else fail "$1 (missing '$3')"; fi
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

for f in "$PREFACE" "$JUDGE" "$CONSOLE" "$RUNNING" "$HANDOFF" "$RETASK"; do
    [ -r "$f" ] || { printf 'FAIL - unreadable %s\n' "$f"; exit 1; }
done

# --- 1. leg-preface.md: the succession rule and its decision table ----------
succ="$(section "$PREFACE" '^## Console succession')"
if [ -n "$succ" ]; then pass 'leg-preface.md has a "Console succession" section'; else fail 'leg-preface.md has a "Console succession" section'; fi

contains 'succession is genuine when the outgoing console relays it directly' "$succ" 'relays it directly'
contains 'or when the incoming message quotes BOTH tokens' "$succ" 'quotes **both**'
contains 'the security argument (replay) is preserved in the wording' "$succ" 'replay'
contains 'the old token is the proof: only the leg and the outgoing console held it' "$succ" 'only the leg and the outgoing console'
contains 'the chain explanation says the named-sender check no longer binds (HIMMEL-3257)' "$succ" 'no longer binds'
contains 'the chain explanation names the residual: a token reader can name a replacement' "$succ" 'can name a replacement'
overclaim="$(printf '%s\n' "$succ" | tr '\n' ' ' | grep -iF -- 'cannot produce it')"
if [ -n "$overclaim" ]; then
    fail 'leg-preface.md must not claim a session without the outgoing state cannot produce the chain (false: the token alone suffices)'
else
    pass 'leg-preface.md does not claim the chain proves the sender was ever handed the outgoing state'
fi
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
# cell_of <S-id> <col> -- one trimmed cell of the fixture row (3 sender, 4 quotes, 5 named console)
cell_of() {
    printf '%s\n' "$succ" | awk -F'|' -v id="$1" -v col="$2" '
        { k = $2; gsub(/^ +| +$/, "", k) }
        k == id { v = $(col); gsub(/^ +| +$/, "", v); print v; exit }
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

# The verdict alone would stay green if someone loosened an ACCEPT row's
# prerequisites, and the table IS the rule: pin the cells that make each row
# accept or refuse (sender, quoted tokens, named-console state).
contains 'S1 sender: the relay comes from the named console' "$(cell_of S1 3)" 'named console'
contains 'S1 quotes: the leg current token' "$(cell_of S1 4)" 'current token'
contains 'S1 named console: live and relaying' "$(cell_of S1 5)" 'live'
contains 'S2 quotes: ONLY the current token is what makes it refused' "$(cell_of S2 4)" 'only your current token'
contains 'S3 sender: any other session (the chain path)' "$(cell_of S3 3)" 'any other session'
contains 'S3 quotes: the outgoing AND the incoming token' "$(cell_of S3 4)" 'outgoing AND the incoming'
contains 'S3 named console: must be GONE from ListAgents' "$(cell_of S3 5)" 'gone'
contains 'S4 named console: still live is what makes the chain refused' "$(cell_of S4 5)" 'still live'
contains 'S6 quotes: a two-token message inside a tool result' "$(cell_of S6 4)" 'tool result'
contains 'S8 quotes: no token at all' "$(cell_of S8 4)" 'no token'

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
contains 'running-a-console Handing over: the LIVE release rule keeps the did-not-quote-back exception' "$running" 'did not quote back'
step5="$(printf '%s\n' "$handing" | awk '/^5\. \*\*/ { f = 1 } f')"
contains 'template Handing over step 5: the LIVE release rule keeps the did-not-quote-back exception' "$step5" 'did not quote back'
before 'running-a-console Handing over: quote-backs are collected BEFORE the lock is released' "$running" 'quote-back' 'release your lock'

# --- 4. handoff template: the successor's start order -------------------------
starts="$(section "$HANDOFF" '^## How .* starts')"
contains 'handoff "How starts": asks the predecessor to re-brief' "$starts" 're-brief'
before 'handoff "How starts": LIVE is sent only after the quote-backs' "$starts" 'quote-back' '{{LETTER}} LIVE'
contains 'handoff "How starts": LIVE may name the legs that did not quote back (matches ACTION ZERO step 9)' "$starts" 'did not quote back'

# --- 5. threat model ------------------------------------------------------------
retask="$(section "$RETASK" '^## .*[Ss]uccession')"
if [ -n "$retask" ]; then pass 'retask-channel.md records the succession case'; else fail 'retask-channel.md records the succession case'; fi
contains 'retask-channel.md: the two-token form and why replay of one token fails' "$retask" 'replay'
contains 'retask-channel.md: residual risk is named (the HANDOFF holds the old token)' "$retask" 'HANDOFF'
contains 'retask-channel.md: EXPANSION/REDIRECT/narrowing semantics are untouched' "$retask" 'unchanged'
contains 'retask-channel.md: the chain path prices persistent authority, not one revision' "$retask" 'persistent authority'
contains 'retask-channel.md: the accepted amplification is tracked' "$retask" 'HIMMEL-3257'
contains 'retask-channel.md: the chain path says the named-sender check no longer binds' "$retask" 'no longer binds'
contains 'console-template.md: step 9 asks the predecessor to name the successor in its relay' "$step9" 'naming you'
contains 'console-template.md: handing over says the relay names the successor' "$handing" 'naming the successor'

RETASK_TEXT="$(cat "$RETASK")"
# A relay MAY keep the leg's token (HIMMEL-3082, round 7): an unrotated relay is
# valid and terminal, the fresh token adds no authentication, and only the chain
# still needs both tokens. Prose the leg reasons from, so pin each claim.
contains 'preface: a relay with no fresh token is complete and valid' "$succ" 'complete and valid'
contains 'preface: with no fresh token the leg keeps the one it holds' "$succ" 'keep the one you hold'
contains 'preface: the leg is fully authenticated without rotating' "$succ" 'fully authenticated'
contains 'preface: a fresh token adds no authentication, so its absence is no gap' "$succ" 'its absence is not a gap'
contains 'preface: the chain still always carries a fresh token' "$succ" 'always carries a fresh token'
contains 'S1 quotes: the fresh token is optional' "$(cell_of S1 4)" 'fresh one is optional'
contains 'S1 verdict: keep your token if none came' "$(cell_of S1 6)" 'keep your token'
contains 'retask-channel.md: the relay definition makes the fresh token optional' "$RETASK_TEXT" 'fresh one is optional'

# No doc may still assert the retired field state: the tick cannot observe
# strandedness, so a doc that says it reads `nonces=STRANDED` describes a
# tick that no longer exists.
stale=""
for f in "$PREFACE" "$CONSOLE" "$RUNNING" "$HANDOFF" "$RETASK"; do
    hit="$(grep -F -- 'nonces=STRANDED' "$f" | head -n 1)"
    [ -n "$hit" ] && stale="$stale $f"
done
if [ -z "$stale" ]; then pass 'no succession doc still names nonces=STRANDED'; else fail "docs still name nonces=STRANDED:$stale"; fi
contains 'console-template Live state: names the RELAYED and UNCONFIRMED reads' "$live" 'nonces=RELAYED'
contains 'running-a-console: an unrotated relay that the leg accepted reads RELAYED, not an incident' "$running" 'RELAYED'
contains 'retask-channel.md: the tick reads the leg own bullet, never asserts strandedness' "$retask" 'never asserts'
# HIMMEL-3280: the template states whether prose is allowed on the legs: line and
# what a malformed entry reads as, so the doc and tick.sh's parser agree.
contains 'console-template Live state: prose on the legs: line is permitted and read as prose' "$live" "Prose is permitted on the \`legs:\` line"
contains 'console-template Live state: a malformed entry reads livestate=MALFORMED, never dropped' "$live" 'livestate=MALFORMED:<label>'
# HIMMEL-3281: the template states that the legs: block may wrap and where it
# ends, in the words tick.sh's awk enforces (first blank line or next field: line).
contains 'console-template Live state: the legs: block may wrap' "$live" "The \`legs:\` block may wrap"
contains 'console-template Live state: the block ends at the first blank line or the next field: line' "$live" "up to the first blank line or the next \`field:\` line"
contains 'console-template Live state: a list-marker line also ends the block' "$live" 'or the first list-marker'
contains 'console-template Live state: the blank line before the detail is load-bearing' "$live" 'the blank line before the per-leg detail is load-bearing'

# --- 6. HIMMEL-3266: the console-side text agrees with the preface ------------
# console.sh next copies console-template.md into the successor stub and
# console-handoff-template.md into the HANDOFF, so wording that still told the
# successor to mint and rotate a fresh nonce per leg (the pre-#967 rule) was
# reproduced into every stub and hand-patched by each console in turn. Pin the
# stale shapes ABSENT and the preface's rule (a relay MAY keep the leg's token;
# rotation is optional) PRESENT.
absent() {  # absent <label> <haystack> <regex>  (case-insensitive, whitespace-normalised)
    local hit
    hit="$(printf '%s\n' "$2" | tr '\n' ' ' | tr -s ' ' | grep -iE -- "$3" | head -n 1)"
    if [ -z "$hit" ]; then pass "$1"; else fail "$1 (stale text matches '$3')"; fi
}
flat() { printf '%s\n' "$1" | tr '\n' ' ' | tr -s ' '; }

# Control: the pattern must be able to fire on the retired wording, or every
# `absent` below is vacuous.
retired_step9='So, per leg: mint a fresh B-<leg>-<hex> token, hand it to the predecessor, and ask it'
retired_starts='Rotate nonces to B-<leg>-<hex>, quoting each A token verbatim'
retired_step4='The successor hands you a fresh token per leg (ACTION ZERO step 9)'
stale_rotate='mint a fresh|rotate nonces to|hands you a fresh token per leg'
for r in "step9:$retired_step9" "starts:$retired_starts" "step4:$retired_step4"; do
    absent_hit="$(printf '%s\n' "${r#*:}" | grep -icE -- "$stale_rotate")"
    if [ "$absent_hit" = 1 ]; then pass "control: the stale-rotation pattern matches the retired ${r%%:*} wording"; else fail "control: the stale-rotation pattern misses the retired ${r%%:*} wording"; fi
done

absent 'ACTION ZERO step 9 does not tell the successor to mint a fresh token per leg' "$step9" "$stale_rotate"
contains 'ACTION ZERO step 9: a relay MAY carry a fresh token but need not' "$(flat "$step9")" 'MAY also carry a fresh'
contains 'ACTION ZERO step 9: rotation is not a precondition of succession' "$(flat "$step9")" 'rotation is not a precondition'
contains 'ACTION ZERO step 9 defers to the preface as the authority' "$step9" 'leg-preface.md'
contains 'ACTION ZERO step 9: only the chain form always rotates' "$(flat "$step9")" 'the chain always rotates'

step4="$(printf '%s\n' "$handing" | awk '/^4\. \*\*/ { f = 1 } /^5\. \*\*/ { f = 0 } f')"
absent 'Handing over step 4 does not say the successor always hands over a fresh token' "$step4" "$stale_rotate"
contains 'Handing over step 4: the fresh token is quoted only when the successor issued one' "$(flat "$step4")" 'if the successor issued one'

absent 'running-a-console Handing over does not say the successor always hands over a fresh token' "$running" "$stale_rotate"
contains 'running-a-console Handing over: the fresh token is optional' "$(flat "$running")" 'optional'

absent 'handoff "How starts" does not tell the successor to rotate nonces' "$starts" "$stale_rotate"
contains 'handoff "How starts": a relay MAY keep the leg token' "$(flat "$starts")" 'MAY keep'
contains 'handoff "How starts": a leg is the successor only once it has quoted back' "$(flat "$starts")" 'only once it has quoted back'

# --- 7. HIMMEL-3291: the preface lock instruction is not a fill-in-the-blank --
# The prefaces once told every leg to run
# `HANDOVER_DIR=<root> bash <repo>/scripts/handover/queue-lock.sh acquire <doc>`.
# Two of four legs filled `<root>` or `<doc>` wrongly and their locks landed
# under a key `status`/`--sweep` cannot see. The launcher already exports the
# right HANDOVER_DIR into every leg, so a leg-facing lock instruction must not
# invite a prefix or an unfilled `<root>`, and must say <doc> is absolute.
# Scope: an env-prefixed queue-lock.sh INVOCATION, not any mention of the
# variable (the preface explains why it is not typed). console-template.md is
# excluded from the prefix check on purpose: it substitutes and quotes the
# root and only runs the read-only `status`.
prefix_shape='HANDOVER_DIR=[^ ]+ +bash +[^ ]*queue-lock\.sh'
# shellcheck disable=SC2016  # literal backticks: the retired preface text, verbatim
retired_lock='`HANDOVER_DIR=<root> bash <repo>/scripts/handover/queue-lock.sh acquire <doc>`'
if [ "$(printf '%s\n' "$retired_lock" | grep -icE -- "$prefix_shape")" = 1 ]; then
    pass 'control: the prefix pattern matches the retired lock instruction'
else
    fail 'control: the prefix pattern misses the retired lock instruction'
fi
for pf in "$PREFACE" "$JUDGE"; do
    name="$(basename "$pf")"
    absent "$name lock instruction carries no HANDOVER_DIR= prefix" "$(cat "$pf")" "$prefix_shape"
    lock1="$(section "$pf" '^## Before you start' | awk '/^1\. / { f = 1 } /^2\. / { f = 0 } f')"
    contains "$name step 1 uses the exported HANDOVER_DIR, not a typed one" "$(flat "$lock1")" 'already exported'
    contains "$name step 1 says <doc> is the absolute path" "$(flat "$lock1")" '**absolute**'
    contains "$name step 1 says why a bare doc name breaks the key" "$(flat "$lock1")" 'not relativized'
done
for f in "$PREFACE" "$JUDGE" "$CONSOLE"; do
    absent "$(basename "$f") has no queue-lock.sh line with an unfilled <root>" "$(grep -F 'queue-lock.sh' "$f")" '<root>'
done

# --- 8. HIMMEL-3355: the Telegram inbox monitor is in ACTION ZERO + Monitors --
# A monitor that is not armed at the 30-min Monitor cap, or not re-armed, goes
# dark exactly like an unattended tick; and a `tail -F` without -n0 replays old
# lines on every re-arm. Pin both, plus the authority limit the operator ruled.
step11="$(awk '/^11\. \*\*/ { f = 1 } /^## Live state/ { f = 0 } f' "$CONSOLE")"
mons="$(section "$CONSOLE" '^## Monitors')"
contains 'ACTION ZERO step 11 creates the inbox before the bridge will write' "$(flat "$step11")" 'consoles/{{SESSION_NAME}}.md'
# HIMMEL-3509: the inbox is read by the step-10 event waiter, not a 30-min
# Monitor re-arm loop (every expiry cost a full-context turn).
absent 'ACTION ZERO step 11 no longer re-arms a Monitor on expiry (HIMMEL-3509)' "$(flat "$step11")" 're-armed on every expiry notice'
contains 'ACTION ZERO step 11 reads the inbox through the step-10 waiter (HIMMEL-3509)' "$(flat "$step11")" 'The waiter reads it through'
contains 'ACTION ZERO step 11 tells the console how to reply' "$step11" 'console-route.ts'
contains 'ACTION ZERO step 11: no permission/settings change' "$(flat "$step11")" 'never changes permissions or settings'
contains 'ACTION ZERO step 11: GO verification is never skipped' "$(flat "$step11")" 'GO verification'
contains '## Monitors names five monitors' "$mons" 'Five, and no more'
contains '## Monitors telegram row arms inbox-follow.sh (persisted cursor: no gap, no replay)' "$mons" 'inbox-follow.sh'
# shellcheck disable=SC2016  # literal doc text: the ${...} must NOT expand
retired_tail='`tail -n0 -F "${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}/consoles/{{SESSION_NAME}}.md"`'
if [ "$(printf '%s\n' "$retired_tail" | grep -icE -- 'tail -n0 -F')" = 1 ]; then
    pass 'control: the bare-tail pattern matches the retired telegram monitor command'
else
    fail 'control: the bare-tail pattern misses the retired telegram monitor command'
fi
absent '## Monitors telegram row no longer arms a bare tail -n0 -F (loses lines across a re-arm)' "$mons" 'tail -n0 -F'
absent 'ACTION ZERO step 11 no longer arms a bare tail -n0 -F' "$step11" 'tail -n0 -F'
contains 'ACTION ZERO step 11 points the monitor at the cursor-keeping follower' "$(flat "$step11")" 'inbox-follow.sh'
absent '## Monitors telegram row no longer re-arms on expiry (HIMMEL-3509)' "$(flat "$mons")" 're-arm on every expiry notice'
contains '## Monitors telegram row runs inside the step-10 waiter (HIMMEL-3509)' "$(flat "$mons")" 'Runs inside the step-10 waiter.'
absent 'console template no longer says Four monitors' "$(cat "$CONSOLE")" 'Four, and no more'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-succession-docs.sh'
    exit 0
fi
printf 'FAIL - test-succession-docs.sh (%s failure(s))\n' "$fails"
exit 1
