#!/usr/bin/env bash
# scripts/observability/test-exit-codes.sh - lint for the exit-code registry (HIMMEL-4853).
# A script marked "table": true documents its rcs as '#   <n> - <meaning>' header rows; the lint fails when such
# a row names an rc the registry lacks. Prose-documented scripts are seeded by hand and not linted (ponytail:
# prose is not machine-readable, a table convention for them is HIMMEL-4853 ask 3's follow-up).
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REG="$HERE/exit-codes.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/exit-codes-test.XXXXXX")" || { echo "test-exit-codes: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# lint <registry>: prints each documented-but-unregistered "script rc" and returns 1 if any.
lint() {
  local reg="$1" script rc miss=0
  while IFS= read -r script; do
    [ -f "$REPO/$script" ] || { echo "$script missing"; miss=1; continue; }
    while IFS= read -r rc; do
      [ -n "$rc" ] || continue
      jq -e --arg s "$script" --arg r "$rc" '.scripts[$s].codes | has($r)' "$reg" >/dev/null || { echo "$script $rc"; miss=1; }
    done < <(sed -nE 's/^#[[:space:]]+([0-9]{1,3})[[:space:]]+[-—–]+[[:space:]].*/\1/p' "$REPO/$script" | sort -un)
  done < <(jq -r '.scripts | to_entries[] | select(.value.table == true) | .key' "$reg")
  return $miss
}

echo "registry shape"
check "valid JSON, version 1" 'jq -e ".version == 1 and (.scripts | length) > 0" "$REG" >/dev/null'
check "every class is result, retry, refusal or error, every rc a number with a meaning" \
  'jq -e "[.scripts[].codes | to_entries[] | select((.key | test(\"^[0-9]{1,3}\$\") | not) or (.value.class | IN(\"result\",\"retry\",\"refusal\",\"error\") | not) or ((.value.meaning // \"\") == \"\"))] | length == 0" "$REG" >/dev/null'
check "every seeded script exists" '[ -z "$(jq -r ".scripts | keys[]" "$REG" | while read -r s; do [ -f "$REPO/$s" ] || echo "$s"; done)" ]'
check "basenames are unique (the digest looks scripts up by basename)" \
  '[ "$(jq -r ".scripts | keys[] | split(\"/\") | last" "$REG" | sort | uniq -d | wc -l)" = 0 ]'

echo "lint"
out=$(lint "$REG"); rc=$?
check "the shipped registry documents every table rc ($out)" '[ "$rc" = 0 ]'
jq 'del(.scripts["scripts/check-ci.sh"].codes["6"])' "$REG" >"$TMP/missing.json"
out=$(lint "$TMP/missing.json"); rc=$?
check "RED control: a row removed from the registry fails the lint and names it" '[ "$rc" = 1 ] && [ "$out" = "scripts/check-ci.sh 6" ]'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
