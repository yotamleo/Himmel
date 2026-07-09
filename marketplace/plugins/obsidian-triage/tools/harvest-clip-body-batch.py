#!/usr/bin/env python3
"""
harvest-clip-body-batch.py — bulk-mark unharvested clips via the clip-body path.

Implements the mechanical subset of /harvest-clips that needs no LLM:
- Find Clippings/*.md without `harvested_at:`.
- Skip github URLs (need luna-ingest skill — LLM dispatch, defer).
- Skip unparseable frontmatter (operator must inspect).
- Apply URL canonicalization rules per Phase 3.
- Injection-screen the clip's untrusted content — body PLUS the full raw
  frontmatter region (HIMMEL-256, flag-only).
- Insert the four harvest_* markers (plus optional `harvest_flag` +
  `harvest_flag_detail` on injection hits) via Phase 5 frontmatter write.
- Skip/fail outcomes with injection hits still persist `harvest_flag` +
  `harvest_flag_detail` (frontmatter-only write) — a flagged clip never
  reaches /triage-clips unscreened.
- No body mutation (G-3 invariant for clip-body path).

Idempotent. Re-running skips already-harvested clips.

Usage:
    python harvest-clip-body-batch.py <vault-path> [--dry-run] [--limit N]
    python harvest-clip-body-batch.py <vault-path> --firecrawl-thin [--firecrawl-budget N] [--dry-run]
        Opt-in escalation (LUNA-27 / HIMMEL-320): for thin-body
        article/web clips, fetch clean markdown via firecrawl's
        /v2/scrape API and write it as a `## Harvested content` section
        instead of leaving the clip thin. Needs FIRECRAWL_API_KEY (and
        optionally FIRECRAWL_BASE_URL for self-hosted). Credit-conscious:
        skips X/github/youtube (owned by cheaper paths) and caps scrape
        calls at --firecrawl-budget (default 20) per run. Default runs
        never touch firecrawl.
    python harvest-clip-body-batch.py --scan-only <file>
        Injection-scan one file; print one matched pattern-class name per
        line. Exit 0 = clean, 1 = hits, 2 = error. The mechanical executor
        for harvest-clips.md Phase 4.5.
    python harvest-clip-body-batch.py <vault-path> --rescan-flags [--dry-run]
        One-time backfill: scan already-harvested clips (pre-HIMMEL-256
        harvests bypassed the screen); on hits add ONLY the harvest_flag +
        harvest_flag_detail keys.

Cross-platform paths via pathlib. Windows / Git Bash / macOS / Linux all work.

LUNA-26 batch tooling. Triage stage stays LLM-driven via /triage-clips.
"""
import argparse
import re
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse, parse_qsl, urlencode

# Force UTF-8 stdout on Windows so clip filenames + URLs containing
# non-ASCII (en-dash, arrow, emoji) don't crash the print() pipeline
# under cp1252.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

TODAY = None  # set in main from --date or system

# URL canonicalization rules from harvest-clips.md Phase 3.
TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "ref", "source", "mc_cid", "mc_eid",
}

# Firecrawl thin-body escalation (LUNA-27 / HIMMEL-320). Opt-in via
# --firecrawl-thin: a credit-conscious escalation lane that fetches clean
# markdown for clips the Web Clipper captured thinly. Default runs never
# touch firecrawl — the free tier (1000 credits/mo) is scarce.
FIRECRAWL_DEFAULT_BASE_URL = "https://api.firecrawl.dev"
FIRECRAWL_DEFAULT_BUDGET = 20  # max scrape calls per run (~1 credit each)

# Hosts firecrawl must NOT scrape — a cheaper/better path already owns them:
#   x.com / twitter → twitter-cli-enrich (X anti-automation; firecrawl
#       can't auth a logged-in session)
#   github.com → luna-ingest gh-api (the github-ingest path; never reaches
#       the clip-body path here anyway, but listed for defence-in-depth)
#   youtube → playwright-crawl-youtube (transcript path)
#   reddit family -> reddit-enrich owns reddit (HIMMEL-769); firecrawl can't
#       auth reddit (anonymous .json is 403-blocked; burner cookies required)
#   instagram → ig-media-fetch owns it (HIMMEL-770 media rung; firecrawl
#       can't pass the IG login wall or extract media anyway)
FIRECRAWL_SKIP_HOSTS = {
    "x.com", "twitter.com", "mobile.twitter.com", "www.twitter.com", "www.x.com",
    "github.com", "www.github.com",
    "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be",
    "reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "np.reddit.com", "m.reddit.com", "redd.it",
    "instagram.com", "www.instagram.com", "m.instagram.com",
}

# Curated platform hosts that need dedicated enrichers when clipper output is
# thin. Generic article hosts intentionally stay plain thin-body partials.
ENRICHER_GAP_HOSTS = {
    "tiktok.com",
    "linkedin.com",
    "bsky.app",
    "threads.net",
    "facebook.com",
    "pinterest.com",
    "twitch.tv",
    "spotify.com",
    "mastodon.social",
}

# Thin-body heuristic (harvest-clips.md Phase 4): a clip-body clip is NOT
# thin if it carries one of these section headings with real content.
_RICH_SECTION_HEADINGS = ("## highlights", "## the idea", "## summary", "## key points")

