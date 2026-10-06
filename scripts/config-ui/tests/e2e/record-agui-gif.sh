#!/usr/bin/env bash
# HIMMEL-4480 PR4: regenerate scripts/config-ui/docs/agui-live-run.gif.
# Records the AG-UI page streaming a fixture journal that is appended to while the page is open (a live
# stream over the real SSE path), then encodes the frames with the station ffmpeg.
# HIMMEL-4669: the recorder writes lossless screenshot frames (8 fps, from the first event on) instead of a
# video: unchanged pixels stay unchanged, so the GIF stays small. One palette for the whole run, no dither.
# Needs: bun, ffmpeg, Playwright's Chromium (build 1243), agui-web/dist built. Run it from your own terminal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  "") out="$here/../../docs/agui-live-run.gif" ;;
  /*) out="$1" ;;
  *) out="$PWD/$1" ;;  # resolved before the cd below, so a relative path means the caller's cwd
esac
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agui-gif.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT

[ -f "$here/../../agui-web/dist/index.html" ] || { echo "agui-web/dist missing: cd scripts/config-ui/agui-web && bun install && bun run build" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }

cd "$here"
[ -d node_modules ] || bun install
AGUI_FRAMES="$tmp/frames" bunx playwright test -c playwright.record.config.ts record-agui

mkdir -p "$(dirname "$out")"
frames=(-framerate 8 -i "$tmp/frames/%05d.png")  # 8 = 1000 / FRAME_MS in record-agui.rec.ts
ffmpeg -loglevel error -y "${frames[@]}" -vf "palettegen=max_colors=64:stats_mode=full" "$tmp/palette.png"
ffmpeg -loglevel error -y "${frames[@]}" -i "$tmp/palette.png" -lavfi "[0:v][1:v] paletteuse=dither=none:diff_mode=rectangle" "$out"
echo "wrote $out ($(wc -c <"$out") bytes)"
