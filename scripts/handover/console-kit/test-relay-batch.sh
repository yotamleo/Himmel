#!/usr/bin/env bash
# test-relay-batch.sh — Exercises relay-batch.sh: one command that
# relays a console succession to every leg, never minting or rotating a token.
# inbox-send.sh is stubbed (INBOX_SEND). bash 3.2-safe.
#
# RELAY_BATCH overrides the script under test (the RED control).
#
# Run: bash scripts/handover/console-kit/test-relay-batch.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RB="${RELAY_BATCH:-$HERE/relay-batch.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-batch-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

DOC="$WORK/DEMO-nextleg-2026-10-08A-console.md"
LEG1="$WORK/DEMO-1-N7-alpha.md"
LEG2="$WORK/DEMO-2-N8-beta.md"
: > "$LEG1"; : > "$LEG2"
cat > "$DOC" <<'EOF'
# console

## Live state

legs: `N7:tok-seven:lock7:11` `N8:tok-eight:lock8:22`
`N9:tok-nine:lock9:33` extra prose
queue: none
last GO: none

## Results
EOF
printf '{"schema":1,"legs":[{"doc":"%s","label":"N7","added":"x","lane":"native"},{"doc":"%s","label":"N8","added":"x","lane":"claudex"}]}\n' "$LEG1" "$LEG2" > "${DOC%.md}.fleet.json"

SEND="$WORK/send.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/send.log"\n' "$WORK" > "$SEND"
export INBOX_SEND="$SEND"
# The live process census (claude_sessions format: pid<TAB>name<TAB>model<TAB>autocompact).
CENSUS="$WORK/census.sh"
printf '#!/usr/bin/env bash\ncat "%s/census.txt"\n' "$WORK" > "$CENSUS"
export RELAY_BATCH_CENSUS="$CENSUS"
census() { : > "$WORK/census.txt"; for n in "$@"; do printf '100\t%s\topus\t200000\n' "$n" >> "$WORK/census.txt"; done; }
census DEMO-1-N7-alpha DEMO-2-N8-beta
# The himmel-bus CLI: logs `<verb> <to>` and the body file it was handed.
BUS="$WORK/bus.sh"
# shellcheck disable=SC2016  # $1-$3 expand in the stub, not here; read-sink-ok: $3 is the body file relay-batch.sh mktemps
LOGBUS="$(printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1 $2" >> "%s/bus.log"; cat "$3" >> "%s/bus.body"\n' "$WORK" "$WORK")"
printf '%s\n' "$LOGBUS" > "$BUS"
chmod +x "$BUS"
export RELAY_BATCH_BUS="$BUS"
# The outgoing console's own bus identity: without one, no bus record is sent.
export HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-08A-console

