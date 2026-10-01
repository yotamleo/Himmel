#!/usr/bin/env bash
# minerva-spec-gate.sh <spec.md> — HIMMEL-3996. minerva Stage 2 runs this BEFORE
# dispatching the spec critic; a non-zero exit means "do not start the critic".
# A spec must carry:
#   1. `Estimate record: <path>` — an effort-assess record (HIMMEL-3995) whose
#      dod.passed is true; the path is absolute or relative to the spec.
#   2. an `## Alternatives considered` section with at least one line.
#   3. a `## Definition of done` section with at least one line.
# Every missing item is named on stderr (all of them, not just the first).
# bash 3.2-safe; needs python3 (the same dependency as effort-assess).
set -u

spec="${1:-}"
if [ ! -f "$spec" ]; then
  echo "minerva-spec-gate: spec file not found: ${spec:-<none>}" >&2
  exit 2
fi

missing=""
add(){ missing="${missing}  - $1
"; }

# section_has_body <heading text>: true when the section under that exact H2
# (case-insensitive, trailing space ok) has a non-blank line. Any H1 or H2 ends
# the section, so a later `# Notes` block is not counted as its content.
section_has_body(){
  awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
    /^##?[[:space:]]/ {
      h = tolower($0); sub(/^#+[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
      insec = ($0 ~ /^##[[:space:]]/ && h == want); next
    }
    insec && $0 ~ /[^[:space:]]/ { found = 1 }
    END { exit found ? 0 : 1 }' "$spec"
}

line="$(grep -i -m1 '^[[:space:]]*Estimate record:' "$spec" || true)"
rec="${line#*:}"
# shellcheck disable=SC2016  # the backticks are literal characters to strip, not a command substitution
rec="$(printf '%s' "$rec" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^`//; s/`$//')"
if [ -z "$rec" ]; then
  add "estimate record: no 'Estimate record: <path>' line (run effort-assess ticket, save its JSON, reference it)"
else
  case "$rec" in /*) path="$rec";; *) path="$(dirname "$spec")/$rec";; esac
  if [ ! -f "$path" ]; then
    add "estimate record: file not found: $rec"
  elif ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("dod",{}).get("passed") is True and "median_seq" in d and "sigma" in d else 1)' "$path" 2>/dev/null; then
    add "estimate record: $rec is not a passing effort-assess record (needs median_seq, sigma, dod.passed=true)"
  fi
fi

section_has_body 'Alternatives considered' || add "alternatives: no '## Alternatives considered' section with content"
section_has_body 'Definition of done' || add "definition of done: no '## Definition of done' section with content"

if [ -n "$missing" ]; then
  printf 'minerva-spec-gate: REFUSED — do not start the spec critic. Missing:\n%s' "$missing" >&2
  exit 1
fi
echo "minerva-spec-gate: ok"
