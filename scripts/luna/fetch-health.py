#!/usr/bin/env python3
"""Daily no-LLM health probes for Luna clip-source fetch integrations."""

from __future__ import annotations

import argparse
import base64
import http.cookiejar
from http.cookiejar import LoadError
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

STATUSES = (
    "ok",
    "auth-or-cookie-expired",
    "blocked-or-rate-limited",
    "transport-fail",
)
TIMEOUT_SECONDS = 30
USER_AGENT = "himmel-fetch-health/1.0"
# x.com cookies are still served under both hosts; the exported Netscape
# file carries whichever the browser session used (HIMMEL-2549).
TWITTER_COOKIE_DOMAINS = ("x.com", "twitter.com")

# Fixed known-good URLs send no Luna corpus content. The egress matrix governs
# corpus-to-provider content, so no matrix row or ledger applies; response bodies
# stay in memory and only the classification state below is persisted.
DEFAULT_URLS = {
    "reddit": "https://www.reddit.com/r/reddit.com/comments/87/the_downing_street_memo/",
    "x-fxtwitter": "https://api.fxtwitter.com/jack/status/20",
    "instagram-embed": "https://www.instagram.com/p/CG0UU3ylXnv/embed/captioned/",
    "instagram-media": "https://www.instagram.com/p/CG0UU3ylXnv/",
    "x-media": "https://x.com/Twitter/status/1354143047324299264",
    "youtube-playwright": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "firecrawl": "https://example.com/",
}


@dataclass(frozen=True)
class ProbeResult:
    status: str
    reason: str

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            raise ValueError(f"invalid fetch-health status: {self.status}")


@dataclass(frozen=True)
class HttpResult:
    status: int
    body: bytes


class AuthScopedRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Never forward Cookie/Authorization headers to an off-scope redirect."""

    def __init__(self, allowed_auth_hosts: set[str]):
        super().__init__()
        self.allowed_auth_hosts = {host.lower() for host in allowed_auth_hosts}

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        host = (urllib.parse.urlparse(newurl).hostname or "").lower()
        if host not in self.allowed_auth_hosts:
            redirected.remove_header("Cookie")
            redirected.remove_header("Authorization")
        return redirected


def resolve_home(env: dict[str, str]) -> Path:
    if os.name == "nt" and env.get("USERPROFILE"):
        return Path(env["USERPROFILE"])
    return Path(env.get("HOME") or env.get("USERPROFILE") or str(Path.home()))


def state_path(env: dict[str, str]) -> Path:
    override = env.get("HIMMEL_FETCH_HEALTH_STATE", "").strip()
    if override:
        return Path(override)
    return resolve_home(env) / ".himmel" / "fetch-health.json"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def fetch_http(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    data: bytes | None = None,
    allowed_auth_hosts: set[str] | None = None,
    timeout: int = TIMEOUT_SECONDS,
) -> HttpResult:
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    opener = urllib.request.build_opener(AuthScopedRedirectHandler(allowed_auth_hosts or set()))
    try:
        with opener.open(request, timeout=timeout) as response:
            return HttpResult(response.status, response.read())
    except urllib.error.HTTPError as error:
        return HttpResult(error.code, error.read())


def classify_http(
    result: HttpResult,
    *,
    auth_required: bool,
    valid_body: Callable[[bytes], bool],
) -> ProbeResult:
    if result.status == 429:
        return ProbeResult("blocked-or-rate-limited", "http-429")
    if result.status == 401:
        return ProbeResult("auth-or-cookie-expired", "http-401")
    if result.status == 403:
        status = "auth-or-cookie-expired" if auth_required else "blocked-or-rate-limited"
        return ProbeResult(status, "http-403")
    if result.status < 200 or result.status >= 300:
        return ProbeResult("transport-fail", f"http-{result.status}")
    if valid_body(result.body):
        return ProbeResult("ok", "known-good response validated")
    status = "auth-or-cookie-expired" if auth_required else "blocked-or-rate-limited"
    return ProbeResult(status, "unexpected response shape")


def cookie_header(cookie_file: Path, url: str) -> str:
    jar = http.cookiejar.MozillaCookieJar(str(cookie_file))
    jar.load(ignore_discard=True, ignore_expires=True)
    request = urllib.request.Request(url)
    jar.add_cookie_header(request)
    return request.get_header("Cookie") or ""


def _json(body: bytes):
    return json.loads(body.decode("utf-8"))


def probe_reddit(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    home = resolve_home(env)
    cookie_file = Path(env.get("REDDIT_COOKIE_FILE", "").strip() or home / ".luna" / "cookies" / "reddit.txt")
    if not cookie_file.is_file():
        return ProbeResult("auth-or-cookie-expired", "reddit cookie file missing")
    url = env.get("FETCH_HEALTH_REDDIT_URL", DEFAULT_URLS["reddit"]).rstrip("/") + ".json?raw_json=1"
    try:
        cookies = cookie_header(cookie_file, url)
    except (OSError, LoadError):
        return ProbeResult("auth-or-cookie-expired", "reddit cookie file unreadable")
    if not cookies:
        return ProbeResult("auth-or-cookie-expired", "reddit cookie file has no matching cookies")
    try:
        result = http(
            url,
            headers={"Accept": "application/json", "Cookie": cookies, "User-Agent": USER_AGENT},
            allowed_auth_hosts={"www.reddit.com", "reddit.com", "old.reddit.com"},
        )
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "reddit request failed")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return isinstance(data, list) and len(data) >= 2 and data[0].get("data", {}).get("children", [{}])[0].get("kind") == "t3"
        except (ValueError, KeyError, IndexError, AttributeError):
            return False

    return classify_http(result, auth_required=True, valid_body=valid)


def probe_fxtwitter(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    url = env.get("FETCH_HEALTH_FXTWITTER_URL", DEFAULT_URLS["x-fxtwitter"])
    try:
        result = http(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT})
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "fxtwitter request failed")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return data.get("code") == 200 and isinstance(data.get("tweet"), dict)
        except (ValueError, AttributeError):
            return False

    return classify_http(result, auth_required=False, valid_body=valid)


def probe_instagram_embed(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    url = env.get("FETCH_HEALTH_INSTAGRAM_EMBED_URL", DEFAULT_URLS["instagram-embed"])
    try:
        result = http(url, headers={"Accept": "text/html", "User-Agent": USER_AGENT})
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "instagram embed request failed")
    return classify_http(result, auth_required=False, valid_body=lambda body: b"Caption" in body)


def classify_command(returncode: int, stderr: str) -> ProbeResult:
    if returncode == 0:
        return ProbeResult("ok", "command probe succeeded")
    text = stderr.lower()
    if re.search(r"429|rate.?limit|too many requests|temporarily blocked|challenge", text):
        return ProbeResult("blocked-or-rate-limited", "command reported block or rate limit")
    if re.search(r"401|403|auth|login|cookie|credential|unauthorized|forbidden", text):
        return ProbeResult("auth-or-cookie-expired", "command reported authentication failure")
    return ProbeResult("transport-fail", "command probe failed")


def run_command(args: list[str], *, env: dict[str, str], timeout: int = TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
    # Foreign CLIs (gallery-dl, twitter) embed their own Python runtime. A
    # PYTHONHOME/PYTHONPATH inherited from the invoking interpreter (e.g. a uv
    # python stub that injects its own PYTHONHOME) points that runtime at the
    # WRONG stdlib and crashes it (SRE module mismatch class); PYTHONPATH is
    # stripped alongside it defensively (no observed repro, same failure class).
    # Scrub only what reaches subprocess.run — the caller's `env` dict (used for
    # config lookups like TWITTER_AUTH_TOKEN) is left untouched.
    child_env = {k: v for k, v in env.items() if k not in ("PYTHONHOME", "PYTHONPATH")}
    return subprocess.run(args, capture_output=True, text=True, env=child_env, timeout=timeout, check=False)


def probe_gallery_dl(
    source: str,
    cookie_name: str,
    url_key: str,
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    cookie_file = resolve_home(env) / ".luna" / "cookies" / cookie_name
    if not cookie_file.is_file():
        return ProbeResult("auth-or-cookie-expired", f"{source} cookie file missing")
    binary = shutil.which("gallery-dl", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "gallery-dl missing")
    url = env.get(url_key, DEFAULT_URLS[source])
    try:
        # HIMMEL-2549 CR round 1 CRITIC-1: gallery-dl needs no .env key at
        # all (the cookie path is a file, not a credential in this dict), so
        # it gets child_env (the pre-merge process env) unchanged — never
        # `env`, which the registry populates with the whole checkout .env.
        completed = command(
            [binary, "--simulate", "--cookies", str(cookie_file), url],
            env=child_env if child_env is not None else env,
            timeout=TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "gallery-dl invocation failed")
    return classify_command(completed.returncode, completed.stderr)


def twitter_cookie_credentials(env: dict[str, str]) -> tuple[str, str]:
    # HIMMEL-2549: TWITTER_AUTH_TOKEN / TWITTER_CT0 ARE the auth_token / ct0
    # cookies in the Netscape file the x-media probe already reads, so read the
    # pair from there rather than making the operator duplicate the secret into
    # .env. Same reader as cookie_header (MozillaCookieJar), which also parses
    # the `#HttpOnly_` line prefix that auth_token is written under.
    cookie_file = resolve_home(env) / ".luna" / "cookies" / "twitter.txt"
    if not cookie_file.is_file():
        return "", ""
    jar = http.cookiejar.MozillaCookieJar(str(cookie_file))
    try:
        # ignore_expires=True is deliberate here and must NOT be "fixed" into
        # expiry filtering (CR round 4 codex-1, declined with reason). This is
        # a HEALTH PROBE: its job is to attempt the call with whatever
        # credentials exist and report what actually happened. An expired
        # auth_token makes the twitter CLI fail auth, which classify_command
        # turns into `auth-or-cookie-expired` — the correct, useful diagnosis.
        # Filtering expired cookies out first would downgrade that to
        # "credentials missing", hiding a real expiry behind a wrong reason.
        # The youtube converter DOES check expiry, because there an expired
        # marker would overwrite a good file; nothing destructive happens here.
        jar.load(ignore_discard=True, ignore_expires=True)
    except (OSError, LoadError):
        return "", ""
    found: dict[str, str] = {}
    for cookie in jar:
        domain = (cookie.domain or "").lstrip(".").lower()
        if domain in TWITTER_COOKIE_DOMAINS and cookie.name in ("auth_token", "ct0"):
            value = (cookie.value or "").strip()
            # CR round 4 codex-1: setdefault alone kept the FIRST match even
            # when its value is empty/stale, so a real credential for the
            # OTHER supported domain (x.com vs twitter.com) later in the same
            # jar was ignored. Skip empty candidates so the first NON-EMPTY
            # match per name wins — still first-wins, not last-wins.
            if value and cookie.name not in found:
                found[cookie.name] = value
    return found.get("auth_token", ""), found.get("ct0", "")


def probe_twitter_cli(
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    token = env.get("TWITTER_AUTH_TOKEN", "").strip()
    ct0 = env.get("TWITTER_CT0", "").strip()
    if not token or not ct0:
        # Per-key fallback: an explicitly provided value still wins for ITS key.
        cookie_token, cookie_ct0 = twitter_cookie_credentials(env)
        token = token or cookie_token
        ct0 = ct0 or cookie_ct0
    if not token or not ct0:
        return ProbeResult(
            "auth-or-cookie-expired",
            "twitter CLI credentials missing (TWITTER_AUTH_TOKEN/TWITTER_CT0, or auth_token/ct0 in ~/.luna/cookies/twitter.txt)",
        )
    binary = shutil.which("twitter", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "twitter CLI missing")
    tweet_id = env.get("FETCH_HEALTH_TWITTER_TWEET_ID", "20")
    # The CLI reads the pair from ITS OWN environment, so the resolved
    # (cookie-sourced or .env-sourced) value has to reach the child — but
    # HIMMEL-2549 CR round 1 CRITIC-1: onto the CHILD env BASE (the pre-merge
    # process env), never onto `env`, which the registry populates with the
    # whole checkout .env (~120 keys, most of them unrelated credentials).
    # This injection is still load-bearing; only its base dict changed.
    # run_command still scrubs PYTHONHOME/PYTHONPATH out of whatever results.
    base = dict(child_env) if child_env is not None else dict(env)
    base["TWITTER_AUTH_TOKEN"] = token
    base["TWITTER_CT0"] = ct0
    try:
        completed = command([binary, "tweet", tweet_id, "--json"], env=base, timeout=TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "twitter CLI invocation failed")
    return classify_command(completed.returncode, completed.stderr)


def probe_youtube(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    state_file = resolve_home(env) / ".luna" / "playwright-state" / "youtube.json"
    if not state_file.is_file():
        return ProbeResult(
            "auth-or-cookie-expired",
            "youtube Playwright storage state missing "
            "(rebuild: yt-dlp --cookies-from-browser 'chrome:<profile>' -> Netscape -> storageState)",
        )
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
        cookies = []
        target_host = "www.youtube.com"
        for item in state.get("cookies", []):
            domain = str(item.get("domain", "")).lstrip(".").lower()
            if target_host == domain or target_host.endswith("." + domain):
                cookies.append(f"{item['name']}={item['value']}")
        if not cookies:
            return ProbeResult("auth-or-cookie-expired", "youtube storage state has no matching cookies")
    except (OSError, ValueError, KeyError, TypeError):
        return ProbeResult(
            "auth-or-cookie-expired",
            "youtube Playwright storage state unreadable "
            "(rebuild: yt-dlp --cookies-from-browser 'chrome:<profile>' -> Netscape -> storageState)",
        )
    url = env.get("FETCH_HEALTH_YOUTUBE_URL", DEFAULT_URLS["youtube-playwright"])
    try:
        result = http(
            url,
            headers={"Accept": "text/html", "Cookie": "; ".join(cookies), "User-Agent": USER_AGENT},
            allowed_auth_hosts={"www.youtube.com", "youtube.com"},
        )
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "youtube request failed")
    # YouTube serves anonymous public HTML (with a <title>) regardless of cookie
    # validity, so <title> alone was a false-green on an expired storage state.
    # The ytcfg block embeds "LOGGED_IN":true only for authenticated sessions
    # ("LOGGED_IN":false for anonymous), so require it — a 2xx without it flows
    # to auth-or-cookie-expired via classify_http, mirroring reddit's login-wall.
    # Keep the consent.youtube.com redirect guard (HIMMEL-1449 r2).
    return classify_http(
        result,
        auth_required=True,
        valid_body=lambda body: b'"LOGGED_IN":true' in body and b"consent.youtube.com" not in body,
    )


def probe_github(
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
    *,
    child_env: dict[str, str] | None = None,
) -> ProbeResult:
    binary = shutil.which("gh", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "gh CLI missing")
    try:
        # HIMMEL-2549 CR round 1 CRITIC-1: gh authenticates from its own
        # config, needing no .env key — child_env (pre-merge process env)
        # unchanged, never `env` (the whole-checkout-.env lookup dict).
        completed = command(
            [binary, "api", "repos/cli/cli", "--jq", ".full_name"],
            env=child_env if child_env is not None else env,
            timeout=TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "gh invocation failed")
    return classify_command(completed.returncode, completed.stderr)


def primary_repo_root() -> Path:
    """Resolve the primary checkout, matching scripts/bitbucket/src/env.ts."""
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
            check=False,
        )
        if completed.returncode == 0 and completed.stdout.strip():
            common = Path(completed.stdout.strip())
            if not common.is_absolute():
                common = (Path.cwd() / common).resolve()
            return common.parent
    except (OSError, subprocess.TimeoutExpired):
        pass
    return Path(__file__).resolve().parents[2]


def _clean_dotenv_value(raw: str) -> str:
    # Normalize a dotenv value (HIMMEL-1468): the prior raw value.strip() left
    # BITBUCKET_API_TOKEN="secret" holding literal quotes, so Basic auth failed
    # on any non-cron path where no shell pre-sources the file, and an inline
    # `# comment` was kept on the value. Strip MATCHED surrounding single or
    # double quotes (an unmatched opening quote is left verbatim — don't guess
    # where it closes), then drop a trailing unquoted inline comment: a `#`
    # preceded by whitespace, mirroring python-dotenv so a bare mid-token `#`
    # (KEY=a#b) is preserved and a quoted value keeps the `#` inside its quotes.
    # HIMMEL-1476: scan for the first UNESCAPED closing quote (prev char not a
    # backslash) so an embedded `\"` no longer counts as the delimiter — the
    # prior value.find(value[0], 1) truncated `"abc\"def"` to `abc\`. A full
    # escape parser is out of scope, so `\\"` (escaped backslash, then the real
    # closing quote) still reads as escaped and over-runs — accepted here.
    value = raw.strip()
    if value and value[0] in ('"', "'"):
        quote = value[0]
        for close in range(1, len(value)):
            if value[close] == quote and value[close - 1] != "\\":
                return value[1:close]
    return re.sub(r"\s+#.*", "", value)


def load_repo_env(env: dict[str, str], repo_root: Path) -> dict[str, str]:
    loaded = dict(env)
    env_file = repo_root / ".env"
    if not env_file.is_file():
        return loaded
    # HIMMEL-2549 duplicate/absent policy, mirroring scripts/lib/load-dotenv.sh
    # so the two loaders cannot disagree about the same file:
    #   * the FIRST occurrence of a key in the file wins (that loader's awk
    #     `key in seen` guard) — including an empty `KEY=` placeholder, which
    #     therefore shadows a value appended lower down, in BOTH loaders;
    #   * an existing value that is set-but-EMPTY counts as ABSENT (its
    #     HIMMEL-1922 rule). The prior setdefault let a bare `KEY=` exported
    #     into the process env win, and every probe then read "missing" while
    #     the .env held the real value.
    # A live NON-empty process value still wins over the file.
    #
    # HIMMEL-2549 CR round 5: "empty" here means ZERO-LENGTH, exactly like
    # bash's `[ -z "${KEY-}" ]` (the documented shell-side policy this
    # mirrors) — NOT `.strip()`-empty. A whitespace-only exported value
    # (`KEY="   "`) makes `[ -z ]` false, so load_dotenv.sh treats it as
    # PRESENT and does not load from the file; a `.strip()` check here would
    # have disagreed and loaded from the file anyway, breaking the parity
    # this function exists to guarantee. Confirmed both ways:
    # `KEY="   "; [ -z "${KEY-}" ]` -> false (present) in bash. The FILE side
    # is unaffected by this distinction: `_clean_dotenv_value` (this file)
    # and `_load_dotenv_trim` (load-dotenv.sh) both strip a file value before
    # it is ever compared, so a whitespace-only line in the .env still reads
    # as the trimmed value on both sides either way.
    seen: set[str] = set()
    try:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            key = key.strip()
            if key in seen or loaded.get(key, ""):
                continue
            seen.add(key)
            loaded[key] = _clean_dotenv_value(value)
    except OSError:
        pass
    return loaded


def probe_bitbucket(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    # HIMMEL-2549: the .env merge moved up to build_probe_registry, so this
    # probe is no longer the only one that can see the checkout's config.
    email = env.get("BITBUCKET_EMAIL", "").rstrip()
    token = env.get("BITBUCKET_API_TOKEN", "").rstrip()
    if not email or not token:
        return ProbeResult("auth-or-cookie-expired", "Bitbucket credentials missing")
    auth = base64.b64encode(f"{email}:{token}".encode()).decode()
    try:
        result = http(
            "https://api.bitbucket.org/2.0/user",
            headers={"Accept": "application/json", "Authorization": f"Basic {auth}", "User-Agent": USER_AGENT},
            allowed_auth_hosts={"api.bitbucket.org"},
        )
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "Bitbucket request failed")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return bool(data.get("uuid") or data.get("account_id"))
        except (ValueError, AttributeError):
            return False

    return classify_http(result, auth_required=True, valid_body=valid)


def probe_firecrawl(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    api_key = env.get("FIRECRAWL_API_KEY", "").strip()
    if not api_key:
        return ProbeResult("auth-or-cookie-expired", "Firecrawl API key missing")
    # Normalize the base (HIMMEL-1468): rstrip("/") alone left a FIRECRAWL_BASE_URL
    # set WITH a /v2 suffix composing /v2/v2/scrape. Drop a trailing /v2 (then any
    # newly-exposed slash) before appending the /v2 path ourselves.
    base_url = re.sub(r"/v2$", "", env.get("FIRECRAWL_BASE_URL", "").strip().rstrip("/")) or "https://api.firecrawl.dev"
    url = env.get("FETCH_HEALTH_FIRECRAWL_URL", DEFAULT_URLS["firecrawl"])
    payload = json.dumps({"url": url, "formats": ["markdown"]}).encode()
    api_host = (urllib.parse.urlparse(base_url).hostname or "").lower()
    try:
        result = http(
            f"{base_url}/v2/scrape",
            method="POST",
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json", "User-Agent": USER_AGENT},
            data=payload,
            allowed_auth_hosts={api_host},
        )
    except (OSError, urllib.error.URLError, TimeoutError):
        return ProbeResult("transport-fail", "Firecrawl request failed")

    def valid(body: bytes) -> bool:
        try:
            data = _json(body)
            return data.get("success") is True and bool((data.get("data") or {}).get("markdown", "").strip())
        except (ValueError, AttributeError):
            return False

    return classify_http(result, auth_required=True, valid_body=valid)


def build_probe_registry(
    env: dict[str, str],
    http: Callable[..., HttpResult],
    command: Callable[..., subprocess.CompletedProcess[str]],
    repo_root: Path,
) -> dict[str, Callable[[], ProbeResult]]:
    # HIMMEL-2549: merge the primary checkout's .env HERE — the one boundary
    # where the process env and the resolved repo root meet — so every probe,
    # the FETCH_HEALTH_* URL overrides and REDDIT_COOKIE_FILE included, sees the
    # same effective config on both the `--probe` and the scheduled path. The
    # cron wrapper sources nothing, so before this only probe_bitbucket (which
    # called load_repo_env itself) could read a key that lives only in .env.
    #
    # CR round 1 CRITIC-1: that merge is for CONFIG LOOKUP only. The checkout's
    # .env carries ~120 keys (router/wifi/sudo passwords, Jira/Confluence/Codex
    # tokens, Grafana/VM credentials, a dozen vendor API keys...) that a
    # third-party child process (gallery-dl, gh) or a CLI reading its own
    # environment (twitter) has no business seeing. `effective` is the merged
    # lookup dict every probe reads config from; `child_env` is the ORIGINAL,
    # pre-merge process env — the only thing a command probe's subprocess is
    # ever handed, plus (for twitter only) the one resolved credential pair it
    # actually needs, injected by probe_twitter_cli itself.
    effective = load_repo_env(env, repo_root)
    child_env = env
    return {
        "reddit": lambda: probe_reddit(effective, http),
        "x-fxtwitter": lambda: probe_fxtwitter(effective, http),
        "instagram-embed": lambda: probe_instagram_embed(effective, http),
        "instagram-media": lambda: probe_gallery_dl("instagram-media", "instagram.txt", "FETCH_HEALTH_INSTAGRAM_MEDIA_URL", effective, command, child_env=child_env),
        "x-media": lambda: probe_gallery_dl("x-media", "twitter.txt", "FETCH_HEALTH_X_MEDIA_URL", effective, command, child_env=child_env),
        "x-twitter-cli": lambda: probe_twitter_cli(effective, command, child_env=child_env),
        "youtube-playwright": lambda: probe_youtube(effective, http),
        "github": lambda: probe_github(effective, command, child_env=child_env),
        "bitbucket": lambda: probe_bitbucket(effective, http),
        "firecrawl": lambda: probe_firecrawl(effective, http),
    }


def run_probes(
    env: dict[str, str],
    *,
    http: Callable[..., HttpResult] = fetch_http,
    command: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    repo_root: Path | None = None,
) -> dict[str, ProbeResult]:
    root = repo_root or primary_repo_root()
    probes = build_probe_registry(env, http, command, root)
    results: dict[str, ProbeResult] = {}
    for source, probe in probes.items():
        try:
            results[source] = probe()
        except Exception:
            results[source] = ProbeResult("transport-fail", "unexpected probe failure")
    return results


def run_single_probe(
    source: str,
    env: dict[str, str],
    *,
    http: Callable[..., HttpResult] = fetch_http,
    command: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    repo_root: Path | None = None,
) -> ProbeResult:
    root = repo_root or primary_repo_root()
    probes = build_probe_registry(env, http, command, root)
    if source not in probes:
        valid = ", ".join(sorted(probes))
        raise ValueError(f"unknown probe source: {source!r} (valid sources: {valid})")
    try:
        return probes[source]()
    except Exception:
        return ProbeResult("transport-fail", "unexpected probe failure")


def read_previous(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(path: Path, results: dict[str, ProbeResult], now: datetime) -> None:
    previous = read_previous(path).get("sources", {})
    checked_at = now.isoformat().replace("+00:00", "Z")
    checked_epoch = int(now.timestamp())
    sources = {}
    for source, result in sorted(results.items()):
        old = previous.get(source, {}) if isinstance(previous, dict) else {}
        if not isinstance(old, dict):
            # A malformed per-source entry (e.g. a corrupt state file with a
            # string value) must not crash write_state — that would wedge every
            # future run on the same bad file (CR r1 codex-1).
            old = {}
        last_success = checked_epoch if result.status == "ok" else old.get("last_success_timestamp")
        row = {"status": result.status, "checked_at": checked_at, "reason": result.reason}
        if isinstance(last_success, int) and last_success >= 0:
            row["last_success_timestamp"] = last_success
        sources[source] = row
    payload = {"version": 1, "checked_at": checked_at, "sources": sources}
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", help="override output state path")
    parser.add_argument("--probe", metavar="SOURCE", help="run a single probe and print its JSON result (skips state writes)")
    args = parser.parse_args(argv)
    env = dict(os.environ)

    if args.probe:
        try:
            result = run_single_probe(args.probe, env)
        except ValueError as error:
            parser.error(str(error))
        print(json.dumps({"status": result.status, "reason": result.reason}))
        return 0 if result.status == "ok" else 1

    path = Path(args.state) if args.state else state_path(env)
    results = run_probes(env)
    write_state(path, results, utc_now())
    for source, result in sorted(results.items()):
        print(f"{source}: {result.status} ({result.reason})")
    return 0 if all(result.status == "ok" for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
