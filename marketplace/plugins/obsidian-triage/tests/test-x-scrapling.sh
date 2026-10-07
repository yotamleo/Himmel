#!/usr/bin/env bash
# Tests for the cookieless Scrapling X backend (HIMMEL-4677):
# tools/x-scrapling-media.py (extraction from recorded status HTML) and its
# wiring into x-media-fetch.py as the PRIMARY backend, gallery-dl the fallback.
# Hermetic: NO network. Extraction runs on fixtures/x-scrapling/*.html (+ a
# recorded video.twimg.com URL log); the fetch path runs a stub
# X_SCRAPLING_PYTHON that prints canned helper JSON, and stub curl / gallery-dl /
# ffmpeg on a sealed PATH.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
HELPER="$TOOLS_DIR/x-scrapling-media.py"
TOOL="$TOOLS_DIR/x-media-fetch.py"
FIX="$SCRIPT_DIR/fixtures/x-scrapling"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/x-scrapling.XXXXXX")" || exit 1; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$tmp"' EXIT; echo "tmp=$tmp"
HOME="$tmp/home"; mkdir -p "$HOME/.luna/cookies"; export HOME
export X_MEDIA_NO_SLEEP=1
# HIMMEL-4708: Tests 5-13 pin the cookie switch ON - today's gallery-dl
# fallback, unchanged. Test 14 runs with it off (the default).
export HIMMEL_MEDIA_COOKIES=on
unset X_SCRAPLING_PYTHON HARVEST_SCRAPE_DENY

