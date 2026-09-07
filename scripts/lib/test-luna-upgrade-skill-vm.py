#!/usr/bin/env python3
"""Hermetic tests for test-luna-upgrade-skill-vm.py helpers.

Run: python scripts/lib/test-luna-upgrade-skill-vm.py

All tests use a fake `run` callable (canned (rc, out) pairs) — no live VM
required.  Mirrors test-vmsdk.py style.
"""

import importlib.util
import json
import unittest
from pathlib import Path

# test-luna-upgrade-skill-vm.py lives in scripts/ (parent of lib/).
# The filename contains hyphens so we must use importlib, not bare import.
_SCRIPTS = Path(__file__).resolve().parent.parent
_DRIVER = _SCRIPTS / "test-luna-upgrade-skill-vm.py"
_spec = importlib.util.spec_from_file_location("test_luna_upgrade_skill_vm", _DRIVER)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


# ---------------------------------------------------------------------------
# S2 — upgrade-complete count
# ---------------------------------------------------------------------------

class TestS2UpgradeComplete(unittest.TestCase):
    def test_zero_occurrences_fails(self):
        self.assertFalse(mod.assert_s2_upgrade_complete("Nothing happened.\n"))

    def test_one_occurrence_passes(self):
        self.assertTrue(
            mod.assert_s2_upgrade_complete(
                "Running upgrade...\nUpgrade complete\nAll done.\n"
            )
        )

    def test_two_occurrences_fails(self):
        self.assertFalse(
            mod.assert_s2_upgrade_complete(
                "Upgrade complete\nSomething\nUpgrade complete\n"
            )
        )

    def test_empty_string_fails(self):
        self.assertFalse(mod.assert_s2_upgrade_complete(""))


# ---------------------------------------------------------------------------
# S3 — owned files restored (sha compare)
# ---------------------------------------------------------------------------

class TestS3OwnedFilesRestored(unittest.TestCase):
    _SETUP_SHA = "aabbcc"
    _APP_SHA = "ddeeff"

    def _run_both_match(self, cmd, **kw):
        if "setup.sh" in cmd:
            return (0, f"{self._SETUP_SHA}  /home/u/vault/scripts/setup.sh\n")
        if "app.json" in cmd:
            return (0, f"{self._APP_SHA}  /home/u/vault/.obsidian/app.json\n")
        return (0, "")

    def _run_setup_mismatch(self, cmd, **kw):
        if "setup.sh" in cmd:
            return (0, "BADSHA  /home/u/vault/scripts/setup.sh\n")
        if "app.json" in cmd:
            return (0, f"{self._APP_SHA}  /home/u/vault/.obsidian/app.json\n")
        return (0, "")

    def _run_app_missing(self, cmd, **kw):
        if "setup.sh" in cmd:
            return (0, f"{self._SETUP_SHA}  /home/u/vault/scripts/setup.sh\n")
        if "app.json" in cmd:
            return (1, "sha256sum: no such file")
        return (0, "")

    def test_both_match_both_pass(self):
        setup_ok, app_ok = mod.assert_s3_owned_files_restored(
            self._run_both_match,
            "~/luna-test-vault",
            self._SETUP_SHA,
            self._APP_SHA,
        )
        self.assertTrue(setup_ok)
        self.assertTrue(app_ok)

    def test_setup_mismatch_only_setup_fails(self):
        setup_ok, app_ok = mod.assert_s3_owned_files_restored(
            self._run_setup_mismatch,
            "~/luna-test-vault",
            self._SETUP_SHA,
            self._APP_SHA,
        )
        self.assertFalse(setup_ok)
        self.assertTrue(app_ok)

    def test_app_missing_only_app_fails(self):
        setup_ok, app_ok = mod.assert_s3_owned_files_restored(
            self._run_app_missing,
            "~/luna-test-vault",
            self._SETUP_SHA,
            self._APP_SHA,
        )
        self.assertTrue(setup_ok)
        self.assertFalse(app_ok)


# ---------------------------------------------------------------------------
# S4 — user content sha compare
# ---------------------------------------------------------------------------

class TestS4UserContent(unittest.TestCase):
    _USER_SHA = "112233"

    def _run_match(self, cmd, **kw):
        return (0, f"{self._USER_SHA}  /home/u/vault/50-Journal/Daily/2026-06-21.md\n")

    def _run_mismatch(self, cmd, **kw):
        return (0, "CHANGED  /home/u/vault/50-Journal/Daily/2026-06-21.md\n")

    def _run_missing(self, cmd, **kw):
        return (1, "sha256sum: no such file")

    def test_sha_match_passes(self):
        self.assertTrue(
            mod.assert_s4_user_content(self._run_match, "~/luna-test-vault", self._USER_SHA)
        )

    def test_sha_mismatch_fails(self):
        self.assertFalse(
            mod.assert_s4_user_content(self._run_mismatch, "~/luna-test-vault", self._USER_SHA)
        )

    def test_missing_file_fails(self):
        self.assertFalse(
            mod.assert_s4_user_content(self._run_missing, "~/luna-test-vault", self._USER_SHA)
        )


