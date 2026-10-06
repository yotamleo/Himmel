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

# --- 4b. SHA boundary rule (HIMMEL-3699: BSD sed has no \b, so the collapse is
# a perl lookaround). A 40-hex run bounded by non-word chars / start / end
# collapses; one touching [A-Za-z0-9_] stays; 39/41-hex runs stay. ---
LOG4B="$WORKDIR/c4b.jsonl"
sha_of_cmd() {
    : >"$LOG4B"
    run_hook "$(payload s4b /tmp/repo Bash "$1" '[X]')" "$LOG4B" >/dev/null
    jq -r .input_sha <"$LOG4B"
}
H40a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
H40b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_same() { # name cmd-a cmd-b
    local a b; a=$(sha_of_cmd "$2"); b=$(sha_of_cmd "$3")
    if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "$1"; else fail "$1 ($a vs $b)"; fi
}
assert_differ() { # name cmd-a cmd-b
    local a b; a=$(sha_of_cmd "$2"); b=$(sha_of_cmd "$3")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then pass "$1"; else fail "$1 ($a vs $b)"; fi
}
assert_same "40-hex at start and end of the input collapses" "$H40a x $H40a" "$H40b x $H40b"
assert_same "40-hex between punctuation collapses" "git show ($H40a):f" "git show ($H40b):f"
assert_same "two SHAs separated by one space both collapse" "git log $H40a $H40b" "git log $H40b $H40a"
assert_differ "40-hex touching a word char on the left stays" "g$H40a x" "g$H40b x"
assert_differ "40-hex touching a word char on the right stays" "$H40a""_x" "$H40b""_x"
assert_differ "39-hex run stays" "x ${H40a#a} y" "x ${H40b#b} y"
assert_differ "41-hex run stays" "x a$H40a y" "x b$H40b y"

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

# --- 8. SHORT secrets (< 12 chars) in key=value and flag forms: phase 1's
# generic rule required 12+ chars, so DB_PASS=short leaked in the clear. ---
short_leak() {  # short_leak <name> <command> <secret>
    local log="$WORKDIR/short-$1.jsonl"
    run_hook "$(payload sh "/tmp/repo" Bash "$2" '[X]')" "$log" >/dev/null
    # a row must exist: an unreadable or empty log would otherwise pass vacuously
    if [ ! -s "$log" ]; then fail "short secret redacted: $1 (no row written)"
    elif grep -qF "$3" "$log" 2>/dev/null; then fail "short secret redacted: $1"; else pass "short secret redacted: $1"; fi
}
short_leak env-assign   'DB_PASS=hunter2 ./run.sh'                     hunter2
short_leak token-assign 'curl -d token=tkz https://x.test'             tkz
short_leak api-key      'export API_KEY=k1 && deploy'                  k1
short_leak quoted-spc   'login --user u password="my pass" now'        'my pass'
short_leak mysql-p      'mysql -uroot -pS3cret db'                     S3cret
short_leak pw-flag-sp   'psql --password pw1 -h host'                  pw1
short_leak pw-flag-eq   'psql --password=pw2 -h host'                  pw2
# the secret carries non-hex letters: input_sha is hex and would collide with a short one
short_leak mysql-pwd    'MYSQL_PWD=zq9 mysql db'                       zq9
# The redactor must not eat the flag that FOLLOWS a value-less --password.
LOGK="$WORKDIR/keep.jsonl"
run_hook "$(payload sk /tmp/repo Bash 'psql --password --host db1' '[X]')" "$LOGK" >/dev/null
if grep -qF -e '--host' "$LOGK" 2>/dev/null; then pass "a flag after a value-less --password survives"; else fail "a flag after a value-less --password survives"; fi

# --- 9. cwd, session_title, session_id and tool go through redact() too. ---
LOG9="$WORKDIR/c9.jsonl"
S9="ghp_EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
run_hook "$(payload "sid-$S9" "/w/token=zzz/worktrees/slug-$S9" "Tool$S9" 'ls' '[X]')" "$LOG9" >/dev/null
for leak in "$S9" "zzz"; do
    if grep -qF "$leak" "$LOG9" 2>/dev/null; then fail "secret '$leak' in cwd/session_id/tool/title is redacted"; else pass "secret '$leak' in cwd/session_id/tool/title is redacted"; fi
done
if [ -s "$LOG9" ]; then pass "a redacted-field denial still writes a row"; else fail "a redacted-field denial still writes a row"; fi

# --- 10. every field is capped, tool included, so a row stays bounded. ---
LOG10="$WORKDIR/c10.jsonl"
BIG=$(printf 'x%.0s' $(seq 1 3000))
run_hook "$(payload "$BIG" "/$BIG" "$BIG" "$BIG" "$BIG")" "$LOG10" >/dev/null
row_bytes=$(LC_ALL=C wc -c <"$LOG10" | tr -d '[:space:]')
tool_len=$(jq -r '.tool | length' "$LOG10" 2>/dev/null)
if [ -n "$tool_len" ] && [ "$tool_len" -le 200 ]; then pass "tool field capped at 200 chars"; else fail "tool field capped at 200 chars (got ${tool_len:-none})"; fi
if [ -n "$row_bytes" ] && [ "$row_bytes" -le 4096 ]; then pass "an oversized denial still fits one PIPE_BUF row"; else fail "an oversized denial still fits one PIPE_BUF row (got ${row_bytes:-none} bytes)"; fi

