#!/usr/bin/env bash
# scripts/cr/test-gemini-first-pass.sh — TDD tests for gemini-first-pass.sh (HIMMEL-270).
# Deterministic: a fake `gemini` binary is prepended to PATH; no live gemini-cli,
# no network. (scripts/gemini/test-invoke.sh stays the LIVE smoke test for the
# chokepoint itself.) Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GFP="$SCRIPT_DIR/gemini-first-pass.sh"

TMP="$(mktemp -d -t gfp-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Fake gemini: records its argv (one arg per line) and piped stdin to separate
# files; plays back a canned response. Prompt travels via stdin (not -p argv)
# so prompt assertions read FAKE_STDIN_FILE; flag assertions still use FAKE_ARGV_FILE.
cat > "$TMP/bin/gemini" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_ARGV_FILE:?}"
if [ ! -t 0 ]; then cat > "${FAKE_STDIN_FILE:-/dev/null}"; fi
if [ -n "${FAKE_STDOUT_FILE:-}" ]; then cat "$FAKE_STDOUT_FILE"; fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$TMP/bin/gemini"
export PATH="$TMP/bin:$PATH"
export FAKE_ARGV_FILE="$TMP/argv.txt"
export FAKE_STDIN_FILE="$TMP/stdin.txt"

passed=0; failed=0
ok()   { echo "  ok: $1" >&2; passed=$((passed+1)); }
bad()  { echo "FAIL: $1" >&2; failed=$((failed+1)); }

# Fixture diff: one file, one hunk, new-file lines 10-18.
FIXTURE_DIFF="$TMP/fixture.diff"
cat > "$FIXTURE_DIFF" <<'EOF'
diff --git a/src/app.sh b/src/app.sh
index 0000000..1111111 100644
--- a/src/app.sh
+++ b/src/app.sh
@@ -10,6 +10,9 @@
 context line
+new line eleven
+new line twelve
+new line thirteen
 context line
 context line
 context line
EOF

# --- test: empty stdin -> exit 2 ---
echo "test: empty stdin exits 2 with usage" >&2
out="$(printf '' | bash "$GFP" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "Usage:"; then
    ok "empty stdin -> rc=2 + usage"
else
    bad "empty stdin: want rc=2 + usage, got rc=$rc out=$out"
fi

# --- test: unknown flag -> exit 2 ---
echo "test: unknown flag exits 2" >&2
printf 'x' | bash "$GFP" --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "unknown flag -> rc=2"; else bad "unknown flag: want rc=2, got rc=$rc"; fi

# Canned well-formed gemini output. IDs deliberately wrong/missing so the
# renumbering is observable.
WELLFORMED="$TMP/wellformed.md"
cat > "$WELLFORMED" <<'EOF'
## Critical Issues (1 found)
- [gemini-9]: Unquoted variable expansion [src/app.sh:12]

## Important Issues (1 found)
- Missing error check on cat [src/app.sh:11]

## Suggestions (1 found)
- Consider quoting [src/app.sh:13]
EOF

ZEROFOUND="$TMP/zerofound.md"
cat > "$ZEROFOUND" <<'EOF'
## Critical Issues (0 found)

## Important Issues (0 found)

## Suggestions (0 found)
EOF

# --- test: well-formed output passes through, renumbered ---
echo "test: well-formed output -> exit 0, headings, renumbered IDs" >&2
out="$(FAKE_STDOUT_FILE="$WELLFORMED" bash "$GFP" < "$FIXTURE_DIFF" 2>"$TMP/err1")"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '^# Gemini First-Pass Review$' \
   && printf '%s' "$out" | grep -q '^## Critical Issues (1 found)$' \
   && printf '%s' "$out" | grep -q '^## Important Issues (1 found)$' \
   && printf '%s' "$out" | grep -q '^## Suggestions (1 found)$' \
   && printf '%s' "$out" | grep -q '^- \[gemini-1\]: Unquoted variable expansion \[src/app.sh:12\]$' \
   && printf '%s' "$out" | grep -q '^- \[gemini-2\]: Missing error check on cat \[src/app.sh:11\]$' \
   && printf '%s' "$out" | grep -q '^- \[gemini-3\]: Consider quoting \[src/app.sh:13\]$'; then
    ok "well-formed pass-through + renumber"
