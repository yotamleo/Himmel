#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-minerva-spec-gate.sh — HIMMEL-3996: minerva-spec-gate.sh refuses the
# Stage-2 spec critic unless the spec carries an estimate record (effort-assess
# output that passed its DoD), an Alternatives section and a Definition-of-done
# section. Fixtures: one missing each, then a filled one that passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/minerva-spec-gate.sh"
tool="$here/../skills/effort-assess/effort_assess.py"
td="$(mktemp -d "${TMPDIR:-/tmp}/minerva-gate.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }

python3 "$tool" ticket --low S --high S --g1 no --deps none --scope-file a.sh --red r --goal G2 --alternative x >"$td/est.json" 2>/dev/null
# a refused estimate: no RED, so dod.passed is false (the tool exits 1 but still prints the record)
python3 "$tool" ticket --low S --high S --g1 no --deps none --scope-file a.sh >"$td/refused.json" 2>/dev/null

mkspec(){ # <file> <estimate line or -> <alt yes|no> <dod yes|no>
  { echo "# Spec"; echo
    [ "$2" = "-" ] || echo "$2"
    echo; echo "## Problem"; echo "text"; echo
    echo "## Alternatives considered"; [ "$3" = yes ] && { echo "1. keep the midpoint"; echo "2. variant A"; }; echo
    echo "## Definition of done"; [ "$4" = yes ] && echo "- gate fires on a bare spec, passes when filled"; echo
    echo "## ASSUMPTIONS"; echo "- none"
  } >"$1"
}

expect_refuse(){ # <label> <needle> <spec>
  local out rc
  out="$(bash "$gate" "$3" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "$1: non-zero exit" || bad "$1: expected non-zero exit"
  case "$out" in *"$2"*) ok "$1: names $2";; *) bad "$1: output lacks [$2]: $out";; esac
}

# RED fixtures: each missing exactly one requirement
mkspec "$td/no-est.md" - yes yes;                                    expect_refuse "no estimate record" "estimate" "$td/no-est.md"
mkspec "$td/dangling.md" "Estimate record: $td/nope.json" yes yes;   expect_refuse "estimate file missing" "estimate" "$td/dangling.md"
mkspec "$td/refused.md" "Estimate record: $td/refused.json" yes yes; expect_refuse "estimate refused by DoD" "estimate" "$td/refused.md"
mkspec "$td/no-alt.md" "Estimate record: $td/est.json" no yes;       expect_refuse "no alternatives" "alternatives" "$td/no-alt.md"
mkspec "$td/no-dod.md" "Estimate record: $td/est.json" yes no;       expect_refuse "no DoD" "definition of done" "$td/no-dod.md"
expect_refuse "missing spec file" "spec" "$td/absent.md"

# the filled fixture passes (absolute path, then a path relative to the spec)
mkspec "$td/good.md" "Estimate record: $td/est.json" yes yes
bash "$gate" "$td/good.md" >/dev/null 2>&1 && ok "filled spec passes (absolute record)" || bad "filled spec should pass"
mkspec "$td/rel.md" "Estimate record: est.json" yes yes
bash "$gate" "$td/rel.md" >/dev/null 2>&1 && ok "filled spec passes (record relative to spec)" || bad "relative record should pass"

# HIMMEL-4043: exact heading text, and a section ends at ANY H1 or H2
mkspec_raw(){ # <file> <alt heading> <dod heading>; both sections get a body
  { echo "# Spec"; echo; echo "Estimate record: $td/est.json"; echo
    echo "$2"; echo "- body"; echo
    echo "$3"; echo "- body"; echo
  } >"$1"
}
mkspec_raw "$td/prefix-alt.md" "## Alternatives-not-considered" "## Definition of done"
expect_refuse "prefix-only alternatives heading" "alternatives" "$td/prefix-alt.md"
mkspec_raw "$td/prefix-dod.md" "## Alternatives considered" "## Definition of done later"
expect_refuse "prefix-only DoD heading" "definition of done" "$td/prefix-dod.md"
{ echo "# Spec"; echo; echo "Estimate record: $td/est.json"; echo
  echo "## Alternatives considered"; echo; echo "# Notes"; echo "belongs to the H1, not to alternatives"; echo
  echo "## Definition of done"; echo "- ok"; } >"$td/h1-end.md"
expect_refuse "H1 ends the alternatives section" "alternatives" "$td/h1-end.md"
mkspec_raw "$td/mixed-case.md" "## alternatives CONSIDERED" "## Definition Of Done  "
bash "$gate" "$td/mixed-case.md" >/dev/null 2>&1 && ok "case and trailing space tolerated" || bad "case/trailing-space heading should pass"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
