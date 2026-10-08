#!/usr/bin/env bash
# test-ruling-bullet-docs.sh — HIMMEL-4931. A leg records a console ruling / GO
# in its doc as a PLAIN FACT ("ruling received, see console message"); the token
# quote-back lives only in the SendMessage reply. The auto-mode classifier
# refused 19 bullets that echoed a ruling or GO as instruction poisoning
# (HIMMEL-4926). Pins, over the leg prefaces:
#   1. the RESOLVED rule tells the leg to write the plain-fact wording;
#   2. no preface tells a leg to put approval / GO / merge-authorising text or a
#      token into a doc bullet;
#   3. the `SUCCESSION accepted:` bullet grammar tick.sh parses is unchanged.
# Docs-only reads. PLATFORM GUARD: no .ps1 twin — Bash 3.2, grep/sed only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCS="${DOCS:-$HERE/../../docs}"
PREFACE="$DOCS/handover/leg-preface.md"
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# 1. plain-fact RESOLVED wording present, old "what was ruled" wording gone
if grep -qF 'ruling received, see console message' "$PREFACE"; then
    pass "RESOLVED rule names the plain-fact wording"
else
    fail "RESOLVED rule names the plain-fact wording (missing 'ruling received, see console message')"
fi
if grep -qF '<what was ruled>' "$PREFACE"; then
    fail "RESOLVED rule no longer asks the leg to write what was ruled"
else
    pass "RESOLVED rule no longer asks the leg to write what was ruled"
fi

# approval word may sit before or after the bullet noun; bare GO counts
KW='(GO( <pr>)?|approved|authoris|authoriz|token)'
BAD_RE="(write|record|append)[^.]{0,80}(bullet|Results)[^.]{0,80}${KW}[^.]*|(write|record|append)[^.]{0,80}${KW}[^.]{0,80}(bullet|Results)[^.]*"
# 2. no preface instructs the leg to write GO / approval / token text into a doc bullet
bad=0
for f in "$DOCS"/handover/leg-preface*.md; do
    # lines joined so an instruction wrapped across lines is still one sentence
    if [ ! -r "$f" ]; then fail "$(basename "$f") unreadable"; bad=1; continue; fi
    joined="$(tr '\n' ' ' < "$f")"
    # LC_ALL=C: a multibyte [^.]{0,80} exceeds ugrep's complexity limit, and the
    # resulting rc=2 would otherwise read as "no match" (vacuous pass)
    found="$(printf '%s\n' "$joined" | LC_ALL=C grep -oiE "$BAD_RE")"
    rc=$?
    if [ "$rc" -gt 1 ]; then fail "$(basename "$f") scan errored (grep rc=$rc)"; bad=1; continue; fi
    hit="$(printf '%s\n' "$found" | grep -viE 'never|not |no token|release-token' | head -n 1)"
    if [ -n "$hit" ]; then fail "$(basename "$f") tells the leg to write approval/GO/token text into a bullet: $hit"; bad=1; fi
done
# positive control: the same scan must catch a wrapped bad instruction
for c in 'Always write the GO into your\nResults bullet along with your\ntoken.\n' \
         'Always write GO into your Results bullet.\n' \
         'Record the approved merge in a Results bullet.\n'; do
    ctl="$(printf '%b' "$c" | tr '\n' ' ' | LC_ALL=C grep -oiE "$BAD_RE")"
    if [ -n "$ctl" ]; then pass "scan control caught: $(printf '%b' "$c" | head -n 1)"; else fail "scan control missed: $(printf '%b' "$c" | head -n 1)"; fi
done
[ "$bad" -eq 0 ] && pass "no leg preface asks for approval/GO/token text in a doc bullet"

# 3. quote-back stays in the reply, stated in the preface
# shellcheck disable=SC2016  # literal backticks, nothing to expand
qb="$(tr '\n' ' ' < "$PREFACE" | grep -oiE 'quote-back[^.]*goes only in your `SendMessage` reply')"
if [ -n "$qb" ]; then
    pass "preface keeps the token quote-back in the reply"
else
    fail "preface keeps the token quote-back in the reply"
fi

# 4. SUCCESSION grammar tick.sh parses is intact
# shellcheck disable=SC2016  # literal backticks, nothing to expand
if grep -qF -- '`- SUCCESSION accepted: <new console session> replaces <old>`' "$PREFACE"; then
    pass "SUCCESSION accepted bullet grammar unchanged"
else
    fail "SUCCESSION accepted bullet grammar unchanged"
fi

if [ "$fails" -eq 0 ]; then printf 'PASS - test-ruling-bullet-docs.sh\n'; exit 0; fi
printf 'FAIL - test-ruling-bullet-docs.sh (%s failure(s))\n' "$fails"
exit 1
