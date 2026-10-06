#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the ok/bad reporting lines, as in test-headed-arm-leg.sh
# scripts/handover/console-kit/test-brief-lint.sh - suite for brief-lint.sh
# (HIMMEL-4573): the arming-time check that a leg or judge brief carries a
# filled `> **Prior art:**` line, plus the headed-arm-leg.sh call site that
# refuses an arming with a failing brief unless --no-prior-art-check is passed.
#
# Asserts:
#   1. A brief with no Prior art line, an empty one, a bare `none` (any case or
#      trailing punctuation), an unfilled `<placeholder>`, or `none found` with
#      no query all FAIL (exit 1, reason on stderr).
#   2. A filled line, `none found (<query>)`, and a multi-line filled field PASS.
#   3. Usage errors exit 2 (no arg, unreadable file).
#   4. headed-arm-leg.sh refuses a template-shaped brief (carries a `> **Contract:**`
#      or `> **Completion condition:**` line) that fails the lint, naming
#      --no-prior-art-check; the flag lets it through; a filled brief passes;
#      a relay or consult launch and a non-template fixture are not gated.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/brief-lint.sh"
LEG="$HERE/headed-arm-leg.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/brief-lint.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
expect_rc() { # label want-rc doc
    local rc=0 err
    err="$(bash "$LINT" "$3" 2>&1 >/dev/null)" || rc=$?
    if [ "$rc" -eq "$2" ]; then ok "$1"; else bad "$1 (rc=$rc want $2): $err"; fi
}
mk() { # name lines...
    local f="$tmp/$1.md"; shift
    printf '%s\n' "$@" > "$f"
}

mk none '# brief' '> **Why:** x' '> **Contract:** y'
mk empty '# brief' '> **Prior art:**' '' '> **Contract:** y'
mk empty_sp '# brief' '> **Prior art:**    ' '' '> **Contract:** y'
mk bare_none '# brief' '> **Prior art:** none' '' '> **Contract:** y'
mk bare_None '# brief' '> **Prior art:** None.' '' '> **Contract:** y'
mk bare_NONE '# brief' '> **Prior art:**   NONE  ' '' '> **Contract:** y'
mk placeholder '# brief' '> **Prior art:** <related tickets, prior fixes, graph neighbours, with source>' '' '> **Contract:** y'
mk nf_noq '# brief' '> **Prior art:** none found' '' '> **Contract:** y'
mk nf_emptyq '# brief' '> **Prior art:** none found ()' '' '> **Contract:** y'
mk next_field '# brief' '> **Prior art:**' '> **Contract:** y'
mk filled '# brief' '> **Prior art:** HIMMEL-2581 (graphify non-adoption); fixed in #1500 (qmd jira-himmel)' '' '> **Contract:** y'
mk nf_q '# brief' '> **Prior art:** none found (qmd -c jira-himmel "prior art field")' '' '> **Contract:** y'
mk titled '# brief' '> **Prior art (required, HIMMEL-4573):** HIMMEL-2581 (graphify non-adoption)' '' '> **Contract:** y'
mk titled_bare '# brief' '> **Prior art (required, HIMMEL-4573):** none' '' '> **Contract:** y'
mk nf_ph '# brief' '> **Prior art:** none found (<query>)' '' '> **Contract:** y'
mk multi '# brief' '> **Prior art:**' '> HIMMEL-2581 graphify non-adoption (qmd jira-himmel)' '> #1500 prior fix' '' '> **Contract:** y'
mk first_none_then_more '# brief' '> **Prior art:** none' '> HIMMEL-1 is related' '' '> **Contract:** y'

expect_rc "1a no field fails" 1 "$tmp/none.md"
expect_rc "1b empty fails" 1 "$tmp/empty.md"
expect_rc "1c whitespace-only fails" 1 "$tmp/empty_sp.md"
expect_rc "1d bare none fails" 1 "$tmp/bare_none.md"
expect_rc "1e bare None. fails" 1 "$tmp/bare_None.md"
expect_rc "1f bare NONE fails" 1 "$tmp/bare_NONE.md"
expect_rc "1g unfilled placeholder fails" 1 "$tmp/placeholder.md"
expect_rc "1h none found without a query fails" 1 "$tmp/nf_noq.md"
expect_rc "1i none found () fails" 1 "$tmp/nf_emptyq.md"
expect_rc "1j empty line followed directly by the next field fails" 1 "$tmp/next_field.md"
expect_rc "1k none found (<query>) placeholder fails" 1 "$tmp/nf_ph.md"
expect_rc "1l titled field with a bare none fails" 1 "$tmp/titled_bare.md"
expect_rc "2e template-titled field (required, ticket) passes" 0 "$tmp/titled.md"
expect_rc "2a filled passes" 0 "$tmp/filled.md"
expect_rc "2b none found (query) passes" 0 "$tmp/nf_q.md"
expect_rc "2c multi-line filled passes" 0 "$tmp/multi.md"
expect_rc "2d none then a continuation line passes (field is non-empty)" 0 "$tmp/first_none_then_more.md"

rc=0; bash "$LINT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "3a no arg exits 2" || bad "3a no arg exits 2 (rc=$rc)"
rc=0; bash "$LINT" "$tmp/does-not-exist.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "3b unreadable file exits 2" || bad "3b unreadable file exits 2 (rc=$rc)"

# 4. Launcher call site. --dry-run exits before any launch, so no stubs needed;
# the gate must run before the dry-run exit. A fixed preflight stub keeps the
# bank state out of it.
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$tmp/preflight.sh"; chmod +x "$tmp/preflight.sh"
mk tmpl_bad '# brief' '> **Why:** x' '> **Contract:** y' '## Results'
mk tmpl_bad_judge '# brief' '> **Completion condition:** z' '## Results'
mk tmpl_ok '# brief' '> **Prior art:** none found (qmd -c jira-himmel "x")' '> **Contract:** y' '## Results'
mk fixture_plain '# fixture brief' '## Results'
run_leg() { # doc args...
    local doc="$1"; shift
    HEADED_ARM_LEG_PREFLIGHT="$tmp/preflight.sh" LEG_REPO="$tmp" \
        bash "$LEG" --dry-run "$@" "HIMMEL-9999-x" "$doc" "$tmp/signal" 9999999999 "$tmp/log" claude-sonnet-5-5 2>&1
}
rc=0; out="$(run_leg "$tmp/tmpl_bad.md" --profile leg-impl)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--no-prior-art-check'; } \
    && ok "4a failing template brief is refused, flag named" || bad "4a failing template brief is refused (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/tmpl_bad_judge.md" --judge)" || rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--no-prior-art-check'; } \
    && ok "4b failing judge brief is refused" || bad "4b failing judge brief is refused (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/tmpl_bad.md" --profile leg-impl --no-prior-art-check)" || rc=$?
[ "$rc" -eq 0 ] && ok "4c --no-prior-art-check lets it through" || bad "4c --no-prior-art-check (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/tmpl_ok.md" --profile leg-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "4d filled template brief passes" || bad "4d filled template brief (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/fixture_plain.md" --profile leg-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "4e non-template fixture is not gated" || bad "4e non-template fixture (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/tmpl_bad.md" --relay)" || rc=$?
{ [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q -- 'no-prior-art-check'; } && ok "4f relay launch is not gated" || bad "4f relay launch is not gated (rc=$rc): $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
