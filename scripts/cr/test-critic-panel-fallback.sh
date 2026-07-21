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
        ok)
            printf '# %s First-Pass Review\\n' "\$slug"
            printf '\\n'
            printf '## Critical Issues (0 found)\\n'
            printf '\\n'
            printf '## Important Issues (0 found)\\n'
            printf '\\n'
            printf '## Suggestions (0 found)\\n'
            exit 0 ;;
        generic)
            printf 'connection refused\\n' >&2
            exit 1 ;;
        accessdenied)
            printf 'AccessDenied.Unpurchased: the Model Studio service has not been activated\\n' >&2
            exit 1 ;;
        accessdenied-paired)
            printf 'AccessDenied due to quota limits reached for this model\\n' >&2
            exit 1 ;;
        alloctier)
            # Only the documented code — deliberately NO "quota…exhaust"
            # wording, so this case fails without the HIMMEL-736 branch.
            printf 'Error: 403 AllocationQuota.FreeTierOnly: the platform automatically stopped the service for this model\\n' >&2
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
# Case 0: primary success reports the actual responding model in availability.
# ===========================================================================
run_case ok "$JSON" "$tmp/out0" "$tmp/err0" "$tmp/cap0"
stderr0="$(cat "$tmp/err0")"
check_contains "0: primary ok availability carries responding model" "$stderr0" \
    "panel-availability: qwen3coder ok responding-model($PRI)"
check "0: fallback model NEVER invoked on primary success" \
    "$(grep -cF -- "$FB" "$tmp/cap0")" "0"

# ===========================================================================
# Case 1: quota-exhaustion on primary -> fall back ONCE to OpenRouter, succeed.
# ===========================================================================
run_case exhaust "$JSON" "$tmp/out1" "$tmp/err1" "$tmp/cap1"
out1="$(cat "$tmp/out1")"
stderr1="$(cat "$tmp/err1")"
pri_calls1=$(grep -cF -- "$PRI" "$tmp/cap1")
fb_calls1=$(grep -cF -- "$FB" "$tmp/cap1")

check_contains "1: WARN line names quota-exhaustion + fallback model" "$stderr1" \
    "WARN critic-panel: qwen3coder quota-exhausted - fell back to $FB"
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
check_contains "1b: fallback-failed token with model + rc" "$stderr1b" \
    "panel-availability: qwen3coder fallback-failed($FB) (rc=1)"
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
# HIMMEL-1176: reason= is APPENDED after the untouched (rc=1) — a generic
# "connection refused" body matches no signature -> generic-rc-1.
check_contains "2: reason=generic-rc-1 appended (HIMMEL-1176)" "$stderr2" \
    "panel-availability: qwen3coder unavailable (rc=1) reason=generic-rc-1"

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
# HIMMEL-1176: rc 124/137 always classifies timeout, appended after the
# existing "(timeout Ns)" wording.
check_contains "3: reason=timeout appended (HIMMEL-1176)" "$stderr3" "reason=timeout"

# ===========================================================================
# Case 4: registry row WITHOUT fallback_model + exhaustion failure -> still no
# fallback (an empty fallback_models array gates the retry; nothing else does).
# Locks the contract that no configured fallback means plain unavailable even
# under an exhaustion signature.
# ===========================================================================
JSON_NOFB="$tmp/critics-nofb.json"
printf '{"panel":[{"slug":"qwen3coder","model":"%s","provider":"alibaba-coding-plan","tier":"free","fallback_models":[]}]}' "$PRI" > "$JSON_NOFB"
run_case exhaust "$JSON_NOFB" "$tmp/out4" "$tmp/err4" "$tmp/cap4"
stderr4="$(cat "$tmp/err4")"
check_contains "4: no-fallback row -> plain unavailable on exhaustion" "$stderr4" \
    "panel-availability: qwen3coder unavailable (rc=1)"
