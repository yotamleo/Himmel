#!/usr/bin/env bash
# test-check-hook-file-parse.sh — paired tests for the PostToolUse guard that
# catches a hook file which does not parse (HIMMEL-2230).
#
# The guard exists because a scripts/hooks/*.sh is LIVE the instant it is
# written: the motivating incident never reached a commit, so every commit-time
# lint layer was out of the path while the broken hook denied every command
# fleet-wide. These cases are therefore rc-proofs against the REAL guard and the
# REAL checker, with negative controls — the incident was originally caught only
# because a probe harness's benign inputs went red while every positive case
# still passed.
#
# Usage: bash scripts/hooks/test-check-hook-file-parse.sh
# Exit:  0 all passed, 1 any failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/check-hook-file-parse.sh"
[ -f "$HOOK" ] || { printf 'FAIL: guard not found at %s\n' "$HOOK"; exit 1; }

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not installed\n'; exit 0; }

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; [ $# -ge 2 ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }

# assert_rc <label> <want> <got> [extra] and assert_err <label> <ere>: if/else
# forms on purpose. The A && B || C shape reads as if-then-else but is not one
# (C also runs when B fails), and shellcheck flags it as SC2015.
assert_rc() {
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected rc=$2, got $3${4:+ - $4}"; fi
}
assert_err() {
    if grep -qE "$2" "$ERR"; then pass "$1"; else fail "$1" "stderr did not match: $2"; fi
}

TMP="$(mktemp -d -t hookparse.XXXXXX)"
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP" 2>/dev/null; }
trap cleanup EXIT

Q="$(printf '\047')"
mkdir -p "$TMP/scripts/hooks" "$TMP/scripts/other"

# A hook-shaped file whose awk program carries a prose apostrophe: the quote
# ends the shell string, the file stops parsing, and (were it live) the hook
# would deny every command. Built with printf so this suite's own source stays
# parseable.
# SC2016: the printf format strings carry literal $1/$cmd on purpose — they are
# the fixture source being written to disk, not expansions here.
# shellcheck disable=SC2016
_write_broken() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -uo pipefail\n'
        printf 'cmd="$1"\n'
        printf 'verdict=$(printf %s%%s\n%s "$cmd" | awk %s\n' "$Q" "$Q" "$Q"
        printf '    # the scanner walks each record; it%ss the entry point\n' "$Q"
        printf '    /danger/ { print "BLOCK"; exit }\n'
        printf '    { print "ALLOW" }\n'
        printf '%s)\n' "$Q"
        printf 'printf %sverdict=%%s\n%s "$verdict"\n' "$Q" "$Q"
    } > "$1"
}

# The shape `bash -n` cannot see: two prose apostrophes re-balance the file, so
# it PARSES while awk receives a truncated program.
# shellcheck disable=SC2016
_write_truncated() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -uo pipefail\n'
        printf 'awk %sBEGIN { x = 1 }  # it%ss the parser%ss job\n' "$Q" "$Q" "$Q"
        printf '%s /dev/null\n' "$Q"
    } > "$1"
}

# shellcheck disable=SC2016
_write_clean() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -uo pipefail\n'
        printf 'cmd="$1"\n'
        printf 'verdict=$(printf %s%%s\n%s "$cmd" | awk %s\n' "$Q" "$Q" "$Q"
        printf '    # the scanner walks each record; this is the entry point\n'
        printf '    /danger/ { print "BLOCK"; exit }\n'
        printf '    { print "ALLOW" }\n'
        printf '%s)\n' "$Q"
        printf 'printf %sverdict=%%s\n%s "$verdict"\n' "$Q" "$Q"
    } > "$1"
}

# run <tool> <file_path> -> echoes "<rc>"; stderr lands in $ERR.
ERR="$TMP/err"
run() {
    printf '{"tool_name":%s,"tool_input":{"file_path":%s}}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
        | bash "$HOOK" >/dev/null 2>"$ERR"
    echo "$?"
}

printf '\nPositive controls (the guard must fire)\n'

BROKEN="$TMP/scripts/hooks/broken.sh"
_write_broken "$BROKEN"
RC="$(run Write "$BROKEN")"
assert_rc "unparseable hook file denies" 2 "$RC"
assert_err "refusal names [parse]" '\[parse\]'
assert_err "refusal states the fleet-wide consequence" 'DENIES EVERY COMMAND'

TRUNC="$TMP/scripts/hooks/truncated.sh"
_write_truncated "$TRUNC"
if bash -n "$TRUNC" 2>/dev/null; then
    pass "truncated fixture parses (so this case proves more than bash -n alone)"
else
    fail "truncated fixture must PARSE, else it does not test [quote-break] independently"
fi
RC="$(run Write "$TRUNC")"
assert_rc "parseable-but-truncated awk program denies" 2 "$RC"
assert_err "refusal names [quote-break]" '\[quote-break\]'

# Windows lane: the same file arrives with backslash separators.
WINPATH="$(printf '%s' "$BROKEN" | tr '/' '\134')"
RC="$(run Edit "$WINPATH")"
assert_rc "backslash-separated path is still in scope" 2 "$RC"

printf '\nNegative controls (the guard must stay silent)\n'

CLEAN="$TMP/scripts/hooks/clean.sh"
_write_clean "$CLEAN"
RC="$(run Write "$CLEAN")"
assert_rc "clean hook file allows" 0 "$RC" "$(head -3 "$ERR")"

OUTSIDE="$TMP/scripts/other/broken.sh"
_write_broken "$OUTSIDE"
RC="$(run Write "$OUTSIDE")"
assert_rc "a broken file OUTSIDE scripts/hooks/ is out of scope" 0 "$RC"

RC="$(run Read "$BROKEN")"
assert_rc "non-write tool is ignored" 0 "$RC"

RC="$(run Write "$TMP/scripts/hooks/does-not-exist.sh")"
assert_rc "missing file fails open" 0 "$RC"

RC="$(printf 'not json' | bash "$HOOK" >/dev/null 2>&1; echo $?)"
assert_rc "unparseable stdin fails open" 0 "$RC"

printf '\nReal corpus (a guard that fires on healthy production files is unshippable)\n'
CORPUS_FAIL=""
for _hf in "$SCRIPT_DIR"/*.sh; do
    [ -f "$_hf" ] || continue
    RC="$(run Write "$_hf")"
    [ "$RC" = "0" ] || CORPUS_FAIL="$CORPUS_FAIL $(basename "$_hf")(rc=$RC)"
done
if [ -z "$CORPUS_FAIL" ]; then
    pass "every scripts/hooks/*.sh passes the guard"
else
    fail "guard fires on healthy hook files:$CORPUS_FAIL"
fi

printf '\n====================================\n'
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '====================================\n'
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