else
    bad "well-formed: rc=$rc out=$out err=$(cat "$TMP/err1")"
fi

# --- test: zero-findings output -> exit 0 ---
echo "test: zero findings -> exit 0" >&2
out="$(FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$FIXTURE_DIFF" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^## Critical Issues (0 found)$'; then
    ok "zero findings -> rc=0"
else
    bad "zero findings: want rc=0 + (0 found), got rc=$rc out=$out"
fi

# --- test: prompt reaches gemini with the diff embedded ---
echo "test: prompt contains role text + diff" >&2
FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$FIXTURE_DIFF" >/dev/null 2>&1
if grep -q 'first-pass code reviewer' "$FAKE_STDIN_FILE" && grep -q 'new line twelve' "$FAKE_STDIN_FILE"; then
    ok "prompt contains role + diff"
else
    bad "prompt missing role text or diff content (stdin: $FAKE_STDIN_FILE)"
fi

# --- test: --model forwarded as -m to the gemini binary ---
# invoke.sh consumes --model and emits `-m <name>`; the PATH stub records the
# argv that actually reached `gemini`, so the assertion is on that file.
echo "test: --model forwarded to gemini argv" >&2
FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" --model gemini-2.5-flash < "$FIXTURE_DIFF" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -qx -- '-m' "$FAKE_ARGV_FILE" && grep -qx 'gemini-2.5-flash' "$FAKE_ARGV_FILE"; then
    ok "--model -> -m gemini-2.5-flash in gemini argv"
else
    bad "--model: rc=$rc argv=$(tr '\n' ' ' < "$FAKE_ARGV_FILE")"
fi

# --- test: gemini exits non-zero -> rc=1, fail-open note ---
echo "test: gemini non-zero -> rc=1 fail-open" >&2
err="$(FAKE_STDOUT_FILE="$ZEROFOUND" FAKE_RC=7 bash "$GFP" < "$FIXTURE_DIFF" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'fail-open'; then
    ok "gemini rc=7 -> script rc=1 + fail-open note"
else
    bad "gemini non-zero: want rc=1 + fail-open, got rc=$rc err=$err"
fi

# --- test: missing heading (3 permutations) -> rc=1, raw logged ---
for missing in Critical Important Suggestions; do
    echo "test: missing $missing heading -> rc=1" >&2
    M="$TMP/missing-$missing.md"
    grep -v "^## $missing" "$ZEROFOUND" > "$M"
    err="$(FAKE_STDOUT_FILE="$M" bash "$GFP" < "$FIXTURE_DIFF" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'Raw output:'; then
        ok "missing $missing -> rc=1 + raw log path"
    else
        bad "missing $missing: want rc=1 + raw log, got rc=$rc err=$err"
    fi
done

# --- test: bullet count != declared (N found) -> rc=1 (truncation guard) ---
echo "test: count mismatch -> rc=1" >&2
MISMATCH="$TMP/mismatch.md"
cat > "$MISMATCH" <<'EOF'
## Critical Issues (2 found)
- [gemini-1]: Only one bullet present [src/app.sh:12]

## Important Issues (0 found)

## Suggestions (0 found)
EOF
err="$(FAKE_STDOUT_FILE="$MISMATCH" bash "$GFP" < "$FIXTURE_DIFF" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'declared 2 vs 1'; then
    ok "count mismatch -> rc=1"
else
    bad "count mismatch: want rc=1 + 'declared 2 vs 1', got rc=$rc err=$err"
fi

# --- test: citation to file absent from diff -> dropped, N recomputed ---
echo "test: hallucinated file citation dropped" >&2
HALLFILE="$TMP/hallfile.md"
cat > "$HALLFILE" <<'EOF'
## Critical Issues (2 found)
- [gemini-1]: Real finding [src/app.sh:12]
- [gemini-2]: Cites a file not in the diff [other/ghost.sh:5]

## Important Issues (0 found)

## Suggestions (0 found)
EOF
out="$(FAKE_STDOUT_FILE="$HALLFILE" bash "$GFP" < "$FIXTURE_DIFF" 2>"$TMP/err-hf")"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '^## Critical Issues (1 found)$' \
   && ! printf '%s' "$out" | grep -q 'ghost.sh' \
   && grep -q 'dropped' "$TMP/err-hf"; then
    ok "absent-file citation dropped + N recomputed"
