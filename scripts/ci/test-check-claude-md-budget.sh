#!/usr/bin/env bash
# Smoke test for scripts/ci/check-claude-md-budget.sh (HIMMEL-2038).
#
# The gate budgets ONLY himmel's own bytes: the `## graphify` section is
# upstream-owned (written verbatim by `graphify install --platform claude`) and
# excluded from the count with the installer's own boundary rule. Exercises the
# guard's direct-file mode against hermetic fixtures (mktemp -d), the real repo
# CLAUDE.md, and — when the uv-managed graphifyy venv is present — the REAL
# installer (`graphify.install.claude_install`) for the idempotence contract:
# a reinstall over the committed file changes nothing.
#
# Usage: bash scripts/ci/test-check-claude-md-budget.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-claude-md-budget.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# A minimal graphify section every valid fixture carries (content is
# irrelevant to the gate — the section is excluded from the count).
section=$'## graphify\n\nupstream text, not ours.\n'

# Case A: a file comfortably under the budget (ours tiny + a section) → exit 0
echo "== Case A: under budget =="
printf '# tiny\n\n%s' "$section" > "$tmp/under.md"
bash "$GUARD" "$tmp/under.md"; rc=$?
if [ "$rc" -eq 0 ]; then pass "under.md -> exit 0"; else fail "under.md -> expected 0 got $rc"; fi

