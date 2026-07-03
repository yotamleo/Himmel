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

# Test R: registry-sync — the REAL critics.json must keep the panel invariants:
# a non-empty free tier (counting only rows the panel would accept: slug+model+
# tier, mirroring its row filter) and the anchor slug pinned to the anchor model.
# The anchor constants are sourced FROM critic-panel.sh, so this is a live
# cross-check of critics.json against the panel's fallback, not a third copy.
ANCHOR_SLUG="$(sed -n 's/^ANCHOR_SLUG="\(.*\)"$/\1/p' "$PANEL")"
ANCHOR_MODEL="$(sed -n 's/^ANCHOR_MODEL="\(.*\)"$/\1/p' "$PANEL")"
check "R: ANCHOR_SLUG extracted from critic-panel.sh" "$([ -n "$ANCHOR_SLUG" ] && echo yes)" "yes"
check "R: ANCHOR_MODEL extracted from critic-panel.sh" "$([ -n "$ANCHOR_MODEL" ] && echo yes)" "yes"
reg_free="$(python3 - "$HERE/critics.json" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
ok = any(e.get("slug") and e.get("model") and e.get("tier") == "free"
         for e in d.get("panel", []))
print("yes" if ok else "no")
PYEOF
)"
check "R: registry has >=1 valid free-tier critic" "$reg_free" "yes"
reg_anchor="$(python3 - "$HERE/critics.json" "$ANCHOR_SLUG" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
for e in d.get("panel", []):
    if e.get("slug") == sys.argv[2]:
        print(e.get("tier", "") + " " + e.get("model", "")); break
PYEOF
)"
check "R: anchor slug $ANCHOR_SLUG is free-tier + pinned to the panel's ANCHOR_MODEL" "$reg_anchor" "free $ANCHOR_MODEL"

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
check_contains "E: qwen3coder finding present" "$out_e" "[qwen3coder-"
# deliberately tied to the stub's qwen-branch text — proves the anchor MODEL ran
check_contains "E: qwen anchor branch ran" "$out_e" "null dereference in handler"

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
check_contains "I2: malformed JSON -> anchor finding present" "$out_i2" "[qwen3coder-"
# deliberately tied to the stub's qwen-branch text — proves the anchor MODEL ran
check_contains "I2: qwen anchor branch ran" "$out_i2" "null dereference in handler"

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

# Tests K1+K2+K3: parallel mode (CRITIC_PARALLEL=1)
# Wrapped in timeout guard like J1 — parallel tests require the 'timeout' binary
# to bound CI runs if something hangs.
if command -v timeout > /dev/null 2>&1; then

    # K1: Determinism — parallel output must be byte-identical to sequential.
    # The real proof: critic-0 (qwen3coder, index 0 in registry) is SLOW (sleep 2),
    # critic-1 (gptoss, index 1) is INSTANT. In parallel mode critic-1 finishes first,
    # but the merged output MUST still be in registry order (qwen3coder findings first,
    # numbered before gptoss findings). We assert:
    #   (a) parallel stdout == sequential stdout (byte-identical convergence)
    #   (b) qwen3coder slug-IDs come before gptoss slug-IDs in the merged output
    # A bug that merged in completion order would put gptoss-1 before qwen3coder-*
    # and fail both assertions.
    STUB_SLOW="$tmp/stub-cfp-slow.sh"
    # stub-cfp-slow.py: same as stub-cfp.py but qwen3coder sleeps 2s first
    python3 - "$tmp" <<'PYEOF'
