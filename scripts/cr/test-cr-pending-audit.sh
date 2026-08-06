#!/usr/bin/env bash
# shellcheck disable=SC2015
# Tests for cr/cr-pending-audit.sh (HIMMEL-1553). Each case builds a REAL temp
# git repo (the audit resolves everything from <git-common-dir>, mirroring
# clear-cr-marker.sh's no-env-seam posture) and writes markers + ledger at the
# fixed paths under the temp repo's own .git.
set -uo pipefail

# grep -q against text with NO pipeline (pipefail + early grep -q exit trap —
# HIMMEL-1430; same helper as test-clear-cr-marker.sh).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SCRIPT_DIR/cr-pending-audit.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# make_repo — temp git repo with one commit on branch `feat/x`; sets tmp + sha.
make_repo() {
    tmp=$(mktemp -d)
    (
        cd "$tmp" || exit 1
        git init -q -b main .
        git config user.email t@t.t; git config user.name t
        echo hi > f.txt
        git add f.txt
        git commit -qm "base"
        git checkout -qb feat/x
        echo more >> f.txt
        git commit -qam "work"
    ) >/dev/null 2>&1
    sha=$(git -C "$tmp" rev-parse --verify refs/heads/feat/x)
}

# write_marker <tmp> <branch> <sha>
write_marker() {
    mkdir -p "$1/.git/cr-pending/$(dirname "$2")"
    printf '2026-08-04T10:00:00+02:00 | %s | full\n' "$3" > "$1/.git/cr-pending/$2"
}

# write_ledger <tmp> <jsonl-lines...>
write_ledger() {
    local t="$1"; shift
    : > "$t/.git/cr-critic-scores.jsonl"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$t/.git/cr-critic-scores.jsonl"; done
}

avail_ok() { printf '{"kind":"avail","branch":"feat/x","head":"%s","model":"codex","status":"ok"}' "$1"; }
finding()  { printf '{"kind":"finding","branch":"feat/x","head":"%s","model":"codex","finding_id":"codex-1","severity":"%s","file":"a.sh","line":1,"verdict":"%s"}' "$1" "$2" "$3"; }

echo "T1: stale marker -> NEEDS-ACTION reason=stale-marker, exit 1"
make_repo
write_marker "$tmp" feat/x "0000000000000000000000000000000000000000"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "class=NEEDS-ACTION reason=stale-marker" && grepq "$out" "re-run /pr-check" \
    && pass || fail "T1 rc=$rc out=$out"
rm -rf "$tmp"

echo "T2: marker at tip, empty ledger -> reason=no-review-at-tip"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=no-review-at-tip" && pass || fail "T2 rc=$rc out=$out"
rm -rf "$tmp"

