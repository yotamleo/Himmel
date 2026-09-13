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
#      nonce shape, not a prefix match. The reported finding is grepped for
#      the nonce prefix, so an unrelated rule matching only the suffix does
#      not count as proof the allowlist anchor still holds.
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
else
    FIX="$WORK/fixtures"
    mkdir -p "$FIX"
    printf 'token="Y-N204-a68d71"\n' > "$FIX/nonce-alone.txt" # gitleaks:allow
    # base64'd, never a contiguous Stripe-shaped literal in this tracked file
    # — GitHub push protection scans committed blobs for exactly that shape,
    # and a real key literal here gets the whole push rejected even though
    # it is only a test fixture (HIMMEL-3003 follow-up).
    base64 -d <<<'dG9rZW49IlktTjIwNC1hNjhkNzEtc2tfbGl2ZV80ZUMzOUhxTHlqV0Rhcmp0VDF6ZHA3ZGMiCg==' > "$FIX/nonce-suffixed.txt"

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

    run_gitleaks "$FIX/nonce-alone.txt" "$BASELINE_CFG" /dev/null
    case "$GITLEAKS_RC" in
        1) ok "baseline (no new allowlist entry): bare RETASK nonce leaks" ;;
        0) bad "baseline: bare RETASK nonce does NOT leak even without the new allowlist entry — the RED control is vacuous" ;;
        *) bad "baseline: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac

    run_gitleaks "$FIX/nonce-alone.txt" "$TMPL/.gitleaks.toml" /dev/null
    case "$GITLEAKS_RC" in
        0) ok "bare RETASK nonce does not leak (allowlisted)" ;;
        1) bad "bare RETASK nonce still leaks — allowlist regex not matching" ;;
        *) bad "nonce-alone: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac

    # The suffixed control must prove the SPECIFIC finding covers the
    # nonce-prefixed value, not merely that SOME rule flagged the fixture —
    # an unrelated rule could match the appended credential alone even if
    # the allowlist regex lost its `$` anchor and over-suppressed the nonce
    # prefix (codex-adv round 2 finding). Capture the report and grep it.
    SUFFIX_REPORT="$WORK/report-suffixed.json"
    run_gitleaks "$FIX/nonce-suffixed.txt" "$TMPL/.gitleaks.toml" "$SUFFIX_REPORT"
    case "$GITLEAKS_RC" in
        1)
            if grep -qF 'Y-N204-a68d71' "$SUFFIX_REPORT"; then
                ok "nonce-suffixed real-looking credential still leaks, finding covers the nonce prefix (control)"
            else
                bad "nonce-suffixed leaked but no reported finding covers the nonce prefix — an unrelated rule matched the suffix alone, not proof the allowlist anchor still holds"
            fi
            ;;
        0) bad "nonce-suffixed real-looking credential did NOT leak — allowlist regex over-matches" ;;
        *) bad "nonce-suffixed: gitleaks scanner error (rc=$GITLEAKS_RC), not a leak verdict" ;;
    esac
fi

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "PASS: template-graphify-ignore ($0)"
    exit 0
else
    echo "FAIL: $fails failure(s) in template-graphify-ignore ($0)" >&2
    exit 1
fi
