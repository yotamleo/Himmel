#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-minerva-trace-lint.sh — HIMMEL-4375: minerva's terminal lint refuses a
# surface-shaped spec with no Fact ownership matrix, a spec with no Invariants
# section, and a plan that names no test for an invariant. RED fixture:
# fixtures/minerva-trace-lint/red-spec.md (the HIMMEL-4254 shape, synthetic);
# the GREEN spec is that fixture plus the two sections, built here.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lint="$here/minerva-trace-lint.sh"
red="$here/fixtures/minerva-trace-lint/red-spec.md"
td="$(mktemp -d "${TMPDIR:-/tmp}/minerva-trace.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
cd "$(git -C "$here" rev-parse --show-toplevel)" || { echo "FAIL - no repo root"; exit 1; }
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }

expect_refuse(){ # <label> <needle> <spec> <plan>
  local out rc
  out="$(bash "$lint" "$3" "$4" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "$1: exit 1" || bad "$1: expected exit 1, got $rc: $out"
  case "$out" in *"$2"*) ok "$1: names $2";; *) bad "$1: output lacks [$2]: $out";; esac
}
expect_pass(){ # <label> <spec> <plan>
  local out
  out="$(bash "$lint" "$2" "$3" 2>&1)" && ok "$1" || bad "$1: expected pass: $out"
}

# a real repo path, so the matrix's path rule is exercised against disk
repo_path="marketplace/plugins/himmel-ops/scripts/minerva-spec-gate.sh"
fact_ok="## Fact ownership

| Fact | Existing surfaces | Owner after | Non-owners |
|---|---|---|---|
| item health | \`$repo_path\` | the feed | doctor delegates, shown as evidence |
| cadence state | none (grep: \`cadence-state\`) | the feed | n/a |
"
inv_ok="## Invariants

- I1 — one fact is one row, whichever surfaces compute it.
"
printf 'plan\n\n- Task 1: I1 — Test: `scripts/test-feed.sh` feeds a fact from two real sources.\n' >"$td/plan.md"
printf 'plan\n\n- Task 1: I1 is covered somewhere.\n' >"$td/plan-untraced.md"

# RED: the 4254-shaped fixture fails on both missing sections
expect_refuse "RED fixture: no Fact ownership" "fact ownership" "$red" "$td/plan.md"
expect_refuse "RED fixture: no Invariants" "invariants" "$red" "$td/plan.md"

# GREEN: the same fixture with both sections passes
{ cat "$red"; echo; printf '%s\n' "$fact_ok"; printf '%s\n' "$inv_ok"; } >"$td/green.md"
expect_pass "GREEN fixture passes" "$td/green.md" "$td/plan.md"

# an invariant the plan mentions without naming a test
expect_refuse "untraced invariant" "I1" "$td/green.md" "$td/plan-untraced.md"

# a matrix row citing neither an existing path nor a grep record
{ cat "$red"; echo; printf '%s\n' "## Fact ownership

| Fact | Existing surfaces | Owner after | Non-owners |
|---|---|---|---|
| item health | the doctor, probably | the feed | n/a |
"; printf '%s\n' "$inv_ok"; } >"$td/no-grep.md"
expect_refuse "row without path or grep record" "item health" "$td/no-grep.md" "$td/plan.md"

# a cited path that does not exist
sed "s#$repo_path#scripts/no-such-file.sh#" "$td/green.md" >"$td/dangling.md"
expect_refuse "cited path missing" "no-such-file" "$td/dangling.md" "$td/plan.md"

# a glob token is a literal path, never expanded into whatever the cwd holds
sed "s#\`$repo_path\`#\`*\`#" "$td/green.md" >"$td/glob.md"
expect_refuse "glob token not expanded" "cites *," "$td/glob.md" "$td/plan.md"

# a surface word only in the first H2 heading still makes the spec surface-shaped
printf '# Feed rework\n\n## Health\n\nRework it.\n\n## Invariants\n\nnone\n' >"$td/h2-only.md"
expect_refuse "surface word in first H2 heading" "fact ownership" "$td/h2-only.md" "$td/plan.md"

# a stray `none` line does not exempt I<n> lines beside it
sed 's/^- I1 — /none\n- I1 — /' "$td/green.md" >"$td/none-plus.md"
expect_refuse "none beside an I<n> line" "I1" "$td/none-plus.md" "$td/plan-untraced.md"

# a matrix row with an empty owner cell
sed 's/| the feed | doctor delegates/|  | doctor delegates/' "$td/green.md" >"$td/no-owner.md"
expect_refuse "row without an owner" "names no owner" "$td/no-owner.md" "$td/plan.md"

# a non-surface spec needs Invariants (may be none) but no matrix
printf '# Rename a flag\n\n## 1. Goal\n\nRename the flag.\n\n## Invariants\n\nnone\n' >"$td/plain.md"
expect_pass "non-surface spec with Invariants: none passes" "$td/plain.md" "$td/plan.md"

# usage errors exit 2
bash "$lint" "$td/absent.md" "$td/plan.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing spec: exit 2" || bad "missing spec: expected exit 2, got $rc"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
