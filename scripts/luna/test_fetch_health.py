#!/usr/bin/env python3
"""Offline tests for fetch-health.py (all network and command probes stubbed)."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("fetch-health.py")
SPEC = importlib.util.spec_from_file_location("fetch_health", MODULE_PATH)
assert SPEC and SPEC.loader
fetch_health = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = fetch_health
SPEC.loader.exec_module(fetch_health)


class _StubResponse:
    """Minimal urlopen-style response for the main()-level probe tests."""

    def __init__(self, status: int, body: bytes):
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class _StubOpener:
    def __init__(self, body: bytes, status: int = 200):
        self._body = body
        self._status = status

    def open(self, request, timeout=None):  # noqa: ANN001 - urllib opener shape
        return _StubResponse(self._status, self._body)


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
            self.assertEqual(fetch_health.probe_bitbucket(env, forbidden_http).status, "auth-or-cookie-expired")
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

    def test_run_command_scrubs_pythonhome_and_pythonpath_from_child_env(self):
        # HIMMEL-2149: a uv python stub injects its own PYTHONHOME into
        # os.environ. Foreign CLIs (gallery-dl, twitter) embed a DIFFERENT
        # Python runtime, so inheriting it crashes them (SRE module mismatch).
        # run_command is the single chokepoint all command probes route
        # through — assert the env handed to subprocess.run lacks both keys.
        seen_env = {}

        def fake_run(args, *, capture_output, text, env, timeout, check):
            seen_env.update(env)
            return subprocess.CompletedProcess(args, 0, "", "")

        outer_env = {"PATH": "/bin", "PYTHONHOME": "/uv/cpython", "PYTHONPATH": "/uv/lib", "TWITTER_AUTH_TOKEN": "tok"}
        with patch.object(fetch_health.subprocess, "run", fake_run):
            fetch_health.run_command(["some-cli"], env=outer_env)
        self.assertNotIn("PYTHONHOME", seen_env)
        self.assertNotIn("PYTHONPATH", seen_env)
        self.assertEqual(seen_env["PATH"], "/bin")
        self.assertEqual(seen_env["TWITTER_AUTH_TOKEN"], "tok")
        # The caller's own env dict (used for config lookups) is untouched.
        self.assertEqual(outer_env["PYTHONHOME"], "/uv/cpython")
        self.assertEqual(outer_env["PYTHONPATH"], "/uv/lib")

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

            # HIMMEL-2549: the merge is the registry's job now, so the probe
            # is handed the effective dict the registry would build.
            result = fetch_health.probe_bitbucket(fetch_health.load_repo_env({}, root), http)
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
        self.assertEqual(clean(r'"abc\"def"'), r'abc\"def')  # HIMMEL-1476: escaped quote is not the delimiter
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

            def http(url, **kwargs):
                seen.update(url=url)
                return fetch_health.HttpResult(200, b'{"success":true,"data":{"markdown":"x"}}')
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

    def test_probe_mode_matches_full_run_for_every_source(self):
        # spec V2 "probe parity": --probe must return the same verdict as the
        # full scheduled run for every source, driven off the registry itself
        # so a newly added source cannot silently escape the assertion.
        with tempfile.TemporaryDirectory() as tmp:
            env = {"HOME": tmp, "PATH": ""}

            def http(url, **kwargs):
                return fetch_health.HttpResult(200, b"")

            def command(args, **kwargs):
                return subprocess.CompletedProcess(args, 1, "", "unauthorized")

            root = Path(tmp)
            full = fetch_health.run_probes(env, http=http, command=command, repo_root=root)
            registry = fetch_health.build_probe_registry(env, http, command, root)
            self.assertEqual(set(registry), set(full))
            for source in registry:
                single = fetch_health.run_single_probe(source, env, http=http, command=command, repo_root=root)
                self.assertEqual(single, full[source], source)

    def test_probe_unknown_source_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                fetch_health.run_single_probe("nonexistent", {"HOME": tmp, "PATH": ""}, repo_root=root)

            stderr = io.StringIO()
            with patch.object(fetch_health, "primary_repo_root", return_value=root):
                with patch.dict(os.environ, {"HOME": tmp, "PATH": ""}, clear=True):
                    with redirect_stderr(stderr):
                        with self.assertRaises(SystemExit) as cm:
                            fetch_health.main(["--probe", "nonexistent"])
            self.assertNotEqual(cm.exception.code, 0)
            self.assertIn("nonexistent", stderr.getvalue())

    def test_probe_mode_skips_state_file_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_file = root / "fetch-health.json"
            env = {"HOME": tmp, "PATH": "", "HIMMEL_FETCH_HEALTH_STATE": str(state_file)}
            with patch.object(fetch_health, "primary_repo_root", return_value=root):
                with patch.dict(os.environ, env, clear=True):
                    stdout = io.StringIO()
                    with redirect_stdout(stdout):
                        exit_code = fetch_health.main(["--probe", "reddit"])
            self.assertEqual(exit_code, 1)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload, {"status": "auth-or-cookie-expired", "reason": "reddit cookie file missing"})
            self.assertFalse(state_file.exists())

    def test_probe_mode_exit_code_zero_when_status_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = {"HOME": tmp, "PATH": "/bin", "TWITTER_AUTH_TOKEN": "token", "TWITTER_CT0": "ct0"}
            completed = subprocess.CompletedProcess(["twitter"], 0, "{}", "")
            with patch.object(fetch_health, "primary_repo_root", return_value=root):
                with patch.object(fetch_health.shutil, "which", return_value="/bin/twitter"):
                    with patch.object(fetch_health.subprocess, "run", return_value=completed):
                        with patch.dict(os.environ, env, clear=True):
                            stdout = io.StringIO()
                            with redirect_stdout(stdout):
                                exit_code = fetch_health.main(["--probe", "x-twitter-cli"])
            self.assertEqual(exit_code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload, {"status": "ok", "reason": "command probe succeeded"})

    def test_main_probe_reads_keys_that_live_only_in_the_repo_dotenv(self):
        # HIMMEL-2549: load_repo_env used to be called from probe_bitbucket
        # ALONE, so every other probe saw the raw process env. The cron wrapper
        # sources nothing, so a key that lives only in the checkout's .env — the
        # documented place — read as "missing" on every scheduled and manual
        # run. Drive this through main() so the fix has to sit at the loader
        # boundary, not in one more probe.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "FIRECRAWL_API_KEY=fc-secret\n"
                "TWITTER_AUTH_TOKEN=tok\n"
                "TWITTER_CT0=ct0\n",
                encoding="utf-8",
            )
            firecrawl_body = b'{"success":true,"data":{"markdown":"Example Domain"}}'

            def run_probe(source):
                completed = subprocess.CompletedProcess(["twitter"], 0, "{}", "")
                # main() reaches fetch_http through a DEFAULT ARGUMENT bound at
                # def time, so patching the module attribute would not take and
                # the probe would hit the real network. Stub the opener that
                # fetch_http builds instead — that is the actual socket seam.
                with patch.object(fetch_health, "primary_repo_root", return_value=root):
                    with patch.object(fetch_health.urllib.request, "build_opener", lambda *a, **k: _StubOpener(firecrawl_body)):
                        with patch.object(fetch_health.shutil, "which", return_value="/bin/twitter"):
                            with patch.object(fetch_health.subprocess, "run", return_value=completed):
                                with patch.dict(os.environ, {"HOME": tmp, "PATH": "/bin"}, clear=True):
                                    stdout = io.StringIO()
                                    with redirect_stdout(stdout):
                                        code = fetch_health.main(["--probe", source])
                return code, json.loads(stdout.getvalue())

            for source in ("firecrawl", "x-twitter-cli"):
                code, payload = run_probe(source)
                self.assertNotIn("missing", payload["reason"], source)
                self.assertEqual(payload["status"], "ok", source)
                self.assertEqual(code, 0, source)

            # Control: with the .env gone the same two probes must still report
            # the credential as missing — the fix must read the FILE, not
            # invent a default.
            (root / ".env").unlink()
            for source, expected in (("firecrawl", "Firecrawl API key missing"), ("x-twitter-cli", "twitter CLI credentials missing")):
                code, payload = run_probe(source)
                self.assertEqual(payload["status"], "auth-or-cookie-expired", source)
                self.assertIn(expected, payload["reason"], source)

    def test_load_repo_env_keeps_first_occurrence_and_treats_empty_as_absent(self):
        # HIMMEL-2549 duplicate-key policy: FIRST occurrence in the file wins,
        # matching the awk `key in seen` guard in scripts/lib/load-dotenv.sh.
        # A set-but-EMPTY process value counts as ABSENT (also matching that
        # loader, HIMMEL-1922) — an exported `KEY=` placeholder used to shadow
        # the real .env value and every probe then reported "missing".
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "FIRECRAWL_API_KEY=first\nFIRECRAWL_API_KEY=second\nTWITTER_CT0=from-file\n",
                encoding="utf-8",
            )
            loaded = fetch_health.load_repo_env({"TWITTER_CT0": "", "TWITTER_AUTH_TOKEN": "live"}, root)
            self.assertEqual(loaded["FIRECRAWL_API_KEY"], "first")
            self.assertEqual(loaded["TWITTER_CT0"], "from-file")
            # A live NON-empty process value still wins over the file.
            self.assertEqual(loaded["TWITTER_AUTH_TOKEN"], "live")

    def test_load_repo_env_treats_a_whitespace_only_process_value_as_present(self):
        # HIMMEL-2549 CR round 5 codex-1: "empty" means ZERO-LENGTH, exactly
        # like bash's `[ -z "${KEY-}" ]` (the documented shell-side policy
        # this mirrors) — confirmed live: `KEY="   "; [ -z "${KEY-}" ]` is
        # FALSE, i.e. present, so load_dotenv.sh does NOT load from the file.
        # A prior `.strip()` check here disagreed (treated it as absent and
        # loaded from the file), breaking the parity this function exists to
        # guarantee. The zero-length ("") case is the DIFFERENT, correct
        # behaviour — see the test above, which must stay green.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text("FIRECRAWL_API_KEY=from-file\n", encoding="utf-8")
            loaded = fetch_health.load_repo_env({"FIRECRAWL_API_KEY": "   "}, root)
            self.assertEqual(loaded["FIRECRAWL_API_KEY"], "   ")

    def test_twitter_cli_falls_back_to_the_luna_cookie_file(self):
        # HIMMEL-2549: TWITTER_AUTH_TOKEN/TWITTER_CT0 ARE the auth_token/ct0
        # cookies in ~/.luna/cookies/twitter.txt, the file the x-media probe
        # already reads. Fall back to it rather than duplicating the secret.
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text(
                "# Netscape HTTP Cookie File\n"
                "#HttpOnly_.x.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\tcookie-token\n"
                ".x.com\tTRUE\t/\tTRUE\t2147483647\tct0\tcookie-ct0\n",
                encoding="utf-8",
            )
            seen = {}

            def command(args, **kwargs):
                seen["args"] = list(args)
                seen["env"] = dict(kwargs["env"])
                return subprocess.CompletedProcess(args, 0, "{}", "")

            # env (lookup) vs. child_env (subprocess base) are now DISTINCT
            # dicts (HIMMEL-2549 CR round 1 CRITIC-1) — child_env deliberately
            # carries no HOME, so its absence in seen["env"] below proves the
            # child got child_env, not the lookup dict.
            env = {"HOME": tmp, "PATH": "/bin"}
            child_env = {"PATH": "/bin"}
            with patch.object(fetch_health.shutil, "which", return_value="/bin/twitter"):
                result = fetch_health.probe_twitter_cli(env, command, child_env=child_env)
            self.assertEqual(result.status, "ok")
            self.assertEqual(seen["args"], ["/bin/twitter", "tweet", "20", "--json"])
            # The CLI itself reads the pair from ITS environment, so the
            # cookie-sourced values have to reach the child.
            self.assertEqual(seen["env"]["TWITTER_AUTH_TOKEN"], "cookie-token")
            self.assertEqual(seen["env"]["TWITTER_CT0"], "cookie-ct0")
            self.assertNotIn("HOME", seen["env"])

    def test_twitter_cli_env_pair_wins_over_the_cookie_file_per_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text(
                "# Netscape HTTP Cookie File\n"
                "#HttpOnly_.x.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\tcookie-token\n"
                ".x.com\tTRUE\t/\tTRUE\t2147483647\tct0\tcookie-ct0\n",
                encoding="utf-8",
            )
            seen = {}

            def command(args, **kwargs):
                seen["env"] = dict(kwargs["env"])
                return subprocess.CompletedProcess(args, 0, "{}", "")

            env = {"HOME": tmp, "PATH": "/bin", "TWITTER_AUTH_TOKEN": "env-token"}
            child_env = {"PATH": "/bin"}
            with patch.object(fetch_health.shutil, "which", return_value="/bin/twitter"):
                result = fetch_health.probe_twitter_cli(env, command, child_env=child_env)
            self.assertEqual(result.status, "ok")
            self.assertEqual(seen["env"]["TWITTER_AUTH_TOKEN"], "env-token")
            self.assertEqual(seen["env"]["TWITTER_CT0"], "cookie-ct0")
            # The resolved TOKEN VALUE still comes from `env` (the lookup
            # dict); the base it lands on is `child_env`, proven by HOME's
            # absence — env and child_env are no longer the same dict.
            self.assertNotIn("HOME", seen["env"])

    def test_twitter_cli_missing_message_names_both_credential_sources(self):
        # Control for the fallback: with NEITHER source present the probe must
        # still classify, and the reason has to name the cookie file too or the
        # operator only ever learns about half the fix.
        with tempfile.TemporaryDirectory() as tmp:
            forbidden_command = lambda *args, **kwargs: self.fail("command should not run")
            result = fetch_health.probe_twitter_cli({"HOME": tmp, "PATH": ""}, forbidden_command)
            self.assertEqual(result.status, "auth-or-cookie-expired")
            self.assertIn("TWITTER_AUTH_TOKEN", result.reason)
            self.assertIn("twitter.txt", result.reason)

    def test_twitter_cli_ignores_a_cookie_file_missing_one_of_the_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text(
                "# Netscape HTTP Cookie File\n"
                "#HttpOnly_.x.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\tcookie-token\n",
                encoding="utf-8",
            )
            forbidden_command = lambda *args, **kwargs: self.fail("command should not run")
            result = fetch_health.probe_twitter_cli({"HOME": tmp, "PATH": ""}, forbidden_command)
            self.assertEqual(result.status, "auth-or-cookie-expired")

    def test_child_process_probes_never_see_the_merged_dotenv_secrets(self):
        # CR round 1 CRITIC-1: build_probe_registry's merged .env dict
        # (`effective`) is for CONFIG LOOKUP only. A probe that shells out to
        # a third-party binary (gallery-dl, gh) or a CLI reading its own
        # environment (twitter) must receive the PRE-MERGE process env as its
        # child environment, never `effective` — the checkout's real .env
        # carries ~120 keys (ROUTER_PASS, WIFI_5_PASS, JIRA_API_TOKEN,
        # CODEX_GITHUB_PERSONAL_ACCESS_TOKEN, several VM passwords...) that
        # none of those children have any business seeing. ROUTER_PASS here
        # stands in for that whole class of unrelated repo secret.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env").write_text(
                "TWITTER_AUTH_TOKEN=tok-from-env\nTWITTER_CT0=ct0-from-env\nROUTER_PASS=should-not-leak\n",
                encoding="utf-8",
            )
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("placeholder", encoding="utf-8")

            seen_envs: dict[str, dict[str, str]] = {}

            def command(args, **kwargs):
                seen_envs[args[0]] = dict(kwargs["env"])
                return subprocess.CompletedProcess(args, 0, "{}", "")

            def which_stub(binary, path=None):
                return f"/bin/{binary}"

            base_env = {"HOME": tmp, "PATH": "/bin"}
            with patch.object(fetch_health.shutil, "which", which_stub):
                registry = fetch_health.build_probe_registry(
                    base_env, lambda *a, **k: fetch_health.HttpResult(200, b""), command, root
                )
                self.assertEqual(registry["x-media"]().status, "ok")
                self.assertEqual(registry["github"]().status, "ok")
                self.assertEqual(registry["x-twitter-cli"]().status, "ok")

            self.assertNotIn("ROUTER_PASS", seen_envs["/bin/gallery-dl"])
            self.assertNotIn("ROUTER_PASS", seen_envs["/bin/gh"])
            self.assertNotIn("ROUTER_PASS", seen_envs["/bin/twitter"])
            # The twitter child still gets the resolved credential pair —
            # that injection is load-bearing, only its base dict changed.
            self.assertEqual(seen_envs["/bin/twitter"]["TWITTER_AUTH_TOKEN"], "tok-from-env")
            self.assertEqual(seen_envs["/bin/twitter"]["TWITTER_CT0"], "ct0-from-env")

    def test_twitter_cookie_credentials_survive_an_unreadable_cookie_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text("this is not a netscape cookie file\n", encoding="utf-8")
            self.assertEqual(fetch_health.twitter_cookie_credentials({"HOME": tmp}), ("", ""))

    def test_twitter_cookie_credentials_skips_an_empty_value_for_a_real_one_on_the_other_domain(self):
        # CR round 4 codex-1: setdefault() kept the FIRST auth_token match
        # even when its value was empty/stale, so a real credential for the
        # OTHER supported domain (x.com vs twitter.com) later in the same jar
        # was ignored — the probe reported "missing" with a usable pair
        # sitting right there. First NON-EMPTY match per name must win.
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text(
                "# Netscape HTTP Cookie File\n"
                "#HttpOnly_.twitter.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\t\n"
                ".x.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\treal-token\n"
                ".x.com\tTRUE\t/\tTRUE\t2147483647\tct0\treal-ct0\n",
                encoding="utf-8",
            )
            self.assertEqual(fetch_health.twitter_cookie_credentials({"HOME": tmp}), ("real-token", "real-ct0"))

    def test_twitter_cli_resolves_the_real_pair_when_the_first_domain_is_empty(self):
        # End-to-end: the probe actually runs with the real pair rather than
        # reporting credentials missing.
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text(
                "# Netscape HTTP Cookie File\n"
                "#HttpOnly_.twitter.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\t\n"
                ".x.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\treal-token\n"
                ".x.com\tTRUE\t/\tTRUE\t2147483647\tct0\treal-ct0\n",
                encoding="utf-8",
            )
            seen = {}

            def command(args, **kwargs):
                seen["env"] = dict(kwargs["env"])
                return subprocess.CompletedProcess(args, 0, "{}", "")

            with patch.object(fetch_health.shutil, "which", return_value="/bin/twitter"):
                result = fetch_health.probe_twitter_cli({"HOME": tmp, "PATH": "/bin"}, command)
            self.assertEqual(result.status, "ok")
            self.assertEqual(seen["env"]["TWITTER_AUTH_TOKEN"], "real-token")
            self.assertEqual(seen["env"]["TWITTER_CT0"], "real-ct0")

    def test_twitter_cookie_credentials_reports_missing_when_the_only_auth_token_is_empty(self):
        # Negative control for the above: if the ONLY auth_token in the jar
        # is empty, that must still resolve to missing — the fix is "skip
        # empty candidates", not "invent a value from nowhere".
        with tempfile.TemporaryDirectory() as tmp:
            cookie = Path(tmp) / ".luna" / "cookies" / "twitter.txt"
            cookie.parent.mkdir(parents=True)
            cookie.write_text(
                "# Netscape HTTP Cookie File\n"
                "#HttpOnly_.twitter.com\tTRUE\t/\tTRUE\t2147483647\tauth_token\t\n"
                ".twitter.com\tTRUE\t/\tTRUE\t2147483647\tct0\treal-ct0\n",
                encoding="utf-8",
            )
            self.assertEqual(fetch_health.twitter_cookie_credentials({"HOME": tmp}), ("", "real-ct0"))
            forbidden_command = lambda *args, **kwargs: self.fail("command should not run")
            result = fetch_health.probe_twitter_cli({"HOME": tmp, "PATH": ""}, forbidden_command)
            self.assertEqual(result.status, "auth-or-cookie-expired")
            self.assertIn("TWITTER_AUTH_TOKEN", result.reason)


if __name__ == "__main__":
    unittest.main()
