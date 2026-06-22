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

# dotenv_help: contiguous `#` block above a key + inline trailing comment
# (HIMMEL-546). Fixture exercises multi-line block, block+inline, inline-only
# (a KEY line directly above breaks contiguity), blank-line break, and absent.
f6="$td/help.env"
{
  printf '# === SECTION: TEST ===\n'
  printf '\n'
  printf '# Operator slug help line one.\n'
  printf '# help line two.\n'
  printf 'USER_SLUG=your-slug\n'
  printf '# group header ---\n'
  printf 'FIRST=a   # inline for first\n'
  printf 'SECOND=b  # inline for second\n'
  printf '\n'
  printf '# stray comment\n'
  printf '\n'
  printf 'THIRD=c\n'
} > "$f6"
check "help multi-line block (no inline)" "$(dotenv_help "$f6" USER_SLUG | tr '\n' '|')" "Operator slug help line one.|help line two.|"
check "help block + inline"               "$(dotenv_help "$f6" FIRST | tr '\n' '|')" "group header ---|inline for first|"
check "help inline only (key line above)" "$(dotenv_help "$f6" SECOND | tr '\n' '|')" "inline for second|"
check "help blank line breaks contiguity" "$(dotenv_help "$f6" THIRD | tr '\n' '|')" ""
check "help empty when key absent"        "$(dotenv_help "$f6" MISSING)" ""

# dotenv_help: a commented-out `# OTHERKEY=...` assignment is a doc-block
# boundary (belongs to the previous var) -> it resets the block and never leaks
# as a literal KEY=value help line. Prose that merely contains '=' is kept.
f6c="$td/help-boundary.env"
{
  printf '# Help for projects.\n'
  printf '# JIRA_PROJECTS=HIMMEL,LUNA\n'
  printf '# Help for board id only.\n'
  printf '# set X=Y in your shell to override.\n'
  printf 'JIRA_BOARD_ID=123\n'
} > "$f6c"
check "help: commented KEY= resets block (no leak)" "$(dotenv_help "$f6c" JIRA_BOARD_ID | tr '\n' '|')" "Help for board id only.|set X=Y in your shell to override.|"

# dotenv_help: key match is exact (anchored on `KEY=`), no prefix collision.
f6d="$td/help-prefix.env"
{
  printf '# Help for FOO.\n'
  printf 'FOO=1\n'
  printf '# Help for FOOBAR.\n'
  printf 'FOOBAR=2\n'
} > "$f6d"
check "help: no prefix collision (FOO)"    "$(dotenv_help "$f6d" FOO | tr '\n' '|')" "Help for FOO.|"
check "help: no prefix collision (FOOBAR)" "$(dotenv_help "$f6d" FOOBAR | tr '\n' '|')" "Help for FOOBAR.|"

# _fe_format_help: non-empty -> leading blank line + 4-space indent per line.
check "format_help non-empty" "$(_fe_format_help "$(printf 'a\nb')" | tr '\n' '|')" "|    a|    b|"
# _fe_format_help: empty input -> no output (bare prompt).
check "format_help empty" "$(_fe_format_help "")" ""

# dotenv_help CRLF-safe: \r on comment + key lines is stripped from the output.
f6b="$td/help-crlf.env"
printf '# crlf help line.\r\nKEY=v   # crlf inline\r\n' > "$f6b"
check "help strips CR (block+inline)" "$(dotenv_help "$f6b" KEY | tr '\n' '|')" "crlf help line.|crlf inline|"

# dotenv_help smoke on real .env.example: JIRA_API_TOKEN's inline carries the
# token-URL (where-to-get-it), so help is non-empty.
if [ -n "$(dotenv_help "$here/../../.env.example" JIRA_API_TOKEN)" ]; then
  echo "ok - dotenv_help smoke on real .env.example (JIRA_API_TOKEN non-empty)"
else
  echo "FAIL: dotenv_help empty for JIRA_API_TOKEN on real .env.example"; fails=$((fails+1))
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