rc=0
out="$(bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-console --claudex N8 2>&1)" || rc=$?
check "relay-batch succeeds for native and claudex relays" "0" "$rc"
check "a native leg also gets a bus record from the outgoing console" "send DEMO-1-N7-alpha" "$(grep -x 'send DEMO-1-N7-alpha' "$WORK/bus.log" 2>/dev/null)"
check "a claudex leg gets a bus record too, under its doc stem" "send DEMO-2-N8-beta" "$(grep -x 'send DEMO-2-N8-beta' "$WORK/bus.log" 2>/dev/null)"
check "the claudex bus send is reported" "1" "$(printf '%s\n' "$out" | grep -c '^BUS-RELAY N8 ok$')"
check "the bus record names the successor as a whole word, once per relayed leg" "2" "$(grep -cE 'your console is now DEMO-nextleg-2026-10-08B-console[. ]' "$WORK/bus.body" 2>/dev/null)"
check "the bus record carries no token" "0" "$(grep -c 'tok-' "$WORK/bus.body" 2>/dev/null)"
check "the bus send is reported" "1" "$(printf '%s\n' "$out" | grep -c '^BUS-RELAY N7 ok$')"
check "a native leg whose bus record lands gets no SendMessage" "0" "$(printf '%s\n' "$out" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "the native bus record is the relay: it names itself an S1 relay" "1" "$(grep -cF 'is an S1 relay' "$WORK/bus.body")"
check "the native bus record gives the exact acknowledgement with no trailing text" "1" "$(grep -c 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-console replaces DEMO-nextleg-2026-10-08A-console$' "$WORK/bus.body")"
check "the native bus record forbids anything after the acknowledgement on its line" "1" "$(grep -cF 'nothing after it on that line' "$WORK/bus.body")"
check "a bus-relayed leg counts as relayed" "1" "$(printf '%s\n' "$out" | grep -c '^RELAYED 2 of 2$')"
check "claudex relay gives the same exact acknowledgement before the send flags" "1" "$(grep -cF 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-console replaces DEMO-nextleg-2026-10-08A-console --token tok-eight' "$WORK/send.log")"
check "claudex relay forbids anything after the acknowledgement on its line" "1" "$(grep -cF 'nothing after it on that line' "$WORK/send.log")"
check "claudex leg goes through inbox-send" "1" "$(printf '%s\n' "$out" | grep -c '^SENT-INBOX N8')"
check "inbox-send is given the leg's token via --token" "1" "$(grep -c -- '--token tok-eight --doc '"$LEG2" "$WORK/send.log")"
check "the claudex leg is not also printed as a SendMessage" "0" "$(printf '%s\n' "$out" | grep -c 'SENDMESSAGE to=DEMO-2')"
check "a leg with no manifest row is skipped, not guessed" "1" "$(printf '%s\n' "$out" | grep -c '^SKIPPED N9')"
# shellcheck disable=SC2016  # the backticks are literal token delimiters
check "no token other than the held ones appears (nothing minted)" "0" "$(printf '%s\n' "$out" | grep -o '`[^`]*`' | grep -vc 'tok-seven\|tok-eight')"
check "the relay never sends LIVE" "0" "$(printf '%s\n' "$out" | grep -c ' LIVE')"
: > "$WORK/bus.body"
bash "$RB" "$DOC" --successor "$WORK/DEMO-nextleg-2026-10-08B-console.md" --claudex N8 >/dev/null 2>&1
check "a successor given as its doc path is relayed as its session name" "1" "$(grep -c 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-console replaces DEMO-nextleg-2026-10-08A-console$' "$WORK/bus.body")"
check "usage without --successor exits 2" "2" "$(bash "$RB" "$DOC" >/dev/null 2>&1; echo $?)"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/usr/bin/env bash\necho "bus: no edge to $2" >&2; exit 1\n' > "$BUS"
outb="$(bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-console --claudex N8 2>&1)"; rcb=$?
check "a refused bus send is reported with its reason" "1" "$(printf '%s\n' "$outb" | grep -c '^BUS-RELAY-FAIL N7 (bus: no edge to DEMO-1-N7-alpha)$')"
check "a refused bus send still prints the SendMessage" "1" "$(printf '%s\n' "$outb" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "a refused bus send does not fail the run" "0" "$rcb"
printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$BUS"
outs="$(RELAY_BATCH_BUS_TIMEOUT=1 bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-console --claudex N8 2>&1)"; rcs=$?
check "a stalled bus send is cut off and reported" "1" "$(printf '%s\n' "$outs" | grep -c '^BUS-RELAY-FAIL N7 (timed out after 1s)$')"
check "a stalled bus send still prints the SendMessage" "1" "$(printf '%s\n' "$outs" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "a stalled bus send does not fail the run" "0" "$rcs"
# Four native legs on a stalled bus: every relay prints before any bus send, and the
# sends share one deadline, so the run ends well inside relay-on-live's 60 s kill.
DOC9="$WORK/DEMO-nextleg-2026-10-08E-console.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# console\n\n## Live state\n\nlegs: `N50:tok-a:l:1` `N51:tok-b:l:2` `N52:tok-c:l:3` `N53:tok-d:l:4`\nqueue: none\n\n## Results\n' > "$DOC9"
printf '{"schema":1,"legs":[' > "${DOC9%.md}.fleet.json"
for n in 50 51 52 53; do
    : > "$WORK/DEMO-$n-N$n-four.md"
    [ "$n" = 50 ] || printf ',' >> "${DOC9%.md}.fleet.json"
    printf '{"doc":"%s","label":"N%s","lane":"native"}' "$WORK/DEMO-$n-N$n-four.md" "$n" >> "${DOC9%.md}.fleet.json"
