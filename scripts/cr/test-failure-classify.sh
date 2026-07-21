#!/usr/bin/env bash
# scripts/cr/test-failure-classify.sh -- TDD tests for failure-classify.sh
# (HIMMEL-1176). Bash 3.2 safe.
# shellcheck disable=SC2015  # A && B || C intentional in the final assert
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FC="$HERE/failure-classify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

# classify <rc> <out_text> <err_text> -> echoes the class via the CLI form.
classify() {
    _rc="$1"; _out_text="${2:-}"; _err_text="${3:-}"
    _outf="$tmp/out"; _errf="$tmp/err"
    printf '%s' "$_out_text" > "$_outf"
    printf '%s' "$_err_text" > "$_errf"
    bash "$FC" "$_rc" "$_outf" "$_errf"
}

# ── Precedence: timeout beats everything, incl. quota text in the body ─────
check "1: rc=124 -> timeout" "$(classify 124 '' 'exceeded your allocated quota')" "timeout"
check "2: rc=137 -> timeout" "$(classify 137 '' '')" "timeout"

# ── quota-5h: Z.ai 5h sentinel (glm-cap fixture cli-tail-0b.txt) ───────────
check "3: Z.ai 5h phrase -> quota-5h" \
    "$(classify 1 '' 'API Error: Request rejected (429) · [1316][Usage limit reached for the past 5 hours. Insufficient balance for extra usage][mock0b]')" \
    "quota-5h"

# ── quota-5h: existing HIMMEL-729 exhaustion table (Alibaba examples) ──────
check "4: exceeded allocated quota -> quota-5h" \
    "$(classify 1 '' 'Alibaba: you have exceeded your allocated quota for qwen3-coder-plus')" "quota-5h"
check "5: AllocationQuota.FreeTierOnly -> quota-5h" \
    "$(classify 1 '' 'Error: 403 AllocationQuota.FreeTierOnly: the platform automatically stopped the service')" "quota-5h"
check "6: AccessDenied PAIRED with quota -> quota-5h" \
    "$(classify 1 '' 'AccessDenied due to quota limits reached for this model')" "quota-5h"
check "7: bare 429 + quota wording -> quota-5h" \
    "$(classify 1 '' 'HTTP 429: quota exceeded, please retry later')" "quota-5h"

# ── quota-long: weekly/balance/plan-expired sentinels ──────────────────────
check "8: weekly limit phrase -> quota-long" \
    "$(classify 1 '' 'Your weekly usage limit has been reached')" "quota-long"
check "9: plan expired phrase -> quota-long" \
    "$(classify 1 '' 'Your plan has expired, please renew')" "quota-long"
check "10: standalone insufficient balance -> quota-long" \
    "$(classify 1 '' 'Insufficient balance for this request')" "quota-long"

# ── rate-limit: plain 429, no quota phrasing ───────────────────────────────
check "11: bare 429 -> rate-limit" "$(classify 1 '' 'HTTP 429 Too Many Requests')" "rate-limit"

# ── auth: 401/403/invalid-api-key/bare AccessDenied (HIMMEL-729 pairing) ───
check "12: 401 -> auth" "$(classify 1 '' 'HTTP 401 Unauthorized')" "auth"
check "13: 403 -> auth" "$(classify 1 '' 'HTTP 403 Forbidden')" "auth"
check "14: invalid api key -> auth" "$(classify 1 '' 'Error: invalid API key provided')" "auth"
check "15: bare AccessDenied (unpaired) -> auth, NOT quota" \
    "$(classify 1 '' 'AccessDenied.Unpurchased: the Model Studio service has not been activated')" "auth"

# ── other 4xx / 5xx ─────────────────────────────────────────────────────────
check "16: 422 -> http-4xx" "$(classify 1 '' 'HTTP 422 Unprocessable Entity')" "http-4xx"
check "17: 500 -> http-5xx" "$(classify 1 '' 'HTTP 500 Internal Server Error')" "http-5xx"
check "18: 503 -> http-5xx" "$(classify 1 '' 'HTTP 503 Service Unavailable')" "http-5xx"

# ── malformed-output marker (critic-first-pass.sh's own fail-open text) ────
check "19: malformed output marker -> malformed-output" \
    "$(classify 1 '' 'critic-first-pass.sh: malformed output — fail-open, proceed claude-only. Raw output: /tmp/x')" \
    "malformed-output"

# ── empty-after-retries ─────────────────────────────────────────────────────
check "20: wholly empty out+err -> empty-response" "$(classify 1 '' '')" "empty-response"
check "21: critic-first-pass rc=0 empty-body marker -> empty-response" \
    "$(classify 1 '' 'critic-first-pass.sh: invoke failed (rc=0) — fail-open, proceed claude-only. Raw output: /tmp/x')" \
    "empty-response"
check "22: whitespace-only blob -> empty-response" "$(classify 1 '
   ' '')" "empty-response"

# ── generic-rc-N fallback (no signature matches anything) ──────────────────
check "23: unrecognized text -> generic-rc-N" "$(classify 42 '' 'connection refused')" "generic-rc-42"
check "24: rc literal embedded in class name" "$(classify 7 '' 'some totally novel error')" "generic-rc-7"

# ── is_quota_exhaustion: sourced function, still usable directly ───────────
printf '%s' 'exceeded your allocated quota' > "$tmp/qe_out"
printf '%s' '' > "$tmp/qe_err"
(
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    . "$FC"
    if is_quota_exhaustion "$tmp/qe_out" "$tmp/qe_err"; then echo yes; else echo no; fi
) > "$tmp/qe_result"
check "25: is_quota_exhaustion true on exhaustion signature" "$(cat "$tmp/qe_result")" "yes"

(
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    . "$FC"
    if is_quota_exhaustion "$tmp/out" "$tmp/err"; then echo yes; else echo no; fi
) > "$tmp/qe_result2" 2>/dev/null || true
# reuse the last classify()'s leftover files (bare "connection refused" — no signature)
check "26: is_quota_exhaustion false on a non-exhaustion body" "$(cat "$tmp/qe_result2")" "no"

# ── sourcing is side-effect-free (no `set -e` leak into the caller) ────────
(
    set +e
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    . "$FC"
    false  # would abort a script under -e; must NOT here
    echo "survived"
) > "$tmp/source_result"
check "27: sourcing does not leak errexit" "$(cat "$tmp/source_result")" "survived"

# ── sourcing does not leak nounset into the caller (HIMMEL-1176, codex CR) ──
(
    set +u
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    . "$FC"
    # A bare unset-var expansion aborts this subshell if `set -u` leaked in from
    # the sourced file; with the fix (set moved into the CLI-only guard) it just
    # expands empty and we reach the echo.
    # shellcheck disable=SC2154
    : "$DELIBERATELY_UNSET_VAR"
    echo "survived"
) > "$tmp/source_result2" 2>/dev/null
check "28: sourcing does not leak nounset" "$(cat "$tmp/source_result2")" "survived"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
