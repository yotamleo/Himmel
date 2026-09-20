#!/usr/bin/env bash
# scripts/lib/test-leg-identity.sh -- table test for leg-identity.sh (HIMMEL-3277).
#
# Every row uses a name the harness really produces: docs filed per
# docs/handover/leg-brief-template.md, sessions as console.sh / headed-arm-leg.sh
# name them, and the legacy -leg<k>- / -legN<k>- spellings live handover buckets
# still carry. The point of the suite is that a derivation is only trusted once
# it has been shown to MATCH a real name, not merely to agree with itself.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=leg-identity.sh
. "$HERE/leg-identity.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; }

# expect <stem> <label> <names-csv>
expect() {
    local got want
    got="$(leg_identity "$1")"
    want="$2"$'\t'"$3"
    if [ "$got" = "$want" ]; then
        ok "$1 -> $2"
    else
        bad "$1: got [$got] want [$want]"
    fi
}

# Canonical: doc == session (+ -RESUME, + -date).
expect 'HIMMEL-3269-N191-scorecard-discovery-2026-09-20-RESUME.md' \
    'N191' 'HIMMEL-3269-N191-scorecard-discovery-2026-09-20,HIMMEL-3269-N191-scorecard-discovery'
expect 'HIMMEL-3277-N194-tick-leg-identity' \
    'N194' 'HIMMEL-3277-N194-tick-leg-identity'
expect '/abs/path/HIMMEL-2-N7-x-2026-09-20-RESUME.md' \
    'N7' 'HIMMEL-2-N7-x-2026-09-20,HIMMEL-2-N7-x'
# Legacy family: the same label, plus the session the console derives for it.
expect 'HIMMEL-3273-stop-queue-race-leg192-2026-09-20-RESUME.md' \
    'N192' 'HIMMEL-3273-stop-queue-race-leg192-2026-09-20,HIMMEL-3273-stop-queue-race-leg192,HIMMEL-3273-N192-stop-queue-race'
expect 'HIMMEL-3277-tick-leg-identity-legN194-2026-09-20-RESUME.md' \
    'N194' 'HIMMEL-3277-tick-leg-identity-legN194-2026-09-20,HIMMEL-3277-tick-leg-identity-legN194,HIMMEL-3277-N194-tick-leg-identity'
expect 'HIMMEL-9-leg3-2026-09-20-RESUME.md' \
    'N3' 'HIMMEL-9-leg3-2026-09-20,HIMMEL-9-leg3,HIMMEL-9-N3'
# Anything else: the whole stem is its own label and joins to no session.
expect 'HIMMEL-9-odd-name-2026-09-20-RESUME.md' \
    'HIMMEL-9-odd-name-2026-09-20-RESUME' 'HIMMEL-9-odd-name-2026-09-20,HIMMEL-9-odd-name'
expect 'weird stem!' 'weird_stem_' 'weird stem!'

# leg_label is exactly the label column.
if [ "$(leg_label 'HIMMEL-3269-N191-scorecard-discovery-2026-09-20-RESUME.md')" = 'N191' ]; then
    ok 'leg_label prints the label alone'
else
    bad 'leg_label prints the label alone'
fi

# Every label the lib emits is accepted by the class tick.sh builds its parser from.
for stem in 'HIMMEL-3269-N191-scorecard-discovery-2026-09-20-RESUME.md' \
            'HIMMEL-9-odd-name-2026-09-20-RESUME.md' 'weird stem!'; do
    lbl="$(leg_label "$stem")"
    if grep -Eq "^[$LEG_LABEL_CLASS]+\$" <<< "$lbl"; then
        ok "label of '$stem' fits LEG_LABEL_CLASS"
    else
        bad "label of '$stem' escapes LEG_LABEL_CLASS: $lbl"
    fi
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
