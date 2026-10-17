#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-append-results.sh
# scripts/handover/console-kit/test-verdict-go.sh - suite for verdict-go.sh
# the one call from a judge verdict to the persisted verdict,
# GO, Results bullet and board. Every sub-script is a stub that logs its argv,
# so the suite pins ORDER, ARGUMENTS and EXIT-CODE PROPAGATION:
#   1. GO happy path: write-verdict -> go -> append-results -> board, in that
#      order, leg message printed
#   2. NO-GO: write-verdict + bullet only; go.sh and the leg message absent
#   3. go.sh refusal: its exit code passes through, the step is named, no
#      bullet, no board
#   4. --trust adds `--trust-reviewed <qid>` to go.sh; without it, absent
#   5. board render failure is non-fatal: exit 0, warning printed
#   6. write-verdict refusal: exit code passes through, go.sh never runs
#   7. usage: bad answer / missing --pr / short head -> exit 2, nothing runs
#   8. a residual line with no HIMMEL key or no-ticket reason -> exit 2, nothing runs
#
# Hermetic: temp dir only. Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/verdict-go.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/verdict-go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

# A sandbox kit: the script under test beside four stubs that log their argv.
KIT="$tmp/kit"; LOG="$tmp/log"; mkdir -p "$KIT"
cp "$SCRIPT" "$KIT/verdict-go.sh" 2>/dev/null || true
cp "$HERE/residual-lines.sh" "$KIT/residual-lines.sh" 2>/dev/null || true
for s in write-verdict go append-results; do
    cat > "$KIT/$s.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "$s" >> "$LOG"
for a in "\$@"; do printf ' [%s]' "\$a" >> "$LOG"; done
printf '\n' >> "$LOG"
case "$s" in
    write-verdict) exit "\${WV_RC:-0}" ;;
    go) echo "/fake/root/.locks/go/\$*"; exit "\${GO_RC:-0}" ;;
    *) exit "\${AR_RC:-0}" ;;
esac
EOF
done
cat > "$KIT/board.mjs" <<EOF
import { appendFileSync } from 'node:fs';
appendFileSync('$LOG', 'board ' + process.argv.slice(2).map((a) => '[' + a + ']').join(' ') + '\n');
process.exit(Number(process.env.BOARD_RC || 0));
EOF

HEAD40="0123456789abcdef0123456789abcdef01234567"
EV="/tmp/claude-$(id -u)/ev.md"
DOC="$tmp/console.md"; : > "$DOC"

run() { # run <args...> -> sets rc, out, log
    : > "$LOG"; rc=0
    out="$(bash "$KIT/verdict-go.sh" "$@" 2>&1)" || rc=$?
    log="$(cat "$LOG")"
}

# --- 1. GO happy path ------------------------------------------------------
run q1 GO "$HEAD40" --pr 77 --evidence-file "$EV" --leg N2033 --doc "$DOC"
check "1: rc 0" "$rc" 0
order="$(cut -d' ' -f1 "$LOG" | tr '\n' ',')"
check "1: order write-verdict,go,append-results,board" "$order" "write-verdict,go,append-results,board,"
contains "1: write-verdict gets qid answer head" "$log" "write-verdict [q1] [GO] [$HEAD40]"
contains "1: write-verdict gets --pr and --evidence-file" "$log" "[--pr] [77] [--evidence-file] [$EV]"
contains "1: go gets pr and head" "$log" "go [77] [$HEAD40]"
contains "1: bullet names qid, answer, pr and head8" "$log" "q1 answer: GO · GO 77 01234567"
contains "1: board is --changed on the doc" "$log" "board [--doc] [$DOC] [--changed]"
contains "1: leg message names the merge command" "$out" "merge-on-green.sh --jira-transition"
contains "1: leg message names the leg" "$out" "N2033"
contains "1: leg message carries GO pr head" "$out" "GO 77 $HEAD40"

# --- 2. NO-GO ---------------------------------------------------------------
run q2 NO-GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
check "2: rc 0" "$rc" 0
order="$(cut -d' ' -f1 "$LOG" | tr '\n' ',')"
check "2: write-verdict then append-results only" "$order" "write-verdict,append-results,"
lacks "2: go.sh never runs" "$log" "go ["
contains "2: bullet records NO-GO" "$log" "q2 answer: NO-GO"
lacks "2: no merge command printed" "$out" "merge-on-green.sh"

# --- 3. go.sh refusal propagates --------------------------------------------
GO_RC=4 run q3 GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
check "3: go.sh exit 4 passes through" "$rc" 4
contains "3: failing step named" "$out" "go.sh failed"
lacks "3: no bullet after a refusal" "$log" "append-results"
lacks "3: no board after a refusal" "$log" "board"