check_not_contains "4: NO WARN line" "$stderr4" "WARN critic-panel"
check "4: fallback model NEVER invoked when row has empty fallback_models" \
    "$(grep -cF -- "$FB" "$tmp/cap4")" "0"
# HIMMEL-1176: the primary's own exhaustion-signature text classifies quota-5h
# even though no fallback ran (fallback_models empty gates only the retry).
check_contains "4: reason=quota-5h appended (HIMMEL-1176)" "$stderr4" \
    "panel-availability: qwen3coder unavailable (rc=1) reason=quota-5h"

# ===========================================================================
# Case 5: GENERIC AccessDenied (auth/permission, e.g. Alibaba
# AccessDenied.Unpurchased = service not activated) -> NO fallback (codex
# adversarial CR on HIMMEL-729): falling back would mask a dead primary lane
# as a healthy critic. AccessDenied counts only when PAIRED with an
# exhaustion/quota/arrearage phrase.
# ===========================================================================
run_case accessdenied "$JSON" "$tmp/out5" "$tmp/err5" "$tmp/cap5"
stderr5="$(cat "$tmp/err5")"
check_contains "5: generic AccessDenied -> plain unavailable" "$stderr5" \
    "panel-availability: qwen3coder unavailable (rc=1)"
check_not_contains "5: NO WARN line" "$stderr5" "WARN critic-panel"
check_not_contains "5: NO fallback token" "$stderr5" "fallback("
check "5: fallback model NEVER invoked on bare AccessDenied" \
    "$(grep -cF -- "$FB" "$tmp/cap5")" "0"
# HIMMEL-1176: a bare (unpaired) AccessDenied classifies auth, never a quota
# bucket — the same HIMMEL-729 pairing rule that gates the fallback trigger.
check_contains "5: reason=auth appended, NOT a quota class (HIMMEL-1176)" "$stderr5" \
    "panel-availability: qwen3coder unavailable (rc=1) reason=auth"

# ===========================================================================
# Case 6: AccessDenied PAIRED with a quota phrase -> fallback DOES fire
# (positive coverage for the paired-AccessDenied signature branches; the
# message matches only the AccessDenied.*(quota|...) pair, none of the
# standalone phrases).
# ===========================================================================
run_case accessdenied-paired "$JSON" "$tmp/out6" "$tmp/err6" "$tmp/cap6"
stderr6="$(cat "$tmp/err6")"
check_contains "6: paired AccessDenied+quota -> WARN + fallback" "$stderr6" \
    "WARN critic-panel: qwen3coder quota-exhausted - fell back to $FB"
check "6: fallback invoked exactly once on paired AccessDenied" \
    "$(grep -cF -- "$FB" "$tmp/cap6")" "1"

# ===========================================================================
# Case 7: Alibaba Stop-on-Exhaust 403 AllocationQuota.FreeTierOnly
# (HIMMEL-736) — the documented free-tier-exhaustion code. Matches NO prior
# branch (no "exceeded"/"exhaust" adjacency the old signature required in the
# same clause, no AccessDenied) — must be recognised as exhaustion and fall
# back ONCE to OpenRouter.
# ===========================================================================
run_case alloctier "$JSON" "$tmp/out7" "$tmp/err7" "$tmp/cap7"
stderr7="$(cat "$tmp/err7")"
check_contains "7: AllocationQuota.FreeTierOnly -> WARN + fallback" "$stderr7" \
    "WARN critic-panel: qwen3coder quota-exhausted - fell back to $FB"
check "7: fallback invoked exactly once on FreeTierOnly" \
    "$(grep -cF -- "$FB" "$tmp/cap7")" "1"