done
printf ']}\n' >> "${DOC9%.md}.fleet.json"
census DEMO-50-N50-four DEMO-51-N51-four DEMO-52-N52-four DEMO-53-N53-four
out4="$(RELAY_BATCH_BUS_TIMEOUT=2 timeout 5 bash "$RB" "$DOC9" --successor DEMO-nextleg-2026-10-08F-console 2>&1)"; rc4=$?
check "four stalled bus sends share one deadline (the run is not killed)" "0" "$rc4"
check "four stalled bus sends: every SENDMESSAGE is printed" "4" "$(printf '%s\n' "$out4" | grep -c '^SENDMESSAGE to=DEMO-5[0-3]-N5[0-3]-four ::')"
check "four stalled bus sends: the tally is printed" "1" "$(printf '%s\n' "$out4" | grep -c '^RELAYED 4 of 4$')"
check "four stalled bus sends: each is reported timed out" "4" "$(printf '%s\n' "$out4" | grep -c '^BUS-RELAY-FAIL N5[0-3] (timed out after 2s)$')"
check "a fallback SendMessage follows the bus sends" "0" "$(printf '%s\n' "$out4" | awk '/^BUS-RELAY/ { exit } /^SENDMESSAGE/ { n++ } END { print n + 0 }')"
census DEMO-1-N7-alpha DEMO-2-N8-beta
printf '%s\n' "$LOGBUS" > "$BUS"
: > "$WORK/bus.log"
outn="$(HIMMEL_BUS_NAME='' bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-console --claudex N8 2>&1)"
check "a console with no bus identity sends no bus record" "" "$(cat "$WORK/bus.log")"
check "a console with no bus identity prints no BUS-RELAY line" "0" "$(printf '%s\n' "$outn" | grep -c '^BUS-RELAY')"
check "a console with no bus identity still prints the SendMessage" "1" "$(printf '%s\n' "$outn" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "the payload names the successor" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -c 'your console is now DEMO-nextleg-2026-10-08B-console')"
check "the payload quotes the leg's current token" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -c 'tok-seven')"
check "native relay gives the exact acknowledgement with no trailing text" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -c 'SUCCESSION accepted: DEMO-nextleg-2026-10-08B-console replaces DEMO-nextleg-2026-10-08A-console$')"
check "the payload no longer asks the leg to verify the relay" "0" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -cF 'Verify this relay')"
check "the payload names itself an S1 relay" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -cF 'S1 relay')"
# shellcheck disable=SC2016  # literal backticks in the pattern
check "the payload quotes only the leg's current token" "\`tok-seven\`" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -o '`[^`]*`' | tr -d '\n')"
check "native relay forbids anything after the acknowledgement on its line" "1" "$(printf '%s\n' "$outn" | grep '^SENDMESSAGE' | grep -cF 'nothing after it on that line')"
# The rows below exercise the SendMessage path: no bus identity from here on.
export HIMMEL_BUS_NAME=
# Each leg's session is resolved from the LIVE process census, never guessed: the full
# doc stem first, then leg_identity's names; exactly one live match or UNRESOLVED.
LEG3="$WORK/DEMO-3-N10-gamma-2026-10-08.md"
LEG4="$WORK/DEMO-4-N11-delta-2026-10-08-RESUME.md"
LEG5="$WORK/DEMO-5-N12-eps.md"
LEG6="$WORK/DEMO-6-N13-eta-2026-10-08.md"
LEG7="$WORK/DEMO-7-N14-zeta-2026-10-08.md"
: > "$LEG3"; : > "$LEG4"; : > "$LEG5"; : > "$LEG6"; : > "$LEG7"
DOC2="$WORK/DEMO-nextleg-2026-10-08C-console.md"
cat > "$DOC2" <<'EOF2'
# console

