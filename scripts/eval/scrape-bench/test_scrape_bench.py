"""Stubbed unit tests for the scrape bench. No network: urlopen is patched."""
import io
import json
import os
import sys
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import agent_reach_adapter  # noqa: E402
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

    def test_long_challenge_page_is_not_success(self):
        body = "Just a moment...\n\n" + "Checking your browser before accessing the site. " * 80
        self.assertGreaterEqual(len(body), 1500)
        self.assertFalse(score.score(body, "x", "y")["success"])

    def test_long_article_with_late_marker_is_success(self):
        body = GOOD * 6 + "\nA footnote about a 404 not found page.\n"
        self.assertGreaterEqual(len(body), 1500)
        self.assertTrue(score.score(body, "x", "y")["success"])

    def test_long_article_discussing_marker_near_start_is_success(self):
        intro = "Notes on the web. " * 20 + "Why every captcha annoys readers: a short history. "
        body = intro + GOOD * 6
        self.assertGreater(len(body), score.SHORT_BODY)
        self.assertLess(body.lower().find("captcha"), 1500)
        self.assertTrue(score.score(body, "x", "y")["success"])

    def test_short_marker_dominated_challenge_page_is_not_success(self):
        body = "# Just a moment...\n\nEnable JavaScript and cookies to continue.\n" * 6
        self.assertFalse(score.score(body, "x", "y")["success"])

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


    def test_transport_error_is_unknown_credits_not_zero(self):
        p = providers.FirecrawlProvider(5)
        with mock.patch("urllib.request.urlopen", side_effect=OSError("boom")):
            rows, _ = RunTests().run_bench(p)
        self.assertEqual({r["credits_known"] for r in rows}, {False})

    def test_answered_call_and_cap_skip_are_confirmed(self):
        p = providers.FirecrawlProvider(1)
        with mock.patch("urllib.request.urlopen", side_effect=lambda *a, **k: fc_response()):
            rows, _ = RunTests().run_bench(p)
        self.assertEqual([r["credits_known"] for r in rows], [True, True, True])

    def test_ledger_write_failure_warns_with_class_only(self):
        with mock.patch("builtins.open", side_effect=OSError("/secret/nope/ledger.jsonl")):
            with mock.patch("sys.stderr", io.StringIO()) as err:
                providers.ledger_append(1, True)
        self.assertRegex(err.getvalue(), r"^warning: firecrawl ledger write failed \(\w+\)\n$")
        self.assertNotIn("nope", err.getvalue())


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

    def test_command_error_records_err_class(self):
        p = providers.CommandProvider("h", "sh -c 'echo err=Timeout >&2; exit 1'")
        rows, _ = RunTests().run_bench(p)
        self.assertEqual({r["error"] for r in rows}, {"CommandError:Timeout"})

    def test_err_label_is_sanitized(self):
        p = providers.CommandProvider("h", "sh -c 'echo err=bad/path:secret >&2; exit 1'")
        rows, _ = RunTests().run_bench(p)
        self.assertEqual({r["error"] for r in rows}, {"CommandError"})

    def test_adapter_timeout_and_missing_binary_labels(self):
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("x", 1)), \
                mock.patch("sys.stderr", io.StringIO()) as err:
            self.assertEqual(local_adapters.main("lightpanda", "https://x.test/a"), 1)
        self.assertEqual(err.getvalue(), "err=Timeout\n")
        with mock.patch("subprocess.run", side_effect=FileNotFoundError("x")), \
                mock.patch("sys.stderr", io.StringIO()) as err:
            self.assertEqual(local_adapters.main("scrapling-static", "https://x.test/a"), 1)
        self.assertEqual(err.getvalue(), "err=MissingBinary\n")
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("x", 1)), \
                mock.patch("sys.stderr", io.StringIO()) as err:
            self.assertEqual(agent_reach_adapter.main("https://www.youtube.com/watch?v=x"), 1)
        self.assertEqual(err.getvalue(), "err=Timeout\n")

    def test_scrapling_status_takes_last_fetched_line(self):
        log = "INFO: Fetched (301) <GET a>\nINFO: Fetched (404) <GET b>\n"
        self.assertEqual(local_adapters.scrapling_status(log), 404)
        self.assertIsNone(local_adapters.scrapling_status("no status here"))

    def test_lightpanda_result_parses_json(self):
        raw = json.dumps({"url": "u", "http_status": 200, "content": "# Hi", "error": None})
        self.assertEqual(local_adapters.lightpanda_result(raw), ("# Hi", 200, None))


    def test_lightpanda_nonzero_exit_with_content_is_a_failure(self):
        raw = json.dumps({"url": "u", "http_status": 200, "content": "# Hi", "error": None})
        done = mock.Mock(returncode=2, stdout=raw, stderr="")
        with mock.patch("subprocess.run", return_value=done), mock.patch("sys.stderr", io.StringIO()) as err:
            self.assertEqual(local_adapters.lightpanda("https://x.test/a"), 1)
        self.assertEqual(err.getvalue(), "err=LightpandaExit2\n")


