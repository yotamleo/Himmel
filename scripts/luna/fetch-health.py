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
    return subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout, check=False)


def probe_gallery_dl(
    source: str,
    cookie_name: str,
    url_key: str,
    env: dict[str, str],
    command: Callable[..., subprocess.CompletedProcess[str]],
) -> ProbeResult:
    cookie_file = resolve_home(env) / ".luna" / "cookies" / cookie_name
    if not cookie_file.is_file():
        return ProbeResult("auth-or-cookie-expired", f"{source} cookie file missing")
    binary = shutil.which("gallery-dl", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "gallery-dl missing")
    url = env.get(url_key, DEFAULT_URLS[source])
    try:
        completed = command([binary, "--simulate", "--cookies", str(cookie_file), url], env=env, timeout=TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "gallery-dl invocation failed")
    return classify_command(completed.returncode, completed.stderr)


def probe_twitter_cli(env: dict[str, str], command: Callable[..., subprocess.CompletedProcess[str]]) -> ProbeResult:
    if not env.get("TWITTER_AUTH_TOKEN", "").strip() or not env.get("TWITTER_CT0", "").strip():
        return ProbeResult("auth-or-cookie-expired", "twitter CLI credentials missing")
    binary = shutil.which("twitter", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "twitter CLI missing")
    tweet_id = env.get("FETCH_HEALTH_TWITTER_TWEET_ID", "20")
    try:
        completed = command([binary, "tweet", tweet_id, "--json"], env=env, timeout=TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return ProbeResult("transport-fail", "twitter CLI invocation failed")
    return classify_command(completed.returncode, completed.stderr)


def probe_youtube(env: dict[str, str], http: Callable[..., HttpResult]) -> ProbeResult:
    state_file = resolve_home(env) / ".luna" / "playwright-state" / "youtube.json"
    if not state_file.is_file():
        return ProbeResult("auth-or-cookie-expired", "youtube Playwright storage state missing")
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
        return ProbeResult("auth-or-cookie-expired", "youtube Playwright storage state unreadable")
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


def probe_github(env: dict[str, str], command: Callable[..., subprocess.CompletedProcess[str]]) -> ProbeResult:
    binary = shutil.which("gh", path=env.get("PATH"))
    if not binary:
        return ProbeResult("transport-fail", "gh CLI missing")
    try:
        completed = command([binary, "api", "repos/cli/cli", "--jq", ".full_name"], env=env, timeout=TIMEOUT_SECONDS)
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


def load_repo_env(env: dict[str, str], repo_root: Path) -> dict[str, str]:
    loaded = dict(env)
    env_file = repo_root / ".env"
    if not env_file.is_file():
        return loaded
    try:
        for line in env_file.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            loaded.setdefault(key.strip(), value.strip())
    except OSError:
        pass
    return loaded


def probe_bitbucket(env: dict[str, str], http: Callable[..., HttpResult], repo_root: Path) -> ProbeResult:
    effective = load_repo_env(env, repo_root)
    email = effective.get("BITBUCKET_EMAIL", "").rstrip()
    token = effective.get("BITBUCKET_API_TOKEN", "").rstrip()
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
    base_url = env.get("FIRECRAWL_BASE_URL", "").strip().rstrip("/") or "https://api.firecrawl.dev"
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


def run_probes(
    env: dict[str, str],
    *,
    http: Callable[..., HttpResult] = fetch_http,
    command: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    repo_root: Path | None = None,
) -> dict[str, ProbeResult]:
    root = repo_root or primary_repo_root()
    probes = {
        "reddit": lambda: probe_reddit(env, http),
        "x-fxtwitter": lambda: probe_fxtwitter(env, http),
        "instagram-embed": lambda: probe_instagram_embed(env, http),
        "instagram-media": lambda: probe_gallery_dl("instagram-media", "instagram.txt", "FETCH_HEALTH_INSTAGRAM_MEDIA_URL", env, command),
        "x-media": lambda: probe_gallery_dl("x-media", "twitter.txt", "FETCH_HEALTH_X_MEDIA_URL", env, command),
        "x-twitter-cli": lambda: probe_twitter_cli(env, command),
        "youtube-playwright": lambda: probe_youtube(env, http),
        "github": lambda: probe_github(env, command),
        "bitbucket": lambda: probe_bitbucket(env, http, root),
        "firecrawl": lambda: probe_firecrawl(env, http),
    }
    results: dict[str, ProbeResult] = {}
    for source, probe in probes.items():
        try:
            results[source] = probe()
        except Exception:
            results[source] = ProbeResult("transport-fail", "unexpected probe failure")
    return results


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
    args = parser.parse_args(argv)
    env = dict(os.environ)
    path = Path(args.state) if args.state else state_path(env)
    results = run_probes(env)
    write_state(path, results, utc_now())
    for source, result in sorted(results.items()):
        print(f"{source}: {result.status} ({result.reason})")
    return 0 if all(result.status == "ok" for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