# --- 4. --trust adds --trust-reviewed <qid> ---------------------------------
run q4 GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC" --trust
contains "4: go gets --trust-reviewed qid" "$log" "go [--trust-reviewed] [q4] [77] [$HEAD40]"
run q4 GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
lacks "4: without --trust no flag" "$log" "--trust-reviewed"

# --- 5. board failure is non-fatal ------------------------------------------
BOARD_RC=1 run q5 GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
check "5: rc 0 despite board failure" "$rc" 0
contains "5: warning printed" "$out" "board render failed"
contains "5: leg message still printed" "$out" "merge-on-green.sh --jira-transition"

# --- 6. write-verdict refusal propagates ------------------------------------
WV_RC=3 run q6 GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
check "6: write-verdict exit 3 passes through" "$rc" 3
contains "6: failing step named" "$out" "write-verdict.sh failed"
lacks "6: go.sh never runs" "$log" "go ["

# --- 6b. append-results refusal propagates -----------------------------------
AR_RC=3 run q6b GO "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
check "6b: append-results exit 3 passes through" "$rc" 3
contains "6b: failing step named" "$out" "append-results.sh failed"
lacks "6b: no board after a bullet failure" "$log" "board"
lacks "6b: no leg message after a bullet failure" "$out" "merge-on-green.sh"

# --- 6c. --prior passes through to write-verdict only when given ----------------
run q6c NO-GO "$HEAD40" --pr 77 --evidence-file "$EV" --prior GO
check "6c: rc 0" "$rc" 0
contains "6c: write-verdict gets --prior GO" "$log" "[--evidence-file] [$EV] [--prior] [GO]"
run q6c NO-GO "$HEAD40" --pr 77 --evidence-file "$EV"
lacks "6c: without --prior the flag is absent" "$log" "--prior"
run q6c NO-GO "$HEAD40" --pr 77 --evidence-file "$EV" --prior
check "6c: --prior with no value rc 2" "$rc" 2
check "6c: --prior with no value ran nothing" "$(cat "$LOG")" ""

# --- 7. usage ----------------------------------------------------------------
run q7 MAYBE "$HEAD40" --pr 77 --evidence-file "$EV" --doc "$DOC"
check "7: bad answer rc 2" "$rc" 2
check "7: bad answer ran nothing" "$(cat "$LOG")" ""
run q7 GO "$HEAD40" --evidence-file "$EV" --doc "$DOC"
check "7: missing --pr rc 2" "$rc" 2
check "7: missing --pr ran nothing" "$(cat "$LOG")" ""
run q7 GO abc123 --pr 77 --evidence-file "$EV" --doc "$DOC"
check "7: short head rc 2" "$rc" 2
check "7: short head ran nothing" "$(cat "$LOG")" ""

# --- 8. residual lines must name a ticket or a no-ticket reason ---
EVR="$tmp/ev-residual.md"
printf '## Non-blocking\n\n- tighten the regex\n' > "$EVR"
run q8a GO "$HEAD40" --pr 77 --evidence-file "$EVR" --doc "$DOC"
check "8a: an unkeyed Non-blocking bullet rc 2" "$rc" 2
contains "8a: the offending line is printed" "$out" "unfiled residual: - tighten the regex"
contains "8a: the hint names no-ticket" "$out" "no-ticket: <reason>"
check "8a: nothing ran" "$(cat "$LOG")" ""  # read-sink-ok: the test's own sandbox log
printf 'Evidence read.\n\nresidual: x\n' > "$EVR"
run q8b NO-GO "$HEAD40" --pr 77 --evidence-file "$EVR"
check "8b: an unkeyed residual: line on a NO-GO rc 2" "$rc" 2
check "8b: nothing ran" "$(cat "$LOG")" ""  # read-sink-ok: the test's own sandbox log
printf '## Follow-ups\n\n- keyed HIMMEL-123 item\n- other item, no-ticket: operator accepted\n' > "$EVR"
run q8c GO "$HEAD40" --pr 77 --evidence-file "$EVR"
check "8c: keyed and no-ticket residuals rc 0" "$rc" 0
contains "8c: write-verdict ran" "$log" "write-verdict"
run q8d GO "$HEAD40" --pr 77 --evidence-file "$tmp/no-such-evidence.md"
contains "8d: an unreadable evidence file is left to write-verdict" "$log" "write-verdict"

[ "$fails" -eq 0 ] && echo "all ok" || { echo "$fails failure(s)"; exit 1; }
