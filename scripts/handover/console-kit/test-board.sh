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
same() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

B="$W/bucket"
mkdir -p "$B" "$W/bin" "$W/repo"

# The tick stub records its argv and prints a fixed line + fingerprint. N1..N7
# cover every phase; the fleet is 9/15 with six idle slots. N12 (issue #1336):
# tail=FINDING with a lock reported lost at the same time -- the tick reports
# both independently of any leg-doc prose.
cat > "$W/bin/tick-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TICK_ARGV_LOG"
[ "${TICK_STUB_FAIL:-0}" -eq 0 ] || exit 1
printf '%s\n' 'TICK 12:34 hb=skip legs=N1:FRESH,N2:FRESH,N3:FRESH,N4:FRESH,N5:WRAPPED,N6:FRESH,N7:FRESH,N12:STALE livestate=ok procs=6 models=sonnet:6 ceiling=ok atq=0 suites=0alive/0dead prs=#2001,#2002 bank=5h8/wk42/codex=? fill=28 tails=N1:LIVE,N2:LIVE,N3:READY,N4:LIVE,N5:WRAPPED,N6:READY,N7:BLOCKED,N12:FINDING inbox=none tick=UNKNOWN fleet='"${TICK_STUB_FLEET:-9/15}"' capacity=UNDERFILLED:6 gql=4321/13:00 orphans=none nonces=ok legset=ok board=MISSING'
printf '%s\n' 'board-fp=deadbeefdeadbeef'
STUB
chmod +x "$W/bin/tick-stub"

# gh stub: open PRs, merged PRs (this shift, and the per-epic search) and per-PR
# `pr view` state from files.
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "pr view "*) [ -f "$GH_VIEW/$3.json" ] && cat "$GH_VIEW/$3.json" || exit 1 ;;
    *"--state open"*) cat "$GH_OPEN" ;;
    *"--state merged"*"in:title"*) cat "$GH_EPIC" ;;
    *"--state merged"*) cat "$GH_MERGED" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$W/bin/gh"

# Sessions stub (Ask 3, HIMMEL-3745): sourced, then claude_sessions() is called, same as
# board.mjs invokes the real claude-sessions.sh. Empty by default -- no window is ever
# "still open" unless a test explicitly points BOARD_SESSIONS elsewhere. Never the real
# process census.
cat > "$W/bin/sessions-empty.sh" <<'STUB'
claude_sessions() { :; }
STUB

cat > "$W/open.json" <<'JSON'
[
 {"number":2001,"title":"feat(x): [HIMMEL-3332] slice S3","headRefName":"feat/himmel-3332-s3","isDraft":false,
  "statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"},{"conclusion":"SUCCESS","status":"COMPLETED"},{"state":"SUCCESS"}]},
 {"number":2002,"title":"feat(y): [HIMMEL-3340] verdict bar","headRefName":"feat/himmel-3340-bar","isDraft":false,
  "statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"},{"conclusion":"","status":"IN_PROGRESS"}]},
 {"number":2003,"title":"feat(v): [HIMMEL-3380] no checks yet","headRefName":"feat/himmel-3380","isDraft":false,"statusCheckRollup":[]}
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

# `gh pr view` answers for PRs the merged-this-shift panel does not list: 1700 merged
# long ago (outside the 24 h window), 1701 closed unmerged.
mkdir -p "$W/view"
printf '%s\n' '{"state":"MERGED"}' > "$W/view/1700.json"
printf '%s\n' '{"state":"CLOSED"}' > "$W/view/1701.json"

# Leg docs: the ticket key is the doc's leading token, the label its N<k>.
mkleg() {  # mkleg <name> <bullet>...
    local name="$1"; shift
    printf '%s\n' '# leg' '## Results' "$@" > "$B/$name-2026-09-21-RESUME.md"
}
# A lock token that straddles the 220-char clip must not survive as a fragment.
pad190="$(printf '%190s' '' | tr ' ' x)"
mkleg HIMMEL-3340-N1-alpha "- 12:00 LIVE — working ${pad190:0:176} lock cachyos-x8664-pid424242 after"
# A later section's bullet naming another (merged) PR must not overwrite the leg's PR.
printf '%s\n' '# leg' '## Results' '- 12:00 LIVE — PR 2002 open, watching CI' '' '## Notes' \
    '- 13:00 unrelated later-section bullet: see PR 1990 merged' \
    > "$B/HIMMEL-3340-N2-beta-2026-09-21-RESUME.md"
