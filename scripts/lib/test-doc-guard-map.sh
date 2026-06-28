#!/usr/bin/env bash
# Unit test for scripts/lib/doc-guard-map.sh (dgm_rows). Exit 0 if all pass.
set -uo pipefail
LIB="$(cd "$(dirname "$0")" && pwd)/doc-guard-map.sh"
# shellcheck source=/dev/null
. "$LIB"
_fail=0
chk() { local name="$1" want="$2" got="$3"; if [ "$got" = "$want" ]; then printf '  PASS  %s\n' "$name"; else printf '  FAIL  %s\n    want=[%s]\n    got =[%s]\n' "$name" "$want" "$got"; _fail=$((_fail+1)); fi; }

MAP=$(mktemp)
{
    printf '# c\n'
    printf '\n'
    printf '   \n'
    printf 'block\tadd\t^\\.claude/commands/\tdocs/commands-catalog.md\n'
    printf 'advise\tmodify\t^scripts/hooks/\tdocs/internals/enforcement.md\n'
} >> "$MAP"

chk "block+add yields the block row only" \
  "^\.claude/commands/	docs/commands-catalog.md" \
  "$(dgm_rows "$MAP" block add)"
chk "advise (any trigger) yields the advise row only" \
  "^scripts/hooks/	docs/internals/enforcement.md" \
  "$(dgm_rows "$MAP" advise)"
chk "block+modify yields nothing" "" "$(dgm_rows "$MAP" block modify)"
chk "comments and blank/whitespace lines skipped" "1" "$(dgm_rows "$MAP" block add | wc -l | tr -d ' ')"

rm -f "$MAP"
if [ "$_fail" -eq 0 ]; then echo "OK"; exit 0; else echo "FAIL: $_fail"; exit 1; fi
