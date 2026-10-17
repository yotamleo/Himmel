#!/usr/bin/env bash
# test-action-zero.sh — Exercises action-zero.sh: the incoming
# console's mechanical probes in one command. bank-preflight and himmel-doctor
# are stubbed (ACTION_ZERO_BANK / ACTION_ZERO_DOCTOR). bash 3.2-safe.
#
# ACTION_ZERO overrides the script under test (the RED control).
#
# Run: bash scripts/handover/console-kit/test-action-zero.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
AZ="${ACTION_ZERO:-$HERE/action-zero.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/action-zero-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"; mkdir -p "$ROOT"
DOC="$ROOT/DEMO-next-2026-10-08A-console.md"
echo "# console" > "$DOC"
printf '#!/usr/bin/env bash\necho "bank ok 12%%"\n' > "$WORK/bank.sh"
printf '#!/usr/bin/env bash\necho "C28 fine"\necho "C29 WARN CHILD_SESSION inherited"\n' > "$WORK/doctor.sh"
export ACTION_ZERO_BANK="$WORK/bank.sh" ACTION_ZERO_DOCTOR="$WORK/doctor.sh"

out="$(bash "$AZ" --doc "$DOC" --root "$ROOT" --prefix NOSUCHPREFIX 2>&1)"
for sec in LOCKS HEAD BANK PROCS C29 LOAD LOCK; do
    check "section $sec present" "1" "$(printf '%s\n' "$out" | grep -cE "^== $sec( |\$)")"
done
check "head sha printed" "1" "$(printf '%s\n' "$out" | grep -cE '^[0-9a-f]{40}$')"
check "bank output shown" "1" "$(printf '%s\n' "$out" | grep -c 'bank ok 12%')"
check "only the C29 line is kept" "0" "$(printf '%s\n' "$out" | grep -c 'C28 fine')"
check "C29 line is shown" "1" "$(printf '%s\n' "$out" | grep -c 'C29 WARN')"
check "no matching procs reads none" "1" "$(printf '%s\n' "$out" | sed -n '/^== PROCS/,/^== C29/p' | grep -c '^none')"
check "without --acquire no lock is taken" "0" "$(printf '%s\n' "$out" | grep -c 'release-token')"
check "no --acquire leaves the lock free" "1" "$(env HANDOVER_DIR="$ROOT" bash "$HERE/../queue-lock.sh" status "$DOC" 2>&1 | grep -ci 'free')"

out2="$(bash "$AZ" --doc "$DOC" --root "$ROOT" --acquire 2>&1)"
check "--acquire on a free lock prints the release token" "1" "$(printf '%s\n' "$out2" | grep -c 'release-token')"
out3="$(bash "$AZ" --doc "$DOC" --root "$ROOT" --acquire 2>&1)"
check "--acquire on a held lock does not take it over" "1" "$(printf '%s\n' "$out3" | grep -c 'NOT ACQUIRED')"
# a held lock whose status text merely contains the word "free" is not free
DOCF="$WORK/DEMO-freedom-console.md"; : > "$DOCF"
env HANDOVER_DIR="$ROOT" bash "$HERE/../queue-lock.sh" acquire "$DOCF" >/dev/null 2>&1
out5="$(bash "$AZ" --doc "$DOCF" --root "$ROOT" --acquire 2>&1)"
check "a held lock with 'free' in its text is not treated as free" "1" "$(printf '%s\n' "$out5" | grep -c 'NOT ACQUIRED')"
printf '#!/usr/bin/env bash\necho "doctor crashed"\nexit 4\n' > "$WORK/doctor-bad.sh"
out4="$(ACTION_ZERO_DOCTOR="$WORK/doctor-bad.sh" bash "$AZ" --doc "$DOC" --root "$ROOT" 2>&1)"
check "a failed doctor reads unavailable, not none" "1" "$(printf '%s\n' "$out4" | sed -n '/^== C29/,/^== LOAD/p' | grep -c '^unavailable')"
# the C29 step asks the doctor for C29 only (a full sweep took
# over 120 s on OVERLORD8 and printed TIMEOUT doctor). The real row is copied
# from a live run.
# shellcheck disable=SC2016 # the stub script body must keep its $ literal
printf '#!/usr/bin/env bash\necho "$*" > "%s"\nif [ "$1" = "--only" ] && [ "$2" = "C29" ]; then echo "OK   C29-child-session: no claude child-session launchers missing persistence"; fi\n' "$WORK/doctor-args.txt" > "$WORK/doctor-argv.sh"
out7="$(ACTION_ZERO_DOCTOR="$WORK/doctor-argv.sh" bash "$AZ" --doc "$DOC" --root "$ROOT" 2>&1)"
check "the C29 step runs the doctor with --only C29" "--only C29" "$(cat "$WORK/doctor-args.txt" 2>/dev/null)"
check "the C29 row reaches the summary" "1" "$(printf '%s\n' "$out7" | sed -n '/^== C29/,/^== LOAD/p' | grep -c 'OK   C29-child-session')"
check "usage without --root exits 2" "2" "$(bash "$AZ" --doc "$DOC" >/dev/null 2>&1; echo $?)"