else
    bad "hallucinated file: rc=$rc out=$out err=$(cat "$TMP/err-hf")"
fi

# --- test: citation to real file but line outside every hunk -> dropped ---
echo "test: line-outside-hunk citation dropped" >&2
HALLLINE="$TMP/hallline.md"
cat > "$HALLLINE" <<'EOF'
## Critical Issues (1 found)
- [gemini-1]: Cites line 99, hunk covers 10-18 [src/app.sh:99]

## Important Issues (1 found)
- [gemini-2]: Real finding [src/app.sh:11]

## Suggestions (0 found)
EOF
out="$(FAKE_STDOUT_FILE="$HALLLINE" bash "$GFP" < "$FIXTURE_DIFF" 2>"$TMP/err-hl")"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '^## Critical Issues (0 found)$' \
   && printf '%s' "$out" | grep -q '^## Important Issues (1 found)$' \
   && printf '%s' "$out" | grep -q '^- \[gemini-1\]: Real finding \[src/app.sh:11\]$'; then
    ok "line-outside-hunk dropped, survivor renumbered from 1"
else
    bad "line-outside-hunk: rc=$rc out=$out err=$(cat "$TMP/err-hl")"
fi

# --- test: multi-file diff over cap -> cut at file boundary, markers present ---
echo "test: truncation at file boundary" >&2
BIGDIFF="$TMP/big.diff"
cat "$FIXTURE_DIFF" > "$BIGDIFF"
cat >> "$BIGDIFF" <<'EOF'
diff --git a/src/second.sh b/src/second.sh
index 0000000..2222222 100644
--- a/src/second.sh
+++ b/src/second.sh
@@ -1,3 +1,6 @@
 ctx
+SECOND-FILE-MARKER one
+SECOND-FILE-MARKER two
+SECOND-FILE-MARKER three
 ctx
 ctx
EOF
fixture_bytes=$(wc -c < "$FIXTURE_DIFF")
out="$(GEMINI_FIRST_PASS_CAP_BYTES="$fixture_bytes" FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$BIGDIFF" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '^# Gemini First-Pass Review (truncated input)$' \
   && grep -q 'TRUNCATED' "$FAKE_STDIN_FILE" \
   && ! grep -q 'SECOND-FILE-MARKER' "$FAKE_STDIN_FILE" \
   && grep -q 'new line twelve' "$FAKE_STDIN_FILE"; then
    ok "file-boundary truncation: file 1 kept, file 2 cut, markers set"
else
    bad "file-boundary truncation: rc=$rc out=$out"
fi

# --- test: 3-file diff truncated at last file boundary (last-boundary semantics) ---
echo "test: 3-file diff cut before file 3, file 2 kept" >&2
FILE2MARK="FILE2-MARK-$(date +%s)"
FILE3MARK="FILE3-MARK-$(date +%s)"
THREEDIFF="$TMP/three.diff"
# Section 1: reuse FIXTURE_DIFF
cat "$FIXTURE_DIFF" > "$THREEDIFF"
# Section 2: small synthetic file with FILE2MARK
cat >> "$THREEDIFF" <<EOF
diff --git a/src/second.sh b/src/second.sh
index 0000000..2222222 100644
--- a/src/second.sh
+++ b/src/second.sh
@@ -1,3 +1,4 @@
 ctx
+$FILE2MARK
 ctx
 ctx
EOF
# Measure bytes of sections 1+2 to set the cap just before section 3
sec12_bytes=$(wc -c < "$THREEDIFF")
# Section 3: synthetic file with FILE3MARK
cat >> "$THREEDIFF" <<EOF
diff --git a/src/third.sh b/src/third.sh
index 0000000..3333333 100644
--- a/src/third.sh
+++ b/src/third.sh
@@ -1,3 +1,4 @@
 ctx
+$FILE3MARK
 ctx
 ctx
