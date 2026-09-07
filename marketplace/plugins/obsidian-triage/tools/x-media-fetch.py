#!/usr/bin/env python3
"""x-media-fetch.py - deterministic X/Twitter media enrichment rung (HIMMEL-1226).

Parity sibling of ig-media-fetch.py (HIMMEL-770). The clip harvest pipeline
stores a tweet's TEXT + media metadata only: X media is referenced by URL
(`<video ... src="https://video.twimg.com/...">`, `![Image](https://pbs.twimg.com/media/...)`)
and NEVER downloaded, so a tweet whose substance is the media (a video/GIF demo,
an animated UI element, a caption-less visual) leaves nothing searchable behind.
This rung captures it. For X clips whose body carries a video.twimg.com /
pbs.twimg.com/media/ reference and which carry no media_enriched_at: marker:

  - Download the tweet's media via gallery-dl (burner-account cookies).
  - Video items (incl. GIF-like tweet_video): ffmpeg -> mono 16kHz WAV -> local
    faster-whisper transcript. A SOUNDLESS video (the common tweet_video GIF -
    e.g. an animated UI element) has no audio to transcribe, so its first frame
    is screenshotted into the vault as a slide instead, then vision-digested -
    this is the path that recovers the purely-visual X ideas.
  - Image items: ffmpeg recompress <=1600px JPEG, copy into the vault at
    Clippings/_media/<clip-slug>/slide-NN.jpg, embed under ### Slides.
  - Videos NEVER enter the vault; only the transcript TEXT (or a screenshot
    frame for a soundless GIF) is written.
  - Write ONE ## Crawled content section (create, or extend the existing one)
    under the media_* marker namespace: media_enriched_at / media_enrichment_status
    / media_last_error. Scoped-G-3: everything outside the tool-owned region is
    byte-identical post-write, else revert.
  - Retryable failures park the clip with x_media_pending: true (parity with the
    IG rung's ig_media_pending); a verified success clears it.

  --apply-digest <clip> --digest-file <tmp>: the mechanical slide-digest applier
    (agent reads images/frames, tool writes the ### Slide digest H3 + strips the
    pending marker). Scoped-G-3 (reconstruction check + fm_raw hash immutability)
    + revert-on-failure.

Downloader NEVER prints cookie contents. Media/audio/transcripts never leave the
machine. Run under `uv run --python 3.12` (Windows python3 is a flaky Store stub).

Exit codes: 0 run completed (may include failed/partial clips), 1 bad usage,
2 preflight (missing gallery-dl/ffmpeg or cookie file), 3 scoped-G-3 verify
failed / reverted (used by --apply-digest and --flag-screen).
"""
import argparse
import datetime
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TODAY = datetime.date.today().isoformat()
# Anchored provenance detector (codex-adv HIMMEL-1235): a real x-media
# provenance comment occupies its own line. A bare substring match (e.g.
# "via x-media -->" anywhere in the text) is defeatable by untrusted
# crawled/tweet prose that happens to contain that literal string, so every
# provenance-detection site shares THIS anchored full-line check instead.
PROV_RE = re.compile(r"(?m)^<!-- media-enriched \S+ via x-media -->[ \t]*$")
RATE_LIMIT_S = 0 if os.environ.get("X_MEDIA_NO_SLEEP") else 10
DEFAULT_LIMIT = 10
SLIDE_CAP = 20
LONG_EDGE_MAX = 1600
DEFAULT_WHISPER_MODEL = "base"
DOWNLOAD_TIMEOUT = 180
FFMPEG_TIMEOUT = int(os.environ.get("X_MEDIA_FFMPEG_TIMEOUT", "300"))
# Separate seam for the soundless-video frame-extract subprocess (mirrors the IG
# rung's HIMMEL-805 seam): FFMPEG_TIMEOUT is GLOBAL - it also guards extract_wav,
# the audio probe, and recompress_slide - so cranking it down to trace the
# frame-extract timeout races the faster probe/wav/recompress calls. FRAME_TIMEOUT
# defaults to FFMPEG_TIMEOUT (behavior unchanged when unset) and seams ONLY
# soundless_video_frame's frame-extract subprocess.
FRAME_TIMEOUT = int(os.environ.get("X_MEDIA_FRAME_TIMEOUT", str(FFMPEG_TIMEOUT)))
WHISPER_TIMEOUT = 1800

# x.com / twitter.com /<user>/status/<id> (mobile. and www. tolerated).
X_URL_RE = re.compile(
    r"^https?://(?:www\.|mobile\.|m\.)?(?:x|twitter)\.com/([^/]+)/status/(\d+)"
)
# Selection predicate: the clip body carries downloadable X media - a video, or a
# real media image (NOT a bare pbs.twimg.com/*_thumb/ poster, which only implies
# a video already caught by video.twimg.com).
TWIMG_MEDIA_RE = re.compile(r"video\.twimg\.com|pbs\.twimg\.com/media/")
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm"}

MEDIA_KEYS = ["media_enriched_at", "media_enrichment_status", "media_last_error"]
HARVEST_FLAG_KEYS = ["harvest_flag", "harvest_flag_detail"]