## Live state

legs: `N10:tok-ten:lock10:1` `N11:tok-eleven:lock11:2` `N12:tok-twelve:lock12:3`
`N13:tok-thirteen:lock13:4` `N14:tok-fourteen:lock14:5`
queue: none

## Results
EOF2
# the lane lives in the manifest. mk_fm2 <lane> gives N10-N12 (and N.0) that
# lane; N13/N14 stay native, since a claudex leg skips the census these two exercise.
mk_fm2() { printf '{"schema":1,"legs":[{"doc":"%s","label":"N10","lane":"%s"},{"doc":"%s","label":"N11","lane":"%s"},{"doc":"%s","label":"N12","lane":"%s"},{"doc":"%s","label":"N13","lane":"native"},{"doc":"%s","label":"N14","lane":"native"},{"doc":"%s","label":"N.0","lane":"%s"}]}\n' "$LEG3" "$1" "$LEG4" "$1" "$LEG5" "$1" "$LEG6" "$LEG7" "$LEG5" "$1" > "${DOC2%.md}.fleet.json"; }
mk_fm2 claudex
census DEMO-3-N10-gamma-2026-10-08 DEMO-4-N11-delta-2026-10-08-RESUME DEMO-5-N12-eps DEMO-7-N14-zeta DEMO-7-N14-zeta-2026-10-08 DEMO-unrelated
: > "$WORK/send.log"
out2="$(bash "$RB" "$DOC2" --successor S2 --claudex N10,N11,N12 2>&1)"
check "session equal to the full dated stem is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N10 (DEMO-3-N10-gamma-2026-10-08)')"
check "session equal to the full -RESUME stem is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N11 (DEMO-4-N11-delta-2026-10-08-RESUME)')"
check "session equal to the undated name is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N12 (DEMO-5-N12-eps)')"
check "inbox-send is handed the census-resolved name" "1" "$(grep -c '^DEMO-3-N10-gamma-2026-10-08 ' "$WORK/send.log")"
check "no live match is UNRESOLVED with its candidates" "1" "$(printf '%s\n' "$out2" | grep '^UNRESOLVED N13' | grep -c 'DEMO-6-N13-eta-2026-10-08')"
check "two live matches are UNRESOLVED" "1" "$(printf '%s\n' "$out2" | grep -c '^UNRESOLVED N14')"
check "an unresolved leg is never reported sent" "0" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N1[34]')"
check "an unresolved leg is never handed to inbox-send" "0" "$(grep -c 'tok-thirteen\|tok-fourteen' "$WORK/send.log")"
check "unresolved legs do not fail the run" "0" "$(bash "$RB" "$DOC2" --successor S2 --claudex N10,N11,N12 >/dev/null 2>&1; echo $?)"
mk_fm2 native
out3="$(bash "$RB" "$DOC2" --successor S2 2>&1)"
check "native payload uses the census-resolved full stem" "1" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-4-N11-delta-2026-10-08-RESUME ::')"
check "an unresolved native leg prints no SendMessage" "0" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-[67]-')"
check "a manifest leg missing from Live state is reported by literal label" "1" "$(printf '%s\n' "$out2" | grep -c '^NOT-IN-LIVE-STATE N\.0 ')"
mk_fm2 claudex
census DEMO-1-N7-alpha DEMO-2-N8-beta

printf '#!/usr/bin/env bash\nexit 3\n' > "$SEND"
check "a failed claudex delivery exits 1" "1" "$(bash "$RB" "$DOC" --successor S --claudex N8 >/dev/null 2>&1; echo $?)"

