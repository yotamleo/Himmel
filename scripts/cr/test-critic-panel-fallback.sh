#!/usr/bin/env bash
# scripts/cr/test-critic-panel-fallback.sh -- HIMMEL-729 quota-exhaustion fallback.
# Focused tests for the panel's per-member QUOTA-EXHAUSTION -> OpenRouter
# fallback + visible WARN (the consumer half of the alibaba quota guard).
#
# The panel's member seam is CRITIC_FIRST_PASS (critic-first-pass.sh), stubbed
# here exactly as test-critic-panel.sh stubs it. The stub simulates, per model:
#   - primary (qwen3-coder-plus)        : fails, behaviour set by FB_STUB_MODE
#   - fallback (qwen/qwen3-...:free)    : succeeds (or fails if FB_FALLBACK_FAIL=1)
# Bash 3.2 safe.
set -uo pipefail

# Hermetic: the panel reads CR_PROFILE (HIMMEL-558). Clear ambient values so the
# default free-tier path is used.
unset CR_PROFILE CRITIC_PANEL_TIERS 2>/dev/null || true

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
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected to contain [$3]"
        fails=$((fails + 1))
    fi
}

check_not_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "FAIL - $1: expected NOT to contain [$3]"
        fails=$((fails + 1))
    else
        echo "ok - $1"
    fi
}

# --- Fixture: 1-row free panel, anchor with the OpenRouter fallback pinned. ---
PRI="qwen3-coder-plus"
FB="qwen/qwen3-next-80b-a3b-instruct:free"
JSON="$tmp/critics-fb.json"
printf '{"panel":[{"slug":"qwen3coder","model":"%s","provider":"alibaba-coding-plan","tier":"free","fallback_model":"%s","fallback_provider":"openrouter"}]}' \
    "$PRI" "$FB" > "$JSON"

# --- Stub for CRITIC_FIRST_PASS. Records every invocation's model to
# $FB_CAPTURE so the tests can prove "exactly one fallback attempt". ---
STUB="$tmp/stub-cfp.sh"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
set -uo pipefail
model=""
slug=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --model) model="\$2"; shift 2 ;;
        --slug)  slug="\$2";  shift 2 ;;
        --perspective-file) shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null   # consume the diff on stdin
[ -n "\${FB_CAPTURE:-}" ] && printf '%s\n' "\$model" >> "\$FB_CAPTURE"

if [ "\$model" = "$FB" ]; then
    if [ "\${FB_FALLBACK_FAIL:-0}" = "1" ]; then
        printf 'fallback provider also down\\n' >&2
        exit 1
    fi
    printf '# %s First-Pass Review\\n' "\$slug"
    printf '\\n'
    printf '## Critical Issues (1 found)\\n'
    printf -- '- [%s-1]: fallback caught a null deref in handler [foo.sh:3]\\n' "\$slug"
    printf '\\n'
    printf '## Important Issues (0 found)\\n'
    printf '\\n'
    printf '## Suggestions (0 found)\\n'
    exit 0
fi

if [ "\$model" = "$PRI" ]; then
    case "\${FB_STUB_MODE:-exhaust}" in
        exhaust)
            printf 'Alibaba: you have exceeded your allocated quota for qwen3-coder-plus\\n' >&2
            exit 1 ;;
        generic)
            printf 'connection refused\\n' >&2
            exit 1 ;;
        timeout)
            exit 124 ;;
    esac
fi
printf 'stub: unknown model %s\\n' "\$model" >&2
exit 1
EOS
chmod +x "$STUB"

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 line
+null check missing
+x = 1'

# Each case runs the panel ONCE, capturing stdout+stderr to files (not via
# command substitution) so the per-case FB_CAPTURE invocation counts are exact.
run_case() {
    # $1=mode $2=json $3=out_file $4=err_file $5=capture_file [$6=fb_fail]
    _mode="$1"; _json="$2"; _outf="$3"; _errf="$4"; _cap="$5"; _fbf="${6:-0}"
    : > "$_cap"
    printf '%s' "$DIFF" | CRITICS_JSON="$_json" CRITIC_FIRST_PASS="$STUB" \
        FB_STUB_MODE="$_mode" FB_FALLBACK_FAIL="$_fbf" FB_CAPTURE="$_cap" \
        bash "$PANEL" >"$_outf" 2>"$_errf"
}

