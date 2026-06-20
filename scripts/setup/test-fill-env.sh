#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-fill-env.sh -- hermetic tests for fill-env.sh pure helpers (HIMMEL-453).
# dotenv_get/set (incl. CRLF), fillable_keys (fixture-based, NOT pinned to the
# live .env.example), and the non-interactive fill_env no-op.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$here/fill-env.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# dotenv_set replaces existing key (first match only).
f1="$td/f1.env"
printf 'A=1\nKEY=old\nB=2\nKEY=dup\n' > "$f1"
dotenv_set "$f1" KEY new
check "set replaces first match" "$(dotenv_get "$f1" KEY)" "new"
check "set leaves later dup"     "$(grep -c '^KEY=dup' "$f1")" "1"
check "set preserves siblings"   "$(dotenv_get "$f1" B)" "2"

# dotenv_set appends an absent key.
f2="$td/f2.env"
printf 'A=1\n' > "$f2"
dotenv_set "$f2" NEWKEY hello
check "set appends absent key" "$(dotenv_get "$f2" NEWKEY)" "hello"

# dotenv_set preserves a backslash-bearing value (awk ENVIRON, not -v escaping).
f2b="$td/f2b.env"
printf 'KEY=old\n' > "$f2b"
dotenv_set "$f2b" KEY 'C:\Users\me\himmel'
check "set keeps backslashes" "$(dotenv_get "$f2b" KEY)" 'C:\Users\me\himmel'

# dotenv_set appends safely onto a file with NO trailing newline (no fusing).
f2c="$td/f2c.env"
printf 'FOO=old' > "$f2c"   # deliberately no trailing \n
dotenv_set "$f2c" BAR new
check "no-trailing-newline: FOO intact" "$(dotenv_get "$f2c" FOO)" "old"
check "no-trailing-newline: BAR added"  "$(dotenv_get "$f2c" BAR)" "new"

# Value containing '=' (e.g. a base64-padded token) round-trips intact.
f2d="$td/f2d.env"
printf 'TOK=old\n' > "$f2d"
dotenv_set "$f2d" TOK 'a=b=c=='
check "value with = round-trips" "$(dotenv_get "$f2d" TOK)" 'a=b=c=='

# CRLF: a KEY=old\r line -> get returns clean value, set replaces cleanly.
f3="$td/f3.env"
printf 'A=1\r\nKEY=old\r\n' > "$f3"
check "get strips CR" "$(dotenv_get "$f3" KEY)" "old"
dotenv_set "$f3" KEY fresh
check "set on CRLF line" "$(dotenv_get "$f3" KEY)" "fresh"

# fillable_keys against a FIXTURE (commented + uncommented + blank + no-`=`).
f4="$td/example.env"
{
  printf '# a comment\n'
  printf 'USER_SLUG=your-slug\n'
  printf '# COMMENTED_KEY=skipme\n'
  printf '\n'
  printf 'JIRA_API_TOKEN=tok\n'
  printf 'not a kv line\n'
  printf '  # indented comment\n'
  printf 'ubuntu_vm_user=u\n'
} > "$f4"
got="$(fillable_keys "$f4" | tr '\n' ',')"
check "fillable_keys = uncommented only" "$got" "USER_SLUG,JIRA_API_TOKEN,ubuntu_vm_user,"

# fillable_keys smoke run against the real .env.example (no assert, just rc 0).
if fillable_keys "$here/../../.env.example" >/dev/null 2>&1; then
  echo "ok - fillable_keys smoke on real .env.example"
else
  echo "FAIL: fillable_keys errored on real .env.example"; fails=$((fails+1))
fi

# fill_env non-interactive (stdin not a TTY) -> rc 0, file unchanged.
f5="$td/f5.env"
printf 'JIRA_API_TOKEN=keepme\n' > "$f5"
before="$(cat "$f5")"
fill_env "$f5" "$f4" </dev/null >/dev/null 2>&1; rc=$?
check "fill_env non-interactive rc 0" "$rc" "0"
check "fill_env non-interactive no-op" "$(cat "$f5")" "$before"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