EOF
out="$(GEMINI_FIRST_PASS_CAP_BYTES="$sec12_bytes" FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$THREEDIFF" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '(truncated input)' \
   && grep -q "$FILE2MARK" "$FAKE_STDIN_FILE" \
   && ! grep -q "$FILE3MARK" "$FAKE_STDIN_FILE"; then
    ok "3-file last-boundary: file 2 kept, file 3 cut, (truncated input) set"
else
    bad "3-file last-boundary: rc=$rc has_file2=$(grep -c "$FILE2MARK" "$FAKE_STDIN_FILE" 2>/dev/null || echo 0) has_file3=$(grep -c "$FILE3MARK" "$FAKE_STDIN_FILE" 2>/dev/null || echo 0)"
fi

# --- test: single file over cap -> hunk-boundary fallback, non-empty prompt ---
echo "test: truncation hunk fallback on oversized single file" >&2
HUGE="$TMP/huge.diff"
{
    printf 'diff --git a/src/wide.sh b/src/wide.sh\n'
    printf 'index 0000000..3333333 100644\n'
    printf -- '--- a/src/wide.sh\n'
    printf '+++ b/src/wide.sh\n'
    printf '@@ -1,2 +1,42 @@\n ctx\n'
    i=1; while [ "$i" -le 40 ]; do printf '+HUNK-ONE-LINE %03d padding padding padding\n' "$i"; i=$((i+1)); done
    printf ' ctx\n'
    printf '@@ -50,2 +90,42 @@\n ctx\n'
    i=1; while [ "$i" -le 40 ]; do printf '+HUNK-TWO-LINE %03d padding padding padding\n' "$i"; i=$((i+1)); done
    printf ' ctx\n'
} > "$HUGE"
out="$(GEMINI_FIRST_PASS_CAP_BYTES=1900 FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$HUGE" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '(truncated input)' \
   && grep -q 'HUNK-ONE-LINE 001' "$FAKE_STDIN_FILE" \
   && ! grep -q 'HUNK-TWO-LINE' "$FAKE_STDIN_FILE"; then
    ok "hunk fallback: hunk 1 kept, hunk 2 cut, prompt non-empty"
else
    bad "hunk fallback: rc=$rc out=$out"
fi

# --- test: non-unified-diff stdin (stat summary) -> exit 2, 'not a unified diff' in stderr ---
echo "test: stat-summary stdin -> exit 2, not-unified-diff message" >&2
stat_summary=" scripts/cr/x.sh | 214 ++++
 scripts/cr/y.sh |  12 ---
 2 files changed, 9 insertions(+)"
err="$(printf '%s\n' "$stat_summary" | bash "$GFP" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'not a unified diff'; then
    ok "stat-summary -> rc=2 + 'not a unified diff'"
else
    bad "stat-summary: want rc=2 + 'not a unified diff', got rc=$rc err=$err"
fi

# --- test: truncation hard fallback (cut=0) -> head -c CAP, (truncated input) marker, content beyond cap excluded ---
echo "test: truncation hard fallback (cut<=0) -> head -c CAP applied" >&2
# CAP=50 is below the byte offset of the fixture's first @@ line (101),
# so both fc and hc stay 0 and the else branch fires.
out="$(GEMINI_FIRST_PASS_CAP_BYTES=50 FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$FIXTURE_DIFF" 2>/dev/null)"; rc=$?
prompt_has_diff_git=$(grep -c 'diff --git a/src/app.sh' "$FAKE_STDIN_FILE" || true)
prompt_has_thirteen=$(grep -c 'new line thirteen' "$FAKE_STDIN_FILE" || true)
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '(truncated input)' \
   && [ "$prompt_has_diff_git" -gt 0 ] \
   && [ "$prompt_has_thirteen" -eq 0 ]; then
    ok "hard-cap fallback: (truncated input) set, diff head kept, content past cap excluded"
else
    bad "hard-cap fallback: rc=$rc out=$out has_diff_git=$prompt_has_diff_git has_thirteen=$prompt_has_thirteen"
fi

# --- test: mal-cited bullet (no [file:line]) is dropped, N recomputed to 0, stderr says 'dropped' ---
echo "test: bullet without citation dropped, count recomputed to 0" >&2
MALCITED="$TMP/malcited.md"
cat > "$MALCITED" <<'EOF'
## Critical Issues (1 found)
- [gemini-1]: Real-sounding issue but no citation