echo "T2b: FAILED attempts at tip (avail unavailable + usage) are NOT reviews -> no-review-at-tip (adversarial r3)"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" \
    "{\"kind\":\"avail\",\"branch\":\"feat/x\",\"head\":\"$sha\",\"model\":\"coderabbit\",\"status\":\"unavailable\"}" \
    "{\"kind\":\"usage\",\"branch\":\"feat/x\",\"head\":\"$sha\",\"model\":\"codex\",\"est_total_tokens\":1}"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=no-review-at-tip" && ! grepq "$out" "reason=gates-may-pass" \
    && grepq "$out" "missing signal, not a review" && pass || fail "T2b rc=$rc out=$out"
rm -rf "$tmp"

echo "T3: blocking crit finding at tip -> reason=findings-at-tip blocking=1"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" "$(avail_ok "$sha")" "$(finding "$sha" crit agreed)"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=findings-at-tip" && grepq "$out" "blocking=1" && pass || fail "T3 rc=$rc out=$out"
rm -rf "$tmp"

echo "T4: clean evidence at tip -> reason=gates-may-pass names clear-cr-marker.sh"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" "$(avail_ok "$sha")" "$(finding "$sha" crit disproved)"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=gates-may-pass" && grepq "$out" "clear-cr-marker.sh feat/x" && pass || fail "T4 rc=$rc out=$out"
rm -rf "$tmp"

echo "T5: amended-to-sug finding is NOT re-reported as blocking (HIMMEL-1294)"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" "$(avail_ok "$sha")" "$(finding "$sha" crit agreed)" \
    "{\"kind\":\"amend\",\"target_head\":\"$sha\",\"finding_id\":\"codex-1\",\"artifact\":\"diff\",\"perspective\":\"off\",\"set\":{\"severity\":\"sug\"},\"reason\":\"t\"}"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=gates-may-pass" && pass || fail "T5 rc=$rc out=$out"
rm -rf "$tmp"

echo "T5b: SHORT-sha finding corrected by a FULL-sha amend is not re-reported (codex-1/glm-5)"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" "$(avail_ok "$sha")" "$(finding "${sha:0:8}" crit agreed)" \
    "{\"kind\":\"amend\",\"target_head\":\"$sha\",\"finding_id\":\"codex-1\",\"artifact\":\"diff\",\"perspective\":\"off\",\"set\":{\"severity\":\"sug\"},\"reason\":\"t\"}"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=gates-may-pass" && ! grepq "$out" "reason=findings-at-tip" \
    && pass || fail "T5b rc=$rc out=$out"
rm -rf "$tmp"

echo "T5c: FULL-sha finding corrected by a SHORT-sha amend is not re-reported (codex-1/glm-5, reverse)"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" "$(avail_ok "$sha")" "$(finding "$sha" crit agreed)" \
    "{\"kind\":\"amend\",\"target_head\":\"${sha:0:8}\",\"finding_id\":\"codex-1\",\"artifact\":\"diff\",\"perspective\":\"off\",\"set\":{\"severity\":\"sug\"},\"reason\":\"t\"}"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=gates-may-pass" && ! grepq "$out" "reason=findings-at-tip" \
    && pass || fail "T5c rc=$rc out=$out"
rm -rf "$tmp"

echo "T6: SHORT-form ledger head still counts as review evidence at the tip"
make_repo
write_marker "$tmp" feat/x "$sha"
write_ledger "$tmp" "$(avail_ok "${sha:0:8}")"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "reason=gates-may-pass" && pass || fail "T6 rc=$rc out=$out"
rm -rf "$tmp"

echo "T7: orphan marker (branch deleted) -> summarized, exit 0, NOT NEEDS-ACTION"
make_repo
write_marker "$tmp" feat/gone "1111111111111111111111111111111111111111"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grepq "$out" "no longer exist locally" && ! grepq "$out" "NEEDS-ACTION" \
    && pass || fail "T7 rc=$rc out=$out"
rm -rf "$tmp"

echo "T8: --ticket scopes the sweep with key boundaries (digit AND letter suffixes excluded)"
make_repo
git -C "$tmp" branch -q feat/himmel-11-a feat/x
git -C "$tmp" branch -q feat/himmel-110-b feat/x
git -C "$tmp" branch -q feat/himmel-11abc-c feat/x
write_marker "$tmp" feat/himmel-11-a    "2222222222222222222222222222222222222222"
write_marker "$tmp" feat/himmel-110-b   "2222222222222222222222222222222222222222"
write_marker "$tmp" feat/himmel-11abc-c "2222222222222222222222222222222222222222"
out=$(cd "$tmp" && bash "$AUDIT" --ticket HIMMEL-11 2>&1); rc=$?
[ "$rc" -eq 1 ] && grepq "$out" "branch=feat/himmel-11-a" && ! grepq "$out" "branch=feat/himmel-110-b" \
    && ! grepq "$out" "branch=feat/himmel-11abc-c" \
    && pass || fail "T8 rc=$rc out=$out"
out2=$(cd "$tmp" && bash "$AUDIT" --ticket HIMMEL-9 2>&1); rc2=$?
[ "$rc2" -eq 0 ] && [ -z "$out2" ] && pass || fail "T8b (no-match ticket must be silent rc 0) rc=$rc2 out=$out2"
rm -rf "$tmp"

echo "T9: explicit branch with no marker -> informative line, exit 0"
make_repo
out=$(cd "$tmp" && bash "$AUDIT" feat/x 2>&1); rc=$?
[ "$rc" -eq 0 ] && grepq "$out" "no pending marker" && pass || fail "T9 rc=$rc out=$out"
rm -rf "$tmp"

echo "T10: doctrinal footer rides every NEEDS-ACTION report"
make_repo
write_marker "$tmp" feat/x "0000000000000000000000000000000000000000"
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
grepq "$out" "NEVER a terminal block" && grepq "$out" "HIMMEL-1519/1553" && pass || fail "T10 out=$out"
rm -rf "$tmp"

echo "T11: malformed --ticket refused (exit 2)"
make_repo
out=$(cd "$tmp" && bash "$AUDIT" --ticket "not a key" 2>&1); rc=$?
[ "$rc" -eq 2 ] && grepq "$out" "must be a key" && pass || fail "T11 rc=$rc out=$out"
rm -rf "$tmp"

echo "T12: no markers at all -> silent, exit 0"
make_repo
out=$(cd "$tmp" && bash "$AUDIT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass || fail "T12 rc=$rc out=$out"
rm -rf "$tmp"

echo
echo "cr-pending-audit tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
