#!/usr/bin/env bash
# Tests for ig-media-fetch.py (HIMMEL-770). Hermetic: NO live network, NO
# gallery-dl/ffmpeg/whisper. The tool runs under `uv run --python 3.12 python`
# (Windows bare python3 is a flaky Store stub); the harness prepends a "$tmp/bin"
# dir carrying ONE uv stub for the whole suite (Tasks 1-8) - the stub branches on
# *transcribe.py* (fixed whisper transcript, from Task 3) and otherwise strips the
# uv args through the explicit `python` token and exec's the real python.
# Task 1 exercises --dry-run selection + byte-identity only.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
TOOL="$TOOLS_DIR/ig-media-fetch.py"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- ONE uv stub for the whole harness (exec-final-command - Git-Bash
# grandchild-reaping trap). ASCII only. -------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/uv" <<'STUB'
#!/usr/bin/env bash
# ONE uv stub for the whole harness (exec-final-command - Git-Bash
# grandchild-reaping trap). ASCII only.
case "$*" in
  *transcribe.py*)
    exec echo "THIS IS THE FIXED TRANSCRIPT" ;;
  *)
    # strip uv args (run --python 3.12 [--with pkg] ...) through the
    # explicit `python` token, then exec the real python on the rest.
    while [ $# -gt 0 ] && [ "$1" != "python" ]; do shift; done
    [ $# -gt 0 ] || { echo "uv-stub: no python token in: $*" >&2; exit 9; }
    shift
    exec python "$@" ;;
esac
STUB
chmod +x "$tmp/bin/uv"
export PATH="$tmp/bin:$PATH"

run_tool() { # $@ = tool args -> runs under the uv stub
  PYTHONUTF8=1 uv run --python 3.12 python "$TOOL" "$@"
}

# --- fixture vault: four IG clips exercising the selection predicate --------
V="$tmp/vault"
mkdir -p "$V/Clippings"

# (a) IG reel, enrichment_status: failed, no ## Crawled content -> SELECTED
cat > "$V/Clippings/a-reel.md" <<'EOF'
---
title: "a reel"
source: "https://www.instagram.com/reel/AAAA111/"
type: instagram
enrichment_status: failed
---
# a reel

## Source
[link](https://www.instagram.com/reel/AAAA111/)
EOF

# (b) IG post, caption-only ## Crawled content (no ### Transcript/### Slides)
#     -> SELECTED (thin)
cat > "$V/Clippings/b-thin.md" <<'EOF'
---
title: "b thin"
source: "https://www.instagram.com/p/BBBB222/"
type: instagram
---
# b thin

## Crawled content
Just the caption text, no transcript and no slides.

## Source
[link](https://www.instagram.com/p/BBBB222/)
EOF

# (c) IG clip already media-enriched -> SKIPPED
cat > "$V/Clippings/c-done.md" <<'EOF'
---
title: "c done"
source: "https://www.instagram.com/reel/CCCC333/"
type: instagram
media_enriched_at: 2026-01-01
---
# c done

## Crawled content
### Transcript
Already transcribed.

## Source
[link](https://www.instagram.com/reel/CCCC333/)
EOF

# (d) non-IG clip -> SKIPPED
cat > "$V/Clippings/d-other.md" <<'EOF'
---
title: "d other"
source: "https://x.com/u/status/1"
type: twitter
enrichment_status: failed
---
# d other

## Source
[link](https://x.com/u/status/1)
EOF

# --- Test 1: --dry-run plan lists EXACTLY (a) and (b) -----------------------
echo "Test 1: dry-run selection"
declare -A before
for f in a-reel b-thin c-done d-other; do
  before[$f]="$(sha256sum "$V/Clippings/$f.md" | cut -d' ' -f1)"
done

run_tool "$V" --dry-run >"$tmp/plan.out" 2>"$tmp/plan.err"
rc=$?
assert "--dry-run exit 0" 0 "$rc"

nplan="$(grep -c '^PLAN ' "$tmp/plan.out")"
assert "exactly 2 clips planned" 2 "$nplan"
grep -q '^PLAN Clippings/a-reel.md -- would fetch reel/AAAA111 \[dry-run\]$' "$tmp/plan.out" && a=ok || a=no
assert "(a) reel planned" ok "$a"
grep -q '^PLAN Clippings/b-thin.md -- would fetch p/BBBB222 \[dry-run\]$' "$tmp/plan.out" && a=ok || a=no
assert "(b) thin post planned" ok "$a"
grep -q 'c-done.md' "$tmp/plan.out" && a=present || a=absent; assert "(c) already-enriched NOT planned" absent "$a"
grep -q 'd-other.md' "$tmp/plan.out" && a=present || a=absent; assert "(d) non-IG NOT planned" absent "$a"
grep -q '2 selected, 0 enriched' "$tmp/plan.out" && a=ok || a=no; assert "summary reports 2 selected" ok "$a"

# --- Test 2: --dry-run leaves every clip byte-identical ---------------------
echo "Test 2: dry-run byte-identity"
for f in a-reel b-thin c-done d-other; do
  after="$(sha256sum "$V/Clippings/$f.md" | cut -d' ' -f1)"
  assert "$f.md byte-identical after dry-run" "${before[$f]}" "$after"
done

# --- Setup: HOME, stubs, and test fixtures for Tests 3+ ----------------------
HOME="$tmp/home"
mkdir -p "$HOME/.luna/cookies"
export HOME

# Add gallery-dl stub with .bat wrapper for Windows
# Create .bat wrapper (for Windows) and bash wrapper (for MSYS)
cat > "$tmp/bin/gallery-dl.bat" <<'STUB'
@echo off
REM Extract -D and its argument
setlocal enabledelayedexpansion
set dest=
for %%i in (%*) do (
    if "!prev_flag!"=="-D" (
        set dest=%%i
        setlocal disabledalayedexpansion
    )
    set prev_flag=%%i
)
if "!dest!"=="" (
    echo gallery-dl-stub: no -D specified >&2
    exit /b 1
)
if not exist "!dest!" mkdir "!dest!"
(echo fake jpeg 1) > "!dest!\image-1.jpg"
(echo fake jpeg 2) > "!dest!\image-2.jpg"
exit /b 0
STUB

cat > "$tmp/bin/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) shift; dest="$1" ;;
    *) ;;
  esac
  shift
done
[ -n "$dest" ] || { echo "gallery-dl-stub: no -D specified" >&2; exit 1; }
mkdir -p "$dest"
echo "fake jpeg 1" > "$dest/image-1.jpg"
echo "fake jpeg 2" > "$dest/image-2.jpg"
exit 0
STUB
chmod +x "$tmp/bin/gallery-dl"

# Add ffmpeg stub with .bat wrapper for Windows. The stub CREATES its output
# (the last arg) so recompress_slide (returncode 0 AND dst.is_file()) succeeds;
# extract_wav (Task 3) likewise wants the WAV to exist. The .bat walks args via
# `shift` (NOT `for %%i in (%*)`) because the recompress -vf filter carries
# unquoted parens - min(1600,iw) - that break for-parenthesization. ASCII only.
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
:findlast
if not "%~2"=="" ( shift & goto findlast )
type nul > "%~1"
exit /b 0
STUB

cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
for last in "$@"; do :; done
: > "$last"
exit 0
STUB
chmod +x "$tmp/bin/ffmpeg"

# make_ig_vault DIR SHORTCODE: fresh single-clip vault so each run is isolated
# (a permanent media_enriched_at marker in one must not de-select the next).
make_ig_vault() {
  local dir="$1" sc="$2"
  mkdir -p "$dir/Clippings"
  cat > "$dir/Clippings/clip.md" <<EOF
---
title: "err clip"
source: "https://www.instagram.com/reel/$sc/"
type: instagram
enrichment_status: failed
---
# err clip

## Source
[link](https://www.instagram.com/reel/$sc/)
EOF
}

# --- Test 3: missing cookie file -> exit 2 with instagram.txt + Cookie-Editor
echo "Test 3: missing cookie file"
run_tool "$V" >"$tmp/no-cookie.out" 2>"$tmp/no-cookie.err"
rc=$?
assert "missing cookie exit 2" 2 "$rc"
grep -q "instagram.txt" "$tmp/no-cookie.err" && a=ok || a=no
assert "stderr mentions instagram.txt" ok "$a"
grep -q "Cookie-Editor" "$tmp/no-cookie.err" && a=ok || a=no
assert "stderr mentions Cookie-Editor" ok "$a"

# --- Test 4: preflight with stubs -> download + recompress slides + outcome line
echo "Test 4: download + slide write + outcome line"

# Create cookie file (contents never printed)
echo "DUMMY_COOKIES" > "$HOME/.luna/cookies/instagram.txt"
chmod 600 "$HOME/.luna/cookies/instagram.txt"

# Set IG_MEDIA_NO_SLEEP to skip rate limit in test
export IG_MEDIA_NO_SLEEP=1

# Fresh isolated vault (the gallery-dl stub emits image-1.jpg + image-2.jpg).
VD="$tmp/vault-dl"
make_ig_vault "$VD" DDDD444
run_tool "$VD" >"$tmp/download.out" 2>"$tmp/download.err"
rc=$?
assert "download run exit 0" 0 "$rc"

# Real per-clip outcome line: 2 image slides, no video transcript.
grep -qF "Clippings/clip.md: 2 slides + 0 transcript" "$tmp/download.out" && a=ok || a=no
assert "clip outcome line present (2 slides + 0 transcript)" ok "$a"
grep -qF "![[Clippings/_media/clip/slide-01.jpg]]" "$VD/Clippings/clip.md" && a=ok || a=no
assert "slide-01 embed written into clip" ok "$a"
[ -f "$VD/Clippings/_media/clip/slide-02.jpg" ] && a=ok || a=no
assert "slide-02.jpg copied into vault _media/" ok "$a"

# --- Test 5: stale-cache case (pre-seed old.mp4, download must clear it first)
echo "Test 5: stale-cache cleanup"
VS="$tmp/vault-stale"
make_ig_vault "$VS" SSSS555
mkdir -p "$HOME/.luna/ig-media/SSSS555"
echo "old video data" > "$HOME/.luna/ig-media/SSSS555/old.mp4"

run_tool "$VS" >"$tmp/stale.out" 2>"$tmp/stale.err"
rc=$?
assert "stale-cache run exit 0" 0 "$rc"

# Cache dir should be cleared before download, so old.mp4 is gone
[ ! -f "$HOME/.luna/ig-media/SSSS555/old.mp4" ] && a=ok || a=no
assert "old.mp4 removed before download" ok "$a"

# Only the new JPEGs are present -> 2 slides written.
grep -qF "Clippings/clip.md: 2 slides + 0 transcript" "$tmp/stale.out" && a=ok || a=no
assert "stale-cache outcome line correct" ok "$a"

# --- Test 6: missing ffmpeg -> exit 2 with winget
echo "Test 6: missing ffmpeg"
rm "$tmp/bin/ffmpeg" "$tmp/bin/ffmpeg.bat"
# Save original PATH and filter out ffmpeg paths
original_path="$PATH"
# Remove any paths containing "FFmpeg" or "ffmpeg"
filtered_path=$(echo "$original_path" | tr ':' '\n' | grep -v -i ffmpeg | tr '\n' ':' | sed 's/:$//')
export PATH="$tmp/bin:$filtered_path"
run_tool "$V" >"$tmp/no-ffmpeg.out" 2>"$tmp/no-ffmpeg.err"
rc=$?
# Restore original PATH for remaining tests
export PATH="$original_path"
assert "missing ffmpeg exit 2" 2 "$rc"
grep -q "winget" "$tmp/no-ffmpeg.err" && a=ok || a=no
assert "stderr mentions winget" ok "$a"

# --- download-error taxonomy: recreate ffmpeg (Test 6 removed it), then feed
#     failing gallery-dl stubs and assert the media_* marker taxonomy ----------
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
exit /b 0
STUB
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$tmp/bin/ffmpeg"

# fail_gallery_dl MESSAGE: overwrite the gallery-dl stub so it exits 1, printing
# MESSAGE on stderr and creating NO media (both bash + .bat forms).
fail_gallery_dl() {
  local msg="$1"
  cat > "$tmp/bin/gallery-dl.bat" <<STUB
@echo off
echo $msg 1>&2
exit /b 1
STUB
  cat > "$tmp/bin/gallery-dl" <<STUB
#!/usr/bin/env bash
echo "$msg" >&2
exit 1
STUB
  chmod +x "$tmp/bin/gallery-dl"
}

# --- Test 7: download 404 -> media_last_error: removed + permanent enriched_at,
#     and the permanent failure RELEASES ig_media_pending (the media is gone;
#     the clip parks as caption-only evidence, never stranding in the inbox).
echo "Test 7: download error taxonomy (removed / permanent)"
VE="$tmp/vault-removed"
mkdir -p "$VE/Clippings"
cat > "$VE/Clippings/clip.md" <<'EOF'
---
title: "err clip"
source: "https://www.instagram.com/reel/ERRR777/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# err clip

## Source
[link](https://www.instagram.com/reel/ERRR777/)
EOF
fail_gallery_dl "HTTP Error 404: Not Found"
run_tool "$VE" >"$tmp/removed.out" 2>"$tmp/removed.err"
rc=$?
assert "removed run exit 0" 0 "$rc"
grep -q '^media_enrichment_status: failed$' "$VE/Clippings/clip.md" && a=ok || a=no
assert "removed status failed" ok "$a"
grep -q '^media_last_error: removed$' "$VE/Clippings/clip.md" && a=ok || a=no
assert "removed last_error removed" ok "$a"
grep -q '^media_enriched_at:' "$VE/Clippings/clip.md" && a=present || a=absent
assert "removed enriched_at set (permanent)" present "$a"
grep -q '^ig_media_pending:' "$VE/Clippings/clip.md" && a=present || a=absent
assert "ig_media_pending released on permanent failure" absent "$a"

# --- Test 8: download login wall -> retryable class, NO permanent enriched_at
echo "Test 8: download error taxonomy (login wall / retryable)"
VL="$tmp/vault-login"
make_ig_vault "$VL" LOGN888
fail_gallery_dl "login required"
run_tool "$VL" >"$tmp/login.out" 2>"$tmp/login.err"
rc=$?
assert "login run exit 0" 0 "$rc"
grep -q '^media_enrichment_status: failed$' "$VL/Clippings/clip.md" && a=ok || a=no
assert "login status failed" ok "$a"
grep -q '^media_last_error: login_wall$' "$VL/Clippings/clip.md" && a=ok || a=no
assert "login last_error login_wall (retryable)" ok "$a"
grep -q '^media_enriched_at:' "$VL/Clippings/clip.md" && a=present || a=absent
assert "login enriched_at NOT set (retryable)" absent "$a"

# --- Test 9: reel transcript path (ffmpeg WAV -> faster-whisper via uv) -------
# gallery-dl emits ONE video.mp4; ffmpeg (touch) creates the mono-16k WAV in a
# TEMP dir; the shared uv stub serves the whisper call (its *transcribe.py*
# branch echoes the fixed transcript). Windows: win32 python's subprocess /
# shutil.which cannot resolve the extensionless bash uv stub, so a uv.bat
# PATHEXT twin (mirroring the gallery-dl.bat / ffmpeg.bat twins) emits the same
# fixed transcript. The written clip must gain a ### Transcript block AND leave
# zero .mp4/.wav/.webm anywhere under the vault (video stays in the cache under
# HOME/.luna/ig-media/, WAV in a TemporaryDirectory).
echo "Test 9: reel transcript path"
VR="$tmp/vault-reel"
make_ig_vault "$VR" REEL999

# gallery-dl now emits a single reel video (both bash + .bat forms)
cat > "$tmp/bin/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) shift; dest="$1" ;;
    *) ;;
  esac
  shift
done
[ -n "$dest" ] || { echo "gallery-dl-stub: no -D specified" >&2; exit 1; }
mkdir -p "$dest"
echo "fake video data" > "$dest/video.mp4"
exit 0
STUB
chmod +x "$tmp/bin/gallery-dl"
cat > "$tmp/bin/gallery-dl.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set dest=
for %%i in (%*) do (
    if "!prev_flag!"=="-D" set dest=%%i
    set prev_flag=%%i
)
if "!dest!"=="" ( echo gallery-dl-stub: no -D specified 1>&2 & exit /b 1 )
if not exist "!dest!" mkdir "!dest!"
(echo fake video data) > "!dest!\video.mp4"
exit /b 0
STUB

# ffmpeg creates the requested WAV (the last arg) - stands in for the transcode
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
for last in "$@"; do :; done
: > "$last"
exit 0
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set last=
for %%i in (%*) do set last=%%i
type nul > "!last!"
exit /b 0
STUB

# Windows PATHEXT twin of the shared bash uv stub. Mirrors the bash stub's
# *transcribe.py* branch (fixed whisper transcript) so the Windows path
# validates the transcribe arg contract; every other uv call strips its args
# through the explicit `python` token and runs the real python. ASCII only.
cat > "$tmp/bin/uv.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
echo %*| findstr /C:"transcribe.py" >nul
if not errorlevel 1 (
  echo THIS IS THE FIXED TRANSCRIPT
  exit /b 0
)
set "found="
:shift_loop
if "%~1"=="" goto no_python
if /I "%~1"=="python" ( set "found=1" & shift & goto build_args )
shift
goto shift_loop
:build_args
set "args="
:build_loop
if "%~1"=="" goto exec_py
set "args=!args! %1"
shift
goto build_loop
:exec_py
python!args!
exit /b !errorlevel!
:no_python
echo uv-stub: no python token in args 1>&2
exit /b 9
STUB

run_tool "$VR" >"$tmp/reel.out" 2>"$tmp/reel.err"
rc=$?
assert "reel run exit 0" 0 "$rc"

grep -q '^### Transcript$' "$VR/Clippings/clip.md" && a=ok || a=no
assert "reel clip gains ### Transcript block" ok "$a"
grep -qF "THIS IS THE FIXED TRANSCRIPT" "$VR/Clippings/clip.md" && a=ok || a=no
assert "reel transcript text written into clip" ok "$a"

found="$(find "$VR" \( -name '*.mp4' -o -name '*.wav' -o -name '*.webm' \) 2>/dev/null)"
[ -z "$found" ] && a=ok || a=no
assert "no .mp4/.wav/.webm under the vault" ok "$a"

# --- carousel/slides fixtures: gallery-dl emits JPEGs; ffmpeg exec's cp (bash)
# / creates the dst (bat) - recompress_slide needs the dst to exist. ----------
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
# recompress/extract stub: copy the -i source to the last arg (dst).
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
# .bat walks args via `shift` (the recompress -vf carries unquoted parens that
# break `for %%i in (%*)`); it creates the dst so recompress_slide succeeds.
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
:findlast
if not "%~2"=="" ( shift & goto findlast )
type nul > "%~1"
exit /b 0
STUB

# The single-quoted echo lines emit literal $-refs into the generated stub;
# they must NOT expand here (that is the whole point of the generator).
# shellcheck disable=SC2016
emit_gallery_dl() { # $@ = filenames the stub should drop into -D dest
  {
    echo '#!/usr/bin/env bash'
    echo 'dest=""'
    echo 'while [ $# -gt 0 ]; do case "$1" in -D) shift; dest="$1" ;; esac; shift; done'
    echo '[ -n "$dest" ] || { echo "gallery-dl-stub: no -D specified" >&2; exit 1; }'
    echo 'mkdir -p "$dest"'
    for f in "$@"; do echo "echo data > \"\$dest/$f\""; done
    echo 'exit 0'
  } > "$tmp/bin/gallery-dl"
  chmod +x "$tmp/bin/gallery-dl"
  {
    echo '@echo off'
    echo 'setlocal enabledelayedexpansion'
    echo 'set dest='
    echo 'for %%i in (%*) do ('
    echo '    if "!prev_flag!"=="-D" set dest=%%i'
    echo '    set prev_flag=%%i'
    echo ')'
    echo 'if "!dest!"=="" ( echo gallery-dl-stub: no -D specified 1>&2 & exit /b 1 )'
    echo 'if not exist "!dest!" mkdir "!dest!"'
    for f in "$@"; do echo "(echo data) > \"!dest!\\$f\""; done
    echo 'exit /b 0'
  } > "$tmp/bin/gallery-dl.bat"
}

# --- Test 10 (a): carousel -> 3 vault slides + pending-digest marker ---------
echo "Test 10: carousel -> vault _media slides"
emit_gallery_dl 1.jpg 2.jpg 3.jpg
VC="$tmp/vault-carousel"
make_ig_vault "$VC" CARO010
run_tool "$VC" >"$tmp/caro.out" 2>"$tmp/caro.err"
assert "carousel run exit 0" 0 "$?"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VC/Clippings/clip.md")"
assert "3 slide embeds under ### Slides" 3 "$n"
grep -q '^### Slides$' "$VC/Clippings/clip.md" && a=ok || a=no
assert "### Slides heading present" ok "$a"
for k in 01 02 03; do
  [ -f "$VC/Clippings/_media/clip/slide-$k.jpg" ] && a=ok || a=no
  assert "slide-$k.jpg copied into vault _media/" ok "$a"
done
grep -qF '<!-- slides-pending-digest -->' "$VC/Clippings/clip.md" && a=ok || a=no
assert "slides-pending-digest marker present" ok "$a"

# --- Test 11 (b): slide cap 25 -> exactly 20 embeds + 20 files ---------------
echo "Test 11: slide cap (25 -> 20)"
# Word-splitting is intentional: each padded name is its own emit_gallery_dl arg.
# shellcheck disable=SC2046
emit_gallery_dl $(seq -w 1 25 | sed 's/^/img-/;s/$/.jpg/')
VP="$tmp/vault-cap"
make_ig_vault "$VP" CAPP011
run_tool "$VP" >"$tmp/cap.out" 2>"$tmp/cap.err"
assert "cap run exit 0" 0 "$?"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VP/Clippings/clip.md")"
assert "exactly 20 slide embeds (cap)" 20 "$n"
nf="$(find "$VP/Clippings/_media/clip" -name 'slide-*.jpg' | wc -l | tr -d ' ')"
assert "exactly 20 slide files (cap)" 20 "$nf"

# --- Test 12 (c): mixed carousel -> 2 image slides + slide-indexed transcript
echo "Test 12: mixed carousel (image + video + image)"
emit_gallery_dl 1.jpg 2.mp4 3.jpg
VM="$tmp/vault-mixed"
make_ig_vault "$VM" MIXD012
run_tool "$VM" >"$tmp/mixed.out" 2>"$tmp/mixed.err"
assert "mixed run exit 0" 0 "$?"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VM/Clippings/clip.md")"
assert "mixed: exactly 2 image embeds" 2 "$n"
grep -qF '**Slide 2 (video):**' "$VM/Clippings/clip.md" && a=ok || a=no
assert "mixed: video item labeled by slide index (Slide 2)" ok "$a"
grep -q '^### Transcript$' "$VM/Clippings/clip.md" && a=ok || a=no
assert "mixed: ### Transcript present" ok "$a"
grep -qF "THIS IS THE FIXED TRANSCRIPT" "$VM/Clippings/clip.md" && a=ok || a=no
assert "mixed: video transcript text written" ok "$a"
vid="$(find "$VM" -name '*.mp4' -o -name '*.wav' -o -name '*.webm' 2>/dev/null)"
[ -z "$vid" ] && a=ok || a=no
assert "mixed: NO video/wav under the vault" ok "$a"
grep -qF "2 slides + 1 transcript" "$tmp/mixed.out" && a=ok || a=no
assert "mixed: outcome line notes 2 slides + 1 transcript" ok "$a"

# --- Test 13 (d): marker-namespace independence + re-run idempotency ---------
echo "Test 13: marker-namespace independence + idempotency"
emit_gallery_dl 1.jpg 2.jpg
VN="$tmp/vault-ns"
mkdir -p "$VN/Clippings"
cat > "$VN/Clippings/clip.md" <<'EOF'
---
title: "d ns"
source: "https://www.instagram.com/p/NAMS013/"
type: instagram
enriched_at: 2026-01-02
enrichment_status: ok
---
# d ns

## Crawled content
<!-- enriched 2026-01-02 via ig-embed (no-login) -->

**@author**

Existing caption text.

## Source
[link](https://www.instagram.com/p/NAMS013/)
EOF
run_tool "$VN" >"$tmp/ns.out" 2>"$tmp/ns.err"
assert "namespace run exit 0" 0 "$?"
grep -q '^enriched_at: 2026-01-02$' "$VN/Clippings/clip.md" && a=ok || a=no
assert "ig-embed enriched_at kept untouched" ok "$a"
grep -q '^enrichment_status: ok$' "$VN/Clippings/clip.md" && a=ok || a=no
assert "ig-embed enrichment_status kept untouched" ok "$a"
grep -q '^media_enrichment_status: ok$' "$VN/Clippings/clip.md" && a=ok || a=no
assert "media_enrichment_status: ok added" ok "$a"
grep -q '^media_enriched_at:' "$VN/Clippings/clip.md" && a=ok || a=no
assert "media_enriched_at added" ok "$a"
grep -qF "Existing caption text." "$VN/Clippings/clip.md" && a=ok || a=no
assert "existing ig-embed caption preserved (not duplicated)" ok "$a"
grep -q '^### Slides$' "$VN/Clippings/clip.md" && a=ok || a=no
assert "### Slides spliced into existing ## Crawled content" ok "$a"

sha1="$(sha256sum "$VN/Clippings/clip.md" | cut -d' ' -f1)"
run_tool "$VN" >"$tmp/ns2.out" 2>"$tmp/ns2.err"
assert "second run exit 0" 0 "$?"
sha2="$(sha256sum "$VN/Clippings/clip.md" | cut -d' ' -f1)"
assert "clip byte-identical after re-run" "$sha1" "$sha2"
grep -q '0 selected, 0 enriched' "$tmp/ns2.out" && a=ok || a=no
assert "re-run selects nothing (idempotent)" ok "$a"
nslides="$(grep -c '^### Slides$' "$VN/Clippings/clip.md")"
assert "exactly ONE ### Slides block (no dup on re-run)" 1 "$nslides"

# --- Test 14 (a): --apply-digest inserts ONE ### Slide digest H3, strips the
#     pending marker, and leaves frontmatter + everything else byte-identical --
echo "Test 14: apply-digest happy path"
AD="$tmp/vault-apply"
mkdir -p "$AD/Clippings"
cat > "$AD/Clippings/clip.md" <<'EOF'
---
title: "apply happy"
source: "https://www.instagram.com/p/APLY100/"
type: instagram
media_enriched_at: 2026-07-08
---
# apply happy

## Crawled content
<!-- media-enriched 2026-07-08 via ig-media -->

### Slides
![[Clippings/_media/clip/slide-01.jpg]]
![[Clippings/_media/clip/slide-02.jpg]]
<!-- slides-pending-digest -->

## Source
[link](https://www.instagram.com/p/APLY100/)
EOF

# Frontmatter baseline (must be byte-identical post-apply): the block delimited
# by the first two --- fences. This IS the fm_raw immutability invariant.
fm_before="$(sed -n '/^---$/,/^---$/p' "$AD/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
src_before="$(grep -c '^## Source$' "$AD/Clippings/clip.md")"

cat > "$tmp/digest-a.txt" <<'EOF'
Slide 1: a chart showing revenue growth.
Slide 2: bullet points on the three takeaways.
EOF

run_tool --apply-digest "$AD/Clippings/clip.md" --digest-file "$tmp/digest-a.txt" >"$tmp/apply.out" 2>"$tmp/apply.err"
rc=$?
assert "apply-digest exit 0" 0 "$rc"
n="$(grep -c '^### Slide digest$' "$AD/Clippings/clip.md")"
assert "exactly one ### Slide digest H3 added" 1 "$n"
grep -qF '<!-- slides-pending-digest -->' "$AD/Clippings/clip.md" && a=present || a=absent
assert "pending marker stripped" absent "$a"
grep -qF "Slide 1: a chart showing revenue growth." "$AD/Clippings/clip.md" && a=ok || a=no
assert "digest text written into clip" ok "$a"
fm_after="$(sed -n '/^---$/,/^---$/p' "$AD/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
assert "frontmatter byte-identical after apply" "$fm_before" "$fm_after"
src_after="$(grep -c '^## Source$' "$AD/Clippings/clip.md")"
assert "## Source section preserved" "$src_before" "$src_after"
grep -qF "OK apply-digest clip.md" "$tmp/apply.out" && a=ok || a=no
assert "OK apply-digest summary line printed" ok "$a"

# --- Test 15 (b): usage failures -> exit 1, clip byte-identical (no write) ----
echo "Test 15: apply-digest usage failures (absent marker / missing digest-file)"
AN="$tmp/vault-apply-nomark"
mkdir -p "$AN/Clippings"
cat > "$AN/Clippings/clip.md" <<'EOF'
---
title: "no marker"
source: "https://www.instagram.com/p/NOMK200/"
type: instagram
---
# no marker

## Crawled content
### Slides
![[Clippings/_media/clip/slide-01.jpg]]

## Source
[link](https://www.instagram.com/p/NOMK200/)
EOF
echo "Some digest text." > "$tmp/digest-b.txt"
sha_before="$(sha256sum "$AN/Clippings/clip.md" | cut -d' ' -f1)"
run_tool --apply-digest "$AN/Clippings/clip.md" --digest-file "$tmp/digest-b.txt" >"$tmp/apply-b.out" 2>"$tmp/apply-b.err"
rc=$?
assert "absent-marker exit 1" 1 "$rc"
sha_after="$(sha256sum "$AN/Clippings/clip.md" | cut -d' ' -f1)"
assert "absent-marker clip byte-identical (no write)" "$sha_before" "$sha_after"
grep -q 'expected exactly one pending marker' "$tmp/apply-b.err" && a=ok || a=no
assert "absent-marker error message on stderr" ok "$a"
# Missing --digest-file is also a usage error (exit 1, no write).
run_tool --apply-digest "$AN/Clippings/clip.md" >"$tmp/apply-b2.out" 2>"$tmp/apply-b2.err"
rc=$?
assert "missing --digest-file exit 1" 1 "$rc"
sha_after2="$(sha256sum "$AN/Clippings/clip.md" | cut -d' ' -f1)"
assert "missing --digest-file clip byte-identical" "$sha_before" "$sha_after2"

# --- Test 16 (c): scoped-G-3 reconstruction guard -> non-zero exit, no write --
# The clip already carries a ### Slide digest block whose text equals the digest
# file's, sitting BEFORE the pending marker. The mechanical marker -> H3 transform
# can no longer be uniquely reconstructed back to the baseline body, so the tool
# refuses BEFORE writing (scoped-G-3), leaving the clip byte-identical. This is
# the deterministically-triggerable G-3 refusal; the post-write revert path is
# belt-and-suspenders a hermetic test cannot corrupt without patching python.
echo "Test 16: apply-digest scoped-G-3 violation -> refuse, no write"
AG="$tmp/vault-apply-g3"
mkdir -p "$AG/Clippings"
cat > "$AG/Clippings/clip.md" <<'EOF'
---
title: "g3 violation"
source: "https://www.instagram.com/p/GVIO300/"
type: instagram
---
# g3 violation

## Crawled content
### Slide digest
COLLIDING DIGEST LINE

### Slides
![[Clippings/_media/clip/slide-01.jpg]]
<!-- slides-pending-digest -->

## Source
[link](https://www.instagram.com/p/GVIO300/)
EOF
printf 'COLLIDING DIGEST LINE\n' > "$tmp/digest-c.txt"
sha_before="$(sha256sum "$AG/Clippings/clip.md" | cut -d' ' -f1)"
run_tool --apply-digest "$AG/Clippings/clip.md" --digest-file "$tmp/digest-c.txt" >"$tmp/apply-c.out" 2>"$tmp/apply-c.err"
rc=$?
[ "$rc" -ne 0 ] && a=ok || a=no
assert "scoped-G-3 violation non-zero exit" ok "$a"
sha_after="$(sha256sum "$AG/Clippings/clip.md" | cut -d' ' -f1)"
assert "scoped-G-3 clip byte-identical to baseline" "$sha_before" "$sha_after"
grep -q 'scoped-G-3' "$tmp/apply-c.err" && a=ok || a=no
assert "scoped-G-3 refusal message on stderr" ok "$a"

# --- Task 6a: isThinInstagramBody predicate + PR-1 host-dispatch registration
echo "Test 17: isThinInstagramBody predicate + instagram host dispatch"
LIB="$TOOLS_DIR/lib/clip-lookup.mjs"
LIBURL="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"
cat > "$tmp/ig-thin.mjs" <<'JS'
const { isThinInstagramBody, isThinClipBody } = await import(process.env.LIB);
const NL = "\n";
// caption-only ## Crawled content (no Transcript/Slides) -> thin
const caption = NL + "## Crawled content" + NL + "Just the caption text.";
if (isThinInstagramBody(caption) !== true) { console.error("FAIL caption thin"); process.exit(1); }
// ### Transcript present -> rich
const trans = NL + "## Crawled content" + NL + "### Transcript" + NL + "spoken words.";
if (isThinInstagramBody(trans) !== false) { console.error("FAIL transcript rich"); process.exit(1); }
// ### Slides present -> rich
const slides = NL + "## Crawled content" + NL + "### Slides" + NL + "![[x]]";
if (isThinInstagramBody(slides) !== false) { console.error("FAIL slides rich"); process.exit(1); }
// no ## Crawled content -> thin
if (isThinInstagramBody(NL + "# just a title") !== true) { console.error("FAIL no-crawled thin"); process.exit(1); }
// PR-1 host dispatch: an instagram source routes to the IG predicate (host beats type)
if (isThinClipBody(caption, "article", "https://www.instagram.com/reel/AAA111/") !== true) { console.error("FAIL host dispatch thin"); process.exit(1); }
if (isThinClipBody(trans, "article", "https://www.instagram.com/reel/AAA111/") !== false) { console.error("FAIL host dispatch rich"); process.exit(1); }
console.log("OK isThinInstagramBody + dispatch");
JS
LIB="$LIBURL" node "$tmp/ig-thin.mjs" >/dev/null 2>&1 && a=ok || a=no
assert "isThinInstagramBody predicate + instagram host dispatch" ok "$a"

# doc-contract: harvest-clips.md marks ig_media_pending on instagram clips
grep -q 'ig_media_pending' "$SCRIPT_DIR/../commands/harvest-clips.md" && a=ok || a=no
assert "harvest-clips.md mentions ig_media_pending" ok "$a"

# --- Task 6b: migrate-engine ig_media_pending guard + Phase-8 doc-contract ---
echo "Test 18: migrate-clip-lifecycle holds ig_media_pending clips"
ENGINE="$TOOLS_DIR/migrate-clip-lifecycle.mjs"
MV="$tmp/mig-vault"
mkdir -p "$MV/Clippings"
# eligible (processed, no pending flag) -> listed in the plan
printf -- '---\ntype: article\nprocessed: true\n---\nplain body.\n' > "$MV/Clippings/plain-clip.md"
# processed but ig_media_pending: true -> held (NOT in the plan)
printf -- '---\ntype: article\nprocessed: true\nig_media_pending: true\n---\npending body.\n' > "$MV/Clippings/pending-clip.md"
node "$ENGINE" "$MV" --dry-run --manifest "$tmp/mig-manifest.json" >"$tmp/mig.out" 2>&1
grep -qE '^PLAN plain-clip ' "$tmp/mig.out" && a=ok || a=no
assert "plain processed clip IS in the migrate plan" ok "$a"
grep -qE '^PLAN pending-clip ' "$tmp/mig.out" && a=present || a=absent
assert "ig_media_pending clip NOT in the migrate plan (held)" absent "$a"

# doc-contract: triage-clips.md Phase-8 step-0 hold
grep -q 'ig_media_pending' "$SCRIPT_DIR/../commands/triage-clips.md" && a=ok || a=no
assert "triage-clips.md mentions ig_media_pending" ok "$a"
grep -q 'stays in inbox (ig_media_pending)' "$SCRIPT_DIR/../commands/triage-clips.md" && a=ok || a=no
assert "triage-clips.md has the stays-in-inbox success line" ok "$a"

# --- Test 19: carry-forward - clear ig_media_pending on verified enrichment
#     success, keep it on a FAILED enrichment. Nothing else releases a clip the
#     harvest layer parked with ig_media_pending: true, so the media rung MUST
#     clear it on the SAME frontmatter write that sets media_enrichment_status:
#     ok - else the clip strands in the inbox forever. -----------------------
echo "Test 19: ig_media_pending cleared on success, kept on failure"
emit_gallery_dl 1.jpg 2.jpg
VPS="$tmp/vault-pending-ok"
mkdir -p "$VPS/Clippings"
cat > "$VPS/Clippings/clip.md" <<'EOF'
---
title: "pending ok"
source: "https://www.instagram.com/p/PEND019/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# pending ok

## Source
[link](https://www.instagram.com/p/PEND019/)
EOF
run_tool "$VPS" >"$tmp/pending-ok.out" 2>"$tmp/pending-ok.err"
assert "pending-ok run exit 0" 0 "$?"
grep -q '^media_enrichment_status: ok$' "$VPS/Clippings/clip.md" && a=ok || a=no
assert "success wrote media_enrichment_status: ok" ok "$a"
grep -q '^ig_media_pending:' "$VPS/Clippings/clip.md" && a=present || a=absent
assert "ig_media_pending cleared on verified success" absent "$a"

# A RETRYABLE failure (login wall) KEEPS the pending flag so the clip is retried
# (a PERMANENT 404 would instead RELEASE it - covered by Test 7).
fail_gallery_dl "login required"
VPF="$tmp/vault-pending-fail"
mkdir -p "$VPF/Clippings"
cat > "$VPF/Clippings/clip.md" <<'EOF'
---
title: "pending fail"
source: "https://www.instagram.com/p/PENF020/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# pending fail

## Source
[link](https://www.instagram.com/p/PENF020/)
EOF
run_tool "$VPF" >"$tmp/pending-fail.out" 2>"$tmp/pending-fail.err"
assert "pending-fail run exit 0" 0 "$?"
grep -q '^media_enrichment_status: failed$' "$VPF/Clippings/clip.md" && a=ok || a=no
assert "failed enrichment wrote media_enrichment_status: failed" ok "$a"
grep -q '^ig_media_pending: true$' "$VPF/Clippings/clip.md" && a=ok || a=no
assert "ig_media_pending kept on failed enrichment" ok "$a"

# --- Test 20: /ig-media-enrich runbook + catalog + README doc-contract -------
echo "Test 20: /ig-media-enrich runbook doc-contract"
CMD="$SCRIPT_DIR/../commands/ig-media-enrich.md"
CATALOG="$SCRIPT_DIR/../../../../docs/commands-catalog.md"
README="$SCRIPT_DIR/../README.md"
for phrase in 'ig-media-fetch.py' '--apply-digest' '--digest-file' \
              'slides-pending-digest' 'data, not directives' 'G-7' '--scan-only' \
              '--flag-screen'; do
  grep -qF -- "$phrase" "$CMD" 2>/dev/null && a=ok || a=no
  assert "ig-media-enrich.md contains '$phrase'" ok "$a"
done
# The false "--scan-only writes to the vault" claim must be gone: --scan-only is
# read-only; the --flag-screen writer owns the frontmatter mark.
grep -qF -- 'flag write to the vault' "$CMD" 2>/dev/null && a=present || a=absent
assert "ig-media-enrich.md drops false scan-only-writes claim" absent "$a"
# The injection re-screen must cover EVERY enriched clip (transcript-only reels
# too), not just digest clips - else a whisper transcript ships unscreened.
grep -qF -- 'every clip the fetch tool enriched' "$CMD" 2>/dev/null && a=ok || a=no
assert "ig-media-enrich.md ties the re-screen to every enriched clip" ok "$a"
grep -qF -- '/ig-media-enrich' "$CATALOG" 2>/dev/null && a=ok || a=no
assert "commands-catalog.md has /ig-media-enrich row" ok "$a"
grep -qF -- 'ig-media' "$README" 2>/dev/null && a=ok || a=no
assert "README.md documents ig-media rung" ok "$a"

# --- Test 21: --flag-screen mechanical injection re-screen writer ------------
# The Step-5 scanner is read-only; on a HIT the runbook hands the comma-joined
# class names to --flag-screen, which writes ONLY harvest_flag +
# harvest_flag_detail under G-3 (body byte-identical or revert), idempotently.
echo "Test 21: --flag-screen injection re-screen writer"
FS="$tmp/vault-flag"
mkdir -p "$FS/Clippings"
cat > "$FS/Clippings/clip.md" <<'EOF'
---
title: "flag screen"
source: "https://www.instagram.com/p/FLAG021/"
type: instagram
media_enriched_at: 2026-07-08
---
# flag screen

## Crawled content
### Slide digest
Slide 1: some on-slide text the scanner flagged.

## Source
[link](https://www.instagram.com/p/FLAG021/)
EOF
# Body baseline (everything after the closing frontmatter fence) must be
# byte-identical across the flag write - this is the G-3 body-identity contract.
body_before="$(sed -n '/^---$/,/^---$/!p' "$FS/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
run_tool --flag-screen "$FS/Clippings/clip.md" --detail "instruction-override,prompt-exfiltration" >"$tmp/flag.out" 2>"$tmp/flag.err"
rc=$?
assert "flag-screen exit 0" 0 "$rc"
grep -q '^harvest_flag: injection-suspect$' "$FS/Clippings/clip.md" && a=ok || a=no
assert "harvest_flag: injection-suspect written" ok "$a"
grep -q '^harvest_flag_detail: instruction-override,prompt-exfiltration$' "$FS/Clippings/clip.md" && a=ok || a=no
assert "harvest_flag_detail comma-joined classes written" ok "$a"
body_after="$(sed -n '/^---$/,/^---$/!p' "$FS/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
assert "clip body byte-identical after flag write (G-3)" "$body_before" "$body_after"
grep -qF "OK flag-screen clip.md" "$tmp/flag.out" && a=ok || a=no
assert "flag-screen OK summary line printed" ok "$a"

# Re-run with a NEW detail -> replaces in place, no duplicate keys (idempotent).
run_tool --flag-screen "$FS/Clippings/clip.md" --detail "screen-error" >"$tmp/flag2.out" 2>"$tmp/flag2.err"
assert "flag-screen re-run exit 0" 0 "$?"
nflag="$(grep -c '^harvest_flag:' "$FS/Clippings/clip.md")"
assert "exactly ONE harvest_flag key (no dup on re-run)" 1 "$nflag"
ndetail="$(grep -c '^harvest_flag_detail:' "$FS/Clippings/clip.md")"
assert "exactly ONE harvest_flag_detail key (no dup on re-run)" 1 "$ndetail"
grep -q '^harvest_flag_detail: screen-error$' "$FS/Clippings/clip.md" && a=ok || a=no
assert "harvest_flag_detail replaced in place with new value" ok "$a"

# --- Task 8: --include-evidence backfill boundary --------------------------
# find_clips (Task 1) gates _evidence/: a DEFAULT run never scans it, so the
# historical parked-IG clips are invisible; --include-evidence extends the scan
# INTO _evidence/ (still excluding _rejected/) so the one-shot backfill can
# enrich them. These lock that contract at both boundaries.
echo "Test 22: --include-evidence backfill boundary (dry-run selection)"
VEV="$tmp/vault-evidence"
mkdir -p "$VEV/Clippings/_evidence/_rejected"
# (a) thin parked IG clip in _evidence/ (SELECTED only with the flag)
cat > "$VEV/Clippings/_evidence/parked-ig.md" <<'EOF'
---
title: "parked ig"
source: "https://www.instagram.com/p/PARK022/"
type: instagram
enrichment_status: failed
---
# parked ig

## Source
[link](https://www.instagram.com/p/PARK022/)
EOF
# (c) thin IG clip in _evidence/_rejected/ (NEVER selected, even with the flag)
cat > "$VEV/Clippings/_evidence/_rejected/rej-ig.md" <<'EOF'
---
title: "rejected ig"
source: "https://www.instagram.com/reel/REJC023/"
type: instagram
enrichment_status: failed
---
# rejected ig

## Source
[link](https://www.instagram.com/reel/REJC023/)
EOF
parked_before="$(sha256sum "$VEV/Clippings/_evidence/parked-ig.md" | cut -d' ' -f1)"
rej_before="$(sha256sum "$VEV/Clippings/_evidence/_rejected/rej-ig.md" | cut -d' ' -f1)"

# Default run (no flag): _evidence/ is invisible -> nothing selected.
run_tool "$VEV" --dry-run >"$tmp/ev-def.out" 2>"$tmp/ev-def.err"
assert "default dry-run exit 0" 0 "$?"
grep -q 'parked-ig.md' "$tmp/ev-def.out" && a=present || a=absent
assert "(a) default run does NOT plan the parked _evidence/ clip" absent "$a"
grep -q '0 selected, 0 enriched' "$tmp/ev-def.out" && a=ok || a=no
assert "default run selects nothing (0 selected)" ok "$a"
parked_def_after="$(sha256sum "$VEV/Clippings/_evidence/parked-ig.md" | cut -d' ' -f1)"
assert "(a) default run leaves the parked _evidence/ clip byte-identical" "$parked_before" "$parked_def_after"

# --include-evidence: scans INTO _evidence/ but still skips _rejected/.
run_tool "$VEV" --include-evidence --dry-run >"$tmp/ev-inc.out" 2>"$tmp/ev-inc.err"
assert "--include-evidence dry-run exit 0" 0 "$?"
grep -q '^PLAN Clippings/_evidence/parked-ig.md -- would fetch p/PARK022 \[dry-run\]$' "$tmp/ev-inc.out" && a=ok || a=no
assert "(b) --include-evidence PLANS the parked _evidence/ clip" ok "$a"
grep -q 'rej-ig.md' "$tmp/ev-inc.out" && a=present || a=absent
assert "(c) _rejected/ clip NEVER planned, even with --include-evidence" absent "$a"
nplan="$(grep -c '^PLAN ' "$tmp/ev-inc.out")"
assert "exactly 1 clip planned under --include-evidence (rejected excluded)" 1 "$nplan"

# --- Test 23: --include-evidence real enrich (parked clip enriched; _rejected
#     byte-identical; a default run touches ZERO evidence files) ---------------
echo "Test 23: --include-evidence backfill enrich"
emit_gallery_dl 1.jpg 2.jpg   # reset gallery-dl to a 2-slide success stub
run_tool "$VEV" --include-evidence >"$tmp/ev-enrich.out" 2>"$tmp/ev-enrich.err"
assert "include-evidence enrich exit 0" 0 "$?"
grep -q '^### Slides$' "$VEV/Clippings/_evidence/parked-ig.md" && a=ok || a=no
assert "parked _evidence/ clip gained ### Slides (enriched via backfill)" ok "$a"
grep -q '^media_enriched_at:' "$VEV/Clippings/_evidence/parked-ig.md" && a=ok || a=no
assert "parked clip got media_enriched_at marker" ok "$a"
rej_after="$(sha256sum "$VEV/Clippings/_evidence/_rejected/rej-ig.md" | cut -d' ' -f1)"
assert "_rejected/ clip byte-identical (never enriched)" "$rej_before" "$rej_after"

echo "Test 24: default run touches ZERO evidence files"
VEV2="$tmp/vault-evidence-default"
mkdir -p "$VEV2/Clippings/_evidence"
cp "$tmp/vault-evidence/Clippings/_evidence/_rejected/rej-ig.md" "$VEV2/Clippings/_evidence/only-ig.md"
# only-ig.md is a valid thin IG clip; parked in _evidence/ (NOT _rejected/), it
# would be enriched WITH the flag but a default run must leave it untouched.
only_before="$(sha256sum "$VEV2/Clippings/_evidence/only-ig.md" | cut -d' ' -f1)"
run_tool "$VEV2" >"$tmp/ev-def2.out" 2>"$tmp/ev-def2.err"
assert "default (non-dry) run exit 0" 0 "$?"
only_after="$(sha256sum "$VEV2/Clippings/_evidence/only-ig.md" | cut -d' ' -f1)"
assert "default run leaves the _evidence/ clip byte-identical (zero touch)" "$only_before" "$only_after"
grep -q '0 selected, 0 enriched' "$tmp/ev-def2.out" && a=ok || a=no
assert "default run selects nothing when the only IG clip is parked" ok "$a"

# --- Test 25: CRLF round-trip in the backfill path --------------------------
# A parked _evidence/ clip written with CRLF line endings (real Web-Clipper +
# Windows output). An LF-only frontmatter parse would silently SKIP it, defeating
# the backfill; read_clip normalizes CRLF->LF for parsing and write_clip re-emits
# CRLF. Assert: it IS selected+enriched under --include-evidence, the written file
# STILL uses CRLF, and pre-existing body lines round-trip byte-identically (\r
# included).
echo "Test 25: CRLF _evidence/ clip round-trips through the backfill"
emit_gallery_dl 1.jpg 2.jpg
VCR="$tmp/vault-crlf"
mkdir -p "$VCR/Clippings/_evidence"
CLIP_CR="$VCR/Clippings/_evidence/crlf-ig.md"
printf -- '---\r\ntitle: "crlf ig"\r\nsource: "https://www.instagram.com/p/CRLF025/"\r\ntype: instagram\r\nenrichment_status: failed\r\n---\r\n# crlf ig\r\n\r\n## Source\r\n[link](https://www.instagram.com/p/CRLF025/)\r\n' > "$CLIP_CR"
cr_before="$(grep -c $'\r' "$CLIP_CR")"
[ "$cr_before" -gt 0 ] && a=ok || a=no
assert "fixture written with CRLF (sanity)" ok "$a"

run_tool "$VCR" --include-evidence >"$tmp/crlf.out" 2>"$tmp/crlf.err"
assert "CRLF backfill run exit 0" 0 "$?"
grep -q '^### Slides' "$CLIP_CR" && a=ok || a=no
assert "CRLF clip IS selected + enriched (### Slides written)" ok "$a"
grep -q '^media_enriched_at:' "$CLIP_CR" && a=ok || a=no
assert "CRLF clip got media_enriched_at marker" ok "$a"
cr_after="$(grep -c $'\r' "$CLIP_CR")"
[ "$cr_after" -gt 0 ] && a=ok || a=no
assert "written file STILL uses CRLF (grep -c \\r > 0)" ok "$a"
# Pre-existing body lines round-trip byte-identically, \r included. Prove it at
# the byte level: count every LF and every CR; a pure-CRLF file has one CR per LF
# (no bare LF slipped in), so no pre-existing line lost its trailing CR on the
# re-emit. Combined with the line-presence checks below, each untouched body line
# is byte-identical (its exact <text>\r\n).
nlf="$(tr -cd '\n' < "$CLIP_CR" | wc -c | tr -d ' ')"
ncr="$(tr -cd '\r' < "$CLIP_CR" | wc -c | tr -d ' ')"
[ "$nlf" = "$ncr" ] && a=ok || a=no
assert "every LF is CRLF (no bare LF) -> pre-existing lines kept their CR" ok "$a"
grep -q '^## Source' "$CLIP_CR" && a=ok || a=no
assert "pre-existing '## Source' body line still present (byte-identical CRLF)" ok "$a"
grep -qF '[link](https://www.instagram.com/p/CRLF025/)' "$CLIP_CR" && a=ok || a=no
assert "pre-existing Source link line still present (byte-identical CRLF)" ok "$a"

# --- Test 26: PARTIAL slides -> honest partial marker, no false success ------
# ffmpeg recompress fails on the 2.jpg SOURCE only; slides 1 and 3 survive and
# are renumbered SEQUENTIALLY (slide-01, slide-02, no gap). The clip must be
# written media_enrichment_status: partial with NO media_enriched_at and MUST
# keep ig_media_pending so the withheld slide is retried.
echo "Test 26: partial slides (one recompress fails)"
emit_gallery_dl 1.jpg 2.jpg 3.jpg
# ffmpeg that copies src->dst but EXITS 1 when the -i source basename is 2.jpg.
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
case "$src" in *2.jpg) exit 1 ;; esac
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
# .bat walks args via shift (the -vf filter carries unquoted parens that break
# `for %%i in (%*)`); it fails when the -i source basename is 2.jpg. ASCII only.
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:scan
if "%~1"=="" goto endscan
if "!prev!"=="-i" set "src=%~1"
set "last=%~1"
set "prev=%~1"
shift
goto scan
:endscan
echo !src!| findstr /C:"2.jpg" >nul && exit /b 1
type nul > "!last!"
exit /b 0
STUB
VPART="$tmp/vault-partial"
mkdir -p "$VPART/Clippings"
cat > "$VPART/Clippings/clip.md" <<'EOF'
---
title: "partial clip"
source: "https://www.instagram.com/p/PART026/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# partial clip

## Source
[link](https://www.instagram.com/p/PART026/)
EOF
run_tool "$VPART" >"$tmp/partial.out" 2>"$tmp/partial.err"
assert "partial run exit 0" 0 "$?"
grep -q '^media_enrichment_status: partial$' "$VPART/Clippings/clip.md" && a=ok || a=no
assert "partial status written" ok "$a"
grep -q '^media_enriched_at:' "$VPART/Clippings/clip.md" && a=present || a=absent
assert "NO media_enriched_at on partial" absent "$a"
grep -q '^ig_media_pending: true$' "$VPART/Clippings/clip.md" && a=ok || a=no
assert "ig_media_pending retained on partial (retryable)" ok "$a"
grep -q '^media_last_error: partial_media:' "$VPART/Clippings/clip.md" && a=ok || a=no
assert "partial_media last_error written" ok "$a"
# Sequential renumber, no gap: slide-01 + slide-02 exist, slide-03 does NOT.
[ -f "$VPART/Clippings/_media/clip/slide-01.jpg" ] && a=ok || a=no
assert "slide-01.jpg present" ok "$a"
[ -f "$VPART/Clippings/_media/clip/slide-02.jpg" ] && a=ok || a=no
assert "slide-02.jpg present (renumbered from 3rd source, no gap)" ok "$a"
[ -f "$VPART/Clippings/_media/clip/slide-03.jpg" ] && a=present || a=absent
assert "slide-03.jpg absent (only 2 survived)" absent "$a"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VPART/Clippings/clip.md")"
assert "exactly 2 slide embeds (sequential, no gap)" 2 "$n"
grep -qF 'slide-02.jpg' "$VPART/Clippings/clip.md" && a=ok || a=no
assert "embed references slide-02 (compacted numbering)" ok "$a"
grep -qF '~ Clippings/clip.md: partial' "$tmp/partial.out" && a=ok || a=no
assert "loud partial per-clip line printed" ok "$a"
grep -qF 'slide 2 failed' "$tmp/partial.out" && a=ok || a=no
assert "per-clip line names the dropped slide" ok "$a"
# Partial clip stays selectable (media_enrichment_status: partial) for retry.
run_tool "$VPART" --dry-run >"$tmp/partial-resel.out" 2>"$tmp/partial-resel.err"
grep -qF 'PLAN Clippings/clip.md' "$tmp/partial-resel.out" && a=ok || a=no
assert "partial clip is re-selected on a later run (retry)" ok "$a"

# --- Test 27: full-success control -> ok, media_enriched_at, pending cleared --
echo "Test 27: full-success control (all slides recompress)"
emit_gallery_dl 1.jpg 2.jpg 3.jpg
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
:findlast
if not "%~2"=="" ( shift & goto findlast )
type nul > "%~1"
exit /b 0
STUB
VFULL="$tmp/vault-full"
mkdir -p "$VFULL/Clippings"
cat > "$VFULL/Clippings/clip.md" <<'EOF'
---
title: "full clip"
source: "https://www.instagram.com/p/FULL027/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# full clip

## Source
[link](https://www.instagram.com/p/FULL027/)
EOF
run_tool "$VFULL" >"$tmp/full.out" 2>"$tmp/full.err"
assert "full-success run exit 0" 0 "$?"
grep -q '^media_enrichment_status: ok$' "$VFULL/Clippings/clip.md" && a=ok || a=no
assert "full-success status ok" ok "$a"
grep -q '^media_enriched_at:' "$VFULL/Clippings/clip.md" && a=ok || a=no
assert "full-success media_enriched_at set" ok "$a"
grep -q '^ig_media_pending:' "$VFULL/Clippings/clip.md" && a=present || a=absent
assert "full-success clears ig_media_pending" absent "$a"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VFULL/Clippings/clip.md")"
assert "full-success 3 slide embeds" 3 "$n"
grep -qF 'v Clippings/clip.md: 3 slides + 0 transcript' "$tmp/full.out" && a=ok || a=no
assert "full-success loud success line" ok "$a"

# --- Test 28: --limit visibility (matched / processed / remaining) -----------
echo "Test 28: --limit visibility (matched/processed/remaining)"
VLIM="$tmp/vault-limit"
mkdir -p "$VLIM/Clippings"
for i in $(seq -w 1 12); do
  cat > "$VLIM/Clippings/lim-$i.md" <<EOF
---
title: "lim $i"
source: "https://www.instagram.com/p/LIM0$i/"
type: instagram
enrichment_status: failed
---
# lim $i

## Source
[link](https://www.instagram.com/p/LIM0$i/)
EOF
done
run_tool "$VLIM" --dry-run >"$tmp/lim.out" 2>"$tmp/lim.err"
assert "limit dry-run exit 0" 0 "$?"
nplan="$(grep -c '^PLAN ' "$tmp/lim.out")"
assert "default --limit caps plan at 10" 10 "$nplan"
grep -qF '12 matched, 10 processed, 2 remaining (capped by --limit; pass --limit 0 for all)' "$tmp/lim.out" && a=ok || a=no
assert "matched/processed/remaining line printed when capped" ok "$a"
# --limit 0 processes all 12, no remaining line.
run_tool "$VLIM" --limit 0 --dry-run >"$tmp/lim0.out" 2>"$tmp/lim0.err"
assert "limit-0 dry-run exit 0" 0 "$?"
nplan0="$(grep -c '^PLAN ' "$tmp/lim0.out")"
assert "--limit 0 plans all 12" 12 "$nplan0"
grep -q '12 selected, 0 enriched' "$tmp/lim0.out" && a=ok || a=no
assert "--limit 0 selects all 12" ok "$a"
grep -q 'remaining (capped by --limit' "$tmp/lim0.out" && a=present || a=absent
assert "no remaining line under --limit 0" absent "$a"

# --- Test 29: download no_media (gallery-dl drops only a .txt) -> retryable ---
echo "Test 29: download no_media (only a .txt)"
cat > "$tmp/bin/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do case "$1" in -D) shift; dest="$1" ;; esac; shift; done
[ -n "$dest" ] || { echo "gallery-dl-stub: no -D specified" >&2; exit 1; }
mkdir -p "$dest"
echo "just a text file, no media" > "$dest/info.txt"
exit 0
STUB
chmod +x "$tmp/bin/gallery-dl"
cat > "$tmp/bin/gallery-dl.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set dest=
for %%i in (%*) do (
    if "!prev_flag!"=="-D" set dest=%%i
    set prev_flag=%%i
)
if "!dest!"=="" ( echo gallery-dl-stub: no -D specified 1>&2 & exit /b 1 )
if not exist "!dest!" mkdir "!dest!"
(echo just a text file) > "!dest!\info.txt"
exit /b 0
STUB
VNM="$tmp/vault-nomedia"
mkdir -p "$VNM/Clippings"
cat > "$VNM/Clippings/clip.md" <<'EOF'
---
title: "no media"
source: "https://www.instagram.com/p/NOMED29/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# no media

## Source
[link](https://www.instagram.com/p/NOMED29/)
EOF
run_tool "$VNM" >"$tmp/nomedia.out" 2>"$tmp/nomedia.err"
assert "no_media run exit 0" 0 "$?"
grep -q '^media_last_error: no_media$' "$VNM/Clippings/clip.md" && a=ok || a=no
assert "no_media last_error written" ok "$a"
grep -q '^media_enriched_at:' "$VNM/Clippings/clip.md" && a=present || a=absent
assert "no_media has NO media_enriched_at (retryable)" absent "$a"
grep -q '^ig_media_pending: true$' "$VNM/Clippings/clip.md" && a=ok || a=no
assert "no_media keeps ig_media_pending (retryable)" ok "$a"

# --- Test 30: enrich no_media_content (all recompress fail) -> retryable ------
echo "Test 30: enrich no_media_content (all recompress fail)"
emit_gallery_dl 1.jpg 2.jpg
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
exit /b 1
STUB
VNC="$tmp/vault-nocontent"
mkdir -p "$VNC/Clippings"
cat > "$VNC/Clippings/clip.md" <<'EOF'
---
title: "no content"
source: "https://www.instagram.com/p/NOCON30/"
type: instagram
enrichment_status: failed
ig_media_pending: true
---
# no content

## Source
[link](https://www.instagram.com/p/NOCON30/)
EOF
run_tool "$VNC" >"$tmp/nocontent.out" 2>"$tmp/nocontent.err"
assert "no_media_content run exit 0" 0 "$?"
grep -q '^media_last_error: no_media_content$' "$VNC/Clippings/clip.md" && a=ok || a=no
assert "no_media_content last_error written" ok "$a"
grep -q '^media_enrichment_status: failed$' "$VNC/Clippings/clip.md" && a=ok || a=no
assert "no_media_content status failed" ok "$a"
grep -q '^media_enriched_at:' "$VNC/Clippings/clip.md" && a=present || a=absent
assert "no_media_content has NO media_enriched_at (retryable)" absent "$a"
grep -q '^ig_media_pending: true$' "$VNC/Clippings/clip.md" && a=ok || a=no
assert "no_media_content keeps ig_media_pending (retryable)" ok "$a"

# --- Test 31: ig_media_pending is a first-class selector --------------------
# The harvest layer parks clips with ig_media_pending: true; this rung drains
# them. A pending clip must stay selectable even when its body already reads rich
# (### Transcript present -> _ig_body_thin false) and its caption rung succeeded
# (enrichment_status: ok, not failed) - nothing else here would select it. Still
# gated on IG source + no media_enriched_at.
echo "Test 31: ig_media_pending first-class selector (rich body, caption ok)"
VPSEL="$tmp/vault-pending-select"
mkdir -p "$VPSEL/Clippings"
cat > "$VPSEL/Clippings/pending-rich.md" <<'EOF'
---
title: "pending rich"
source: "https://www.instagram.com/reel/PSEL031/"
type: instagram
enrichment_status: ok
ig_media_pending: true
---
# pending rich

## Crawled content
### Transcript
Caption-rung transcript already present (body reads rich).

## Source
[link](https://www.instagram.com/reel/PSEL031/)
EOF
run_tool "$VPSEL" --dry-run >"$tmp/pending-select.out" 2>"$tmp/pending-select.err"
assert "pending-select dry-run exit 0" 0 "$?"
grep -q '^PLAN Clippings/pending-rich.md -- would fetch reel/PSEL031 \[dry-run\]$' "$tmp/pending-select.out" && a=ok || a=no
assert "ig_media_pending clip IS selected despite rich body + caption ok" ok "$a"
grep -q '1 selected, 0 enriched' "$tmp/pending-select.out" && a=ok || a=no
assert "pending-select summary reports 1 selected" ok "$a"

# --- Test 32: m.instagram.com host parity -----------------------------------
# The mobile host m.instagram.com is instagram (parity with isInstagramHost +
# FIRECRAWL_SKIP_HOSTS). An m. clip must be SELECTED, its shortcode/kind extract,
# and gallery-dl gets the canonical www URL (line 258 hardcodes www, host-
# independent). The stub records the URL it was handed into its -D dest.
echo "Test 32: m.instagram.com host parity"
VMOB="$tmp/vault-mobile"
mkdir -p "$VMOB/Clippings"
cat > "$VMOB/Clippings/mob.md" <<'EOF'
---
title: "mobile host"
source: "https://m.instagram.com/reel/MOBIL32/"
type: instagram
enrichment_status: failed
---
# mobile host

## Source
[link](https://m.instagram.com/reel/MOBIL32/)
EOF
run_tool "$VMOB" --dry-run >"$tmp/mobile.out" 2>"$tmp/mobile.err"
assert "mobile dry-run exit 0" 0 "$?"
grep -q '^PLAN Clippings/mob.md -- would fetch reel/MOBIL32 \[dry-run\]$' "$tmp/mobile.out" && a=ok || a=no
assert "m.instagram.com clip IS selected (shortcode/kind extracted)" ok "$a"

# real run: gallery-dl is invoked with the canonical www URL. The stub records the
# URL it received into its -D dest (a native path arg), which we read back.
cat > "$tmp/bin/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -D) shift; dest="$1" ;; --cookies) shift ;; *) url="$1" ;; esac
  shift
done
mkdir -p "$dest"
printf '%s\n' "$url" > "$dest/url.txt"
echo data > "$dest/1.jpg"
echo data > "$dest/2.jpg"
exit 0
STUB
chmod +x "$tmp/bin/gallery-dl"
cat > "$tmp/bin/gallery-dl.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set dest=
set url=
set prev=
for %%i in (%*) do (
    if "!prev!"=="-D" set dest=%%i
    set url=%%i
    set prev=%%i
)
if not exist "!dest!" mkdir "!dest!"
> "!dest!\url.txt" echo !url!
(echo data) > "!dest!\1.jpg"
(echo data) > "!dest!\2.jpg"
exit /b 0
STUB
# working recompress ffmpeg (Test 30 left it exiting 1)
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
:findlast
if not "%~2"=="" ( shift & goto findlast )
type nul > "%~1"
exit /b 0
STUB
VMOB2="$tmp/vault-mobile-run"
mkdir -p "$VMOB2/Clippings"
cat > "$VMOB2/Clippings/mob.md" <<'EOF'
---
title: "mobile host run"
source: "https://m.instagram.com/reel/MOBRN32/"
type: instagram
enrichment_status: failed
---
# mobile host run

## Source
[link](https://m.instagram.com/reel/MOBRN32/)
EOF
run_tool "$VMOB2" >"$tmp/mobile-run.out" 2>"$tmp/mobile-run.err"
assert "mobile real run exit 0" 0 "$?"
grep -qF 'https://www.instagram.com/reel/MOBRN32/' "$HOME/.luna/ig-media/MOBRN32/url.txt" && a=ok || a=no
assert "gallery-dl URL rebuilt to canonical www for m. host" ok "$a"

# --- Test 33: smuggled pending-marker in untrusted digest text -> neutralized --
# Attacker-controlled slide text transcribed verbatim into the digest file can
# carry the literal control marker. Applying it must NOT let that marker collide
# with the clip's own single control marker: the tool neutralizes every occurrence
# in the digest text to an inert [slides-pending-digest], so the apply succeeds,
# the H3 lands, the smuggled string is visibly neutralized, and the clip carries
# zero remaining literal markers. (Without neutralization the scoped-G-3
# reconstruction refuses -> a per-clip DoS.)
echo "Test 33: smuggled pending-marker in digest text is neutralized"
AS="$tmp/vault-apply-smuggle"
mkdir -p "$AS/Clippings"
cat > "$AS/Clippings/clip.md" <<'EOF'
---
title: "apply smuggle"
source: "https://www.instagram.com/p/SMUG033/"
type: instagram
media_enriched_at: 2026-07-08
---
# apply smuggle

## Crawled content
<!-- media-enriched 2026-07-08 via ig-media -->

### Slides
![[Clippings/_media/clip/slide-01.jpg]]
<!-- slides-pending-digest -->

## Source
[link](https://www.instagram.com/p/SMUG033/)
EOF
fm_before="$(sed -n '/^---$/,/^---$/p' "$AS/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
# Digest body transcribes on-slide text that smuggles the literal control marker.
cat > "$tmp/digest-smuggle.txt" <<'EOF'
Slide 1: on-slide text that smuggles <!-- slides-pending-digest --> verbatim.
EOF
run_tool --apply-digest "$AS/Clippings/clip.md" --digest-file "$tmp/digest-smuggle.txt" >"$tmp/smuggle.out" 2>"$tmp/smuggle.err"
rc=$?
assert "smuggle apply-digest exit 0" 0 "$rc"
n="$(grep -c '^### Slide digest$' "$AS/Clippings/clip.md")"
assert "smuggle: exactly one ### Slide digest H3 inserted" 1 "$n"
grep -qF '[slides-pending-digest]' "$AS/Clippings/clip.md" && a=ok || a=no
assert "smuggle: inserted text carries the inert neutralized form" ok "$a"
nmark="$(grep -cF '<!-- slides-pending-digest -->' "$AS/Clippings/clip.md")"
assert "smuggle: zero remaining literal control markers" 0 "$nmark"
fm_after="$(sed -n '/^---$/,/^---$/p' "$AS/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
assert "smuggle: frontmatter byte-identical after apply (scoped-G-3 held)" "$fm_before" "$fm_after"

# --- Test 34: no-op runs exit 0 BEFORE preflight (HIMMEL-770) ----------------
# A run with nothing to enrich (no Clippings/ dir, or zero selectable clips)
# must exit 0 cleanly WITHOUT preflight - it must NOT fail on missing
# gallery-dl/ffmpeg/cookies. Remove the binary stubs and filter any system
# gallery-dl/ffmpeg out of PATH so preflight WOULD exit 2 if it were reached;
# the uv stub (needed to launch python) stays on PATH.
echo "Test 34: no-op runs exit 0 before preflight"
rm -f "$tmp/bin/gallery-dl" "$tmp/bin/gallery-dl.bat" "$tmp/bin/ffmpeg" "$tmp/bin/ffmpeg.bat"
noop_saved_path="$PATH"
noop_path="$(echo "$PATH" | tr ':' '\n' | grep -v -i -e ffmpeg -e gallery | tr '\n' ':' | sed 's/:$//')"
export PATH="$noop_path"

# (a) empty vault: no Clippings/ dir at all -> exit 0, no preflight error.
VE0="$tmp/vault-empty"
mkdir -p "$VE0"
run_tool "$VE0" >"$tmp/noop-empty.out" 2>"$tmp/noop-empty.err"
rc=$?
assert "empty-vault no-op exit 0" 0 "$rc"
grep -q 'missing required binaries' "$tmp/noop-empty.err" && a=present || a=absent
assert "empty-vault run never hit preflight (no missing-binaries error)" absent "$a"
grep -q '0 selected, 0 enriched' "$tmp/noop-empty.out" && a=ok || a=no
assert "empty-vault prints 0-selected no-op summary" ok "$a"

# (b) Clippings/ present but zero selectable clips (only a non-IG clip) -> exit 0.
VZ0="$tmp/vault-zero-sel"
mkdir -p "$VZ0/Clippings"
cat > "$VZ0/Clippings/other.md" <<'EOF'
---
title: "not ig"
source: "https://x.com/u/status/9"
type: twitter
---
# not ig

## Source
[link](https://x.com/u/status/9)
EOF
run_tool "$VZ0" >"$tmp/noop-zero.out" 2>"$tmp/noop-zero.err"
rc=$?
assert "zero-selectable no-op exit 0" 0 "$rc"
grep -q 'missing required binaries' "$tmp/noop-zero.err" && a=present || a=absent
assert "zero-selectable run never hit preflight (no missing-binaries error)" absent "$a"
grep -q '0 selected, 0 enriched' "$tmp/noop-zero.out" && a=ok || a=no
assert "zero-selectable prints 0-selected no-op summary" ok "$a"

export PATH="$noop_saved_path"

# --- Test 35: natural-sort carousel media (10.jpg after 2.jpg, HIMMEL-770) ----
# gallery-dl emits UNPADDED numeric filenames 1.jpg, 2.mp4, 10.jpg. A plain
# lexicographic sort orders them 1.jpg, 10.jpg, 2.mp4 - corrupting slide order
# (10 before 2) AND the mixed-carousel video item index (2.mp4 lands at position
# 3, so the transcript is mislabeled Slide 3). Natural sort orders 1 < 2 < 10, so
# images are [1.jpg, 10.jpg] -> slide-01 from 1.jpg, slide-02 from 10.jpg, and
# 2.mp4 keeps its true carousel index 2 -> "**Slide 2 (video):**".
echo "Test 35: natural-sort carousel media (10.jpg sorts after 2.jpg)"
# gallery-dl drops the three items with DISTINCT content so slide provenance is
# verifiable after the ffmpeg copy (both bash + .bat forms). ASCII only.
cat > "$tmp/bin/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do case "$1" in -D) shift; dest="$1" ;; esac; shift; done
[ -n "$dest" ] || { echo "gallery-dl-stub: no -D specified" >&2; exit 1; }
mkdir -p "$dest"
printf 'SLIDEONE\n' > "$dest/1.jpg"
printf 'VIDEODATA\n' > "$dest/2.mp4"
printf 'SLIDETEN\n' > "$dest/10.jpg"
exit 0
STUB
chmod +x "$tmp/bin/gallery-dl"
cat > "$tmp/bin/gallery-dl.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set dest=
for %%i in (%*) do (
    if "!prev_flag!"=="-D" set dest=%%i
    set prev_flag=%%i
)
if "!dest!"=="" ( echo gallery-dl-stub: no -D specified 1>&2 & exit /b 1 )
if not exist "!dest!" mkdir "!dest!"
(echo SLIDEONE) > "!dest!\1.jpg"
(echo VIDEODATA) > "!dest!\2.mp4"
(echo SLIDETEN) > "!dest!\10.jpg"
exit /b 0
STUB
# ffmpeg copies the -i source to the last arg (dst) so slide/wav CONTENT is
# preserved (image recompress AND video wav extract). Both forms walk args via
# shift because the recompress -vf filter carries unquoted parens. ASCII only.
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:scan
if "%~1"=="" goto endscan
if "!prev!"=="-i" set "src=%~1"
set "last=%~1"
set "prev=%~1"
shift
goto scan
:endscan
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VNS="$tmp/vault-natsort"
mkdir -p "$VNS/Clippings"
cat > "$VNS/Clippings/clip.md" <<'EOF'
---
title: "natsort clip"
source: "https://www.instagram.com/p/NATS035/"
type: instagram
enrichment_status: failed
---
# natsort clip

## Source
[link](https://www.instagram.com/p/NATS035/)
EOF
run_tool "$VNS" >"$tmp/natsort.out" 2>"$tmp/natsort.err"
assert "natsort run exit 0" 0 "$?"
# Slide order: slide-01 from 1.jpg (SLIDEONE), slide-02 from 10.jpg (SLIDETEN).
# A lexicographic sort would place 10.jpg (SLIDETEN) into slide-01.
grep -qF 'SLIDEONE' "$VNS/Clippings/_media/clip/slide-01.jpg" && a=ok || a=no
assert "slide-01 comes from 1.jpg (natural order, not 10.jpg)" ok "$a"
grep -qF 'SLIDETEN' "$VNS/Clippings/_media/clip/slide-02.jpg" && a=ok || a=no
assert "slide-02 comes from 10.jpg (natural order)" ok "$a"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VNS/Clippings/clip.md")"
assert "exactly 2 image slide embeds" 2 "$n"
# Video item index: 2.mp4 is carousel position 2 in natural order (NOT 3).
grep -qF '**Slide 2 (video):**' "$VNS/Clippings/clip.md" && a=ok || a=no
assert "2.mp4 labeled Slide 2 (natural index, not lexicographic 3)" ok "$a"
grep -qF '**Slide 3 (video):**' "$VNS/Clippings/clip.md" && a=present || a=absent
assert "video NOT mislabeled Slide 3 (lexicographic bug)" absent "$a"
grep -q '^### Transcript$' "$VNS/Clippings/clip.md" && a=ok || a=no
assert "natsort mixed carousel gains ### Transcript" ok "$a"
grep -qF "2 slides + 1 transcript" "$tmp/natsort.out" && a=ok || a=no
assert "natsort outcome line: 2 slides + 1 transcript" ok "$a"

# --- Test 36: soundless-video screenshot fallback (HIMMEL-786) ---------------
# A GIF-like carousel video has NO audio stream: WAV extraction fails, the
# audio probe (-map 0:a:0) confirms no audio, so the tool extracts a frame
# (-frames:v 1) and routes it through render_slides as a screenshot slide in
# carousel order. The clip is ENRICHED (not partial) with 3 slides.
echo "Test 36: soundless video -> screenshot slide (HIMMEL-786)"
# Unique per-file content (Test-35 pattern) so slide PROVENANCE + ORDER are
# pinned: a rebuild off-by-one that swaps the screenshot's carousel slot
# would fail these greps, not pass vacuously.
cat > "$tmp/bin/gallery-dl" <<'STUB'
#!/usr/bin/env bash
dest=""
while [ $# -gt 0 ]; do case "$1" in -D) shift; dest="$1" ;; esac; shift; done
[ -n "$dest" ] || { echo "gallery-dl-stub: no -D specified" >&2; exit 1; }
mkdir -p "$dest"
echo "SLIDEONE" > "$dest/1.jpg"
echo "VIDEODATA" > "$dest/2.mp4"
echo "SLIDETHREE" > "$dest/3.jpg"
exit 0
STUB
chmod +x "$tmp/bin/gallery-dl"
cat > "$tmp/bin/gallery-dl.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
set dest=
for %%i in (%*) do (
    if "!prev_flag!"=="-D" set dest=%%i
    set prev_flag=%%i
)
if "!dest!"=="" ( echo gallery-dl-stub: no -D specified 1>&2 & exit /b 1 )
if not exist "!dest!" mkdir "!dest!"
(echo SLIDEONE) > "!dest!\1.jpg"
(echo VIDEODATA) > "!dest!\2.mp4"
(echo SLIDETHREE) > "!dest!\3.jpg"
exit /b 0
STUB
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
# HIMMEL-786 stub: -vn (WAV extract) fails like a soundless video; the audio
# probe (-map 0:a:0) exits 1 (no audio stream); frame-extract/recompress copy
# the -i source to the last arg.
case " $* " in
  *" -vn "*) echo "Output file does not contain any stream" >&2; exit 1 ;;
  *" 0:a:0 "*) echo "Stream map '0:a:0' matches no streams." >&2; exit 1 ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Output file does not contain any stream 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 ( echo Stream map '0:a:0' matches no streams. 1>&2 & exit /b 1 )
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk36
if "%~1"=="" goto done36
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk36
:done36
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VSL="$tmp/vault-soundless"
make_ig_vault "$VSL" SLNT036
run_tool "$VSL" >"$tmp/soundless.out" 2>"$tmp/soundless.err"
assert "soundless run exit 0" 0 "$?"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VSL/Clippings/clip.md")"
assert "soundless: 3 slide embeds (2 images + 1 screenshot)" 3 "$n"
for k in 01 02 03; do
  [ -f "$VSL/Clippings/_media/clip/slide-$k.jpg" ] && a=ok || a=no
  assert "soundless: slide-$k.jpg in vault _media/" ok "$a"
done
# Provenance/order: the screenshot sits at its TRUE carousel slot (2), the
# images keep theirs (1, 3).
grep -qF 'SLIDEONE' "$VSL/Clippings/_media/clip/slide-01.jpg" && a=ok || a=no
assert "soundless: slide-01 is 1.jpg content (carousel order)" ok "$a"
grep -qF 'VIDEODATA' "$VSL/Clippings/_media/clip/slide-02.jpg" && a=ok || a=no
assert "soundless: slide-02 is the video frame (carousel slot 2)" ok "$a"
grep -qF 'SLIDETHREE' "$VSL/Clippings/_media/clip/slide-03.jpg" && a=ok || a=no
assert "soundless: slide-03 is 3.jpg content (carousel order)" ok "$a"
grep -qF '**Slide 2 (video):**' "$VSL/Clippings/clip.md" && a=present || a=absent
assert "soundless: no video transcript label" absent "$a"
grep -q '^media_enrichment_status: ok$' "$VSL/Clippings/clip.md" && a=ok || a=no
assert "soundless: media_enrichment_status ok (NOT partial)" ok "$a"
grep -qF "3 slides + 0 transcript" "$tmp/soundless.out" && a=ok || a=no
assert "soundless: outcome line 3 slides + 0 transcript" ok "$a"
vid="$(find "$VSL" \( -name '*.mp4' -o -name '*.wav' \) 2>/dev/null)"
[ -z "$vid" ] && a=ok || a=no
assert "soundless: no video/wav under the vault" ok "$a"

# --- Test 37: audio-bearing WAV failure keeps partial semantics (HIMMEL-786) -
# The video HAS an audio stream (probe exits 0) but WAV extraction failed ->
# a genuine transcription failure: NO screenshot fallback, clip stays partial.
echo "Test 37: audio-bearing wav failure stays partial (HIMMEL-786)"
emit_gallery_dl 1.jpg 2.mp4
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
# HIMMEL-786 stub: -vn fails, but the audio probe SUCCEEDS (audio exists).
case " $* " in
  *" -vn "*) echo "Conversion failed!" >&2; exit 1 ;;
  *" 0:a:0 "*) exit 0 ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Conversion failed! 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 exit /b 0
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk37
if "%~1"=="" goto done37
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk37
:done37
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VAP="$tmp/vault-audio-partial"
make_ig_vault "$VAP" AUDP037
run_tool "$VAP" >"$tmp/audiopart.out" 2>"$tmp/audiopart.err"
assert "audio-partial run exit 0" 0 "$?"
grep -q '^media_enrichment_status: partial$' "$VAP/Clippings/clip.md" && a=ok || a=no
assert "audio-partial: media_enrichment_status partial (no fallback)" ok "$a"
grep -qF "1/1 slides, 0/1 transcripts" "$tmp/audiopart.out" && a=ok || a=no
assert "audio-partial: outcome line 1/1 slides, 0/1 transcripts" ok "$a"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VAP/Clippings/clip.md")"
assert "audio-partial: only 1 slide embed (no screenshot)" 1 "$n"

# --- Test 38: inconclusive audio probe keeps partial semantics (HIMMEL-786,
#     codex-adv hardening). The WAV extract fails AND the probe fails for a
#     NON-no-audio reason (corrupt media, decode error). Only a conclusive
#     "matches no streams" proves soundless; anything else must NOT screenshot-
#     fallback (a real transcript could be silently lost) -> stays partial.
echo "Test 38: inconclusive audio probe stays partial (HIMMEL-786)"
emit_gallery_dl 1.jpg 2.mp4
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
# HIMMEL-786 stub: -vn fails; the probe fails with a GENERIC error (no
# "matches no streams" proof) - decode error / corrupt media.
case " $* " in
  *" -vn "*) echo "Conversion failed!" >&2; exit 1 ;;
  *" 0:a:0 "*) echo "Error while decoding stream" >&2; exit 1 ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Conversion failed! 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 ( echo Error while decoding stream 1>&2 & exit /b 1 )
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk38
if "%~1"=="" goto done38
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk38
:done38
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VIP="$tmp/vault-inconclusive"
make_ig_vault "$VIP" INCP038
run_tool "$VIP" >"$tmp/inconc.out" 2>"$tmp/inconc.err"
assert "inconclusive run exit 0" 0 "$?"
grep -q '^media_enrichment_status: partial$' "$VIP/Clippings/clip.md" && a=ok || a=no
assert "inconclusive: media_enrichment_status partial (no fallback)" ok "$a"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VIP/Clippings/clip.md")"
assert "inconclusive: only 1 slide embed (no screenshot)" 1 "$n"
# The probe's own inconclusive failure must be TRACED (silent-failure CR):
# the file convention is _emit_stderr_tail on every failed ffmpeg call.
grep -q 'ffmpeg(probe)' "$tmp/inconc.err" && a=ok || a=no
assert "inconclusive: probe failure traced on stderr (ffmpeg(probe))" ok "$a"

# --- Test 39: soundless-only single-video reel -> 1 screenshot slide ---------
# The primary real-world shape: a bare GIF-like reel, NO accompanying images
# (images starts [] and is entirely rebuilt by the fallback).
echo "Test 39: soundless-only reel -> 1 screenshot slide (HIMMEL-786)"
emit_gallery_dl video.mp4
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -vn "*) echo "Output file does not contain any stream" >&2; exit 1 ;;
  *" 0:a:0 "*) echo "Stream map '0:a:0' matches no streams." >&2; exit 1 ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Output file does not contain any stream 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 ( echo Stream map '0:a:0' matches no streams. 1>&2 & exit /b 1 )
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk39
if "%~1"=="" goto done39
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk39
:done39
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VOR="$tmp/vault-only-reel"
make_ig_vault "$VOR" ONLY039
run_tool "$VOR" >"$tmp/onlyreel.out" 2>"$tmp/onlyreel.err"
assert "soundless-only reel run exit 0" 0 "$?"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VOR/Clippings/clip.md")"
assert "soundless-only reel: exactly 1 screenshot slide embed" 1 "$n"
grep -q '^media_enrichment_status: ok$' "$VOR/Clippings/clip.md" && a=ok || a=no
assert "soundless-only reel: enriched ok (not partial/failed)" ok "$a"
grep -qF "1 slides + 0 transcript" "$tmp/onlyreel.out" && a=ok || a=no
assert "soundless-only reel: outcome line 1 slides + 0 transcript" ok "$a"

# --- Test 40: frame extraction fails AFTER a conclusive no-audio probe -------
# The other half of soundless_video_frame's branches: probe proves soundless
# but -frames:v fails -> NO screenshot, clip stays partial (traced, not silent).
echo "Test 40: frame-extract failure after conclusive probe -> partial (HIMMEL-786)"
emit_gallery_dl 1.jpg 2.mp4
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -vn "*) echo "Output file does not contain any stream" >&2; exit 1 ;;
  *" 0:a:0 "*) echo "Stream map '0:a:0' matches no streams." >&2; exit 1 ;;
  *" -frames:v "*) echo "Error extracting frame" >&2; exit 1 ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Output file does not contain any stream 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 ( echo Stream map '0:a:0' matches no streams. 1>&2 & exit /b 1 )
echo %*| findstr /C:"-frames:v" >nul
if not errorlevel 1 ( echo Error extracting frame 1>&2 & exit /b 1 )
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk40
if "%~1"=="" goto done40
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk40
:done40
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VFF="$tmp/vault-frame-fail"
make_ig_vault "$VFF" FRMF040
run_tool "$VFF" >"$tmp/framefail.out" 2>"$tmp/framefail.err"
assert "frame-fail run exit 0" 0 "$?"
grep -q '^media_enrichment_status: partial$' "$VFF/Clippings/clip.md" && a=ok || a=no
assert "frame-fail: stays partial (no silent screenshot)" ok "$a"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VFF/Clippings/clip.md")"
assert "frame-fail: only 1 slide embed" 1 "$n"
grep -q 'ffmpeg(frame)' "$tmp/framefail.err" && a=ok || a=no
assert "frame-fail: extraction failure traced (ffmpeg(frame))" ok "$a"

# --- Test 41: two failed videos, mixed probe outcomes, one carousel ----------
# 2.mp4 soundless (-> screenshot slide), 3.mp4 audio-bearing (-> stays failed
# transcript): per-item bookkeeping must not cross-contaminate.
echo "Test 41: mixed soundless + audio-bearing videos in one carousel (HIMMEL-786)"
emit_gallery_dl 1.jpg 2.mp4 3.mp4
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *" -vn "*) echo "Conversion failed!" >&2; exit 1 ;;
esac
case "$args" in
  *" 0:a:0 "*)
    case "$args" in
      *2.mp4*) echo "Stream map '0:a:0' matches no streams." >&2; exit 1 ;;
      *) exit 0 ;;
    esac ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Conversion failed! 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if errorlevel 1 goto copy41
echo %*| findstr /C:"2.mp4" >nul
if not errorlevel 1 ( echo Stream map '0:a:0' matches no streams. 1>&2 & exit /b 1 )
exit /b 0
:copy41
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk41
if "%~1"=="" goto done41
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk41
:done41
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VMX="$tmp/vault-mixed-probe"
make_ig_vault "$VMX" MXPR041
run_tool "$VMX" >"$tmp/mixedprobe.out" 2>"$tmp/mixedprobe.err"
assert "mixed-probe run exit 0" 0 "$?"
n="$(grep -cF '![[Clippings/_media/clip/slide-' "$VMX/Clippings/clip.md")"
assert "mixed-probe: 2 slide embeds (image + screenshot of 2.mp4)" 2 "$n"
grep -q '^media_enrichment_status: partial$' "$VMX/Clippings/clip.md" && a=ok || a=no
assert "mixed-probe: partial (3.mp4 transcript genuinely lost)" ok "$a"
grep -qF "2/2 slides, 0/1 transcripts" "$tmp/mixedprobe.out" && a=ok || a=no
assert "mixed-probe: outcome line 2/2 slides, 0/1 transcripts" ok "$a"

# --- Test 42: frame-extract TIMEOUT after a conclusive probe -> traced +
#     partial (codex-adv round 3). IG_MEDIA_FFMPEG_TIMEOUT=1 seams the 300s
#     constant; the stub hangs only on the -frames:v call (exec sleep - the
#     Git-Bash grandchild-reaping trap).
echo "Test 42: frame-extract timeout traced, stays partial (HIMMEL-786)"
emit_gallery_dl 1.jpg 2.mp4
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -vn "*) echo "Output file does not contain any stream" >&2; exit 1 ;;
  *" 0:a:0 "*) echo "Stream map '0:a:0' matches no streams." >&2; exit 1 ;;
  *" -frames:v "*) exec sleep 5 ;;
esac
src=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-i" ] && src="$a"
  prev="$a"; last="$a"
done
exec cp "$src" "$last"
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"-vn" >nul
if not errorlevel 1 ( echo Output file does not contain any stream 1>&2 & exit /b 1 )
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 ( echo Stream map '0:a:0' matches no streams. 1>&2 & exit /b 1 )
echo %*| findstr /C:"-frames:v" >nul
if not errorlevel 1 ( ping -n 6 127.0.0.1 >nul & exit /b 0 )
setlocal enabledelayedexpansion
set "src="
set "prev="
set "last="
:walk42
if "%~1"=="" goto done42
if "!prev!"=="-i" set "src=%~1"
set "prev=%~1"
set "last=%~1"
shift
goto walk42
:done42
copy /y "!src!" "!last!" >nul
exit /b 0
STUB
VFT="$tmp/vault-frame-timeout"
make_ig_vault "$VFT" FRTO042
IG_MEDIA_FFMPEG_TIMEOUT=1 run_tool "$VFT" >"$tmp/frametimeout.out" 2>"$tmp/frametimeout.err"
assert "frame-timeout run exit 0" 0 "$?"
grep -q '^media_enrichment_status: partial$' "$VFT/Clippings/clip.md" && a=ok || a=no
assert "frame-timeout: stays partial" ok "$a"
grep -q 'ffmpeg(frame): timed out' "$tmp/frametimeout.err" && a=ok || a=no
assert "frame-timeout: timeout traced (ffmpeg(frame))" ok "$a"

echo ""
echo "ig-media-enrich tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