# Prompt-injection screen (HIMMEL-256, harvest-clips.md Phase 4.5).
# CANONICAL pattern list — the runbook describes these classes in prose;
# keep the two in sync. Flag-only: a match adds
# `harvest_flag: injection-suspect` frontmatter. No deletion, no
# quarantine, no body modification.
# Regex-DoS safety: every pattern is linear-time — no nested quantifiers;
# free gaps are bounded (`.{0,40}`); matching is per-line so input size
# per search call is one line.
INJECTION_PATTERNS = [
    ("instruction-override",
     r"\b(ignore|disregard|forget|do not follow)\s+(all\s+|any\s+)?(your\s+)?"
     r"(previous|prior|above|earlier|preceding|original|system)\s+"
     r"(instructions?|prompts?|directions?|rules|context)\b"),
    ("fake-role-tag",
     r"<\s*/?\s*(system|assistant)\s*>"
     r"|<\|im_(start|end)\|>"
     r"|\[\s*/?\s*(INST|SYSTEM)\s*\]"),
    ("reader-agent-tool-invocation",
     r"\b(you\s+(must|should)\s+now|please)\s+(run|execute|invoke|call|use)\b"
     r".{0,40}\b(tool|command|bash|shell|terminal)\b"),
    ("allowlist-manipulation",
     r"\b(approve|add|modify|edit|update)\b.{0,40}"
     r"\b(allowlist|allow-list|whitelist|pairing|permissions?|access\.json)\b"),
    ("prompt-exfiltration",
     r"\b(reveal|print|show|output|exfiltrate)\b.{0,40}"
     r"\b(system\s+prompt|hidden\s+instructions|your\s+instructions)\b"),
]
_INJECTION_RE = [(name, re.compile(pat, re.IGNORECASE)) for name, pat in INJECTION_PATTERNS]

# Tool-written flag lines, excluded from the frontmatter scan so re-scanning
# an already-flagged clip can't self-trigger on its own harvest_flag_detail
# (the class names could otherwise collide with future patterns). The
# exclusion is EXACT-SHAPE: only `harvest_flag: injection-suspect` and a
# `harvest_flag_detail:` whose value is a comma-joined list of KNOWN class
# names (+ the fail-closed `screen-error` token) are excluded. An attacker
# smuggling a payload into a fake harvest_flag_detail: line cannot match
# this shape, so the payload line still gets scanned.
_FLAG_TOKENS = "|".join(
    [re.escape(name) for name, _ in INJECTION_PATTERNS] + ["screen-error"]
)
_TOOL_FLAG_LINE_RE = re.compile(
    r"^(harvest_flag:[ \t]*injection-suspect"
    r"|harvest_flag_detail:[ \t]*(%s)(,(%s))*)[ \t]*$" % (_FLAG_TOKENS, _FLAG_TOKENS)
)


def scan_injection(body: str) -> list:
    """Return the names of injection-pattern classes matching the body.

    Line-by-line scan (untrusted web text never feeds a multi-line
    regex). Returns [] for clean bodies. Detection only — the caller
    decides what to do with a hit; this function never mutates anything.
    """
    hits = []
    lines = body.split("\n")
    for name, rx in _INJECTION_RE:
        for line in lines:
            if rx.search(line):
                hits.append(name)
                break
    return hits


def scan_clip(fm_raw: str, body: str) -> list:
    """Injection-scan the clip's untrusted content: the body PLUS the FULL
    raw frontmatter region. parse_frontmatter is lossy (it captures only
    the first physical line per key), so a multiline `title:` value or an
    unmapped key (`description:` etc.) would evade a fm.get()-based scan
    (HIMMEL-256 final CR). Tool-written harvest_flag/_detail lines are
    excluded via _TOOL_FLAG_LINE_RE so a re-scan of an already-flagged
    clip stays stable. One combined scan_injection call keeps hit classes
    deduped (a class counts once whether it hits fm, body, or both)."""
    fm_lines = [ln for ln in fm_raw.split("\n") if not _TOOL_FLAG_LINE_RE.match(ln)]
    untrusted = "\n".join(fm_lines) + "\n" + body
    return scan_injection(untrusted)


