#!/usr/bin/env bash
# Smoke test for the luna template's graphify-out ignore block + RETASK-nonce
# gitleaks allowlist (HIMMEL-3003).
#
# Asserts:
#   1. `git check-ignore` matches graphify-out/graph.json under the template
#      .gitignore.
#   2. Baseline (RED): the same RETASK nonce leaks under the template's
#      ruleset WITHOUT the new allowlist regex — proves the nonce would
#      otherwise trip the generic-api-key rule, not that gitleaks silently
#      no-ops on this fixture.
#   3. A RETASK nonce alone (e.g. `token="Y-N204-a68d71"`) does NOT leak  # gitleaks:allow
#      against the template .gitleaks.toml (GREEN — the new allowlist entry
#      is what suppresses the baseline finding above).
#   4. RED-preserving control: the same nonce SUFFIXED with a real-looking
#      credential still leaks — the allowlist regex is anchored to the exact
#      nonce shape, not a prefix match. The finding's own `.Secret` field
#      (not the whole report) is checked for the nonce prefix, so an
#      unrelated rule matching only the suffix does not count as proof the
#      allowlist anchor still holds.
#   5-7. (HIMMEL-3168) The same baseline / allowlisted / anchor-control shape
#      for the 16-hex nonce (`B-N44-<16 hex>`): allowlisted, while a 17-hex
#      tail and a credential-suffixed 16-hex nonce still leak.
#
# `run_gitleaks` classifies gitleaks' own exit code rather than treating any
# nonzero as "leak found": 0 = clean, 1 = leak found (gitleaks' documented
# --exit-code default), anything else = a scanner/config error, which fails
# the assertion regardless of which outcome was expected.
#
# Skips (with an explicit SKIP verdict, never a silent pass) if gitleaks is
# not on PATH.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Usage: bash scripts/test-template-graphify-ignore.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPL="$ROOT/templates/luna-second-brain"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
skip() { echo "SKIP - $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/template-graphify-ignore.XXXXXX")" || {
    echo "FAIL - mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. .gitignore: graphify-out/ is ignored.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/repo"
git init -q "$WORK/repo"
# Disable the user's own global core.excludesFile for this repo so the
# assertion can only pass because of the copied .gitignore, never because
# graphify-out/ happens to be ignored globally on the machine running the
# test (codex-adv round 4 finding).
git -C "$WORK/repo" config core.excludesFile /dev/null
cp "$TMPL/.gitignore" "$WORK/repo/.gitignore"
if git -C "$WORK/repo" check-ignore -q graphify-out/graph.json; then
    ok "template .gitignore matches graphify-out/graph.json"
else
    bad "template .gitignore does NOT match graphify-out/graph.json"
fi

# ---------------------------------------------------------------------------
# 2-4. gitleaks: baseline leaks, allowlisted nonce doesn't, suffixed does.
# ---------------------------------------------------------------------------
if ! command -v gitleaks >/dev/null 2>&1; then
    skip "gitleaks not on PATH — nonce-allowlist rows not run"
elif ! command -v jq >/dev/null 2>&1; then
    skip "jq not on PATH — nonce-allowlist rows not run"
