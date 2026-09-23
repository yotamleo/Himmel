#!/usr/bin/env bash
# scripts/guardrails/test-gitleaks-retired-org.sh — HIMMEL-3508 regression:
# .gitleaks.toml's himmel-retired-org-name rule blocks a retired third-party
# org's name (a repo we no longer maintain) case-insensitively, while leaving
# ordinary text and near-miss words alone.
#
# The fixture string is built at runtime (never written literally in this
# file) so the scanner catches the SAME string a real leak would contain,
# without this test file itself becoming a hit.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as the other
# guardrail tests here — no .ps1 twin.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="$REPO_ROOT/.gitleaks.toml"
[ -f "$CONFIG" ] || { echo "FAIL: $CONFIG not found"; exit 1; }

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "SKIP: gitleaks not installed on this host — cannot exercise the real scanner"
    exit 0
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

if ! WS="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-retired-org-test.XXXXXX")"; then
    echo "test-gitleaks-retired-org: mktemp -d failed" >&2
    exit 2
fi
trap 'rm -rf "$WS"' EXIT

new_repo() {
    local d
    d="$(mktemp -d "$WS/repo.XXXXXX")" || { echo "mktemp -d under \$WS failed" >&2; exit 2; }
    git -C "$d" init -q
    git -C "$d" config user.email test@example.com
    git -C "$d" config user.name test
    printf '%s\n' "$d"
}

# scan_staged <repo> -- runs the real pre-commit scanner (gitleaks protect
# --staged) against himmel's own .gitleaks.toml; returns gitleaks' exit code
# (0 = no leaks, non-zero = leaks found / blocked) and writes a JSON report to
# $REPORT for detected_our_rule() to inspect.
REPORT="$WS/report.json"
scan_staged() {
    rm -f "$REPORT"
    gitleaks protect --staged --no-banner -c "$CONFIG" -s "$1" \
        --report-format json --report-path "$REPORT" >/dev/null 2>&1
}

# detected_our_rule -- true only if the last scan_staged report shows OUR
# rule fired, not merely that gitleaks exited non-zero for some other reason.
detected_our_rule() {
    [ -f "$REPORT" ] && grep -q '"RuleID": *"himmel-retired-org-name"' "$REPORT" 2>/dev/null
}

# T1 -- RED: the retired org's name, built at runtime, staged -> blocked by
# our specific rule (not merely blocked for some unrelated reason).
r="$(new_repo)"
fixture="$(printf 'kn%sstic' o)"
printf '%s appears in this text\n' "$fixture" > "$r/f.txt"
git -C "$r" add f.txt
if scan_staged "$r" || ! detected_our_rule; then
    fail "T1 retired org name is blocked by the pre-commit scanner"
else
    pass "T1 retired org name is blocked by the pre-commit scanner"
fi

# T1b -- same fixture, mixed case, still blocked by our rule (case-insensitive).
r="$(new_repo)"
fixture_mixed="$(printf 'Kn%sSTIC' O)"
printf 'org: %s\n' "$fixture_mixed" > "$r/f.txt"
git -C "$r" add f.txt
if scan_staged "$r" || ! detected_our_rule; then
    fail "T1b mixed-case retired org name is blocked (case-insensitive)"
else
    pass "T1b mixed-case retired org name is blocked (case-insensitive)"
fi

# T2 -- control: ordinary text passes.
r="$(new_repo)"
printf 'ordinary text with nothing sensitive in it\n' > "$r/f.txt"
git -C "$r" add f.txt
if scan_staged "$r"; then
    pass "T2 ordinary text passes"
else
    fail "T2 ordinary text passes"
fi

# T3 -- control: near-miss "knot" does not match.
r="$(new_repo)"
printf 'a knot in the rope\n' > "$r/f.txt"
git -C "$r" add f.txt
if scan_staged "$r"; then
    pass "T3 near-miss 'knot' passes"
else
    fail "T3 near-miss 'knot' passes"
fi

# T4 -- control: near-miss "stick" does not match.
r="$(new_repo)"
printf 'a walking stick\n' > "$r/f.txt"
git -C "$r" add f.txt
if scan_staged "$r"; then
    pass "T4 near-miss 'stick' passes"
else
    fail "T4 near-miss 'stick' passes"
fi

echo
echo "== summary =="
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$failures FAILURE(S)"
    exit 1
fi