mkleg HIMMEL-3332-N3-gamma '- 12:00 LIVE — building' '- 12:10 READY 2001 0123456789abcdef GREEN'
mkleg HIMMEL-3348-N4-delta '- 12:00 MERGED #1995 → 0123abc'
mkleg HIMMEL-3300-N5-eps '- 12:00 WRAPPED — released'
mkleg HIMMEL-3350-N6-zeta '- 12:00 READY-TO-OPEN — /pr-check clean, not opened'
mkleg HIMMEL-3351-N7-eta '- 12:00 BLOCKED — the push was refused <script>alert(1)</script>'
mkleg HIMMEL-3370-N8-theta '- 12:00 LIVE — PR 1700 open, watching CI'
mkleg HIMMEL-3371-N9-iota '- 12:00 LIVE — PR 1701 open, watching CI'
# HIMMEL-3374: a bullet that merely CITES a PR is not the leg's PR. N10 has no PR of
# its own, so it keeps its phase; a citation in any form (#n, PR #n, PR n merged, a
# /pull/ URL) attributes nothing.
mkleg HIMMEL-3377-N10-lambda '- 12:00 LIVE — working' '- 12:20 FINDING scope-shrunk — #1995 (HIMMEL-3348, in the base) already shipped; see PR #1995 merged, PR 1995 merged, https://github.com/o/r/pull/1995'
mkleg HIMMEL-3378-N11-mu '- 12:00 LIVE — building; PR 1995 merged upstream, so #1995 is in the base'
# Regression (issue #1336): a leg whose LAST line is a long FINDING must not hide a
# lost/stale lock reported by the tick at the same time. The tick line above marks
# N12 tail=FINDING, lock=STALE; board.mjs must surface both, not just the FINDING.
pad180="$(printf '%180s' '' | tr ' ' q)"
mkleg HIMMEL-3379-N12-xi '- 12:00 LIVE — working' "- 12:30 FINDING ${pad180} needs a ruling"
# Two docs share a label; Live state names one by doc stem (N18) or by nonce (N19).
# The newer-by-mtime doc is the wrong one in both.
mkleg HIMMEL-3375-N18-iota '- 12:00 LIVE — the right doc'
mkleg HIMMEL-9998-N18-other '- 12:00 LIVE — a previous shift reused this label'
# shellcheck disable=SC2016  # backtick token, literal fixture text
printf '%s\n' '# leg' '> RETASK token `V-N19-cafe1919`' '## Results' '- 12:00 LIVE — the right doc' \
    > "$B/HIMMEL-3376-N19-kappa-2026-09-21-RESUME.md"
# The wrong doc quotes a LONGER token that merely starts with the entry nonce.
# shellcheck disable=SC2016  # backtick token, literal fixture text
mkleg HIMMEL-9997-N19-old '- 12:00 LIVE — a previous shift reused this label, token `V-N19-cafe1919zz`'
touch -d '2 hours ago' "$B/HIMMEL-3375-N18-iota-2026-09-21-RESUME.md" "$B/HIMMEL-3376-N19-kappa-2026-09-21-RESUME.md"  # gnu-ok: console kit is Linux-only

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
    '  `N8:V-N8-aaaa0808:cachyos-x8664-pid808080:808`' \
    '  `N9:V-N9-bbbb0909:cachyos-x8664-pid909090:909`' \
    '  `N10:V-N10-aaaa1010:cachyos-x8664-pid101010:1010`' \
    '  `N11:V-N11-bbbb1111:cachyos-x8664-pid111011:1011`' \
    '  `N12:V-N12-aaaa1212:cachyos-x8664-pid121212:1212`' \
    '  `N16_x.y-z:V-N16-aaaa1616:cachyos-x8664-pid161616:1616`' \
    '  `N15:V-N15-aaaa1515:cachyos-x8664-pid151515`' \
    '  `N17:V-N17-aaaa1717::1717`' \
    '  `HIMMEL-3375-N18-iota-2026-09-21-RESUME:V-N18-aaaa1818:cachyos-x8664-pid181818:1818`' \
    '  `N19:V-N19-cafe1919:cachyos-x8664-pid191919:1919`' \
    '- detail `N13:V-N13-aaaa1313:cachyos-x8664-pid131313:1313` is under the block, not in it' \
    'queue: N1 (3340), N2 (3340)' \
    'last GO: `1022:a87f5d946d8b4002ae9641864f82cffb1ac8a4b7`' \
    'acked: none' \
    'epics: HIMMEL-3332=4' \
    'decisions: ship the Telegram bridge restart?; widen the fleet cap to 20?' \
    '' '## Results (newest at the bottom)' \
    '- DISPATCH N1 — token `V-N1-aaaa1111`, lock `cachyos-x8664-pid111111`, window 5' \
    '- lock cachyos-x8664-pid830420 was released at wrap; the console doc alone keeps it' \
    '- DISPATCH AA-N1 — nonce AA-N1-abcdef12, stem form AB-HIMMEL-3340-N1-alpha-cafe0123 (two-letter consoles)' \
    '- RULING <b>bold</b> & ampersand' \
    > "$DOC"

