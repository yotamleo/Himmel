#!/usr/bin/env python3
"""yt-scrapling-meta.py - cookieless YouTube metadata + transcript (HIMMEL-4677).

Sibling of ig-scrapling-media.py / x-scrapling-media.py, called by
playwright-crawl-youtube.mjs as its PRIMARY path (the logged-in Playwright crawl
is the fallback). Two sources, NO cookie for either:

- metadata + description: the watch page via Scrapling's stealth fetcher
  (ytInitialPlayerResponse);
- transcript: yt-dlp subtitles (json3, manual or auto captions). The page's own
  timedtext URLs are PO-token gated and come back empty outside the player, so
  the transcript never comes from the page.

Prints one JSON object:

  {"status": "ok", "title", "channel", "duration", "views", "published",
   "description", "transcript": [{"ts", "tx"}], "transcript_source": "yt-dlp",
   "transcript_error": null | str}
  {"status": "login_wall"|"removed"|"skipped"|"error", "detail": str}

A video with metadata but no transcript is still "ok", with transcript_error
set (the crawler records it as a partial).

Exit: 0 ok, 3 scrapling not installed, 4 login_wall, 5 removed, 6 error,
7 skipped (the HIMMEL-4361 route denies the `local-headless` slot: the
HARVEST_SCRAPE_DENY kill switch or the vault's .harvest-backends).

`--from-html FILE [--final-url URL]` skips the page fetch and `--subs-file FILE`
skips yt-dlp (tests).
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

TIMEOUT_MS = 60000
YTDLP_TIMEOUT = int(os.environ.get("YT_SCRAPLING_YTDLP_TIMEOUT", "180"))
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,20}$")
PLAYER_KEY = "ytInitialPlayerResponse = "
LOGIN_HOSTS = ("consent.youtube.com", "accounts.google.com")
# Sub tracks in preference order: English as authored (or YouTube's own "en"
# auto track), then the original-language auto track.
SUB_PREFERENCE = (".en.json3", ".en-orig.json3")


def _batch_module():
    """harvest-clip-body-batch.py: HIMMEL-4361 routing + the private-host guard."""
    path = Path(__file__).with_name("harvest-clip-body-batch.py")
    spec = importlib.util.spec_from_file_location("harvest_clip_body_batch", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def scrapling_permitted(vault, url):
    """The `local-headless` slot's routing, as in ig-media-fetch.py."""
    killed = {n.strip() for n in (os.environ.get("HARVEST_SCRAPE_DENY") or "").split(",")}
    if killed & {"all", "local-headless"}:
        return False
    if vault is None:
        return True
    routes = _batch_module().load_backend_routes(vault)
    if routes.error:
        return False
    hit = routes.match(url)
    if hit is None:
        return True
    mode, names = hit
    return ("local-headless" in names) == (mode == "only")


def player_response(page_html, video_id):
    """The ytInitialPlayerResponse object for this video, or None. An
    unavailable video's response carries no videoDetails at all (HIMMEL-4704):
    with no response naming this video, the first one without videoDetails but
    with a playabilityStatus stands in for it. One naming ANOTHER video never
    does."""
    dec = json.JSONDecoder()
    start = 0
    fallback = None
    while True:
        i = page_html.find(PLAYER_KEY, start)
        if i < 0:
            return fallback
        start = i + len(PLAYER_KEY)
        try:
            obj, _ = dec.raw_decode(page_html, start)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        if (obj.get("videoDetails") or {}).get("videoId") == video_id:
            return obj
        if (fallback is None and "videoDetails" not in obj
                and isinstance(obj.get("playabilityStatus"), dict)):
            fallback = obj


def _is_private(ps):
    """The playabilityStatus names a private video (its reason or messages)."""
    msgs = ps.get("messages")
    text = " ".join([str(ps.get("reason") or "")]
                    + [str(m) for m in (msgs if isinstance(msgs, list) else [])])
    return "private" in text.lower()


def _clock(seconds):
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def extract_meta(page_html, video_id, final_url=None):
    host = (urlparse(final_url or "").hostname or "").lower()
    if host in LOGIN_HOSTS:
        return {"status": "login_wall", "detail": host}
    pr = player_response(page_html, video_id)
    if pr is None:
        return {"status": "error", "detail": "no player response for this video"}
    ps = pr.get("playabilityStatus") or {}
    play = ps.get("status", "")
    if play == "LOGIN_REQUIRED":
        return {"status": "login_wall", "detail": "LOGIN_REQUIRED"}
    if play == "ERROR" and _is_private(ps):
        # A private video also reports ERROR (HIMMEL-4704): the logged-in
        # fallback may still read it, so it is a login wall, never removed.
        return {"status": "login_wall", "detail": "ERROR: private video"}
    if play == "ERROR":
        return {"status": "removed", "detail": play}
    if play == "UNPLAYABLE":
        # Region, age or members-only: recoverable, so the fallback may still run.
        return {"status": "error", "detail": play}
    vd = pr.get("videoDetails")
    if not vd:
        return {"status": "error", "detail": f"no videoDetails ({play or 'no playability status'})"}
    mf = (pr.get("microformat") or {}).get("playerMicroformatRenderer") or {}
    length = vd.get("lengthSeconds")
    return {
        "status": "ok",
        "title": vd.get("title") or "",
        "channel": vd.get("author") or mf.get("ownerChannelName") or "",
        "duration": _clock(length) if str(length or "").isdigit() else "",
        "views": vd.get("viewCount") or "",
        "published": (mf.get("publishDate") or "")[:10],
        "description": vd.get("shortDescription") or "",
    }