def canonicalize(url: str):
    """Apply per-domain canonical rules. Returns canonical URL string,
    or None if the input is unparseable (caller routes the clip to a
    skipped/failed outcome rather than writing a corrupt canonical)."""
    try:
        p = urlparse(url.strip().strip('"'))
    except Exception:
        return None
    if not p.hostname:
        return None
    host = (p.hostname or "").lower()
    path = p.path
    query = p.query

    # x.com / twitter.com / mobile.twitter.com → x.com
    if host in {"x.com", "twitter.com", "mobile.twitter.com", "www.twitter.com", "www.x.com"}:
        # Keep path through /status/<id> — strip trailing extras.
        m = re.match(r"(/[^/]+/status/\d+)", path)
        if m:
            path = m.group(1)
        return urlunparse(("https", "x.com", path, "", "", ""))

    # youtube.com / youtu.be → youtube.com/watch?v=<id>
    if host in {"youtu.be", "www.youtu.be"}:
        vid = path.lstrip("/").split("/")[0]
        return f"https://youtube.com/watch?v={vid}" if vid else url
    if host in {"youtube.com", "www.youtube.com", "m.youtube.com"}:
        params = dict(parse_qsl(query))
        vid = params.get("v")
        if vid:
            return f"https://youtube.com/watch?v={vid}"
        return url

    # github.com — strip /tree/<branch>, /blob/<branch>/<path>, trailing /, lowercase owner/repo.
    if host in {"github.com", "www.github.com"}:
        parts = [p for p in path.split("/") if p]
        if len(parts) >= 2:
            owner, repo = parts[0].lower(), parts[1].lower()
            rest = parts[2:]
            # Strip /tree/<branch> or /blob/<branch>
            if rest and rest[0] in {"tree", "blob"} and len(rest) >= 2:
                rest = []
            new_path = "/" + "/".join([owner, repo] + rest)
            return urlunparse(("https", "github.com", new_path.rstrip("/"), "", "", ""))
        return url

    # reddit — host -> www.reddit.com, drop query/fragment, strip trailing slash,
    # lowercase the /r/<subreddit> segment. redd.it short links are left
    # untouched (a network HEAD redirect is needed — the reddit-enrich rung
    # resolves them first, then feeds the resolved full URL back through here).
    # Mirrors lib/url-canonical.mjs REDDIT_HOSTS exactly.
    if host in {"reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "np.reddit.com", "m.reddit.com"}:
        parts = [seg for seg in path.split("/") if seg]
        if len(parts) >= 2 and parts[0].lower() == "r":
            parts[0] = "r"
            parts[1] = parts[1].lower()
        new_path = ("/" + "/".join(parts)) if parts else ""
        return urlunparse(("https", "www.reddit.com", new_path.rstrip("/"), "", "", ""))

    # medium.com — drop ?source=
    if host.endswith("medium.com"):
        params = [(k, v) for (k, v) in parse_qsl(query) if k != "source"]
        return urlunparse((p.scheme, host, path, "", urlencode(params), ""))

    # Generic — drop tracking params.
    params = [(k, v) for (k, v) in parse_qsl(query) if k.lower() not in TRACKING_PARAMS]
    new_query = urlencode(params)
    return urlunparse((p.scheme, host, path, "", new_query, ""))


def is_github_url(url: str) -> bool:
    try:
        host = (urlparse(url.strip().strip('"')).hostname or "").lower()
    except Exception:
        return False
    return host in {"github.com", "www.github.com"}


def _normalized_host(url: str) -> str:
    try:
        host = (urlparse(url.strip().strip('"')).hostname or "").lower()
    except Exception:
        return ""
    return host[4:] if host.startswith("www.") else host


def enricher_gap_host(canonical: str) -> str | None:
    """Return the harvest_enricher_gap host for thin known-platform clips.

    Dedicated enricher routes are excluded; generic article hosts are not
    classified. Matching is suffix-aware so a platform's share-link subdomain
    (open.spotify.com, clips.twitch.tv, m.facebook.com, …) folds to its base
    domain — that base is the roll-up key (one enricher per platform, not per
    subdomain). Substack-hosted publications keep their exact subdomain.
    """
    host = _normalized_host(canonical)
    if not host or host in FIRECRAWL_SKIP_HOSTS:
        return None
    if host.endswith(".substack.com"):
        return host
    for base in ENRICHER_GAP_HOSTS:
        if host == base or host.endswith("." + base):
            return base
    return None


def is_thin_body(body: str) -> bool:
    """harvest-clips.md Phase 4 thinness heuristic: True iff the body has
    fewer than 10 non-blank, non-heading lines AND carries no
    Highlights / The Idea / Summary / Key Points section with real
    content (>40 chars below the heading, before the next H2)."""
    content_lines = [
        ln for ln in body.split("\n")
        if ln.strip() and not ln.lstrip().startswith("#")
    ]
    if len(content_lines) >= 10:
        return False
    lowered = body.lower()
    for heading in _RICH_SECTION_HEADINGS:
        idx = lowered.find(heading)
        if idx < 0:
            continue
        chars = 0
        for ln in body[idx:].split("\n")[1:]:
            if ln.lstrip().startswith("## "):
                break
            chars += len(ln.strip())
        if chars > 40:
            return False
    return True


def _is_private_host(host: str) -> bool:
    """True for hosts that must never be shipped to an external scraper:
    localhost, internal TLDs (.local/.lan/.internal), and RFC1918 / loopback
    / link-local / reserved IP literals. Mirrors the harvest-clips.md G-1
    privacy gate for the firecrawl egress path."""
    import ipaddress
    h = host.lower().strip(".")
    if h == "localhost" or h.endswith((".local", ".lan", ".internal")):
        return True
    try:
        ip = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return False
    return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved


def firecrawl_eligible(canonical: str) -> bool:
    """A canonical URL is firecrawl-eligible iff it is http(s), carries no
    basic-auth credentials, and its host is neither a private/internal host
    (G-1 privacy gate — don't leak internal URLs to a 3rd-party scraper) nor
    one owned by a cheaper/better path (X, github, youtube). Keeps the scarce
    free-tier credits aimed at genuine public article/web URLs."""
    try:
        p = urlparse(canonical)
    except Exception:
        return False
    if p.scheme not in ("http", "https"):
        return False
    if p.username or p.password:
        return False  # basic-auth userinfo — never forward creds to firecrawl
    host = (p.hostname or "").lower()
    if not host or host in FIRECRAWL_SKIP_HOSTS:
        return False
    return not _is_private_host(host)


def _revert(path: Path, original: str) -> None:
    """Best-effort restore of a clip to its pre-write content. Swallows a
    revert-time write error (nothing more we can do — the failure is already
    being reported to the operator) rather than masking the original error."""
    try:
        path.write_text(original, encoding="utf-8", newline="\n")
    except Exception:
        pass


def insert_harvested_section(body: str, section_md: str):
    """Insert a `## Harvested content` block before the first line-anchored
    `## Source` heading (else at the top of the body). Returns
    (new_body, insert_ok); insert_ok asserts the original body content was
    only inserted-into, never altered (G-3 body-write invariant)."""
    block = section_md if section_md.endswith("\n\n") else section_md.rstrip("\n") + "\n\n"
    m = re.search(r"(?m)^## Source\b", body)
    if m:
        before, after = body[:m.start()], body[m.start():]
    else:
        before, after = "", body
    return before + block + after, (before + after == body)


class FirecrawlClient:
    """Thin firecrawl /v2/scrape client (stdlib urllib — no new deps).
    Injectable for tests: override `scrape`. `base_url` defaults to the
    hosted API but honors FIRECRAWL_BASE_URL so self-hosted firecrawl
    instances (open source, AGPL) work for operators with more budget."""

    def __init__(self, api_key, base_url=None, budget=FIRECRAWL_DEFAULT_BUDGET, timeout=45):
        self.api_key = api_key
        self.base_url = (base_url or FIRECRAWL_DEFAULT_BASE_URL).rstrip("/")
        self.remaining = budget
        self.timeout = timeout

    def scrape(self, url: str) -> str:
        """POST /v2/scrape, return data.markdown. Raises on any failure
        (HTTP error, success=false, empty markdown) — the caller routes a
        failed scrape to a retryable partial outcome."""
        import json
        import urllib.request
        payload = json.dumps({"url": url, "formats": ["markdown"]}).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base_url}/v2/scrape",
            data=payload,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        if not data.get("success"):
            raise RuntimeError(f"firecrawl success=false: {str(data)[:200]}")
        md = (data.get("data") or {}).get("markdown")
        if not md or not md.strip():
            raise RuntimeError("firecrawl returned empty markdown")
        return md


