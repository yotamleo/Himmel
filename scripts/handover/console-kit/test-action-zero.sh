#!/usr/bin/env bash
# test-action-zero.sh — HIMMEL-4902. Exercises action-zero.sh: the incoming
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
printf '#!/usr/bin/env bash\necho "doctor crashed"\nexit 4\n' > "$WORK/doctor-bad.sh"
out4="$(ACTION_ZERO_DOCTOR="$WORK/doctor-bad.sh" bash "$AZ" --doc "$DOC" --root "$ROOT" 2>&1)"
check "a failed doctor reads unavailable, not none" "1" "$(printf '%s\n' "$out4" | sed -n '/^== C29/,/^== LOAD/p' | grep -c '^unavailable')"
check "usage without --root exits 2" "2" "$(bash "$AZ" --doc "$DOC" >/dev/null 2>&1; echo $?)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