# ===========================================================================
# HIMMEL-737 fallback CHAIN (ordered fallback_models array). Cases 1-7 above
# already exercise the LEGACY single-string fallback_model -> 1-element-chain
# path (the $JSON fixture uses "fallback_model"), so legacy back-compat is
# covered. Cases 8-10 below exercise a 2-element chain.
# ===========================================================================
FB1="qwen-plus"
FB2="qwen/qwen3-next-80b-a3b-instruct:free"
CHAIN_JSON="$tmp/critics-chain.json"
printf '{"panel":[{"slug":"qwen3coder","model":"%s","provider":"alibaba-coding-plan","tier":"free","fallback_models":["%s","%s"]}]}' \
    "$PRI" "$FB1" "$FB2" > "$CHAIN_JSON"

# Chain stub: primary always quota-exhausts; each fallback succeeds unless its
# FBn_FAIL env is 1. Records every invoked model to FB_CAPTURE (one per line).
CHAIN_STUB="$tmp/stub-chain.sh"
cat > "$CHAIN_STUB" <<EOS
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
cat >/dev/null
[ -n "\${FB_CAPTURE:-}" ] && printf '%s\n' "\$model" >> "\$FB_CAPTURE"
emit_ok() {
    printf '# %s First-Pass Review\\n' "\$slug"
    printf '\\n'
    printf '## Critical Issues (1 found)\\n'
    printf -- '- [%s-1]: chain fallback caught a bug [foo.sh:3]\\n' "\$slug"
    printf '\\n'
    printf '## Important Issues (0 found)\\n'
    printf '\\n'
    printf '## Suggestions (0 found)\\n'
}
case "\$model" in
    "$PRI") printf 'Alibaba: you have exceeded your allocated quota\\n' >&2; exit 1 ;;
    "$FB1") if [ "\${FB1_FAIL:-0}" = "1" ]; then printf 'fb1 down\\n' >&2; exit 1; fi; emit_ok; exit 0 ;;
    "$FB2") if [ "\${FB2_FAIL:-0}" = "1" ]; then printf 'fb2 down\\n' >&2; exit 1; fi; emit_ok; exit 0 ;;
esac
printf 'stub: unknown model %s\\n' "\$model" >&2
exit 1
EOS
chmod +x "$CHAIN_STUB"

# --- Case 8: chain-of-2, first fallback succeeds -> second NEVER attempted. ---
: > "$tmp/cap8"
printf '%s' "$DIFF" | CRITICS_JSON="$CHAIN_JSON" CRITIC_FIRST_PASS="$CHAIN_STUB" \
    FB_CAPTURE="$tmp/cap8" bash "$PANEL" >"$tmp/out8" 2>"$tmp/err8"
stderr8="$(cat "$tmp/err8")"; out8="$(cat "$tmp/out8")"
check_contains "8: first fallback wins -> fallback($FB1)" "$stderr8" \
    "panel-availability: qwen3coder fallback($FB1)"
check "8: FB1 invoked exactly once" "$(grep -cF -- "$FB1" "$tmp/cap8")" "1"
check "8: FB2 NOT invoked (first success wins)" "$(grep -cF -- "$FB2" "$tmp/cap8")" "0"
check_contains "8: responded 1/1" "$out8" "(1/1 critics responded)"

# --- Case 9: chain-of-2, first fails, second succeeds. ---
: > "$tmp/cap9"
printf '%s' "$DIFF" | CRITICS_JSON="$CHAIN_JSON" CRITIC_FIRST_PASS="$CHAIN_STUB" \
    FB_CAPTURE="$tmp/cap9" FB1_FAIL=1 bash "$PANEL" >"$tmp/out9" 2>"$tmp/err9"
stderr9="$(cat "$tmp/err9")"; out9="$(cat "$tmp/out9")"
check_contains "9: first fallback fails -> fallback-failed($FB1)" "$stderr9" \
    "panel-availability: qwen3coder fallback-failed($FB1) (rc=1)"
# CR round: the fallback-failed line carries a bounded head of the attempt's
# stderr (rate-limit vs auth vs outage stay distinguishable after the temp rm).
check_contains "9: fallback-failed line carries the attempt's stderr head" "$stderr9" \
    "fallback-failed($FB1) (rc=1): fb1 down"