# --- the manifest records each leg's lane; --claudex is derived from it.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/send.log"\n' "$WORK" > "$SEND"
LEGC="$WORK/DEMO-8-N20-codex-2026-10-09.md"; LEGN="$WORK/DEMO-9-N21-nat-2026-10-09.md"
LEGU="$WORK/DEMO-10-N22-unk-2026-10-09.md"; LEGP="$WORK/DEMO-11-P01-pilot-2026-10-09.md"
: > "$LEGC"; : > "$LEGN"; : > "$LEGU"; : > "$LEGP"
DOC4="$WORK/DEMO-nextleg-2026-10-09A-console.md"
cat > "$DOC4" <<'EOF4'
# console

## Live state

legs: `N20:tok-twenty:lock20:1` `N21:tok-twentyone:lock21:2` `N22:tok-twentytwo:lock22:3`
queue: none

## Results
EOF4
FM4="${DOC4%.md}.fleet.json"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N20","lane":"claudex"},{"doc":"%s","label":"N21","lane":"native"},{"doc":"%s","label":"N22","lane":"unknown"},{"doc":"%s","label":"P01","lane":"deepseek","lockless":true}]}\n' "$LEGC" "$LEGN" "$LEGU" "$LEGP" > "$FM4"
# the claudex leg is not a `claude -n` process: no census entry for it at all.
census DEMO-9-N21-nat-2026-10-09
: > "$WORK/send.log"
out4="$(bash "$RB" "$DOC4" --successor S4 2>&1)"; rc4=$?
check "no --claudex: a manifest claudex leg is delivered through the inbox" "1" "$(printf '%s\n' "$out4" | grep -c '^SENT-INBOX N20 (DEMO-8-N20-codex-2026-10-09)')"
check "no --claudex: the claudex leg is not relayed as native" "0" "$(printf '%s\n' "$out4" | grep -c 'SENDMESSAGE to=DEMO-8')"
check "a claudex leg is not UNRESOLVED for lacking a claude -n process" "0" "$(printf '%s\n' "$out4" | grep -c '^UNRESOLVED N20')"
check "inbox-send gets the claudex leg's token" "1" "$(grep -c -- '--token tok-twenty --doc '"$LEGC" "$WORK/send.log")"
check "a native-lane leg still gets a printed SendMessage" "1" "$(printf '%s\n' "$out4" | grep -c '^SENDMESSAGE to=DEMO-9-N21-nat-2026-10-09 ::')"
check "lane unknown prints UNRESOLVED-LANE" "1" "$(printf '%s\n' "$out4" | grep -c '^UNRESOLVED-LANE N22')"
check "lane unknown is never relayed as native" "0" "$(printf '%s\n' "$out4" | grep -c 'SENDMESSAGE to=DEMO-10')"
check "lane unknown is never handed to inbox-send" "0" "$(grep -c 'tok-twentytwo' "$WORK/send.log")"
check "UNRESOLVED-LANE does not fail the run" "0" "$rc4"
check "a lockless row has its own explicit section" "1" "$(printf '%s\n' "$out4" | grep -c '^LOCKLESS P01 lane=deepseek doc='"$LEGP")"
check "a lockless row is not listed as NOT-IN-LIVE-STATE" "0" "$(printf '%s\n' "$out4" | grep -c '^NOT-IN-LIVE-STATE P01')"
check "a lockless row is never sent a relay" "0" "$(printf '%s\n' "$out4" | grep -c 'SENDMESSAGE to=.*pilot')"
: > "$WORK/send.log"
out5="$(bash "$RB" "$DOC4" --successor S4 --claudex N20 2>&1)"
check "--claudex that agrees with the manifest relays" "1" "$(printf '%s\n' "$out5" | grep -c '^SENT-INBOX N20')"
out6="$(bash "$RB" "$DOC4" --successor S4 --claudex N20,N21 2>&1)"; rc6=$?
check "--claudex naming a non-claudex manifest leg is refused (rc 1)" "1" "$rc6"
check "a refused --claudex mismatch sends nothing" "0" "$(printf '%s\n' "$out6" | grep -c '^SENT-INBOX\|^SENDMESSAGE')"
out7="$(bash "$RB" "$DOC4" --successor S4 --claudex N99 2>&1)"; rc7=$?
check "--claudex omitting the manifest's claudex leg is refused (rc 1)" "1" "$rc7"
check "the refusal names the disagreement" "1" "$(printf '%s\n' "$out7" | grep -c 'disagrees with the fleet manifest')"
# a non-lockless leg on a lane with no relay path is UNRESOLVED-LANE, never relayed as native
DOC6="$WORK/DEMO-nextleg-2026-10-09C-console.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# console\n\n## Live state\n\nlegs: `N30:tok-thirty:lock30:1`\nqueue: none\n\n## Results\n' > "$DOC6"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N30","lane":"deepseek"}]}\n' "$LEGN" > "${DOC6%.md}.fleet.json"
out9="$(bash "$RB" "$DOC6" --successor S6 2>&1)"
check "an unsupported lane is UNRESOLVED-LANE" "1" "$(printf '%s\n' "$out9" | grep -c '^UNRESOLVED-LANE N30 (lane deepseek')"
check "an unsupported lane is never printed as a SendMessage" "0" "$(printf '%s\n' "$out9" | grep -c '^SENDMESSAGE')"
# a console whose Live state lists no legs but whose manifest has a lockless row still reports it
DOC5="$WORK/DEMO-nextleg-2026-10-09B-console.md"
printf '# console\n\n## Live state\n\nlegs: none\nqueue: none\n\n## Results\n' > "$DOC5"
printf '{"schema":1,"legs":[{"doc":"%s","label":"P01","lane":"deepseek","lockless":true}]}\n' "$LEGP" > "${DOC5%.md}.fleet.json"
out8="$(bash "$RB" "$DOC5" --successor S5 2>&1)"; rc8=$?
check "lockless-only console still lists the lockless row" "1" "$(printf '%s\n' "$out8" | grep -c '^LOCKLESS P01 lane=deepseek')"
check "lockless-only console exits 0" "0" "$rc8"

