#!/usr/bin/env bash
# scripts/cr/test-critic-first-pass.sh — TDD tests for critic-first-pass.sh (HIMMEL-415).
# Deterministic: HERMES_PY is set to a bash shim that ignores its args and
# prints canned output — no live hermes, no network.
#
# Stub mechanism: invoke.sh calls "$py" -c '<snippet>'. The shim (py.sh)
# ignores all argv (including the -c snippet) and execs python with stub.py,
# which prints canned contract-shaped output. The -c snippet never runs so
# 'from hermes_cli.main import main' is never attempted.
# Bash 3.2 safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFP="$HERE/critic-first-pass.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check(){ if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }

# Stub python: prints a canned, contract-shaped review with a valid citation.
# The citation [foo.sh:3] is within the hunk range of the DIFF below (+1,2 -> lines 1-2...
# actually diff @@ -1,2 +1,3 @@ means new-file lines 1-3, so line 3 is in range).
cat > "$tmp/stub.py" <<'PY'
import os
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY

# invoke.sh execs: "$py" -c '<snippet reading HERMES_PROMPT_FILE>'. The snippet
# imports hermes_cli; our stub must satisfy that call. The shim ignores -c and
# all other argv, then runs stub.py via plain python — hermes_cli import never
# attempted. This is the proven path: shim ignores argv, python runs stub.py.
cat > "$tmp/py.sh" <<PY
#!/usr/bin/env bash
exec python3 "$tmp/stub.py"
PY
chmod +x "$tmp/py.sh"

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 line
+for i in 1 2 3; do :; done
+another line'

# --- test: derived slug in header + ID ---
out="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model qwen/qwen3-coder-480b-a35b-instruct 2>/dev/null)"
# slug derives to: qwen3coder480ba3 (last segment after /, lowercased, non-alnum stripped, 16 chars)
check "header carries slug" "$(printf '%s' "$out" | grep -c '^# qwen3coder480ba3 First-Pass Review')" "1"
check "finding renumbered to slug-1" "$(printf '%s' "$out" | grep -c '\[qwen3coder480ba3-1\]')" "1"

# --- test: --slug override ---
cat > "$tmp/stub.py" <<'PY'
import os
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
out2="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug qwen3coder 2>/dev/null)"
check "explicit slug used" "$(printf '%s' "$out2" | grep -c '\[qwen3coder-1\]')" "1"

# --- test: missing --model is a usage error (rc 2) ---
printf '%s' "$DIFF" | bash "$CFP" >/dev/null 2>&1; check "missing model rc2" "$?" "2"

# --- test: citation guard still drops out-of-range cites ---
cat > "$tmp/stub.py" <<'PY'
import os
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: bogus [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
out3="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug s 2>/dev/null)"
check "hallucinated cite dropped" "$(printf '%s' "$out3" | grep -c '^## Critical Issues (0 found)')" "1"

# --- test: retry recovers on first-attempt empty response ---
# Counter file: bash shim increments it, decides which stub.py to exec.
counter_file="$tmp/retry_counter"
printf '0' > "$counter_file"
cat > "$tmp/stub_retry_empty.py" <<'PY'
# Returns nothing (empty output, rc 0) — simulates hermes producing no response.
PY
cat > "$tmp/stub_retry_good.py" <<'PY'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
# The shim increments a bash counter, then picks empty on call 1 and good from call 2 onward.
cat > "$tmp/py_retry.sh" <<SHEOF
#!/usr/bin/env bash
n=\$(cat "$counter_file")
n=\$((n + 1))
printf '%s' "\$n" > "$counter_file"
if [ "\$n" -le 1 ]; then
    exec python3 "$tmp/stub_retry_empty.py"
else
    exec python3 "$tmp/stub_retry_good.py"
fi
SHEOF
chmod +x "$tmp/py_retry.sh"
out4="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py_retry.sh" bash "$CFP" --model x/y --slug s 2>/dev/null)"
rc4=$?
check "retry recovers rc" "$rc4" "0"
check "retry recovers output" "$(printf '%s' "$out4" | grep -c '^## Critical Issues (1 found)')" "1"
check "retry used 2 attempts" "$(cat "$counter_file")" "2"

# --- test: fail-open after exhaustion (3 retries all empty) ---
counter_file2="$tmp/exhaust_counter"
printf '0' > "$counter_file2"
cat > "$tmp/stub_exhaust_empty.py" <<'PY'
# Always returns nothing (empty output, rc 0).
PY
cat > "$tmp/py_exhaust.sh" <<SHEOF
#!/usr/bin/env bash
n=\$(cat "$counter_file2")
n=\$((n + 1))
printf '%s' "\$n" > "$counter_file2"
exec python3 "$tmp/stub_exhaust_empty.py"
SHEOF
chmod +x "$tmp/py_exhaust.sh"
printf '%s' "$DIFF" | HERMES_PY="$tmp/py_exhaust.sh" bash "$CFP" --model x/y --slug s >/dev/null 2>&1
rc5=$?
check "exhausted retries fail-open rc1" "$rc5" "1"
check "exhausted retries tried 3 times" "$(cat "$counter_file2")" "3"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
