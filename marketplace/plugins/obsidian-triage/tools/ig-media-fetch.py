#!/usr/bin/env python3
"""
ig-media-fetch.py - deterministic Instagram media enrichment rung (HIMMEL-770).

Escalation rung AFTER ig-embed-enrich.mjs. For IG clips whose caption rung
failed OR whose body is still thin (no ### Transcript / ### Slides) and which
carry no media_enriched_at: marker:

  - Download reel/carousel media via gallery-dl (burner-account cookies).
  - Reels (video): ffmpeg -> mono 16kHz WAV -> local faster-whisper transcript.
  - Carousels (images): ffmpeg recompress <=1600px JPEG, copy into the vault at
    Clippings/_media/<clip-slug>/slide-NN.jpg, embed under ### Slides.
  - Mixed carousels: video items -> same whisper path (### Transcript labeled by
    slide index); videos NEVER copied into the vault.
  - Write ONE ## Crawled content section (create, or extend the ig-embed one)
    under a DISTINCT marker namespace: media_enriched_at / media_enrichment_status
    / media_last_error. Scoped-G-3: everything outside the tool-owned region is
    byte-identical post-write, else revert.

  --apply-digest <clip> --digest-file <tmp>: the mechanical slide-digest applier
    (agent reads images, tool writes the ### Slide digest H3 + strips the pending
    marker). Scoped-G-3 (reconstruction check + fm_raw hash immutability) +
    revert-on-failure.

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
RATE_LIMIT_S = 0 if os.environ.get("IG_MEDIA_NO_SLEEP") else 10
DEFAULT_LIMIT = 10
SLIDE_CAP = 20
LONG_EDGE_MAX = 1600
DEFAULT_WHISPER_MODEL = "base"
DOWNLOAD_TIMEOUT = 180
FFMPEG_TIMEOUT = int(os.environ.get("IG_MEDIA_FFMPEG_TIMEOUT", "300"))
WHISPER_TIMEOUT = 1800

IG_URL_RE = re.compile(
    r"^https?://(?:www\.|m\.)?instagram\.com/(p|reel|reels|tv)/([A-Za-z0-9_-]+)"
)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".webm"}

MEDIA_KEYS = ["media_enriched_at", "media_enrichment_status", "media_last_error"]
HARVEST_FLAG_KEYS = ["harvest_flag", "harvest_flag_detail"]


# --- frontmatter (mirrors harvest-clip-body-batch.py) ----------------------
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
    """Read a clip; normalize CRLF -> LF for ALL internal processing (the
    parked _evidence/ IG clips may be CRLF; an LF-only parse would silently
    skip them and defeat the backfill). Returns (text, has_crlf). Mirrors
    ig-embed-enrich.mjs hasCrlf handling. Read with newline="" (NOT read_text,
    whose universal-newline translation would strip every \r before the
    has_crlf test and silently downgrade a CRLF clip to LF on re-emit)."""
    with path.open("r", encoding="utf-8", newline="") as f:
        raw = f.read()
    has_crlf = "\r\n" in raw
    return (raw.replace("\r\n", "\n") if has_crlf else raw), has_crlf


def write_clip(path: Path, text: str, has_crlf: bool):
    """Write a clip, re-emitting CRLF when the original used it."""
    out = text.replace("\n", "\r\n") if has_crlf else text
    path.write_text(out, encoding="utf-8", newline="")


def clip_slug(path: Path) -> str:
    return path.stem


def is_ig_source(src: str):
    m = IG_URL_RE.match((src or "").strip().strip('"'))
    if not m:
        return None
    kind = "reel" if m.group(1) == "reels" else m.group(1)
    return {"kind": kind, "shortcode": m.group(2)}


def _ig_body_thin(body: str) -> bool:
    """Thin = the ## Crawled content section has neither ### Transcript nor
    ### Slides. A caption-only body is thin by definition. No ## Crawled
    content at all -> thin. Mirrors isThinInstagramBody (tools/lib)."""
    m = re.search(r"(?m)^## Crawled content\b", body)
    if not m:
        return True
    section = body[m.start():]
    nxt = re.search(r"(?m)^## (?!Crawled content)", section[1:])
    if nxt:
        section = section[: nxt.start() + 1]
    has_transcript = re.search(r"(?m)^### Transcript\b", section) is not None
    has_slides = re.search(r"(?m)^### Slides\b", section) is not None
    return not (has_transcript or has_slides)


def already_media_enriched(fm_raw: str) -> bool:
    return bool(re.search(r"^media_enriched_at:[\s]*\S", fm_raw, re.MULTILINE))


def upsert_media_markers(fm_raw: str, markers: dict) -> str:
    """Replace any existing media_* key in place; append the rest after the
    last non-empty frontmatter line. A None value drops the key."""
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
    Idempotent: a re-screen replaces the flag rather than duplicating the key.
    Mirrors upsert_media_markers (and harvest-clip-body-batch's flag write)."""
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