# --- b/N3: label collisions and the lockless predicate.
# a lockless row ahead of a locked leg with the same label never drops the leg silently
DOC7="$WORK/DEMO-nextleg-2026-10-09D-console.md"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# console\n\n## Live state\n\nlegs: `N21:tok-twentyone:lock21:2`\nqueue: none\n\n## Results\n' > "$DOC7"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"deepseek","lockless":true},{"doc":"%s","label":"N21","lane":"native"}]}\n' "$LEGP" "$LEGN" > "${DOC7%.md}.fleet.json"
census DEMO-9-N21-nat-2026-10-09
out10="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1: a locked leg behind a same-label lockless row is still relayed" "1" "$(printf '%s\n' "$out10" | grep -c '^SENDMESSAGE to=DEMO-9-N21-nat-2026-10-09 ::')"
# two locked rows under one label are ambiguous: UNRESOLVED, nothing sent
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"native"},{"doc":"%s","label":"N21","lane":"claudex"}]}\n' "$LEGN" "$LEGC" > "${DOC7%.md}.fleet.json"
: > "$WORK/send.log"
out11="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1: two locked rows with one label print UNRESOLVED" "1" "$(printf '%s\n' "$out11" | grep -c '^UNRESOLVED N21 (2 manifest rows')"
check "B1: an ambiguous label sends nothing" "0 sendlog-bytes=0" "$(printf '%s\n' "$out11" | grep -c '^SENDMESSAGE\|^SENT-INBOX') sendlog-bytes=$(wc -c < "$WORK/send.log" | tr -d ' ')"
# a live entry whose only manifest row is lockless is reported, not skipped silently
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"deepseek","lockless":true}]}\n' "$LEGP" > "${DOC7%.md}.fleet.json"
out12="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1: a live leg whose only row is lockless prints UNRESOLVED" "1" "$(printf '%s\n' "$out12" | grep -c '^UNRESOLVED N21 ')"
# B1b: only the boolean true is lockless; the string "true" stays a visible, relayed row
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":"native","lockless":"true"}]}\n' "$LEGN" > "${DOC7%.md}.fleet.json"
out13="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "B1b: a string true is not lockless: the leg is relayed" "1" "$(printf '%s\n' "$out13" | grep -c '^SENDMESSAGE to=DEMO-9-N21-nat-2026-10-09 ::')"
check "B1b: a string true is not listed as LOCKLESS" "0" "$(printf '%s\n' "$out13" | grep -c '^LOCKLESS')"
# N3: an empty lane is unknown, not the next field
printf '{"schema":1,"legs":[{"doc":"%s","label":"N21","lane":""},{"doc":"%s","label":"P01","lane":"","lockless":true}]}\n' "$LEGN" "$LEGP" > "${DOC7%.md}.fleet.json"
out14="$(bash "$RB" "$DOC7" --successor S7 2>&1)"
check "N3: an empty lane prints UNRESOLVED-LANE unknown" "1" "$(printf '%s\n' "$out14" | grep -c '^UNRESOLVED-LANE N21 (manifest lane unknown')"
check "N3: an empty lockless lane lists as unknown" "1" "$(printf '%s\n' "$out14" | grep -c '^LOCKLESS P01 lane=unknown ')"