# --- frontmatter (mirrors ig-media-fetch.py) -------------------------------
def parse_frontmatter(text: str):
    if not text.startswith("---\n"):
        return None, "", text, False
    end = text.find("\n---\n", 4)
    if end < 0:
        return None, "", text, False
    fm_raw = text[4:end]
    body = text[end + 5:]
    fm = {}
    for line in fm_raw.split("\n"):
        m = re.match(r"^([a-zA-Z_][a-zA-Z0-9_]*):(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm, fm_raw, body, True


def read_clip(path: Path):
    """Read a clip; normalize CRLF -> LF for ALL internal processing (parked X
    clips may be CRLF; an LF-only parse would silently skip them and defeat the
    backfill). Returns (text, has_crlf). Read with newline="" (NOT read_text,
    whose universal-newline translation would strip every \r before the has_crlf
    test and silently downgrade a CRLF clip to LF on re-emit)."""
    with path.open("r", encoding="utf-8", newline="") as f:
        raw = f.read()
    has_crlf = "\r\n" in raw
    return (raw.replace("\r\n", "\n") if has_crlf else raw), has_crlf


def write_clip(path: Path, text: str, has_crlf: bool):
    """Write a clip, re-emitting CRLF when the original used it. ATOMIC
    (codex-adv HIMMEL-1226): write to a temp file in the SAME directory, fsync,
    then os.replace() onto the destination - so a mid-write crash / disk-full /
    I/O error can never truncate the existing note (a bare write_text truncates
    before writing, and the G-3 revert never runs when the write call itself
    dies). os.replace is atomic within a filesystem on POSIX and Windows."""
    out = text.replace("\n", "\r\n") if has_crlf else text
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".x-media-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(out)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def is_x_source(src: str):
    """Return {"shortcode": <status-id>, "url": <canonical x.com url>} for an
    x.com/twitter.com status source, else None. shortcode is the numeric status
    id (the per-tweet cache/dir key)."""
    m = X_URL_RE.match((src or "").strip().strip('"'))
    if not m:
        return None
    user, status_id = m.group(1), m.group(2)
    return {"shortcode": status_id,
            "url": f"https://x.com/{user}/status/{status_id}"}


def _has_twimg_media(body: str) -> bool:
    """The clip body references at least one downloadable X media item."""
    return TWIMG_MEDIA_RE.search(body) is not None


def already_media_enriched(fm_raw: str) -> bool:
    return bool(re.search(r"^media_enriched_at:[\s]*\S", fm_raw, re.MULTILINE))


def upsert_media_markers(fm_raw: str, markers: dict) -> str:
    """Replace any existing media_* key in place; append the rest after the last
    non-empty frontmatter line. A None value drops the key."""
    lines = fm_raw.split("\n")
    seen = set()
    out = []
    for line in lines:
        matched = None
        for k in MEDIA_KEYS:
            if line.startswith(k + ":"):
                matched = k
                break
        if matched is None:
            out.append(line)
            continue
        seen.add(matched)
        if markers.get(matched) is None:
            continue
        out.append(f"{matched}: {markers[matched]}")
    insert_idx = len(out)
    for i in range(len(out) - 1, -1, -1):
        if out[i].strip():
            insert_idx = i + 1
            break
    tail = []
    for k in MEDIA_KEYS:
        if k in seen or markers.get(k) is None:
            continue
        tail.append(f"{k}: {markers[k]}")
    return "\n".join(out[:insert_idx] + tail + out[insert_idx:])


def upsert_harvest_flag(fm_raw: str, detail: str) -> str:
    """Replace any existing harvest_flag / harvest_flag_detail line in place;
    append the pair after the last non-empty frontmatter line otherwise.
    Idempotent: a re-screen replaces the flag rather than duplicating the key."""
    markers = {"harvest_flag": "injection-suspect", "harvest_flag_detail": detail}
    lines = fm_raw.split("\n")
    seen = set()
    out = []
    for line in lines:
        matched = None
        for k in HARVEST_FLAG_KEYS:
            if line.startswith(k + ":"):
                matched = k
                break
        if matched is None:
            out.append(line)
            continue
        seen.add(matched)
        out.append(f"{matched}: {markers[matched]}")
    insert_idx = len(out)
    for i in range(len(out) - 1, -1, -1):
        if out[i].strip():
            insert_idx = i + 1
            break
    tail = [f"{k}: {markers[k]}" for k in HARVEST_FLAG_KEYS if k not in seen]
    return "\n".join(out[:insert_idx] + tail + out[insert_idx:])


def set_x_media_pending(fm_raw: str) -> str:
    """Set x_media_pending: true (idempotent - replace in place, else append
    after the last non-empty frontmatter line). Unlike the IG rung - where the
    HARVEST layer parks ig_media_pending - X selection is body-twimg-based, so
    THIS rung parks a retryable/partial X clip with x_media_pending: true as an
    operator breadcrumb (the clip stays selectable regardless, since it carries
    no media_enriched_at)."""
    lines = fm_raw.split("\n")
    for i, ln in enumerate(lines):
        if ln.startswith("x_media_pending:"):
            lines[i] = "x_media_pending: true"
            return "\n".join(lines)
    insert_idx = len(lines)
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip():
            insert_idx = i + 1
            break
    return "\n".join(lines[:insert_idx] + ["x_media_pending: true"]
                     + lines[insert_idx:])


def drop_x_media_pending(fm_raw: str) -> str:
    """Remove any x_media_pending: line from the frontmatter. A verified
    enrichment success (or a permanent failure that releases the clip) clears the
    breadcrumb. Frontmatter-only; no-op when absent."""
    lines = [ln for ln in fm_raw.split("\n")
             if not ln.startswith("x_media_pending:")]
    return "\n".join(lines)


# --- cache + preflight + download -----------------------------------------------
def _emit_stderr_tail(label: str, stderr: str):
    """Emit a one-line, truncated (~200 char) tail of a failed subprocess'
    stderr so a silent tool failure is diagnosable instead of collapsing to a
    bare taxonomy token."""
    tail = (stderr or "").strip().replace("\n", " ")
    if tail:
        print(f"{label}: {tail[-200:]}", file=sys.stderr)


def _home() -> Path:
    home = os.environ.get("HOME")
    return Path(home) if home else Path.home()


def cookie_file() -> Path:
    return _home() / ".luna" / "cookies" / "twitter.txt"


def cache_root() -> Path:
    return _home() / ".luna" / "x-media"


def preflight():
    missing = [b for b in ("gallery-dl", "ffmpeg") if shutil.which(b) is None]
    if missing:
        print(
            "x-media-fetch: missing required binaries: " + ", ".join(missing) +
            "\n  install: winget install yt-dlp.gallery-dl ; winget install "
            "Gyan.FFmpeg   (or: uv tool install gallery-dl)",
            file=sys.stderr,
        )
        sys.exit(2)
    cf = cookie_file()
    if not cf.is_file():
        print(
            "x-media-fetch: cookie file missing: " + str(cf) +
            "\n  Export x.com cookies (logged into your BURNER account) with the "
            "Cookie-Editor extension in Netscape format, save to that path, then "
            "chmod 600 it. (Cookie contents are never printed.)",
            file=sys.stderr,
        )
        sys.exit(2)
    return cf


def _natural_key(p: Path):
    """Natural-sort key: split the filename into digit / non-digit runs and
    compare digit runs numerically, so gallery-dl's UNPADDED media filenames
    order 1 < 2 < 10. A plain lexicographic sort puts 10.jpg before 2.jpg,
    corrupting media order AND the mixed-tweet video item indices."""
    return [int(t) if t.isdigit() else t.lower()
            for t in re.split(r"(\d+)", p.name)]


def download_media(x: dict, cf: Path):
    dest = cache_root() / x["shortcode"]
    if dest.exists():
        shutil.rmtree(dest)   # a prior partial run must not leave stale files
    dest.mkdir(parents=True)  # fresh dir: classify sees ONLY this download
    gallery_dl = shutil.which("gallery-dl")
    if not gallery_dl:
        return None, "gallery_dl_missing"
    cmd = [gallery_dl, "--cookies", str(cf), "-D", str(dest), x["url"]]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=DOWNLOAD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, "download_timeout"
    if proc.returncode != 0:
        blob = (proc.stderr + proc.stdout).lower()
        if "404" in blob or "not found" in blob or "removed" in blob:
            return None, "removed"          # permanent
        if "login" in blob or "challenge" in blob or "403" in blob:
            return None, "login_wall"       # retryable
        _emit_stderr_tail("gallery-dl", proc.stderr)
        return None, "download_error"       # retryable
    files = sorted((p for p in dest.iterdir()
                    if p.is_file() and p.suffix.lower() in IMAGE_EXTS | VIDEO_EXTS),
                   key=_natural_key)
    if not files:
        return None, "no_media"             # retryable
    return files, None


def classify(files):
    return {
        "images": [f for f in files if f.suffix.lower() in IMAGE_EXTS],
        "videos": [f for f in files if f.suffix.lower() in VIDEO_EXTS],
    }


def _media_dir(vault: Path, slug: str) -> Path:
    return vault / "Clippings" / "_media" / slug


def write_markers(path: Path, text: str, fm_raw: str, body: str, has_crlf: bool,
                  status: str, error: str, permanent: bool):
    """Write frontmatter-only with media enrichment markers. Re-reads after the
    write and verifies the BODY is byte-for-byte identical to the pre-write body
    (Scoped-G-3) and that the frontmatter parses carrying every marker key just
    written. Reverts and returns False on any mismatch; True on a verified write.

    permanent=True (removed/404): stamp media_enriched_at (the media is gone, so
    the clip converges) and RELEASE x_media_pending. A retryable failure instead
    PARKS x_media_pending: true so the clip is retried on a later run."""
    markers = {}
    if status:
        markers["media_enrichment_status"] = status
    if error:
        markers["media_last_error"] = error
    if permanent:
        markers["media_enriched_at"] = TODAY
    new_fm_raw = upsert_media_markers(fm_raw, markers)
    if permanent:
        new_fm_raw = drop_x_media_pending(new_fm_raw)
    else:
        new_fm_raw = set_x_media_pending(new_fm_raw)
    new_text = f"---\n{new_fm_raw}\n---\n{body}"
    write_clip(path, new_text, has_crlf)
    disk_text, _ = read_clip(path)
    disk_fm, _, disk_body, disk_present = parse_frontmatter(disk_text)
    if not (disk_present and disk_body == body
            and all(k in disk_fm for k in markers)):
        write_clip(path, text, has_crlf)   # revert outside-region drift
        return False
    return True


# --- video transcript (ffmpeg WAV + faster-whisper via uv) ------------------
def extract_wav(video: Path, wav: Path) -> bool:
    """Transcode video -> mono 16kHz WAV. The WAV lives in a caller-owned temp
    dir; the video NEVER enters the vault. Resolve ffmpeg via shutil.which so a
    PATHEXT-shimmed binary (Windows .bat) is honored."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return False
    cmd = [ffmpeg, "-y", "-i", str(video), "-ac", "1", "-ar", "16000",
           "-vn", str(wav)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=FFMPEG_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False
    if p.returncode != 0:
        _emit_stderr_tail("ffmpeg(wav)", p.stderr)
        return False
    return wav.is_file()


def whisper_transcribe(wav: Path, model: str):
    """Run the sibling transcribe.py under `uv run --python 3.12` with
    faster-whisper; return the stripped stdout transcript, or None on failure."""
    helper = Path(__file__).with_name("transcribe.py")
    uv = shutil.which("uv")
    if not uv:
        return None
    cmd = [uv, "run", "--python", "3.12", "--with", "faster-whisper",
           "python", str(helper), str(wav), model]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=WHISPER_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None
    if p.returncode != 0:
        _emit_stderr_tail("whisper", p.stderr)
        return None
    return p.stdout.strip() or None


def _has_audio_stream(video: Path) -> bool:
    """True if the video carries an audio stream (probe: decode one audio frame
    via -map 0:a:0 -f null). Returns False ONLY on conclusive proof - ffmpeg
    reporting the 0:a:0 map "matches no streams". Every other failure (no ffmpeg,
    timeout, decode error, corrupt media) reports True so the caller keeps the
    conservative failed/partial path instead of silently replacing a lost
    transcript with a screenshot. The probe subprocess is pinned to LC_ALL=C/
    LANG=C so the substring match is locale-independent - the env override is
    load-bearing; a localized ffmpeg build would otherwise disable the fallback."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return True
    cmd = [ffmpeg, "-i", str(video), "-map", "0:a:0", "-frames:a", "1",
           "-f", "null", "-"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=FFMPEG_TIMEOUT,
                           env={**os.environ, "LC_ALL": "C", "LANG": "C"})
    except subprocess.TimeoutExpired:
        print(f"ffmpeg(probe): timed out after {FFMPEG_TIMEOUT}s",
              file=sys.stderr)
        return True
    if p.returncode == 0:
        return True
    if "matches no streams" in (p.stderr or ""):
        return False
    _emit_stderr_tail("ffmpeg(probe)", p.stderr)   # inconclusive - trace it
    return True


def soundless_video_frame(video: Path):
    """Screenshot fallback for a soundless GIF-like video (the common X
    tweet_video - e.g. an animated UI element): extract the first frame NEXT TO
    the video in the download cache (never the vault; render_slides copies it in)
    and return the frame Path. Returns None when the video has an audio stream
    (genuine transcription failure - caller keeps partial semantics) or the
    extraction fails."""
    if _has_audio_stream(video):
        return None
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    frame = video.with_suffix(".frame.jpg")
    cmd = [ffmpeg, "-y", "-i", str(video), "-frames:v", "1", str(frame)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=FRAME_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"ffmpeg(frame): timed out after {FRAME_TIMEOUT}s",
              file=sys.stderr)
        return None
    if p.returncode != 0:
        _emit_stderr_tail("ffmpeg(frame)", p.stderr)
        return None
    return frame if frame.is_file() else None


def transcribe_videos(videos, model):
    """videos: list of (item_index, Path) in tweet media order. Returns
    (results, failed) where results is [{"index": item_index, "text": t}] for
    each video that transcodes + transcribes and failed is the list of
    item_index values whose transcode/transcribe dropped out. item_index is the
    item's 1-based position in the FULL media set, so a mixed-tweet video block
    is labeled by its item index; a lone video is index 1. Videos NEVER enter the
    vault; only the transcript TEXT is written."""
    out = []
    failed = []
    for idx, video in videos:
        with tempfile.TemporaryDirectory() as td:
            wav = Path(td) / "audio.wav"          # temp; never enters the vault
            if not extract_wav(video, wav):
                failed.append(idx)
                continue
            text = whisper_transcribe(wav, model)
            if text:
                out.append({"index": idx, "text": text})
            else:
                failed.append(idx)
    return out, failed


# --- image slides (ffmpeg recompress -> vault _media/ copy) -----------------
def recompress_slide(src: Path, dst: Path) -> bool:
    """Recompress one image to a <=LONG_EDGE_MAX-px long-edge JPEG at ~q80. The
    min() scale filter naturally skips enlarging an already-smaller image."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return False
    cmd = [ffmpeg, "-y", "-i", str(src),
           "-vf",
           "scale='min(%d,iw)':'min(%d,ih)':force_original_aspect_ratio=decrease"
           % (LONG_EDGE_MAX, LONG_EDGE_MAX),
           "-qscale:v", "5", str(dst)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=FFMPEG_TIMEOUT)
    except subprocess.TimeoutExpired:
        return False
    if p.returncode != 0:
        _emit_stderr_tail("ffmpeg(slide)", p.stderr)
        return False
    return dst.is_file()


def render_slides(images, slug, vault):
    """Copy up to SLIDE_CAP recompressed slides into
    vault/Clippings/_media/<slug>/slide-NN.jpg; return (embeds, failed) where
    embeds is the ordered ![[Clippings/_media/<slug>/slide-NN.jpg]] lines and
    failed is the list of 1-based SOURCE positions whose recompress dropped out.
    Surviving slides are renumbered SEQUENTIALLY (slide-01..slide-0K, no gaps) -
    a failed source does not burn a slide number - so the compacted numbering
    matches the --apply-digest docstring. The vault-absolute embed paths survive
    an /archive-clips move of the clip note."""
    media_dir = _media_dir(vault, slug)
    media_dir.mkdir(parents=True, exist_ok=True)
    embeds = []
    failed = []
    out_n = 0
    for src_i, src in enumerate(images[:SLIDE_CAP], start=1):
        dst = media_dir / f"slide-{out_n + 1:02d}.jpg"
        if not recompress_slide(src, dst):
            failed.append(src_i)
            continue
        out_n += 1
        embeds.append(f"![[Clippings/_media/{slug}/slide-{out_n:02d}.jpg]]")
    return embeds, failed


# --- ## Crawled content render + scoped-G-3 upsert --------------------------
def render_crawled(transcripts, slide_embeds, caption):
    """Build a full ## Crawled content section body: an optional caption, one
    ### Transcript block per transcribed video (labeled by item index when slides
    are also present, i.e. a mixed tweet), then a ### Slides block with the embeds
    + the <!-- slides-pending-digest --> marker."""
    lines = ["## Crawled content", f"<!-- media-enriched {TODAY} via x-media -->", ""]
    if caption:
        lines += [caption, ""]
    for t in transcripts:
        # Mixed tweets label each video block by its media item index.
        if slide_embeds:
            # This full-media label is intentionally decoupled from render_slides'
            # compact slide-XX filenames; unified numbering is deferred (parity
            # with the IG rung's HIMMEL-791 note).
            lines += ["### Transcript", f"**Item {t['index']} (video):**",
                      t["text"], ""]
        else:
            lines += ["### Transcript", t["text"], ""]
    if slide_embeds:
        lines += ["### Slides"] + slide_embeds + ["<!-- slides-pending-digest -->", ""]
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def _strip_crawled(body: str) -> str:
    """Return `body` with its ## Crawled content section removed and blank runs
    collapsed. Scoped-G-3 compares this before/after the write: everything
    OUTSIDE the tool-owned crawled section must be byte-identical."""
    m = re.search(r"(?m)^## Crawled content\b", body)
    if not m:
        outside = body
    else:
        rest = body[m.end():]
        nxt = re.search(r"(?m)^## (?!Crawled content)", rest)
        end = m.end() + (nxt.start() if nxt else len(rest))
        outside = body[:m.start()] + body[end:]
    return re.sub(r"\n{3,}", "\n\n", outside).strip()


def _strip_prior_media(body: str) -> str:
    """Remove any x-media-written ### Transcript / ### Slides / ### Slide digest
    block (the pending-digest marker rides inside ### Slides) from an existing
    ## Crawled content section, so a re-selected PARTIAL clip re-renders cleanly
    instead of accreting duplicate H3 blocks on retry. Byte-identical no-op when
    the section carries no such block (fresh clip, or a caption-only section)."""
    m = re.search(r"(?m)^## Crawled content\b", body)
    if not m:
        return body
    rest = body[m.end():]
    nxt = re.search(r"(?m)^## (?!Crawled content)", rest)
    end = m.end() + (nxt.start() if nxt else len(rest))
    head, section, after = body[:m.end()], body[m.end():end], body[end:]
    stripped = re.sub(
        r"(?ms)^### (?:Transcript|Slides|Slide digest)\b.*?(?=^### |^## |\Z)",
        "", section)
    if stripped == section:
        return body
    stripped = re.sub(r"\n{3,}", "\n\n", stripped)
    return head + stripped + after


def _drop_descriptor(slides_failed, videos_failed) -> str:
    """Human descriptor of the dropped media on a PARTIAL run, e.g.
    "slides 3,5 failed; video 2 failed" - fed into media_last_error and the loud
    per-clip line so a partial loss is never silent."""
    parts = []
    if slides_failed:
        parts.append("slide%s %s failed" % (
            "s" if len(slides_failed) > 1 else "",
            ",".join(str(i) for i in slides_failed)))
    if videos_failed:
        parts.append("video%s %s failed" % (
            "s" if len(videos_failed) > 1 else "",
            ",".join(str(i) for i in videos_failed)))
    return "; ".join(parts)


def _splice_crawled(body: str, section: str) -> str:
    """Upsert into an existing ## Crawled content (splice the new ### H3 block(s)
    in before the section end, keeping any existing caption) OR insert the fresh
    `section` before ## Source (else append). `section` is the full
    render_crawled output."""
    m = re.search(r"(?m)^## Crawled content\b", body)
    if m:
        rest = body[m.end():]
        nxt = re.search(r"(?m)^## (?!Crawled content)", rest)
        cut = m.end() + (nxt.start() if nxt else len(rest))
        head, after = body[:cut], body[cut:]
        h3 = re.search(r"(?m)^### ", section)
        blocks = (section[h3.start():] if h3 else section).rstrip("\n")
        # HIMMEL-1235: starting `blocks` at the first ### heading drops
        # render_crawled's <!-- media-enriched ... via x-media --> provenance
        # comment (it lives BEFORE the first ###). An existing section from an
        # earlier fxtwitter pass carries no such comment, so the spliced-in
        # ### Slides + pending marker would land with no x-media provenance and
        # the --apply-digest guard would refuse forever. Prepend it here -
        # unless the existing section already has x-media provenance (a
        # same-tool re-run), which must not duplicate the comment. Detection is
        # the anchored PROV_RE (codex-adv): a bare "via x-media -->" substring
        # buried in untrusted crawled prose no longer counts as real provenance.
        if not PROV_RE.search(body[m.start():cut]):
            blocks = f"<!-- media-enriched {TODAY} via x-media -->\n\n" + blocks
        sep = "" if head.endswith("\n\n") else ("\n" if head.endswith("\n") else "\n\n")
        return head + sep + blocks + "\n" + after
    src = re.search(r"(?m)^## Source\b", body)
    if src:
        before, after = body[:src.start()], body[src.start():]
        sep = "" if before.endswith("\n\n") or before == "" else (
            "\n" if before.endswith("\n") else "\n\n")
        return before + sep + section + "\n\n" + after
    return body.rstrip("\n") + "\n\n" + section + "\n"


def write_crawled(path: Path, text: str, fm_raw: str, body: str, section: str,
                  has_crlf: bool, status: str = "ok", last_error: str = "null",
                  enriched: bool = True) -> bool:
    """Splice the ## Crawled content section into `body`, write the media_*
    markers, then re-read and verify: the new body is exactly what we wrote, the
    frontmatter still parses carrying every marker, and everything OUTSIDE the
    crawled section is byte-identical (scoped-G-3). Revert and return False on any
    mismatch; return True on a verified write.

    Full success (enriched=True) sets media_enriched_at and CLEARS
    x_media_pending. A PARTIAL write (enriched=False) writes the section for the
    media that DID survive but sets status=partial + a partial_media: last_error,
    withholds media_enriched_at, and PARKS x_media_pending: true so the clip stays
    selectable and is retried. Prior x-media H3 blocks are stripped first so a
    partial retry re-renders cleanly instead of duplicating."""
    new_body = _splice_crawled(_strip_prior_media(body), section)
    markers = {
        "media_enrichment_status": status,
        "media_last_error": last_error,
    }
    if enriched:
        markers["media_enriched_at"] = TODAY
    new_fm_raw = upsert_media_markers(fm_raw, markers)
    if enriched:
        new_fm_raw = drop_x_media_pending(new_fm_raw)
    else:
        new_fm_raw = set_x_media_pending(new_fm_raw)
    new_text = f"---\n{new_fm_raw}\n---\n{new_body}"
    write_clip(path, new_text, has_crlf)
    disk_text, _ = read_clip(path)
    disk_fm, _, disk_body, disk_present = parse_frontmatter(disk_text)
    ok = (disk_present
          and disk_body == new_body
          and all(k in disk_fm for k in markers)
          and _strip_crawled(body) == _strip_crawled(disk_body))
    if not ok:
        write_clip(path, text, has_crlf)   # revert outside-region drift
        return False
    return True


# --- discovery / selection -------------------------------------------------
def find_clips(vault: Path, include_evidence: bool, include_done: bool = False):
    """Discover selectable clips. --include-evidence and --include-done are
    ORTHOGONAL pool switches (each opens exactly one gated pool, neither implies
    the other): the default inbox scan excludes _synthesis / _rejected /
    _deferred / _done / _evidence; --include-evidence adds _evidence (never its
    _rejected subfolder); --include-done adds the graduated _done pool. A full
    historical backfill therefore passes BOTH flags."""
    root = vault / "Clippings"
    if not root.is_dir():
        return []
    out = []
    for p in sorted(root.rglob("*.md")):
        parts = p.parts
        if "_synthesis" in parts or p.name == "_deferred.md":
            continue
        if "_done" in parts and not include_done:
            continue
        if "_evidence" in parts:
            if not include_evidence:
                continue
            if "_rejected" in parts:      # never touch rejected evidence
                continue
        out.append(p)
    return out


def is_selected(fm: dict, fm_raw: str, body: str):
    """Select an X clip that (1) has an x.com/twitter.com status source, (2) is
    not already media-enriched, and (3) references downloadable X media in its
    body. A PARTIAL / x_media_pending clip is still selectable through the same
    predicate: it carries no media_enriched_at and its original twimg refs
    remain, so it is retried until it fully enriches or the media is gone."""
    x = is_x_source(fm.get("source", ""))
    if not x:
        return None
    if already_media_enriched(fm_raw):
        return None
    if not _has_twimg_media(body):
        return None
    return x


def parse_args(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("vault", type=Path, nargs="?")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--include-evidence", action="store_true")
    ap.add_argument("--include-done", action="store_true",
                    help="also scan _done/ graduated clips (the backfill pass)")
    ap.add_argument("--whisper-model", default=DEFAULT_WHISPER_MODEL)
    ap.add_argument("--apply-digest", type=Path, default=None, metavar="CLIP")
    ap.add_argument("--digest-file", type=Path, default=None, metavar="FILE")
    ap.add_argument("--repair-provenance", type=Path, default=None, metavar="CLIP")
    ap.add_argument("--flag-screen", type=Path, default=None, metavar="CLIP")
    ap.add_argument("--detail", default=None, metavar="DETAIL")
    return ap.parse_args(argv)


def enrich_batch(args, selected, matched_total, remaining):
    """Download media, transcode/transcribe any video items, recompress + copy
    images into the vault, then write ONE ## Crawled content section per clip
    under the scoped-G-3 contract. Videos (incl. mixed-tweet video items) go
    through whisper only and are NEVER copied into the vault; a soundless GIF-like
    video falls back to a first-frame screenshot slide. Only transcript TEXT and
    image/frame files are written. Marker namespace is media_*.

    Per-clip isolation: the whole per-clip body is wrapped so an unexpected error
    on one clip is reported loudly and counted failed, never aborting the batch. A
    clip whose media only PARTIALLY survived is written honestly as
    media_enrichment_status: partial and KEEPS x_media_pending for retry."""
    import time
    cf = preflight()
    enriched = 0
    partial = 0
    failed = 0
    for p, x in selected:
        relpath = p.relative_to(args.vault).as_posix()
        try:
            if RATE_LIMIT_S > 0:
                time.sleep(RATE_LIMIT_S)
            files, error = download_media(x, cf)
            if error:
                text, has_crlf = read_clip(p)
                fm, fm_raw, body, present = parse_frontmatter(text)
                permanent = error == "removed"      # 404/removed is permanent
                if write_markers(p, text, fm_raw, body, has_crlf,
                                 status="failed", error=error, permanent=permanent):
                    print(f"x {relpath}: failed ({error})")
                else:
                    print(f"marker write REVERTED - failure NOT recorded for "
                          f"{relpath}", file=sys.stderr)
                failed += 1
                continue
            # Split media in tweet order: images -> vault slides; videos (any
            # position, incl. mixed tweets) -> whisper, labeled by item index.
            images = classify(files)["images"]
            screenshot_image_positions = set()
            videos = [(i, f) for i, f in enumerate(files, start=1)
                      if f.suffix.lower() in VIDEO_EXTS]
            expected_videos = len(videos)
            transcripts, videos_failed = (
                transcribe_videos(videos, args.whisper_model) if videos
                else ([], []))
            # Soundless-video screenshot fallback: a failed video with NO audio
            # stream (GIF-like tweet_video) becomes a slide screenshot in tweet
            # order instead of a failed transcript.
            if videos_failed:
                vmap = dict(videos)
                screenshots = {}
                still_failed = []
                for idx in videos_failed:
                    frame = soundless_video_frame(vmap[idx])
                    if frame is None:
                        still_failed.append(idx)
                    else:
                        screenshots[idx] = frame
                videos_failed = still_failed
                if screenshots:
                    expected_videos -= len(screenshots)
                    rebuilt_images = []
                    for i, f in enumerate(files, start=1):
                        if i in screenshots:
                            rebuilt_images.append(screenshots[i])
                            screenshot_image_positions.add(len(rebuilt_images))
                        elif f.suffix.lower() in IMAGE_EXTS:
                            rebuilt_images.append(f)
                    images = rebuilt_images
            # Media-dir namespace (codex-adv HIMMEL-1226): stem ALONE collides
            # across pools (--include-done/--include-evidence recurse inbox +
            # _evidence + _done, where duplicate basenames are valid), silently
            # cross-wiring one clip's slides onto another. The X status id is a
            # unique per-tweet key; <stem>-<status-id> keeps the readable stem
            # (parity with the IG _media/<slug>/ layout) AND is collision-free
            # across different tweets. Two notes of the SAME tweet share the dir,
            # which is correct - the media is identical.
            slug = f"{p.stem}-{x['shortcode']}"
            expected_images = len(images[:SLIDE_CAP])
            media_dir = _media_dir(args.vault, slug)
            media_pre_existed = media_dir.exists()
            slide_embeds, slides_failed = (
                render_slides(images, slug, args.vault) if images else ([], []))
            recompress_failed = set(slides_failed)
            video_frame_slides = sum(
                1 for pos in screenshot_image_positions
                if pos <= SLIDE_CAP and pos not in recompress_failed)
            # Outcome-line qualifiers: "(M video-frame)" counts screenshot slides
            # that actually rendered; "(K capped)" discloses SLIDE_CAP-trimmed
            # items (log-only - cap != failure).
            capped_out = len(images) - expected_images
            quals = []
            if video_frame_slides:
                quals.append(f"{video_frame_slides} video-frame")
            if capped_out:
                quals.append(f"{capped_out} capped")
            qual_suffix = " ({})".format(", ".join(quals)) if quals else ""
            text, has_crlf = read_clip(p)
            fm, fm_raw, body, present = parse_frontmatter(text)
            if not present:
                print(f"x {relpath}: no frontmatter")
                failed += 1
                continue
            if not transcripts and not slide_embeds:
                # Nothing survived transcode/recompress -> retryable, no ok marker.
                if not write_markers(p, text, fm_raw, body, has_crlf,
                                     status="failed", error="no_media_content",
                                     permanent=False):
                    print(f"marker write REVERTED - failure NOT recorded for "
                          f"{relpath}", file=sys.stderr)
                print(f"x {relpath}: no transcript/slides")
                failed += 1
                continue
            # Caption: the tweet text already lives in the harvested clip body;
            # this rung adds media only, so pass None (no duplication).
            section = render_crawled(transcripts, slide_embeds, None)
            is_partial = (len(slide_embeds) < expected_images
                          or len(transcripts) < expected_videos)
            if is_partial:
                descriptor = _drop_descriptor(slides_failed, videos_failed)
                ok = write_crawled(p, text, fm_raw, body, section, has_crlf,
                                   status="partial",
                                   last_error="partial_media:" + descriptor,
                                   enriched=False)
                if ok:
                    print(f"~ {relpath}: partial "
                          f"({len(slide_embeds)}/{expected_images} slides"
                          f"{qual_suffix}, "
                          f"{len(transcripts)}/{expected_videos} transcripts; "
                          f"{descriptor})")
                    partial += 1
                else:
                    _cleanup_orphan_media(media_dir, slide_embeds,
                                          media_pre_existed, relpath)
                    failed += 1
            elif write_crawled(p, text, fm_raw, body, section, has_crlf):
                print(f"v {relpath}: {len(slide_embeds)} slides{qual_suffix} + "
                      f"{len(transcripts)} transcript")
                enriched += 1
            else:
                _cleanup_orphan_media(media_dir, slide_embeds,
                                      media_pre_existed, relpath)
                failed += 1
        except Exception as e:            # per-clip isolation: one bad clip
            print(f"FAIL {relpath}: unexpected: {e}", file=sys.stderr)
            failed += 1
            continue
    print(f"\nx-media-fetch: {len(selected)} selected, {enriched} enriched, "
          f"{partial} partial, {failed} failed")
    if remaining > 0:
        print(f"x-media-fetch: {matched_total} matched, {len(selected)} "
              f"processed, {remaining} remaining (capped by --limit; pass "
              f"--limit 0 for all)")


def _cleanup_orphan_media(media_dir: Path, slide_embeds, pre_existed: bool,
                          relpath: str):
    """A G-3-reverted write leaves the clip body clean but the recompressed slide
    JPEGs already sit in Clippings/_media/<slug>/ - orphans with no clip
    referencing them. Remove the media dir we created THIS pass (only if it did
    not pre-exist, so a prior run's slides are never nuked) and note it."""
    if slide_embeds and not pre_existed and media_dir.exists():
        shutil.rmtree(media_dir, ignore_errors=True)
        print(f"x {relpath}: G-3 verify failed (reverted; orphan _media cleaned)")
    else:
        print(f"x {relpath}: G-3 verify failed (reverted)")


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def run_apply_digest(clip: Path, digest_file: Path) -> int:
    """Mechanical slide-digest applier (scoped-G-3). The agent reads the slide
    images/frames and writes the digest TEXT to `digest_file` (untrusted ->
    treated as data, never executed); the tool inserts exactly ONE ### Slide
    digest H3 inside ## Crawled content (where the pending marker sat) and strips
    the single <!-- slides-pending-digest --> marker. Scoped-G-3 is enforced two
    ways: (1) the reconstruction check proves the transform is exactly one H3
    added + one marker removed; (2) the post-write fm_raw hash equality proves the
    frontmatter is byte-identical (the digest only ever touches the body). Reverts
    to baseline on any violation. Exit 0 success, 1 usage, 3 (reverted) on G-3
    failure."""
    if digest_file is None or not clip.is_file() or not digest_file.is_file():
        print("x-media-fetch --apply-digest: need <clip> and --digest-file "
              "<existing file>", file=sys.stderr)
        return 1
    text, has_crlf = read_clip(clip)
    baseline = _sha(text)   # normalized-text baseline (CRLF contract)
    fm, fm_raw, body, present = parse_frontmatter(text)
    if not present:
        print("x-media-fetch --apply-digest: no frontmatter", file=sys.stderr)
        return 1
    marker = "<!-- slides-pending-digest -->"
    if body.count(marker) != 1:
        print("x-media-fetch --apply-digest: expected exactly one pending "
              "marker; found %d" % body.count(marker), file=sys.stderr)
        return 1
    # Provenance guard (codex-adv HIMMEL-1226/1235): the pending marker must
    # sit inside a tool-written x-media ## Crawled content section - proven by
    # an ANCHORED, full-line "via x-media" provenance comment (PROV_RE) that
    # render_crawled always emits, with the marker following it. A bare marker
    # planted in attacker-controlled clip prose (or a clip whose crawled prose
    # merely CONTAINS the literal substring, mid-line) is refused, so the
    # applier never treats forged/accidental markers as workflow control.
    # NOT unforgeable (an attacker who copies the whole crawled block still
    # passes) - the full per-run-nonce + media-path-ownership fix spanning BOTH
    # media rungs is HIMMEL-1228; this raises the bar cheaply for now.
    prov_m = PROV_RE.search(body)
    if prov_m is None or body.index(marker) < prov_m.end():
        print("x-media-fetch --apply-digest: pending marker is not inside an "
              "x-media crawled section (no 'via x-media' provenance before it); "
              "refusing", file=sys.stderr)
        return 1
    digest = digest_file.read_text(encoding="utf-8").strip()
    # Untrusted digest text must never carry the control marker: neutralize any
    # smuggled literal occurrence to an inert ASCII form.
    digest = digest.replace(marker, "[slides-pending-digest]")
    h3 = "### Slide digest\n" + digest + "\n"
    idx = body.index(marker)
    new_body = body[:idx] + h3 + "\n" + body[idx + len(marker):]
    new_body = new_body.replace(marker, "", 1) if marker in new_body else new_body
    # Scoped-G-3: removing our exactly-one added H3 block and re-inserting the
    # marker must reproduce the baseline body byte-for-byte.
    reconstructed = new_body.replace(h3 + "\n", marker, 1)
    if reconstructed != body:
        print("x-media-fetch --apply-digest: scoped-G-3 reconstruction "
              "mismatch; refusing", file=sys.stderr)
        return 3
    new_text = f"---\n{fm_raw}\n---\n{new_body}"
    write_clip(clip, new_text, has_crlf)
    disk, _ = read_clip(clip)
    dfm, dfm_raw, dbody, dpresent = parse_frontmatter(disk)
    # FM immutability invariant: post-write fm_raw hash == pre-write fm_raw hash.
    ok = dpresent and dbody == new_body and _sha(dfm_raw) == _sha(fm_raw)
    if not ok:
        write_clip(clip, text, has_crlf)   # revert
        if _sha(read_clip(clip)[0]) != baseline:
            print("x-media-fetch --apply-digest: REVERT FAILED", file=sys.stderr)
        print("x-media-fetch --apply-digest: post-write verify failed; "
              "reverted", file=sys.stderr)
        return 3
    print(f"OK apply-digest {clip.name}: 1 ### Slide digest H3 added, marker stripped")
    return 0


def _vault_root_from_clip(clip: Path) -> Path:
    """Vault root = the directory above the clip's Clippings/ ancestor (the
    clip lives at <vault>/Clippings/..., possibly nested under a pool like
    _done/2026-05/). Walk parents rather than assume a fixed depth."""
    for p in clip.resolve().parents:
        if p.name == "Clippings":
            return p.parent
    return clip.resolve().parent


def run_repair_provenance(clip: Path) -> int:
    """One-time mechanical repair (HIMMEL-1235) for clips already written by
    the pre-fix _splice_crawled: a ### Slides block + exactly one
    <!-- slides-pending-digest --> marker were spliced into a PRE-EXISTING
    ## Crawled content section (e.g. from an earlier fxtwitter pass) with NO
    <!-- media-enriched ... via x-media --> provenance comment, so
    --apply-digest's provenance guard refuses them forever. Not applicable
    (exit 1, no write) when there is no ## Crawled content section, no
    ### Slides block + exactly one pending marker inside it, or the section
    already carries x-media provenance.

    Anti-forgery (HIMMEL-1228): BEFORE stamping provenance, every
    ![[Clippings/_media/<slug>/slide-NN.jpg]] embed in the ### Slides block
    must resolve to a file that actually exists on disk (relative to the
    vault root derived from the clip's own path) - a bare Slides block with no
    embeds, or an embed pointing at a missing file, is refused. This prevents
    laundering a forged/planted marker into one --apply-digest will accept.

    Scoped-G-3: a reconstruction check (removing exactly the inserted
    provenance text reproduces the pre-write body byte-for-byte) plus fm_raw
    hash immutability, mirroring run_apply_digest. Reverts on any violation.
    Exit 0 repaired, 1 usage/not-applicable, 3 G-3 failure."""
    if not clip.is_file():
        print("x-media-fetch --repair-provenance: clip not found: %s" % clip,
              file=sys.stderr)
        return 1
    text, has_crlf = read_clip(clip)
    _fm, fm_raw, body, present = parse_frontmatter(text)
    if not present:
        print("x-media-fetch --repair-provenance: no frontmatter",
              file=sys.stderr)
        return 1
    m = re.search(r"(?m)^## Crawled content\b", body)
    if not m:
        print("x-media-fetch --repair-provenance: no ## Crawled content "
              "section; not applicable", file=sys.stderr)
        return 1
    rest = body[m.end():]
    nxt = re.search(r"(?m)^## (?!Crawled content)", rest)
    sec_end = m.end() + (nxt.start() if nxt else len(rest))
    section = body[m.start():sec_end]
    marker = "<!-- slides-pending-digest -->"
    marker_re = re.compile(r"(?m)^" + re.escape(marker) + r"[ \t]*$")
    slides_m = re.search(r"(?m)^### Slides[ \t]*$", section)
    # HIMMEL-1235 (CodeRabbit/codex): the pending marker must sit INSIDE the
    # ### Slides block as its own anchored line, not merely somewhere in the
    # ## Crawled content section - a marker planted elsewhere in the section, in
    # a LATER sibling ### subsection, or mid-line in prose must not qualify a
    # clip for provenance repair. Bound slides_block to the ### Slides subsection
    # (up to the next ## / ### heading), so the marker AND embed checks below are
    # scoped to Slides alone.
    if slides_m:
        after_slides = section[slides_m.end():]
        nxt_h = re.search(r"(?m)^#{2,3} ", after_slides)
        slides_end = slides_m.end() + (nxt_h.start() if nxt_h else len(after_slides))
        slides_block = section[slides_m.start():slides_end]
    else:
        slides_block = ""
    if not slides_m or len(marker_re.findall(slides_block)) != 1:
        print("x-media-fetch --repair-provenance: no ### Slides block + "
              "exactly one pending marker line in the ### Slides block; not "
              "applicable", file=sys.stderr)
        return 1
    if PROV_RE.search(section):
        print("x-media-fetch --repair-provenance: section already carries "
              "x-media provenance; not applicable", file=sys.stderr)
        return 1
    embeds = re.findall(r"(?m)^!\[\[(Clippings/_media/[^\]]+?)\]\]$",
                        slides_block)
    vault_root = _vault_root_from_clip(clip)
    media_root = (vault_root / "Clippings" / "_media").resolve()

    def _contained_slide(embed: str) -> bool:
        # Anti-forgery containment (HIMMEL-1235 / codex-adv): the embed regex
        # accepts any suffix after Clippings/_media/, so a crafted ../ (or
        # symlink) embed could otherwise resolve to an arbitrary existing file
        # (e.g. .../Windows/win.ini) and satisfy the "slide exists" gate,
        # laundering forged provenance. Resolve the path (following .. and
        # symlinks) and require it stays UNDER Clippings/_media/ AND is a real
        # file. (Binding a slide to the clip's own status id stays HIMMEL-1228.)
        try:
            p = (vault_root / embed).resolve()
        except (OSError, RuntimeError):
            return False
        return p.is_relative_to(media_root) and p.is_file()

    missing = [e for e in embeds if not _contained_slide(e)]
    if not embeds or missing:
        print("x-media-fetch --repair-provenance: refusing - referenced "
              "slide file(s) missing on disk: %s"
              % (", ".join(missing) if missing else "(no slide embeds found)"),
              file=sys.stderr)
        return 1
    slides_abs = m.start() + slides_m.start()
    before, after = body[:slides_abs], body[slides_abs:]
    sep = "" if before.endswith("\n\n") else ("\n" if before.endswith("\n") else "\n\n")
    prov = f"<!-- media-enriched {TODAY} via x-media -->"
    inserted = sep + prov + "\n\n"
    new_body = before + inserted + after
    # Scoped-G-3: removing exactly the inserted text must reproduce the
    # baseline body byte-for-byte (proves nothing outside it changed).
    reconstructed = new_body.replace(inserted, "", 1)
    if reconstructed != body:
        print("x-media-fetch --repair-provenance: scoped-G-3 reconstruction "
              "mismatch; refusing", file=sys.stderr)
        return 3
    new_text = f"---\n{fm_raw}\n---\n{new_body}"
    write_clip(clip, new_text, has_crlf)
    disk, _ = read_clip(clip)
    _dfm, dfm_raw, dbody, dpresent = parse_frontmatter(disk)
    ok = dpresent and dbody == new_body and _sha(dfm_raw) == _sha(fm_raw)
    if not ok:
        write_clip(clip, text, has_crlf)   # revert
        print("x-media-fetch --repair-provenance: post-write verify failed; "
              "reverted", file=sys.stderr)
        return 3
    print(f"OK repair-provenance {clip.name}: x-media provenance inserted "
          f"before ### Slides")
    return 0


def run_flag_screen(clip: Path, detail: str) -> int:
    """Mechanical injection re-screen writer (Step 5). The Step-5 scanner
    (harvest-clip-body-batch --scan-only) is READ-ONLY; when it HITS, the agent
    hands the comma-joined pattern-class names (or `screen-error` on a fail-closed
    scanner error) here and the TOOL writes ONLY harvest_flag: injection-suspect +
    harvest_flag_detail: <detail> into the frontmatter. Same verified-write
    discipline as write_markers: baseline text, re-read from disk, body
    byte-identity, revert on any mismatch. Idempotent. The body is never touched.
    Exit 0 verified, 1 usage, 3 reverted."""
    if not detail or not clip.is_file():
        print("x-media-fetch --flag-screen: need <clip> and --detail "
              "<comma-classes|screen-error>", file=sys.stderr)
        return 1
    text, has_crlf = read_clip(clip)
    fm, fm_raw, body, present = parse_frontmatter(text)
    if not present:
        print("x-media-fetch --flag-screen: no frontmatter", file=sys.stderr)
        return 1
    new_fm_raw = upsert_harvest_flag(fm_raw, detail)
    new_text = f"---\n{new_fm_raw}\n---\n{body}"
    write_clip(clip, new_text, has_crlf)
    disk_text, _ = read_clip(clip)
    disk_fm, _, disk_body, disk_present = parse_frontmatter(disk_text)
    ok = (disk_present and disk_body == body
          and disk_fm.get("harvest_flag") == "injection-suspect"
          and disk_fm.get("harvest_flag_detail") == detail)
    if not ok:
        write_clip(clip, text, has_crlf)   # revert outside-region drift
        print("x-media-fetch --flag-screen: post-write verify failed; "
              "reverted", file=sys.stderr)
        return 3
    print(f"OK flag-screen {clip.name}: harvest_flag=injection-suspect "
          f"detail={detail}")
    return 0


def main():
    args = parse_args(sys.argv[1:])
    if args.apply_digest is not None:
        sys.exit(run_apply_digest(args.apply_digest, args.digest_file))
    if args.repair_provenance is not None:
        sys.exit(run_repair_provenance(args.repair_provenance))
    if args.flag_screen is not None:
        sys.exit(run_flag_screen(args.flag_screen, args.detail))
    if args.vault is None or not args.vault.is_dir():
        print("x-media-fetch: vault path required (or not a dir)", file=sys.stderr)
        sys.exit(1)
    clips = find_clips(args.vault, args.include_evidence, args.include_done)
    selected = []
    for p in clips:
        try:
            text, has_crlf = read_clip(p)
        except Exception:
            continue
        fm, fm_raw, body, present = parse_frontmatter(text)
        if not present:
            continue
        x = is_selected(fm, fm_raw, body)
        if x:
            selected.append((p, x))
    matched_total = len(selected)
    selected = selected[: args.limit] if args.limit > 0 else selected
    remaining = matched_total - len(selected)

    if args.dry_run:
        for p, x in selected:
            print(f"PLAN {p.relative_to(args.vault).as_posix()} -- "
                  f"would fetch status/{x['shortcode']} [dry-run]")
        print(f"\nx-media-fetch: {len(selected)} selected, 0 enriched "
              f"(dry_run=True)")
        if remaining > 0:
            print(f"x-media-fetch: {matched_total} matched, {len(selected)} "
                  f"processed, {remaining} remaining (capped by --limit; pass "
                  f"--limit 0 for all)")
        sys.exit(0)

    if not selected:
        # No-op run: report the standard summary and exit 0 WITHOUT preflight - a
        # run with nothing to do must not fail on missing gallery-dl/ffmpeg/cookies.
        print(f"\nx-media-fetch: {len(selected)} selected, 0 enriched, "
              f"0 partial, 0 failed")
        sys.exit(0)

    enrich_batch(args, selected, matched_total, remaining)


if __name__ == "__main__":
    main()
