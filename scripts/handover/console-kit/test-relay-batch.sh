#!/usr/bin/env bash
# test-relay-batch.sh — HIMMEL-4902. Exercises relay-batch.sh: one command that
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

out="$(bash "$RB" "$DOC" --successor DEMO-nextleg-2026-10-08B-console --claudex N8 2>&1)"
check "native leg gets a printed SendMessage payload" "1" "$(printf '%s\n' "$out" | grep -c '^SENDMESSAGE to=DEMO-1-N7-alpha ::')"
check "the payload names the successor" "1" "$(printf '%s\n' "$out" | grep '^SENDMESSAGE' | grep -c 'your console is now DEMO-nextleg-2026-10-08B-console')"
check "the payload quotes the leg's current token" "1" "$(printf '%s\n' "$out" | grep '^SENDMESSAGE' | grep -c 'tok-seven')"
check "claudex leg goes through inbox-send" "1" "$(printf '%s\n' "$out" | grep -c '^SENT-INBOX N8')"
check "inbox-send is given the leg's token via --token" "1" "$(grep -c -- '--token tok-eight --doc '"$LEG2" "$WORK/send.log")"
check "the claudex leg is not also printed as a SendMessage" "0" "$(printf '%s\n' "$out" | grep -c 'SENDMESSAGE to=DEMO-2')"
check "a leg with no manifest row is skipped, not guessed" "1" "$(printf '%s\n' "$out" | grep -c '^SKIPPED N9')"
# shellcheck disable=SC2016  # the backticks are literal token delimiters
check "no token other than the held ones appears (nothing minted)" "0" "$(printf '%s\n' "$out" | grep -o '`[^`]*`' | grep -vc 'tok-seven\|tok-eight')"
check "the relay never sends LIVE" "0" "$(printf '%s\n' "$out" | grep -c ' LIVE')"
check "usage without --successor exits 2" "2" "$(bash "$RB" "$DOC" >/dev/null 2>&1; echo $?)"
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
# HIMMEL-5074: the lane lives in the manifest. mk_fm2 <lane> gives N10-N12 (and N.0) that
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

# --- HIMMEL-5074: the manifest records each leg's lane; --claudex is derived from it.
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

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
