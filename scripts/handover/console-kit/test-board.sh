#!/usr/bin/env bash
# test-board.sh — HIMMEL-3361. Hermetic tests for board.mjs, the generator of the
# console's progress board (console-board.html). tick.sh and gh are stubbed (a
# BOARD_TICK override and a PATH stub), so the suite reads no queue, process,
# scheduler or GitHub state. The board<->tick freshness round trip (board.mjs
# output read back by the REAL tick.sh) is pinned in test-tick.sh, where the tick
# stubs already live.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (tick.sh
# reads pgrep, atq and the konsole launch logs); this suite exercises a kit script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/board.mjs"
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP - test-board.sh (node not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/board-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac
}
lacks() {
    case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac
}

B="$W/bucket"
mkdir -p "$B" "$W/bin" "$W/repo"

# The tick stub records its argv and prints a fixed line + fingerprint. N1..N7
# cover every phase; the fleet is 9/15 with six idle slots.
cat > "$W/bin/tick-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TICK_ARGV_LOG"
[ "${TICK_STUB_FAIL:-0}" -eq 0 ] || exit 1
printf '%s\n' 'TICK 12:34 hb=skip legs=N1:FRESH,N2:FRESH,N3:FRESH,N4:FRESH,N5:WRAPPED,N6:FRESH,N7:FRESH livestate=ok procs=6 models=sonnet:6 ceiling=ok atq=0 suites=0alive/0dead prs=#2001,#2002 bank=5h8/wk42/codex=? fill=28 tails=N1:LIVE,N2:LIVE,N3:READY,N4:LIVE,N5:WRAPPED,N6:READY,N7:BLOCKED inbox=none tick=UNKNOWN fleet=9/15 capacity=UNDERFILLED:6 gql=4321/13:00 orphans=none nonces=ok legset=ok board=MISSING'
printf '%s\n' 'board-fp=deadbeefdeadbeef'
STUB
chmod +x "$W/bin/tick-stub"

# gh stub: open PRs, merged PRs (this shift, and the per-epic search) from files.
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"--state open"*) cat "$GH_OPEN" ;;
    *"--state merged"*"in:title"*) cat "$GH_EPIC" ;;
    *"--state merged"*) cat "$GH_MERGED" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$W/bin/gh"

cat > "$W/open.json" <<'JSON'
[
 {"number":2001,"title":"feat(x): [HIMMEL-3332] slice S3","headRefName":"feat/himmel-3332-s3","isDraft":false,
  "statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"},{"conclusion":"SUCCESS","status":"COMPLETED"}]},
 {"number":2002,"title":"feat(y): [HIMMEL-3340] verdict bar","headRefName":"feat/himmel-3340-bar","isDraft":false,
  "statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"},{"conclusion":"","status":"IN_PROGRESS"}]}
]
JSON
cat > "$W/merged.json" <<'JSON'
[
 {"number":1990,"title":"feat(z): [HIMMEL-3332] S1","mergedAt":"2026-09-21T09:00:00Z","headRefName":"feat/himmel-3332-s1"},
 {"number":1995,"title":"fix(w): [HIMMEL-3348] harden","mergedAt":"2026-09-21T10:00:00Z","headRefName":"fix/himmel-3348"}
]
JSON
cat > "$W/epic.json" <<'JSON'
[
 {"number":1990,"title":"feat(z): [HIMMEL-3332] S1"},
 {"number":1985,"title":"feat(z): [HIMMEL-3332] S2"},
 {"number":1500,"title":"docs: mentions HIMMEL-3332 in passing, not the cited key"}
]
JSON

