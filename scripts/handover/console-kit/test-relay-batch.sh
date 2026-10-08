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
# Leg docs carry -<date> and -RESUME; the launcher's session name has neither (leg_identity).
LEG3="$WORK/DEMO-3-N10-gamma-2026-10-08.md"
LEG4="$WORK/DEMO-4-N11-delta-2026-10-08-RESUME.md"
LEG5="$WORK/DEMO-5-N12-eps.md"
: > "$LEG3"; : > "$LEG4"; : > "$LEG5"
DOC2="$WORK/DEMO-nextleg-2026-10-08C-console.md"
cat > "$DOC2" <<'EOF2'
# console

## Live state

legs: `N10:tok-ten:lock10:1` `N11:tok-eleven:lock11:2`
queue: none

## Results
EOF2
printf '{"schema":1,"legs":[{"doc":"%s","label":"N10"},{"doc":"%s","label":"N11"},{"doc":"%s","label":"N12"}]}\n' "$LEG3" "$LEG4" "$LEG5" > "${DOC2%.md}.fleet.json"
: > "$WORK/send.log"
out2="$(bash "$RB" "$DOC2" --successor S2 --claudex N10,N11 2>&1)"
check "a dated leg doc is addressed by its undated session" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N10 (DEMO-3-N10-gamma)')"
check "a dated -RESUME leg doc is addressed by its undated session" "1" "$(printf '%s\n' "$out2" | grep -c '^SENT-INBOX N11 (DEMO-4-N11-delta)')"
check "inbox-send is handed the real session name" "1" "$(grep -c '^DEMO-3-N10-gamma ' "$WORK/send.log")"
check "a manifest leg missing from Live state is reported" "1" "$(printf '%s\n' "$out2" | grep -c '^NOT-IN-LIVE-STATE N12')"
out3="$(bash "$RB" "$DOC2" --successor S2 2>&1)"
check "native payload uses the undated session too" "1" "$(printf '%s\n' "$out3" | grep -c '^SENDMESSAGE to=DEMO-4-N11-delta ::')"

printf '#!/usr/bin/env bash\nexit 3\n' > "$SEND"
check "a failed claudex delivery exits 1" "1" "$(bash "$RB" "$DOC" --successor S --claudex N8 >/dev/null 2>&1; echo $?)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