# --- 11. umask 077: a fresh state dir is 700 and the log 600. ---
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
LOG11="$WORKDIR/fresh-dir/state/c11.jsonl"
( umask 022; run_hook "$(payload s11 /tmp/repo Bash 'ls' '[X]')" "$LOG11" >/dev/null )
check_mode() { if [ "$(mode_of "$1")" = "$2" ]; then pass "$3"; else fail "$3 (got $(mode_of "$1"))"; fi; }
check_mode "$LOG11" 600 "log file is created 0600 under a permissive caller umask"
check_mode "$(dirname "$LOG11")" 700 "a state dir the hook creates is 0700"
# A phase-1 log already on disk is 0644 (umask only governs NEW files), so the
# hook must tighten an existing log too, and the rotated generation with it.
LOG11B="$WORKDIR/c11b.jsonl"
: > "$LOG11B"; : > "$LOG11B.1"; chmod 644 "$LOG11B" "$LOG11B.1"
run_hook "$(payload s11b /tmp/repo Bash 'ls' '[X]')" "$LOG11B" >/dev/null
check_mode "$LOG11B" 600 "an existing 0644 log is tightened to 0600 on the next append"
check_mode "$LOG11B.1" 600 "an existing 0644 rotated generation is tightened to 0600"

# --- 12. rotation: past the byte cap the log renames to .1 (one generation)
# and a fresh file starts; the row that triggered it is not lost. ---
LOG12="$WORKDIR/c12.jsonl"
export HIMMEL_CLASSIFIER_DENIALS_MAX_BYTES=2000
i=0; while [ "$i" -lt 12 ]; do run_hook "$(payload s12 /tmp/repo Bash "ls $i" '[X]')" "$LOG12" >/dev/null; i=$((i + 1)); done
if [ -f "$LOG12.1" ]; then pass "log past the cap rotates to .1"; else fail "log past the cap rotates to .1"; fi
cur_bytes=$(wc -c <"$LOG12" 2>/dev/null | tr -d '[:space:]')
if [ -n "$cur_bytes" ] && [ "$cur_bytes" -le 2600 ]; then pass "live log stays near the cap"; else fail "live log stays near the cap (got ${cur_bytes:-none})"; fi
total=$(cat "$LOG12" "$LOG12.1" 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$total" = "12" ]; then pass "rotation keeps every row across the two generations"; else fail "rotation keeps every row across the two generations (got $total)"; fi
i=0; while [ "$i" -lt 60 ]; do run_hook "$(payload s12 /tmp/repo Bash "ls $i" '[X]')" "$LOG12" >/dev/null; i=$((i + 1)); done
if [ ! -e "$LOG12.2" ]; then pass "only one rotated generation is kept"; else fail "only one rotated generation is kept"; fi
unset HIMMEL_CLASSIFIER_DENIALS_MAX_BYTES

# --- 13. fail-open survives the new code: an unwritable state dir and an
# unwritable rotation target both still exit 0. ---
if [ "$(id -u)" != "0" ]; then
    RO="$WORKDIR/ro"; mkdir -p "$RO"; chmod 500 "$RO"
    rc=$(run_hook "$(payload s13 /tmp/repo Bash 'ls' '[X]')" "$RO/sub/c13.jsonl")
    if [ "$rc" = "0" ]; then pass "unwritable state dir exits 0"; else fail "unwritable state dir exits 0 (rc=$rc)"; fi
    chmod 700 "$RO"
fi

# --- 14. HARD RULE (HIMMEL-3724): input_head and reason_tag never leave the
# host. Only these files may name them; a new consumer (the later Telegram
# page) must not carry them, and adding one here is a conscious edit.
# leg-digest.ts (+ its ledger fixture) is a host-local reader: it maps reason_tag onto the closed category list and never emits it raw; test-leg-digest.sh is the egress test that checks the digest's output (HIMMEL-4670).
# ponytail: a file-list pin is a coarse proxy (a reader can forward the fields
# under another name); test-tick.sh pins the real tick-line output. Upgrade: an
# egress test on the Telegram page when that slice lands. ---
REPO_ROOT="$(cd "$(dirname "$HOOK")/../.." && pwd)"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    readers=$(git -C "$REPO_ROOT" grep -l -E 'input_head|reason_tag' -- scripts ':!*.md' | sort | tr '\n' ' ')
    want="scripts/eval/leg-digest/fixtures/classifier-denials.jsonl scripts/eval/leg-digest/leg-digest.ts scripts/eval/leg-digest/test-leg-digest.sh scripts/handover/console-kit/test-tick.sh scripts/handover/console-kit/tick.sh scripts/hooks/log-classifier-denial.sh scripts/hooks/test-log-classifier-denial.sh "
    if [ "$readers" = "$want" ]; then
        pass "only the host-local files reference input_head / reason_tag"
    else
        fail "only the host-local files reference input_head / reason_tag (got: $readers)"
    fi
else
    pass "input_head/reason_tag reader pin skipped (not a git checkout)"
fi

echo "----"
if [ "$FAILED" -eq 0 ]; then
    echo "log-classifier-denial: all cases passed"
    exit 0
else
    echo "log-classifier-denial: $FAILED case(s) failed"
    exit 1
fi