jq_py() { # $1 = json file, $2 = python expression over `d`
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# --- Test 1: direct mp4s + an image, in article order ----------------------
echo "Test 1: extract direct mp4 status"
python3 "$HELPER" --from-html "$FIX/direct-mp4.html" --status-id 2100888166219886818 >"$tmp/direct.json"
assert "direct exit 0" 0 "$?"
assert "direct status ok" ok "$(jq_py "$tmp/direct.json" 'd["status"]')"
assert "one image then four videos" "image video video video video" \
  "$(jq_py "$tmp/direct.json" '" ".join(i["kind"] for i in d["items"])')"
assert "image normalised to name=large" "https://pbs.twimg.com/media/HSfaimhaIAAoFk6?format=jpg&name=large" \
  "$(jq_py "$tmp/direct.json" 'd["items"][0]["url"]')"
assert "videos are direct video.twimg.com mp4s" "True" \
  "$(jq_py "$tmp/direct.json" 'all(i["url"].startswith("https://video.twimg.com/") and ".mp4" in i["url"] and not i["hls"] for i in d["items"][1:])')"

# --- Test 2: streamed video -> captured HLS master; quoted post excluded ----
echo "Test 2: extract HLS status with a quoted post"
python3 "$HELPER" --from-html "$FIX/hls-quote.html" --net-log "$FIX/hls-quote.netlog" \
  --status-id 2106396375269134597 >"$tmp/hls.json"
assert "hls exit 0" 0 "$?"
assert "one HLS video item" "1 video True" \
  "$(jq_py "$tmp/hls.json" 'str(len(d["items"]))+" "+d["items"][0]["kind"]+" "+str(d["items"][0]["hls"])')"
assert "master playlist chosen, not a variant" \
  "https://video.twimg.com/amplify_video/2106366034596839426/pl/P7vFEoCnfC8F3GGY.m3u8?tag=29&v=cfc" \
  "$(jq_py "$tmp/hls.json" 'd["items"][0]["url"]')"
python3 "$HELPER" --from-html "$FIX/hls-quote.html" --net-log "$FIX/hls-quote.netlog" \
  --status-id 2105643919119696297 >"$tmp/quoted.json"
assert "quoted status yields only its own media" "image" \
  "$(jq_py "$tmp/quoted.json" '" ".join(i["kind"] for i in d["items"])')"
# The focal tweet's own permalink (its timestamp) sits AFTER the quoted post;
# with the pre-quote video link gone, that trailing link alone must identify it.
sed 's#/status/2106396375269134597/video/1#/i/videos/1#g' "$FIX/hls-quote.html" >"$tmp/trailing.html"
python3 "$HELPER" --from-html "$tmp/trailing.html" --net-log "$FIX/hls-quote.netlog" \
  --status-id 2106396375269134597 >"$tmp/trailing.json"
assert "trailing permalink identifies the status" "ok 1" \
  "$(jq_py "$tmp/trailing.json" 'd["status"]+" "+str(len(d.get("items", [])))')"

# --- Test 3: streamed video with no captured playlist -> error, never short ok
echo "Test 3: HLS without a network log"
python3 "$HELPER" --from-html "$FIX/hls-quote.html" --status-id 2106396375269134597 >"$tmp/nolog.json"
assert "no playlist exit 6" 6 "$?"
assert "no playlist status error" error "$(jq_py "$tmp/nolog.json" 'd["status"]')"

# --- Test 4: login wall, unknown status, off-host media --------------------
echo "Test 4: login wall / no media / host allowlist"
python3 "$HELPER" --from-html "$FIX/hls-quote.html" --status-id 2106396375269134597 \
  --final-url "https://x.com/i/flow/login?redirect_after_login=%2Fx" >"$tmp/login.json"
assert "login wall exit 4" 4 "$?"
assert "login wall status" login_wall "$(jq_py "$tmp/login.json" 'd["status"]')"
python3 "$HELPER" --from-html "$FIX/direct-mp4.html" --status-id 1 >"$tmp/none.json"
assert "unknown status exit 4" 4 "$?"
assert "unknown status no_media" no_media "$(jq_py "$tmp/none.json" 'd["status"]')"
sed 's#https://video.twimg.com/#https://video.twimg.com.evil.example/#g' "$FIX/direct-mp4.html" >"$tmp/evil.html"
python3 "$HELPER" --from-html "$tmp/evil.html" --status-id 2100888166219886818 >"$tmp/evil.json"
grep -q evil.example "$tmp/evil.html"
assert "leak matcher control: finds the planted host" 0 "$?"
grep -q evil.example "$tmp/evil.json"
assert "off-host video URL never returned (grep rc 1, not an error)" 1 "$?"
python3 "$HELPER" --from-html "$FIX/direct-mp4.html" --status-id 210088816621988681 >"$tmp/prefix.json"
assert "a status id that only prefixes another is not that status" no_media "$(jq_py "$tmp/prefix.json" 'd["status"]')"
python3 "$HELPER" --status-id abc --from-html "$FIX/direct-mp4.html" >/dev/null 2>&1
assert "non-numeric status id refused" 2 "$?"

# --- fetch-path stubs ------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/scrapling-python" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_CALLS"
cat "$STUB_JSON"
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/scrapling-python"
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
echo "ffmpeg $*" >> "$STUB_CALLS"
for last in "$@"; do :; done
[ "$last" = "-" ] || echo "fake media" > "$last"
# FAKE_FFMPEG_FULL: -fs stopped the copy at the cap (a sparse file that size).
if [ -n "${FAKE_FFMPEG_FULL:-}" ]; then
  cap=""; while [ $# -gt 0 ]; do [ "$1" = "-fs" ] && cap="$2"; shift; done
  [ -z "$cap" ] || python3 -c 'import sys; open(sys.argv[1], "r+b").truncate(int(sys.argv[2]))' "$last" "$cap"
fi
STUB
cat > "$tmp/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do case "$1" in -D) shift; dest="$1" ;; esac; shift; done
mkdir -p "$dest"; echo one > "$dest/1.jpg"; echo gdl >> "$STUB_CALLS"
STUB
chmod +x "$tmp/bin/curl" "$tmp/bin/ffmpeg" "$tmp/gallery-dl"
# Sealed PATH: the station's real gallery-dl/curl/ffmpeg/yt-dlp must never be
# reachable (a leaked real one would hit x.com). Only these tools exist.
mkdir -p "$tmp/sys"
for t in python3 bash env cat mkdir rm cp sed grep; do ln -s "$(command -v "$t")" "$tmp/sys/$t"; done
export PATH="$tmp/bin:$tmp/sys" STUB_CALLS="$tmp/calls"
cat > "$tmp/ok.json" <<'EOF'
{"status": "ok", "items": [
 {"kind": "image", "url": "https://pbs.twimg.com/media/AAAA?format=jpg&name=large", "hls": false},
 {"kind": "image", "url": "https://pbs.twimg.com/media/BBBB?format=png&name=large", "hls": false}]}
EOF
echo '{"status": "login_wall", "detail": "/i/flow/login"}' >"$tmp/wall.json"
echo '{"status": "ok", "items": [{"kind": "video", "url": "https://video.twimg.com/amplify_video/9/pl/M.m3u8?tag=1", "hls": true}]}' >"$tmp/hls-ok.json"
echo '{"status": "ok", "items": [{"kind": "image", "url": "https://pbs.twimg.com.evil.example/media/A.jpg", "hls": false}]}' >"$tmp/evil-ok.json"

make_vault() { # $1 dir, $2 status id
  mkdir -p "$1/Clippings"
  cat > "$1/Clippings/clip.md" <<EOF
---
title: "x clip"
source: "https://x.com/someuser/status/$2"
type: tweet
harvest_skill: clip-body
---
# Tweet by @someuser

Some tweet text.

![Image](https://pbs.twimg.com/media/HJLs0KcaIAAdStu?format=jpg&name=large)
EOF
}
run_tool() { python3 "$TOOL" "$@"; }

# --- Test 5: Scrapling primary, no cookie and no gallery-dl needed ----------
echo "Test 5: scrapling primary, cookieless"
: >"$tmp/calls"; export X_SCRAPLING_PYTHON="$tmp/scrapling-python" STUB_JSON="$tmp/ok.json" STUB_RC=0
make_vault "$tmp/v5" 5005
run_tool "$tmp/v5" >"$tmp/v5.out" 2>"$tmp/v5.err"
assert "scrapling run exit 0" 0 "$?"
grep -qF "Clippings/clip.md: 2 slides + 0 transcript [scrapling]" "$tmp/v5.out" && a=ok || a=no
assert "outcome line names the scrapling backend" ok "$a"
grep -q '^media_enrichment_status: ok$' "$tmp/v5/Clippings/clip.md" && a=ok || a=no
assert "clip enriched ok" ok "$a"
grep -q -- '--status-id 5005' "$tmp/calls" && a=ok || a=no
assert "helper called with the status id" ok "$a"
grep -q -- '^curl .*--max-redirs 0 --proto =https' "$tmp/calls" && a=ok || a=no
assert "curl follows no redirect and only https" ok "$a"

# --- Test 6: a streamed video goes through ffmpeg, https-only ---------------
echo "Test 6: HLS item via ffmpeg"
: >"$tmp/calls"; export STUB_JSON="$tmp/hls-ok.json"
make_vault "$tmp/v6" 6006
run_tool "$tmp/v6" >"$tmp/v6.out" 2>"$tmp/v6.err"
grep -qF -- 'ffmpeg -nostdin -hide_banner -loglevel error -protocol_whitelist https,tls,tcp,crypto -i https://video.twimg.com/amplify_video/9/pl/M.m3u8?tag=1 -c copy' "$tmp/calls" && a=ok || a=no
assert "ffmpeg stream-copies the master playlist, https-only" ok "$a"
: >"$tmp/calls"; make_vault "$tmp/v6b" 6016
FAKE_FFMPEG_FULL=1 run_tool "$tmp/v6b" >"$tmp/v6b.out" 2>"$tmp/v6b.err"
assert "an HLS copy stopped at the size cap is refused, never processed" 1 "$(grep -c '^ffmpeg ' "$tmp/calls")"
grep -q '^x_media_pending: true$' "$tmp/v6b/Clippings/clip.md" && a=ok || a=no
assert "the capped clip stays pending" ok "$a"

# --- Test 7: an off-host item URL is refused before any download ------------
echo "Test 7: media host allowlist in the fetcher"
: >"$tmp/calls"; export STUB_JSON="$tmp/evil-ok.json"
make_vault "$tmp/v7" 7007
run_tool "$tmp/v7" >"$tmp/v7.out" 2>"$tmp/v7.err"
grep -q '^curl ' "$tmp/calls" && a=fetched || a=refused
assert "off-host URL never fetched" refused "$a"
grep -q '^x_media_pending: true$' "$tmp/v7/Clippings/clip.md" && a=ok || a=no
assert "clip stays pending (retryable)" ok "$a"

# --- Test 8: Scrapling login wall -> gallery-dl fallback -------------------
echo "Test 8: gallery-dl fallback"
: >"$tmp/calls"; export STUB_JSON="$tmp/wall.json" STUB_RC=4
cp "$tmp/gallery-dl" "$tmp/bin/gallery-dl"; echo DUMMY >"$HOME/.luna/cookies/twitter.txt"
make_vault "$tmp/v8" 8008
run_tool "$tmp/v8" >"$tmp/v8.out" 2>"$tmp/v8.err"
assert "fallback run exit 0" 0 "$?"
grep -qF "1 slides + 0 transcript [gallery-dl]" "$tmp/v8.out" && a=ok || a=no
assert "outcome line names the gallery-dl fallback" ok "$a"
grep -q '^gdl$' "$tmp/calls" && a=ok || a=no
assert "gallery-dl ran after scrapling" ok "$a"

# --- Test 9: unlaunchable scrapling interpreter -> gallery-dl fallback -----
echo "Test 9: scrapling interpreter missing"
make_vault "$tmp/v9" 9009
X_SCRAPLING_PYTHON="$tmp/no-such-python" run_tool "$tmp/v9" >"$tmp/v9.out" 2>"$tmp/v9.err"
assert "missing-interpreter run exit 0" 0 "$?"
grep -qF "[gallery-dl]" "$tmp/v9.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"

# --- Test 10: Scrapling login wall, no fallback -> retryable failure -------
echo "Test 10: no fallback available"
rm -f "$tmp/bin/gallery-dl" "$HOME/.luna/cookies/twitter.txt"
make_vault "$tmp/v10" 1010
run_tool "$tmp/v10" >"$tmp/v10.out" 2>"$tmp/v10.err"
assert "no-fallback run exit 0" 0 "$?"
grep -q '^x_media_pending: true$' "$tmp/v10/Clippings/clip.md" && a=ok || a=no
assert "clip stays pending (retryable)" ok "$a"
grep -q '^media_last_error: login_wall$' "$tmp/v10/Clippings/clip.md" && a=ok || a=no
assert "login_wall recorded" ok "$a"

# --- Test 11: kill switch skips scrapling ----------------------------------
echo "Test 11: HARVEST_SCRAPE_DENY kill switch"
: >"$tmp/calls"; export STUB_JSON="$tmp/ok.json" STUB_RC=0
cp "$tmp/gallery-dl" "$tmp/bin/gallery-dl"; echo DUMMY >"$HOME/.luna/cookies/twitter.txt"
make_vault "$tmp/v11" 1111
HARVEST_SCRAPE_DENY=local-headless run_tool "$tmp/v11" >"$tmp/v11.out" 2>"$tmp/v11.err"
assert "kill-switch run exit 0" 0 "$?"
grep -q -- '--status-id' "$tmp/calls" && a=called || a=skipped
assert "scrapling not called under the kill switch" skipped "$a"
grep -qF "[gallery-dl]" "$tmp/v11.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"

# --- Test 12: .harvest-backends skip=local-headless skips scrapling --------
echo "Test 12: .harvest-backends route"
: >"$tmp/calls"
make_vault "$tmp/v12" 1212
echo "x.com skip=local-headless" >"$tmp/v12/.harvest-backends"
run_tool "$tmp/v12" >"$tmp/v12.out" 2>"$tmp/v12.err"
assert "route-skip run exit 0" 0 "$?"
grep -q -- '--status-id' "$tmp/calls" && a=called || a=skipped
assert "scrapling not called when the route skips it" skipped "$a"
grep -qF "[gallery-dl]" "$tmp/v12.out" && a=ok || a=no
assert "gallery-dl served it" ok "$a"

# --- Test 13: preflight: neither backend usable -> exit 2 ------------------
echo "Test 13: preflight"
rm -f "$tmp/bin/gallery-dl" "$HOME/.luna/cookies/twitter.txt"
make_vault "$tmp/v13" 1313
unset X_SCRAPLING_PYTHON
run_tool "$tmp/v13" >"$tmp/v13.out" 2>"$tmp/v13.err"
assert "no scrapling venv, no gallery-dl -> exit 2" 2 "$?"
grep -q "scrapling-venv" "$tmp/v13.err" && a=ok || a=no
assert "preflight names the scrapling venv install" ok "$a"

# --- Test 14: cookie switch off (HIMMEL-4708 default) -----------------------
# gallery-dl and the cookie file are both present; with the switch off a
# Scrapling miss must never reach them - the clip is deferred, naming scrapling.
echo "Test 14: cookie switch off"
unset HIMMEL_MEDIA_COOKIES
: >"$tmp/calls"; export X_SCRAPLING_PYTHON="$tmp/scrapling-python" STUB_JSON="$tmp/wall.json" STUB_RC=4
cp "$tmp/gallery-dl" "$tmp/bin/gallery-dl"; echo DUMMY >"$HOME/.luna/cookies/twitter.txt"
make_vault "$tmp/v14" 1414
run_tool "$tmp/v14" >"$tmp/v14.out" 2>"$tmp/v14.err"
assert "switch-off run exit 0" 0 "$?"
grep -q -- '--status-id' "$tmp/calls" && a=ok || a=no
assert "scrapling still tried first" ok "$a"
grep -q '^gdl$' "$tmp/calls" && a=called || a=skipped
assert "gallery-dl (cookie) never called with the switch off" skipped "$a"
grep -q '^media_enrichment_status: deferred$' "$tmp/v14/Clippings/clip.md" && a=ok || a=no
assert "clip recorded deferred" ok "$a"
grep -q '^media_last_error: scrapling:login_wall$' "$tmp/v14/Clippings/clip.md" && a=ok || a=no
assert "error names the scrapling backend" ok "$a"
grep -q '^x_media_pending: true$' "$tmp/v14/Clippings/clip.md" && a=ok || a=no
assert "deferred clip stays pending" ok "$a"
# Scrapling unavailable and cookies off: preflight refuses, never touches gallery-dl.
: >"$tmp/calls"
make_vault "$tmp/v14b" 1415
HARVEST_SCRAPE_DENY=all run_tool "$tmp/v14b" >"$tmp/v14b.out" 2>"$tmp/v14b.err"
assert "no scrapling + switch off -> exit 2" 2 "$?"
grep -q '^gdl$' "$tmp/calls" && a=called || a=skipped
assert "gallery-dl not called on the preflight stop" skipped "$a"
grep -q "HIMMEL_MEDIA_COOKIES=on" "$tmp/v14b.err" && a=ok || a=no
assert "preflight names the switch" ok "$a"

echo ""
echo "x-scrapling tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
