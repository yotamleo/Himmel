#!/usr/bin/env bash
# Tests for the cookieless Scrapling Instagram backend (HIMMEL-4675):
# tools/ig-scrapling-media.py (extraction from recorded post HTML) and its
# wiring into ig-media-fetch.py as the PRIMARY backend, gallery-dl the fallback.
# Hermetic: NO network. Extraction runs on fixtures/ig-scrapling/*.html; the
# fetch path runs a stub IG_SCRAPLING_PYTHON that prints canned helper JSON, and
# stub curl / gallery-dl / ffmpeg on PATH.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
HELPER="$TOOLS_DIR/ig-scrapling-media.py"
TOOL="$TOOLS_DIR/ig-media-fetch.py"
FIX="$SCRIPT_DIR/fixtures/ig-scrapling"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ig-scrapling.XXXXXX")" || exit 1; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$tmp"' EXIT; echo "tmp=$tmp"
HOME="$tmp/home"; mkdir -p "$HOME/.luna/cookies"; export HOME
export IG_MEDIA_NO_SLEEP=1 HIMMEL_IG_DAILY_CAP=100000
unset IG_SCRAPLING_PYTHON HARVEST_SCRAPE_DENY

jq_py() { # $1 = json file, $2 = python expression over `d`
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# --- Test 1: reel fixture -> one video item, caption, decoy ignored ---------
echo "Test 1: extract reel"
python3 "$HELPER" --from-html "$FIX/reel.html" --shortcode REELFIX1 >"$tmp/reel.json"
assert "reel exit 0" 0 "$?"
assert "reel status ok" ok "$(jq_py "$tmp/reel.json" 'd["status"]')"
assert "reel has one item" 1 "$(jq_py "$tmp/reel.json" 'len(d["items"])')"
assert "reel item is the first video version" "video https://scontent-fix1-1.cdninstagram.com/v/fixture/REELFIX1_7.mp4?oh=fixture" \
  "$(jq_py "$tmp/reel.json" 'd["items"][0]["kind"]+" "+d["items"][0]["url"]')"
assert "reel caption" "Fixture caption for REELFIX1. #fixture" "$(jq_py "$tmp/reel.json" 'd["caption"]')"

# --- Test 2: carousel fixture -> every child, in order, widest candidate ----
echo "Test 2: extract carousel"
python3 "$HELPER" --from-html "$FIX/carousel.html" --shortcode CARFIX22 >"$tmp/car.json"
assert "carousel exit 0" 0 "$?"
assert "carousel has six image items" "6 image" \
  "$(jq_py "$tmp/car.json" 'str(len(d["items"]))+" "+",".join(sorted({i["kind"] for i in d["items"]}))')"
grep -q decoy "$tmp/car.json" && a=present || a=absent
assert "decoy node (same code, no media) ignored" absent "$a"
first="$(jq_py "$tmp/car.json" 'd["items"][0]["url"]')"
last="$(jq_py "$tmp/car.json" 'd["items"][-1]["url"]')"
[ "$first" != "$last" ] && a=ok || a=same
assert "carousel items are distinct children" ok "$a"
assert "carousel children in page order" "1 7 13 19 25 31" \
  "$(jq_py "$tmp/car.json" '" ".join(i["url"].split("CARFIX22_")[1].split(".")[0] for i in d["items"])')"

# --- Test 2b: the widest candidate wins, whatever its position -------------
echo "Test 2b: widest candidate"
printf '%s' '<script type="application/json">{"x":{"code":"WIDE0001","image_versions2":{"candidates":[{"width":320,"url":"https://a.cdninstagram.com/s.jpg"},{"width":1080,"url":"https://a.cdninstagram.com/l.jpg"},{"width":640,"url":"https://a.cdninstagram.com/m.jpg"}]}}}</script>' >"$tmp/wide.html"
python3 "$HELPER" --from-html "$tmp/wide.html" --shortcode WIDE0001 >"$tmp/wide.json"
assert "widest candidate chosen" "https://a.cdninstagram.com/l.jpg" "$(jq_py "$tmp/wide.json" 'd["items"][0]["url"]')"

# --- Test 3: wrong shortcode -> no_media, exit 4 ---------------------------
echo "Test 3: no media for another shortcode"
python3 "$HELPER" --from-html "$FIX/reel.html" --shortcode NOPE0000 >"$tmp/none.json"
assert "no-media exit 4" 4 "$?"
assert "no-media status" no_media "$(jq_py "$tmp/none.json" 'd["status"]')"

# --- Test 4: a non-CDN media host is refused -------------------------------
echo "Test 4: CDN host allowlist"
sed 's#scontent-fix1-1.cdninstagram.com#cdninstagram.com.evil.example#g' "$FIX/reel.html" >"$tmp/evil.html"
python3 "$HELPER" --from-html "$tmp/evil.html" --shortcode REELFIX1 >"$tmp/evil.json"
assert "off-CDN media -> exit 4" 4 "$?"
assert "off-CDN media -> no_media" no_media "$(jq_py "$tmp/evil.json" 'd["status"]')"

# --- Test 4b: a carousel child with no CDN URL -> error, never a short ok --
echo "Test 4b: incomplete carousel"
printf '%s' '<script type="application/json">{"x":{"code":"PART0001","carousel_media":[{"image_versions2":{"candidates":[{"url":"https://a.cdninstagram.com/1.jpg"}]}},{"image_versions2":{"candidates":[{"url":"https://evil.example/2.jpg"}]}}]}}</script>' >"$tmp/part.html"
python3 "$HELPER" --from-html "$tmp/part.html" --shortcode PART0001 >"$tmp/part.json"
assert "incomplete carousel exit 6" 6 "$?"
assert "incomplete carousel status error" error "$(jq_py "$tmp/part.json" 'd["status"]')"

# --- Test 5: landing on the login page is a login wall ---------------------
echo "Test 5: login wall"
python3 "$HELPER" --from-html "$FIX/reel.html" --shortcode REELFIX1 \
  --final-url "https://www.instagram.com/accounts/login/?next=%2Freel%2FREELFIX1%2F" >"$tmp/login.json"
assert "login wall exit 4" 4 "$?"
assert "login wall status" login_wall "$(jq_py "$tmp/login.json" 'd["status"]')"

# --- fetch-path stubs ------------------------------------------------------
mkdir -p "$tmp/bin"
# Stub scrapling python: records its call, prints $STUB_JSON, exits $STUB_RC.
cat > "$tmp/scrapling-python" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
cat "$STUB_JSON"
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/scrapling-python"
# Hanging helper for the --budget test (Test 12).
cat > "$tmp/slow-python" <<'STUB'
#!/usr/bin/env bash
exec python3 -c "import time; time.sleep(30)"
STUB
chmod +x "$tmp/slow-python"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_CALLS"
out=""
while [ $# -gt 0 ]; do case "$1" in -o) shift; out="$1" ;; esac; shift; done
[ -n "$out" ] || exit 2
echo "fake media" > "$out"
STUB
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
for last in "$@"; do :; done
: > "$last"
STUB
cat > "$tmp/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do case "$1" in -D) shift; dest="$1" ;; esac; shift; done
mkdir -p "$dest"; echo one > "$dest/1.jpg"; echo gdl >> "$STUB_CALLS"
STUB
chmod +x "$tmp/bin/curl" "$tmp/bin/ffmpeg" "$tmp/gallery-dl"
# Sealed PATH: the station's real gallery-dl/curl/ffmpeg must never be reachable
# (a leaked real gallery-dl would hit instagram.com). Only these tools exist.
mkdir -p "$tmp/sys"
for t in python3 bash env cat mkdir rm cp sed grep; do ln -s "$(command -v "$t")" "$tmp/sys/$t"; done
export PATH="$tmp/bin:$tmp/sys" STUB_CALLS="$tmp/calls"
cat > "$tmp/ok.json" <<'EOF'
{"status": "ok", "caption": "Scrapled caption text", "items": [
 {"kind": "image", "url": "https://scontent-fix1-1.cdninstagram.com/v/fixture/A_1.jpg"},
 {"kind": "image", "url": "https://scontent-fix1-1.cdninstagram.com/v/fixture/A_2.jpg"}]}
EOF
echo '{"status": "login_wall", "detail": "accounts/login"}' >"$tmp/wall.json"

make_vault() { # $1 dir, $2 shortcode
  mkdir -p "$1/Clippings"
  cat > "$1/Clippings/clip.md" <<EOF
---
title: "c"
source: "https://www.instagram.com/p/$2/"
type: instagram
ig_media_pending: true
---
# c

## Source
[link](https://www.instagram.com/p/$2/)
EOF
}
run_tool() { python3 "$TOOL" "$@"; }

# --- Test 6: Scrapling primary, no cookie and no gallery-dl needed ----------
echo "Test 6: scrapling primary, cookieless"
: >"$tmp/calls"; export IG_SCRAPLING_PYTHON="$tmp/scrapling-python" STUB_JSON="$tmp/ok.json" STUB_RC=0
make_vault "$tmp/v6" SCRP0006
run_tool "$tmp/v6" >"$tmp/v6.out" 2>"$tmp/v6.err"
assert "scrapling run exit 0" 0 "$?"
grep -qF "Clippings/clip.md: 2 slides + 0 transcript [scrapling]" "$tmp/v6.out" && a=ok || a=no
assert "outcome line names the scrapling backend" ok "$a"
grep -q '^media_enrichment_status: ok$' "$tmp/v6/Clippings/clip.md" && a=ok || a=no
assert "clip enriched ok" ok "$a"
grep -qF "Scrapled caption text" "$tmp/v6/Clippings/clip.md" && a=ok || a=no
assert "scrapling caption lands in ## Crawled content" ok "$a"
grep -q -- '--shortcode SCRP0006' "$tmp/calls" && a=ok || a=no
assert "helper called with the shortcode" ok "$a"
grep -q -- '^curl .*--max-redirs 0' "$tmp/calls" && a=ok || a=no
assert "curl follows no redirect off the CDN host" ok "$a"
grep -q '^ig_media_backend: scrapling$' "$tmp/v6/Clippings/clip.md" && a=ok || a=no
assert "clip records ig_media_backend: scrapling (HIMMEL-4684)" ok "$a"

# --- Test 7: Scrapling login wall -> gallery-dl fallback -------------------
echo "Test 7: gallery-dl fallback"
: >"$tmp/calls"; export STUB_JSON="$tmp/wall.json" STUB_RC=4
cp "$tmp/gallery-dl" "$tmp/bin/gallery-dl"; echo DUMMY >"$HOME/.luna/cookies/instagram.txt"
make_vault "$tmp/v7" SCRP0007
run_tool "$tmp/v7" >"$tmp/v7.out" 2>"$tmp/v7.err"
assert "fallback run exit 0" 0 "$?"
grep -qF "1 slides + 0 transcript [gallery-dl]" "$tmp/v7.out" && a=ok || a=no
assert "outcome line names the gallery-dl fallback" ok "$a"
grep -q '^gdl$' "$tmp/calls" && a=ok || a=no
assert "gallery-dl ran after scrapling" ok "$a"
grep -q '^ig_media_backend: gallery-dl$' "$tmp/v7/Clippings/clip.md" && a=ok || a=no
assert "clip records ig_media_backend: gallery-dl (HIMMEL-4684)" ok "$a"

# --- Test 7b: curl missing -> gallery-dl fallback, no crash ---------------
echo "Test 7b: curl missing"
: >"$tmp/calls"; export STUB_JSON="$tmp/ok.json" STUB_RC=0
cp "$tmp/bin/curl" "$tmp/curl.off"; rm -f "$tmp/bin/curl"
make_vault "$tmp/v7b" SCRP0071
run_tool "$tmp/v7b" >"$tmp/v7b.out" 2>"$tmp/v7b.err"
assert "curl-missing run exit 0" 0 "$?"
grep -qF "[gallery-dl]" "$tmp/v7b.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"
cp "$tmp/curl.off" "$tmp/bin/curl"
export STUB_JSON="$tmp/wall.json" STUB_RC=4

# --- Test 7c: unlaunchable scrapling interpreter -> gallery-dl fallback ----
echo "Test 7c: scrapling interpreter missing"
make_vault "$tmp/v7c" SCRP0072
IG_SCRAPLING_PYTHON="$tmp/no-such-python" run_tool "$tmp/v7c" >"$tmp/v7c.out" 2>"$tmp/v7c.err"
assert "missing-interpreter run exit 0" 0 "$?"
grep -qF "[gallery-dl]" "$tmp/v7c.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"

# --- Test 8: Scrapling login wall, no fallback -> retryable failure --------
echo "Test 8: no fallback available"
rm -f "$tmp/bin/gallery-dl" "$HOME/.luna/cookies/instagram.txt"
make_vault "$tmp/v8" SCRP0008
run_tool "$tmp/v8" >"$tmp/v8.out" 2>"$tmp/v8.err"
assert "no-fallback run exit 0" 0 "$?"
grep -q '^ig_media_pending: true$' "$tmp/v8/Clippings/clip.md" && a=ok || a=no
assert "clip stays pending (retryable)" ok "$a"
grep -q '^media_last_error: login_wall$' "$tmp/v8/Clippings/clip.md" && a=ok || a=no
assert "login_wall recorded" ok "$a"

# --- Test 9: kill switch skips scrapling -----------------------------------
echo "Test 9: HARVEST_SCRAPE_DENY kill switch"
: >"$tmp/calls"; export STUB_JSON="$tmp/ok.json" STUB_RC=0
cp "$tmp/gallery-dl" "$tmp/bin/gallery-dl"; echo DUMMY >"$HOME/.luna/cookies/instagram.txt"
make_vault "$tmp/v9" SCRP0009
HARVEST_SCRAPE_DENY=local-headless run_tool "$tmp/v9" >"$tmp/v9.out" 2>"$tmp/v9.err"
assert "kill-switch run exit 0" 0 "$?"
grep -q -- '--shortcode' "$tmp/calls" && a=called || a=skipped
assert "scrapling not called under the kill switch" skipped "$a"
grep -qF "[gallery-dl]" "$tmp/v9.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"

# --- Test 10: .harvest-backends skip=local-headless skips scrapling --------
echo "Test 10: .harvest-backends route"
: >"$tmp/calls"
make_vault "$tmp/v10" SCRP0010
echo "www.instagram.com skip=local-headless" >"$tmp/v10/.harvest-backends"
run_tool "$tmp/v10" >"$tmp/v10.out" 2>"$tmp/v10.err"
assert "route-skip run exit 0" 0 "$?"
grep -q -- '--shortcode' "$tmp/calls" && a=called || a=skipped
assert "scrapling not called when the route skips it" skipped "$a"
grep -qF "[gallery-dl]" "$tmp/v10.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"

# --- Test 11: preflight: neither backend usable -> exit 2 ------------------
echo "Test 11: preflight"
rm -f "$tmp/bin/gallery-dl"
make_vault "$tmp/v11" SCRP0011
HARVEST_SCRAPE_DENY=all run_tool "$tmp/v11" >"$tmp/v11.out" 2>"$tmp/v11.err"
assert "no usable backend -> exit 2" 2 "$?"
unset IG_SCRAPLING_PYTHON
run_tool "$tmp/v11" >"$tmp/v11b.out" 2>"$tmp/v11b.err"
assert "no scrapling venv, no gallery-dl -> exit 2" 2 "$?"
grep -q "scrapling-venv" "$tmp/v11b.err" && a=ok || a=no
assert "preflight names the scrapling venv install" ok "$a"

# --- Test 12: wall-clock budget stops the batch and still prints the summary
# (HIMMEL-4684). The stub helper hangs; the per-clip timeout is capped by what
# is left of the budget, and no clip starts once it is spent.
echo "Test 12: --budget"
make_vault "$tmp/v12" SCRP0012
sed 's/SCRP0012/SCRP0013/g' "$tmp/v12/Clippings/clip.md" >"$tmp/v12/Clippings/clip2.md"
t0=$SECONDS
IG_SCRAPLING_PYTHON="$tmp/slow-python" run_tool "$tmp/v12" --budget 2 >"$tmp/v12.out" 2>"$tmp/v12.err"
rc=$?; took=$((SECONDS - t0))
assert "budget run exit 0" 0 "$rc"
[ "$took" -lt 15 ] && a=ok || a="took ${took}s"
assert "budget run stops inside its budget, not the 180s download timeout" ok "$a"
grep -qF "ig-media-fetch: 2 selected" "$tmp/v12.out" && a=ok || a=no
assert "summary printed after a budget stop" ok "$a"
grep -qF "budget" "$tmp/v12.out" && a=ok || a=no
assert "budget stop is reported" ok "$a"
grep -q '^media_' "$tmp/v12/Clippings/clip2.md" && a=touched || a=untouched
assert "clip after the budget stop is not started" untouched "$a"
grep -q '^ig_media_pending: true$' "$tmp/v12/Clippings/clip2.md" && a=ok || a=no
assert "unstarted clip stays pending" ok "$a"

echo ""
echo "ig-scrapling tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
