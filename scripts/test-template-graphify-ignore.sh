#!/usr/bin/env bash
# Smoke test for the luna template's graphify-out ignore block + RETASK-nonce
# gitleaks allowlist (HIMMEL-3003).
#
# Asserts:
#   1. `git check-ignore` matches graphify-out/graph.json under the template
#      .gitignore.
#   2. A RETASK nonce alone (e.g. `token="Y-N204-a68d71"`) does NOT leak  # gitleaks:allow
#      against the template .gitleaks.toml.
#   3. RED-preserving control: the same nonce SUFFIXED with a real-looking
#      credential still leaks — the allowlist regex is anchored to the exact
#      nonce shape, not a prefix match.
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

WORK="$(mktemp -d)"
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
# 2 + 3. gitleaks: nonce alone is allowlisted; a suffixed credential is not.
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

    if gitleaks detect --no-git --source "$FIX/nonce-alone.txt" \
        --config "$TMPL/.gitleaks.toml" --no-banner \
        --report-path /dev/null --report-format json >/dev/null 2>&1; then
        ok "bare RETASK nonce does not leak (allowlisted)"
    else
        bad "bare RETASK nonce still leaks — allowlist regex not matching"
    fi

    if gitleaks detect --no-git --source "$FIX/nonce-suffixed.txt" \
        --config "$TMPL/.gitleaks.toml" --no-banner \
        --report-path /dev/null --report-format json >/dev/null 2>&1; then
        bad "nonce-suffixed real-looking credential did NOT leak — allowlist regex over-matches"
    else
        ok "nonce-suffixed real-looking credential still leaks (control)"
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
