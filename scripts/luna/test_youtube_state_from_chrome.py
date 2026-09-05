#!/usr/bin/env python3
"""Offline tests for youtube-state-from-chrome.py (no network, no yt-dlp, no real HOME writes)."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("youtube-state-from-chrome.py")
SPEC = importlib.util.spec_from_file_location("youtube_state_from_chrome", MODULE_PATH)
assert SPEC and SPEC.loader
youtube_state = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = youtube_state
SPEC.loader.exec_module(youtube_state)

FETCH_HEALTH_PATH = Path(__file__).with_name("fetch-health.py")
FETCH_HEALTH_SPEC = importlib.util.spec_from_file_location("fetch_health", FETCH_HEALTH_PATH)
assert FETCH_HEALTH_SPEC and FETCH_HEALTH_SPEC.loader
fetch_health = importlib.util.module_from_spec(FETCH_HEALTH_SPEC)
sys.modules[FETCH_HEALTH_SPEC.name] = fetch_health
FETCH_HEALTH_SPEC.loader.exec_module(fetch_health)

# A jar carrying an HttpOnly login cookie, a plain YouTube cookie and a
# Google auth cookie the YouTube session also needs.
MIXED_JAR = (
    "# Netscape HTTP Cookie File\n"
    "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t2147483647\tSID\thttponly-secret-value\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tplain-secret-value\n"
    ".google.com\tTRUE\t/\tTRUE\t2147483647\tSSID\tgoogle-secret-value\n"
)

# The same jar plus one unrelated-domain cookie that must be filtered out.
JAR_WITH_UNRELATED_DOMAIN = MIXED_JAR + ".example.com\tTRUE\t/\tTRUE\t2147483647\tirrelevant\tirrelevant-value\n"

NO_MATCH_JAR = "# Netscape HTTP Cookie File\n.example.com\tTRUE\t/\tTRUE\t2147483647\tirrelevant\tirrelevant-value\n"

# CR round 1 codex-1: a SIGNED-OUT Chrome profile still exports these visitor
# cookies for youtube.com/google.com — count > 0, but no auth marker among
# them. Names match the live-measured signed-out set.
VISITOR_ONLY_JAR = (
    "# Netscape HTTP Cookie File\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tvisitor-value\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tYSC\tysc-value\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tPREF\tpref-value\n"
    ".google.com\tTRUE\t/\tTRUE\t2147483647\tNID\tnid-value\n"
)

# CR round 2 codex-1, measured live on the real jar: yt-dlp's Chrome export
# writes the Netscape expiry column as Chrome's own WebKit/Chromium
# microseconds-since-1601 timestamp, not Unix seconds.
# 13467564657153552 -> 1823091057.153552 Unix seconds (2027-10-09), a sane
# ~1-year-out SID expiry (computed independently via raw/1e6 - 11644473600,
# not just trusted from the CR message).
WEBKIT_EXPIRY_RAW = 13467564657153552
WEBKIT_EXPIRY_UNIX = 1823091057.153552

# A WebKit timestamp landing in 2020-01-01 (1577836800 Unix seconds) —
# unambiguously in the past for any date this suite could plausibly run on,
# and also safely before the fixed NOW_FOR_TESTS reference below.
WEBKIT_EXPIRED_RAW = 13222310400000000
NOW_FOR_TESTS = 1800000000.0  # between WEBKIT_EXPIRED's and WEBKIT_EXPIRY's converted dates

WEBKIT_EXPIRY_JAR = (
    "# Netscape HTTP Cookie File\n"
    f".google.com\tTRUE\t/\tTRUE\t{WEBKIT_EXPIRY_RAW}\tSID\twebkit-secret-value\n"
)

UNIX_EXPIRY_JAR = (
    "# Netscape HTTP Cookie File\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tunix-secret-value\n"
)

# A session-cookie (expiry 0) auth marker alongside a plain visitor cookie.
SESSION_MARKER_JAR = (
    "# Netscape HTTP Cookie File\n"
    ".youtube.com\tTRUE\t/\tTRUE\t0\tSID\tsession-secret-value\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tvisitor-value\n"
)

# An auth marker whose WebKit-form expiry is in the past, alongside a plain
# visitor cookie (so the jar is not ALSO hitting the zero-marker case).
EXPIRED_MARKER_JAR = (
    "# Netscape HTTP Cookie File\n"
    f".google.com\tTRUE\t/\tTRUE\t{WEBKIT_EXPIRED_RAW}\tSID\texpired-secret-value\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tvisitor-value\n"
)

# CR round 6 codex-2: a jar whose ONLY marker is SAPISID (measured live,
# authenticated-only, previously omitted from AUTH_MARKER_COOKIES) alongside
# a plain visitor cookie — must be ACCEPTED, not rejected as signed out.
SAPISID_ONLY_MARKER_JAR = (
    "# Netscape HTTP Cookie File\n"
    ".google.com\tTRUE\t/\tTRUE\t2147483647\tSAPISID\tsapisid-secret-value\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tvisitor-value\n"
)

# CR round 7 codex-1: a future-dated but EMPTY marker (`SID=`) used to
# satisfy both the name check and the expiry check. Only marker present, and
# it's empty -> must be rejected same as no marker at all.
EMPTY_MARKER_ONLY_JAR = (
    "# Netscape HTTP Cookie File\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tSID\t\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tVISITOR_INFO1_LIVE\tvisitor-value\n"
)

# The same empty SID= alongside a REAL marker (LOGIN_INFO) — the empty one
# must not poison an otherwise-valid export.
EMPTY_MARKER_ALONGSIDE_REAL_ONE_JAR = (
    "# Netscape HTTP Cookie File\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tSID\t\n"
    ".youtube.com\tTRUE\t/\tTRUE\t2147483647\tLOGIN_INFO\treal-login-info-value\n"
)


def _write_jar(directory: Path, content: str) -> Path:
    jar_path = directory / "cookies.txt"
    jar_path.write_text(content, encoding="utf-8")
    return jar_path


class YoutubeStateFromChromeTests(unittest.TestCase):
    def test_mixed_jar_converts_all_three_cookies_with_correct_http_only_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), MIXED_JAR)
            state = youtube_state.build_storage_state(jar_path)
            self.assertEqual(state["origins"], [])
            by_name = {c["name"]: c for c in state["cookies"]}
            self.assertEqual(set(by_name), {"SID", "VISITOR_INFO1_LIVE", "SSID"})
            self.assertTrue(by_name["SID"]["httpOnly"])
            self.assertFalse(by_name["VISITOR_INFO1_LIVE"]["httpOnly"])
            self.assertFalse(by_name["SSID"]["httpOnly"])
            self.assertEqual(by_name["SID"]["domain"], ".youtube.com")
            self.assertEqual(by_name["SSID"]["domain"], ".google.com")

    def test_emitted_cookies_do_not_carry_a_samesite_key(self):
        # CR round 6 codex-3: the Netscape source has no SameSite column, so
        # hard-coding "Lax" asserted a value the source never provided (and
        # got it wrong for __Secure-3PSID-style cookies that need None).
        # Omit the field entirely rather than guess. probe_youtube reads only
        # name/value, so this is invisible to it — exactly why a test has to
        # pin the emitted shape directly rather than rely on the probe.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), MIXED_JAR)
            state = youtube_state.build_storage_state(jar_path)
            for cookie in state["cookies"]:
                self.assertNotIn("sameSite", cookie)

    def test_unrelated_domain_cookie_is_filtered_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), JAR_WITH_UNRELATED_DOMAIN)
            state = youtube_state.build_storage_state(jar_path)
            names = {c["name"] for c in state["cookies"]}
            self.assertEqual(names, {"SID", "VISITOR_INFO1_LIVE", "SSID"})
            self.assertNotIn("irrelevant", names)

    def test_output_file_mode_is_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), MIXED_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            mode = stat.S_IMODE(os.stat(out_path).st_mode)
            self.assertEqual(mode, 0o600)

    def test_no_matching_cookies_writes_no_file_and_returns_nonzero(self):
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), NO_MATCH_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertNotEqual(exit_code, 0)
            self.assertFalse(out_path.exists())
            self.assertIn("no YouTube cookies", stderr.getvalue())

    def test_success_stdout_names_count_and_path_but_never_a_cookie_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), MIXED_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            output = stdout.getvalue()
            self.assertIn("3", output)
            self.assertIn(str(out_path), output)
            for secret in ("httponly-secret-value", "plain-secret-value", "google-secret-value"):
                self.assertNotIn(secret, output)

    def test_visitor_cookies_only_writes_no_file_and_returns_nonzero(self):
        # CR round 1 codex-1: a signed-out profile's visitor-only cookies
        # must NOT overwrite a good working storage state. count > 0 here
        # (4 cookies survive the domain filter) but none is an auth marker.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), VISITOR_ONLY_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            out_path.parent.mkdir(parents=True)
            out_path.write_text('{"cookies": [{"name": "existing"}], "origins": []}', encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertNotEqual(exit_code, 0)
            # The prior good state must survive untouched.
            self.assertEqual(out_path.read_text(encoding="utf-8"), '{"cookies": [{"name": "existing"}], "origins": []}')
            self.assertIn("signed-in session marker", stderr.getvalue())

    def test_a_jar_whose_only_marker_is_sapisid_is_accepted(self):
        # CR round 6 codex-2: AUTH_MARKER_COOKIES used to carry only 4 of the
        # 11 measured authenticated-only names. SAPISID is one of the missing
        # 7 — a valid export whose only marker was SAPISID was wrongly
        # rejected as signed out. Must now be accepted.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), SAPISID_ONLY_MARKER_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            self.assertTrue(out_path.is_file())

    def test_empty_valued_marker_alone_writes_no_file_and_returns_nonzero(self):
        # CR round 7 codex-1: a future-dated but EMPTY marker (`SID=`) used
        # to pass both the name check and the expiry check. Only marker
        # present is empty -> must be rejected, same as no marker at all.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), EMPTY_MARKER_ONLY_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertNotEqual(exit_code, 0)
            self.assertFalse(out_path.exists())
            self.assertIn("signed-in session marker", stderr.getvalue())

    def test_empty_valued_marker_does_not_poison_an_otherwise_valid_export(self):
        # Control for the above: the empty SID= must not reject an export
        # that ALSO carries a real marker (LOGIN_INFO).
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), EMPTY_MARKER_ALONGSIDE_REAL_ONE_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            self.assertTrue(out_path.is_file())

    def test_signed_out_and_empty_failure_messages_are_distinguishable(self):
        # An operator needs to tell "wrong profile" (zero cookies survived
        # the domain filter) apart from "signed-out profile" (cookies
        # survived, but none of them is an auth marker) — same exit code,
        # different diagnosis.
        with tempfile.TemporaryDirectory() as tmp:
            empty_dir = Path(tmp) / "a"
            empty_dir.mkdir()
            signed_out_dir = Path(tmp) / "b"
            signed_out_dir.mkdir()
            empty_jar = _write_jar(empty_dir, NO_MATCH_JAR)
            signed_out_jar = _write_jar(signed_out_dir, VISITOR_ONLY_JAR)
            empty_out = Path(tmp) / "empty.json"
            signed_out_out = Path(tmp) / "signed-out.json"

            empty_stderr = io.StringIO()
            with redirect_stderr(empty_stderr):
                youtube_state.main(["--from-cookies", str(empty_jar), "--out", str(empty_out)])
            signed_out_stderr = io.StringIO()
            with redirect_stderr(signed_out_stderr):
                youtube_state.main(["--from-cookies", str(signed_out_jar), "--out", str(signed_out_out)])

            self.assertIn("no YouTube cookies", empty_stderr.getvalue())
            self.assertNotIn("signed-in session marker", empty_stderr.getvalue())
            self.assertIn("signed-in session marker", signed_out_stderr.getvalue())
            self.assertNotIn("no YouTube cookies", signed_out_stderr.getvalue())

    def test_webkit_microsecond_expiry_converts_to_correct_unix_seconds(self):
        # CR round 2 codex-1: yt-dlp's Chrome export writes the Netscape
        # expiry column as WebKit microseconds-since-1601, not Unix seconds.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), WEBKIT_EXPIRY_JAR)
            state = youtube_state.build_storage_state(jar_path)
            self.assertEqual(len(state["cookies"]), 1)
            # places=3 tolerates float64 rounding on a 17-significant-digit
            # raw value; the whole-second date (2027-10-09) is exact either way.
            self.assertAlmostEqual(state["cookies"][0]["expires"], WEBKIT_EXPIRY_UNIX, places=3)

    def test_plain_unix_seconds_expiry_passes_through_unchanged(self):
        # Control for the above: a jar that ALREADY carries a plain
        # Unix-seconds expiry must not be corrupted by the WebKit heuristic.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), UNIX_EXPIRY_JAR)
            state = youtube_state.build_storage_state(jar_path)
            self.assertEqual(state["cookies"][0]["expires"], 2147483647.0)

    def test_session_cookie_expiry_still_lands_as_negative_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), SESSION_MARKER_JAR)
            state = youtube_state.build_storage_state(jar_path)
            by_name = {c["name"]: c for c in state["cookies"]}
            self.assertEqual(by_name["SID"]["expires"], -1.0)

    def test_expired_auth_marker_writes_no_file_and_names_expiry(self):
        # CR round 2 codex-1: an auth marker that IS present but past its
        # (correctly-converted) expiry must not overwrite a good state.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), EXPIRED_MARKER_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            stderr = io.StringIO()
            with patch.object(youtube_state, "_current_unix_time", return_value=NOW_FOR_TESTS):
                with redirect_stderr(stderr):
                    exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertNotEqual(exit_code, 0)
            self.assertFalse(out_path.exists())
            self.assertIn("EXPIRED", stderr.getvalue())
            # Distinct from both existing messages — the operator needs to
            # tell "signed out"/"wrong profile" apart from "session expired".
            self.assertNotIn("signed-in session marker (looked for one of", stderr.getvalue())
            self.assertNotIn("no YouTube cookies", stderr.getvalue())

    def test_session_cookie_auth_marker_is_accepted_as_not_expired(self):
        # A session-cookie marker (expires -1) has no real expiry to compare
        # against "now" and must be ACCEPTED, not treated as expired.
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), SESSION_MARKER_JAR)
            out_path = Path(tmp) / "state" / "youtube.json"
            with patch.object(youtube_state, "_current_unix_time", return_value=NOW_FOR_TESTS):
                exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            self.assertTrue(out_path.is_file())

    def test_ytdlp_nonzero_exit_with_a_landed_jar_still_succeeds(self):
        # HIMMEL-2549, measured live: yt-dlp exits 1 on a video-extraction
        # warning ("The page needs to be reloaded") while still writing the
        # complete, correct cookie jar. The jar is the deliverable — a
        # non-zero exit must not throw a landed jar away.
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "state" / "youtube.json"

            def fake_run(args, **kwargs):
                cookie_path = Path(args[args.index("--cookies") + 1])
                cookie_path.write_text(MIXED_JAR, encoding="utf-8")
                return subprocess.CompletedProcess(args, 1, "", "ERROR: [youtube] dQw4w9WgXcQ: The page needs to be reloaded.\n")

            stderr = io.StringIO()
            with patch.object(youtube_state.shutil, "which", return_value="/bin/yt-dlp"):
                with patch.object(youtube_state.subprocess, "run", fake_run):
                    with redirect_stderr(stderr):
                        exit_code = youtube_state.main(["--profile", "Default", "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            self.assertTrue(out_path.is_file())
            self.assertIn("despite a yt-dlp extraction warning", stderr.getvalue())

    def test_ytdlp_truncated_jar_without_trailing_newline_fails(self):
        # CR round 3 codex-1: yt-dlp's own YoutubeDLCookieJar.save() writes
        # the file directly (no temp-file-and-rename), so a kill or a full
        # disk mid-write can leave a nonempty but TRUNCATED jar (no trailing
        # newline). That must not be accepted as a usable export, even
        # though a live auth marker line could have already landed.
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "state" / "youtube.json"
            truncated = MIXED_JAR.rstrip("\n")  # cut mid-line, no trailing newline

            def fake_run(args, **kwargs):
                cookie_path = Path(args[args.index("--cookies") + 1])
                cookie_path.write_text(truncated, encoding="utf-8")
                return subprocess.CompletedProcess(args, 0, "", "")

            stderr = io.StringIO()
            with patch.object(youtube_state.shutil, "which", return_value="/bin/yt-dlp"):
                with patch.object(youtube_state.subprocess, "run", fake_run):
                    with redirect_stderr(stderr):
                        exit_code = youtube_state.main(["--profile", "Default", "--out", str(out_path)])
            self.assertNotEqual(exit_code, 0)
            self.assertFalse(out_path.exists())
            self.assertIn("TRUNCATED", stderr.getvalue())

    def test_ytdlp_properly_terminated_jar_still_succeeds(self):
        # Control for the above: a well-formed, newline-terminated jar from a
        # successful yt-dlp run must not be rejected by the truncation check.
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "state" / "youtube.json"

            def fake_run(args, **kwargs):
                cookie_path = Path(args[args.index("--cookies") + 1])
                cookie_path.write_text(MIXED_JAR, encoding="utf-8")
                return subprocess.CompletedProcess(args, 0, "", "")

            with patch.object(youtube_state.shutil, "which", return_value="/bin/yt-dlp"):
                with patch.object(youtube_state.subprocess, "run", fake_run):
                    exit_code = youtube_state.main(["--profile", "Default", "--out", str(out_path)])
            self.assertEqual(exit_code, 0)
            self.assertTrue(out_path.is_file())

    def test_ytdlp_nonzero_exit_with_no_jar_written_still_fails(self):
        # Negative control for the above: a non-zero exit that never produced
        # a cookie file at all is a real failure, not an advisory.
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "state" / "youtube.json"

            def fake_run(args, **kwargs):
                return subprocess.CompletedProcess(args, 1, "", "ERROR: could not copy Chrome cookie database\n")

            stderr = io.StringIO()
            with patch.object(youtube_state.shutil, "which", return_value="/bin/yt-dlp"):
                with patch.object(youtube_state.subprocess, "run", fake_run):
                    with redirect_stderr(stderr):
                        exit_code = youtube_state.main(["--profile", "Default", "--out", str(out_path)])
            self.assertNotEqual(exit_code, 0)
            self.assertFalse(out_path.exists())

    def test_produced_state_is_consumable_by_the_real_fetch_health_probe(self):
        # Proves the two halves agree on the file shape: probe_youtube reads
        # exactly what this script writes (HIMMEL-2549).
        with tempfile.TemporaryDirectory() as tmp:
            jar_path = _write_jar(Path(tmp), MIXED_JAR)
            state_path = Path(tmp) / ".luna" / "playwright-state" / "youtube.json"
            exit_code = youtube_state.main(["--from-cookies", str(jar_path), "--out", str(state_path)])
            self.assertEqual(exit_code, 0)

            def http(url, **kwargs):
                return fetch_health.HttpResult(200, b'<html><script>ytcfg.set({"LOGGED_IN":true});</script></html>')

            result = fetch_health.probe_youtube({"HOME": tmp}, http)
            self.assertEqual(result.status, "ok")


if __name__ == "__main__":
    unittest.main()
