#!/usr/bin/env bash
# Tests for x-media-fetch.py (HIMMEL-1226). Hermetic: NO live network, NO
# gallery-dl/ffmpeg/whisper. The tool runs under `uv run --python 3.12 python`
# (Windows bare python3 is a flaky Store stub); the harness prepends a "$tmp/bin"
# dir carrying stubs for uv / gallery-dl / ffmpeg (bash + Windows .bat twins,
# because win32 python's subprocess/shutil.which resolves .bat via PATHEXT but
# NOT an extensionless bash script). The uv stub branches on *transcribe.py* (a
# fixed whisper transcript) and otherwise strips the uv args through the explicit
# `python` token and exec's the real python. X_TEST_NO_AUDIO drives the soundless
# GIF-like path: uv transcribe emits EMPTY (whisper "fails") and ffmpeg's audio
# probe reports "matches no streams", so the first-frame screenshot fallback runs.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
TOOL="$TOOLS_DIR/x-media-fetch.py"

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# --- uv stub (bash + .bat). ASCII only. ------------------------------------
cat > "$tmp/bin/uv" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *transcribe.py*)
    if [ -n "${X_TEST_NO_AUDIO:-}" ]; then exit 0; fi
    exec echo "THIS IS THE FIXED TRANSCRIPT" ;;
  *)
    while [ $# -gt 0 ] && [ "$1" != "python" ]; do shift; done
    [ $# -gt 0 ] || { echo "uv-stub: no python token in: $*" >&2; exit 9; }
    shift
    exec python "$@" ;;
esac
STUB
chmod +x "$tmp/bin/uv"
cat > "$tmp/bin/uv.bat" <<'STUB'
@echo off
setlocal enabledelayedexpansion
echo %*| findstr /C:"transcribe.py" >nul
if not errorlevel 1 (
  if defined X_TEST_NO_AUDIO ( exit /b 0 )
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

export PATH="$tmp/bin:$PATH"

run_tool() { PYTHONUTF8=1 uv run --python 3.12 python "$TOOL" "$@"; }

# --- ffmpeg stub (bash + .bat). Creates the output file (last arg); for the
# audio probe (-map 0:a:0) reports "matches no streams" when X_TEST_NO_AUDIO is
# set (else "has audio"). This is what steers the soundless-GIF screenshot path.
cat > "$tmp/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"0:a:0"*)
    if [ -n "${X_TEST_NO_AUDIO:-}" ]; then
      echo "Stream map 0:a:0 matches no streams." >&2
      exit 1
    fi
    exit 0 ;;
esac
for last in "$@"; do :; done
: > "$last"
exit 0
STUB
chmod +x "$tmp/bin/ffmpeg"
cat > "$tmp/bin/ffmpeg.bat" <<'STUB'
@echo off
echo %*| findstr /C:"0:a:0" >nul
if not errorlevel 1 (
  REM exit /b 1 inside a parenthesized block returns 0 to the parent on some
  REM cmd.exe builds; `exit 1` (full cmd exit) propagates the non-zero code the
  REM tool's _has_audio_stream needs to take the soundless screenshot path.
  if defined X_TEST_NO_AUDIO ( echo Stream map 0:a:0 matches no streams. 1>&2 & exit 1 )
  exit /b 0
)
:findlast
if not "%~2"=="" ( shift & goto findlast )
type nul > "%~1"
exit /b 0
STUB

# gallery-dl stub factory: emits the named files into -D dest (bash + .bat).
# shellcheck disable=SC2016
emit_gallery_dl() {
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

# fail_gallery_dl MESSAGE: exit 1 printing MESSAGE, no media (bash + .bat).
fail_gallery_dl() {
  local msg="$1"
  cat > "$tmp/bin/gallery-dl" <<STUB
#!/usr/bin/env bash
echo "$msg" >&2
exit 1
STUB
  chmod +x "$tmp/bin/gallery-dl"
  cat > "$tmp/bin/gallery-dl.bat" <<STUB
@echo off
echo $msg 1>&2
exit /b 1
STUB
}

# make_x_vault DIR ID BODYMEDIA: single X clip whose body carries BODYMEDIA.
make_x_vault() {
  local dir="$1" id="$2" media="$3"
  mkdir -p "$dir/Clippings"
  cat > "$dir/Clippings/clip.md" <<EOF
---
title: "x clip"
source: "https://x.com/someuser/status/$id"
type: tweet
harvest_skill: clip-body
---
# Tweet by @someuser

Some tweet text.

$media

## Source
[link](https://x.com/someuser/status/$id)
EOF
}

VIDEO_MEDIA='<video preload="auto" src="https://video.twimg.com/tweet_video/HJKyJvDakAA1jt8.mp4" type="video/mp4"></video>'
IMAGE_MEDIA='![Image](https://pbs.twimg.com/media/HJLs0KcaIAAdStu?format=jpg&name=large)'

export X_MEDIA_NO_SLEEP=1

# --- Test 1: dry-run selection ---------------------------------------------
echo "Test 1: dry-run selection predicate"
V="$tmp/vault"
mkdir -p "$V/Clippings"
# (a) X video clip -> SELECTED
cat > "$V/Clippings/a-video.md" <<EOF
---
title: "a video"
source: "https://x.com/u/status/111"
type: tweet
---
# a video
$VIDEO_MEDIA

## Source
EOF
# (b) X image clip -> SELECTED
cat > "$V/Clippings/b-image.md" <<EOF
---
title: "b image"
source: "https://twitter.com/u/status/222"
type: tweet
---
# b image
$IMAGE_MEDIA

## Source
EOF
# (c) already media-enriched -> SKIPPED
cat > "$V/Clippings/c-done.md" <<EOF
---
title: "c done"
source: "https://x.com/u/status/333"
type: tweet
media_enriched_at: 2026-01-01
---
# c done
$VIDEO_MEDIA
EOF
# (d) non-X (instagram) -> SKIPPED
cat > "$V/Clippings/d-ig.md" <<EOF
---
title: "d ig"
source: "https://www.instagram.com/reel/AAA/"
type: instagram
---
# d ig
$VIDEO_MEDIA
EOF
# (e) X text-only (no twimg media) -> SKIPPED
cat > "$V/Clippings/e-text.md" <<EOF
---
title: "e text"
source: "https://x.com/u/status/555"
type: tweet
---
# e text
Just words, no media.
EOF

declare -A before
for f in a-video b-image c-done d-ig e-text; do
  before[$f]="$(sha256sum "$V/Clippings/$f.md" | cut -d' ' -f1)"
done
run_tool "$V" --dry-run >"$tmp/plan.out" 2>"$tmp/plan.err"
assert "--dry-run exit 0" 0 "$?"
nplan="$(grep -c '^PLAN ' "$tmp/plan.out")"
assert "exactly 2 clips planned" 2 "$nplan"
grep -q '^PLAN Clippings/a-video.md -- would fetch status/111 \[dry-run\]$' "$tmp/plan.out" && a=ok || a=no
assert "(a) X video planned" ok "$a"
grep -q '^PLAN Clippings/b-image.md -- would fetch status/222 \[dry-run\]$' "$tmp/plan.out" && a=ok || a=no
assert "(b) X image planned" ok "$a"
grep -q 'c-done.md' "$tmp/plan.out" && a=present || a=absent; assert "(c) already-enriched NOT planned" absent "$a"
grep -q 'd-ig.md' "$tmp/plan.out" && a=present || a=absent; assert "(d) instagram NOT planned" absent "$a"
grep -q 'e-text.md' "$tmp/plan.out" && a=present || a=absent; assert "(e) text-only X NOT planned" absent "$a"

# --- Test 2: dry-run byte-identity -----------------------------------------
echo "Test 2: dry-run byte-identity"
for f in a-video b-image c-done d-ig e-text; do
  after="$(sha256sum "$V/Clippings/$f.md" | cut -d' ' -f1)"
  assert "$f.md byte-identical after dry-run" "${before[$f]}" "$after"
done

# --- HOME + cookies for Tests 3+ -------------------------------------------
HOME="$tmp/home"; mkdir -p "$HOME/.luna/cookies"; export HOME

# --- Test 3: missing cookie file -> exit 2 with twitter.txt + Cookie-Editor -
echo "Test 3: missing cookie file"
emit_gallery_dl 1.jpg
run_tool "$V" >"$tmp/no-cookie.out" 2>"$tmp/no-cookie.err"
assert "missing cookie exit 2" 2 "$?"
grep -q "twitter.txt" "$tmp/no-cookie.err" && a=ok || a=no
assert "stderr mentions twitter.txt" ok "$a"
grep -q "Cookie-Editor" "$tmp/no-cookie.err" && a=ok || a=no
assert "stderr mentions Cookie-Editor" ok "$a"

echo "DUMMY_COOKIES" > "$HOME/.luna/cookies/twitter.txt"
chmod 600 "$HOME/.luna/cookies/twitter.txt"

# --- Test 4: image download -> slide write + outcome + pending-digest -------
echo "Test 4: image download -> vault slides"
emit_gallery_dl 1.jpg 2.jpg
VI="$tmp/vault-img"; make_x_vault "$VI" 444 "$IMAGE_MEDIA"
run_tool "$VI" >"$tmp/img.out" 2>"$tmp/img.err"
assert "image run exit 0" 0 "$?"
grep -qF "Clippings/clip.md: 2 slides + 0 transcript" "$tmp/img.out" && a=ok || a=no
assert "outcome line 2 slides + 0 transcript" ok "$a"
# Media dir is namespaced <stem>-<status-id> (codex-adv collision fix): clip.md + status 444.
n="$(grep -cF '![[Clippings/_media/clip-444/slide-' "$VI/Clippings/clip.md")"
assert "2 slide embeds under ### Slides" 2 "$n"
[ -f "$VI/Clippings/_media/clip-444/slide-02.jpg" ] && a=ok || a=no
assert "slide-02.jpg copied into vault _media/<stem>-<id>/" ok "$a"
grep -qF '<!-- slides-pending-digest -->' "$VI/Clippings/clip.md" && a=ok || a=no
assert "slides-pending-digest marker present" ok "$a"
grep -q '^media_enriched_at:' "$VI/Clippings/clip.md" && a=ok || a=no
assert "media_enriched_at stamped on success" ok "$a"

# --- Test 5: video with audio -> transcript path ---------------------------
echo "Test 5: video transcript path (audio present)"
emit_gallery_dl video.mp4
VV="$tmp/vault-vid"; make_x_vault "$VV" 555 "$VIDEO_MEDIA"
run_tool "$VV" >"$tmp/vid.out" 2>"$tmp/vid.err"
assert "video run exit 0" 0 "$?"
grep -q '^### Transcript$' "$VV/Clippings/clip.md" && a=ok || a=no
assert "clip gains ### Transcript block" ok "$a"
grep -qF "THIS IS THE FIXED TRANSCRIPT" "$VV/Clippings/clip.md" && a=ok || a=no
assert "transcript text written into clip" ok "$a"
found="$(find "$VV" \( -name '*.mp4' -o -name '*.wav' -o -name '*.webm' \) 2>/dev/null)"
[ -z "$found" ] && a=ok || a=no
assert "no .mp4/.wav/.webm under the vault" ok "$a"

# --- Test 6: soundless GIF-like video -> first-frame screenshot slide -------
echo "Test 6: soundless GIF -> video-frame screenshot slide (the hunt case)"
emit_gallery_dl video.mp4
VG="$tmp/vault-gif"; make_x_vault "$VG" 666 "$VIDEO_MEDIA"
export X_TEST_NO_AUDIO=1   # must be EXPORTED to reach the uv/ffmpeg stub grandchildren
run_tool "$VG" >"$tmp/gif.out" 2>"$tmp/gif.err"
assert "soundless run exit 0" 0 "$?"
unset X_TEST_NO_AUDIO
grep -qF "1 slides (1 video-frame) + 0 transcript" "$tmp/gif.out" && a=ok || a=no
assert "outcome line notes 1 video-frame slide" ok "$a"
n="$(grep -cF '![[Clippings/_media/clip-666/slide-' "$VG/Clippings/clip.md")"
assert "1 screenshot slide embedded" 1 "$n"
[ -f "$VG/Clippings/_media/clip-666/slide-01.jpg" ] && a=ok || a=no
assert "slide-01.jpg (frame) copied into vault _media/<stem>-<id>/" ok "$a"
grep -qF '<!-- slides-pending-digest -->' "$VG/Clippings/clip.md" && a=ok || a=no
assert "soundless clip carries pending-digest marker" ok "$a"
found="$(find "$VG" \( -name '*.mp4' -o -name '*.wav' \) 2>/dev/null)"
[ -z "$found" ] && a=ok || a=no
assert "no video/wav under the vault (soundless path)" ok "$a"

# --- Test 7: removed (404) -> permanent, releases x_media_pending -----------
echo "Test 7: download error taxonomy (removed / permanent)"
VR="$tmp/vault-removed"
mkdir -p "$VR/Clippings"
cat > "$VR/Clippings/clip.md" <<EOF
---
title: "removed"
source: "https://x.com/u/status/777"
type: tweet
x_media_pending: true
---
# removed
$VIDEO_MEDIA
EOF
fail_gallery_dl "HTTP Error 404: Not Found"
run_tool "$VR" >"$tmp/removed.out" 2>"$tmp/removed.err"
assert "removed run exit 0" 0 "$?"
grep -q '^media_enrichment_status: failed$' "$VR/Clippings/clip.md" && a=ok || a=no
assert "removed status failed" ok "$a"
grep -q '^media_last_error: removed$' "$VR/Clippings/clip.md" && a=ok || a=no
assert "removed last_error removed" ok "$a"
grep -q '^media_enriched_at:' "$VR/Clippings/clip.md" && a=present || a=absent
assert "removed enriched_at set (permanent)" present "$a"
grep -q '^x_media_pending:' "$VR/Clippings/clip.md" && a=present || a=absent
assert "x_media_pending released on permanent failure" absent "$a"

# --- Test 8: login_wall -> retryable, parks x_media_pending ----------------
echo "Test 8: download error taxonomy (login wall / retryable)"
VL="$tmp/vault-login"; make_x_vault "$VL" 888 "$VIDEO_MEDIA"
fail_gallery_dl "login required"
run_tool "$VL" >"$tmp/login.out" 2>"$tmp/login.err"
assert "login run exit 0" 0 "$?"
grep -q '^media_last_error: login_wall$' "$VL/Clippings/clip.md" && a=ok || a=no
assert "login last_error login_wall (retryable)" ok "$a"
grep -q '^media_enriched_at:' "$VL/Clippings/clip.md" && a=present || a=absent
assert "login enriched_at NOT set (retryable)" absent "$a"
grep -q '^x_media_pending: true$' "$VL/Clippings/clip.md" && a=ok || a=no
assert "x_media_pending parked on retryable failure" ok "$a"

# --- Test 9: success clears a pre-existing x_media_pending -----------------
echo "Test 9: x_media_pending cleared on verified success"
emit_gallery_dl 1.jpg 2.jpg
VPS="$tmp/vault-pending"
mkdir -p "$VPS/Clippings"
cat > "$VPS/Clippings/clip.md" <<EOF
---
title: "pending ok"
source: "https://x.com/u/status/999"
type: tweet
x_media_pending: true
---
# pending ok
$IMAGE_MEDIA

## Source
EOF
run_tool "$VPS" >"$tmp/pending.out" 2>"$tmp/pending.err"
assert "pending-ok run exit 0" 0 "$?"
grep -q '^media_enrichment_status: ok$' "$VPS/Clippings/clip.md" && a=ok || a=no
assert "success wrote media_enrichment_status: ok" ok "$a"
grep -q '^x_media_pending:' "$VPS/Clippings/clip.md" && a=present || a=absent
assert "x_media_pending cleared on verified success" absent "$a"

# --- Test 10: idempotency -> re-run no-op, byte-identical ------------------
echo "Test 10: re-run idempotency"
sha1="$(sha256sum "$VI/Clippings/clip.md" | cut -d' ' -f1)"
run_tool "$VI" >"$tmp/idem.out" 2>"$tmp/idem.err"
assert "second run exit 0" 0 "$?"
sha2="$(sha256sum "$VI/Clippings/clip.md" | cut -d' ' -f1)"
assert "clip byte-identical after re-run" "$sha1" "$sha2"
grep -q '0 selected, 0 enriched' "$tmp/idem.out" && a=ok || a=no
assert "re-run selects nothing (idempotent)" ok "$a"
nslides="$(grep -c '^### Slides$' "$VI/Clippings/clip.md")"
assert "exactly ONE ### Slides block (no dup)" 1 "$nslides"

# --- Test 11: apply-digest (happy / usage-fail / G-3 violation) ------------
echo "Test 11: apply-digest"
AD="$tmp/vault-apply"; mkdir -p "$AD/Clippings"
cat > "$AD/Clippings/clip.md" <<'EOF'
---
title: "apply"
source: "https://x.com/u/status/1000"
type: tweet
media_enriched_at: 2026-07-20
---
# apply

## Crawled content
<!-- media-enriched 2026-07-20 via x-media -->

### Slides
![[Clippings/_media/clip/slide-01.jpg]]
<!-- slides-pending-digest -->

## Source
[link](https://x.com/u/status/1000)
EOF
fm_before="$(sed -n '/^---$/,/^---$/p' "$AD/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
printf 'Slide 1: dots morphing into the number 7.\n' > "$tmp/digest.txt"
run_tool --apply-digest "$AD/Clippings/clip.md" --digest-file "$tmp/digest.txt" >"$tmp/apply.out" 2>"$tmp/apply.err"
assert "apply-digest exit 0" 0 "$?"
n="$(grep -c '^### Slide digest$' "$AD/Clippings/clip.md")"
assert "exactly one ### Slide digest H3 added" 1 "$n"
grep -qF '<!-- slides-pending-digest -->' "$AD/Clippings/clip.md" && a=present || a=absent
assert "pending marker stripped" absent "$a"
grep -qF "dots morphing into the number 7." "$AD/Clippings/clip.md" && a=ok || a=no
assert "digest text written" ok "$a"
fm_after="$(sed -n '/^---$/,/^---$/p' "$AD/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
assert "frontmatter byte-identical after apply" "$fm_before" "$fm_after"
# usage failure: missing pending marker -> exit 1, no write
AN="$tmp/vault-apply-nomark"; mkdir -p "$AN/Clippings"
cat > "$AN/Clippings/clip.md" <<'EOF'
---
title: "nomark"
source: "https://x.com/u/status/1001"
type: tweet
---
# nomark

## Crawled content
### Slides
![[Clippings/_media/clip/slide-01.jpg]]

## Source
EOF
sha_b="$(sha256sum "$AN/Clippings/clip.md" | cut -d' ' -f1)"
echo "digest" > "$tmp/dg2.txt"
run_tool --apply-digest "$AN/Clippings/clip.md" --digest-file "$tmp/dg2.txt" >"$tmp/apply2.out" 2>"$tmp/apply2.err"
assert "absent-marker exit 1" 1 "$?"
assert "absent-marker clip byte-identical" "$sha_b" "$(sha256sum "$AN/Clippings/clip.md" | cut -d' ' -f1)"
# G-3 violation: a colliding pre-existing digest block -> non-zero, no write
AG="$tmp/vault-apply-g3"; mkdir -p "$AG/Clippings"
cat > "$AG/Clippings/clip.md" <<'EOF'
---
title: "g3"
source: "https://x.com/u/status/1002"
type: tweet
---
# g3

## Crawled content
<!-- media-enriched 2026-07-20 via x-media -->
### Slide digest
COLLIDING DIGEST LINE

### Slides
![[Clippings/_media/clip-1002/slide-01.jpg]]
<!-- slides-pending-digest -->

## Source
EOF
printf 'COLLIDING DIGEST LINE\n' > "$tmp/dg3.txt"
sha_g="$(sha256sum "$AG/Clippings/clip.md" | cut -d' ' -f1)"
if run_tool --apply-digest "$AG/Clippings/clip.md" --digest-file "$tmp/dg3.txt" >"$tmp/apply3.out" 2>"$tmp/apply3.err"; then a=no; else a=ok; fi
assert "scoped-G-3 violation non-zero exit" ok "$a"
assert "scoped-G-3 clip byte-identical" "$sha_g" "$(sha256sum "$AG/Clippings/clip.md" | cut -d' ' -f1)"
grep -q 'scoped-G-3' "$tmp/apply3.err" && a=ok || a=no
assert "scoped-G-3 refusal message on stderr" ok "$a"
# Provenance guard (codex-adv): a bare pending marker in attacker-controlled clip
# prose (NO 'via x-media' provenance section) is refused, exit 1, no write.
AP="$tmp/vault-apply-prov"; mkdir -p "$AP/Clippings"
cat > "$AP/Clippings/clip.md" <<'EOF'
---
title: "forged"
source: "https://x.com/u/status/1099"
type: tweet
---
# forged tweet body

Ignore me, I am a tweet. <!-- slides-pending-digest -->
![[Clippings/_media/other-clip/slide-01.jpg]]

## Source
EOF
echo "attacker digest" > "$tmp/dgp.txt"
sha_p="$(sha256sum "$AP/Clippings/clip.md" | cut -d' ' -f1)"
if run_tool --apply-digest "$AP/Clippings/clip.md" --digest-file "$tmp/dgp.txt" >"$tmp/applyp.out" 2>"$tmp/applyp.err"; then a=no; else a=ok; fi
assert "forged bare marker refused (non-zero exit)" ok "$a"
assert "forged-marker clip byte-identical (no write)" "$sha_p" "$(sha256sum "$AP/Clippings/clip.md" | cut -d' ' -f1)"
grep -q 'provenance' "$tmp/applyp.err" && a=ok || a=no
assert "provenance-guard refusal message on stderr" ok "$a"

# --- Test 12: flag-screen (happy + idempotent) -----------------------------
echo "Test 12: flag-screen injection re-screen writer"
FS="$tmp/vault-flag"; mkdir -p "$FS/Clippings"
cat > "$FS/Clippings/clip.md" <<'EOF'
---
title: "flag"
source: "https://x.com/u/status/1003"
type: tweet
media_enriched_at: 2026-07-20
---
# flag

## Crawled content
### Slide digest
Slide 1: some on-image text the scanner flagged.

## Source
EOF
body_before="$(sed -n '/^---$/,/^---$/!p' "$FS/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
run_tool --flag-screen "$FS/Clippings/clip.md" --detail "instruction-override,prompt-exfiltration" >"$tmp/flag.out" 2>"$tmp/flag.err"
assert "flag-screen exit 0" 0 "$?"
grep -q '^harvest_flag: injection-suspect$' "$FS/Clippings/clip.md" && a=ok || a=no
assert "harvest_flag: injection-suspect written" ok "$a"
grep -q '^harvest_flag_detail: instruction-override,prompt-exfiltration$' "$FS/Clippings/clip.md" && a=ok || a=no
assert "harvest_flag_detail comma-joined classes written" ok "$a"
body_after="$(sed -n '/^---$/,/^---$/!p' "$FS/Clippings/clip.md" | sha256sum | cut -d' ' -f1)"
assert "clip body byte-identical after flag write (G-3)" "$body_before" "$body_after"
run_tool --flag-screen "$FS/Clippings/clip.md" --detail "screen-error" >"$tmp/flag2.out" 2>"$tmp/flag2.err"
assert "flag-screen re-run exit 0" 0 "$?"
nflag="$(grep -c '^harvest_flag:' "$FS/Clippings/clip.md")"
assert "exactly ONE harvest_flag key (no dup)" 1 "$nflag"

# --- Test 13: --include-done backfill boundary -----------------------------
echo "Test 13: --include-done backfill boundary (dry-run)"
VD="$tmp/vault-done"
mkdir -p "$VD/Clippings/_done/2026-05"
cat > "$VD/Clippings/_done/2026-05/graduated.md" <<EOF
---
title: "graduated"
source: "https://x.com/u/status/1004"
type: tweet
---
# graduated
$VIDEO_MEDIA
EOF
# default run: _done/ invisible
run_tool "$VD" --dry-run >"$tmp/done-def.out" 2>"$tmp/done-def.err"
grep -q 'graduated.md' "$tmp/done-def.out" && a=present || a=absent
assert "default run does NOT plan _done/ clip" absent "$a"
# --include-done: _done/ scanned
run_tool "$VD" --include-done --dry-run >"$tmp/done-inc.out" 2>"$tmp/done-inc.err"
grep -q 'graduated.md' "$tmp/done-inc.out" && a=ok || a=no
assert "--include-done PLANS the _done/ clip" ok "$a"
# Orthogonality (CR [codex-1]): --include-done must NOT pull in the _evidence
# pool - that stays gated behind --include-evidence.
mkdir -p "$VD/Clippings/_evidence"
cat > "$VD/Clippings/_evidence/parked.md" <<EOF
---
title: "parked ev"
source: "https://x.com/u/status/1005"
type: tweet
---
# parked
$VIDEO_MEDIA
EOF
run_tool "$VD" --include-done --dry-run >"$tmp/done-only.out" 2>"$tmp/done-only.err"
grep -q 'parked.md' "$tmp/done-only.out" && a=present || a=absent
assert "--include-done alone does NOT plan the _evidence clip (orthogonal)" absent "$a"
run_tool "$VD" --include-evidence --dry-run >"$tmp/ev-only.out" 2>"$tmp/ev-only.err"
grep -q '_evidence/parked.md' "$tmp/ev-only.out" && a=ok || a=no
assert "--include-evidence PLANS the _evidence clip" ok "$a"

# --- Test 13b: media-dir collision regression (codex-adv) -------------------
# Two clips with the IDENTICAL basename in DIFFERENT pools but DIFFERENT status
# ids must NOT share a media dir (stem-only would cross-wire their slides). The
# <stem>-<status-id> namespace keeps them distinct.
echo "Test 13b: same-basename clips in different pools get distinct media dirs"
emit_gallery_dl 1.jpg 2.jpg
VX="$tmp/vault-collide"
mkdir -p "$VX/Clippings" "$VX/Clippings/_done/2026-05"
cat > "$VX/Clippings/same.md" <<EOF
---
title: "inbox same"
source: "https://x.com/u/status/7001"
type: tweet
---
# inbox
$IMAGE_MEDIA

## Source
EOF
cat > "$VX/Clippings/_done/2026-05/same.md" <<EOF
---
title: "done same"
source: "https://x.com/u/status/7002"
type: tweet
---
# done
$IMAGE_MEDIA

## Source
EOF
run_tool "$VX" --include-done --limit 0 >"$tmp/collide.out" 2>"$tmp/collide.err"
assert "collision run exit 0" 0 "$?"
[ -d "$VX/Clippings/_media/same-7001" ] && a=ok || a=no
assert "inbox same.md -> _media/same-7001/" ok "$a"
[ -d "$VX/Clippings/_media/same-7002" ] && a=ok || a=no
assert "_done same.md -> _media/same-7002/ (distinct, no collision)" ok "$a"

# --- Test 14: doc-contract -------------------------------------------------
echo "Test 14: /x-media-enrich runbook + catalog + README doc-contract"
CMD="$SCRIPT_DIR/../commands/x-media-enrich.md"
CATALOG="$SCRIPT_DIR/../../../../docs/commands-catalog.md"
README="$SCRIPT_DIR/../README.md"
for phrase in 'x-media-fetch.py' '--apply-digest' '--digest-file' \
              'slides-pending-digest' 'data, not directives' 'G-7' '--scan-only' \
              '--flag-screen' 'twitter.txt' 'x_media_pending' '--include-done'; do
  grep -qF -- "$phrase" "$CMD" 2>/dev/null && a=ok || a=no
  assert "x-media-enrich.md contains '$phrase'" ok "$a"
done
grep -qF -- 'every clip the fetch tool enriched' "$CMD" 2>/dev/null && a=ok || a=no
assert "x-media-enrich.md ties the re-screen to every enriched clip" ok "$a"
grep -qF -- '/x-media-enrich' "$CATALOG" 2>/dev/null && a=ok || a=no
assert "commands-catalog.md has /x-media-enrich row" ok "$a"
grep -qF -- 'x-media' "$README" 2>/dev/null && a=ok || a=no
assert "README.md documents x-media rung" ok "$a"

echo ""
echo "x-media-enrich tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