# a hung probe is bounded, prints a stable TIMEOUT line, and the
# remaining sections still run. The stubs sleep as a grandchild (no exec), the
# shape that holds a $(...) pipe open if only the parent is killed.
# Resolved in a subshell: a source edge would pull check-ci-watch.sh into the lint set.
_TIMEOUT_BIN="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "$_TIMEOUT_BIN"' _ "$HERE/../../lib/timeout-bin.sh" 2>/dev/null)"
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    printf '#!/usr/bin/env bash\nsleep 30\necho late\n' > "$WORK/hang.sh"
    t0=$SECONDS
    out6="$(ACTION_ZERO_BANK="$WORK/hang.sh" ACTION_ZERO_DOCTOR="$WORK/hang.sh" ACTION_ZERO_BANK_TIMEOUT=1 ACTION_ZERO_DOCTOR_TIMEOUT=1 "$_TIMEOUT_BIN" -k 2 25 bash "$AZ" --doc "$DOC" --root "$ROOT" 2>&1)"
    el=$((SECONDS - t0))
    check "hung probes finish inside the bound" "1" "$([ "$el" -lt 15 ] && echo 1 || echo 0)"
    check "bank hang prints TIMEOUT bank after 1s" "1" "$(printf '%s\n' "$out6" | sed -n '/^== BANK/,/^== PROCS/p' | grep -c '^TIMEOUT bank after 1s$')"
    check "doctor hang prints TIMEOUT doctor after 1s" "1" "$(printf '%s\n' "$out6" | sed -n '/^== C29/,/^== LOAD/p' | grep -c '^TIMEOUT doctor after 1s$')"
    check "sections after a hang still run" "1" "$(printf '%s\n' "$out6" | grep -c '^== LOCK (this document)')"
else
    echo "SKIP: hang rows (no timeout binary)"
fi