run() {  # run <extra args...> -- prints board.mjs stdout; rc in $rc
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="${BOARD_SESSIONS:-$W/bin/sessions-empty.sh}" \
        GH_OPEN="${BOARD_TEST_GH_OPEN:-$W/open.json}" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
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
# HIMMEL-3369: a healthy lookup warns of nothing (the failure cases are pinned below).
lacks 'a healthy label lookup prints no stderr warning (HIMMEL-3369)' "$(cat "$W/stderr.log")" 'leg labels unavailable'
lacks 'a healthy label lookup renders no unavailable banner (HIMMEL-3369)' "$html" 'labels-unavailable'

# --- secrets: a board is published to a URL, so no nonce or lock token may reach it
for secret in aaaa1111 bbbb2222 cccc3333 dddd4444 eeee5555 ffff6666 pid111111 pid222222 pid333333 pid830420 pid4242 'V-N1-' 'x8664' abcdef12 cafe0123 'AA-N1-' aaaa0808 bbbb0909 aaaa1616 aaaa1313 aaaa1818 cafe1919 pid808080 pid181818 aaaa1212 pid121212; do
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
contains 'a FINDING bullet citing a merged PR keeps its phase and gets no PR (HIMMEL-3374)' "$html" '<b>N10</b> <span class="tk">HIMMEL-3377</span> <span class="ph">LIVE</span></div>'
contains 'a LIVE bullet citing a merged PR gets no PR either (HIMMEL-3374)' "$html" '<b>N11</b> <span class="tk">HIMMEL-3378</span> <span class="ph">LIVE</span></div>'
contains 'lock released + WRAPPED tail: WRAPPED' "$html" 'data-label="N5" data-phase="WRAPPED"'
contains 'READY tail with no PR anywhere: READY-TO-OPEN' "$html" 'data-label="N6" data-phase="READY-TO-OPEN"'
contains 'a CI-red PR is flagged on its leg' "$html" 'data-ci="failing"'
contains 'a green PR (check runs + a commit status) reads green' "$html" 'data-label="N3" data-phase="READY" data-ci="green"'
contains 'the phase ladder counts legs per phase' "$html" 'data-ladder="READY" data-count="1"'

# --- attention: what needs the console, and the operator's own decisions
contains 'a BLOCKED leg is listed as needing the console' "$html" 'data-need="N7"'
contains 'a READY leg awaits GO' "$html" 'data-need="N3"'
contains 'a READY-TO-OPEN leg awaits the console' "$html" 'data-need="N6"'
# Regression (issue #1336): a long FINDING tail must not hide a lock the tick
# reports lost in the same tick line. RED before the fix: board.mjs checked
# tail === 'FINDING' before lostLock, so the lock text never rendered.
contains 'a FINDING leg with a lost lock still shows the lock (issue #1336)' "$html" '<b>N12</b> FINDING — needs a ruling · lock STALE — lost or stale'
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

# --- HIMMEL-3366: the follow-ups deferred from the first board
# Results parse is section-bounded: a later section's bullet is not the leg's Results.
lacks "a later section's bullet is not the leg's last Results bullet" "$html" 'unrelated later-section'
# Merged detection reads the PR itself, not the 24 h merged panel.
contains 'a PR merged outside the 24 h panel still reads MERGED (gh pr view)' "$html" 'data-label="N8" data-phase="MERGED"'
contains 'a closed-unmerged PR does not read MERGED' "$html" 'data-label="N9" data-phase="LIVE"'
# READY-TO-OPEN says what it is waiting for, not "lost lock".
contains 'a READY-TO-OPEN leg is explained as awaiting the PR open' "$html" 'awaiting PR open'
lacks 'a READY-TO-OPEN leg with a fresh lock is not called lost or stale' "$html" 'lock FRESH — lost or stale'
# A PR with no checks yet is not green.
contains 'an empty check rollup reads pending, not green' "$html" '<li data-ci="pending"><b>#2003</b>'
# The legs: block reads exactly as tick.sh's grammar: four non-empty fields, the
# tick's label class, every terminator.
contains 'a label with _ . - is a leg (tick label class)' "$html" 'data-label="N16_x.y-z"'
lacks 'a detail bullet under the block adds no phantom leg' "$html" 'data-label="N13"'
lacks 'a three-field span is not an entry' "$html" 'data-label="N15"'
lacks 'a span with an empty field is not an entry' "$html" 'data-label="N17"'
# Leg-doc discovery follows the leg's identity, not label + mtime alone.
contains 'a doc stem in Live state resolves that exact doc' "$html" '<b>N18</b> <span class="tk">HIMMEL-3375</span>'
contains 'a reused label resolves to the doc holding the entry nonce' "$html" '<b>N19</b> <span class="tk">HIMMEL-3376</span>'

# --- HIMMEL-3369: a failed leg-label lookup is visible, not an empty fleet. The
# BOARD_LEGID seam points at a helper that fails, or labels fewer names than asked.
printf '%s\n' 'return 3' > "$W/legid-fail.sh"
BOARD_LEGID="$W/legid-fail.sh" run --out "$W/fail-board.html" >/dev/null; rc=$?
failhtml="$(cat "$W/fail-board.html" 2>/dev/null)"
failerr="$(cat "$W/stderr.log")"
contains 'a failing label lookup still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a failing label lookup warns on stderr' "$failerr" 'leg labels unavailable'
contains 'a failing label lookup names why' "$failerr" 'the lookup failed'
contains 'a failing label lookup renders the unavailable banner' "$failhtml" 'data-banner="labels-unavailable"'
TICK_STUB_FAIL=1 BOARD_LEGID="$W/legid-fail.sh" run --out "$W/fail-empty-board.html" >/dev/null
failemptyhtml="$(cat "$W/fail-empty-board.html" 2>/dev/null)"
contains 'a failing lookup with no tick legs says so in the Legs panel, not "no legs"' "$failemptyhtml" '<p class="none">leg labels unavailable</p>'
lacks 'a failing lookup with no tick legs does not claim no legs' "$failemptyhtml" 'no legs'

# One label for three names: the first leg still renders, the shortfall is reported.
# shellcheck disable=SC2016  # the helper body is literal, evaluated by the board's bash
printf '%s\n' 'leg_label() { [ "$1" = N1 ] && printf N1; }' > "$W/legid-short.sh"
BOARD_LEGID="$W/legid-short.sh" run --out "$W/short-board.html" >/dev/null; rc=$?
shorthtml="$(cat "$W/short-board.html" 2>/dev/null)"
shorterr="$(cat "$W/stderr.log")"
contains 'a short label lookup still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a short label lookup warns with the shortfall' "$shorterr" 'returned 1 of'
contains 'a short label lookup renders the unavailable banner' "$shorthtml" 'data-banner="labels-unavailable"'
contains 'a short label lookup keeps the legs it did label' "$shorthtml" 'data-label="N1"'
lacks 'a short label lookup does not claim no legs' "$shorthtml" 'no legs'

# --- HIMMEL-3745 (Ask 3): a WRAPPED leg whose claude window is still alive is its
# own needs-the-console state, derived from an independent process census -- never
# from tick.sh's procs= (which only counts HELD legs). N5 is the fixture's one
# WRAPPED leg (doc stem HIMMEL-3300-N5-eps-2026-09-21); leg_identity() derives its
# undated session name HIMMEL-3300-N5-eps.
cat > "$W/bin/sessions-n5-alive.sh" <<'STUB'
claude_sessions() { printf '999\tHIMMEL-3300-N5-eps\tsonnet\ton\n'; }
STUB
out="$(BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/n5-alive-board.html")"; rc=$?
n5html="$(cat "$W/n5-alive-board.html" 2>/dev/null)"
contains 'a WRAPPED leg with a live census match reads WRAPPED, window still open' "$n5html" 'data-label="N5" data-phase="WRAPPED, window still open"'
contains 'it is listed as needing the console' "$n5html" 'data-need="N5"'
contains 'the need row explains why' "$n5html" 'WRAPPED, window still open — close the leg window'