## Important Issues (0 found)

## Suggestions (0 found)
EOF
out="$(FAKE_STDOUT_FILE="$MALCITED" bash "$GFP" < "$FIXTURE_DIFF" 2>"$TMP/err-mc")"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q '^## Critical Issues (0 found)$' \
   && grep -q 'dropped' "$TMP/err-mc"; then
    ok "mal-cited bullet dropped, count -> 0, 'dropped' in stderr"
else
    bad "mal-cited bullet: rc=$rc out=$out err=$(cat "$TMP/err-mc")"
fi

# --- test: large (>pipe-buffer) valid diff passes the shape guard ---
echo "test: >128KB valid diff not rejected by shape guard" >&2
LARGE="$TMP/large.diff"
cat "$FIXTURE_DIFF" > "$LARGE"
{
    printf 'diff --git a/src/big.txt b/src/big.txt\n'
    printf 'index 0000000..4444444 100644\n'
    printf -- '--- a/src/big.txt\n'
    printf '+++ b/src/big.txt\n'
    printf '@@ -0,0 +1,3000 @@\n'
    i=1; while [ "$i" -le 3000 ]; do printf '+filler line %05d padding padding padding padding\n' "$i"; i=$((i+1)); done
} >> "$LARGE"
large_bytes=$(wc -c < "$LARGE")
out="$(FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$LARGE" 2>"$TMP/err-large")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^## Critical Issues (0 found)$'; then
    ok "large valid diff passes guard (no SIGPIPE false reject) [bytes=$large_bytes]"
else
    bad "large diff: want rc=0, got rc=$rc bytes=$large_bytes err=$(cat "$TMP/err-large")"
fi

# --- test: prompt travels to gemini via stdin, not argv (Windows argv limit) ---
echo "test: prompt via stdin not argv" >&2
FAKE_STDOUT_FILE="$WELLFORMED" bash "$GFP" < "$FIXTURE_DIFF" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q 'first-pass code reviewer' "$FAKE_STDIN_FILE" \
   && grep -q 'new line twelve' "$FAKE_STDIN_FILE" \
   && ! grep -q 'first-pass code reviewer' "$FAKE_ARGV_FILE"; then
    ok "prompt on stdin, argv clean"
else
    bad "stdin prompt: rc=$rc argv=$(head -c 200 "$FAKE_ARGV_FILE" | tr '\n' ' ')"
fi

# --- test: invalid GEMINI_FIRST_PASS_CAP_BYTES falls back to default with warning ---
echo "test: invalid CAP_BYTES -> warning + fallback to default" >&2
err="$(GEMINI_FIRST_PASS_CAP_BYTES=bogus FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$FIXTURE_DIFF" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$err" | grep -q 'invalid GEMINI_FIRST_PASS_CAP_BYTES'; then
    ok "invalid CAP_BYTES -> rc=0 + warning on stderr"
else
    bad "invalid CAP_BYTES: want rc=0 + warning, got rc=$rc err=$err"
fi

# --- test: --model with no value -> exit 2 (rc=2 branch) ---
echo "test: --model with no value -> exit 2" >&2
printf 'x' | bash "$GFP" --model 2>/dev/null; rc=$?
if [ "$rc" -eq 2 ]; then ok "--model with no value -> rc=2"; else bad "--model no value: want rc=2, got rc=$rc"; fi

# --- test: empty gemini stdout with rc=0 (quota soft-failure shape) -> rc=1 fail-open ---
# gemini may exit 0 but emit nothing on quota exhaustion; the script must treat
# empty output (no headings) as malformed and fail-open rather than emit an
# empty review.
echo "test: empty gemini stdout rc=0 -> rc=1 fail-open" >&2
EMPTY_OUT="$TMP/empty.md"
printf '' > "$EMPTY_OUT"
err="$(FAKE_STDOUT_FILE="$EMPTY_OUT" bash "$GFP" < "$FIXTURE_DIFF" 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q 'fail-open'; then
    ok "empty gemini stdout rc=0 -> rc=1 fail-open"
else
    bad "empty gemini stdout: want rc=1 fail-open, got rc=$rc err=$err"
fi

