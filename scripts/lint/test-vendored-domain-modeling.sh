#!/usr/bin/env bash
# test-vendored-domain-modeling.sh — the vendored domain-modeling skill is present,
# pinned, licensed, and retargeted at docs/glossary.md.
#
# Usage: bash scripts/lint/test-vendored-domain-modeling.sh
# Exit: 0 all passed, 1 any failed. bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN="$ROOT/marketplace/plugins/domain-modeling"
DIR="$PLUGIN/skills/domain-modeling"
PIN=49dd158d1076134a641b33efb035946536778336

PASS=0
FAIL=0
check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$name"
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$name"; fi
}

for f in SKILL.md GLOSSARY-FORMAT.md; do
  check "$f exists" test -f "$DIR/$f"
done
check "LICENSE exists" test -f "$PLUGIN/LICENSE"
for f in SKILL.md GLOSSARY-FORMAT.md; do
  check "$f carries the pin sha" grep -q "$PIN" "$DIR/$f"
  check "$f names docs/glossary.md" grep -q 'docs/glossary\.md' "$DIR/$f"
  # shellcheck disable=SC2016
  check "$f body no longer targets a root GLOSSARY.md" bash -c 'sed "1,/^# /d" "$1" | grep -E "(^|[^/A-Za-z-])GLOSSARY\.md" && exit 1; exit 0' _ "$DIR/$f"
done
check "LICENSE is MIT" grep -q '^MIT License' "$PLUGIN/LICENSE"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