# --render-legs writes the legs: line through live-state.sh (the lock tokens
# come from the held locks, the nonce is kept), instead of a hand edit
LDOC="$ROOT/DEMO-1-N61-a-2026-10-16.md"; : > "$LDOC"
LCON="$ROOT/DEMO-next-2026-10-16A-console.md"
# shellcheck disable=SC2016  # the backticks are literal span markers
printf '# console\n\n## Live state\nlegs: `N61:Z-N61-aa:stale-token:7`queue: none\nlast GO: none\n\n## Results\n' > "$LCON"
printf '{"schema": 1, "legs": [{"doc": "%s", "label": "N61", "lane": "native"}]}\n' "$LDOC" > "${LCON%.md}.fleet.json"
env HANDOVER_DIR="$ROOT" bash "$HERE/../queue-lock.sh" acquire "$LDOC" >/dev/null 2>&1
tok="$(env HANDOVER_DIR="$ROOT" bash "$HERE/../queue-lock.sh" status "$LDOC" 2>/dev/null | head -1 | jq -r '.session // empty')"
out8="$(bash "$AZ" --doc "$LCON" --root "$ROOT" 2>&1)"
check "without --render-legs the legs: line is not touched" "1" "$(grep -c 'stale-token' "$LCON")"
check "without --render-legs there is no LEGS section" "0" "$(printf '%s\n' "$out8" | grep -c '^== LEGS')"
out9="$(bash "$AZ" --doc "$LCON" --root "$ROOT" --render-legs 2>&1)"
check "--render-legs prints a LEGS section" "1" "$(printf '%s\n' "$out9" | grep -c '^== LEGS')"
check "the legs: line now carries the held lock token" "1" "$(grep -c "^legs: \`N61:Z-N61-aa:$tok:7\`" "$LCON")"
check "the nonce was kept, not rewritten" "0" "$(grep -c 'stale-token' "$LCON")"
check "the next field line is intact" "1" "$(grep -c '^last GO: none$' "$LCON")"
rm -f "${LCON%.md}.fleet.json"
out10="$(bash "$AZ" --doc "$LCON" --root "$ROOT" --render-legs 2>&1)"; rc10=$?
check "no fleet manifest: LEGS says unavailable and the run carries on" "1" "$(printf '%s\n' "$out10" | sed -n '/^== LEGS/,/^== LOCK/p' | grep -c '^unavailable')"
check "no fleet manifest: the run exits nonzero" "1" "$rc10"
printf 'not json\n' > "${LCON%.md}.fleet.json"
bash "$AZ" --doc "$LCON" --root "$ROOT" --render-legs >/dev/null 2>&1; rc11=$?
check "a render that fails exits nonzero" "1" "$rc11"
rm -f "${LCON%.md}.fleet.json"

# DOC is a digest of the supplied doc, not its instructions or result history.
DDOC="$ROOT/digest-console.md"
cat > "$DDOC" <<'DOC'
# console
**Status:** LIVE

## Live state
head: abc123
legs: `N61:nonce:lock:7`
  `N62:nonce-two:lock-two:8`
queue: held-doc.md
lock: console-lock

## Open rulings
- [ ] Approve the next slice
  PRIVATE ruling body
- [x] Closed decision
### Choose a lane
PRIVATE heading body
- PRIVATE ruling body list

## Results
PRIVATE result history
DOC
before_digest="$(cat "$DDOC")"
dout="$(bash "$AZ" --doc "$DDOC" --root "$ROOT" 2>&1)"
digest="$(printf '%s\n' "$dout" | awk '/^== DOC$/ {s=1; next} /^== / {s=0} s')"
# shellcheck disable=SC2016  # backticks are literal leg span markers
expected_digest='**Status:** LIVE
head: abc123
legs: `N61:nonce:lock:7` `N62:nonce-two:lock-two:8`
queue: held-doc.md
lock: console-lock
open rulings: 2
- Approve the next slice
- Choose a lane'
check "DOC digest contains state and open ruling titles only" "$expected_digest" "$digest"
check "DOC digest leaves the supplied document untouched" "$before_digest" "$(cat "$DDOC")"
awk '/^## Results$/ {for (i=1;i<=200;i++) print "- [ ] Decision " i} {print} END {for (i=1;i<=1000;i++) print "PRIVATE history " i}' "$DDOC" > "$ROOT/long-console.md"
long_out="$(bash "$AZ" --doc "$ROOT/long-console.md" --root "$ROOT" 2>&1)"
long_digest="$(printf '%s\n' "$long_out" | awk '/^== DOC$/ {s=1; next} /^== / {s=0} s')"
long_lines="$(printf '%s\n' "$long_digest" | wc -l | tr -d ' ')"
case "$long_digest" in *'open rulings: 202'*'additional ruling titles omitted'*) present=1 ;; *) present=0 ;; esac
check "DOC digest remains present and under 60 lines for a long document" 1 "$([ "$present" -eq 1 ] && [ "$long_lines" -lt 60 ] && echo 1 || echo 0)"
missing_out="$(bash "$AZ" --doc "$DOC" --root "$ROOT" 2>&1)"
check "missing Live state prints DOC unavailable and later sections still run" 2 "$(printf '%s\n' "$missing_out" | grep -cE '^DOC unavailable$|^== LOCK \(this document\)$')"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