# --- test: raw-log file contains raw output on fail-open path ---
echo "test: raw-log file contains gemini raw output on fail-open" >&2
MALFORMED_OUT="$TMP/malformed.md"
printf 'this is not valid review output at all\n' > "$MALFORMED_OUT"
err="$(FAKE_STDOUT_FILE="$MALFORMED_OUT" bash "$GFP" < "$FIXTURE_DIFF" 2>&1 >/dev/null)"; rc=$?
# Extract the log path from stderr (format: "Raw output: /path/to/file")
log_path="$(printf '%s' "$err" | grep -o 'Raw output: [^ ]*' | cut -d' ' -f3)"
if [ "$rc" -eq 1 ] && [ -n "$log_path" ] && [ -f "$log_path" ] && grep -qF 'this is not valid review output at all' "$log_path"; then
    ok "raw-log file exists and contains the gemini raw output"
else
    bad "raw-log: rc=$rc log_path=$log_path err=$err"
fi

# --- test: positive citation match in a second hunk of the same file ---
# The fixture diff has only one hunk (lines 10-18). Add a second hunk and
# verify a citation pointing into it is kept (not dropped as hallucinated).
echo "test: citation in second hunk of same file is kept" >&2
TWOHUNK="$TMP/twohunk.diff"
cat > "$TWOHUNK" <<'EOF'
diff --git a/src/app.sh b/src/app.sh
index 0000000..1111111 100644
--- a/src/app.sh
+++ b/src/app.sh
@@ -10,6 +10,9 @@
 context line
+new line eleven
+new line twelve
+new line thirteen
 context line
 context line
 context line
@@ -50,3 +53,4 @@
 context line
+new line fifty-four
 context line
 context line
EOF
SECOND_HUNK_CIT="$TMP/second_hunk_cit.md"
cat > "$SECOND_HUNK_CIT" <<'EOF'
## Critical Issues (1 found)
- [gemini-1]: Issue in second hunk [src/app.sh:54]

## Important Issues (0 found)

## Suggestions (0 found)
EOF
out="$(FAKE_STDOUT_FILE="$SECOND_HUNK_CIT" bash "$GFP" < "$TWOHUNK" 2>"$TMP/err-2h")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'second hunk'; then
    ok "citation in second hunk of same file is kept"
else
    bad "second-hunk citation: rc=$rc out=$out err=$(cat "$TMP/err-2h")"
fi

# --- test: cap-equality boundary (diffbytes == CAPBYTES) -> NOT truncated ---
# When diffbytes exactly equals the cap, the diff fits within the cap and
# must NOT be truncated (truncated=0, no '(truncated input)' marker).
echo "test: cap-equality (diffbytes == CAP) -> not truncated" >&2
exact_bytes="$(printf '%s\n' "$(cat "$FIXTURE_DIFF")" | wc -c | tr -d '[:space:]')"
out="$(GEMINI_FIRST_PASS_CAP_BYTES="$exact_bytes" FAKE_STDOUT_FILE="$ZEROFOUND" bash "$GFP" < "$FIXTURE_DIFF" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'truncated input'; then
    ok "cap-equality: diffbytes==CAP not truncated"
else
    bad "cap-equality: rc=$rc out=$out (expected no truncated marker)"
fi

# --- test: CRLF gemini-output fixture -> headings parsed, rc=0 ---
# gemini-cli on Windows may return CRLF line endings. The awk normalizer must
# match headings correctly even when lines end with \r.
echo "test: CRLF gemini output -> headings parsed, rc=0" >&2
CRLF_OUT="$TMP/crlf.md"
printf '## Critical Issues (0 found)\r\n## Important Issues (0 found)\r\n## Suggestions (0 found)\r\n' > "$CRLF_OUT"
out="$(FAKE_STDOUT_FILE="$CRLF_OUT" bash "$GFP" < "$FIXTURE_DIFF" 2>"$TMP/err-crlf")"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '## Critical Issues'; then
    ok "CRLF gemini output -> headings parsed, rc=0"
else
    bad "CRLF output: rc=$rc out=$out err=$(cat "$TMP/err-crlf")"
fi

echo "---" >&2
echo "passed=$passed failed=$failed" >&2
[ "$failed" -eq 0 ] || exit 1
exit 0
