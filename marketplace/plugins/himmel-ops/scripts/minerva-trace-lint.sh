#!/usr/bin/env bash
# minerva-trace-lint.sh <spec.md> <plan.md> — HIMMEL-4375. minerva's terminal
# step runs this before the execute hand-off; a non-zero exit sends the run back
# to the spec or plan stage. Rules:
#   1. A surface-shaped spec (its H1 or first H2 section names status, report,
#      doctor, health, probe, check or inventory) carries a `## Fact ownership`
#      table with an owner column. Each row's existing-surfaces cell (column 2)
#      cites backticked repo paths that exist, or reads `none (grep: <pattern>)`
#      — the grep is the mechanical inventory step, which self-answer mode
#      cannot skip.
#   2. Every spec carries `## Invariants`: `none`, or lines opening with I<n>.
#   3. Every I<n> appears in plan.md on a line that names a test (`test-`,
#      `.test.` or `Test:`).
# Paths resolve against the cwd's git top level. Every miss is named on stderr.
# Exit 0 ok, 1 refused, 2 usage. bash 3.2-safe.
set -u
set -f  # backticked cells are split into words below; never glob them

spec="${1:-}"; plan="${2:-}"
if [ ! -f "$spec" ] || [ ! -f "$plan" ]; then
  echo "minerva-trace-lint: usage: minerva-trace-lint.sh <spec.md> <plan.md> (both must exist)" >&2
  exit 2
fi
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

missing=""
add(){ missing="${missing}  - $1
"; }

# section <heading>: the body under that exact H2 (case-insensitive), up to the next H1/H2.
section(){
  awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    /^##?[[:space:]]/ {
      h = tolower($0); sub(/^#+[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      insec = ($0 ~ /^##[[:space:]]/ && h == want); next
    }
    insec { print }' "$spec"
}

surface_words='status|report|doctor|health|probe|check|inventory'
head_text="$(awk '/^#[[:space:]]/ { print; next } /^##[[:space:]]/ { n++; if (n > 1) exit; print; next } n == 1 { print }' "$spec")"
if printf '%s\n' "$head_text" | grep -qiwE "$surface_words"; then
  fo="$(section 'Fact ownership')"
  # one "fact<TAB>surfaces" line per data row under a header carrying an owner column
  rows="$(printf '%s\n' "$fo" | awk -F'|' '
    /^[[:space:]]*\|/ {
      if (!hdr) { for (i = 2; i < NF; i++) if (tolower($i) ~ /owner/) { oc = i; break }; if (oc) hdr = 1; next }
      if ($0 ~ /^[[:space:]]*\|[-:| ]+\|[[:space:]]*$/) next
      f = $2; s = $3; o = $oc; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f); gsub(/[[:space:]]/, "", o)
      if (o == "") print "!\t" f; else print f "\t" s
    }')"
  if [ -z "$rows" ]; then
    add "fact ownership: surface-shaped spec has no '## Fact ownership' table with an owner column and a data row"
  else
    while IFS="$(printf '\t')" read -r fact cell; do
      [ "$fact" = "!" ] && { add "fact ownership: row '$cell' names no owner"; continue; }
      # a grep record is complete only with a backticked pattern: none (grep: `pat`)
      # shellcheck disable=SC2016  # the backticks are literal delimiters
      printf '%s\n' "$cell" | grep -qE 'none \(grep: *`[^`]+`' && continue
      # shellcheck disable=SC2016  # the backticks are literal delimiters
      toks="$(printf '%s\n' "$cell" | grep -oE '`[^`]+`' | tr -d '`')"
      if [ -z "$toks" ]; then
        add "fact ownership: row '$fact' cites no backticked existing path and no 'none (grep: <pattern>)' record"
        continue
      fi
      for t in $toks; do
        case "$t" in /*) p="$t";; *) p="$root/$t";; esac
        [ -e "$p" ] || add "fact ownership: row '$fact' cites $t, which does not exist under $root"
      done
    done <<EOF
$rows
EOF
  fi
fi

inv="$(section 'Invariants' | grep -E '[^[:space:]]' || true)"
if [ -z "$inv" ]; then
  add "invariants: no '## Invariants' section (write 'none', or one I<n> line per one/never/always/every rule)"
elif printf '%s\n' "$inv" | grep -qvixE '[[:space:]]*none[[:space:].]*'; then  # none only as the sole content
  ids="$(printf '%s\n' "$inv" | sed -nE 's/^[[:space:]]*([-*][[:space:]]+)?(\*\*)?(I[0-9]+)([^0-9].*)?$/\3/p' | sort -u)"
  [ -n "$ids" ] || add "invariants: section lists no I<n> lines"
  stray="$(printf '%s\n' "$inv" | grep -E '^[[:space:]]*[-*][[:space:]]' | grep -vE '^[[:space:]]*[-*][[:space:]]+(\*\*)?I[0-9]+([^0-9]|$)' || true)"
  [ -z "$stray" ] || add "invariants: a bullet is not an I<n> line, so no test can trace it: $(printf '%s\n' "$stray" | head -n1)"
  for id in $ids; do
    grep -wE "$id" "$plan" | grep -qE 'test-|\.test\.|[Tt]est:' \
      || add "invariants: $id has no plan line naming its acceptance test (test-*, *.test.*, or Test:)"
  done
fi

if [ -n "$missing" ]; then
  printf 'minerva-trace-lint: REFUSED — fix the spec or plan before hand-off. Missing:\n%s' "$missing" >&2
  exit 1
fi
echo "minerva-trace-lint: ok"