# Leg docs: the ticket key is the doc's leading token, the label its N<k>.
mkleg() {  # mkleg <name> <bullet>...
    local name="$1"; shift
    printf '%s\n' '# leg' '## Results' "$@" > "$B/$name-2026-09-21-RESUME.md"
}
mkleg HIMMEL-3340-N1-alpha '- 12:00 LIVE — working'
mkleg HIMMEL-3340-N2-beta '- 12:00 LIVE — PR 2002 open, watching CI'
mkleg HIMMEL-3332-N3-gamma '- 12:00 LIVE — building' '- 12:10 READY 2001 0123456789abcdef GREEN'
mkleg HIMMEL-3348-N4-delta '- 12:00 LIVE — PR 1995 was merged'
mkleg HIMMEL-3300-N5-eps '- 12:00 WRAPPED — released'
mkleg HIMMEL-3350-N6-zeta '- 12:00 READY-TO-OPEN — /pr-check clean, not opened'
mkleg HIMMEL-3351-N7-eta '- 12:00 BLOCKED — the push was refused <script>alert(1)</script>'

# The console doc: legs carry nonces + lock tokens (which must never reach the
# board); a Results bullet quotes both again in prose.
DOC="$B/HIMMEL-nextleg-2026-09-21V-console.md"
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N1:V-N1-aaaa1111:cachyos-x8664-pid111111:111`' \
    '  `N2:V-N2-bbbb2222:cachyos-x8664-pid222222:222`' \
    '  `N3:V-N3-cccc3333:cachyos-x8664-pid333333:333`' \
    '  `N4:V-N4-dddd4444:cachyos-x8664-pid444444:444`' \
    '  `N5:V-N5-9999aaaa:cachyos-x8664-pid555555:555`' \
    '  `N6:V-N6-eeee5555:cachyos-x8664-pid666666:666`' \
    '  `N7:V-N7-ffff6666:cachyos-x8664-pid777777:777`' \
    'queue: N1 (3340), N2 (3340)' \
    'last GO: `1022:a87f5d946d8b4002ae9641864f82cffb1ac8a4b7`' \
    'acked: none' \
    'epics: HIMMEL-3332=4' \
    'decisions: ship the Telegram bridge restart?; widen the fleet cap to 20?' \
    '' '## Results (newest at the bottom)' \
    '- DISPATCH N1 — token `V-N1-aaaa1111`, lock `cachyos-x8664-pid111111`, window 5' \
    '- lock cachyos-x8664-pid830420 was released at wrap; the console doc alone keeps it' \
    '- RULING <b>bold</b> & ampersand' \
    > "$DOC"

run() {  # run <extra args...> -- prints board.mjs stdout; rc in $rc
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" \
        node "$SUT" --doc "$DOC" --repo "$W/repo" "$@" 2>"$W/stderr.log"
}

out="$(run)"; rc=$?
board="$B/console-board.html"
if [ "$rc" -eq 0 ] && [ "$out" = "$board" ] && [ -f "$board" ]; then
    pass 'prints the path of console-board.html written next to the console doc'
else
    fail "board path (rc=$rc out='$out' stderr=$(cat "$W/stderr.log" 2>/dev/null))"
fi
html="$(cat "$board" 2>/dev/null)"

# --- secrets: a board is published to a URL, so no nonce or lock token may reach it
for secret in aaaa1111 bbbb2222 cccc3333 dddd4444 eeee5555 ffff6666 pid111111 pid222222 pid333333 pid830420 'V-N1-' 'x8664'; do
    lacks "no nonce/lock-token text in the board: $secret" "$html" "$secret"
done
contains 'the legs are named by label' "$html" 'data-label="N3"'

# --- escaping: leg bullets and Results are prose from other sessions
lacks 'a <script> in a leg bullet is escaped' "$html" '<script>alert(1)'
contains 'the escaped script text is still visible' "$html" '&lt;script&gt;alert(1)'
lacks 'a <b> in a Results bullet is escaped' "$html" '<b>bold</b>'

# --- phases: LIVE -> READY-TO-OPEN -> PR open -> READY -> MERGED -> WRAPPED
contains 'no PR, no marker: LIVE' "$html" 'data-label="N1" data-phase="LIVE"'
contains 'an open PR the leg names: PR open' "$html" 'data-label="N2" data-phase="PR open"'
contains 'READY tail + open PR: READY' "$html" 'data-label="N3" data-phase="READY"'
contains 'the leg names a merged PR: MERGED' "$html" 'data-label="N4" data-phase="MERGED"'
contains 'lock released + WRAPPED tail: WRAPPED' "$html" 'data-label="N5" data-phase="WRAPPED"'
contains 'READY tail with no PR anywhere: READY-TO-OPEN' "$html" 'data-label="N6" data-phase="READY-TO-OPEN"'
contains 'a CI-red PR is flagged on its leg' "$html" 'data-ci="failing"'
contains 'a green PR reads green' "$html" 'data-ci="green"'
contains 'the phase ladder counts legs per phase' "$html" 'data-ladder="READY" data-count="1"'

# --- attention: what needs the console, and the operator's own decisions
contains 'a BLOCKED leg is listed as needing the console' "$html" 'data-need="N7"'
contains 'a READY leg awaits GO' "$html" 'data-need="N3"'
contains 'the Live-state decisions: line renders as open operator decisions' "$html" 'widen the fleet cap to 20?'

# --- epics: merged/total from the declared total + the merged PRs citing the key
contains 'a declared epic shows merged/total' "$html" 'data-epic="HIMMEL-3332" data-merged="2" data-total="4"'
lacks 'a PR that only mentions the key in prose is not counted' "$html" 'data-merged="3"'

# --- fleet: N/cap with idle capacity highlighted
contains 'fleet renders N/cap' "$html" 'data-fleet="9/15"'
contains 'idle capacity is highlighted' "$html" 'data-idle="6"'

# --- merged this shift + fingerprint + title
contains 'merged PRs this shift are listed' "$html" '#1995'
contains 'the tick fingerprint is embedded for tick.sh board=' "$html" '<meta name="console-board-fp" content="deadbeefdeadbeef">'
contains 'the page has a name title, not a summary' "$html" '<title>Console Board</title>'
contains 'the page themes for dark mode' "$html" 'prefers-color-scheme: dark'

# --- tick input: the console's own arm (absolute leg docs), no token, no heartbeat
argv="$(cat "$W/argv.log" 2>/dev/null)"
contains 'tick is asked for the fingerprint' "$argv" '--emit-fp'
contains 'tick reads the console doc' "$argv" "--doc $DOC"
contains 'leg docs are discovered by label from the bucket' "$argv" "$B/HIMMEL-3332-N3-gamma-2026-09-21-RESUME.md"
lacks 'a board render never passes the console token (no heartbeat)' "$argv" '--token'
run --legs "$B/HIMMEL-3340-N1-alpha-2026-09-21-RESUME.md" >/dev/null
contains 'an explicit --legs is passed through, not re-discovered' "$(cat "$W/argv.log")" "--legs $B/HIMMEL-3340-N1-alpha-2026-09-21-RESUME.md"
lacks 'an explicit --legs is not widened by discovery' "$(cat "$W/argv.log")" 'N3-gamma'

# --- degraded: a failing tick still leaves a board, marked as such (fp empty)
out="$(TICK_STUB_FAIL=1 run)"; rc=$?
contains 'a failing tick still renders a board (rc 0)' "rc=$rc" 'rc=0'
contains 'and says the tick was unavailable' "$(cat "$board")" 'tick unavailable'
lacks 'and embeds no fingerprint that would read ok' "$(cat "$board")" 'name="console-board-fp" content="deadbeef'

# --- usage
PATH="$W/bin:$PATH" node "$SUT" >/dev/null 2>&1; rc=$?
contains 'no --doc is a usage error (rc 2)' "rc=$rc" 'rc=2'
PATH="$W/bin:$PATH" node "$SUT" --doc "$B/nope.md" >/dev/null 2>&1; rc=$?
contains 'a missing console doc is an error (rc 1)' "rc=$rc" 'rc=1'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-board.sh'
    exit 0
fi
printf 'FAIL - test-board.sh (%s failure(s))\n' "$fails"
exit 1