check_contains "9: second fallback succeeds -> fallback($FB2)" "$stderr9" \
    "panel-availability: qwen3coder fallback($FB2)"
check "9: FB1 invoked exactly once" "$(grep -cF -- "$FB1" "$tmp/cap9")" "1"
check "9: FB2 invoked exactly once" "$(grep -cF -- "$FB2" "$tmp/cap9")" "1"
check_contains "9: responded 1/1" "$out9" "(1/1 critics responded)"

# --- Case 10: chain fully exhausted -> both fallback-failed + unavailable, exit 1. ---
: > "$tmp/cap10"
printf '%s' "$DIFF" | CRITICS_JSON="$CHAIN_JSON" CRITIC_FIRST_PASS="$CHAIN_STUB" \
    FB_CAPTURE="$tmp/cap10" FB1_FAIL=1 FB2_FAIL=1 bash "$PANEL" >"$tmp/out10" 2>"$tmp/err10"
rc10=$?
stderr10="$(cat "$tmp/err10")"
check_contains "10: exhausted -> fallback-failed($FB1)" "$stderr10" \
    "panel-availability: qwen3coder fallback-failed($FB1) (rc=1)"
check_contains "10: exhausted -> fallback-failed($FB2)" "$stderr10" \
    "panel-availability: qwen3coder fallback-failed($FB2) (rc=1)"
check_contains "10: exhausted -> unavailable (primary rc preserved)" "$stderr10" \
    "panel-availability: qwen3coder unavailable (rc=1)"
check "10: each fallback invoked exactly once" \
    "$([ "$(grep -cF -- "$FB1" "$tmp/cap10")" = "1" ] && [ "$(grep -cF -- "$FB2" "$tmp/cap10")" = "1" ] && echo ok)" "ok"
check "10: all-exhausted -> exit 1" "$rc10" "1"
# HIMMEL-1176: an exhausted fallback chain keeps the PRIMARY's reason
# (the primary always quota-exhausts in this stub -> quota-5h), never the
# last fallback attempt's, plus a detail note that the chain was exhausted.
check_contains "10: chain-exhausted keeps the PRIMARY's reason=quota-5h" "$stderr10" \
    "panel-availability: qwen3coder unavailable (rc=1) reason=quota-5h detail=fallback-chain exhausted"

# ===========================================================================
# Cases 9p/10p (CR round): the chain must behave identically under
# CRITIC_PARALLEL=1 (process_member runs in the result loop, but the .fb file
# threading is parallel-path wiring). Guarded on the timeout binary like the
# panel suite's parallel tests, to bound CI if something hangs.
# ===========================================================================
if command -v timeout > /dev/null 2>&1; then
    # 9p: first fails, second succeeds (parallel).
    : > "$tmp/cap9p"
    printf '%s' "$DIFF" | CRITICS_JSON="$CHAIN_JSON" CRITIC_FIRST_PASS="$CHAIN_STUB" \
        FB_CAPTURE="$tmp/cap9p" FB1_FAIL=1 CRITIC_PARALLEL=1 \
        timeout 30 bash "$PANEL" >"$tmp/out9p" 2>"$tmp/err9p"
    stderr9p="$(cat "$tmp/err9p")"; out9p="$(cat "$tmp/out9p")"
    check_contains "9p: parallel first fallback fails -> fallback-failed($FB1)" "$stderr9p" \
        "panel-availability: qwen3coder fallback-failed($FB1) (rc=1)"
    check_contains "9p: parallel second fallback succeeds -> fallback($FB2)" "$stderr9p" \
        "panel-availability: qwen3coder fallback($FB2)"
    check "9p: FB1 invoked exactly once" "$(grep -cF -- "$FB1" "$tmp/cap9p")" "1"
    check "9p: FB2 invoked exactly once" "$(grep -cF -- "$FB2" "$tmp/cap9p")" "1"
    check_contains "9p: responded 1/1" "$out9p" "(1/1 critics responded)"

    # 10p: chain fully exhausted (parallel) -> exit 1.
    : > "$tmp/cap10p"
    printf '%s' "$DIFF" | CRITICS_JSON="$CHAIN_JSON" CRITIC_FIRST_PASS="$CHAIN_STUB" \
        FB_CAPTURE="$tmp/cap10p" FB1_FAIL=1 FB2_FAIL=1 CRITIC_PARALLEL=1 \
        timeout 30 bash "$PANEL" >"$tmp/out10p" 2>"$tmp/err10p"
    rc10p=$?
    stderr10p="$(cat "$tmp/err10p")"
    check_contains "10p: parallel exhausted -> fallback-failed($FB1)" "$stderr10p" \
        "panel-availability: qwen3coder fallback-failed($FB1) (rc=1)"
    check_contains "10p: parallel exhausted -> fallback-failed($FB2)" "$stderr10p" \
        "panel-availability: qwen3coder fallback-failed($FB2) (rc=1)"
    check_contains "10p: parallel exhausted -> unavailable" "$stderr10p" \
        "panel-availability: qwen3coder unavailable (rc=1)"
    check "10p: each fallback invoked exactly once" \
        "$([ "$(grep -cF -- "$FB1" "$tmp/cap10p")" = "1" ] && [ "$(grep -cF -- "$FB2" "$tmp/cap10p")" = "1" ] && echo ok)" "ok"
    check "10p: parallel all-exhausted -> exit 1" "$rc10p" "1"