# ===========================================================================
# Case 1: quota-exhaustion on primary -> fall back ONCE to OpenRouter, succeed.
# ===========================================================================
run_case exhaust "$JSON" "$tmp/out1" "$tmp/err1" "$tmp/cap1"
out1="$(cat "$tmp/out1")"
stderr1="$(cat "$tmp/err1")"
pri_calls1=$(grep -cF -- "$PRI" "$tmp/cap1")
fb_calls1=$(grep -cF -- "$FB" "$tmp/cap1")

check_contains "1: WARN line names quota-exhaustion + fallback model" "$stderr1" \
    "WARN critic-panel: qwen3coder quota-exhausted - fell back to $FB (openrouter)"
check_contains "1: panel-availability fallback(<model>) token" "$stderr1" \
    "panel-availability: qwen3coder fallback($FB)"
check "1: NO plain unavailable for qwen3coder" \
    "$(printf '%s\n' "$stderr1" | grep -cF 'panel-availability: qwen3coder unavailable')" "0"
check_contains "1: fallback member finding in merged stdout" "$out1" "fallback caught a null deref"
check_contains "1: responded 1/1 (fallback counts)" "$out1" "(1/1 critics responded)"
check "1: primary invoked exactly once" "$pri_calls1" "1"
check "1: fallback invoked exactly once (no retry loop)" "$fb_calls1" "1"

# ===========================================================================
# Case 1b: exhaustion on primary AND fallback also fails -> fallback-failed,
# still exactly ONE fallback attempt (no retry loop).
# ===========================================================================
run_case exhaust "$JSON" "$tmp/out1b" "$tmp/err1b" "$tmp/cap1b" 1
stderr1b="$(cat "$tmp/err1b")"
fb_calls1b=$(grep -cF -- "$FB" "$tmp/cap1b")
check_contains "1b: original unavailable line preserved" "$stderr1b" \
    "panel-availability: qwen3coder unavailable (rc=1)"
check_contains "1b: fallback-failed token with rc" "$stderr1b" \
    "panel-availability: qwen3coder fallback-failed (rc=1)"
check "1b: fallback attempted exactly once even on its own failure" "$fb_calls1b" "1"

# ===========================================================================
# Case 2: non-exhaustion failure (rc=1, generic error) -> NO fallback.
# ===========================================================================
run_case generic "$JSON" "$tmp/out2" "$tmp/err2" "$tmp/cap2"
stderr2="$(cat "$tmp/err2")"
fb_calls2=$(grep -cF -- "$FB" "$tmp/cap2")
check_contains "2: plain unavailable (rc=1)" "$stderr2" "panel-availability: qwen3coder unavailable (rc=1)"
check_not_contains "2: NO WARN line" "$stderr2" "WARN critic-panel"
check_not_contains "2: NO fallback token" "$stderr2" "fallback("
check "2: fallback model NEVER invoked" "$fb_calls2" "0"

# ===========================================================================
# Case 3: timeout (rc=124) -> NO fallback (timeout is never exhaustion).
# ===========================================================================
run_case timeout "$JSON" "$tmp/out3" "$tmp/err3" "$tmp/cap3"
stderr3="$(cat "$tmp/err3")"
fb_calls3=$(grep -cF -- "$FB" "$tmp/cap3")
check_contains "3: timeout-unavailable line" "$stderr3" "panel-availability: qwen3coder unavailable (timeout"
check_not_contains "3: NO WARN line" "$stderr3" "WARN critic-panel"
check_not_contains "3: NO fallback token" "$stderr3" "fallback("
check "3: fallback model NEVER invoked on timeout" "$fb_calls3" "0"

# ===========================================================================
# Case 4: registry row WITHOUT fallback_model + exhaustion failure -> still no
# fallback (the fallback_model column gates the retry; nothing else does).
# Locks the contract that absence of fallback_model means plain unavailable even
# under an exhaustion signature.
# ===========================================================================
JSON_NOFB="$tmp/critics-nofb.json"
printf '{"panel":[{"slug":"qwen3coder","model":"%s","provider":"alibaba-coding-plan","tier":"free"}]}' "$PRI" > "$JSON_NOFB"
run_case exhaust "$JSON_NOFB" "$tmp/out4" "$tmp/err4" "$tmp/cap4"
stderr4="$(cat "$tmp/err4")"
check_contains "4: no-fallback row -> plain unavailable on exhaustion" "$stderr4" \
    "panel-availability: qwen3coder unavailable (rc=1)"
check_not_contains "4: NO WARN line" "$stderr4" "WARN critic-panel"
check "4: fallback model NEVER invoked when row has no fallback_model" \
    "$(grep -cF -- "$FB" "$tmp/cap4")" "0"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
