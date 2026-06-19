#!/usr/bin/env bash
# scripts/cr/test-critic-panel.sh -- TDD tests for critic-panel.sh (HIMMEL-415).
# Bash 3.2 safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
fails=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    if printf '%s' "$2" | grep -qF "$3"; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected to contain [$3]"
        fails=$((fails + 1))
    fi
}

STUB_PY="$HERE/testdata/stub-cfp.py"

# Create bash wrapper around Python stub
STUB="$tmp/stub-cfp.sh"
printf '%s\n' '#!/usr/bin/env bash' > "$STUB"
printf 'exec python3 "%s" "$@"\n' "$STUB_PY" >> "$STUB"
chmod +x "$STUB"

# Write fixture JSONs
python3 - "$tmp" <<'PYEOF'
import sys, json, os
tmp = sys.argv[1]
data_all = {'panel': [
    {'slug': 'qwen3coder', 'model': 'qwen/qwen3-coder-480b-a35b-instruct', 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'gptoss',     'model': 'openai/gpt-oss-120b',                 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'kimi',       'model': 'moonshotai/kimi-k2.6',                'provider': 'nvidia', 'tier': 'free'},
]}
data_paid = {'panel': [
    {'slug': 'qwen3coder', 'model': 'qwen/qwen3-coder-480b-a35b-instruct', 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'gptoss',     'model': 'openai/gpt-oss-120b',                 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'kimi',       'model': 'moonshotai/kimi-k2.6',                'provider': 'nvidia', 'tier': 'paid'},
]}
data_fail = {'panel': [{'slug': 'kimi', 'model': 'moonshotai/kimi-k2.6', 'provider': 'nvidia', 'tier': 'free'}]}
for nm, d in [('critics-all', data_all), ('critics-paid', data_paid), ('critics-allfail', data_fail)]:
    open(os.path.join(tmp, nm + '.json'), 'w').write(__import__('json').dumps(d))
PYEOF

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,8 @@
 line
+null check missing
+another line
+x = 1
+unused
+rename me
+bar
+baz'

# Test A: merge + global renumber
out_a="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "A: qwen3coder-1 present" "$(printf '%s\n' "$out_a" | grep -cF '[qwen3coder-1]:')" "1"
check "A: qwen3coder-2 present" "$(printf '%s\n' "$out_a" | grep -cF '[qwen3coder-2]:')" "1"
check "A: qwen3coder-3 present" "$(printf '%s\n' "$out_a" | grep -cF '[qwen3coder-3]:')" "1"
check "A: gptoss renumbered to gptoss-4" "$(printf '%s\n' "$out_a" | grep -cF '[gptoss-4]:')" "1"
check "A: no bare gptoss-1" "$(printf '%s\n' "$out_a" | grep -cF '[gptoss-1]:')" "0"

# Test B: member drop -> stderr + header count
stderr_b="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
out_b="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "B: kimi unavailable" "$(printf '%s\n' "$stderr_b" | grep -cF 'panel-availability: kimi unavailable')" "1"
check "B: qwen3coder ok" "$(printf '%s\n' "$stderr_b" | grep -cF 'panel-availability: qwen3coder ok')" "1"
check "B: gptoss ok" "$(printf '%s\n' "$stderr_b" | grep -cF 'panel-availability: gptoss ok')" "1"
check "B: header 2/3" "$(printf '%s\n' "$out_b" | grep -cF '(2/3 critics responded)')" "1"

# Test C: all-fail -> exit 1
printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-allfail.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1
check "C: all-fail -> exit 1" "$?" "1"

# Test D: >=1 responds -> exit 0
printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1
check "D: >=1 responds -> exit 0" "$?" "0"

# Test E: missing registry -> anchor fallback
stderr_e="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/does-not-exist.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
out_e="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/does-not-exist.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "E: warning on missing registry" "$(printf '%s\n' "$stderr_e" | grep -cF 'anchor-only')" "1"
check "E: anchor used (1/1)" "$(printf '%s\n' "$out_e" | grep -cF '(1/1 critics responded)')" "1"
check_contains "E: gptoss finding present" "$out_e" "[gptoss-"

printf '{}' > "$tmp/critics-empty.json"
stderr_e2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-empty.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check "E2: empty JSON -> anchor warning" "$(printf '%s\n' "$stderr_e2" | grep -cF 'anchor-only')" "1"

# Test F: tier filter
out_f="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-paid.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
stderr_f="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-paid.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check "F: paid kimi skipped -> 2/2" "$(printf '%s\n' "$out_f" | grep -cF '(2/2 critics responded)')" "1"
check "F: no kimi in stderr" "$(printf '%s\n' "$stderr_f" | grep -cF 'kimi')" "0"

# Test G: header format
check "G: Critic Panel Review header" "$(printf '%s\n' "$out_b" | grep -cF '# Critic Panel Review')" "1"

# Test H: section headings
check "H: Critical Issues heading" "$(printf '%s\n' "$out_b" | grep -cF '## Critical Issues')" "1"
check "H: Important Issues heading" "$(printf '%s\n' "$out_b" | grep -cF '## Important Issues')" "1"
check "H: Suggestions heading" "$(printf '%s\n' "$out_b" | grep -cF '## Suggestions')" "1"

# Test I1: (N found) recount in merged output
# Two responders: qwen3coder (1 crit, 1 imp, 1 sug) + gptoss (0 crit, 1 imp, 0 sug) = 1 crit, 2 imp, 1 sug
check_contains "I1: Critical Issues (1 found)" "$out_a" "## Critical Issues (1 found)"
check_contains "I1: Important Issues (2 found)" "$out_a" "## Important Issues (2 found)"
check_contains "I1: Suggestions (1 found)" "$out_a" "## Suggestions (1 found)"

# Test I2: malformed-JSON registry falls back to anchor
printf '{not json}' > "$tmp/critics-bad.json"
stderr_i2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-bad.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
out_i2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-bad.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "I2: malformed JSON -> anchor warning" "$(printf '%s\n' "$stderr_i2" | grep -cF 'anchor-only')" "1"
check_contains "I2: malformed JSON -> anchor finding present" "$out_i2" "[gptoss-"

# Test J: per-member timeout — hung member bounded and dropped
STUB_HANG="$tmp/stub-hang.sh"
printf '%s\n' '#!/usr/bin/env bash' > "$STUB_HANG"
printf '%s\n' 'sleep 999' >> "$STUB_HANG"
chmod +x "$STUB_HANG"

HANG_JSON="$tmp/critics-hang.json"
printf '%s\n' '{"panel":[{"slug":"hang-critic","model":"fake/hang","provider":"test","tier":"free"}]}' > "$HANG_JSON"

# Only run this test if 'timeout' is available (same condition as the panel uses)
if command -v timeout > /dev/null 2>&1; then
    j_rc=0
    stderr_j="$(printf '%s' "$DIFF" | CRITIC_TIMEOUT_SECS=2 CRITICS_JSON="$HANG_JSON" CRITIC_FIRST_PASS="$STUB_HANG" \
        timeout 5 bash "$PANEL" 2>&1 >/dev/null)" || j_rc=$?

    check_contains "J1: hung member timeout in stderr" "$stderr_j" "unavailable (timeout 2s)"
    check_contains "J1: hung member slug in stderr" "$stderr_j" "hang-critic"
    check "J1: all-hang -> exit 1" "$j_rc" "1"
else
    echo "ok - J1: SKIP (no timeout binary)"
    echo "ok - J1: SKIP (no timeout binary)"
    echo "ok - J1: SKIP (no timeout binary)"
fi

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