# No census match (the default empty stub the suite already uses throughout):
# N5 stays plain WRAPPED, as pinned above at line 212. (The ladder itself always
# lists the 'WRAPPED, window still open' phase, at count 0 here -- check the leg's
# own data-phase, not a bare substring of the whole page.)
lacks 'a WRAPPED leg with no census match is never flagged as still open' "$html" 'data-label="N5" data-phase="WRAPPED, window still open"'

# Census unavailable (the sourced helper itself fails): never read as "nothing is
# running" -- falls back to plain WRAPPED, same as no match.
cat > "$W/bin/sessions-fail.sh" <<'STUB'
claude_sessions() { return 1; }
STUB
out="$(BOARD_SESSIONS="$W/bin/sessions-fail.sh" run --out "$W/n5-census-fail-board.html")"; rc=$?
n5failhtml="$(cat "$W/n5-census-fail-board.html" 2>/dev/null)"
contains 'an unavailable census still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'and leaves the WRAPPED leg as plain WRAPPED' "$n5failhtml" 'data-label="N5" data-phase="WRAPPED"'
lacks 'never flags "still open" on a census it could not read' "$n5failhtml" 'data-label="N5" data-phase="WRAPPED, window still open"'

# --- HIMMEL-3745 (Ask 1): --changed re-renders and reports whether the render moved,
# so a console can call ONE kit command after every Live-state mutation; the Artifact
# publish stays a separate model step.
rm -f "$W/changed-board.html"
out1="$(run --out "$W/changed-board.html" --changed)"; rc1=$?
same '--changed on the first render (nothing to compare against) reports CHANGED' "$out1" "CHANGED $W/changed-board.html"
contains '--changed rc is still 0' "rc=$rc1" 'rc=0'
out2="$(run --out "$W/changed-board.html" --changed)"
same '--changed on an identical re-render reports UNCHANGED' "$out2" "UNCHANGED $W/changed-board.html"
out3="$(TICK_STUB_FAIL=1 run --out "$W/changed-board.html" --changed)"
same '--changed after tick goes unavailable (fp now empty, prior fp was real) reports CHANGED' "$out3" "CHANGED $W/changed-board.html"