class LedgerTests(unittest.TestCase):
    """HIMMEL-4647: each bench.main run appends one valid eval-runs row."""

    def bench(self, d, script_body):
        script = Path(d) / "engine.sh"
        script.write_text("#!/bin/sh\n" + script_body, encoding="utf-8")
        script.chmod(0o755)
        fixture = Path(d) / "urls.json"
        fixture.write_text(json.dumps(FIXTURE), encoding="utf-8")
        ledger = Path(d) / "eval-runs.jsonl"
        with mock.patch.dict(os.environ, {"HIMMEL_EVAL_RUNS_LEDGER": str(ledger)}), \
                mock.patch("sys.stdout", io.StringIO()), mock.patch("sys.stderr", io.StringIO()):
            bench.main(["--provider", "cmd", "--name", "eng", "--cmd", str(script),
                        "--fixture", str(fixture), "--out", str(Path(d) / "o.jsonl"), "--delay", "0"])
        return [json.loads(l) for l in ledger.read_text(encoding="utf-8").splitlines()]

    def test_run_appends_one_valid_row(self):
        import eval_runs
        with tempfile.TemporaryDirectory() as d:
            rows = self.bench(d, "cat <<'EOF'\n%s\nEOF\n" % GOOD)
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual(eval_runs.validate(r), [])
        self.assertEqual((r["eval"], r["n"], r["status"], r["config"]["provider"]), ("scrape-bench", 3, "ok", "eng"))
        self.assertAlmostEqual(r["metrics"]["title_match_rate"], 2 / 3)
        self.assertEqual(sorted(r["cases"]), ["a", "b", "c"])

    def test_ledger_error_only_warns(self):
        import eval_runs
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(eval_runs, "file_sha256", side_effect=OSError("gone")):
            rows = None
            try:
                rows = self.bench(d, "cat <<'EOF'\n%s\nEOF\n" % GOOD)
            except FileNotFoundError:
                rows = []
            except OSError as e:
                self.fail("a ledger error escaped the bench: %s" % e)
        self.assertEqual(rows, [])

    def test_needs_auth_run_is_partial(self):
        with tempfile.TemporaryDirectory() as d:
            rows = self.bench(d, "exit 77\n")
        self.assertEqual((rows[0]["status"], rows[0]["metrics"]["success_rate"]), ("partial", None))


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

    def test_unknown_credits_render_with_marker(self):
        rows = [{"category": "c1", "provider": "p", "status": "error", "credits": 0, "credits_known": False,
                 "success": False, "title_match": False, "phrase_hit": False,
                 "boilerplate_ratio": 1.0, "length": 0, "latency_s": 1.0}]
        self.assertIn("| 0+? |", render.render(rows))


if __name__ == "__main__":
    unittest.main()
