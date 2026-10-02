#!/usr/bin/env bash
# Regression: .gitleaks.toml allowlists a bare 40-hex commit SHA and the exact
# literal runClaudexSharedDispatch, while a longer or mixed-case hex token is
# still caught. POSIX bash 3.2+.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/.gitleaks.toml"
[ -f "$CONFIG" ] || { echo "FAIL: $CONFIG not found"; exit 1; }
command -v gitleaks >/dev/null 2>&1 || { echo "SKIP: gitleaks not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-allowlist.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0

# scan <name> <line> <expect: clean|flag>
scan() {
  printf '%s\n' "$2" > "$TMP/f.txt"
  gitleaks dir "$TMP/f.txt" --config "$CONFIG" --no-banner --redact --exit-code 42 >/dev/null 2>&1
  rc=$?
  if { [ "$3" = clean ] && [ $rc -eq 0 ]; } || { [ "$3" = flag ] && [ $rc -eq 42 ]; }; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (rc=$rc, expected $3)"; fails=$((fails + 1))
  fi
}

sha="6dcfd2469d17afd771a77f90a37fd0f122b8e857"
scan "bare 40-hex SHA is allowed" "secret = $sha" clean
scan "40-hex SHA with trailing punctuation is allowed" "secret = $sha." clean
scan "runClaudexSharedDispatch literal is allowed" "Jira: runClaudexSharedDispatch" clean
scan "longer hex token still flagged" "secret = ${sha}6dcfd2469d17afd771" flag
upper="$(printf '%s' "${sha:0:8}" | tr 'a-f' 'A-F')${sha:8}"
scan "mixed-case 40-char token still flagged" "secret = $upper" flag

if [ $fails -eq 0 ]; then
  echo "all passed"
else
  echo "$fails failed"; exit 1
fi