# --- HIMMEL-3745 (Ask 3 x Ask 1): the WRAPPED-window census is read independently
# of tick's --emit-fp, so a window opening on an otherwise-unchanged tick
# fingerprint must still flip --changed to CHANGED.
rm -f "$W/changed-census-board.html"
out4="$(run --out "$W/changed-census-board.html" --changed)"; rc4=$?
same 'census --changed: first render reports CHANGED' "$out4" "CHANGED $W/changed-census-board.html"
contains 'census --changed: rc is still 0' "rc=$rc4" 'rc=0'
out5="$(BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/changed-census-board.html" --changed)"
same 'a WRAPPED leg gaining a live window flips CHANGED although tick-fp is unchanged' "$out5" "CHANGED $W/changed-census-board.html"
out6="$(BOARD_SESSIONS="$W/bin/sessions-n5-alive.sh" run --out "$W/changed-census-board.html" --changed)"
same 'the same still-open leg on a re-render reports UNCHANGED' "$out6" "UNCHANGED $W/changed-census-board.html"

# --- HIMMEL-3768: tick keeps CI colour and fleet capacity out of board-fp on purpose,
# but the page SHOWS them, so --changed folds a signature of those cells in separately.
rm -f "$W/changed-cf.html"
run --out "$W/changed-cf.html" --changed >/dev/null
same 'ci/fleet --changed: an identical re-render reports UNCHANGED' "$(run --out "$W/changed-cf.html" --changed)" "UNCHANGED $W/changed-cf.html"
sed 's/"conclusion":"FAILURE"/"conclusion":"SUCCESS"/' "$W/open.json" > "$W/open-ci-moved.json"
same 'only a PR CI colour moving (failing to pending) flips --changed' "$(BOARD_TEST_GH_OPEN="$W/open-ci-moved.json" run --out "$W/changed-cf.html" --changed)" "CHANGED $W/changed-cf.html"
same 'and the moved CI colour, re-rendered again, reads UNCHANGED' "$(BOARD_TEST_GH_OPEN="$W/open-ci-moved.json" run --out "$W/changed-cf.html" --changed)" "UNCHANGED $W/changed-cf.html"
same 'only fleet capacity moving flips --changed' "$(BOARD_TEST_GH_OPEN="$W/open-ci-moved.json" TICK_STUB_FLEET=10/15 run --out "$W/changed-cf.html" --changed)" "CHANGED $W/changed-cf.html"
contains 'the tick fingerprint meta is still exactly tick'"'"'s' "$(cat "$W/changed-cf.html")" '<meta name="console-board-fp" content="deadbeefdeadbeef">'

