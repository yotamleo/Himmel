#!/usr/bin/env bash
# scripts/cr/failure-classify.sh — single-source CR critic failure classifier
# (HIMMEL-1176). Exposes classify_failure <rc> [out_file] [err_file], which
# echoes exactly ONE reason class to stdout: timeout, quota-5h, quota-long,
# rate-limit, auth, http-4xx, http-5xx, malformed-output, empty-response, or
# generic-rc-N (N = the literal rc). Also owns is_quota_exhaustion — moved
# here from critic-panel.sh's former _is_quota_exhaustion (HIMMEL-729) so the
# quota-exhaustion signature table lives in exactly ONE place; critic-panel.sh
# sources this file and keeps a thin `_is_quota_exhaustion` wrapper for its
# existing call site.
#
# Functions only — no side effect when sourced. The CLI form below is
# BASH_SOURCE-guarded (mirrors scripts/cr/triviality-gate.sh) so it also runs
# standalone: `bash failure-classify.sh <rc> [out_file] [err_file]`.
# bash 3.2-safe. Deliberately NO top-level `set` (HIMMEL-1176, codex CR): this
# file is SOURCED by critic-panel.sh, and a top-level `set -uo pipefail` would
# mutate the CALLER's shell options — the exact "no side effect when sourced"
# contract this header claims. The functions are written -u-safe (every
# expansion is defaulted) and do not rely on pipefail; the CLI form below sets
# its own options inside the BASH_SOURCE guard.

# ---------------------------------------------------------------------------
# is_quota_exhaustion <out_file> <err_file> (HIMMEL-729; table moved here HIMMEL-1176)
# True if the captured stdout OR stderr matches a quota-exhaustion signature.
# Bare AccessDenied is NOT exhaustion (codex adversarial CR on HIMMEL-729):
# e.g. Alibaba's AccessDenied.Unpurchased means "service not activated" and a
# plain AccessDenied is an auth/permission failure — falling back on those
# would mask a dead primary lane as a healthy critic. AccessDenied counts only
# when PAIRED with an exhaustion/quota/arrearage phrase. Plain .* is correct:
# grep matches line-by-line, so .* can never cross a newline.
# ---------------------------------------------------------------------------
_FC_QUOTA_SIG='exceeded.*quota|quota.*exhaust|Arrearage|Throttling\.User|allocated quota|AllocationQuota\.FreeTierOnly|AccessDenied.*(quota|exhaust|arrear)|(quota|exhaust|arrear).*AccessDenied'

is_quota_exhaustion() {
    if [ -n "${1:-}" ] && [ -f "$1" ] && grep -qiE "$_FC_QUOTA_SIG" "$1"; then
        return 0
    fi
    if [ -n "${2:-}" ] && [ -f "$2" ] && grep -qiE "$_FC_QUOTA_SIG" "$2"; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# classify_failure <rc> [out_file] [err_file]
#
# Precedence (first match wins):
#   timeout > quota-5h > quota-long > rate-limit > auth > http-4xx > http-5xx
#   > malformed-output > empty-response > generic-rc-N
#
# HIMMEL-729 pairing rule preserved: both quota buckets are checked BEFORE
# auth, so a bare AccessDenied/401/403 classifies auth, while the SAME text
# paired with a quota/exhaustion phrase classifies quota-5h/quota-long first —
# auth can only win when no quota phrase is present.
# ---------------------------------------------------------------------------
classify_failure() {
    _cf_rc="${1:-1}"
    _cf_out="${2:-}"
    _cf_err="${3:-}"

    case "$_cf_rc" in
        124|137) echo timeout; return 0 ;;
    esac

    _cf_blob=""
    [ -n "$_cf_out" ] && [ -f "$_cf_out" ] && _cf_blob="$(cat "$_cf_out" 2>/dev/null)"
    [ -n "$_cf_err" ] && [ -f "$_cf_err" ] && _cf_blob="$_cf_blob
$(cat "$_cf_err" 2>/dev/null)"

    _cf_has() { printf '%s' "$_cf_blob" | grep -qiE "$1"; }

    # quota-5h: the existing HIMMEL-729 exhaustion table, the Z.ai 5-hour
    # sentinel (tests/fixtures/glm-cap/cli-tail-0b.txt: "Usage limit reached
    # for the past 5 hours"), or a bare 429 paired with quota-ish wording.
    if is_quota_exhaustion "$_cf_out" "$_cf_err"; then echo quota-5h; return 0; fi
    if _cf_has 'past 5 hours'; then echo quota-5h; return 0; fi
    if _cf_has '(^|[^0-9])429([^0-9]|$)' && _cf_has 'quota|usage limit|insufficient balance|exceeded'; then
        echo quota-5h; return 0
    fi

    # quota-long: weekly/balance/plan-expired sentinels. No CLI-tail fixture
    # exists yet for the weekly window (only the glm-cap monitor-0c.json
    # schema shows a second, weekly TOKENS_LIMIT entry) — this phrasing is a
    # best-effort inference pending a captured weekly-cap error body.
    if _cf_has 'weekly|per[- ]week|7[- ]day|plan (has )?expired|subscription (has )?expired|insufficient balance|balance depleted'; then
        echo quota-long; return 0
    fi

    # rate-limit: plain HTTP 429 without quota phrasing (already excluded above).
    if _cf_has '(^|[^0-9])429([^0-9]|$)'; then echo rate-limit; return 0; fi

    # auth: 401/403, invalid api key, unauthorized, access-denied phrasing.
    if _cf_has '(^|[^0-9])(401|403)([^0-9]|$)|invalid api key|unauthorized|access[ -]?denied|authentication failed'; then
        echo auth; return 0
    fi

    # other 4xx / 5xx.
    if _cf_has '(^|[^0-9])4[0-9][0-9]([^0-9]|$)'; then echo http-4xx; return 0; fi
    if _cf_has '(^|[^0-9])5[0-9][0-9]([^0-9]|$)'; then echo http-5xx; return 0; fi

    # critic-first-pass.sh's own malformed-output fail-open marker.
    if _cf_has 'malformed output'; then echo malformed-output; return 0; fi

    # empty-after-retries: critic-first-pass.sh's "invoke failed (rc=0)" marks
    # a run that returned successfully but with an empty/whitespace-only body
    # after all 3 retries; a wholly empty blob is the same signal.
    _cf_trim="$(printf '%s' "$_cf_blob" | tr -d '[:space:]')"
    if [ -z "$_cf_trim" ] || _cf_has 'invoke failed \(rc=0\)'; then
        echo empty-response; return 0
    fi

    echo "generic-rc-${_cf_rc}"
    return 0
}

# CLI form (not sourced): classify_failure <rc> [out_file] [err_file].
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    set -uo pipefail
    [ $# -ge 1 ] || { echo "usage: failure-classify.sh <rc> [out_file] [err_file]" >&2; exit 2; }
    classify_failure "$1" "${2:-}" "${3:-}"
    exit 0
fi
