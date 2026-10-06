#!/usr/bin/env bash
# HIMMEL-4480 PR4: regenerate scripts/config-ui/docs/agui-live-run.gif.
# Records the AG-UI page streaming a fixture journal that is appended to while the page is open (a live
# stream over the real SSE path), then converts the video with the station ffmpeg.
# Needs: bun, ffmpeg, Playwright's Chromium (build 1243), agui-web/dist built. Run it from your own terminal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:-$here/../../docs/agui-live-run.gif}"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

[ -f "$here/../../agui-web/dist/index.html" ] || { echo "agui-web/dist missing: cd scripts/config-ui/agui-web && bun install && bun run build" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }

cd "$here"
[ -d node_modules ] || bun install
AGUI_WEBM="$tmp/run.webm" AGUI_VIDEO_DIR="$tmp/video" bunx playwright test -c playwright.record.config.ts

mkdir -p "$(dirname "$out")"
filters="fps=10,scale='min(960,iw)':-1:flags=lanczos"
ffmpeg -loglevel error -y -i "$tmp/run.webm" -vf "$filters,palettegen=max_colors=64:stats_mode=diff" "$tmp/palette.png"
ffmpeg -loglevel error -y -i "$tmp/run.webm" -i "$tmp/palette.png" -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=4" "$out"
echo "wrote $out ($(wc -c <"$out") bytes)"