# --- HIMMEL-3856: `versions: v1.0.0, v1.0.1` renders one Release panel per fixVersion,
# from ONE stubbed Jira CLI call per version (BOARD_JIRA seam, mirrors BOARD_TICK). The
# stub answers from $JIRA_DIR/<version>.tsv in the CLI's `list --labels` row format
# (key, type, status, title, labels; tab-separated) and never touches Jira.
JD="$W/jira"
mkdir -p "$JD"
cat > "$W/bin/jira-stub" <<'STUB'
#!/usr/bin/env bash
printf 'project=%s args=%s\n' "${JIRA_PROJECT_KEY:-}" "$*" >> "$JIRA_ARGV_LOG"
[ "${JIRA_STUB_FAIL:-0}" -eq 0 ] || exit 1
v="$(printf '%s' "$*" | sed -n 's/.*fixVersion = "\([^"]*\)".*/\1/p')"  # gnu-ok: console kit is Linux-only
[ -f "$JIRA_DIR/$v.tsv" ] && cat "$JIRA_DIR/$v.tsv" || exit 1
STUB
chmod +x "$W/bin/jira-stub"
T="$(printf '\t')"
write_v100() {  # write_v100 <done count: 3 or 4>
    {
        printf 'HIMMEL-9001%sBug%sIn Progress%sfix the blocker cachyos-x8664-pid777777 now%sci,v1-blocker\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9002%sTask%sTo Do%snot a blocker%sci\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9003%sTask%sTo Do%sblocker two%sv1-blocker\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9004%sTask%sDone%sshipped a%sv1-blocker\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9005%sTask%sDone%sshipped b%s\n' "$T" "$T" "$T" "$T"
        printf 'HIMMEL-9006%sTask%sDone%sshipped c%sv1-blocker\n' "$T" "$T" "$T" "$T"
        [ "$1" -lt 4 ] || printf 'HIMMEL-9007%sTask%sDone%sshipped d%s\n' "$T" "$T" "$T" "$T"
    } > "$JD/v1.0.0.tsv"
}
write_v100 3
{
    printf 'HIMMEL-9101%sTask%sDone%sfirst%s\n' "$T" "$T" "$T" "$T"
    printf 'HIMMEL-9102%sTask%sTo Do%ssecond%sv1-blocker\n' "$T" "$T" "$T" "$T"
} > "$JD/v1.0.1.tsv"
DOCV="$B/HIMMEL-nextleg-2026-09-21V-console-v.md"
sed 's/^epics: .*/&\nversions: v1.0.0, v1.0.1/' "$DOC" > "$DOCV"  # gnu-ok: console kit is Linux-only
runv() {  # runv <extra args...> -- like run, on the console doc that carries a versions: line
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" BOARD_JIRA="${BOARD_JIRA:-$W/bin/jira-stub}" \
        JIRA_ARGV_LOG="$W/jira-argv.log" JIRA_DIR="$JD" JIRA_PROJECT_KEY=HIMMEL \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$DOCV" --repo "$W/repo" "$@" 2>"$W/stderr.log"
}
rm -f "$W/jira-argv.log"
runv --out "$W/v-board.html" >/dev/null; rc=$?
vhtml="$(cat "$W/v-board.html" 2>/dev/null)"
jargv="$(cat "$W/jira-argv.log" 2>/dev/null)"
contains 'a versions: line still renders a board (rc 0)' "rc=$rc" 'rc=0'
contains 'each version renders done/total' "$vhtml" 'data-release="v1.0.0" data-done="3" data-total="6"'
contains 'the second version renders its own counts' "$vhtml" 'data-release="v1.0.1" data-done="1" data-total="2"'
contains 'the panel is titled Release <version>' "$vhtml" '<h2>Release v1.0.0</h2>'
contains 'an open v1-blocker ticket is listed with its key' "$vhtml" 'data-blocker="HIMMEL-9001"'
contains 'a listed blocker shows its status' "$vhtml" '<span class="pr">In Progress</span>'
contains 'a second open blocker is listed' "$vhtml" 'data-blocker="HIMMEL-9003"'
lacks 'an open ticket without the v1-blocker label is not listed' "$vhtml" 'HIMMEL-9002'
lacks 'a done v1-blocker ticket is not listed as a blocker' "$vhtml" 'HIMMEL-9004'
lacks 'a lock token in a blocker title is redacted' "$vhtml" 'pid777777'
contains 'the versions fingerprint meta is present' "$vhtml" 'console-board-versions-fp'
same 'one Jira call per version' "$(printf '%s\n' "$jargv" | grep -c .)" '2'
contains 'the CLI is asked by fixVersion JQL' "$jargv" 'fixVersion = "v1.0.0"'
contains 'the CLI is asked for labels' "$jargv" '--labels'
contains 'the CLI is asked for a high limit' "$jargv" '--limit 1000'
contains 'JIRA_PROJECT_KEY comes from the environment' "$jargv" 'project=HIMMEL'

# A failing CLI reads unavailable per version and never fails the render.
JIRA_STUB_FAIL=1 runv --out "$W/v-fail-board.html" >/dev/null; rc=$?
vfail="$(cat "$W/v-fail-board.html" 2>/dev/null)"
contains 'a failing Jira CLI still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a failing Jira CLI reads unavailable' "$vfail" 'data-release="v1.0.0" data-unavailable="1"'
lacks 'a failing Jira CLI fabricates no counts' "$vfail" 'data-done='
# A missing CLI (nothing at the seam path) reads unavailable too.
BOARD_JIRA="$W/bin/no-such-jira" runv --out "$W/v-missing-board.html" >/dev/null; rc=$?
contains 'a missing Jira CLI still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a missing Jira CLI reads unavailable' "$(cat "$W/v-missing-board.html")" 'data-release="v1.0.0" data-unavailable="1"'

# No versions: line -> nothing extra, and Jira is never called.
rm -f "$W/jira-argv.log"
JIRA_ARGV_LOG="$W/jira-argv.log" BOARD_JIRA="$W/bin/jira-stub" run --out "$W/nov-board.html" >/dev/null
lacks 'no versions: line renders no Release panel' "$(cat "$W/nov-board.html")" 'data-release'
lacks 'no versions: line renders no release fingerprint' "$(cat "$W/nov-board.html")" 'console-board-versions-fp'
if [ ! -e "$W/jira-argv.log" ]; then pass 'no versions: line makes no Jira call'; else fail 'no versions: line made a Jira call'; fi

# The version rows fold into --changed: a count moving flips it, an identical render does not.
rm -f "$W/v-changed.html"
vc1="$(runv --out "$W/v-changed.html" --changed)"
same 'versions --changed: first render reports CHANGED' "$vc1" "CHANGED $W/v-changed.html"
vc2="$(runv --out "$W/v-changed.html" --changed)"
same 'versions --changed: an identical re-render reports UNCHANGED' "$vc2" "UNCHANGED $W/v-changed.html"
write_v100 4
vc3="$(runv --out "$W/v-changed.html" --changed)"
same 'a done count moving flips --changed although tick-fp is unchanged' "$vc3" "CHANGED $W/v-changed.html"
contains 'the tick fingerprint meta is left as tick computed it' "$(cat "$W/v-changed.html")" '<meta name="console-board-fp" content="deadbeefdeadbeef">'
vc4="$(JIRA_STUB_FAIL=1 runv --out "$W/v-changed.html" --changed)"
same 'the CLI going unavailable flips --changed' "$vc4" "CHANGED $W/v-changed.html"
# A blocker retitled in Jira changes what the panel shows, so it flips --changed too.
runv --out "$W/v-changed.html" --changed >/dev/null
sed -i 's/fix the blocker/renamed blocker/' "$JD/v1.0.0.tsv"  # gnu-ok: console kit is Linux-only
vc5="$(runv --out "$W/v-changed.html" --changed)"
same 'a retitled blocker flips --changed' "$vc5" "CHANGED $W/v-changed.html"
# A partial answer (one row that does not parse among valid ones) is not complete totals.
write_v100 3
printf 'garbled line without tabs\n' >> "$JD/v1.0.0.tsv"
runv --out "$W/v-partial.html" >/dev/null; rc=$?
vpart="$(cat "$W/v-partial.html" 2>/dev/null)"
contains 'a partial Jira answer still renders the board (rc 0)' "rc=$rc" 'rc=0'
contains 'a partial Jira answer reads unavailable, not short totals' "$vpart" 'data-release="v1.0.0" data-unavailable="1"'
contains 'a clean version beside a partial one still renders' "$vpart" 'data-release="v1.0.1" data-done="1" data-total="2"'
# A row without the labels column (the CLI with --labels always emits it) would hide blockers.
write_v100 3
printf 'HIMMEL-9008%sTask%sTo Do%sno labels column\n' "$T" "$T" "$T" >> "$JD/v1.0.0.tsv"
runv --out "$W/v-nolabels.html" >/dev/null
contains 'a row missing the labels column reads unavailable' "$(cat "$W/v-nolabels.html" 2>/dev/null)" 'data-release="v1.0.0" data-unavailable="1"'

# --- HIMMEL-3988: with no --legs, the leg set is the console's fleet manifest
# (<console doc stem>.fleet.json, read through fleet-manifest.sh list -- the same
# validation tick --legs-from uses); no manifest keeps the RESUME-doc scan; an
# explicit --legs wins; a manifest change moves --changed (the tick stub's
# fingerprint is constant, so only board.mjs's own manifest signature can).
M="$W/mf"
mkdir -p "$M"
printf '%s\n' '# console' '## Live state' 'epics: none' '' '## Results' > "$M/console-m.md"
for n in 901 902; do printf '%s\n' "# leg N$n" '## Results' '- 10:00 LIVE — working' > "$M/HIMMEL-9$n-N$n-x-RESUME.md"; done
MDOC="$M/console-m.md"
MFLEET="$M/console-m.fleet.json"
mrun() {
    PATH="$W/bin:$PATH" BOARD_TICK="$W/bin/tick-stub" TICK_ARGV_LOG="$W/argv.log" \
        BOARD_SESSIONS="$W/bin/sessions-empty.sh" \
        GH_OPEN="$W/open.json" GH_MERGED="$W/merged.json" GH_EPIC="$W/epic.json" GH_VIEW="$W/view" \
        node "$SUT" --doc "$MDOC" --repo "$W/repo" --out "$M/board.html" "$@" 2>"$W/stderr.log"
}
mrun >/dev/null
lacks 'no manifest: tick gets no --legs (the RESUME-doc scan stays the fallback, HIMMEL-3988)' "$(cat "$W/argv.log")" "$M/HIMMEL-9901"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N901","added":"2026-10-01T00:00:00Z"}]}\n' "$M/HIMMEL-9901-N901-x-RESUME.md" > "$MFLEET"
mrun --changed >/dev/null
contains 'manifest present: tick is armed with the manifest legs (HIMMEL-3988)' "$(cat "$W/argv.log")" "--legs $M/HIMMEL-9901-N901-x-RESUME.md"
lacks 'manifest present: a RESUME doc it does not list is not armed (HIMMEL-3988)' "$(cat "$W/argv.log")" 'HIMMEL-9902'
contains 'manifest present: the listed leg is on the board' "$(cat "$M/board.html")" 'data-label="N901"'
same 'manifest unchanged: --changed reports UNCHANGED' "$(mrun --changed)" "UNCHANGED $M/board.html"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N901"},{"doc":"%s","label":"N902"}]}\n' "$M/HIMMEL-9901-N901-x-RESUME.md" "$M/HIMMEL-9902-N902-x-RESUME.md" > "$MFLEET"
same 'manifest gained a leg: --changed reports CHANGED (HIMMEL-3988)' "$(mrun --changed)" "CHANGED $M/board.html"
mrun --legs "$M/HIMMEL-9902-N902-x-RESUME.md" >/dev/null
contains 'an explicit --legs wins over the manifest' "$(cat "$W/argv.log")" "--legs $M/HIMMEL-9902-N902-x-RESUME.md"
lacks 'an explicit --legs wins over the manifest (manifest leg not armed)' "$(cat "$W/argv.log")" 'HIMMEL-9901'
printf '%s\n' 'not json' > "$MFLEET"
mrun >/dev/null; rc=$?
contains 'an invalid manifest falls back to the scan, rc 0' "rc=$rc" 'rc=0'
contains 'an invalid manifest is reported on stderr, not silently ignored' "$(cat "$W/stderr.log")" 'fleet manifest'

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