# ---------------------------------------------------------------------------
# S5 — stamp version == nested marketplace.json metadata.version
# ---------------------------------------------------------------------------

class TestS5Stamp(unittest.TestCase):
    _VER = "0.2.0"
    _STAMP = json.dumps({"version": _VER})
    _NESTED_MP = json.dumps({"metadata": {"version": _VER}, "plugins": []})
    _NESTED_MP_WRONG = json.dumps({"metadata": {"version": "0.0.1"}, "plugins": []})
    _NESTED_TARGET = (
        "templates/luna-second-brain/marketplace/.claude-plugin/marketplace.json"
    )

    def _run_match(self, cmd, **kw):
        if ".vault-template.json" in cmd:
            return (0, self._STAMP)
        if self._NESTED_TARGET in cmd:
            return (0, self._NESTED_MP)
        return (0, "")

    def _run_version_mismatch(self, cmd, **kw):
        if ".vault-template.json" in cmd:
            return (0, self._STAMP)
        if self._NESTED_TARGET in cmd:
            return (0, self._NESTED_MP_WRONG)
        return (0, "")

    def _run_stamp_missing(self, cmd, **kw):
        if ".vault-template.json" in cmd:
            return (1, "cat: no such file")
        return (0, "")

    def test_version_match_passes(self):
        self.assertTrue(mod.assert_s5_stamp(self._run_match, "~/luna-test-vault"))

    def test_version_mismatch_fails(self):
        self.assertFalse(
            mod.assert_s5_stamp(self._run_version_mismatch, "~/luna-test-vault")
        )

    def test_stamp_missing_fails(self):
        self.assertFalse(
            mod.assert_s5_stamp(self._run_stamp_missing, "~/luna-test-vault")
        )

    def test_nested_marketplace_path_targeted(self):
        """S5 must read the NESTED template marketplace.json (not repo-root)."""
        cats = []

        def recording_run(cmd, **kw):
            if cmd.startswith("cat "):
                cats.append(cmd)
            if ".vault-template.json" in cmd:
                return (0, self._STAMP)
            if self._NESTED_TARGET in cmd:
                return (0, self._NESTED_MP)
            return (0, "")

        mod.assert_s5_stamp(recording_run, "~/luna-test-vault")
        mp_cats = [c for c in cats if "marketplace.json" in c]
        self.assertTrue(
            any(self._NESTED_TARGET in c for c in mp_cats),
            f"expected nested marketplace.json path in cat commands; got: {mp_cats}",
        )
        # Confirm it does NOT read the repo-root marketplace.json (which lacks
        # metadata.version)
        self.assertFalse(
            any(
                "marketplace/.claude-plugin/marketplace.json" in c
                and "luna-second-brain" not in c
                for c in mp_cats
            ),
            "S5 must not read the repo-root marketplace.json"
        )


# ---------------------------------------------------------------------------
# Auth-blocker decision (_is_auth_blocker)
# ---------------------------------------------------------------------------

class TestAuthBlocker(unittest.TestCase):
    def test_auth_signature_nonzero_fires(self):
        """A canned auth-failure output with rc!=0 triggers the blocker."""
        self.assertTrue(mod._is_auth_blocker("Error: not logged in", rc=1))

    def test_please_run_login_fires(self):
        self.assertTrue(
            mod._is_auth_blocker("Please run claude login to authenticate", rc=1)
        )

    def test_invalid_api_key_fires(self):
        self.assertTrue(mod._is_auth_blocker("Invalid API key provided.", rc=1))

    def test_authentication_failed_fires(self):
        self.assertTrue(mod._is_auth_blocker("Authentication failed.", rc=1))

    def test_credit_balance_fires(self):
        self.assertTrue(
            mod._is_auth_blocker("Insufficient credit balance.", rc=1)
        )

    def test_quota_fires(self):
        self.assertTrue(
            mod._is_auth_blocker("You have exceeded your quota.", rc=1)
        )

    def test_rate_limit_fires(self):
        self.assertTrue(mod._is_auth_blocker("Rate limit exceeded.", rc=1))

    def test_empty_output_nonzero_fires(self):
        """Empty output on rc!=0 is treated as 'no engine output at all'."""
        self.assertTrue(mod._is_auth_blocker("", rc=1))
        self.assertTrue(mod._is_auth_blocker("   \n", rc=1))

    def test_clean_rc0_with_quota_word_does_not_fire(self):
        """rc==0 with the word 'quota' must NOT fire — false-positive guard."""
        self.assertFalse(
            mod._is_auth_blocker(
                "Upgrade complete\nquota of files refreshed: 3\n", rc=0
            )
        )

    def test_clean_rc0_with_rate_limit_does_not_fire(self):
        self.assertFalse(
            mod._is_auth_blocker(
                "rate limit not reached; upgrade complete\n", rc=0
            )
        )

    def test_normal_output_nonzero_no_auth_token_does_not_fire(self):
        """Non-zero rc without any auth token is not a blocker."""
        self.assertFalse(
            mod._is_auth_blocker("Skill failed: upgrade.sh returned 1", rc=1)
        )


