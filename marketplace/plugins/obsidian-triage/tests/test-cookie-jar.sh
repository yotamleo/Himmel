#!/usr/bin/env bash
# Tests for lib/cookie-jar.mjs - Netscape cookies.txt parse + Cookie header
# build. Pure string logic; no I/O, no network.
set -u -o pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../tools/lib/cookie-jar.mjs"
LIBURL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$lib")"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

node --check "$lib" || { echo "FAIL: cookie-jar.mjs does not parse"; exit 1; }

# A Netscape cookies.txt with: a live reddit cookie, an expired reddit cookie,
# a wrong-domain cookie, a #HttpOnly_ live cookie, a comment, and a blank line.
# Fields are TAB-separated: domain iSub path secure expiry name value
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s\n' \
'# Netscape HTTP Cookie File' \
'' \
'.reddit.com	TRUE	/	TRUE	9999999999	reddit_session	live-token-1' \
'.reddit.com	TRUE	/	TRUE	1000000000	old_expired	dead-token' \
'.example.com	TRUE	/	TRUE	9999999999	other	nope' \
'#HttpOnly_.reddit.com	TRUE	/	TRUE	0	token_v2	session-token-2' \
  > "$tmp/cookies.txt"

# parse count: 4 real cookies (comment + blank skipped; HttpOnly line kept)
n="$(FILE="$tmp/cookies.txt" LIB="$LIBURL" node --input-type=module -e '
import {readFileSync} from "node:fs";
const {parseNetscapeCookies} = await import(process.env.LIB);
console.log(parseNetscapeCookies(readFileSync(process.env.FILE,"utf8")).length);')"
assert "parse skips comment+blank, keeps HttpOnly (4 cookies)" 4 "$n"

# header at now=1720000000: live reddit + session HttpOnly kept; expired dropped;
# wrong-domain dropped. Order preserved.
hdr="$(FILE="$tmp/cookies.txt" LIB="$LIBURL" node --input-type=module -e '
import {readFileSync} from "node:fs";
const {parseNetscapeCookies, cookieHeaderFor} = await import(process.env.LIB);
const jar = parseNetscapeCookies(readFileSync(process.env.FILE,"utf8"));
console.log(cookieHeaderFor(jar, "www.reddit.com", 1720000000));')"
assert "header keeps live+session, drops expired+wrong-domain" "reddit_session=live-token-1; token_v2=session-token-2" "$hdr"

# all-expired jar -> empty header (caller treats as auth_expired)
printf '%s\n' '.reddit.com	TRUE	/	TRUE	1000000000	only	dead' > "$tmp/expired.txt"
ehdr="$(FILE="$tmp/expired.txt" LIB="$LIBURL" node --input-type=module -e '
import {readFileSync} from "node:fs";
const {parseNetscapeCookies, cookieHeaderFor} = await import(process.env.LIB);
const jar = parseNetscapeCookies(readFileSync(process.env.FILE,"utf8"));
console.log(JSON.stringify(cookieHeaderFor(jar, "www.reddit.com", 1720000000)));')"
assert "all-expired jar builds empty header" '""' "$ehdr"

# subdomain match: .reddit.com applies to old.reddit.com
shdr="$(FILE="$tmp/cookies.txt" LIB="$LIBURL" node --input-type=module -e '
import {readFileSync} from "node:fs";
const {parseNetscapeCookies, cookieHeaderFor} = await import(process.env.LIB);
const jar = parseNetscapeCookies(readFileSync(process.env.FILE,"utf8"));
console.log(cookieHeaderFor(jar, "old.reddit.com", 1720000000).includes("reddit_session") ? "yes" : "no");')"
assert "dot-domain applies to subdomain host" yes "$shdr"

echo ""
echo "cookie-jar tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