def drop_ig_media_pending(fm_raw: str) -> str:
    """Remove any ig_media_pending: line from the frontmatter. The harvest layer
    parks a thin/failed IG clip with ig_media_pending: true and holds it in the
    inbox; NOTHING else releases it, so the media rung clears the hold on a
    verified enrichment success. Frontmatter-only; no-op when absent."""
    lines = [ln for ln in fm_raw.split("\n")
             if not ln.startswith("ig_media_pending:")]
    return "\n".join(lines)


# --- cache + preflight + download -----------------------------------------------
def _emit_stderr_tail(label: str, stderr: str):
    """Emit a one-line, truncated (~200 char) tail of a failed subprocess'
    stderr to sys.stderr so a silent tool failure (bad ffmpeg args, gallery-dl
    error) is diagnosable instead of collapsing to a bare taxonomy token."""
    tail = (stderr or "").strip().replace("\n", " ")
    if tail:
        print(f"{label}: {tail[-200:]}", file=sys.stderr)


def _home() -> Path:
    # Use HOME env var if set (for tests); fallback to Path.home()
    home = os.environ.get("HOME")
    return Path(home) if home else Path.home()


def cookie_file() -> Path:
    return _home() / ".luna" / "cookies" / "instagram.txt"


def cache_root() -> Path:
    return _home() / ".luna" / "ig-media"


def preflight():
    missing = [b for b in ("gallery-dl", "ffmpeg") if shutil.which(b) is None]
    if missing:
        print(
            "ig-media-fetch: missing required binaries: " + ", ".join(missing) +
            "\n  install: winget install yt-dlp.gallery-dl ; winget install "
            "Gyan.FFmpeg   (or: uv tool install gallery-dl)",
            file=sys.stderr,
        )
        sys.exit(2)
    cf = cookie_file()
    if not cf.is_file():
        print(
            "ig-media-fetch: cookie file missing: " + str(cf) +
            "\n  Export instagram.com cookies (logged into your BURNER account) "
            "with the Cookie-Editor extension in Netscape format, save to that "
            "path, then chmod 600 it. (Cookie contents are never printed.)",
            file=sys.stderr,
        )
        sys.exit(2)
    return cf


def _natural_key(p: Path):
    """Natural-sort key: split the filename into digit / non-digit runs and
    compare digit runs numerically, so gallery-dl's UNPADDED carousel filenames
    order 1 < 2 < 10. A plain lexicographic sort puts 10.jpg before 2.jpg,
    corrupting slide order AND the mixed-carousel video item indices."""
    return [int(t) if t.isdigit() else t.lower()
            for t in re.split(r"(\d+)", p.name)]


def download_media(ig: dict, cf: Path):
    dest = cache_root() / ig["shortcode"]
    if dest.exists():
        shutil.rmtree(dest)   # a prior partial run must not leave stale files
    dest.mkdir(parents=True)  # fresh dir: classify sees ONLY this download
    url = f"https://www.instagram.com/{ig['kind']}/{ig['shortcode']}/"
    # Find gallery-dl in PATH; on Windows, try .bat if available
    gallery_dl = shutil.which("gallery-dl")
    if not gallery_dl:
        return None, "gallery_dl_missing"
    cmd = [gallery_dl, "--cookies", str(cf), "-D", str(dest), url]
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


