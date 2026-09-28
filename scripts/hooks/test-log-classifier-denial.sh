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
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/log-classifier-denial-test.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
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

# --- 3b. RED-shaped redaction control on the UNBRACKETED-reason fallback
# path: a classifier denial_reason with no bracketed tag can itself quote
# the offending command, so the fallback must redact it too, not just
# input_head. ---
SECRET2="ghp_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
LOG2B="$WORKDIR/c2b.jsonl"
run_hook "$(payload s2b /tmp/repo Bash 'ls' "denied because $SECRET2 was found")" "$LOG2B" >/dev/null
if grep -qF "$SECRET2" "$LOG2B" 2>/dev/null; then
    fail "gitleaks-shaped token redacted on the unbracketed-reason fallback path"
else
    pass "gitleaks-shaped token redacted on the unbracketed-reason fallback path"
fi
if grep -q '\[REDACTED\]' "$LOG2B" 2>/dev/null; then
    pass "redaction marker present in reason_tag fallback"
else
    fail "redaction marker present in reason_tag fallback"
fi

# --- 3c. RED-shaped redaction control on the BRACKETED-reason path: a
# secret embedded INSIDE the brackets must also be redacted, not just an
# unbracketed fallback -- round 2 of the critic panel found the bracket
# extraction itself still ran on raw text. ---
SECRET3="ghp_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
LOG2C="$WORKDIR/c2c.jsonl"
run_hook "$(payload s2c /tmp/repo Bash 'ls' "[LEAK $SECRET3]")" "$LOG2C" >/dev/null
if grep -qF "$SECRET3" "$LOG2C" 2>/dev/null; then
    fail "gitleaks-shaped token redacted on the bracketed-reason path"
else
    pass "gitleaks-shaped token redacted on the bracketed-reason path"
fi
if grep -q '\[REDACTED\]' "$LOG2C" 2>/dev/null; then
    pass "redaction marker present in bracketed reason_tag"
else
    fail "redaction marker present in bracketed reason_tag"
fi

# --- 3d. RED-shaped redaction control on a MULTI-LINE PEM body: round 1's
# single-line PEM sed rule only matched a BEGIN...END pair on the SAME
# line, so a real multi-line key body (BEGIN, body lines, END on separate
# lines) still leaked in full -- round 3 of the critic panel. ---
LOG2D="$WORKDIR/c2d.jsonl"
PEMBODY='MIIEowIBAAKCAQEAsecretsecretsecretsecretsecretsecretsecretsecret'
# The BEGIN/END markers are assembled at runtime so no literal PEM header sits in
# this file for the CI gitleaks tree scan to flag as a private key.
PEMLBL="RSA PRIV""ATE KEY"
run_hook "$(payload s2d /tmp/repo Bash "echo -----BEGIN $PEMLBL-----
$PEMBODY
anothersecretlineanothersecretlineanothersecretline
-----END $PEMLBL-----" '[Data Exfiltration]')" "$LOG2D" >/dev/null
if grep -qF "$PEMBODY" "$LOG2D" 2>/dev/null; then
    fail "multi-line PEM body redacted before it reaches the jsonl"
else
    pass "multi-line PEM body redacted before it reaches the jsonl"
fi
if grep -q '\[REDACTED-PEM\]' "$LOG2D" 2>/dev/null; then
    pass "PEM redaction marker present for multi-line body"
else
    fail "PEM redaction marker present for multi-line body"
fi

# --- 3e. RED-shaped redaction control on a PEM BEGIN with no matching END:
# the redactor must fail CLOSED and drop everything after the marker,
# never emit it unredacted just because no END was ever seen. ---
LOG2E="$WORKDIR/c2e.jsonl"
PEMBODY2='MIIEowIBAAKCAQEAsecretsecretsecretsecretsecretsecretsecretsecret'
run_hook "$(payload s2e /tmp/repo Bash "echo -----BEGIN OPENSSH PRIVATE KEY-----
$PEMBODY2
after this there is no end marker at all so this must all vanish" '[Data Exfiltration]')" "$LOG2E" >/dev/null
if grep -qF "$PEMBODY2" "$LOG2E" 2>/dev/null; then
    fail "PEM body with no END marker redacted (fail-closed)"
else
    pass "PEM body with no END marker redacted (fail-closed)"
fi
if grep -qF "this must all vanish" "$LOG2E" 2>/dev/null; then
    fail "text after a BEGIN with no END is dropped (fail-closed)"
else
    pass "text after a BEGIN with no END is dropped (fail-closed)"
fi
if grep -q '\[REDACTED-PEM\]' "$LOG2E" 2>/dev/null; then
    pass "PEM redaction marker present for BEGIN with no END"
else
    fail "PEM redaction marker present for BEGIN with no END"
fi

# --- 3f. RED-shaped redaction control: a github_pat_ token was uncovered
# by round 1/2's pattern set (which only matched gh[pousr]_) -- round 3
# of the critic panel. ---
SECRET4="github_pat_11AAAAAAAAAAAAAAAAAAAA_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
LOG2F="$WORKDIR/c2f.jsonl"
run_hook "$(payload s2f /tmp/repo Bash 'ls' "denied because $SECRET4 was found")" "$LOG2F" >/dev/null
if grep -qF "$SECRET4" "$LOG2F" 2>/dev/null; then
    fail "github_pat_ token redacted"
else
    pass "github_pat_ token redacted"
fi
if grep -q '\[REDACTED\]' "$LOG2F" 2>/dev/null; then
    pass "redaction marker present for github_pat_ token"
else
    fail "redaction marker present for github_pat_ token"
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
title=$(jq -r .session_title "$LOG4")
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

# --- 7. a multiline command is capped as a WHOLE: input_head stays one
# bounded line (cut -c1-200 alone caps per line, not per value). ---
LOG8="$WORKDIR/c8.jsonl"
multiline=$(printf 'line-%s\n' $(seq 1 100))
run_hook "$(payload s8 /tmp/repo Bash "$multiline" '[Out-of-Place Publication]')" "$LOG8" >/dev/null
head_len=$(jq -r '.input_head | length' "$LOG8" 2>/dev/null)
if [ -n "$head_len" ] && [ "$head_len" -le 200 ]; then
    pass "multiline input_head capped at 200 chars in total"
else
    fail "multiline input_head capped at 200 chars in total (got ${head_len:-none})"
fi

echo "----"
if [ "$FAILED" -eq 0 ]; then
    echo "log-classifier-denial: all cases passed"
    exit 0
else
    echo "log-classifier-denial: $FAILED case(s) failed"
    exit 1
fi