else
    for _i in 1 2 3 4 5 6 7 8 9 10; do echo "ok - 9p/10p: SKIP (no timeout binary)"; done
fi

# ===========================================================================
# Case 11 (HIMMEL-737 integration): quota text reaches the signature END TO
# END through the REAL critic-first-pass.sh. The provider 403 arrives as the
# member's "review" BODY (rc 0, malformed) - before the cfp raw-head stderr
# fix the exhaustion text was buried in a temp file and the chain stayed dark.
# Seam = HERMES_PY (the invoke.sh python shim, as in test-critic-first-pass.sh);
# CRITIC_FIRST_PASS is NOT overridden, so the real cfp path runs. A counter
# makes call 1 (primary) return the 403 body and call 2+ (fallback) a valid
# contract-shaped review.
# ===========================================================================
INT_CNT="$tmp/int-counter"
printf '0' > "$INT_CNT"
INT_PY="$tmp/py-int.sh"
cat > "$INT_PY" <<SHEOF
#!/usr/bin/env bash
n=\$(cat "$INT_CNT"); n=\$((n + 1)); printf '%s' "\$n" > "$INT_CNT"
if [ "\$n" -le 1 ]; then
    printf 'HTTP 403: The free quota has been exhausted\n'
    exit 0
fi
printf '%s\n' '## Critical Issues (1 found)'
printf '%s\n' '- [C-1]: quota chain integration finding [foo.sh:2]'
printf '%s\n' '## Important Issues (0 found)'
printf '%s\n' '## Suggestions (0 found)'
SHEOF
chmod +x "$INT_PY"

printf '%s' "$DIFF" | CRITICS_JSON="$CHAIN_JSON" HERMES_PY="$INT_PY" \
    bash "$PANEL" >"$tmp/out11" 2>"$tmp/err11"
stderr11="$(cat "$tmp/err11")"; out11="$(cat "$tmp/out11")"
check_contains "11: e2e quota body fires the chain (WARN)" "$stderr11" \
    "WARN critic-panel: qwen3coder quota-exhausted - fell back to $FB1"
check_contains "11: e2e fallback availability token" "$stderr11" \
    "panel-availability: qwen3coder fallback($FB1)"
check_contains "11: fallback finding lands in merged stdout" "$out11" \
    "quota chain integration finding"
check_contains "11: responded 1/1 through the real cfp path" "$out11" "(1/1 critics responded)"
check "11: exactly 2 invoke calls (primary + one fallback)" "$(cat "$INT_CNT")" "2"

