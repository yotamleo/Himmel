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
# Legacy with the slug AFTER the leg token: it survives into the derived session.
expect 'HIMMEL-9-legN3-worker-2026-09-20-RESUME.md' \
    'N3' 'HIMMEL-9-legN3-worker-2026-09-20,HIMMEL-9-legN3-worker,HIMMEL-9-N3-worker'
# Anything else: the whole stem is its own label and joins to no session.
expect 'HIMMEL-9-odd-name-2026-09-20-RESUME.md' \
    'HIMMEL-9-odd-name-2026-09-20-RESUME' 'HIMMEL-9-odd-name-2026-09-20,HIMMEL-9-odd-name'
expect 'weird stem!' 'weird_stem_' 'weird stem!'

# HIMMEL-3278: a successor (`b`, `c`, ...) is a DIFFERENT session from its base leg,
# so the letters stay in the label -- N38b is not N38. Every row below is a name
# the live handover bucket carries.
expect 'HIMMEL-2733-lean-profile-v2-legN38b-2026-09-07-RESUME.md' \
    'N38b' 'HIMMEL-2733-lean-profile-v2-legN38b-2026-09-07,HIMMEL-2733-lean-profile-v2-legN38b,HIMMEL-2733-N38b-lean-profile-v2'
expect 'HIMMEL-2743-oem-parity-projection-legN52b-claudex-2026-09-07-RESUME.md' \
    'N52b' 'HIMMEL-2743-oem-parity-projection-legN52b-claudex-2026-09-07,HIMMEL-2743-oem-parity-projection-legN52b-claudex,HIMMEL-2743-N52b-oem-parity-projection-claudex'
expect 'HIMMEL-1899-public-ci-shell-reds-legN3c-2026-09-06.md' \
    'N3c' 'HIMMEL-1899-public-ci-shell-reds-legN3c-2026-09-06,HIMMEL-1899-public-ci-shell-reds-legN3c,HIMMEL-1899-N3c-public-ci-shell-reds'
# The canonical successor a console's own brief mandates ("hand off to an N196b").
expect 'HIMMEL-3278-N196b-leg-relaunch-2026-09-20-RESUME.md' \
    'N196b' 'HIMMEL-3278-N196b-leg-relaunch-2026-09-20,HIMMEL-3278-N196b-leg-relaunch'
# A ticket key that is not <KEY>-<digits>: the leg token still parses.
expect 'HIMMEL-drift-graphify-0955-legN5-2026-09-06.md' \
    'N5' 'HIMMEL-drift-graphify-0955-legN5-2026-09-06,HIMMEL-drift-graphify-0955-legN5,HIMMEL-N5-drift-graphify-0955'
expect 'HIMMEL-gh627-luna-upgrade-bash32-legN189-2026-09-12-RESUME.md' \
    'N189' 'HIMMEL-gh627-luna-upgrade-bash32-legN189-2026-09-12,HIMMEL-gh627-luna-upgrade-bash32-legN189,HIMMEL-N189-gh627-luna-upgrade-bash32'
# ...but only an UPPERCASE project key is trusted without digits: prose that merely
# contains "-leg<digits>" is not a leg doc, and neither is a console/mission doc.
expect 'next-session-leg5-2026-09-06.md' \
    'next-session-leg5-2026-09-06' 'next-session-leg5-2026-09-06,next-session-leg5'
expect 'HIMMEL-nextleg-2026-09-20N-console.md' \
    'HIMMEL-nextleg-2026-09-20N-console' 'HIMMEL-nextleg-2026-09-20N-console'
# A bare-key doc is a leg only when it says legN<k>: `-leg1` in a fleet/cadence
# series is a different numbering that would collide with the real N1.
expect 'HIMMEL-linux-fleet-2026-09-04-leg1.md' \
    'HIMMEL-linux-fleet-2026-09-04-leg1' 'HIMMEL-linux-fleet-2026-09-04-leg1'
expect 'HIMMEL-v1-installer-cadence-2026-09-05-leg2-evidence.md' \
    'HIMMEL-v1-installer-cadence-2026-09-05-leg2-evidence' 'HIMMEL-v1-installer-cadence-2026-09-05-leg2-evidence'
expect 'HIMMEL-1899-public-propagation-legG10-2026-09-05.md' \
    'HIMMEL-1899-public-propagation-legG10-2026-09-05' 'HIMMEL-1899-public-propagation-legG10-2026-09-05,HIMMEL-1899-public-propagation-legG10'

# leg_base: the leg a successor continues. The label keeps N38 and N38b apart;
# the base is what a metric that counts relaunches of ONE leg groups by.
check_base() {
    local got
    got="$(leg_base "$1")"
    if [ "$got" = "$2" ]; then ok "leg_base $1 -> $2"; else bad "leg_base $1: got [$got] want [$2]"; fi
}
check_base 'HIMMEL-2733-lean-profile-v2-legN38b-2026-09-07-RESUME.md' 'N38'
check_base 'HIMMEL-2733-lean-profile-v2-legN38-2026-09-07-RESUME.md' 'N38'
check_base 'HIMMEL-3278-N196b-leg-relaunch-2026-09-20-RESUME.md' 'N196'
check_base 'HIMMEL-3278-N196-leg-relaunch-2026-09-20-RESUME.md' 'N196'
check_base 'HIMMEL-9-odd-name-2026-09-20-RESUME.md' 'HIMMEL-9-odd-name-2026-09-20-RESUME'
# The property that matters: distinct labels, one base.
l38="$(leg_label 'HIMMEL-2733-x-legN38-2026-09-07-RESUME.md')"
l38b="$(leg_label 'HIMMEL-2733-x-legN38b-2026-09-07-RESUME.md')"
if [ "$l38" != "$l38b" ] && [ "$(leg_base 'HIMMEL-2733-x-legN38-2026-09-07-RESUME.md')" = "$(leg_base 'HIMMEL-2733-x-legN38b-2026-09-07-RESUME.md')" ]; then
    ok 'N38 and N38b: distinct labels, same base'
else
    bad "N38 and N38b: labels [$l38] [$l38b] must differ, bases must match"
fi

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