# --- a WRAPPED leg (lock free, tail WRAPPED) is neither relayed nor counted; the run ends in n of m.
DOC8="$WORK/DEMO-nextleg-2026-10-20A-console.md"
LEGW="$WORK/DEMO-12-N40-wrapped-2026-10-20.md"; LEGL="$WORK/DEMO-13-N41-live-2026-10-20.md"; LEGX="$WORK/DEMO-14-N42-gone-2026-10-20.md"
printf '# leg\n\n## Results\n\n- 10:00 LIVE - x\n- 10:30 WRAPPED - done\n' > "$LEGW"
printf '# leg\n\n## Results\n\n- 10:00 LIVE - x\n' > "$LEGL"
printf '# leg\n\n## Results\n\n- 10:00 LIVE - x\n- 10:30 WRAPPED - done\n' > "$LEGX"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# console\n\n## Live state\n\nlegs: `N40:tok-forty:lock40:1` `N41:tok-fortyone:lock41:2`\nqueue: none\n\n## Results\n' > "$DOC8"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N40","lane":"native"},{"doc":"%s","label":"N41","lane":"native"},{"doc":"%s","label":"N42","lane":"native"}]}\n' "$LEGW" "$LEGL" "$LEGX" > "${DOC8%.md}.fleet.json"
census DEMO-12-N40-wrapped-2026-10-20 DEMO-13-N41-live-2026-10-20
out15="$(bash "$RB" "$DOC8" --successor S8 2>&1)"; rc15=$?
check "the wrapped-leg relay exits 0" "0" "$rc15"
check "a wrapped leg on Live state is not relayed" "0" "$(printf '%s\n' "$out15" | grep -c 'N40')"
check "a wrapped leg off Live state is not reported" "0" "$(printf '%s\n' "$out15" | grep -c 'N42')"
check "the live leg is relayed" "1" "$(printf '%s\n' "$out15" | grep -c '^SENDMESSAGE to=DEMO-13-N41-live-2026-10-20 ::')"
check "the summary shows n of m with m the live fleet" "1" "$(printf '%s\n' "$out15" | grep -c '^RELAYED 1 of 1$')"
census DEMO-9-N21-nat-2026-10-09
out16="$(bash "$RB" "$DOC4" --successor S4 2>&1)"; rc16=$?
check "the relay with an undeliverable leg exits 0" "0" "$rc16"
check "legs the relay could not deliver count in m but not n" "1" "$(printf '%s\n' "$out16" | grep -c '^RELAYED 2 of 3$')"

