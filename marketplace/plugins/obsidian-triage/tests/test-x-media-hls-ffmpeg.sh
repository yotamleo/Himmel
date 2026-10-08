#!/usr/bin/env bash
# Real-ffmpeg check of the x-media-fetch.py HLS path (HIMMEL-4802). The other
# suites stub ffmpeg, so none of them shows that a playlist rewritten by
# _resolve_hls actually stream-copies under `-protocol_whitelist file`. Here a
# real ffmpeg builds TS and fMP4 HLS sets locally, a stub curl serves them as
# video.twimg.com URLs (no network), and the tool's own _fetch_item runs the
# real ffmpeg over the rewritten playlists. A playlist naming a non-file URI
# must be refused by that same ffmpeg command line.
# No ffmpeg: SKIP (exit 0) locally; FAIL when HIMMEL_REQUIRE_FFMPEG=1, which
# the CI shell-unit job sets after installing its pinned ffmpeg.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "$SCRIPT_DIR/../tools" && pwd)/x-media-fetch.py"

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  if [ "${HIMMEL_REQUIRE_FFMPEG:-}" = "1" ]; then
    echo "  FAIL  ffmpeg/ffprobe required (HIMMEL_REQUIRE_FFMPEG=1) but not on PATH"
    exit 1
  fi
  echo "SKIP: ffmpeg/ffprobe not on PATH (set HIMMEL_REQUIRE_FFMPEG=1 to require)"
  exit 0
fi
echo "ffmpeg: $(ffmpeg -version | head -n 1)"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/x-hls-ffmpeg.XXXXXX")" || exit 1
[ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$tmp"' EXIT

# --- local HLS sets, built by the real ffmpeg (libx264 + aac, as X serves) --------
# Served at https://video.twimg.com/<path> -> $tmp/www/<path>.
www="$tmp/www"; ts="$www/ts"; fm="$www/fm"
mkdir -p "$ts" "$fm/vid" "$fm/aud"
gen() { ffmpeg -nostdin -hide_banner -loglevel error -y "$@"; }
src=(-f lavfi -i "testsrc=size=160x120:rate=10:duration=4" -f lavfi -i "sine=frequency=440:duration=4")
# TS: one muxed variant under a master.
gen "${src[@]}" -c:v libx264 -g 10 -c:a aac -f hls -hls_time 2 -hls_playlist_type vod \
  -hls_segment_filename "$ts/s%d.ts" "$ts/V.m3u8" || { echo "  FAIL  could not build the TS fixture"; exit 1; }
cat >"$ts/M.m3u8" <<'EOF'
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=160x120
V.m3u8
EOF
# fMP4: X's layout - video and audio renditions, each with an init map.
fmp4=(-f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4)
if ! gen "${src[@]}" -map 0:v -c:v libx264 -g 10 "${fmp4[@]}" \
       -hls_segment_filename "$fm/vid/s%d.m4s" "$fm/vid/V.m3u8" \
   || ! gen "${src[@]}" -map 1:a -c:a aac "${fmp4[@]}" \
       -hls_segment_filename "$fm/aud/s%d.m4s" "$fm/aud/A.m3u8"; then
  echo "  FAIL  could not build the fMP4 fixture"; exit 1
fi
cat >"$fm/M.m3u8" <<'EOF'
#EXTM3U
#EXT-X-MEDIA:NAME="Audio",TYPE=AUDIO,GROUP-ID="aud",DEFAULT=YES,AUTOSELECT=YES,URI="aud/A.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=160x120,AUDIO="aud"
vid/V.m3u8
EOF
grep -q '^#EXT-X-MAP:URI="init.mp4"' "$fm/vid/V.m3u8" && a=ok || a=no
assert "control: the fMP4 fixture carries an init map" ok "$a"

# --- stub curl: `-o FILE URL` pairs, URL -> $www file, never the network ----
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; n=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; out="$1" ;;
    https://video.twimg.com/*)
      [ -n "$out" ] || exit 2
      path="${1#https://video.twimg.com/}"; path="${path%%\?*}"
      [ -f "$STUB_WWW/$path" ] || exit 22
      cp "$STUB_WWW/$path" "$out"; n=$((n+1)); out="" ;;
    https://*|http://*) exit 7 ;;
  esac
  shift
done
[ "$n" -gt 0 ] || exit 2
STUB
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" STUB_WWW="$www"

# --- driver: the tool's own _fetch_item / _ffmpeg_hls, real ffmpeg ----------
cat >"$tmp/drive.py" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("xmf", sys.argv[1])
xmf = importlib.util.module_from_spec(spec); spec.loader.exec_module(xmf)
mode, arg, target = sys.argv[2], sys.argv[3], Path(sys.argv[4])
if mode == "fetch":
    print(xmf._fetch_item({"url": arg, "hls": True}, target))
else:
    # A rewritten playlist that still names a non-file URI: _resolve_hls is
    # replaced so the playlist reaches the real ffmpeg command line as is.
    def planted(url, work, deadline):
        (work / "master.m3u8").write_text(Path(arg).read_text(encoding="utf-8"), encoding="utf-8")
        return None
    xmf._resolve_hls = planted
    run = xmf.subprocess.run
    def tee(cmd, **kw):  # the tool logs a 200-char tail; keep all of it
        got = run(cmd, **kw)
        print(got.stderr, file=sys.stderr)
        return got
    xmf.subprocess.run = tee
    work = target.with_name(target.name + ".hls"); work.mkdir()
    print(xmf._ffmpeg_hls("https://video.twimg.com/x/M.m3u8", work, target))
PY
drive() { python3 "$tmp/drive.py" "$TOOL" "$@"; }
streams() { ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$1" | sort | tr '\n' ' '; }

for layout in ts fm; do
  echo "Test: $layout layout stream-copies through the real ffmpeg"
  out="$tmp/$layout.mp4"
  res=$(drive fetch "https://video.twimg.com/$layout/M.m3u8?tag=1" "$out" 2>"$tmp/$layout.err")
  assert "$layout: _fetch_item succeeds" None "$res"
  assert "$layout: output has one audio and one video stream" "audio video " "$(streams "$out" 2>/dev/null)"
  [ -d "$out.hls" ] && a=left || a=clean
  assert "$layout: no HLS workdir left behind" clean "$a"
  [ "$res" = None ] || sed 's/^/         /' "$tmp/$layout.err"
done

echo "Test: a playlist naming a non-file URI is refused by ffmpeg"
# ffmpeg's hls demuxer already confines a local playlist's segments to
# file,crypto,data (and its extension check stops data:), so a crypto: segment
# is the case only the tool's explicit `-protocol_whitelist file` refuses -
# without it ffmpeg opens the crypto protocol and fails later, on the key.
for uri in "crypto:$ts/s0.ts" "http://127.0.0.1:9/s0.ts" "https://video.twimg.com/ts/s0.ts"; do
  name="${uri%%:*}:${uri##*/}"
  printf '#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\n%s\n#EXT-X-ENDLIST\n' "$uri" >"$tmp/bad.m3u8"
  rm -rf "$tmp/bad.mp4" "$tmp/bad.mp4.hls"
  res=$(drive planted "$tmp/bad.m3u8" "$tmp/bad.mp4" 2>"$tmp/bad.err")
  assert "$name: refused" download_error "$res"
  grep -qi 'protocol.*not on whitelist' "$tmp/bad.err" && a=whitelist || a=other
  assert "$name: refused by the file-only protocol whitelist" whitelist "$a"
done

echo ""
echo "x-media-hls-ffmpeg tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