def parse_json3(body):
    """json3 caption events -> [{"ts": "m:ss", "tx": str}]. An event's segs
    join into one line; the auto-caption line breaks (aAppend "\\n") drop out."""
    out = []
    for ev in json.loads(body).get("events") or []:
        text = " ".join("".join(s.get("utf8", "") for s in ev.get("segs") or []).split())
        if text:
            out.append({"ts": _clock(ev.get("tStartMs", 0) / 1000), "tx": text})
    return out


def _pick_subs(folder, video_id):
    for suffix in SUB_PREFERENCE:
        p = folder / f"{video_id}{suffix}"
        if p.is_file():
            return p
    rest = sorted(folder.glob(f"{video_id}.en*.json3"))
    return rest[0] if rest else None


def fetch_transcript(video_id):
    """(segments, None) or (None, error) via yt-dlp, cookieless."""
    ytdlp = shutil.which("yt-dlp")
    if not ytdlp:
        return None, "yt_dlp_missing"
    with tempfile.TemporaryDirectory(prefix="yt-subs-") as d:
        cmd = [ytdlp, "--no-config", "--skip-download", "--no-playlist",
               "--write-subs", "--write-auto-subs", "--sub-langs", "en.*,en",
               "--sub-format", "json3", "-o", str(Path(d) / "%(id)s.%(ext)s"),
               "--", f"https://www.youtube.com/watch?v={video_id}"]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=YTDLP_TIMEOUT)
        except subprocess.TimeoutExpired:
            return None, "yt_dlp_timeout"
        except OSError:
            return None, "yt_dlp_missing"
        subs = _pick_subs(Path(d), video_id)
        if subs is None:
            return None, "transcript_empty" if proc.returncode == 0 else "yt_dlp_error"
        return _segments(subs.read_text(encoding="utf-8"))


def _segments(body):
    try:
        segs = parse_json3(body)
    except (ValueError, AttributeError):
        return None, "transcript_unparseable"
    return (segs, None) if segs else (None, "transcript_empty")


def fetch_page(url):
    """(html, final_url, status). ImportError when scrapling is missing."""
    from scrapling.fetchers import StealthyFetcher
    batch = _batch_module()
    state = {"armed": False}
    page = StealthyFetcher.fetch(
        url, headless=True, network_idle=True, timeout=TIMEOUT_MS,
        page_setup=lambda pg: batch._block_private_requests(pg, state),
        additional_args={"service_workers": "block"})
    if not state["armed"]:
        raise RuntimeError("private-host guard did not install")
    final = str(getattr(page, "url", "") or url)
    if batch._is_private_host((urlparse(final).hostname or "").lower()):
        raise RuntimeError("redirected to a private host")
    return getattr(page, "html_content", None) or "", final, getattr(page, "status", 200)


EXIT = {"ok": 0, "login_wall": 4, "removed": 5, "error": 6, "skipped": 7}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--video-id", required=True)
    ap.add_argument("--vault", type=Path)
    ap.add_argument("--from-html", type=Path)
    ap.add_argument("--final-url", default=None)
    ap.add_argument("--subs-file", type=Path)
    args = ap.parse_args(argv)
    if not VIDEO_ID_RE.match(args.video_id):
        ap.error("--video-id must be a YouTube video id")
    # Route rules match the canonical URL; the hl pin is fetch-only, or an
    # exact-video skip/only rule would stop matching (HIMMEL-4797, j2057 F1).
    canon = f"https://www.youtube.com/watch?v={args.video_id}"
    # hl=en: _is_private reads the English reason text, so ask for English
    # (HIMMEL-4797). ponytail: no language-independent private signal is known
    # in playabilityStatus, so a pinned locale it is; revisit if YouTube ignores hl.
    url = f"{canon}&hl=en"
    if not scrapling_permitted(args.vault, canon):
        out = {"status": "skipped", "detail": "local-headless denied by route or kill switch"}
        print(json.dumps(out))
        return EXIT["skipped"]
    if args.from_html:
        page_html, final, status = args.from_html.read_text(encoding="utf-8"), args.final_url, 200
    else:
        try:
            page_html, final, status = fetch_page(url)
        except ImportError:
            print(json.dumps({"status": "error", "detail": "scrapling not installed"}))
            return 3
        except Exception as e:
            print(json.dumps({"status": "error", "detail": f"{type(e).__name__}: {str(e)[:120]}"}))
            return 6
    if status == 404:
        out = {"status": "removed", "detail": "HTTP 404"}
    elif status and status >= 400:
        out = {"status": "error", "detail": f"HTTP {status}"}
    else:
        out = extract_meta(page_html, args.video_id, final)
    if out["status"] == "ok":
        if args.subs_file:
            segs, err = _segments(args.subs_file.read_text(encoding="utf-8"))
        else:
            segs, err = fetch_transcript(args.video_id)
        out.update(transcript=segs or [], transcript_source="yt-dlp", transcript_error=err)
    print(json.dumps(out, ensure_ascii=False))
    return EXIT[out["status"]]


if __name__ == "__main__":
    sys.exit(main())
