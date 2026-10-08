#!/usr/bin/env bash
# Tests for scripts/web/fetch-url.sh + fetch_url.py (HIMMEL-4908). Hermetic: NO
# external network. X/IG parsing runs on fixtures/*.html (--from-html); the
# plain-host path hits a throwaway 127.0.0.1 http.server; exit 3 runs with an
# empty HOME and a python that cannot import scrapling.
# Platform guard (gitbash-only): bash + python3 + curl-free; no .ps1 twin needed.
# ok/bad never fail, so `[ ] && ok || bad` is the if/else it reads as.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FETCH="$HERE/fetch-url.sh"
PY="$HERE/fetch_url.py"
FIX="$HERE/fixtures"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 - missing [$1]" ;; esac; }
hasnt() { case "$2" in *"$1"*) bad "$3 - unexpected [$1]" ;; *) ok "$3" ;; esac; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/fetch-url.XXXXXX")" || exit 1
srv=""
cleanup() { [ -z "$srv" ] || kill "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

echo "== x thread fixture =="
out="$(python3 -I "$PY" --from-html "$FIX/x-thread.html")"
has "== post 1/2 ==" "$out" "two top-level posts, in order"
has "== post 2/2 ==" "$out" "second post present"
has "author: Voxyz" "$out" "author"
has "handle: @Voxyz_ai" "$out" "handle"
has "date: 2026-10-01T09:30:00.000Z" "$out" "date of the first post"
has "First post & the idea." "$out" "text, entity decoded"
has "Reply two." "$out" "second post text"
has "https://pbs.twimg.com/media/AbC_1?format=jpg&name=small" "$out" "image media url"
has "https://video.twimg.com/amplify_video/5/vid/x.mp4" "$out" "video media url"
hasnt "QUOTED TEXT" "$out" "nested (quoted) article not merged"
hasnt "profile_images" "$out" "avatar is not media"
hasnt "decoy" "$out" "script body ignored"

echo "== x thread fixture, 2026-10 class-based DOM (no data-testid) =="
out="$(python3 -I "$PY" --from-html "$FIX/x-thread-v2.html")"
has "== post 2/2 ==" "$out" "two top-level posts"
has "author: Fixture Author" "$out" "author from font-bold"
has "handle: @Fix_user" "$out" "handle"
has "date: 11:00 PM · Oct 7, 2026" "$out" "full timestamp"
has "Line two with an arrow → here." "$out" "multi-line text kept"
has "date: 2h" "$out" "relative timestamp on a reply"
has "https://pbs.twimg.com/media/FixV2Img?format=webp&name=large" "$out" "image media url"
hasnt "EMBEDDED TEXT" "$out" "embedded article not merged"

echo "== instagram fixture =="
out="$(python3 -I "$PY" --from-html "$FIX/ig-post.html")"
has 'og:title: Fixture User on Instagram: "a caption"' "$out" "og:title"
has "og:image: https://scontent.cdninstagram.com/v/fix.jpg" "$out" "og:image"
printf '<article><div></div></article><meta property="og:title" content="shell fallback">' >"$tmp/shell.html"
has "og:title: shell fallback" "$(python3 -I "$PY" --from-html "$tmp/shell.html")" "empty article shell falls back to og tags"
printf '<p>first</p>second' >"$tmp/pl.html"
out="$(python3 -I -c 'import sys; sys.path.insert(0,sys.argv[1]); import fetch_url; print(fetch_url.html_to_text(open(sys.argv[2]).read()))' "$(dirname "$PY")" "$tmp/pl.html")"
has "first
second" "$out" "closing block tag keeps a word boundary"
printf "<meta property='og:title' content='single quoted'>" >"$tmp/sq.html"
has "og:title: single quoted" "$(python3 -I "$PY" --from-html "$tmp/sq.html")" "single-quoted og tag"

echo "== exit codes =="
python3 -I "$PY" >/dev/null 2>&1; [ $? = 2 ] && ok "no url -> 2" || bad "no url exit"
python3 -I "$PY" 'https://[' >/dev/null 2>&1; [ $? = 2 ] && ok "malformed url -> 2" || bad "malformed url exit"
python3 -I "$PY" 'file:///etc/passwd' >/dev/null 2>&1; [ $? = 2 ] && ok "non-http scheme -> 2" || bad "scheme exit"
mkdir -p "$tmp/home"
# Hermetic: block the scrapling import in-process, so a host python that has it installed never touches the network.
harness='import sys; sys.modules["scrapling"]=None; sys.modules["scrapling.fetchers"]=None; sys.path.insert(0,sys.argv[1]); import fetch_url; sys.exit(fetch_url.main([sys.argv[2]]))'
err="$(python3 -I -c "$harness" "$(dirname "$PY")" 'https://x.com/a/status/1' 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 3 ] && ok "walled host without scrapling -> 3" || bad "expected 3 got $rc ($err)"
has "scrapling-venv" "$err" "exit 3 carries the install hint"
# A 200 with an empty / challenge page is a failed fetch, not a success.
harness2='import sys; sys.path.insert(0,sys.argv[1]); import fetch_url; fetch_url.fetch_walled=lambda u: ("<html><body>checking your browser</body></html>", u, 200); sys.exit(fetch_url.main([sys.argv[2]]))'
python3 -I -c "$harness2" "$(dirname "$PY")" 'https://x.com/a/status/1' >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && ok "walled 200 with no usable content -> 4" || bad "empty-content expected 4 got $rc"
# <br> inside a post's text keeps the line break.
printf '<article><div class="whitespace-pre-wrap" dir="auto">first<br>second<br/>third</div></article>' >"$tmp/br.html"
out="$(python3 -I "$PY" --from-html "$tmp/br.html")"
has "first
second
third" "$out" "br keeps line breaks in post text"

echo "== plain host =="
mkdir -p "$tmp/www"
printf '<html><head><style>x{}</style></head><body><h1>Hello</h1><p>plain page</p></body></html>' >"$tmp/www/p.html"
port="$(python3 -I -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])")"
(cd "$tmp/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
srv=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    python3 -c "import socket,sys; socket.create_connection(('127.0.0.1',$port),0.5)" 2>/dev/null && break
    sleep 0.25
done
kill -0 "$srv" 2>/dev/null && ok "local server is up" || bad "local server died (port taken?)"
out="$(HOME="$tmp/home" bash "$FETCH" "http://127.0.0.1:$port/p.html" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "plain host -> 0" || bad "plain host rc=$rc ($out)"
has "plain page" "$out" "html rendered to text"
hasnt "x{}" "$out" "style body dropped"
err="$(HOME="$tmp/home" bash "$FETCH" "http://127.0.0.1:$port/missing.html" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 4 ] && ok "404 -> 4" || bad "404 rc=$rc"
has "HTTP 404" "$err" "status on stderr"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
