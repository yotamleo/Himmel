#!/usr/bin/env python3
"""Offline tests for fetch-health.py (all network and command probes stubbed)."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("fetch-health.py")
SPEC = importlib.util.spec_from_file_location("fetch_health", MODULE_PATH)
assert SPEC and SPEC.loader
fetch_health = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = fetch_health
SPEC.loader.exec_module(fetch_health)


class FetchHealthTests(unittest.TestCase):
    def test_http_classifier_covers_exact_status_taxonomy(self):
        valid = lambda body: body == b"ok"
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(200, b"ok"), auth_required=True, valid_body=valid).status, "ok")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(401, b""), auth_required=True, valid_body=valid).status, "auth-or-cookie-expired")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(403, b""), auth_required=False, valid_body=valid).status, "blocked-or-rate-limited")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(429, b""), auth_required=True, valid_body=valid).status, "blocked-or-rate-limited")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(503, b""), auth_required=True, valid_body=valid).status, "transport-fail")
        self.assertEqual(fetch_health.classify_http(fetch_health.HttpResult(200, b"login"), auth_required=True, valid_body=valid).status, "auth-or-cookie-expired")

    def test_command_classifier_distinguishes_auth_block_and_transport(self):
        self.assertEqual(fetch_health.classify_command(0, "").status, "ok")
        self.assertEqual(fetch_health.classify_command(1, "login required").status, "auth-or-cookie-expired")
        self.assertEqual(fetch_health.classify_command(1, "HTTP 429 rate limit").status, "blocked-or-rate-limited")
        self.assertEqual(fetch_health.classify_command(1, "connection reset").status, "transport-fail")

    def test_missing_auth_artifacts_are_classified_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": ""}
            forbidden_http = lambda *args, **kwargs: self.fail("network should not run")
            forbidden_command = lambda *args, **kwargs: self.fail("command should not run")
            self.assertEqual(fetch_health.probe_reddit(env, forbidden_http).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_gallery_dl("instagram-media", "instagram.txt", "FETCH_HEALTH_INSTAGRAM_MEDIA_URL", env, forbidden_command).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_gallery_dl("x-media", "twitter.txt", "FETCH_HEALTH_X_MEDIA_URL", env, forbidden_command).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_twitter_cli(env, forbidden_command).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_youtube(env, forbidden_http).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_bitbucket(env, forbidden_http, Path(tmp)).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_firecrawl(env, forbidden_http).status, "auth-or-cookie-expired")

    def test_reddit_uses_netscape_cookie_and_validates_listing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "reddit.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("# Netscape HTTP Cookie File\n.reddit.com\tTRUE\t/\tTRUE\t2147483647\treddit_session\tsecret\n", encoding="utf-8")
            seen = {}

            def http(url, **kwargs):
                seen.update(kwargs)
                body = json.dumps([{"data": {"children": [{"kind": "t3"}]}}, {"data": {"children": []}}]).encode()
                return fetch_health.HttpResult(200, body)

            result = fetch_health.probe_reddit({"HOME": tmp}, http)
            self.assertEqual(result.status, "ok")
            self.assertIn("reddit_session=secret", seen["headers"]["Cookie"])
            self.assertEqual(seen["allowed_auth_hosts"], {"www.reddit.com", "reddit.com", "old.reddit.com"})

    def test_reddit_html_login_wall_classifies_as_expired_cookie(self):
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "reddit.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("# Netscape HTTP Cookie File\n.reddit.com\tTRUE\t/\tTRUE\t2147483647\treddit_session\tsecret\n", encoding="utf-8")
            result = fetch_health.probe_reddit({"HOME": tmp}, lambda *args, **kwargs: fetch_health.HttpResult(200, b"<html>login</html>"))
            self.assertEqual(result.status, "auth-or-cookie-expired")

    def test_reddit_unreadable_cookie_file_classifies_expired_without_raising(self):
        # Regression for HIMMEL-1470: a malformed (non-Netscape) cookie file is
        # the precise case the except clause exists for — MozillaCookieJar.load()
        # raises http.cookiejar.LoadError. The injected `http` callable parameter
        # used to shadow the `http.cookiejar` module, so the handler evaluated
        # `http.cookiejar.LoadError` at raise time, resolved `http` to the
        # callable, and raised AttributeError instead of classifying. Importing
        # LoadError by name removes the `http.` attribute access from the
        # shadowed scope. probe_reddit is called DIRECTLY (not via run_probes)
        # so the pre-fix AttributeError propagates instead of being masked.
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "reddit.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("this is not a netscape cookie file\n", encoding="utf-8")
            forbidden_http = lambda *args, **kwargs: self.fail("network should not run")
            result = fetch_health.probe_reddit({"HOME": tmp}, forbidden_http)
            self.assertEqual(result.status, "auth-or-cookie-expired")
            self.assertEqual(result.reason, "reddit cookie file unreadable")

    def test_auth_free_probes_validate_expected_response_shape(self):
        fxt = fetch_health.probe_fxtwitter({}, lambda *args, **kwargs: fetch_health.HttpResult(200, b'{"code":200,"tweet":{"id":"20"}}'))
        ig = fetch_health.probe_instagram_embed({}, lambda *args, **kwargs: fetch_health.HttpResult(200, b'<div class="Caption">hello</div>'))
        self.assertEqual(fxt.status, "ok")
        self.assertEqual(ig.status, "ok")
        blocked = fetch_health.probe_instagram_embed({}, lambda *args, **kwargs: fetch_health.HttpResult(200, b"login wall"))
        self.assertEqual(blocked.status, "blocked-or-rate-limited")

    def test_gallery_dl_probe_is_simulation_with_real_cookie_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "instagram.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("cookie", encoding="utf-8")
            seen = []

            def command(args, **kwargs):
                seen.extend(args)
                return subprocess.CompletedProcess(args, 0, "", "")

            with patch.object(fetch_health.shutil, "which", return_value="/bin/gallery-dl"):
                result = fetch_health.probe_gallery_dl("instagram-media", "instagram.txt", "FETCH_HEALTH_INSTAGRAM_MEDIA_URL", {"HOME": tmp, "PATH": "/bin"}, command)
            self.assertEqual(result.status, "ok")
            self.assertEqual(seen[:4], ["/bin/gallery-dl", "--simulate", "--cookies", str(cookie)])

    def test_twitter_cli_uses_environment_credentials_without_reading_env_file(self):
        seen = []

        def command(args, **kwargs):
            seen.extend(args)
            return subprocess.CompletedProcess(args, 0, "{}", "")

        env = {"TWITTER_AUTH_TOKEN": "token", "TWITTER_CT0": "ct0", "PATH": "/bin"}
        with patch.object(fetch_health.shutil, "which", return_value="/bin/twitter"):
            result = fetch_health.probe_twitter_cli(env, command)
        self.assertEqual(result.status, "ok")
        self.assertEqual(seen, ["/bin/twitter", "tweet", "20", "--json"])

    def test_youtube_uses_playwright_storage_state_cookies(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / ".luna" / "playwright-state" / "youtube.json"
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({"cookies": [{"domain": ".youtube.com", "name": "SID", "value": "secret"}]}), encoding="utf-8")
            seen = {}

            def http(url, **kwargs):
                seen.update(kwargs)
                # Authenticated YouTube HTML carries the ytcfg LOGGED_IN:true
                # marker; <title> alone is no longer enough (HIMMEL-1449 r2).
                return fetch_health.HttpResult(200, b'<html><title>known video</title><script>ytcfg.set({"LOGGED_IN":true});</script></html>')

            result = fetch_health.probe_youtube({"HOME": tmp}, http)
            self.assertEqual(result.status, "ok")
            self.assertEqual(seen["headers"]["Cookie"], "SID=secret")
            self.assertEqual(seen["allowed_auth_hosts"], {"www.youtube.com", "youtube.com"})

    def test_youtube_anonymous_html_without_auth_marker_classifies_as_expired(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / ".luna" / "playwright-state" / "youtube.json"
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({"cookies": [{"domain": ".youtube.com", "name": "SID", "value": "secret"}]}), encoding="utf-8")

            def http_with(body):
                return lambda *args, **kwargs: fetch_health.HttpResult(200, body)

            # 200 anonymous public HTML: <title> present but no authenticated
            # marker. The old <title>-only check classified this ok (false-green
            # on an expired storage state); the LOGGED_IN:true requirement now
            # routes both the marker-absent and LOGGED_IN:false bodies to
            # auth-or-cookie-expired (HIMMEL-1449 r2).
            no_marker = b"<html><title>known video</title></html>"
            false_marker = b'<html><title>known video</title><script>ytcfg.set({"LOGGED_IN":false});</script></html>'
            self.assertEqual(fetch_health.probe_youtube({"HOME": tmp}, http_with(no_marker)).status, "auth-or-cookie-expired")
            self.assertEqual(fetch_health.probe_youtube({"HOME": tmp}, http_with(false_marker)).status, "auth-or-cookie-expired")

    def test_github_uses_gh_api(self):
        seen = []

        def command(args, **kwargs):
            seen.extend(args)
            return subprocess.CompletedProcess(args, 0, "cli/cli\n", "")

        with patch.object(fetch_health.shutil, "which", return_value="/bin/gh"):
            result = fetch_health.probe_github({"PATH": "/bin"}, command)
        self.assertEqual(result.status, "ok")
        self.assertEqual(seen, ["/bin/gh", "api", "repos/cli/cli", "--jq", ".full_name"])

    def test_primary_repo_root_uses_git_common_dir_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            completed = subprocess.CompletedProcess(
                ["git", "rev-parse", "--git-common-dir"],
                0,
                str(root / ".git") + "\n",
                "",
            )
            with patch.object(fetch_health.subprocess, "run", return_value=completed):
                self.assertEqual(fetch_health.primary_repo_root(), root)

    def test_bitbucket_loads_primary_repo_env_shape_and_sends_basic_auth(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text("BITBUCKET_EMAIL=u@example.com\nBITBUCKET_API_TOKEN=token\n", encoding="utf-8")
            seen = {}

            def http(url, **kwargs):
                seen.update(kwargs)
                return fetch_health.HttpResult(200, b'{"uuid":"{abc}"}')

            result = fetch_health.probe_bitbucket({}, http, root)
            self.assertEqual(result.status, "ok")
            self.assertTrue(seen["headers"]["Authorization"].startswith("Basic "))
            self.assertNotIn("token", seen["headers"]["Authorization"])

    def test_load_repo_env_strips_quotes_and_inline_comments(self):
        # HIMMEL-1468: a raw value.strip() left a quoted dotenv value holding
        # its literal quotes (Basic auth then fails on non-cron paths) and kept
        # an inline `# comment` on the value. Covered: double + single quoted
        # values, a quoted value with a trailing comment, an inline comment, a
        # bare mid-token `#` (kept), and an unmatched opening quote (verbatim).
        clean = fetch_health._clean_dotenv_value
        self.assertEqual(clean('"secret"'), "secret")
        self.assertEqual(clean("'secret'"), "secret")
        self.assertEqual(clean('"value" # trailing comment'), "value")
        self.assertEqual(clean("tok_abc # scoped to fetch-health"), "tok_abc")
        self.assertEqual(clean("a#b"), "a#b")  # no whitespace before # → kept
        self.assertEqual(clean('"unmatched'), '"unmatched')  # leave unmatched alone
        # End-to-end via load_repo_env: a quoted token + inline comment parse
        # to the bare secret, and a leading export stays part of an unquoted value.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                'BITBUCKET_API_TOKEN="quoted-secret"  # operator-injected\n'
                "BITBUCKET_EMAIL=ops@example.com # noqa\n",
                encoding="utf-8",
            )
            loaded = fetch_health.load_repo_env({}, root)
            self.assertEqual(loaded["BITBUCKET_API_TOKEN"], "quoted-secret")
            self.assertEqual(loaded["BITBUCKET_EMAIL"], "ops@example.com")

    def test_firecrawl_uses_v2_scrape_and_validates_markdown(self):
        seen = {}

        def http(url, **kwargs):
            seen["url"] = url
            seen.update(kwargs)
            return fetch_health.HttpResult(200, b'{"success":true,"data":{"markdown":"Example Domain"}}')

        result = fetch_health.probe_firecrawl({"FIRECRAWL_API_KEY": "secret"}, http)
        self.assertEqual(result.status, "ok")
        self.assertEqual(seen["url"], "https://api.firecrawl.dev/v2/scrape")
        self.assertEqual(json.loads(seen["data"]), {"url": "https://example.com/", "formats": ["markdown"]})

    def test_firecrawl_normalizes_base_url_with_v2_suffix(self):
        # HIMMEL-1468: a FIRECRAWL_BASE_URL set WITH a /v2 suffix (or a trailing
        # slash) used to compose /v2/v2/scrape. Each variant must collapse to the
        # single canonical /v2 path.
        for base_url in (
            "https://api.firecrawl.dev/v2",
            "https://api.firecrawl.dev/v2/",
            "https://api.firecrawl.dev/",
        ):
            seen = {}
            http = lambda url, **kwargs: seen.update(url=url) or fetch_health.HttpResult(
                200, b'{"success":true,"data":{"markdown":"x"}}'
            )
            result = fetch_health.probe_firecrawl({"FIRECRAWL_API_KEY": "secret", "FIRECRAWL_BASE_URL": base_url}, http)
            self.assertEqual(result.status, "ok", base_url)
            self.assertEqual(seen["url"], "https://api.firecrawl.dev/v2/scrape", base_url)

    def test_redirect_handler_strips_auth_off_scope(self):
        handler = fetch_health.AuthScopedRedirectHandler({"www.reddit.com"})
        request = urllib.request.Request("https://www.reddit.com/a", headers={"Cookie": "secret", "Authorization": "Bearer secret"})
        redirected = handler.redirect_request(request, None, 302, "Found", {}, "https://evil.example/landing")
        self.assertIsNotNone(redirected)
        self.assertIsNone(redirected.get_header("Cookie"))
        self.assertIsNone(redirected.get_header("Authorization"))

    def test_state_preserves_last_success_across_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fetch-health.json"
            first = datetime(2026, 8, 1, 1, 0, tzinfo=timezone.utc)
            second = datetime(2026, 8, 2, 1, 0, tzinfo=timezone.utc)
            fetch_health.write_state(path, {"reddit": fetch_health.ProbeResult("ok", "good")}, first)
            fetch_health.write_state(path, {"reddit": fetch_health.ProbeResult("transport-fail", "down")}, second)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(data["sources"]["reddit"]["status"], "transport-fail")
            self.assertEqual(data["sources"]["reddit"]["last_success_timestamp"], int(first.timestamp()))

    def test_state_recovers_from_malformed_source_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fetch-health.json"
            path.write_text('{"version":1,"sources":{"reddit":"corrupt"}}', encoding="utf-8")
            now = datetime(2026, 8, 2, 1, 0, tzinfo=timezone.utc)
            fetch_health.write_state(path, {"reddit": fetch_health.ProbeResult("transport-fail", "down")}, now)
            data = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(data["sources"]["reddit"]["status"], "transport-fail")
            self.assertNotIn("last_success_timestamp", data["sources"]["reddit"])

    def test_run_probes_converts_unexpected_adapter_error_to_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": ""}

            def broken_http(*args, **kwargs):
                raise RuntimeError("stub failure")

            results = fetch_health.run_probes(env, http=broken_http, command=lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError("stub failure")), repo_root=Path(tmp))
            self.assertEqual(set(results), {"reddit", "x-fxtwitter", "instagram-embed", "instagram-media", "x-media", "x-twitter-cli", "youtube-playwright", "github", "bitbucket", "firecrawl"})
            self.assertTrue(all(result.status in fetch_health.STATUSES for result in results.values()))


if __name__ == "__main__":
    unittest.main()