# --- a bus relay needs no token, so a manifest leg missing from Live state is relayed too.
DOC10="$WORK/DEMO-nextleg-2026-10-24A-console.md"
LEGA="$WORK/DEMO-15-N60-in-2026-10-24.md"; LEGB="$WORK/DEMO-16-N61-off-2026-10-24.md"; LEGG="$WORK/DEMO-17-N62-gone-2026-10-24.md"
: > "$LEGA"; : > "$LEGB"; : > "$LEGG"
# shellcheck disable=SC2016  # the backticks are literal Live state markers
printf '# console\n\n## Live state\n\nlegs: `N60:tok-sixty:lock60:1`\nqueue: none\n\n## Results\n' > "$DOC10"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N60","lane":"native"},{"doc":"%s","label":"N61","lane":"native"},{"doc":"%s","label":"N62","lane":"native"}]}\n' "$LEGA" "$LEGB" "$LEGG" > "${DOC10%.md}.fleet.json"
census DEMO-15-N60-in-2026-10-24 DEMO-16-N61-off-2026-10-24
printf '%s\n' "$LOGBUS" > "$BUS"
: > "$WORK/bus.log"; : > "$WORK/bus.body"
out17="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-console bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-console 2>&1)"; rc17=$?
check "bus relay of an off-Live-state leg exits 0" "0" "$rc17"
check "a Live-state leg is relayed by bus" "1" "$(grep -cx 'send DEMO-15-N60-in-2026-10-24' "$WORK/bus.log")"
check "a manifest leg missing from Live state is relayed by bus" "1" "$(grep -cx 'send DEMO-16-N61-off-2026-10-24' "$WORK/bus.log")"
check "the off-Live-state bus record carries no token" "0" "$(grep -c 'tok-' "$WORK/bus.body")"
check "no SendMessage is printed when every bus record lands" "0" "$(printf '%s\n' "$out17" | grep -c '^SENDMESSAGE')"
check "a bus-relayed off-Live-state leg is not reported for a hand relay" "0" "$(printf '%s\n' "$out17" | grep -c '^NOT-IN-LIVE-STATE N61 ')"
check "an off-Live-state leg with no live session is left for a hand relay" "1" "$(printf '%s\n' "$out17" | grep -c '^NOT-IN-LIVE-STATE N62 ')"
check "the tally counts both bus relays" "1" "$(printf '%s\n' "$out17" | grep -c '^RELAYED 2 of 3$')"
# shellcheck disable=SC2016  # $2 expands in the stub, not here
printf '#!/usr/bin/env bash\necho "bus: no edge to $2" >&2; exit 1\n' > "$BUS"
out18="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-console bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-console 2>&1)"
check "a refused bus record falls back to the SendMessage for a Live-state leg" "1" "$(printf '%s\n' "$out18" | grep -c '^SENDMESSAGE to=DEMO-15-N60-in-2026-10-24 :: .*tok-sixty')"
check "a refused bus record leaves an off-Live-state leg for a hand relay" "1" "$(printf '%s\n' "$out18" | grep -c '^NOT-IN-LIVE-STATE N61 ')"
check "an off-Live-state leg is never printed a token-less SendMessage" "0" "$(printf '%s\n' "$out18" | grep -c '^SENDMESSAGE to=DEMO-16-')"
check "the fallback tally counts only the printed relay" "1" "$(printf '%s\n' "$out18" | grep -c '^RELAYED 1 of 3$')"
# a manifest row with no lane keeps its doc in the doc field (tab-separated empty fields do not collapse)
LEGL="$WORK/DEMO-18-N63-nolane-2026-10-24.md"; : > "$LEGL"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N60","lane":"native"},{"doc":"%s","label":"N63"}]}\n' "$LEGA" "$LEGL" > "${DOC10%.md}.fleet.json"
out19="$(HIMMEL_BUS_NAME=DEMO-nextleg-2026-10-24A-console bash "$RB" "$DOC10" --successor DEMO-nextleg-2026-10-24B-console 2>&1)"
check "a lane-less off-Live-state leg is reported with its own doc" "1" "$(printf '%s\n' "$out19" | grep -cF "NOT-IN-LIVE-STATE N63 ($LEGL)")"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
