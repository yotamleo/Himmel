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
printf '{"schema":1,"legs":[{"doc":"%s","label":"N7","added":"x"},{"doc":"%s","label":"N8","added":"x"}]}\n' "$LEG1" "$LEG2" > "${DOC%.md}.fleet.json"

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
printf '{"schema":1,"legs":[{"doc":"%s","label":"N10"},{"doc":"%s","label":"N11"},{"doc":"%s","label":"N12"},{"doc":"%s","label":"N13"},{"doc":"%s","label":"N14"},{"doc":"%s","label":"N.0"}]}\n' "$LEG3" "$LEG4" "$LEG5" "$LEG6" "$LEG7" "$LEG5" > "${DOC2%.md}.fleet.json"
census DEMO-3-N10-gamma-2026-10-08 DEMO-4-N11-delta-2026-10-08-RESUME DEMO-5-N12-eps DEMO-7-N14-zeta DEMO-7-N14-zeta-2026-10-08 DEMO-unrelated
: > "$WORK/send.log"
out2="$(bash "$RB" "$DOC2" --successor S2 --claudex N10,N11,N12,N13,N14 2>&1)"
check "session equal to the full dated stem is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N10 (DEMO-3-N10-gamma-2026-10-08)')"
check "session equal to the full -RESUME stem is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N11 (DEMO-4-N11-delta-2026-10-08-RESUME)')"
check "session equal to the undated name is delivered" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N12 (DEMO-5-N12-eps)')"
check "inbox-send is handed the census-resolved name" "1" "$(grep -c '^DEMO-3-N10-gamma-2026-10-08 ' "$WORK/send.log")"
check "no live match is UNRESOLVED with its candidates" "1" "$(printf '%s\n' "$out2" | grep '^UNRESOLVED N13' | grep -c 'DEMO-6-N13-eta-2026-10-08')"
check "two live matches are UNRESOLVED" "1" "$(printf '%s\n' "$out2" | grep -c '^UNRESOLVED N14')"
check "an unresolved leg is never reported sent" "0" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N1[34]')"
check "an unresolved leg is never handed to inbox-send" "0" "$(grep -c 'tok-thirteen\|tok-fourteen' "$WORK/send.log")"
check "unresolved legs do not fail the run" "0" "$(bash "$RB" "$DOC2" --successor S2 --claudex N10 >/dev/null 2>&1; echo $?)"
out3="$(bash "$RB" "$DOC2" --successor S2 2>&1)"
check "native payload uses the census-resolved full stem" "1" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-4-N11-delta-2026-10-08-RESUME ::')"
check "an unresolved native leg prints no SendMessage" "0" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-[67]-')"
check "a manifest leg missing from Live state is reported by literal label" "1" "$(printf '%s\n' "$out2" | grep -c '^NOT-IN-LIVE-STATE N\.0 ')"
census DEMO-1-N7-alpha DEMO-2-N8-beta

printf '#!/usr/bin/env bash\nexit 3\n' > "$SEND"
check "a failed claudex delivery exits 1" "1" "$(bash "$RB" "$DOC" --successor S --claudex N8 >/dev/null 2>&1; echo $?)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