def parse_frontmatter(text: str):
    """Return (fm_dict, fm_raw, body, frontmatter_present_flag).
    Minimal YAML-ish parse for our shape: top-level key: value. No nested parsing."""
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


def already_harvested(fm_raw: str) -> bool:
    return bool(re.search(r"^harvested_at:[\s]*\S", fm_raw, re.MULTILINE))


def insert_fm_lines(fm_raw: str, new_lines: list) -> str:
    """Insert zero-indent YAML key lines after the last existing non-empty
    frontmatter line, preserving existing content."""
    lines = fm_raw.split("\n")
    # Find the last non-empty line.
    insert_idx = len(lines)
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip():
            insert_idx = i + 1
            break
    return "\n".join(lines[:insert_idx] + new_lines + lines[insert_idx:])


def insert_markers(fm_raw: str, markers: dict) -> str:
    """Insert the harvest_* markers — the four core keys, plus the optional
    `harvest_flag` + `harvest_flag_detail` pair when the injection screen
    hit. A key already present in the frontmatter is REPLACED in place (the
    runbook's "replace in place, do NOT duplicate" contract — the reddit-enrich
    rung and luna-ingest both write harvest_url_canonical, so a re-harvest must
    not emit a duplicate YAML key); any key not yet present is appended after
    the last existing top-level key. New keys are zero-indent YAML."""
    pairs = [
        ("harvested_at", f"harvested_at: {markers['harvested_at']}"),
        ("harvest_skill", f"harvest_skill: {markers['harvest_skill']}"),
        ("harvest_url_canonical", f'harvest_url_canonical: "{markers["harvest_url_canonical"]}"'),
        ("harvest_status", f"harvest_status: {markers['harvest_status']}"),
    ]
    if "harvest_flag" in markers:
        pairs.append(("harvest_flag", f"harvest_flag: {markers['harvest_flag']}"))
    if "harvest_flag_detail" in markers:
        pairs.append(("harvest_flag_detail", f"harvest_flag_detail: {markers['harvest_flag_detail']}"))
    lines = fm_raw.split("\n")
    seen = set()
    for i, line in enumerate(lines):
        for key, new_line in pairs:
            if re.match(rf"^{re.escape(key)}:", line):
                lines[i] = new_line
                seen.add(key)
                break
    remaining = [new_line for key, new_line in pairs if key not in seen]
    fm_replaced = "\n".join(lines)
    if not remaining:
        return fm_replaced
    return insert_fm_lines(fm_replaced, remaining)


