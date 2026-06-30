# marketplace/plugins/obsidian-triage/tests/test-vault-lint.py
import os, sys, unittest, copy, shutil, subprocess, json, tempfile, pathlib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "skills", "vault-lint"))
import vault_lint as vl

_ENGINE = os.path.join(os.path.dirname(__file__), "..", "skills", "vault-lint", "vault_lint.py")


class TestCliEncoding(unittest.TestCase):
    """Regression: non-ASCII output must not crash when stdout is cp1252 (Windows)."""

    def test_non_ascii_output_survives_cp1252_stdout(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        # Hebrew filename + content + em-dash → forces non-ASCII into JSON output
        p = pathlib.Path(d, "שלום.md")
        p.write_text("# כותרת — [[שלום]]\n", encoding="utf-8")
        env = {**os.environ, "PYTHONIOENCODING": "cp1252"}
        result = subprocess.run(
            [sys.executable, _ENGINE, d, "--no-report", "--json"],
            env=env, capture_output=True,
        )
        self.assertEqual(
            result.returncode, 0,
            msg=f"Engine crashed. stderr:\n{result.stderr.decode('utf-8', errors='replace')}",
        )
        parsed = json.loads(result.stdout.decode("utf-8"))

class TestExtraction(unittest.TestCase):
    def test_target_strips_alias_heading_block(self):
        self.assertEqual(vl.link_target("path/Note|Alias"), "path/Note")
        self.assertEqual(vl.link_target("Note#Heading"), "Note")
        self.assertEqual(vl.link_target("Note^block1"), "Note")
        self.assertEqual(vl.link_target("  Note  "), "Note")
        # Table-escaped alias pipe (`[[target\|alias]]` inside a markdown table)
        # must not leave a trailing backslash on the target (HIMMEL-411).
        self.assertEqual(vl.link_target(r"path/Note\|Alias"), "path/Note")
        self.assertEqual(
            vl.extract_links(r"| [[30-Resources/Tech/caveman\|caveman]] | x |"),
            ["30-Resources/Tech/caveman"],
        )
    def test_strip_code_removes_fenced_and_inline(self):
        t = "real [[A]]\n```\ncode [[B]]\n```\nand `inline [[C]]` end"
        s = vl.strip_code(t)
        self.assertIn("[[A]]", s)
        self.assertNotIn("[[B]]", s)
        self.assertNotIn("[[C]]", s)
    def test_extract_ignores_code_span_links(self):
        t = "see [[Real Note]] but not `[[regex-class]]` nor <placeholder>"
        self.assertEqual(vl.extract_links(t), ["Real Note"])

class TestResolution(unittest.TestCase):
    def setUp(self):
        import tempfile, pathlib
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, ignore_errors=True)
        def w(rel, body=""):
            p = pathlib.Path(self.d, rel); p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        w("A.md", "links to [[B]] and [[sub/C]] and [[data.json]] and [[Missing]]")
        w("sub/C.md", "")
        w("B.md", "")
        w("data.json", "{}")
        w("_done/2026-01/Old.md", "")
        w("refs-old.md", "see [[Old]]")          # basename resolves into _done/
        w("שלום.md", "[[B]]")                      # Hebrew filename
        self.cfg = copy.deepcopy(vl.DEFAULTS)
        self.idx = vl.build_index(self.d, self.cfg)
    def test_relpath_and_basename_resolve(self):
        self.assertTrue(vl.resolve("B", self.idx))
        self.assertTrue(vl.resolve("sub/C", self.idx))
    def test_non_md_existing_file_not_dead(self):
        self.assertTrue(vl.resolve("data.json", self.idx))
    def test_done_relocation_resolves_by_basename(self):
        self.assertTrue(vl.resolve("Old", self.idx))
    def test_missing_is_dead(self):
        self.assertFalse(vl.resolve("Missing", self.idx))
    def test_hebrew_indexed(self):
        self.assertIn("שלום.md", self.idx["by_rel"])

class TestLint(unittest.TestCase):
    def setUp(self):
        import tempfile, pathlib
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, ignore_errors=True)
        def w(rel, body=""):
            p = pathlib.Path(self.d, rel); p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        w("Home.md", "[[Hub]]")
        w("Hub.md", "---\ntype: x\n---\n[[Real]]")
        w("Real.md", "---\ntype: x\n---\nbody")
        w("Orphan.md", "---\ntype: x\n---\nnobody links here")     # real orphan
        w("_raw/dump.md", "raw [[Nowhere]]")                        # by-design: bulk dir
        w("_index.md", "no frontmatter hub")                        # by-design: orphan_exempt + fm_exempt
        w("60-Maps/old-lint.md", "[[GhostFromReport]]")             # link_scan_exclude: its links are data
        self.cfg = copy.deepcopy(vl.DEFAULTS)
        self.res = vl.lint(self.d, self.cfg, "2026-06-19")
    def _kinds(self, bucket): return {(f["kind"], f["path"]) for f in self.res[bucket]}
    def test_real_orphan_flagged(self):
        self.assertIn(("orphan", "Orphan.md"), self._kinds("real"))
    def test_bulk_dir_orphan_is_by_design(self):
        self.assertIn(("orphan", "_raw/dump.md"), self._kinds("by_design"))
        self.assertNotIn(("orphan", "_raw/dump.md"), self._kinds("real"))
    def test_report_file_links_not_scanned(self):
        self.assertNotIn(("dead_link", "60-Maps/old-lint.md"), self._kinds("real"))
    def test_exempt_hub_no_frontmatter_not_real(self):
        self.assertNotIn(("frontmatter", "_index.md"), self._kinds("real"))
    def test_summary_counts(self):
        self.assertEqual(self.res["summary"]["real_count"], len(self.res["real"]))