def write_markers(path: Path, text: str, fm_raw: str, body: str, has_crlf: bool,
                  status: str, error: str, permanent: bool):
    """Write frontmatter-only with media enrichment markers. Re-reads after the
    write and verifies the BODY is byte-for-byte identical to the pre-write body
    (Scoped-G-3: everything outside the tool-owned frontmatter region stays
    untouched) and that the frontmatter parses carrying every marker key just
    written. Reverts to the original `text` and returns False on any mismatch;
    returns True on a verified write."""
    markers = {}
    if status:
        markers["media_enrichment_status"] = status
    if error:
        markers["media_last_error"] = error
    if permanent:
        markers["media_enriched_at"] = TODAY
    new_fm_raw = upsert_media_markers(fm_raw, markers)
    if permanent:
        # A permanent failure (removed/404) will never enrich; release the clip
        # so it can park as caption-only evidence instead of stranding in the
        # inbox. A retryable failure KEEPS the flag so the clip is retried.
        new_fm_raw = drop_ig_media_pending(new_fm_raw)
    new_text = f"---\n{new_fm_raw}\n---\n{body}"
    write_clip(path, new_text, has_crlf)
    # Verify: body byte-identical to the pre-write body; frontmatter parses and
    # carries every key we just wrote. Revert on any mismatch.
    disk_text, _ = read_clip(path)
    disk_fm, _, disk_body, disk_present = parse_frontmatter(disk_text)
    if not (disk_present and disk_body == body
            and all(k in disk_fm for k in markers)):
        write_clip(path, text, has_crlf)   # revert outside-region drift
        return False
    return True


# --- reel transcript (ffmpeg WAV + faster-whisper via uv) -------------------
def extract_wav(video: Path, wav: Path) -> bool:
    """Transcode video -> mono 16kHz WAV. The WAV lives in a caller-owned temp
    dir; the video NEVER enters the vault. Resolve ffmpeg via shutil.which so a
    PATHEXT-shimmed binary (Windows .bat) is honored (mirrors download_media)."""
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
    faster-whisper; return the stripped stdout transcript, or None on failure.
    Resolve uv via shutil.which (same PATHEXT reason as extract_wav)."""
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
    """True if the video carries an audio stream (probe: decode one audio
    frame via -map 0:a:0 -f null). Returns False ONLY on conclusive proof -
    ffmpeg reporting the 0:a:0 map "matches no streams". Every other failure
    (no ffmpeg, timeout, decode error, corrupt media) reports True so the
    caller keeps the conservative failed/partial path instead of silently
    replacing a lost transcript with a screenshot (codex-adv HIMMEL-786)."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return True
    cmd = [ffmpeg, "-i", str(video), "-map", "0:a:0", "-frames:a", "1",
           "-f", "null", "-"]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=FFMPEG_TIMEOUT)
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
    """Screenshot fallback for a soundless GIF-like video (HIMMEL-786):
    extract the first frame NEXT TO the video in the download cache (never
    the vault; render_slides copies it in) and return the frame Path.
    Returns None when the video has an audio stream (genuine transcription
    failure - caller keeps partial semantics) or the extraction fails."""
    if _has_audio_stream(video):
        return None
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return None
    frame = video.with_suffix(".frame.jpg")
    cmd = [ffmpeg, "-y", "-i", str(video), "-frames:v", "1", str(frame)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=FFMPEG_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"ffmpeg(frame): timed out after {FFMPEG_TIMEOUT}s",
              file=sys.stderr)
        return None
    if p.returncode != 0:
        _emit_stderr_tail("ffmpeg(frame)", p.stderr)
        return None
    return frame if frame.is_file() else None


def transcribe_videos(videos, model):
    """videos: list of (slide_index, Path) in carousel order. Returns
    (results, failed) where results is [{"index": slide_index, "text": t}] for
    each video that transcodes + transcribes and failed is the list of
    slide_index values whose transcode/transcribe dropped out (so the caller can
    tell a PARTIAL run from a full one). slide_index is the item's 1-based
    position in the FULL carousel, so a mixed-carousel video block is labeled by
    its slide (never by a video-only counter); a lone reel is index 1. Videos
    NEVER enter the vault; only the transcript TEXT is written."""
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