def insert_frontmatter_pairs(fm_raw: str, pairs: list[tuple[str, str]], preserve_existing: set[str] | None = None) -> str:
    """Replace/add YAML frontmatter pairs while optionally preserving keys.

    Used for frontmatter-only marks that do not carry the full harvest marker
    set. New keys are appended with the same zero-indent style as harvest_*.
    """
    preserve_existing = preserve_existing or set()
    lines = fm_raw.split("\n")
    seen = set()
    filtered_pairs = list(pairs)
    for i, line in enumerate(lines):
        for key, new_line in filtered_pairs:
            if re.match(rf"^{re.escape(key)}:", line):
                seen.add(key)
                if key not in preserve_existing:
                    lines[i] = new_line
                break
    remaining = [new_line for key, new_line in filtered_pairs if key not in seen]
    fm_replaced = "\n".join(lines)
    if not remaining:
        return fm_replaced
    return insert_fm_lines(fm_replaced, remaining)


def persist_thin_partial(path: Path, text: str, fm: dict, fm_raw: str, body: str, gap_host: str | None, hits: list) -> bool:
    """Write only frontmatter marks for a default thin-body partial.

    Body bytes must remain identical or the original file is restored. Existing
    harvest_enricher_gap and harvest_flag keys are preserved for idempotence and
    to avoid clobbering injection semantics.
    """
    pairs = [("harvest_status", "harvest_status: partial")]
    preserve = {"harvest_enricher_gap"}
    if "harvest_flag" not in fm:
        if hits:
            pairs.append(("harvest_flag", "harvest_flag: injection-suspect"))
            pairs.append(("harvest_flag_detail", f"harvest_flag_detail: {','.join(hits)}"))
        else:
            pairs.append(("harvest_flag", "harvest_flag: thin-body"))
    elif hits and "harvest_flag_detail" not in fm and fm.get("harvest_flag") == "injection-suspect":
        pairs.append(("harvest_flag_detail", f"harvest_flag_detail: {','.join(hits)}"))
    if gap_host and "harvest_enricher_gap" not in fm:
        pairs.append(("harvest_enricher_gap", f"harvest_enricher_gap: {gap_host}"))
    new_fm = insert_frontmatter_pairs(fm_raw, pairs, preserve_existing=preserve)
    path.write_text(f"---\n{new_fm}\n---\n{body}", encoding="utf-8", newline="\n")
    _dfm, _draw, disk_body, disk_ok = parse_frontmatter(path.read_text(encoding="utf-8"))
    if not disk_ok or disk_body != body:
        path.write_text(text, encoding="utf-8", newline="\n")
        return False
    return True

def persist_flag_only(path: Path, text: str, fm_raw: str, body: str, hits: list) -> bool:
    """Write ONLY the harvest_flag + harvest_flag_detail keys into the
    frontmatter (no harvest markers). G-3: re-read from disk, verify the
    body is byte-identical, revert to `text` on any mismatch. Returns True
    on a verified write, False after a revert. Shared by the skip/fail
    paths in process_clip and the --rescan-flags backfill."""
    new_fm = insert_fm_lines(fm_raw, [
        "harvest_flag: injection-suspect",
        f"harvest_flag_detail: {','.join(hits)}",
    ])
    path.write_text(f"---\n{new_fm}\n---\n{body}", encoding="utf-8", newline="\n")
    _dfm, _draw, disk_body, disk_ok = parse_frontmatter(path.read_text(encoding="utf-8"))
    if not disk_ok or disk_body != body:
        path.write_text(text, encoding="utf-8", newline="\n")
        return False
    return True