class TestCliReport(unittest.TestCase):
    def test_load_config_merges_vault_file(self):
        import tempfile, pathlib, json as j
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        pathlib.Path(d, ".vault-lint.json").write_text(j.dumps({"stale_task_days": 7}), encoding="utf-8")
        cfg = vl.load_config(d, None)
        self.assertEqual(cfg["stale_task_days"], 7)
        self.assertIn("bulk_dirs", cfg)                 # defaults still present
    def test_render_report_has_sections(self):
        res = {"summary": {"pages": 5, "real_count": 1, "by_design_count": 2, "date": "2026-06-19"},
               "real": [{"kind": "orphan", "path": "X.md", "detail": "no inbound link", "bucket": "(root)"}],
               "by_design": [{"kind": "orphan", "path": "_raw/a.md", "detail": "", "bucket": "_raw"}]}
        md = vl.render_report(res, vl.DEFAULTS)
        self.assertIn("# Lint Report: 2026-06-19", md)
        self.assertIn("by design (no action)", md.lower())
        self.assertIn("X.md", md)

class TestFindingEmission(unittest.TestCase):
    def _vault(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return d

    def _w(self, root, rel, body=""):
        import pathlib
        p = pathlib.Path(root, rel); p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")

    def _kinds(self, res, bucket):
        return {(f["kind"], f["path"]) for f in res[bucket]}

    def test_dead_link_emitted_real(self):
        d = self._vault()
        self._w(d, "A.md", "---\ntype: x\n---\n[[Missing]]")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        self.assertIn(("dead_link", "A.md"), self._kinds(res, "real"))

    def test_frontmatter_emitted_real(self):
        d = self._vault()
        # Hub links to Note so Note has an inbound link (avoids being only an orphan)
        self._w(d, "Hub.md", "---\ntype: x\n---\n[[Note]]")
        self._w(d, "Note.md", "no fm here")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        self.assertIn(("frontmatter", "Note.md"), self._kinds(res, "real"))

    def test_duplicate_emitted_real(self):
        d = self._vault()
        # Two non-bulk files sharing basename "Dup"
        self._w(d, "a/Dup.md", "---\ntype: x\n---\nbody")
        self._w(d, "b/Dup.md", "---\ntype: x\n---\nbody")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        dup_findings = [f for f in res["real"] if f["kind"] == "duplicate"]
        self.assertTrue(len(dup_findings) >= 1, "expected at least one duplicate finding")
        detail = dup_findings[0]["detail"]
        self.assertIn("a/Dup.md", detail)
        self.assertIn("b/Dup.md", detail)

    def test_known_unbuilt_links_by_design(self):
        d = self._vault()
        self._w(d, "X.md", "---\ntype: x\n---\n[[Stub]]")
        cfg = copy.deepcopy(vl.DEFAULTS)
        cfg["known_unbuilt_links"] = ["Stub"]
        res = vl.lint(d, cfg, "2026-06-19")
        # dead_link for [[Stub]] must be in by_design, NOT real
        real_dl = [(f["kind"], f["path"]) for f in res["real"] if f["kind"] == "dead_link"]
        bd_dl = [(f["kind"], f["path"]) for f in res["by_design"] if f["kind"] == "dead_link"]
        self.assertNotIn(("dead_link", "X.md"), real_dl)
        self.assertIn(("dead_link", "X.md"), bd_dl)

    def test_nested_bulk_dir_orphan_by_design(self):
        d = self._vault()
        self._w(d, "_raw/deep/nested/dump.md", "no fm, no links")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        self.assertIn(("orphan", "_raw/deep/nested/dump.md"), self._kinds(res, "by_design"))
        self.assertNotIn(("orphan", "_raw/deep/nested/dump.md"), self._kinds(res, "real"))

    def test_malformed_json_config_fallback(self):
        import tempfile, pathlib
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        pathlib.Path(d, ".vault-lint.json").write_text("{ not valid json }", encoding="utf-8")
        cfg = vl.load_config(d, None)
        self.assertEqual(cfg, vl.DEFAULTS)

    def test_missing_explicit_config_returns_defaults(self):
        cfg = vl.load_config("/tmp", "/no/such/file.json")
        self.assertIn("bulk_dirs", cfg)
        self.assertEqual(cfg["stale_task_days"], vl.DEFAULTS["stale_task_days"])


class TestDeterminism(unittest.TestCase):
    def _vault(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        return d

    def _w(self, root, rel, body=""):
        import pathlib
        p = pathlib.Path(root, rel); p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")

    def test_dead_link_dedup_per_note(self):
        """Same broken target linked twice in one note → exactly ONE dead_link finding."""
        d = self._vault()
        self._w(d, "A.md", "[[Missing]] and again [[Missing]]")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        count = sum(1 for f in res["real"] if f["kind"] == "dead_link" and f["path"] == "A.md")
        self.assertEqual(count, 1)

    def test_duplicate_path_is_lexicographic_first(self):
        """Duplicate finding path is the lexicographically-first non-bulk path."""
        d = self._vault()
        self._w(d, "b/Dup.md", "---\ntype: x\n---\nbody")
        self._w(d, "a/Dup.md", "---\ntype: x\n---\nbody")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        dup_findings = [f for f in res["real"] if f["kind"] == "duplicate"]
        self.assertTrue(len(dup_findings) >= 1, "expected at least one duplicate finding")
        self.assertEqual(dup_findings[0]["path"], "a/Dup.md")


class TestDefaultProfile(unittest.TestCase):
    """Parity test: default-profile.json must equal vault_lint.DEFAULTS."""

    def test_default_profile_parses_and_matches_defaults(self):
        import json
        profile_path = os.path.join(
            os.path.dirname(__file__), "..", "skills", "vault-lint", "default-profile.json"
        )
        with open(profile_path, encoding="utf-8") as fh:
            on_disk = json.load(fh)
        self.assertEqual(on_disk, vl.DEFAULTS)


class TestDuplicateExempt(unittest.TestCase):
    """_*.md (and other duplicate_exempt patterns) must not trigger duplicate findings."""

    def _w(self, root, rel, body=""):
        import pathlib
        p = pathlib.Path(root, rel); p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")

    def test_exempt_hubs_not_flagged_real_dup_still_flagged(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        # Intentional per-folder hubs — same basename, should be exempt
        self._w(d, "a/_index.md", "# hub a")
        self._w(d, "b/_index.md", "# hub b")
        self._w(d, "c/_index.md", "# hub c")
        # Genuine accidental duplicate — must still be flagged
        self._w(d, "x/Real.md", "---\ntype: x\n---\nbody")
        self._w(d, "y/Real.md", "---\ntype: x\n---\nbody")
        cfg = copy.deepcopy(vl.DEFAULTS)
        res = vl.lint(d, cfg, "2026-06-19")
        index_dups = [f for f in res["real"] if f["kind"] == "duplicate" and "_index" in f["detail"]]
        self.assertEqual(index_dups, [], f"_index hubs should not appear as real duplicates: {index_dups}")
        real_dups = [f for f in res["real"] if f["kind"] == "duplicate" and "Real" in f["detail"]]
        self.assertTrue(len(real_dups) >= 1, "Real.md duplicate must still be flagged")


class TestDotDirSkip(unittest.TestCase):
    """Dot-directories (.obsidian, .pytest_cache, .trash, etc.) must be skipped entirely."""

    def setUp(self):
        import pathlib
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, ignore_errors=True)
        def w(rel, body=""):
            p = pathlib.Path(self.d, rel); p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        # A normal note with an inbound link so it's not an orphan
        w("Hub.md", "---\ntype: x\n---\n[[Real]]")
        w("Real.md", "---\ntype: x\n---\nbody")
        # Dot-dir files — must never appear in the index or findings
        w(".obsidian/workspace.md", "obsidian config")
        w(".pytest_cache/README.md", "pytest cache")
        w(".trash/Deleted.md", "deleted note")
        self.cfg = copy.deepcopy(vl.DEFAULTS)

    def test_dot_dir_files_not_in_index(self):
        idx = vl.build_index(self.d, self.cfg)
        for rel in idx["by_rel"]:
            self.assertFalse(
                rel.startswith(".obsidian/") or rel.startswith(".pytest_cache/") or rel.startswith(".trash/"),
                f"dot-dir file unexpectedly indexed: {rel}",
            )

    def test_dot_dir_files_produce_no_findings(self):
        res = vl.lint(self.d, self.cfg, "2026-06-19")
        all_findings = res["real"] + res["by_design"]
        dot_findings = [
            f for f in all_findings
            if f["path"].startswith(".obsidian/") or f["path"].startswith(".pytest_cache/") or f["path"].startswith(".trash/")
        ]
        self.assertEqual(dot_findings, [], f"unexpected findings for dot-dir files: {dot_findings}")


if __name__ == "__main__":
    unittest.main()