# --- carousel slides (ffmpeg recompress -> vault _media/ copy) --------------
def recompress_slide(src: Path, dst: Path) -> bool:
    """Recompress one carousel image to a <=LONG_EDGE_MAX-px long-edge JPEG at
    ~q80. The min() scale filter naturally skips enlarging an already-smaller
    image. Resolve ffmpeg via shutil.which so a PATHEXT-shimmed binary (Windows
    .bat) is honored (mirrors extract_wav / download_media)."""
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


def _media_dir(vault: Path, slug: str) -> Path:
    return vault / "Clippings" / "_media" / slug


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
    ### Transcript block per transcribed video (labeled by slide index when
    slides are also present, i.e. a mixed carousel), then a ### Slides block
    with the embeds + the <!-- slides-pending-digest --> marker."""
    lines = ["## Crawled content", f"<!-- media-enriched {TODAY} via ig-media -->", ""]
    if caption:
        lines += [caption, ""]
    for t in transcripts:
        # Mixed carousels label each video block by its slide index.
        if slide_embeds:
            lines += ["### Transcript", f"**Slide {t['index']} (video):**",
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
    """Remove any ig-media-written ### Transcript / ### Slides / ### Slide digest
    block (the pending-digest marker rides inside ### Slides) from an existing
    ## Crawled content section, so a re-selected PARTIAL clip re-renders cleanly
    instead of accreting duplicate H3 blocks on retry. Byte-identical no-op when
    the section carries no such block (fresh clip, or ig-embed caption only)."""
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
    """Upsert into an existing ## Crawled content (splice the new ### H3
    block(s) in before the section end, keeping any existing caption) OR insert
    the fresh `section` before ## Source (else append). `section` is the full
    render_crawled output."""
    m = re.search(r"(?m)^## Crawled content\b", body)
    if m:
        rest = body[m.end():]
        nxt = re.search(r"(?m)^## (?!Crawled content)", rest)
        cut = m.end() + (nxt.start() if nxt else len(rest))
        head, after = body[:cut], body[cut:]
        h3 = re.search(r"(?m)^### ", section)
        blocks = (section[h3.start():] if h3 else section).rstrip("\n")
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
    markers, then re-read and verify: the new body is exactly what we wrote,
    the frontmatter still parses carrying every marker, and everything OUTSIDE
    the crawled section is byte-identical (scoped-G-3). Revert to the original
    `text` and return False on any mismatch; return True on a verified write.

    Full success (enriched=True) sets media_enriched_at and CLEARS
    ig_media_pending. A PARTIAL write (enriched=False) writes the section for
    the media that DID survive but sets status=partial + a partial_media:
    last_error, withholds media_enriched_at, and KEEPS ig_media_pending so the
    clip stays selectable and is retried. Prior ig-media H3 blocks are stripped
    first so a partial retry re-renders cleanly instead of duplicating."""
    new_body = _splice_crawled(_strip_prior_media(body), section)
    markers = {
        "media_enrichment_status": status,
        "media_last_error": last_error,
    }
    if enriched:
        markers["media_enriched_at"] = TODAY
    new_fm_raw = upsert_media_markers(fm_raw, markers)
    if enriched:
        new_fm_raw = drop_ig_media_pending(new_fm_raw)
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
def find_clips(vault: Path, include_evidence: bool):
    root = vault / "Clippings"
    if not root.is_dir():
        return []
    out = []
    for p in sorted(root.rglob("*.md")):
        parts = p.parts
        if "_synthesis" in parts or "_done" in parts or p.name == "_deferred.md":
            continue
        if "_evidence" in parts:
            if not include_evidence:
                continue
            if "_rejected" in parts:      # never touch rejected evidence
                continue
        out.append(p)
    return out