else
    FIX="$WORK/fixtures"
    mkdir -p "$FIX"
    printf 'token="Y-N204-a68d71"\n' > "$FIX/nonce-alone.txt" # gitleaks:allow
    # base64'd, never a contiguous Stripe-shaped literal in this tracked file
    # — GitHub push protection (and our own gitleaks pre-commit hook) scans
    # committed blobs for exactly that shape, so a real key literal here gets
    # the whole push rejected even though it is only a test fixture
    # (HIMMEL-3003 follow-up). A split-printf fixture was tried instead but
    # still tripped the stripe-access-token rule: gitleaks scans by LINE, and
    # one fragment alone ("sk_live_" + 10+ chars) still matches the rule's
    # length threshold even split across printf arguments.
    # `-d`/`-D` fallback: GNU coreutils base64 decodes with -d; BSD base64
    # (macOS) requires -D — try both so the fixture builds on either.
    if ! base64 -d <<<'dG9rZW49IlktTjIwNC1hNjhkNzEtc2tfbGl2ZV80ZUMzOUhxTHlqV0Rhcmp0VDF6ZHA3ZGMiCg==' > "$FIX/nonce-suffixed.txt" 2>/dev/null; then
        base64 -D <<<'dG9rZW49IlktTjIwNC1hNjhkNzEtc2tfbGl2ZV80ZUMzOUhxTHlqV0Rhcmp0VDF6ZHA3ZGMiCg==' > "$FIX/nonce-suffixed.txt"
    fi

    # Baseline config = the template's own .gitleaks.toml with the new
    # RETASK-nonce allowlist regex stripped out, so it still carries
    # useDefault + every OTHER allowlist entry — isolating just the one
    # line this ticket adds.
    BASELINE_CFG="$WORK/gitleaks-baseline.toml"
    grep -vF 'N[0-9]+-[0-9a-f]' "$TMPL/.gitleaks.toml" > "$BASELINE_CFG"

    # run_gitleaks <source> <config> <report-path>; sets GITLEAKS_RC to
    # gitleaks' own exit code (0 clean, 1 leak found, anything else a
    # scanner/config error).
    run_gitleaks() {
        gitleaks detect --no-git --source "$1" \
            --config "$2" --no-banner \
            --report-path "$3" --report-format json >/dev/null 2>&1
        GITLEAKS_RC=$?
    }

    # Exit 1 alone does not prove a LEAK was found — gitleaks can also exit 1
    # on some scanner/config errors, so a broken baseline config could satisfy
    # this branch without ever matching the nonce (codex-adv round 6 finding).
    # Require a JSON finding whose Secret is the nonce and whose RuleID is
    # generic-api-key (confirmed the rule this fixture trips under the
    # template's ruleset).
    BASELINE_REPORT="$WORK/report-baseline.json"
    run_gitleaks "$FIX/nonce-alone.txt" "$BASELINE_CFG" "$BASELINE_REPORT"
    case "$GITLEAKS_RC" in
        1)
            if jq -e --arg nonce 'Y-N204-a68d71' \
                'any(.[]; .RuleID == "generic-api-key" and (.Secret // "") == $nonce)' \
                "$BASELINE_REPORT" >/dev/null 2>&1; then
                ok "baseline (no new allowlist entry): bare RETASK nonce leaks"
            else
                bad "baseline leaked but no generic-api-key finding's Secret is the bare nonce — not proof the RED control is real, not a scanner/config error"
            fi
            ;;
        0) bad "baseline: bare RETASK nonce does NOT leak even without the new allowlist entry — the RED control is vacuous" ;;
        *) bad "baseline: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac

    run_gitleaks "$FIX/nonce-alone.txt" "$TMPL/.gitleaks.toml" /dev/null
    case "$GITLEAKS_RC" in
        0) ok "bare RETASK nonce does not leak (allowlisted)" ;;
        1) bad "bare RETASK nonce still leaks — allowlist regex not matching" ;;
        *) bad "nonce-alone: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac

    # The suffixed control must prove the SPECIFIC finding's detected secret
    # covers the nonce-prefixed value, not merely that the nonce prefix
    # appears SOMEWHERE in the report (e.g. a Match/context field) — an
    # unrelated rule could match the appended credential alone even if the
    # allowlist regex lost its `$` anchor and over-suppressed the nonce
    # prefix (codex-adv round 2/3 findings). Check the .Secret field itself.
    SUFFIX_REPORT="$WORK/report-suffixed.json"
    run_gitleaks "$FIX/nonce-suffixed.txt" "$TMPL/.gitleaks.toml" "$SUFFIX_REPORT"
    case "$GITLEAKS_RC" in
        1)
            if jq -e --arg nonce 'Y-N204-a68d71' \
                'any(.[]; (.Secret // "") | contains($nonce))' \
                "$SUFFIX_REPORT" >/dev/null 2>&1; then
                ok "nonce-suffixed real-looking credential still leaks, detected secret covers the nonce prefix (control)"
            else
                bad "nonce-suffixed leaked but no finding's Secret field covers the nonce prefix — an unrelated rule matched the suffix alone, not proof the allowlist anchor still holds"
            fi
            ;;
        0) bad "nonce-suffixed real-looking credential did NOT leak — allowlist regex over-matches" ;;
        *) bad "nonce-suffixed: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac

    # -----------------------------------------------------------------------
    # 5-7. HIMMEL-3168: the RETASK nonce grew to 16 hex (`B-N44-<16 hex>`), so
    # the allowlist's hex run is bounded {4,16}, not {4,8}. Same three-part
    # shape as rows 2-4: RED baseline, allowlisted GREEN, anchor controls.
    # None of these literals is Stripe-shaped, so they can sit inline here
    # with the same-line gitleaks:allow the row-2 fixture uses.
    # -----------------------------------------------------------------------
    NONCE16='B-N44-b5c0792bbc9bdc03'
    printf 'token="B-N44-b5c0792bbc9bdc03"\n' > "$FIX/nonce16-alone.txt" # gitleaks:allow
    printf 'token="B-N44-b5c0792bbc9bdc035"\n' > "$FIX/nonce17-alone.txt" # gitleaks:allow
    printf 'token="B-N44-b5c0792bbc9bdc03-x9Kq2mZ7vLp4Rt8w"\n' > "$FIX/nonce16-suffixed.txt" # gitleaks:allow

    # leaks_with_secret <fixture> <config> <report> <eq|prefix>: 0 iff gitleaks
    # exits 1 AND a generic-api-key finding's .Secret equals (eq) or starts
    # with (prefix) the nonce — an rc=1 alone does not prove the fixture was
    # detected.
    leaks_with_secret() {
        run_gitleaks "$1" "$2" "$3"
        [ "$GITLEAKS_RC" -eq 1 ] || return 1
        jq -e --arg nonce "$NONCE16" --arg mode "$4" \
            'any(.[]; .RuleID == "generic-api-key" and ((.Secret // "") | if $mode == "eq" then . == $nonce else startswith($nonce) end))' \
            "$3" >/dev/null 2>&1
    }

    if leaks_with_secret "$FIX/nonce16-alone.txt" "$BASELINE_CFG" "$WORK/report-16-baseline.json" eq; then
        ok "baseline (no new allowlist entry): bare 16-hex RETASK nonce leaks"
    else
        bad "baseline: bare 16-hex RETASK nonce does not leak under the stripped config (rc=$GITLEAKS_RC) — the RED control is vacuous"
    fi

    run_gitleaks "$FIX/nonce16-alone.txt" "$TMPL/.gitleaks.toml" /dev/null
    case "$GITLEAKS_RC" in
        0) ok "bare 16-hex RETASK nonce does not leak (allowlisted)" ;;
        1) bad "bare 16-hex RETASK nonce still leaks — allowlist hex bound is narrower than 16" ;;
        *) bad "nonce16-alone: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac

    # Controls: one hex digit past the bound, and a real-looking suffix, must
    # each still leak with the nonce inside the finding's own .Secret.
    if leaks_with_secret "$FIX/nonce17-alone.txt" "$TMPL/.gitleaks.toml" "$WORK/report-17.json" prefix; then
        ok "17-hex tail still leaks — allowlist hex bound stops at 16 (control)"
    else
        bad "17-hex tail did NOT leak with the nonce in .Secret (rc=$GITLEAKS_RC) — allowlist over-matches past 16 hex"
    fi
    if leaks_with_secret "$FIX/nonce16-suffixed.txt" "$TMPL/.gitleaks.toml" "$WORK/report-16-suffixed.json" prefix; then
        ok "16-hex nonce + credential suffix still leaks, detected secret covers the nonce prefix (control)"
    else
        bad "16-hex nonce + credential suffix did NOT leak with the nonce in .Secret (rc=$GITLEAKS_RC) — allowlist anchor lost"
    fi
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: template-graphify-ignore ($0)"
    exit 0
else
    echo "FAIL: $fails failure(s) in template-graphify-ignore ($0)" >&2
    exit 1
fi
