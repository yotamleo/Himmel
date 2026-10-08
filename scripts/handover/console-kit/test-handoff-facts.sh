#!/usr/bin/env bash
# test-handoff-facts.sh — HIMMEL-4902. Exercises handoff-facts.sh, the
# mechanical half of the outgoing console's HANDOFF: every field `console.sh
# next` pre-fills so the console writes only its judgement notes. bash 3.2-safe.
#
# HANDOFF_FACTS overrides the script under test (the RED control).
#
# Run: bash scripts/handover/console-kit/test-handoff-facts.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HF="${HANDOFF_FACTS:-$HERE/handoff-facts.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}
has() { # <name> <needle> <haystack>
    case "$3" in *"$2"*) echo "PASS: $1" ;; *) echo "FAIL: $1 (no '$2' in '$3')"; fails=$((fails + 1)) ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/handoff-facts-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git init -q "$REPO" && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" remote add origin https://example.invalid/demo.git
SHA="$(git -C "$REPO" rev-parse HEAD)"

DOC="$WORK/DEMO-nextleg-2026-10-08A-console.md"
LEG1="$WORK/DEMO-1-N7-alpha.md"
LEG2="$WORK/DEMO-2-N8-beta.md"
cat > "$LEG1" <<'EOF'
# leg
## Results
- 10:00 LIVE — started
- 10:30 READY 12 abc GREEN — see `secret-token-value` here
EOF
cat > "$LEG2" <<'EOF'
# leg
## Results
- 09:00 LIVE — started
EOF
cat > "$DOC" <<'EOF'
# console

## Live state

legs: `N7:n1:t1:11` `N8:n2:t2:22`
queue: HIMMEL-9, HIMMEL-10
last GO: `12:abc`
board: none

## Results
- 08:00 LIVE — one
- 08:10 RESOLVED — two
- 08:20 LIVE — three
EOF
printf '{"schema":1,"legs":[{"doc":"%s","label":"N7","added":"x"},{"doc":"%s","label":"N8","added":"x"}]}\n' "$LEG1" "$LEG2" > "${DOC%.md}.fleet.json"

BANK="$WORK/bank.sh"
printf '#!/usr/bin/env bash\necho "bank-preflight: leg=unknown five_hour=9.0 seven_day=91.0 extra_usage=n/a"\necho PROCEED\n' > "$BANK"
PRS="$WORK/prs.sh"
printf '#!/usr/bin/env bash\necho "#5 [HIMMEL-1] a title (feat/a)"\n' > "$PRS"

run() { # <field>
    HANDOFF_FACTS_BANK="$BANK" HANDOFF_FACTS_PRS="$PRS" bash "$HF" "$1" "$DOC" --repo "$REPO" 2>/dev/null
}

has "head names the sha" "$SHA" "$(run head)"
has "head names the remote" "https://example.invalid/demo.git" "$(run head)"
has "bank reads both windows" "5-hour 9.0 %, 7-day 91.0 %" "$(run bank)"
legs="$(run legs)"
has "legs lists N7 with its last marker" "N7: READY" "$legs"
has "legs lists N8 with its last marker" "N8: LIVE" "$legs"
check "legs strips backtick spans" "0" "$(printf '%s' "$legs" | grep -c 'secret-token-value')"
has "prs prints the open PR" "#5 [HIMMEL-1]" "$(run prs)"
has "summary carries the newest bullet" "three" "$(run summary)"
has "queue copies the Live state line" "HIMMEL-9, HIMMEL-10" "$(run queue)"
has "lastgo copies the Live state line" "12:abc" "$(run lastgo)"
check "unknown field exits 2" "2" "$(bash "$HF" nope "$DOC" --repo "$REPO" >/dev/null 2>&1; echo $?)"
printf '#!/usr/bin/env bash\necho "#1 a"\necho "#2 b"\necho "#3 c"\n' > "$PRS"
check "prs at the limit says truncated" "yes" "$(HANDOFF_FACTS_PRS_LIMIT=3 run prs | grep -q truncated && echo yes)"
check "prs under the limit is not flagged" "0" "$(HANDOFF_FACTS_PRS_LIMIT=9 run prs | grep -c truncated)"
cp "${DOC%.md}.fleet.json" "$WORK/fleet.good"
echo '{not json' > "${DOC%.md}.fleet.json"
has "legs with a malformed manifest reads unavailable" "unavailable" "$(run legs)"
check "legs with a malformed manifest is not 'no legs'" "0" "$(run legs | grep -c 'lists no legs')"
cp "$WORK/fleet.good" "${DOC%.md}.fleet.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$PRS"
check "prs failure is fail-open text" "yes" "$(printf '#!/usr/bin/env bash\nexit 1\n' > "$PRS"; run prs | grep -q unavailable && echo yes)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