def is_selected(fm: dict, fm_raw: str, body: str):
    src = fm.get("source", "")
    ig = is_ig_source(src)
    if not ig:
        return None
    if already_media_enriched(fm_raw):
        return None
    # A PARTIAL clip now has a ### Slides body (so _ig_body_thin reads rich) but
    # is NOT fully enriched (no media_enriched_at); it must stay selectable so
    # the withheld media is retried.
    media_status = fm.get("media_enrichment_status", "").strip().strip('"')
    if media_status == "partial":
        return ig
    # The harvest layer parks clips with ig_media_pending: true; this rung
    # drains them. A pending clip must never be unselectable, even when its
    # body already reads rich (### Transcript present) and caption enrichment
    # succeeded - it is still gated on IG source + no media_enriched_at above.
    pending = fm.get("ig_media_pending", "").strip().strip('"') == "true"
    if pending:
        return ig
    failed = fm.get("enrichment_status", "").strip().strip('"') == "failed"
    if failed or _ig_body_thin(body):
        return ig
    return None


def parse_args(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("vault", type=Path, nargs="?")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--include-evidence", action="store_true")
    ap.add_argument("--whisper-model", default=DEFAULT_WHISPER_MODEL)
    ap.add_argument("--apply-digest", type=Path, default=None, metavar="CLIP")
    ap.add_argument("--digest-file", type=Path, default=None, metavar="FILE")
    ap.add_argument("--flag-screen", type=Path, default=None, metavar="CLIP")
    ap.add_argument("--detail", default=None, metavar="DETAIL")
    return ap.parse_args(argv)


def enrich_batch(args, selected, matched_total, remaining):
    """Download media, transcode/transcribe any video items, recompress + copy
    carousel slides into the vault, then write ONE ## Crawled content section
    per clip under the scoped-G-3 contract. Videos (incl. mixed-carousel video
    items) go through whisper only and are NEVER copied into the vault; only the
    transcript TEXT is written. Marker namespace is media_* (distinct from
    ig-embed's enriched_at/enrichment_status).

    Per-clip isolation: the whole per-clip body is wrapped so an unexpected
    error on one clip is reported loudly and counted failed, never aborting the
    batch. A clip whose media only PARTIALLY survived (some slides/videos
    dropped) is written honestly as media_enrichment_status: partial and KEEPS
    ig_media_pending for retry - it is never stamped a full success."""
    import time
    cf = preflight()
    enriched = 0
    partial = 0
    failed = 0
    for p, ig in selected:
        relpath = p.relative_to(args.vault).as_posix()
        try:
            # Rate limit before each download
            if RATE_LIMIT_S > 0:
                time.sleep(RATE_LIMIT_S)
            # Download media
            files, error = download_media(ig, cf)
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
            # Split media in carousel order: images -> vault slides; videos (any
            # position, incl. mixed carousels) -> whisper, labeled by slide index.
            images = classify(files)["images"]
            videos = [(i, f) for i, f in enumerate(files, start=1)
                      if f.suffix.lower() in VIDEO_EXTS]
            expected_videos = len(videos)
            transcripts, videos_failed = (
                transcribe_videos(videos, args.whisper_model) if videos
                else ([], []))
            # Soundless-video screenshot fallback (HIMMEL-786): a failed video
            # with NO audio stream (GIF-like screen capture) becomes a slide
            # screenshot in carousel order instead of a failed transcript.
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
                    images = [screenshots.get(i, f)
                              for i, f in enumerate(files, start=1)
                              if i in screenshots
                              or f.suffix.lower() in IMAGE_EXTS]
            slug = clip_slug(p)
            expected_images = len(images[:SLIDE_CAP])
            media_dir = _media_dir(args.vault, slug)
            media_pre_existed = media_dir.exists()
            slide_embeds, slides_failed = (
                render_slides(images, slug, args.vault) if images else ([], []))
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
            # Caption: don't duplicate an existing ig-embed caption; this rung does
            # not (yet) parse a caption from gallery-dl metadata, so pass None.
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
                          f"({len(slide_embeds)}/{expected_images} slides, "
                          f"{len(transcripts)}/{expected_videos} transcripts; "
                          f"{descriptor})")
                    partial += 1
                else:
                    _cleanup_orphan_media(media_dir, slide_embeds,
                                          media_pre_existed, relpath)
                    failed += 1
            elif write_crawled(p, text, fm_raw, body, section, has_crlf):
                print(f"v {relpath}: {len(slide_embeds)} slides + "
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
    print(f"\nig-media-fetch: {len(selected)} selected, {enriched} enriched, "
          f"{partial} partial, {failed} failed")
    if remaining > 0:
        print(f"ig-media-fetch: {matched_total} matched, {len(selected)} "
              f"processed, {remaining} remaining (capped by --limit; pass "
              f"--limit 0 for all)")


def _cleanup_orphan_media(media_dir: Path, slide_embeds, pre_existed: bool,
                          relpath: str):
    """A G-3-reverted write leaves the clip body clean but the recompressed
    slide JPEGs already sit in Clippings/_media/<slug>/ - orphans with no clip
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
    images and writes the digest TEXT to `digest_file` (untrusted -> treated as
    data, never executed); the tool inserts exactly ONE ### Slide digest H3
    inside ## Crawled content (where the pending marker sat) and strips the
    single <!-- slides-pending-digest --> marker. Scoped-G-3 is enforced two
    ways: (1) the reconstruction check proves the transform is exactly one H3
    added + one marker removed; (2) the post-write fm_raw hash equality proves
    the frontmatter is byte-identical (the digest only ever touches the body).
    Reverts to baseline on any violation. Note (mixed carousels): video
    transcripts are labeled by ORIGINAL carousel item index while image files
    are compacted sequential slide-NN; the digest references the slide-NN image
    files. Exit 0 success, 1 usage, non-zero (reverted) on G-3 failure."""
    if digest_file is None or not clip.is_file() or not digest_file.is_file():
        print("ig-media-fetch --apply-digest: need <clip> and --digest-file "
              "<existing file>", file=sys.stderr)
        return 1
    text, has_crlf = read_clip(clip)
    baseline = _sha(text)   # normalized-text baseline (CRLF contract)
    fm, fm_raw, body, present = parse_frontmatter(text)
    if not present:
        print("ig-media-fetch --apply-digest: no frontmatter", file=sys.stderr)
        return 1
    marker = "<!-- slides-pending-digest -->"
    if body.count(marker) != 1:
        print("ig-media-fetch --apply-digest: expected exactly one pending "
              "marker; found %d" % body.count(marker), file=sys.stderr)
        return 1
    digest = digest_file.read_text(encoding="utf-8").strip()
    # Untrusted digest text must never carry the control marker: neutralize any
    # smuggled literal occurrence to an inert ASCII form so it can't be mistaken
    # for the clip's own single control marker.
    digest = digest.replace(marker, "[slides-pending-digest]")
    h3 = "### Slide digest\n" + digest + "\n"
    # Insert the H3 immediately before the pending marker, then strip the marker.
    idx = body.index(marker)
    new_body = body[:idx] + h3 + "\n" + body[idx + len(marker):]
    new_body = new_body.replace(marker, "", 1) if marker in new_body else new_body
    # Scoped-G-3: removing our exactly-one added H3 block and re-inserting the
    # marker must reproduce the baseline body byte-for-byte.
    reconstructed = new_body.replace(h3 + "\n", marker, 1)
    if reconstructed != body:
        print("ig-media-fetch --apply-digest: scoped-G-3 reconstruction "
              "mismatch; refusing", file=sys.stderr)
        return 3
    new_text = f"---\n{fm_raw}\n---\n{new_body}"
    write_clip(clip, new_text, has_crlf)
    disk, _ = read_clip(clip)
    dfm, dfm_raw, dbody, dpresent = parse_frontmatter(disk)
    # FM immutability invariant: post-write fm_raw hash == pre-write fm_raw
    # hash (the digest only ever touches the body). No YAML-validate step:
    # under `uv run` without --with pyyaml it would be a permanent no-op.
    ok = dpresent and dbody == new_body and _sha(dfm_raw) == _sha(fm_raw)
    if not ok:
        write_clip(clip, text, has_crlf)   # revert
        if _sha(read_clip(clip)[0]) != baseline:
            print("ig-media-fetch --apply-digest: REVERT FAILED", file=sys.stderr)
        print("ig-media-fetch --apply-digest: post-write verify failed; "
              "reverted", file=sys.stderr)
        return 3
    print(f"OK apply-digest {clip.name}: 1 ### Slide digest H3 added, marker stripped")
    return 0


def run_flag_screen(clip: Path, detail: str) -> int:
    """Mechanical injection re-screen writer (Step 5). The Step-5 scanner
    (harvest-clip-body-batch --scan-only) is READ-ONLY; when it HITS, the agent
    hands the comma-joined pattern-class names (or `screen-error` on a fail-
    closed scanner error) here and the TOOL writes ONLY
    harvest_flag: injection-suspect + harvest_flag_detail: <detail> into the
    frontmatter -- never a freehand agent edit of attacker-influenced clip
    metadata. Same verified-write discipline as write_markers: baseline text,
    re-read from disk, body byte-identity, revert on any mismatch. Idempotent:
    an existing harvest_flag is replaced in place, not duplicated. The body is
    never touched. Exit 0 verified, 1 usage, 3 reverted."""
    if not detail or not clip.is_file():
        print("ig-media-fetch --flag-screen: need <clip> and --detail "
              "<comma-classes|screen-error>", file=sys.stderr)
        return 1
    text, has_crlf = read_clip(clip)
    fm, fm_raw, body, present = parse_frontmatter(text)
    if not present:
        print("ig-media-fetch --flag-screen: no frontmatter", file=sys.stderr)
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
        print("ig-media-fetch --flag-screen: post-write verify failed; "
              "reverted", file=sys.stderr)
        return 3
    print(f"OK flag-screen {clip.name}: harvest_flag=injection-suspect "
          f"detail={detail}")
    return 0


def main():
    args = parse_args(sys.argv[1:])
    if args.apply_digest is not None:
        sys.exit(run_apply_digest(args.apply_digest, args.digest_file))   # Task 5
    if args.flag_screen is not None:
        sys.exit(run_flag_screen(args.flag_screen, args.detail))   # Step 5 re-screen
    if args.vault is None or not args.vault.is_dir():
        print("ig-media-fetch: vault path required (or not a dir)", file=sys.stderr)
        sys.exit(1)
    clips = find_clips(args.vault, args.include_evidence)
    selected = []
    for p in clips:
        try:
            text, has_crlf = read_clip(p)
        except Exception:
            continue
        fm, fm_raw, body, present = parse_frontmatter(text)
        if not present:
            continue
        ig = is_selected(fm, fm_raw, body)
        if ig:
            selected.append((p, ig))
    matched_total = len(selected)
    selected = selected[: args.limit] if args.limit > 0 else selected
    remaining = matched_total - len(selected)

    if args.dry_run:
        for p, ig in selected:
            print(f"PLAN {p.relative_to(args.vault).as_posix()} -- "
                  f"would fetch {ig['kind']}/{ig['shortcode']} [dry-run]")
        print(f"\nig-media-fetch: {len(selected)} selected, 0 enriched "
              f"(dry_run=True)")
        if remaining > 0:
            print(f"ig-media-fetch: {matched_total} matched, {len(selected)} "
                  f"processed, {remaining} remaining (capped by --limit; pass "
                  f"--limit 0 for all)")
        sys.exit(0)

    if not selected:
        # No-op run (no Clippings/ dir, or zero selectable clips): report the
        # standard summary and exit 0 WITHOUT preflight - a run with nothing to
        # do must not fail on missing gallery-dl/ffmpeg/cookies.
        print(f"\nig-media-fetch: {len(selected)} selected, 0 enriched, "
              f"0 partial, 0 failed")
        sys.exit(0)

    enrich_batch(args, selected, matched_total, remaining)   # Task 2+


if __name__ == "__main__":
    main()