# Case B: over-budget HIMMEL content is refused, and the message names the
# overage and the exclusion. 20000 'x' outside the section vs the 12288 default.
echo "== Case B: over budget (ours) is refused =="
{ awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x"; printf "\n\n" }'; printf '%s' "$section"; } > "$tmp/over.md"
out_b=$(bash "$GUARD" "$tmp/over.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "over.md -> exit 1"; else fail "over.md -> expected 1 got $rc"; fi
if grep -q 'over the 12288 B always-on budget' <<< "$out_b" && grep -q 'graphify.*section is excluded' <<< "$out_b"; then
    pass "over.md -> message names the budget and the exclusion"
else
    fail "over.md -> message wrong: $out_b"
fi

# Case B2: a HUGE graphify section does NOT count against the budget.
echo "== Case B2: upstream section bytes are free =="
{ printf '# tiny\n\n## graphify\n\n'; awk 'BEGIN { for (i = 0; i < 20000; i++) printf "x"; printf "\n" }'; } > "$tmp/bigsection.md"
bash "$GUARD" "$tmp/bigsection.md"; rc=$?
if [ "$rc" -eq 0 ]; then pass "20 KB inside the section -> exit 0"; else fail "bigsection.md -> expected 0 got $rc"; fi

# Case C: CLAUDE_MD_MAX_BYTES overrides the limit (both directions).
echo "== Case C: env override =="
CLAUDE_MD_MAX_BYTES=3 bash "$GUARD" "$tmp/under.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then pass "limit 3 -> under.md now refused"; else fail "limit 3 -> expected 1 got $rc"; fi
CLAUDE_MD_MAX_BYTES=99999 bash "$GUARD" "$tmp/over.md"; rc=$?
if [ "$rc" -eq 0 ]; then pass "limit 99999 -> over.md now accepted"; else fail "limit 99999 -> expected 0 got $rc"; fi

# Case D: a non-numeric limit is a config error, not a silent pass.
echo "== Case D: bad limit fails closed =="
CLAUDE_MD_MAX_BYTES=lots bash "$GUARD" "$tmp/under.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "CLAUDE_MD_MAX_BYTES=lots -> exit 2"; else fail "bad limit -> expected 2 got $rc"; fi

# Case E: duplicate graphify sections are refused (the installer replaces only
# the LAST one, so duplicates never self-heal).
echo "== Case E: duplicate sections refused =="
printf '# tiny\n\n%s\n%s' "$section" "$section" > "$tmp/dup.md"
out_e=$(bash "$GUARD" "$tmp/dup.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "dup.md -> exit 1"; else fail "dup.md -> expected 1 got $rc"; fi
if grep -q "2 '## graphify' headings" <<< "$out_e"; then
    pass "dup.md -> message counts the duplicates"
else
    fail "dup.md -> message wrong: $out_e"
fi

# Case E2: no graphify section at all is refused with the reinstall hint.
echo "== Case E2: missing section refused =="
printf '# rules\n' > "$tmp/none.md"
out_e2=$(bash "$GUARD" "$tmp/none.md" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "none.md -> exit 1"; else fail "none.md -> expected 1 got $rc"; fi
if grep -q 'graphify install --platform claude' <<< "$out_e2"; then
    pass "none.md -> reinstall hint present"
else
    fail "none.md -> no reinstall hint: $out_e2"
fi
# ' -- then ' in a pasted shell line ends option parsing for `graphify install`
# and turns the re-price command into junk positional argv (HIMMEL-2480 CR
# finding 3) -- the hint must not contain that sequence.
if grep -q -- ' -- then ' <<< "$out_e2"; then
    fail "none.md -> reinstall hint has the unrunnable ' -- then ' copy-paste trap"
else
    pass "none.md -> reinstall hint has no ' -- then ' copy-paste trap"
fi
if grep -q 're-price the hooks: bash scripts/lib/graphify-bin.sh price-hooks' <<< "$out_e2"; then
    pass "none.md -> re-price hint present"
else
    fail "none.md -> no re-price hint: $out_e2"
fi

# Case F: a missing file fails closed rather than passing vacuously.
echo "== Case F: missing file fails closed =="
bash "$GUARD" "$tmp/nope.md" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "missing file -> exit 2"; else fail "missing file -> expected 2 got $rc"; fi

# Case G: the REAL committed CLAUDE.md passes.
echo "== Case G: repo CLAUDE.md is within budget =="
bash "$GUARD" "$REPO_ROOT/CLAUDE.md"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "repo CLAUDE.md -> exit 0 (total $(wc -c < "$REPO_ROOT/CLAUDE.md" | tr -d ' ') B)"
else
    fail "repo CLAUDE.md -> expected 0 got $rc"
fi

# Case H (venv-gated): the REAL installer over the committed file is a no-op —
# the section is verbatim stock, so a reinstall/upgrade rewrites nothing and
# the gate stays green with our counted bytes unchanged.
echo "== Case H: real claude_install is idempotent over the repo file =="
py=""
tool_dir="$(uv tool dir 2>/dev/null | tr -d '\r')"
for cand in "$tool_dir/graphifyy/Scripts/python.exe" "$tool_dir/graphifyy/bin/python"; do
  [ -n "$tool_dir" ] && [ -x "$cand" ] && { py="$cand"; break; }
done
if [ -n "$py" ] && "$py" -c 'import graphify.install' 2>/dev/null; then
    mkdir -p "$tmp/proj"
    cp "$REPO_ROOT/CLAUDE.md" "$tmp/proj/CLAUDE.md"
    "$py" - "$tmp/proj" <<'PY' >/dev/null
import sys, pathlib
from graphify import install
install.claude_install(project_dir=pathlib.Path(sys.argv[1]))
PY
    if cmp -s "$REPO_ROOT/CLAUDE.md" "$tmp/proj/CLAUDE.md"; then
        pass "claude_install over the committed file -> byte-identical (no change)"
    else
        fail "claude_install CHANGED the committed file ($(wc -c < "$tmp/proj/CLAUDE.md" | tr -d ' ') B) — the section is not verbatim stock for this graphify version"
    fi
    n=$(grep -c '^## graphify$' "$tmp/proj/CLAUDE.md")
    if [ "$n" -eq 1 ]; then pass "still exactly one section"; else fail "$n sections after install"; fi
    bash "$GUARD" "$tmp/proj/CLAUDE.md" >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then pass "gate green after install"; else fail "gate -> expected 0 got $rc"; fi
else
    echo "  SKIP  no uv-managed graphifyy venv — real-installer idempotence not exercised here"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILURE(S)"; fi
exit $(( failures > 0 ? 1 : 0 ))