def process_clip(path: Path, dry_run: bool, firecrawl=None) -> tuple[str, str, list]:
    """Return (glyph, message, injection_hits) per logging contract.

    injection_hits is returned STRUCTURALLY (not just embedded in the
    message) so main() can list flagged clips in the run report even when
    the harvest write itself failed — no substring sniffing on messages."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as e:
        return ("x", f"failed (read): {e}", [])
    fm, fm_raw, body, fm_present = parse_frontmatter(text)
    if not fm_present:
        return ("o", "skipped (frontmatter): no closing --- delimiter", [])
    if already_harvested(fm_raw):
        return ("o", "skipped (already-harvested)", [])
    # Injection screen (HIMMEL-256) — flag-only, never blocks the harvest.
    # Runs BEFORE the outcome branches so skips/failures still carry the
    # hit classes. Scans body + full raw frontmatter (scan_clip).
    injection_hits = scan_clip(fm_raw, body)
    flag_suffix = ""
    if injection_hits:
        flag_suffix = f" [injection-suspect: {', '.join(injection_hits)}]"

    def flagged_early(glyph: str, msg: str) -> tuple[str, str, list]:
        """Skip/fail return that still PERSISTS the flag. /triage-clips
        keys ONLY off `harvest_flag:` frontmatter (it has no harvested-
        gate), so a flagged clip that exits via a skip/fail path must
        carry the flag or it reaches triage with full-body trust —
        the runbook's "never reaches /triage-clips unscreened" clause
        (HIMMEL-256 final CR). Frontmatter-only write; respects --dry-run;
        idempotent (clips already carrying harvest_flag are not rewritten)."""
        suffix = flag_suffix
        if injection_hits and "harvest_flag" not in fm:
            if dry_run:
                suffix += " [flag-write: dry-run]"
            elif persist_flag_only(path, text, fm_raw, body, injection_hits):
                suffix += " [harvest_flag written]"
            else:
                suffix += " [flag-write failed (G-3); reverted]"
        return (glyph, f"{msg}{suffix}", injection_hits)

    source = fm.get("source", "").strip().strip('"')
    if not source:
        return flagged_early("o", "skipped (frontmatter): no source: field")
    canonical = canonicalize(source)
    if canonical is None:
        return flagged_early("x", f"failed (canonicalize): unparseable source URL: {source!r}")
    if '"' in canonical or "\n" in canonical:
        # Would corrupt the quoted YAML value. Refuse rather than write garbage.
        return flagged_early("x", f"failed (canonicalize): canonical URL contains unsafe chars: {canonical!r}")
    if is_github_url(canonical):
        # Phase 5 luna-ingest replaces existing harvest_* keys in place
        # (no duplication) when the LLM later harvests this clip.
        return flagged_early("o", f"skipped (github-ingest needed; deferred to LLM): {canonical}")

    # Firecrawl thin-body escalation (opt-in --firecrawl-thin). Only fires
    # for genuine article/web URLs whose clipper-captured body is thin —
    # the LUNA-27 gap. X/github/youtube are excluded (owned elsewhere) and
    # fall straight through to the normal clip-body path, so the flag's
    # blast radius is exactly "thin eligible article clips". Budget-
    # exhausted / fetch-failed clips return a retryable partial WITHOUT
    # marking harvested_at, so a later run retries them.
    if firecrawl is not None and firecrawl_eligible(canonical) and is_thin_body(body):
        if dry_run:
            # Never spend a credit on a dry-run — report the plan only.
            return ("v", f"would harvest via firecrawl (thin-body escalation): {canonical} [dry-run]{flag_suffix}", injection_hits)
        if firecrawl.remaining <= 0:
            return ("~", "partial (thin-body): firecrawl budget exhausted this run; re-run to retry", injection_hits)
        try:
            md = firecrawl.scrape(canonical)
        except Exception as e:
            return ("~", f"partial (thin-body): firecrawl fetch failed ({type(e).__name__}: {str(e)[:120]}); re-run to retry", injection_hits)
        firecrawl.remaining -= 1
        section = (
            f"## Harvested content\n"
            f"<!-- harvest-clips {TODAY} via firecrawl ({canonical}) -->\n\n"
            f"{md.strip()}\n\n"
        )
        new_body, insert_ok = insert_harvested_section(body, section)
        if not insert_ok:
            # Credit already spent (decremented above) — note it like the
            # other post-fetch failures. Nothing was written, so no revert
            # and injection_hits (not merged_hits — fetched md never landed).
            return ("x", "failed (G-3, credit spent): firecrawl insert altered original body content", injection_hits)
        # Re-screen the fetched (untrusted web) markdown; merge with the
        # pre-harvest hits so a clip flagged by either source carries it.
        fc_hits = scan_injection(md)
        merged_hits = injection_hits + [h for h in fc_hits if h not in injection_hits]
        markers = {
            "harvested_at": TODAY,
            "harvest_skill": "firecrawl",
            "harvest_url_canonical": canonical,
            "harvest_status": "ok",
        }
        if merged_hits:
            markers["harvest_flag"] = "injection-suspect"
            markers["harvest_flag_detail"] = ",".join(merged_hits)
        new_text = f"---\n{insert_markers(fm_raw, markers)}\n---\n{new_body}"
        # The scrape already spent a credit (firecrawl.remaining decremented
        # above), so EVERY post-fetch failure below notes "credit spent" — an
        # operator can't otherwise tell a free failure from a paid one. The
        # initial write is wrapped (unlike the clip-body path) because a raise
        # here would otherwise propagate uncaught through main()'s loop and
        # abort the whole batch after the credit was already burned.
        try:
            path.write_text(new_text, encoding="utf-8", newline="\n")
        except Exception as e:
            _revert(path, text)
            return ("x", f"failed (write, credit spent): {e}; reverted", merged_hits)
        try:
            disk_text = path.read_text(encoding="utf-8")
        except Exception as e:
            _revert(path, text)
            return ("x", f"failed (post-write read, credit spent): {e}; reverted", merged_hits)
        _dfm, disk_fm_raw, disk_body, disk_present = parse_frontmatter(disk_text)
        if not disk_present or disk_body != new_body:
            _revert(path, text)
            return ("x", "failed (G-3, credit spent): firecrawl post-write body mismatch; reverted", merged_hits)
        try:
            import yaml  # type: ignore
            yaml.safe_load(disk_fm_raw)
        except ImportError:
            pass  # PyYAML optional — the structural guards above (insert_ok,
            # disk_body byte-compare) already protect the clip; this is just
            # the extra YAML-validity check, same as the clip-body path.
        except Exception as e:
            _revert(path, text)
            return ("x", f"failed (frontmatter-yaml-write, credit spent): {e}; reverted", merged_hits)
        fc_suffix = f" [injection-suspect: {', '.join(merged_hits)}]" if merged_hits else ""
        return ("v", f"harvested via firecrawl, {len(md.encode('utf-8'))}b fetched (thin-body escalation), harvest_status=ok{fc_suffix}", merged_hits)

    if is_thin_body(body):
        gap_host = enricher_gap_host(canonical)
        gap_suffix = f"; harvest_enricher_gap={gap_host}" if gap_host else ""
        if dry_run:
            return ("~", f"partial (thin-body): clipper captured only a skeleton{gap_suffix} [dry-run]{flag_suffix}", injection_hits)
        if persist_thin_partial(path, text, fm, fm_raw, body, gap_host, injection_hits):
            return ("~", f"partial (thin-body): clipper captured only a skeleton{gap_suffix}{flag_suffix}", injection_hits)
        return ("x", f"failed (G-3): thin-body frontmatter mark altered body; reverted{flag_suffix}", injection_hits)

    # clip-body path
    markers = {
        "harvested_at": TODAY,
        "harvest_skill": "clip-body",
        "harvest_url_canonical": canonical,
        "harvest_status": "ok",
    }
    if injection_hits:
        markers["harvest_flag"] = "injection-suspect"
        markers["harvest_flag_detail"] = ",".join(injection_hits)
    new_fm = insert_markers(fm_raw, markers)
    new_text = f"---\n{new_fm}\n---\n{body}"
    if dry_run:
        body_bytes = len(body.encode("utf-8"))
        return ("v", f"harvested via clip-body, {body_bytes}b content (clip-body, no fetch), harvest_status=ok{flag_suffix} [dry-run]", injection_hits)
    # Write, then re-read from disk and verify both (a) the body is
    # byte-identical to the pre-write body (clip-body G-3 invariant)
    # and (b) the frontmatter parses as YAML (Phase 5 step 5).
    # On either failure, revert to the original text and report.
    path.write_text(new_text, encoding="utf-8", newline="\n")
    try:
        disk_text = path.read_text(encoding="utf-8")
    except Exception as e:
        path.write_text(text, encoding="utf-8", newline="\n")
        return ("x", f"failed (post-write read): {e}; reverted{flag_suffix}", injection_hits)
    disk_fm, disk_fm_raw, disk_body, disk_fm_present = parse_frontmatter(disk_text)
    if not disk_fm_present:
        path.write_text(text, encoding="utf-8", newline="\n")
        return ("x", f"failed (G-3 / parse): post-write file lost frontmatter; reverted{flag_suffix}", injection_hits)
    if disk_body != body:
        path.write_text(text, encoding="utf-8", newline="\n")
        return ("x", f"failed (G-3): post-write body differs from pre-write; reverted{flag_suffix}", injection_hits)
    try:
        import yaml  # type: ignore
        yaml.safe_load(disk_fm_raw)
    except ImportError:
        # PyYAML missing — skip parse-validate but log. The minimal regex
        # parser above is structural-only; without PyYAML we cannot verify
        # full YAML semantics. Acceptable for a calibration tool.
        pass
    except Exception as e:
        path.write_text(text, encoding="utf-8", newline="\n")
        return ("x", f"failed (frontmatter-yaml-write): {e}; reverted{flag_suffix}", injection_hits)
    body_bytes = len(body.encode("utf-8"))
    return ("v", f"harvested via clip-body, {body_bytes}b content (clip-body, no fetch), harvest_status=ok{flag_suffix}", injection_hits)


def run_scan_only(path: Path) -> int:
    """--scan-only: machine-parseable single-file injection scan — the
    mechanical executor for harvest-clips.md Phase 4.5. Prints one matched
    pattern-class name per line. Exit 0 = clean, 1 = hits, 2 = error."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as e:
        print(f"scan-only: cannot read {path}: {e}", file=sys.stderr)
        return 2
    _fm, fm_raw, body, fm_present = parse_frontmatter(text)
    hits = scan_clip(fm_raw, body) if fm_present else scan_injection(text)
    for name in hits:
        print(name)
    return 1 if hits else 0


