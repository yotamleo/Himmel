#!/usr/bin/env python3
"""Hermetic tests for enrich-chat-notes (stdlib unittest).

Run: python scripts/luna/test-enrich-chat-notes.py
"""
import contextlib
import datetime as _dt
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.error
from pathlib import Path

_MOD_PATH = Path(__file__).resolve().parent / "enrich-chat-notes.py"
_SPEC = importlib.util.spec_from_file_location("enrich_chat_notes", _MOD_PATH)
mod = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(mod)


class _FakeDateTime:
    """Stand-in for the datetime class: now(...) always returns `fixed`.

    Used to pin the UTC instant the script reads (enriched_at date + the
    off-peak hour) without depending on wall-clock time."""
    def __init__(self, fixed):
        self._fixed = fixed

    def now(self, tz=None):
        return self._fixed


def note(enriched="false", tags="[chat-import, gpt]", title="Test chat",
         body_extra=""):
    return (
        "---\n"
        "type: chat-import\n"
        "source: chatgpt\n"
        "conversation_id: conv-1\n"
        "created: 2025-08-21\n"
        "messages: 2\n"
        f"tags: {tags}\n"
        f"enriched: {enriched}\n"
        "---\n"
        "\n"
        f"# {title}\n"
        "\n"
        "## 🧑 User\n"
        "\n"
        "hello\n"
        "\n"
        "## 🤖 Assistant\n"
        "\n"
        "world\n" + body_extra
    )


class TestFrontmatter(unittest.TestCase):
    def test_roundtrip_fields(self):
        fm, body = mod.split_frontmatter(note())
        self.assertEqual(mod.fm_value(fm, "enriched"), "false")
        self.assertEqual(mod.fm_value(fm, "tags"), "[chat-import, gpt]")
        self.assertIn("# Test chat", body)

    def test_no_frontmatter_returns_none(self):
        self.assertIsNone(mod.split_frontmatter("# Just a heading\n"))

    def test_unclosed_frontmatter_returns_none(self):
        self.assertIsNone(mod.split_frontmatter("---\ntags: [a]\nno closer\n"))

    def test_flow_tags(self):
        self.assertEqual(mod.parse_flow_tags("[a, b]"), ["a", "b"])
        self.assertEqual(mod.parse_flow_tags("[]"), [])
        self.assertEqual(mod.parse_flow_tags('["x", \'y\']'), ["x", "y"])
        self.assertIsNone(mod.parse_flow_tags("block"))  # block style


