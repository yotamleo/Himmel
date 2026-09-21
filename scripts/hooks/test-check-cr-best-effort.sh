#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-cr-best-effort.sh (HIMMEL-3360).
#
# CodeRabbit is best effort: a tracked line that names it AND schedules,
# queues or holds work on it is a violation. Exercises the guard's direct-file
# mode against hermetic fixtures. Case 1 is the RED control — the exact
# sentence a console derived on 2026-09-21 that held seven finished PRs.
#
# Usage: bash scripts/hooks/test-check-cr-best-effort.sh
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-cr-best-effort.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h3360.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

run() { bash "$GUARD" "$@" 2>&1; }

# Case 1 (RED control): the ruling that held seven PRs -> refused, file:line named
echo "== Case 1: 'CodeRabbit is 1/hour account-wide. Queue the opens' -> exit 1 =="
cat > "$tmp/c1.md" <<'EOF'
# Rulings
4. CodeRabbit is 1/hour account-wide. Queue the opens yourself; a push after create discards the review.
EOF
out=$(run "$tmp/c1.md"); rc=$?
if [ "$rc" -eq 1 ]; then pass "case 1 -> exit 1"; else fail "case 1 -> expected 1 got $rc" "$out"; fi
case "$out" in
    *"$tmp/c1.md:2 schedules or holds work on CodeRabbit"*) pass "case 1 -> message names file:line" ;;
    *) fail "case 1 -> message does not name file:line" "$out" ;;
esac

# Case 2: the rule itself, plus the hold vocabulary WITHOUT CodeRabbit on the line -> clean
echo "== Case 2: the best-effort rule and unrelated queue/slot prose -> exit 0 =="
cat > "$tmp/c2.md" <<'EOF'
CodeRabbit is best effort, not gating: the merge gate is CI green + zero
unresolved review threads + the /pr-check panel. A finding that exists blocks.
The console sequences legs into the hourly slot of the bank.
A PR goes through the merge queue once CodeRabbit posts nothing new.
Fill the value slot (coderabbit-1) from the ledger row.
EOF
out=$(run "$tmp/c2.md"); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 2 -> exit 0"; else fail "case 2 -> expected 0 got $rc" "$out"; fi

# Case 3: quoted history carrying the same-line marker -> clean
echo "== Case 3: 'cr-best-effort-ok:' marker on the line -> exit 0 =="
cat > "$tmp/c3.md" <<'EOF'
Old rule: wait for CodeRabbit, one review per hour. cr-best-effort-ok: quoting the retired ruling
EOF
out=$(run "$tmp/c3.md"); rc=$?
if [ "$rc" -eq 0 ]; then pass "case 3 -> exit 0"; else fail "case 3 -> expected 0 got $rc" "$out"; fi

# Case 4: several files, one violation among clean lines -> exit 1, exactly one report
echo "== Case 4: mixed files, one offending line -> exit 1 with one report =="
cat > "$tmp/c4a.sh" <<'EOF'
# CodeRabbit is one reviewer beside the panel; never a bottleneck.
# LEG_SUPPRESS_CR_TRIGGER: opt-out for the CodeRabbit auto-trigger hooks.
warn "not triggering CodeRabbit for this head; trigger manually once a slot is confirmed free"
EOF
out=$(run "$tmp/c2.md" "$tmp/c4a.sh"); rc=$?
if [ "$rc" -eq 1 ]; then pass "case 4 -> exit 1"; else fail "case 4 -> expected 1 got $rc" "$out"; fi
n=$(printf '%s\n' "$out" | grep -c 'schedules or holds work on CodeRabbit')
if [ "$n" -eq 1 ]; then pass "case 4 -> exactly one report (line 3)"; else fail "case 4 -> expected 1 report got $n" "$out"; fi

# Case 5: an unreadable file -> exit 2 (fail closed), not a silent pass
echo "== Case 5: missing file -> exit 2 =="
out=$(run "$tmp/does-not-exist.md"); rc=$?
if [ "$rc" -eq 2 ]; then pass "case 5 -> exit 2"; else fail "case 5 -> expected 2 got $rc" "$out"; fi

# Case 6: a directory passes the readability check but grep fails on it -> exit 2, not a silent pass
echo "== Case 6: directory argument -> exit 2 (grep execution error, not clean) =="
dir="$tmp/adir"
mkdir -p "$dir"
out=$(run "$dir"); rc=$?
if [ "$rc" -eq 2 ]; then pass "case 6 -> exit 2"; else fail "case 6 -> expected 2 got $rc" "$out"; fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