# ---------------------------------------------------------------------------
# Crash classification — rc-3 branch fires on signal-kill or crash keywords
# ---------------------------------------------------------------------------

class TestCrashClassification(unittest.TestCase):
    """Test that the driver classifies a claude crash as environment (rc 3)."""

    def _make_driver_run(self, rc, out):
        """Return a fake run() that returns fixed (rc, out) for all calls."""
        def fake_run(cmd, **kw):
            # Scaffold and probe commands must succeed for the driver to reach
            # the rc-3 check.  Triage: return success for everything except the
            # drive command itself (detected by "timeout" in the command string).
            if "timeout" in cmd:
                return (rc, out)
            # Support bash -lc 'command -v claude' probe → success
            if "command -v claude" in cmd:
                return (0, "/home/u/.local/bin/claude\n")
            # cp, mkdir, printf, sha256sum, rm for scaffold → success
            return (0, "placeholder\n")
        return fake_run

    def _run_driver_main_with_fake_vm(self, drive_rc, drive_out):
        """Invoke mod.main() with a fake VM wired to return (drive_rc, drive_out)
        from drive_claude, and capture sys.exit code.

        Uses unittest.mock to replace the VM class inside mod.main()'s lazy import.
        """
        import sys as _sys
        from unittest import mock as _mock

        class _FakeVM:
            def __init__(self, *a, **kw):
                pass
            def ensure_up(self):
                pass
            def run(self, cmd, **kw):
                if "command -v claude" in cmd:
                    return (0, "/home/u/.local/bin/claude\n")
                # scaffold + probe calls → success with placeholder sha output
                return (0, "abc123  /some/file\n")
            def sync_repo(self, *a, **kw):
                pass
            def install_plugin(self, *a, **kw):
                pass
            def drive_claude(self, prompt, cwd, timeout=600):
                return (drive_rc, drive_out)

        with _mock.patch.dict(_sys.modules, {}):
            # Patch vmsdk.VM inside the driver's lazy import context
            import importlib
            import vmsdk as _vmsdk_mod
            original_vm = _vmsdk_mod.VM
            _vmsdk_mod.VM = _FakeVM
            try:
                with self.assertRaises(SystemExit) as cm:
                    mod.main()
            finally:
                _vmsdk_mod.VM = original_vm
        return cm.exception.code

    def test_segfault_rc139_exits_3(self):
        """rc=139 (SIGSEGV) with crash output → env blocker, exit 3."""
        code = self._run_driver_main_with_fake_vm(
            drive_rc=139,
            drive_out="Segmentation fault (core dumped)\n",
        )
        self.assertEqual(code, 3)

    def test_sigkill_rc137_exits_3(self):
        """rc=137 (SIGKILL) → env blocker, exit 3."""
        code = self._run_driver_main_with_fake_vm(
            drive_rc=137,
            drive_out="Killed\n",
        )
        self.assertEqual(code, 3)

    def test_rc128_exits_3(self):
        """Any rc >= 128 (even without crash keyword) → env blocker, exit 3."""
        code = self._run_driver_main_with_fake_vm(
            drive_rc=128,
            drive_out="some unknown signal\n",
        )
        self.assertEqual(code, 3)

    def test_timeout_rc124_exits_3(self):
        """rc=124 (timeout --signal=KILL) → environment blocker, exit 3."""
        code = self._run_driver_main_with_fake_vm(
            drive_rc=124,
            drive_out="",
        )
        self.assertEqual(code, 3)

    def test_rc1_with_crash_keyword_is_not_masked_as_env(self):
        """A real defect (rc=1) that merely prints a crash keyword must NOT be
        misclassified as an env crash (exit 3) — crash = rc>=128 ONLY."""
        code = self._run_driver_main_with_fake_vm(
            drive_rc=1,
            drive_out="boom: core dumped while writing\n",
        )
        # rc<128 + no auth signature + non-empty output → falls through to the
        # assertions; S2 fails (no 'Upgrade complete') → exit 1, NOT env rc 3.
        self.assertNotEqual(code, 3,
                            msg=f"crash keyword at rc<128 must not mask as env; got {code}")


class TestScaffoldIdempotency(unittest.TestCase):
    """scaffold_vault must clear a stale vault (rm -rf) before cp -r."""

    def test_rm_rf_issued_before_cp_r_and_returns_three_shas(self):
        calls = []

        def fake_run(cmd, **kw):
            calls.append(cmd)
            if cmd.startswith("sha256sum"):
                return (0, "deadbeef00  /some/file\n")
            return (0, "")

        result = mod.scaffold_vault(fake_run)
        self.assertEqual(len(result), 3)  # (user_sha, tmpl_setup_sha, tmpl_app_sha)

        rm_idx = next(i for i, c in enumerate(calls) if c.startswith("rm -rf"))
        cp_idx = next(i for i, c in enumerate(calls) if c.startswith("cp -r"))
        self.assertLess(rm_idx, cp_idx,
                        msg="rm -rf must precede cp -r for idempotent re-runs")


if __name__ == "__main__":
    unittest.main()