# ===========================================================================
# HIMMEL-953: fallback_trigger="any" widens the retry condition to ANY
# non-zero rc (incl. timeout), not just a quota-exhaustion signature match —
# opt-in per row (e.g. the qwenor seat, whose whole chain is same-tier
# OpenRouter free candidates: a plain rate-limit on one candidate is reason
# enough to try the next). Reuses $STUB (already supports FB_STUB_MODE
# generic/timeout for the primary model).
# ===========================================================================
JSON_ANY="$tmp/critics-any.json"
printf '{"panel":[{"slug":"qwen3coder","model":"%s","provider":"alibaba-coding-plan","tier":"free","fallback_model":"%s","fallback_provider":"openrouter","fallback_trigger":"any"}]}' \
    "$PRI" "$FB" > "$JSON_ANY"

# --- Case 12: generic non-exhaustion failure (rc=1) -> trigger=any DOES fall back. ---
run_case generic "$JSON_ANY" "$tmp/out12" "$tmp/err12" "$tmp/cap12"
stderr12="$(cat "$tmp/err12")"; out12="$(cat "$tmp/out12")"
fb_calls12=$(grep -cF -- "$FB" "$tmp/cap12")
check_contains "12: generic rc=1 + trigger=any -> WARN with honest (rc=1) wording" "$stderr12" \
    "WARN critic-panel: qwen3coder failed (rc=1) - fell back to $FB"
check_not_contains "12: WARN does NOT claim quota-exhausted for a generic failure" "$stderr12" \
    "quota-exhausted"
check_contains "12: panel-availability fallback(<model>) token" "$stderr12" \
    "panel-availability: qwen3coder fallback($FB)"
check "12: fallback invoked exactly once" "$fb_calls12" "1"
check_contains "12: responded 1/1" "$out12" "(1/1 critics responded)"

# --- Case 13: timeout (rc=124) -> trigger=any DOES fall back (unlike Case 3). ---
run_case timeout "$JSON_ANY" "$tmp/out13" "$tmp/err13" "$tmp/cap13"
stderr13="$(cat "$tmp/err13")"; out13="$(cat "$tmp/out13")"
fb_calls13=$(grep -cF -- "$FB" "$tmp/cap13")
check_contains "13: timeout + trigger=any -> falls back" "$stderr13" \
    "panel-availability: qwen3coder fallback($FB)"
check "13: fallback invoked exactly once on a timed-out primary" "$fb_calls13" "1"
check_contains "13: responded 1/1" "$out13" "(1/1 critics responded)"

# --- Case 14: trigger=any + fallback ALSO fails -> unavailable, rc=1 wording
# preserved for a generic primary failure (not "timeout"). ---
run_case generic "$JSON_ANY" "$tmp/out14" "$tmp/err14" "$tmp/cap14" 1
stderr14="$(cat "$tmp/err14")"
check_contains "14: exhausted generic+any -> plain unavailable (rc=1)" "$stderr14" \
    "panel-availability: qwen3coder unavailable (rc=1)"
check "14: fallback attempted exactly once" "$(grep -cF -- "$FB" "$tmp/cap14")" "1"

# --- Case 15: trigger=any + TIMEOUT + fallback ALSO fails -> unavailable
# keeps the "(timeout Ns)" wording (not "(rc=124)"), since the primary truly
# timed out. ---
run_case timeout "$JSON_ANY" "$tmp/out15" "$tmp/err15" "$tmp/cap15" 1
stderr15="$(cat "$tmp/err15")"
check_contains "15: exhausted timeout+any -> unavailable keeps timeout wording" "$stderr15" \
    "panel-availability: qwen3coder unavailable (timeout"
check "15: fallback attempted exactly once on exhausted timeout+any" "$(grep -cF -- "$FB" "$tmp/cap15")" "1"

