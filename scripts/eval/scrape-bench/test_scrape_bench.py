"""Stubbed unit tests for the scrape bench. No network: urlopen is patched."""
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench  # noqa: E402
import local_adapters  # noqa: E402
import providers  # noqa: E402
import render  # noqa: E402
import score  # noqa: E402

GOOD = ("# Hello World\n\n" + "This is a real paragraph with the magic phrase inside it. " * 8)
FIXTURE = [
    {"id": "a", "category": "c1", "url": "https://x.test/a", "title": "Hello World", "phrase": "magic phrase"},
    {"id": "b", "category": "c1", "url": "https://x.test/b", "title": "Nope", "phrase": "absent"},
    {"id": "c", "category": "c2", "url": "https://x.test/c", "title": "Hello World", "phrase": "magic phrase"},
]


class Stub(providers.Provider):
    name = "stub"

    def __init__(self, behaviour):
        super().__init__()
        self.behaviour = behaviour

    def scrape(self, url):
        self.calls += 1
        return self.behaviour(url)


class FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fc_response(markdown="x " * 200, credits=1, success=True):
    body = {"success": success, "data": {"markdown": markdown, "metadata": {"creditsUsed": credits}}}
    return FakeResp(json.dumps(body).encode("utf-8"))


class ScoreTests(unittest.TestCase):
    def test_good_page(self):
        s = score.score(GOOD, "Hello World", "magic phrase")
        self.assertTrue(s["success"] and s["title_match"] and s["phrase_hit"])

    def test_short_error_page_is_not_success(self):
        self.assertFalse(score.score("Access Denied " * 30, "x", "y")["success"])

    def test_empty_is_not_success(self):
        self.assertFalse(score.score("", "x", "y")["success"])

    def test_boilerplate_ratio(self):
        md = "[Home](/)\n[About](/a)\nA full sentence of real content here today.\n"
        self.assertAlmostEqual(score.boilerplate_ratio(md), 0.667, places=2)


class RunTests(unittest.TestCase):
    def run_bench(self, provider, **kw):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "o.jsonl"
            rows = bench.run(provider, FIXTURE, out, **kw)
            return rows, [json.loads(ln) for ln in out.read_text().splitlines()]

    def test_rows_and_no_bodies(self):
        rows, on_disk = self.run_bench(Stub(lambda u: GOOD))
        self.assertEqual(len(on_disk), 3)
        self.assertTrue(rows[0]["success"] and rows[0]["phrase_hit"])
        self.assertFalse(rows[1]["title_match"])
        self.assertNotIn("magic phrase inside", json.dumps(on_disk))

    def test_error_records_class_only(self):
        def boom(u):
            raise ValueError("secret-token https://leak.test")
        rows, on_disk = self.run_bench(Stub(boom))
        self.assertEqual(rows[0]["status"], "error")
        self.assertEqual(rows[0]["error"], "ValueError")
        self.assertNotIn("secret-token", json.dumps(on_disk))

    def test_http_status_code_is_recorded(self):
        def limited(u):
            raise urllib.error.HTTPError(u, 429, "Too Many secret", {}, None)
        rows, _ = self.run_bench(Stub(limited))
        self.assertEqual(rows[0]["error"], "HTTPError:429")

    def test_needs_auth(self):
        def auth(u):
            raise providers.NeedsAuth()
        rows, _ = self.run_bench(Stub(auth))
        self.assertEqual({r["status"] for r in rows}, {"needs-auth"})

    def test_category_filter(self):
        rows, _ = self.run_bench(Stub(lambda u: GOOD), categories=["c2"])
        self.assertEqual([r["id"] for r in rows], ["c"])


class IdFilterTests(unittest.TestCase):
    def test_id_filter(self):
        with tempfile.TemporaryDirectory() as d:
            rows = bench.run(Stub(lambda u: GOOD), FIXTURE, Path(d) / "o.jsonl", ids=["b", "c"])
        self.assertEqual([r["id"] for r in rows], ["b", "c"])


class FirecrawlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Path(self.tmp.name) / "ledger.jsonl"
        self.env = mock.patch.dict(os.environ, {"FIRECRAWL_API_KEY": "fc-test-key",
                                                "HIMMEL_FIRECRAWL_LEDGER": str(self.ledger)})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_unset_key_refuses(self):
        with mock.patch.dict(os.environ, {"FIRECRAWL_API_KEY": "  "}):
            with self.assertRaises(SystemExit):
                providers.FirecrawlProvider(5)

    def test_cap_stops_calls_and_ledger_has_no_key_or_url(self):
        p = providers.FirecrawlProvider(2)
        with mock.patch("urllib.request.urlopen", side_effect=lambda *a, **k: fc_response()) as uo:
            rows, _ = RunTests().run_bench(p)
        self.assertEqual(uo.call_count, 2)
        self.assertEqual([r["status"] for r in rows], ["ok", "ok", "skipped-cap"])
        self.assertEqual([r["credits"] for r in rows], [1, 1, 0])
        text = self.ledger.read_text()
        self.assertEqual(len(text.splitlines()), 2)
        self.assertNotIn("fc-test-key", text)
        self.assertNotIn("x.test", text)

    def test_http_failure_counts_a_call_and_logs_zero_credits(self):
        p = providers.FirecrawlProvider(5)
        with mock.patch("urllib.request.urlopen", side_effect=OSError("boom")):
            rows, _ = RunTests().run_bench(p)
        self.assertEqual(p.calls, 3)
        self.assertEqual({r["error"] for r in rows}, {"OSError"})
        self.assertEqual(sum(r["credits"] for r in rows), 0)


class CommandProviderTests(unittest.TestCase):
    def test_stdout_is_markdown(self):
        p = providers.CommandProvider("echoer", "echo {url}")
        self.assertEqual(p.scrape("https://x.test/a"), "https://x.test/a")

    def test_cookie_warning_on_success_is_not_needs_auth(self):
        p = providers.CommandProvider("warn", "sh -c 'echo cookie banner >&2; echo page body'")
        self.assertEqual(p.scrape("https://x.test/a"), "page body")

    def test_cookie_error_on_failure_is_needs_auth(self):
        p = providers.CommandProvider("auth", "sh -c 'echo login required >&2; exit 1'")
        with self.assertRaises(providers.NeedsAuth):
            p.scrape("https://x.test/a")

    def test_exit_77_is_needs_auth(self):
        p = providers.CommandProvider("auth", "sh -c 'exit 77'")
        with self.assertRaises(providers.NeedsAuth):
            p.scrape("https://x.test/a")


class LocalAdapterTests(unittest.TestCase):
    def test_command_error_carries_http_code(self):
        p = providers.CommandProvider("h", "sh -c 'echo http=403 >&2; exit 1'")
        rows, _ = RunTests().run_bench(p)
        self.assertEqual({r["error"] for r in rows}, {"CommandError:403"})

    def test_command_error_without_code_is_class_only(self):
        p = providers.CommandProvider("h", "sh -c 'echo boom >&2; exit 1'")
        rows, _ = RunTests().run_bench(p)
        self.assertEqual({r["error"] for r in rows}, {"CommandError"})

    def test_scrapling_status_takes_last_fetched_line(self):
        log = "INFO: Fetched (301) <GET a>\nINFO: Fetched (404) <GET b>\n"
        self.assertEqual(local_adapters.scrapling_status(log), 404)
        self.assertIsNone(local_adapters.scrapling_status("no status here"))

    def test_lightpanda_result_parses_json(self):
        raw = json.dumps({"url": "u", "http_status": 200, "content": "# Hi", "error": None})
        self.assertEqual(local_adapters.lightpanda_result(raw), ("# Hi", 200, None))


class RenderTests(unittest.TestCase):
    def test_table_per_category_and_provider(self):
        rows = [
            {"category": "c1", "provider": "p", "status": "ok", "success": True, "title_match": True,
             "phrase_hit": False, "boilerplate_ratio": 0.2, "length": 1000, "latency_s": 1.0, "credits": 1},
            {"category": "c1", "provider": "p", "status": "ok", "success": False, "title_match": False,
             "phrase_hit": False, "boilerplate_ratio": 0.4, "length": 0, "latency_s": 3.0, "credits": 1},
            {"category": "c1", "provider": "p", "status": "needs-auth", "credits": 0},
        ]
        out = render.render(rows)
        self.assertIn("| c1 | p | 2 | 50% | 50% | 0% | 0.3 | 500.0 | 2.0 | 2 | 1 needs-auth |", out)


if __name__ == "__main__":
    unittest.main()