def run_rescan_flags(clips: list, vault: Path, dry_run: bool) -> int:
    """--rescan-flags: one-time backfill — clips harvested BEFORE the
    HIMMEL-256 screen shipped were never scanned. Scan body + frontmatter
    of already-harvested clips; on hits add ONLY the harvest_flag +
    harvest_flag_detail keys (no other mutation; body byte-identical or
    revert). Respects --dry-run. Clips already carrying harvest_flag are
    left untouched (operator may have cleared/kept it deliberately —
    re-adding would fight the review loop)."""
    scanned = flagged = failed = 0
    for clip in clips:
        relpath = clip.relative_to(vault).as_posix()
        try:
            text = clip.read_text(encoding="utf-8")
        except Exception as e:
            print(f"FAIL {relpath} -- failed (read): {e}", file=sys.stderr)
            failed += 1
            continue
        fm, fm_raw, body, fm_present = parse_frontmatter(text)
        if not fm_present or not already_harvested(fm_raw):
            continue  # unharvested clips get screened by the normal pass
        if "harvest_flag" in fm:
            continue
        scanned += 1
        hits = scan_clip(fm_raw, body)
        if not hits:
            continue
        flagged += 1
        if dry_run:
            print(f"FLAG {relpath} -- [injection-suspect: {', '.join(hits)}] [dry-run]")
            continue
        if not persist_flag_only(clip, text, fm_raw, body, hits):
            print(f"FAIL {relpath} -- failed (G-3): rescan write altered body; reverted", file=sys.stderr)
            failed += 1
            continue
        print(f"FLAG {relpath} -- [injection-suspect: {', '.join(hits)}]")
    print(
        f"\nharvest-clip-body-batch --rescan-flags: {scanned} scanned, "
        f"{flagged} flagged, {failed} failed. (dry_run={dry_run})"
    )
    if dry_run:
        print("  (DRY-RUN — no files modified)")
    return 4 if failed else 0