import sys, os
src = os.path.join(sys.argv[1], "stub-cfp-slow.py")
open(src, "w").write("""\
#!/usr/bin/env python3
import sys, time

model = ""
slug = ""
args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--model" and i+1 < len(args):
        model = args[i+1]; i += 2
    elif args[i] == "--slug" and i+1 < len(args):
        slug = args[i+1]; i += 2
    else:
        i += 1

sys.stdin.read()

if model == "qwen/qwen3-coder-480b-a35b-instruct":
    time.sleep(2)  # slow: finishes AFTER gptoss in parallel mode
    print("# qwen3coder First-Pass Review")
    print("")
    print("## Critical Issues (1 found)")
    print("- [qwen3coder-1]: null dereference in handler [foo.sh:3]")
    print("")
    print("## Important Issues (1 found)")
    print("- [qwen3coder-2]: unused variable x [foo.sh:5]")
    print("")
    print("## Suggestions (1 found)")
    print("- [qwen3coder-3]: rename for clarity [foo.sh:7]")
    sys.exit(0)
elif model == "openai/gpt-oss-120b":
    # instant: finishes BEFORE qwen3coder in parallel mode
    print("# gptoss First-Pass Review")
    print("")
    print("## Critical Issues (0 found)")
    print("")
    print("## Important Issues (1 found)")
    print("- [gptoss-1]: missing error check [bar.sh:2]")
    print("")
    print("## Suggestions (0 found)")
    sys.exit(0)
else:
    print("stub-cfp-slow: unknown model:", model, file=sys.stderr)
    sys.exit(1)
""")
PYEOF
    printf '%s\n' '#!/usr/bin/env bash' > "$STUB_SLOW"
    printf 'exec python3 "%s/stub-cfp-slow.py" "$@"\n' "$tmp" >> "$STUB_SLOW"
    chmod +x "$STUB_SLOW"

    DATA_2='{"panel":[
  {"slug":"qwen3coder","model":"qwen/qwen3-coder-480b-a35b-instruct","provider":"test","tier":"free"},
  {"slug":"gptoss","model":"openai/gpt-oss-120b","provider":"test","tier":"free"}
]}'
    printf '%s' "$DATA_2" > "$tmp/critics-2.json"

    # (a) byte-identical convergence: slow-critic-0 + instant-critic-1, parallel == sequential
    out_seq="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-2.json" CRITIC_FIRST_PASS="$STUB_SLOW" CRITIC_PARALLEL=0 timeout 30 bash "$PANEL" 2>/dev/null)"
    out_par="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-2.json" CRITIC_FIRST_PASS="$STUB_SLOW" CRITIC_PARALLEL=1 timeout 30 bash "$PANEL" 2>/dev/null)"
    check "K1: parallel output identical to sequential (slow critic-0)" "$out_seq" "$out_par"

    # (b) registry order: qwen3coder-1 must appear before gptoss-* in merged output
    qwen_line="$(printf '%s\n' "$out_par" | grep -n '\[qwen3coder-1\]:' | head -1 | cut -d: -f1)"
    gptoss_line="$(printf '%s\n' "$out_par" | grep -n '\[gptoss-' | head -1 | cut -d: -f1)"
    if [ -n "$qwen_line" ] && [ -n "$gptoss_line" ] && [ "$qwen_line" -lt "$gptoss_line" ]; then
        echo "ok - K1: qwen3coder-* before gptoss-* in merged output (registry order)"
    else
        echo "FAIL - K1: registry order not preserved (qwen3coder line=$qwen_line gptoss line=$gptoss_line)"
        fails=$((fails + 1))
    fi

    # K2: Parallel member-drop — kimi fails in parallel mode; check availability + header
    # Note: critics-all.json has kimi which fails (stub exits 1 for kimi model)
    # Run twice: once for stderr, once for stdout (can't capture both at once cleanly)
    stderr_k2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" CRITIC_PARALLEL=1 timeout 30 bash "$PANEL" 2>&1 >/dev/null)"
    out_k2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" CRITIC_PARALLEL=1 timeout 30 bash "$PANEL" 2>/dev/null)"
    check "K2: parallel kimi unavailable" "$(printf '%s\n' "$stderr_k2" | grep -cF 'panel-availability: kimi unavailable')" "1"
    check "K2: parallel header 2/3" "$(printf '%s\n' "$out_k2" | grep -cF '(2/3 critics responded)')" "1"

else
    echo "ok - K1: SKIP (no timeout binary)"
    echo "ok - K1: SKIP (no timeout binary)"
    echo "ok - K1: SKIP (no timeout binary)"
    echo "ok - K2: SKIP (no timeout binary)"
    echo "ok - K2: SKIP (no timeout binary)"
fi

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