class TestScan(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.vault = Path(self.td.name)
        self.gpt = self.vault / "chats" / "gpt" / "2025-08"
        self.gpt.mkdir(parents=True)

    def tearDown(self):
        self.td.cleanup()

    def test_picks_only_enriched_false(self):
        (self.gpt / "a.md").write_text(note("false"), encoding="utf-8")
        (self.gpt / "b.md").write_text(note("true"), encoding="utf-8")
        (self.gpt.parent / "_index.md").write_text("# Index\n", encoding="utf-8")
        assets = self.gpt.parent / "_assets"
        assets.mkdir()
        (assets / "x.md").write_text(note("false"), encoding="utf-8")
        got = mod.scan_candidates(self.vault, None)
        self.assertEqual([p.name for p in got], ["a.md"])

    def test_limit_and_order(self):
        for name in ("c.md", "a.md", "b.md"):
            (self.gpt / name).write_text(note("false"), encoding="utf-8")
        got = mod.scan_candidates(self.vault, 2)
        self.assertEqual([p.name for p in got], ["a.md", "b.md"])

    def test_scan_skips_non_utf8(self):
        # a binary / locked / non-UTF-8 .md under chats/ must not crash the scan
        (self.gpt / "bad.md").write_bytes(b"\xff\xfe\x00bad bytes")
        (self.gpt / "good.md").write_text(note("false"), encoding="utf-8")
        got = mod.scan_candidates(self.vault, None)
        self.assertEqual([p.name for p in got], ["good.md"])


class TestPayload(unittest.TestCase):
    def test_strips_frontmatter_and_pointers(self):
        text = note(body_extra="\n![[assets/img.png]]\n[image: f1 — not in export archive]\n[audio: not in export archive]\n")
        payload = mod.build_payload(text)
        self.assertNotIn("conversation_id", payload)
        self.assertNotIn("![[", payload)
        self.assertNotIn("[image:", payload)
        self.assertNotIn("[audio:", payload)
        self.assertIn("hello", payload)

    def test_long_body_passes_through_untruncated(self):
        text = note(body_extra="x" * 20000)
        payload = mod.build_payload(text)
        self.assertNotIn("[truncated]", payload)
        self.assertEqual(payload.count("x"), 20000)  # full body preserved
        self.assertGreater(len(payload), 10000)

    def test_title_extraction(self):
        self.assertEqual(mod.note_title(note(title="שיחה בעברית"), "fb"), "שיחה בעברית")
        self.assertEqual(mod.note_title("no heading here", "fb"), "fb")


class TestIndexAndRelated(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.vault = Path(self.td.name)
        (self.vault / "chats" / "gpt").mkdir(parents=True)
        (self.vault / "notes").mkdir()
        (self.vault / ".obsidian").mkdir()
        (self.vault / "notes" / "jira-guide.md").write_text(
            "---\ntags: [jira, workflow, agile]\n---\n# Jira guide\n", encoding="utf-8")
        (self.vault / "notes" / "poems.md").write_text(
            "---\ntags: [poetry, writing]\n---\n# Poems\n", encoding="utf-8")
        (self.vault / ".obsidian" / "cfg.md").write_text(
            "---\ntags: [hidden]\n---\n", encoding="utf-8")
        self.chat = self.vault / "chats" / "gpt" / "2025-08-21-Poem-about-Jira.md"
        self.chat.write_text(note(), encoding="utf-8")

    def tearDown(self):
        self.td.cleanup()

    def test_vocab_and_index(self):
        vocab, index = mod.scan_vault_index(self.vault)
        self.assertIn("jira", vocab)
        self.assertNotIn("hidden", vocab)  # .obsidian skipped
        self.assertIn(self.vault / "notes" / "jira-guide.md", index)

    def test_generic_tags(self):
        self.assertEqual(mod.generic_tags(self.vault), {"chat-import", "gpt"})

    def test_related_scoring(self):
        _, index = mod.scan_vault_index(self.vault)
        generic = mod.generic_tags(self.vault)
        got = mod.related_notes(self.chat, ["jira", "workflow", "chat-import", "gpt"],
                                index, generic)
        self.assertEqual(got, ["jira-guide"])  # 2 shared; poems has 0

    def test_related_self_excluded_and_threshold(self):
        _, index = mod.scan_vault_index(self.vault)
        generic = mod.generic_tags(self.vault)
        got = mod.related_notes(self.chat, ["chat-import", "gpt", "poetry"],
                                index, generic)
        self.assertEqual(got, [])  # generic ignored; 1 shared < 2

    def test_related_cap_and_tiebreak(self):
        for i in range(7):
            (self.vault / "notes" / f"n{i}.md").write_text(
                "---\ntags: [jira, workflow]\n---\n", encoding="utf-8")
        _, index = mod.scan_vault_index(self.vault)
        got = mod.related_notes(self.chat, ["jira", "workflow"], index,
                                mod.generic_tags(self.vault))
        self.assertEqual(len(got), mod.RELATED_MAX)
        self.assertEqual(got, sorted(got))  # path tie-break = sorted stems here


class TestKeyAndRoot(unittest.TestCase):
    def test_env_key_wins(self):
        os.environ["DEEPSEEK_API_KEY"] = "sk-env"
        try:
            self.assertEqual(mod.resolve_api_key(Path(".")), "sk-env")
        finally:
            del os.environ["DEEPSEEK_API_KEY"]

    def test_dotenv_fallback_from_primary_root(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / ".env").write_text(
                "OTHER=1\nDEEPSEEK_API_KEY=sk-dotenv\n", encoding="utf-8")
            os.environ.pop("DEEPSEEK_API_KEY", None)
            orig = mod.primary_root
            mod.primary_root = lambda d: root
            try:
                self.assertEqual(mod.resolve_api_key(Path(".")), "sk-dotenv")
            finally:
                mod.primary_root = orig

    def test_missing_key_returns_none(self):
        with tempfile.TemporaryDirectory() as td:
            os.environ.pop("DEEPSEEK_API_KEY", None)
            orig = mod.primary_root
            mod.primary_root = lambda d: Path(td)
            try:
                self.assertIsNone(mod.resolve_api_key(Path(".")))
            finally:
                mod.primary_root = orig


class TestGateAndLedger(unittest.TestCase):
    def test_gate_parses_verdict_line(self):
        orig = mod._run_gate_eval
        mod._run_gate_eval = lambda root: (0, "allow+log\toperator override\n", "")
        try:
            self.assertEqual(mod.egress_gate(Path(".")),
                             ("allow+log", "operator override"))
        finally:
            mod._run_gate_eval = orig

    def test_gate_nonzero_exit_is_error(self):
        orig = mod._run_gate_eval
        mod._run_gate_eval = lambda root: (2, "", "boom")
        try:
            self.assertEqual(mod.egress_gate(Path("."))[0], "error")
        finally:
            mod._run_gate_eval = orig

    def test_ledger_shape(self):
        with tempfile.TemporaryDirectory() as td:
            ledger = Path(td) / "led.jsonl"
            os.environ["GRAPHIFY_LEDGER"] = str(ledger)
            try:
                ok = mod.ledger_append(Path("/v/chats"), 7, 200)
            finally:
                del os.environ["GRAPHIFY_LEDGER"]
            self.assertTrue(ok)
            rec = json.loads(ledger.read_text(encoding="utf-8").strip())
            self.assertEqual(rec["purpose"], "enrichment")
            self.assertEqual(rec["tool"], "enrich-chat-notes")
            self.assertEqual(rec["corpus"], "luna-personal")
            self.assertEqual(rec["provider"], "deepseek")
            self.assertEqual(rec["verdict"], "allow+log")
            self.assertEqual(rec["notes"], 7)
            self.assertEqual(rec["vocab_tags"], 200)
            for k in ("ts", "path"):
                self.assertIn(k, rec)

    def test_ledger_failure_returns_false(self):
        os.environ["GRAPHIFY_LEDGER"] = os.devnull + "/nope/led.jsonl"
        try:
            self.assertFalse(mod.ledger_append(Path("/v/chats"), 1, 200))
        finally:
            del os.environ["GRAPHIFY_LEDGER"]

    def test_ledger_failure_prints_reason(self):
        os.environ["GRAPHIFY_LEDGER"] = os.devnull + "/nope/led.jsonl"
        buf = io.StringIO()
        try:
            with contextlib.redirect_stderr(buf):
                ok = mod.ledger_append(Path("/v/chats"), 1, 200)
        finally:
            del os.environ["GRAPHIFY_LEDGER"]
        self.assertFalse(ok)
        self.assertIn("ledger append error", buf.getvalue())


class TestRealMatrixWrapper(unittest.TestCase):
    """REAL eval + REAL matrix (not stubbed): pins the governance premise.
    The wrapper collapses pending-operator -> deny on stdout, so the
    accepted set here survives the operator's ratification flip."""
    def test_enrichment_triple_verdict(self):
        repo = Path(__file__).resolve().parents[2]
        helper = repo / "scripts" / "guardrails" / "egress-matrix-eval.mjs"
        try:
            out = subprocess.run(
                ["node", str(helper), "luna-personal", "deepseek", "enrichment"],
                capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            self.skipTest("node not available")
        self.assertEqual(out.returncode, 0, out.stderr)
        verdict = out.stdout.split("\t", 1)[0].strip()
        self.assertIn(verdict, ("deny", "allow+log"))


class TestDeepseekClient(unittest.TestCase):
    def test_call_builds_request_and_parses(self):
        seen = {}
        def fake_post(key, body):
            seen["key"], seen["body"] = key, body
            return {"choices": [{"message": {"content":
                json.dumps({"summary": "s.", "tags": ["jira"]})}}]}
        got = mod.call_deepseek("sk-x", "T", "hello", ["jira", "poetry"],
                                post=fake_post)
        self.assertEqual(got, {"summary": "s.", "tags": ["jira"]})
        self.assertEqual(seen["key"], "sk-x")
        self.assertEqual(seen["body"]["model"], mod.MODEL)
        self.assertEqual(seen["body"]["response_format"], {"type": "json_object"})
        user = seen["body"]["messages"][1]["content"]
        self.assertIn("jira, poetry", user)
        self.assertIn("Title: T", user)

    def test_retry_then_success(self):
        calls = {"n": 0}
        def flaky(key, body):
            calls["n"] += 1
            if calls["n"] < 3:
                raise urllib.error.URLError("down")
            return {"choices": [{"message": {"content": "{}"}}]}
        orig = mod.time.sleep
        mod.time.sleep = lambda s: None
        try:
            got = mod.call_deepseek("k", "t", "p", [], post=flaky)
        finally:
            mod.time.sleep = orig
        self.assertEqual(got, {})
        self.assertEqual(calls["n"], 3)

    def test_exhausted_retries_raise(self):
        def dead(key, body):
            raise urllib.error.URLError("down")
        orig = mod.time.sleep
        mod.time.sleep = lambda s: None
        try:
            with self.assertRaises(urllib.error.URLError):
                mod.call_deepseek("k", "t", "p", [], post=dead)
        finally:
            mod.time.sleep = orig

    def test_validate_filters_tags(self):
        got = mod.validate_result(
            {"summary": "  a\nb  ", "tags": ["JIRA", "nope", "jira", 7]},
            ["jira", "poetry"])
        self.assertEqual(got, {"summary": "a b", "tags": ["jira"]})

    def test_validate_rejects_bad_shapes(self):
        self.assertIsNone(mod.validate_result("not a dict", []))
        self.assertIsNone(mod.validate_result({"summary": "", "tags": []}, []))
        self.assertIsNone(mod.validate_result({"summary": "s", "tags": "x"}, []))


class TestWriteBack(unittest.TestCase):
    def test_full_enrichment_rewrite(self):
        got, _ = mod.enrich_note_text(
            note(), 'He said: "shalom" \\o/', ["jira", "poetry"],
            ["jira-guide"], "2026-07-10")
        fm, body = mod.split_frontmatter(got)
        self.assertEqual(mod.fm_value(fm, "enriched"), "true")
        self.assertEqual(mod.fm_value(fm, "tags"),
                         "[chat-import, gpt, jira, poetry]")
        self.assertEqual(mod.fm_value(fm, "enriched_at"), "2026-07-10")
        self.assertEqual(mod.fm_value(fm, "enriched_model"), mod.MODEL)
        self.assertEqual(mod.fm_value(fm, "summary"),
                         '"He said: \\"shalom\\" \\\\o/"')
        self.assertIn("## Related Notes", body)
        self.assertIn("- [[jira-guide]]", body)
        self.assertIn("# Test chat", body)  # body preserved

    def test_no_related_no_section(self):
        got, _ = mod.enrich_note_text(note(), "s.", [], [], "2026-07-10")
        self.assertNotIn("## Related Notes", got)

    def test_existing_section_not_duplicated(self):
        text = note(body_extra="\n## Related Notes\n\n- [[old]]\n")
        got, _ = mod.enrich_note_text(text, "s.", [], ["new"], "2026-07-10")
        self.assertEqual(got.count("## Related Notes"), 1)
        self.assertNotIn("[[new]]", got)

    def test_block_style_tags_out_of_contract(self):
        text = note().replace("tags: [chat-import, gpt]", "tags:\n  - a")
        self.assertEqual(mod.enrich_note_text(text, "s.", [], [], "2026-07-10"),
                         (None, "block-style-tags"))

    def test_no_frontmatter_out_of_contract(self):
        self.assertEqual(mod.enrich_note_text("# x\n", "s.", [], [], "2026-07-10"),
                         (None, "unclosed-frontmatter"))

    def test_no_enriched_key_out_of_contract(self):
        text = ("---\ntype: chat-import\ntags: [chat-import]\n---\n"
                "# No enriched key\n")
        self.assertEqual(mod.enrich_note_text(text, "s.", [], [], "2026-07-10"),
                         (None, "no-enriched-key"))

    def test_no_tags_key_out_of_contract(self):
        # frontmatter with NO tags: line is out of contract (fold always emits
        # one) -> inferred tags must not be silently dropped; skip the note.
        text = ("---\ntype: chat-import\nenriched: false\n---\n# No tags key\n")
        self.assertEqual(mod.enrich_note_text(text, "s.", ["jira"], [], "2026-07-10"),
                         (None, "no-tags-key"))

    def test_tag_merge_dedups_case_insensitive(self):
        got, _ = mod.enrich_note_text(note(), "s.", ["GPT", "jira"], [], "2026-07-10")
        fm, _ = mod.split_frontmatter(got)
        self.assertEqual(mod.fm_value(fm, "tags"), "[chat-import, gpt, jira]")

    def test_write_atomic_replaces(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "n.md"
            p.write_text("old", encoding="utf-8")
            mod.write_atomic(p, "new")
            self.assertEqual(p.read_text(encoding="utf-8"), "new")
            self.assertEqual([f.name for f in Path(td).iterdir()], ["n.md"])


def _mk_vault(td):
    vault = Path(td)
    gpt = vault / "chats" / "gpt" / "2025-08"
    gpt.mkdir(parents=True)
    (gpt / "a.md").write_text(note("false"), encoding="utf-8")
    (gpt / "b.md").write_text(note("true"), encoding="utf-8")
    (vault / "notes").mkdir()
    (vault / "notes" / "jira-guide.md").write_text(
        "---\ntags: [jira, workflow]\n---\n# Jira guide\n", encoding="utf-8")
    return vault


class TestOffpeak(unittest.TestCase):
    def _warn_at(self, hour):
        orig = mod.datetime
        mod.datetime = _FakeDateTime(
            _dt.datetime(2026, 7, 10, hour, 0, tzinfo=_dt.timezone.utc))
        buf = io.StringIO()
        try:
            with contextlib.redirect_stderr(buf):
                mod.offpeak_warn()
        finally:
            mod.datetime = orig
        return buf.getvalue()

    def test_next_window_at_hour_2_is_04(self):
        self.assertIn("resumes 04:00 UTC", self._warn_at(2))

    def test_next_window_at_hour_9_is_10(self):
        self.assertIn("resumes 10:00 UTC", self._warn_at(9))

    def test_no_warn_outside_peak(self):
        self.assertEqual(self._warn_at(0), "")


class TestVaultClassification(unittest.TestCase):
    """Allow-list classification of --vault (mirrors graphify-fence
    classify() precedence). Hermetic: pops LUNA_VAULT/LUNA_VAULT_PATH/
    CLAUDE_GLM_CONFIG_DIR and points CLAUDE_GLM_CONFIG_DIR at a temp dir
    so the operator's real config is never read."""
    def setUp(self):
        self._env = {k: os.environ.pop(k, None)
                     for k in ("DEEPSEEK_API_KEY", "GRAPHIFY_LEDGER",
                               "LUNA_VAULT", "LUNA_VAULT_PATH",
                               "CLAUDE_GLM_CONFIG_DIR")}
        self._cfg_td = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_GLM_CONFIG_DIR"] = self._cfg_td.name
        self._orig = (mod.egress_gate, mod.resolve_api_key,
                      mod.call_deepseek, mod.ledger_append)

    def tearDown(self):
        (mod.egress_gate, mod.resolve_api_key,
         mod.call_deepseek, mod.ledger_append) = self._orig
        self._cfg_td.cleanup()
        for k, v in self._env.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)

    def _stub_throw(self):
        def _boom(*a, **k):
            raise AssertionError("must not be called on a refused vault")
        mod.egress_gate = _boom
        mod.ledger_append = _boom
        mod.call_deepseek = _boom

    def _cfg(self, name):
        return Path(self._cfg_td.name) / name

    def test_salus_at_root_refuses_before_any_call(self):
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td)
            (vault / "chats").mkdir()
            (vault / ".salus").write_text("", encoding="utf-8")
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_salus_in_parent_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            parent = Path(td)
            (parent / ".salus").write_text("", encoding="utf-8")
            vault = parent / "vault"
            (vault / "chats").mkdir(parents=True)
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_vault_in_phi_roots_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td)
            (vault / "chats").mkdir()
            os.environ["LUNA_VAULT_PATH"] = str(vault)  # would pass otherwise
            self._cfg("phi-roots").write_text(str(vault) + "\n", encoding="utf-8")
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_vault_in_egress_denylist_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td)
            (vault / "chats").mkdir()
            os.environ["LUNA_VAULT_PATH"] = str(vault)
            self._cfg("egress-denylist").write_text(str(vault) + "\n", encoding="utf-8")
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_phi_roots_as_directory_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td)
            (vault / "chats").mkdir()
            os.environ["LUNA_VAULT_PATH"] = str(vault)
            self._cfg("phi-roots").mkdir()  # not a readable file -> fail closed
            self._stub_throw()
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = mod.main(["--vault", str(vault)])
            self.assertEqual(rc, 2)
            self.assertIn("fail closed", buf.getvalue())

    def test_no_luna_root_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td)
            (vault / "chats").mkdir()
            # LUNA_VAULT / LUNA_VAULT_PATH both unset (popped in setUp)
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_vault_not_under_luna_root_refuses(self):
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as sib:
            vault = Path(td)
            (vault / "chats").mkdir()
            os.environ["LUNA_VAULT_PATH"] = sib  # a different root
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_luna_clippings_is_not_luna_personal(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            os.environ["LUNA_VAULT_PATH"] = str(root)
            vault = root / "Clippings"
            (vault / "chats").mkdir(parents=True)
            self._stub_throw()
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_dry_run_refuses_non_allowed_vault(self):
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as sib:
            vault = Path(td)
            gpt = vault / "chats" / "gpt"
            gpt.mkdir(parents=True)
            (gpt / "a.md").write_text(note("false"), encoding="utf-8")
            os.environ["LUNA_VAULT_PATH"] = sib  # vault not allowed
            self._stub_throw()
            before = (gpt / "a.md").read_text(encoding="utf-8")
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = mod.main(["--vault", str(vault), "--dry-run"])
            self.assertEqual(rc, 2)
            self.assertNotIn("DRY RUN", buf.getvalue())  # no payload printing
            self.assertEqual((gpt / "a.md").read_text(encoding="utf-8"), before)

    def test_happy_path_allowed_vault_enriches(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            os.environ["LUNA_VAULT_PATH"] = str(vault)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: "sk"
            mod.ledger_append = lambda root, n, v: True
            mod.call_deepseek = lambda *a, **k: {"summary": "s.",
                                                 "tags": ["jira", "workflow"]}
            rc = mod.main(["--vault", str(vault)])
            self.assertEqual(rc, 0)
            text = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
            fm, _ = mod.split_frontmatter(text)
            self.assertEqual(mod.fm_value(fm, "enriched"), "true")

    def test_gate_corpus_is_pinned_luna_personal(self):
        seen = {}
        fake_proc = types.SimpleNamespace(
            returncode=0, stdout="allow+log\tok", stderr="")

        def fake_run(argv, **kw):
            seen["argv"] = list(argv)
            return fake_proc
        orig = mod.subprocess.run
        mod.subprocess.run = fake_run
        try:
            rc, _out, _err = mod._run_gate_eval(Path("/repo"))
        finally:
            mod.subprocess.run = orig
        self.assertEqual(rc, 0)
        self.assertIn("luna-personal", seen["argv"])
        self.assertIn("enrichment", seen["argv"])


class TestMain(unittest.TestCase):
    def setUp(self):
        self._env = {k: os.environ.pop(k, None)
                     for k in ("DEEPSEEK_API_KEY", "GRAPHIFY_LEDGER",
                               "LUNA_VAULT", "LUNA_VAULT_PATH",
                               "CLAUDE_GLM_CONFIG_DIR")}
        self._cfg_td = tempfile.TemporaryDirectory()
        os.environ["CLAUDE_GLM_CONFIG_DIR"] = self._cfg_td.name
        self._orig = (mod.egress_gate, mod.resolve_api_key,
                      mod.call_deepseek, mod.ledger_append, mod.classify_vault)
        # These tests cover the post-classification flow (gate/ledger/key/api),
        # not classification itself — short-circuit it so the operator's real
        # env/config is never consulted. TestVaultClassification owns classify.
        mod.classify_vault = lambda v: ("luna-personal", "")

    def tearDown(self):
        (mod.egress_gate, mod.resolve_api_key,
         mod.call_deepseek, mod.ledger_append, mod.classify_vault) = self._orig
        self._cfg_td.cleanup()
        for k, v in self._env.items():
            if v is not None:
                os.environ[k] = v
            else:
                os.environ.pop(k, None)

    def test_dry_run_writes_nothing_and_calls_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: (_ for _ in ()).throw(AssertionError("gate called"))
            mod.call_deepseek = lambda *a, **k: (_ for _ in ()).throw(AssertionError("api called"))
            before = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
            rc = mod.main(["--vault", str(vault), "--dry-run"])
            self.assertEqual(rc, 0)
            self.assertEqual((vault / "chats" / "gpt" / "2025-08" / "a.md")
                             .read_text(encoding="utf-8"), before)

    def test_gate_deny_refuses_before_any_call(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("deny", "pending")
            mod.call_deepseek = lambda *a, **k: (_ for _ in ()).throw(AssertionError("api called"))
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_plain_allow_also_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow", "misconfigured")
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_ledger_failure_refuses_before_any_call(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: "sk"
            mod.ledger_append = lambda root, n, v: False
            mod.call_deepseek = lambda *a, **k: (_ for _ in ()).throw(AssertionError("api called"))
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_missing_key_refuses(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: None
            self.assertEqual(mod.main(["--vault", str(vault)]), 2)

    def test_happy_path_enriches_and_flips(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: "sk"
            mod.ledger_append = lambda root, n, v: True
            mod.call_deepseek = lambda *a, **k: {"summary": "s.",
                                                 "tags": ["jira", "workflow"]}
            rc = mod.main(["--vault", str(vault)])
            self.assertEqual(rc, 0)
            text = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
            fm, body = mod.split_frontmatter(text)
            self.assertEqual(mod.fm_value(fm, "enriched"), "true")
            self.assertIn("- [[jira-guide]]", body)
            # rerun: idempotent, nothing left to do
            self.assertEqual(mod.main(["--vault", str(vault)]), 0)

    def test_api_failure_skips_note_and_returns_1(self):
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: "sk"
            mod.ledger_append = lambda root, n, v: True
            def boom(*a, **k):
                raise urllib.error.URLError("down")
            mod.call_deepseek = boom
            rc = mod.main(["--vault", str(vault)])
            self.assertEqual(rc, 1)  # candidates present, zero progress
            text = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
            self.assertIn("enriched: false", text)

    def test_no_chats_dir_is_config_error(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(mod.main(["--vault", td]), 2)

    def test_shape_exception_skips_with_diagnostic(self):
        # a malformed 200 (e.g. empty choices) raises IndexError inside
        # call_deepseek; it must be caught, the note skipped with a diagnostic,
        # and the run continue (rc=1: candidate present, zero progress).
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: "sk"
            mod.ledger_append = lambda root, n, v: True

            def boom(*a, **k):
                raise IndexError("choices empty")
            mod.call_deepseek = boom
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = mod.main(["--vault", str(vault)])
            self.assertEqual(rc, 1)
            self.assertIn("IndexError", buf.getvalue())
            self.assertIn("choices empty", buf.getvalue())
            text = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
            self.assertIn("enriched: false", text)

    def test_empty_surviving_tags_skips(self):
        # every model tag fails the vocab filter -> validate_result returns
        # None -> note stays enriched: false, rc=1 (candidate, zero progress).
        with tempfile.TemporaryDirectory() as td:
            vault = _mk_vault(td)
            mod.egress_gate = lambda root: ("allow+log", "ok")
            mod.resolve_api_key = lambda d: "sk"
            mod.ledger_append = lambda root, n, v: True
            mod.call_deepseek = lambda *a, **k: {"summary": "s.",
                                                 "tags": ["not-in-vocab"]}
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = mod.main(["--vault", str(vault)])
            self.assertEqual(rc, 1)
            self.assertIn("invalid response shape", buf.getvalue())
            text = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
            self.assertIn("enriched: false", text)

    def test_enriched_at_uses_utc_date(self):
        fixed = _dt.datetime(2026, 7, 10, 23, 59, tzinfo=_dt.timezone.utc)
        orig = mod.datetime
        mod.datetime = _FakeDateTime(fixed)
        try:
            with tempfile.TemporaryDirectory() as td:
                vault = _mk_vault(td)
                mod.egress_gate = lambda root: ("allow+log", "ok")
                mod.resolve_api_key = lambda d: "sk"
                mod.ledger_append = lambda root, n, v: True
                mod.call_deepseek = lambda *a, **k: {"summary": "s.",
                                                     "tags": ["jira"]}
                mod.main(["--vault", str(vault)])
                text = (vault / "chats" / "gpt" / "2025-08" / "a.md").read_text(encoding="utf-8")
                fm, _ = mod.split_frontmatter(text)
                self.assertEqual(mod.fm_value(fm, "enriched_at"), "2026-07-10")
        finally:
            mod.datetime = orig


if __name__ == "__main__":
    unittest.main(verbosity=2)