def main():
    global TODAY
    ap = argparse.ArgumentParser()
    ap.add_argument("vault", type=Path, nargs="?")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="0 = no limit")
    ap.add_argument("--date", default=None, help="Override TODAY (default: system)")
    ap.add_argument("--scan-only", type=Path, default=None, metavar="FILE",
                    help="Injection-scan one file; one hit class per line. "
                         "Exit 0=clean, 1=hits, 2=error.")
    ap.add_argument("--rescan-flags", action="store_true",
                    help="Backfill: scan already-harvested clips, add only "
                         "harvest_flag/_detail on hits.")
    ap.add_argument("--firecrawl-thin", action="store_true",
                    help="Escalation: fetch clean markdown via firecrawl for "
                         "thin-body article/web clips (needs FIRECRAWL_API_KEY). "
                         "Off by default — conserves the free-tier credits.")
    ap.add_argument("--firecrawl-budget", type=int, default=FIRECRAWL_DEFAULT_BUDGET,
                    help="Max firecrawl scrape calls per run (~1 credit each). "
                         f"Default {FIRECRAWL_DEFAULT_BUDGET}.")
    args = ap.parse_args()
    if args.scan_only is not None:
        sys.exit(run_scan_only(args.scan_only))
    if args.vault is None:
        ap.error("vault path is required (unless --scan-only)")
    import datetime
    TODAY = args.date or datetime.date.today().isoformat()

    clippings = args.vault / "Clippings"
    if not clippings.is_dir():
        print(f"harvest-clip-body-batch: no Clippings/ at {clippings}", file=sys.stderr)
        sys.exit(2)

    # Inbox-internal exclusions (harvest-clips.md "Scan for unharvested
    # clips"): _synthesis/ (/synthesize-clips proposal pages), _done/
    # (/archive-clips graduated archive), _deferred.md (backlog log) are
    # never source clips — scanning them pollutes derived/archived pages
    # with harvest_* frontmatter, and _synthesis pages (non-URL source:)
    # FAIL canonicalization → exit-4 noise.
    clips = sorted(
        p
        for p in clippings.rglob("*.md")
        if "_synthesis" not in p.parts
        and "_done" not in p.parts
        and p.name != "_deferred.md"
    )
    if args.rescan_flags:
        # Backfill mode ignores --limit (one-time full pass).
        sys.exit(run_rescan_flags(clips, args.vault, args.dry_run))

    firecrawl = None
    if args.firecrawl_thin:
        import os
        api_key = os.environ.get("FIRECRAWL_API_KEY", "").strip()
        if not api_key:
            print(
                "harvest-clip-body-batch: --firecrawl-thin requires FIRECRAWL_API_KEY "
                "in the environment.", file=sys.stderr,
            )
            sys.exit(2)
        base_url = os.environ.get("FIRECRAWL_BASE_URL", "").strip() or None
        firecrawl = FirecrawlClient(api_key, base_url=base_url, budget=args.firecrawl_budget)

    if args.limit > 0:
        clips = clips[: args.limit * 4]  # over-fetch; filter below cuts to limit

    ok = partial = failed = skipped = 0
    processed_count = 0
    flagged = []  # injection-suspect clips (HIMMEL-256) for the run report
    for clip in clips:
        if args.limit > 0 and processed_count >= args.limit:
            break
        glyph, msg, injection_hits = process_clip(clip, args.dry_run, firecrawl)
        relpath = clip.relative_to(args.vault).as_posix()
        if injection_hits:
            # Structural flag state — flagged clips reach the report even
            # when the harvest write failed (any glyph).
            flagged.append(relpath)
        if glyph == "v":
            print(f"OK  {relpath} -- {msg}")
            ok += 1
            processed_count += 1
        elif glyph == "o":
            print(f"SKIP {relpath} -- {msg}")
            skipped += 1
        elif glyph == "~":
            print(f"PART {relpath} -- {msg}")
            partial += 1
            processed_count += 1
        elif glyph == "x":
            print(f"FAIL {relpath} -- {msg}", file=sys.stderr)
            failed += 1
            processed_count += 1
    print(
        f"\nharvest-clip-body-batch: {ok} ok, {partial} partial, "
        f"{failed} failed, {skipped} skipped. (dry_run={args.dry_run})"
    )
    if flagged:
        print(
            f"harvest-clip-body-batch: {len(flagged)} flagged "
            f"injection-suspect (operator review): " + ", ".join(flagged)
        )
    if args.dry_run:
        print("  (DRY-RUN — no files modified)")
    if failed > 0:
        sys.exit(4)
    sys.exit(0)


if __name__ == "__main__":
    main()
