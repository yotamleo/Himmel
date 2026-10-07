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
#   5. HIMMEL-4749: a fresh brief with no front-matter `description:` (or the
#      template placeholder) FAILS, naming the field; a doc whose Results already
#      holds a bullet (a resume) passes without one. headed-arm-leg.sh refuses a
#      fresh template-shaped launch with no description, --no-prior-art-check
#      or not, and still resumes a doc that has run.
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
mk_raw() { # name lines...
    local f="$tmp/$1.md"; shift
    printf '%s\n' "$@" > "$f"
}
# A template brief opens with front matter carrying its description (HIMMEL-4749).
mk() { # name lines...
    local n="$1"; shift
    mk_raw "$n" '---' 'description: Check the lint on a test brief' '---' "$@"
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
mk empty_then_quote '# brief' '> **Prior art:**' '> ' '> unrelated quoted line' '' '> **Contract:** y'
mk nonepad_then_quote '# brief' '> **Prior art:** none' '>   ' '> unrelated quoted line' '' '> **Contract:** y'
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
expect_rc "1m whitespace-only quote line ends the field, so an empty field fails" 1 "$tmp/empty_then_quote.md"
expect_rc "1n bare none then a whitespace-only quote line then unrelated text fails" 1 "$tmp/nonepad_then_quote.md"
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
mk_raw fixture_plain '# fixture brief' '## Results'
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

# 5. HIMMEL-4749 description field.
PA='> **Prior art:** none found (qmd -c jira-himmel "x")'
mk_raw desc_none '# brief' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk_raw desc_ph '---' 'description: <one plain-language line: what this leg is doing and why>' '---' '# brief' "$PA" '> **Contract:** y' '## Results (newest at the bottom)'
mk_raw desc_resumed '# brief' "$PA" '> **Contract:** y' '## Results (newest at the bottom)' '- 10:00 LIVE — started'
expect_rc "5a fresh brief with no description fails" 1 "$tmp/desc_none.md"
err="$(bash "$LINT" "$tmp/desc_none.md" 2>&1 >/dev/null)"
grep -q 'description:' <<< "$err" && ok "5b the failure names the description: field" || bad "5b the failure names the description: field: $err"
grep -q 'first line' <<< "$err" && ok "5b2 the failure says the '---' must be the first line" || bad "5b2 the failure does not name the first-line rule: $err"
expect_rc "5c placeholder description fails" 1 "$tmp/desc_ph.md"
expect_rc "5d a resumed doc (Results bullet) passes without a description" 0 "$tmp/desc_resumed.md"
rc=0; out="$(run_leg "$tmp/desc_none.md" --profile leg-impl)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'description:' <<< "$out"; } \
    && ok "5e launcher refuses a fresh brief with no description" || bad "5e launcher refuses a fresh brief with no description (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/desc_none.md" --profile leg-impl --no-prior-art-check)" || rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'description:' <<< "$out"; } \
    && ok "5f --no-prior-art-check does not bypass the description refusal" || bad "5f --no-prior-art-check bypassed the description refusal (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/desc_resumed.md" --profile leg-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "5g launcher resumes a doc that has run without a description" || bad "5g launcher resume of a pre-description doc (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/desc_none.md" --relay)" || rc=$?
[ "$rc" -eq 0 ] && ok "5h relay launch is not gated on a description" || bad "5h relay launch gated on a description (rc=$rc): $out"

# 6. Every brief template the launcher gates, filled the way a console fills it
#    (each `<placeholder>` replaced), launches: a template that lacks a field the
#    gates require would refuse every brief written from it.
DOCS="$HERE/../../../docs/handover"
fill_template() { # template out
    awk '/^```markdown$/ { inb = 1; next } inb && /^```$/ { exit } inb' "$1" \
        | sed -E 's/<[^>]*>/filled/g; s/<[^>]*$/filled/' > "$2"
}
fill_template "$DOCS/leg-brief-template.md" "$tmp/filled_leg.md"
fill_template "$DOCS/judge-brief-template.md" "$tmp/filled_judge.md"
grep -Eq '^> \*\*(Contract|Completion condition):\*\*' "$tmp/filled_leg.md" \
    && grep -Eq '^> \*\*(Contract|Completion condition):\*\*' "$tmp/filled_judge.md" \
    && ok "6a both filled templates are template-shaped (gated)" || bad "6a a filled template is not gate-shaped"
rc=0; out="$(run_leg "$tmp/filled_leg.md" --profile leg-impl)" || rc=$?
[ "$rc" -eq 0 ] && ok "6b a filled leg-brief-template launches" || bad "6b filled leg-brief-template refused (rc=$rc): $out"
rc=0; out="$(run_leg "$tmp/filled_judge.md" --judge)" || rc=$?
[ "$rc" -eq 0 ] && ok "6c a filled judge-brief-template launches" || bad "6c filled judge-brief-template refused (rc=$rc): $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
