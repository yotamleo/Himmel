#!/usr/bin/env bash
# Smoke test for scripts/hooks/log-classifier-denial.sh (HIMMEL-3724 §4c).
#
# Usage: bash scripts/hooks/test-log-classifier-denial.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/log-classifier-denial.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

run_hook() {
    local input="$1" out="$2"
    HIMMEL_CLASSIFIER_DENIALS_LOG="$out" bash "$HOOK" <<<"$input" >/dev/null 2>&1
    echo "$?"
}

payload() {
    # $1=session_id $2=cwd $3=tool $4=command $5=denial_reason
    jq -n -c \
        --arg sid "$1" --arg cwd "$2" --arg tool "$3" \
        --arg cmd "$4" --arg reason "$5" \
        '{session_id:$sid, cwd:$cwd, tool_name:$tool, tool_input:{command:$cmd}, denial_reason:$reason}'
}

# --- 1. never blocks: rc=0 on a well-formed denial ---
LOG1="$WORKDIR/c1.jsonl"
rc=$(run_hook "$(payload s1 /tmp/repo Bash 'gh pr create' '[Out-of-Place Publication]')" "$LOG1")
if [ "$rc" = "0" ]; then pass "well-formed denial exits 0"; else fail "well-formed denial exits 0 (rc=$rc)"; fi

# --- 2. writes exactly one JSON line with the §4c fields ---
if [ "$(wc -l <"$LOG1" | tr -d '[:space:]')" = "1" ]; then
    pass "appends exactly one line"
else
    fail "appends exactly one line (got $(wc -l <"$LOG1" 2>/dev/null))"
fi
row=$(cat "$LOG1" 2>/dev/null)
for field in ts session_id session_title cwd tool reason_tag input_sha input_head; do
    if printf '%s' "$row" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
        pass "row has field $field"
    else
        fail "row has field $field"
    fi
done
if [ "$(printf '%s' "$row" | jq -r .reason_tag)" = "[Out-of-Place Publication]" ]; then
    pass "reason_tag parsed from bracketed denial_reason"
else
    fail "reason_tag parsed from bracketed denial_reason (got $(printf '%s' "$row" | jq -r .reason_tag))"
fi

# --- 3. RED-shaped redaction control: a gitleaks-shaped token must never
# reach the jsonl, in either the raw or hashed form's preimage. ---
SECRET="ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
LOG2="$WORKDIR/c2.jsonl"
run_hook "$(payload s2 /tmp/repo Bash "curl -H \"Authorization: token $SECRET\" https://api.github.com" '[Data Exfiltration]')" "$LOG2" >/dev/null
if grep -qF "$SECRET" "$LOG2" 2>/dev/null; then
    fail "gitleaks-shaped token redacted before it reaches the jsonl"
else
    pass "gitleaks-shaped token redacted before it reaches the jsonl"
fi
if grep -q '\[REDACTED\]' "$LOG2" 2>/dev/null; then
    pass "redaction marker present in place of the token"
else
    fail "redaction marker present in place of the token"
fi

# --- 4. two calls differing only by a git SHA normalise to the same
# input_sha (this is what lets tick.sh's REPEAT class notice a flip). ---
LOG3="$WORKDIR/c3.jsonl"
run_hook "$(payload s3 /tmp/repo Bash 'git merge-base --is-ancestor aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa HEAD' '[X]')" "$LOG3" >/dev/null
run_hook "$(payload s3 /tmp/repo Bash 'git merge-base --is-ancestor bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb HEAD' '[X]')" "$LOG3" >/dev/null
sha_a=$(sed -n '1p' "$LOG3" | jq -r .input_sha)
sha_b=$(sed -n '2p' "$LOG3" | jq -r .input_sha)
if [ -n "$sha_a" ] && [ "$sha_a" = "$sha_b" ]; then
    pass "input_sha collapses differing SHAs to the same hash"
else
    fail "input_sha collapses differing SHAs to the same hash ($sha_a vs $sha_b)"
fi

# --- 5. session_title derives from a worktree cwd's slug ---
LOG4="$WORKDIR/c4.jsonl"
run_hook "$(payload s4 /repo/.claude/worktrees/feat+foo-bar Bash 'ls' '[X]')" "$LOG4" >/dev/null
title=$(cat "$LOG4" | jq -r .session_title)
if [ "$title" = "feat+foo-bar" ]; then
    pass "session_title derived from worktree slug"
else
    fail "session_title derived from worktree slug (got $title)"
fi

# --- 6. fail-open: malformed/empty stdin never blocks and never crashes ---
rc=$(run_hook "" "$WORKDIR/c5.jsonl")
if [ "$rc" = "0" ]; then pass "empty stdin exits 0"; else fail "empty stdin exits 0 (rc=$rc)"; fi
rc=$(run_hook 'not json' "$WORKDIR/c6.jsonl")
if [ "$rc" = "0" ]; then pass "unparseable stdin exits 0"; else fail "unparseable stdin exits 0 (rc=$rc)"; fi
rc=$(run_hook "$(jq -n -c '{tool_name:"", tool_input:{}}')" "$WORKDIR/c7.jsonl")
if [ "$rc" = "0" ] && [ ! -s "$WORKDIR/c7.jsonl" ]; then
    pass "missing tool_name writes nothing and exits 0"
else
    fail "missing tool_name writes nothing and exits 0"
fi

echo "----"
if [ "$FAILED" -eq 0 ]; then
    echo "log-classifier-denial: all cases passed"
    exit 0
else
    echo "log-classifier-denial: $FAILED case(s) failed"
    exit 1
fi
