"""Fidelity metrics. Heuristics, documented in the report: they rank providers
on the same URLs, they do not prove a page is perfect."""
import re

ERROR_MARKERS = ("access denied", "enable javascript", "just a moment", "captcha",
                 "log in to continue", "sign in to continue", "403 forbidden",
                 "404 not found", "page not found", "are you a robot", "blocked by network security")
SHORT_BODY = 1500   # at or under this, a marker anywhere marks an error page
ERROR_WINDOW = 200  # longer bodies: only a marker in the opening block does
LINK_ONLY = re.compile(r"^\s*(?:[-*+]\s*)?!?\[[^\]]*\]\([^)]*\)\s*$")


MD_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")


def norm(s):
    """Lowercase, drop link targets and emphasis marks so formatting differences
    between engines do not read as missing content."""
    s = MD_LINK.sub(r"\1", s).replace("*", "").replace("_", "").replace("`", "")
    return re.sub(r"\s+", " ", s).strip().lower()


def boilerplate_ratio(md):
    """Share of non-empty lines that are link-only or under 4 words (nav, menus, cookie rows)."""
    lines = [ln for ln in md.splitlines() if ln.strip()]
    if not lines:
        return 1.0
    junk = sum(1 for ln in lines if LINK_ONLY.match(ln) or len(ln.split()) < 4)
    return round(junk / len(lines), 3)


def score(md, expected_title, phrase):
    md = md or ""
    low = norm(md)
    # A challenge or login page is short and marker-dominated; a long article may
    # discuss "captcha" or "404 not found" past its opening block.
    scope = low if len(low) <= SHORT_BODY else low[:ERROR_WINDOW]
    error_page = any(m in scope for m in ERROR_MARKERS)
    return {
        "success": len(md.strip()) >= 200 and not error_page,
        "title_match": norm(expected_title) in low[:5000] if expected_title else False,
        "phrase_hit": norm(phrase) in low if phrase else False,
        "boilerplate_ratio": boilerplate_ratio(md),
        "length": len(md),
    }
