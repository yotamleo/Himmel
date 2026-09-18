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

# ── HIMMEL-3110: codex's own usage-limit wording, verbatim captured body ───
# (scripts/cr/testdata/codex-usage-limit-2026-09-16.txt). Pre-fix this
# classified generic-rc-1 (confirmed against the pre-fix code before this
# fix landed) — codex says "usage limit" and names an absolute reset date,
# never "quota", "past 5 hours", or a bare 429, so it missed every existing
# bucket.
check "10b: codex captured usage-limit body (fixture, stderr) -> quota-long" \
    "$(bash "$FC" 1 /dev/null "$HERE/testdata/codex-usage-limit-2026-09-16.txt")" \
    "quota-long"
check "10c: same codex phrasing via stdout -> quota-long" \
    "$(classify 1 "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 19th, 2026 10:09 AM." '')" \
    "quota-long"
# ── HIMMEL-3110 regression: "hit your usage limit" alone (no pairing phrase)
# must NOT reach an exhaustion bucket -- the HIMMEL-729 pairing discipline
# extends to the new sentinel, not just the pre-existing ones.
check "10d: usage-limit phrase WITHOUT purchase-credits/try-again pairing -> not quota-long" \
    "$(classify 1 '' 'You have hit your usage limit today.')" "generic-rc-1"
# ── HIMMEL-3110 regression: a bare auth fault must still classify auth, not
# leak into quota-long because it shares no wording with the new sentinel.
check "10e: bare 401 alongside unrelated text -> auth, NOT quota-long" \
    "$(classify 1 '' 'HTTP 401 Unauthorized: token_expired, please re-authenticate')" "auth"

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
check "18b: 400 Bad Request (no HTTP/status/code keyword) -> still http-4xx" \
    "$(classify 1 '' '400 Bad Request')" "http-4xx"
check "18c: 500 Internal Server Error with no leading HTTP -> still http-5xx" \
    "$(classify 1 '' 'curl: (22) 500 Internal Server Error')" "http-5xx"

# ── HIMMEL-2107: a ticket ID inside usage text is not an HTTP status ───────
check "16b: usage text containing HIMMEL-473 -> not http-4xx (rc=2 usage-error)" \
    "$(classify 2 '' 'critic-first-pass.sh: empty stdin — pipe a unified diff
Usage: git diff origin/HEAD...HEAD | critic-first-pass.sh --model <name>
The review prompt is adapted to the model FAMILY (HIMMEL-473): gpt/codex, open, claude.
Exit: 0 = findings emitted; 1 = invoke failed; 2 = usage error.')" \
    "usage-error"
check "16c: same HIMMEL-473 text under a non-usage rc still avoids http-4xx" \
    "$(classify 1 '' 'adapted to the model FAMILY (HIMMEL-473): gpt/codex, open, claude.')" \
    "generic-rc-1"

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

# ── first_signal_line <file> (HIMMEL-3105): the FIRST line of a captured body
# that carries a provider-failure signature. Feeds the ledger detail (so the
# provider error line, not the last stderr line, is what the avail row shows)
# and critic-first-pass.sh's "raw signal:" line for bodies whose decisive line
# sits outside the raw-tail bound. Shares failure-classify.sh's signature
# table, so it cannot drift from classify_failure.
fsl() {
    printf '%s' "$1" > "$tmp/fsl_in"
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    ( . "$FC"; first_signal_line "$tmp/fsl_in" )
}
check "29: banner then 429 line -> the 429 line, not the banner" \
    "$(fsl 'A previous hermes update pulled new code; restart the gateway daemon.
Provider said: HTTP 429: The usage limit has been reached
Contact support if this persists.')" \
    "Provider said: HTTP 429: The usage limit has been reached"
check "30: quota wording without a status code is a signal line" \
    "$(fsl 'prelude
The free quota has been exhausted
tail')" \
    "The free quota has been exhausted"
check "31: no signature anywhere -> empty" "$(fsl 'model prose with no failure text at all')" ""
check "32: cfp's own Raw output: path line is never a signal (random mktemp suffix)" \
    "$(fsl 'critic-first-pass.sh: malformed output — fail-open. Raw output: /tmp/cfp-raw.a429bc')" ""
check "33: a ticket ID (HIMMEL-473) is not a status-code signal" \
    "$(fsl 'adapted to the model FAMILY (HIMMEL-473)')" ""
_fsl_long="$(fsl "HTTP 429 $(printf 'x%.0s' $(seq 1 400))")"
check "34: signal line is bounded to 300 chars" "${#_fsl_long}" "300"
_fsl_missing="$(
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    . "$FC"; first_signal_line "$tmp/does-not-exist"; echo "rc=$?"
)"
check "35: missing file -> empty, rc 0" "$_fsl_missing" "rc=0"
# The signature set must cover every distinctive token classify_failure keys a
# non-generic class on (CodeRabbit round 1): a quota-long line outside the raw
# tail has to surface, and a bare "usage limit" (which classify_failure alone
# never acts on, see 3110 above) must not select prose over the real line.
check "36: codex 'hit your usage limit' line is a signal" \
    "$(fsl "prelude
You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 19th, 2026 10:09 AM.
tail")" \
    "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 19th, 2026 10:09 AM."
check "37: plan-expired (quota-long sentinel) line is a signal" \
    "$(fsl 'prelude
Your plan has expired
tail')" \
    "Your plan has expired"
check "38: weekly-cap (quota-long sentinel) line is a signal" \
    "$(fsl 'prelude
Weekly cap reached for this account
tail')" \
    "Weekly cap reached for this account"
check "39: a bare 'usage limit' in prose is not a signal (classify_failure never acts on it alone)" \
    "$(fsl 'The reviewer mentioned a usage limit in passing.')" ""

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