# --- Case 16 (codex-adv, HIMMEL-953): a chain of HUNG candidates shares ONE
# seat budget — total fallback wall-clock is bounded by CRITIC_TIMEOUT_SECS
# and candidates past the budget are SKIPPED, not each handed a fresh full
# member timeout (4x240s stacking risk in sequential mode). ---
if command -v timeout >/dev/null 2>&1; then
    FB2="openai/gpt-oss-20b:free"
    JSON_BUDGET="$tmp/critics-budget.json"
    printf '{"panel":[{"slug":"qwen3coder","model":"%s","provider":"alibaba-coding-plan","tier":"free","fallback_models":["%s","%s"],"fallback_trigger":"any"}]}' \
        "$PRI" "$FB" "$FB2" > "$JSON_BUDGET"
    STUB_BUDGET="$tmp/stub-budget.sh"
    cat > "$STUB_BUDGET" <<STUBEOF
#!/usr/bin/env bash
# primary fails fast; every fallback hangs. exec sleep: Git-Bash timeout
# does not reap grandchildren, exec keeps the sleep AS the timed process.
model=""
while [ \$# -gt 0 ]; do [ "\$1" = "--model" ] && model="\$2"; shift; done
cat >/dev/null
printf '%s\n' "\$model" >> "$tmp/cap16"
[ "\$model" = "$PRI" ] && exit 1
exec sleep 999
STUBEOF
    chmod +x "$STUB_BUDGET"
    : > "$tmp/cap16"
    _t16_start=$SECONDS
    printf '%s' "$DIFF" | CRITICS_JSON="$JSON_BUDGET" CRITIC_FIRST_PASS="$STUB_BUDGET" \
        CRITIC_TIMEOUT_SECS=2 bash "$PANEL" >"$tmp/out16" 2>"$tmp/err16"
    _t16_elapsed=$((SECONDS - _t16_start))
    stderr16="$(cat "$tmp/err16")"
    check_contains "16: budget-exhausted line after a hung candidate" "$stderr16" \
        "fallback-chain budget exhausted"
    check "16: candidate past the budget skipped (never invoked)" "$(grep -cF -- "$FB2" "$tmp/cap16")" "0"
    check "16: seat wall-clock bounded (no stacked full timeouts)" "$([ "$_t16_elapsed" -le 8 ] && echo yes)" "yes"
    check_contains "16: member ends unavailable" "$stderr16" \
        "panel-availability: qwen3coder unavailable"
else
    echo "ok - 16: skipped (no timeout binary)"
fi

# --- Case 17 (codex-adv, HIMMEL-953): fallback attempts PRESERVE the row's
# route_provider — an all-OpenRouter chain must not fall back name-routed
# (":free" ids are unresolvable without --provider openrouter). ---
JSON_RP="$tmp/critics-rp.json"
printf '{"panel":[{"slug":"qwenor","model":"%s","provider":"openrouter","route_provider":"openrouter","tier":"free","fallback_models":["%s"],"fallback_trigger":"any","fallback_provider":"openrouter"}]}' \
    "$PRI" "$FB" > "$JSON_RP"
STUB_RP="$tmp/stub-rp.sh"
cat > "$STUB_RP" <<STUBEOF
#!/usr/bin/env bash
model=""; provider=""
while [ \$# -gt 0 ]; do
    [ "\$1" = "--model" ] && model="\$2"
    [ "\$1" = "--provider" ] && provider="\$2"
    shift
done
cat >/dev/null
printf '%s provider=%s\n' "\$model" "\$provider" >> "$tmp/cap17"
if [ "\$model" = "$PRI" ]; then exit 1; fi
printf '%s\n' "# qwenor First-Pass Review" "" "## Critical Issues (0 found)" "" "## Important Issues (0 found)" "" "## Suggestions (0 found)"
STUBEOF
chmod +x "$STUB_RP"
: > "$tmp/cap17"
printf '%s' "$DIFF" | CRITICS_JSON="$JSON_RP" CRITIC_FIRST_PASS="$STUB_RP" \
    bash "$PANEL" >"$tmp/out17" 2>"$tmp/err17"
check "17: fallback invocation carries the row's route_provider" \
    "$(grep -cF -- "$FB provider=openrouter" "$tmp/cap17")" "1"
check_contains "17: fallback succeeded through the routed provider" "$(cat "$tmp/err17")" \
    "panel-availability: qwenor fallback($FB)"

# --- Case 18 (codex-adv, HIMMEL-953): PARALLEL mode — each member's fallback
# must use ITS OWN row's route_provider, not the residual provider of the
# last-parsed registry row. ---
JSON_2P="$tmp/critics-2p.json"
printf '{"panel":[{"slug":"qwenor","model":"%s","provider":"openrouter","route_provider":"openrouter","tier":"free","fallback_models":["%s"],"fallback_trigger":"any","fallback_provider":"openrouter"},{"slug":"other","model":"m2-ok","provider":"alibaba-coding-plan","route_provider":"alibaba-coding-plan","tier":"free","fallback_provider":"alibaba-coding-plan"}]}' \
    "$PRI" "$FB" > "$JSON_2P"
STUB_2P="$tmp/stub-2p.sh"
cat > "$STUB_2P" <<STUBEOF
#!/usr/bin/env bash
model=""; provider=""
while [ \$# -gt 0 ]; do
    [ "\$1" = "--model" ] && model="\$2"
    [ "\$1" = "--provider" ] && provider="\$2"
    shift
done
cat >/dev/null
printf '%s provider=%s\n' "\$model" "\$provider" >> "$tmp/cap18"
if [ "\$model" = "$PRI" ]; then exit 1; fi
printf '%s\n' "# stub First-Pass Review" "" "## Critical Issues (0 found)" "" "## Important Issues (0 found)" "" "## Suggestions (0 found)"
STUBEOF
chmod +x "$STUB_2P"
: > "$tmp/cap18"
printf '%s' "$DIFF" | CRITICS_JSON="$JSON_2P" CRITIC_FIRST_PASS="$STUB_2P" \
    CRITIC_PARALLEL=1 bash "$PANEL" >"$tmp/out18" 2>"$tmp/err18"
check "18: parallel fallback keeps its OWN row's provider" \
    "$(grep -cF -- "$FB provider=openrouter" "$tmp/cap18")" "1"
check "18: parallel fallback never rides the residual row's provider" \
    "$(grep -cF -- "$FB provider=alibaba-coding-plan" "$tmp/cap18")" "0"
check_contains "18: both members responded" "$(cat "$tmp/out18")" "(2/2 critics responded)"

# --- Case 19 (codex-adv, HIMMEL-953): WITHOUT fallback_provider the chain
# stays NAME-ROUTED (empty --provider) — the HIMMEL-729 cross-provider
# contract must survive the opt-in. ---
JSON_NR="$tmp/critics-nr.json"
printf '{"panel":[{"slug":"qwenor","model":"%s","provider":"openrouter","route_provider":"openrouter","tier":"free","fallback_models":["%s"],"fallback_trigger":"any"}]}'     "$PRI" "$FB" > "$JSON_NR"
STUB_NR="$tmp/stub-nr.sh"
sed "s|cap17|cap19|" "$STUB_RP" > "$STUB_NR"
chmod +x "$STUB_NR"
: > "$tmp/cap19"
printf '%s' "$DIFF" | CRITICS_JSON="$JSON_NR" CRITIC_FIRST_PASS="$STUB_NR"     bash "$PANEL" >"$tmp/out19" 2>"$tmp/err19"
check "19: name-routed fallback keeps an EMPTY provider (no row inheritance)"     "$(grep -cF -- "$FB provider=openrouter" "$tmp/cap19")" "0"
check "19: name-routed fallback WAS attempted"     "$(grep -cF -- "$FB provider=" "$tmp/cap19")" "1"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
