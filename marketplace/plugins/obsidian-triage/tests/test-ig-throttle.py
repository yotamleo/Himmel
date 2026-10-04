#!/usr/bin/env python3
"""Hermetic tests for the shared Instagram throttle (HIMMEL-4306).

No network, no Instagram. A fake clock/sleep drives the Python module; the node
twin is exercised through its CLI against the SAME state file, which is what
proves the two languages share one budget.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

TOOLS = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(TOOLS / "lib"))
import ig_throttle  # noqa: E402

NODE = shutil.which("node")
# 2026-10-04 12:00:00 UTC
T0 = datetime(2026, 10, 4, 12, 0, 0, tzinfo=timezone.utc).timestamp()
MIDNIGHT = datetime(2026, 10, 5, 0, 0, 0, tzinfo=timezone.utc).timestamp()


class Clock:
    def __init__(self, t: float = T0):
        self.t = t
        self.slept: list[float] = []

    def now(self) -> float:
        return self.t

    def sleep(self, s: float) -> None:
        self.slept.append(s)
        self.t += s


class ThrottleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = {
            "HIMMEL_IG_THROTTLE_STATE": os.path.join(self.tmp, "ig.json"),
            "HIMMEL_IG_MIN_GAP_S": "30",
            "HIMMEL_IG_JITTER_S": "10",
            "HIMMEL_IG_DAILY_CAP": "3",
            "HIMMEL_IG_BACKOFF_BASE_S": "60",
        }
        self.clock = Clock()

    def acquire(self, rng=lambda a, b: 0.0):
        return ig_throttle.acquire(self.env, now=self.clock.now, sleep=self.clock.sleep, rng=rng)

    def test_first_request_goes_straight_through(self):
        d = self.acquire()
        self.assertTrue(d.ok)
        self.assertEqual(self.clock.slept, [])

    def test_second_request_waits_the_minimum_gap(self):
        self.acquire()
        d = self.acquire()
        self.assertTrue(d.ok)
        self.assertEqual(self.clock.slept, [30.0])

    def test_jitter_is_added_to_the_gap(self):
        self.acquire()
        self.acquire(rng=lambda a, b: 7.5)
        self.assertEqual(self.clock.slept, [37.5])

    def test_wait_false_denies_as_spacing_and_reserves_nothing(self):
        self.acquire()
        d = ig_throttle.acquire(self.env, now=self.clock.now, sleep=self.clock.sleep,
                                rng=lambda a, b: 0.0, wait=False)
        self.assertEqual((d.ok, d.reason), (False, "spacing"))
        self.assertEqual(self.clock.slept, [])
        self.assertEqual(ig_throttle.status(self.env, now=self.clock.now)["count"], 1)

    def test_no_wait_once_the_gap_has_already_passed(self):
        self.acquire()
        self.clock.t += 120
        self.acquire()
        self.assertEqual(self.clock.slept, [])

    def test_daily_cap_denies_then_resets_next_day(self):
        for _ in range(3):
            self.assertTrue(self.acquire().ok)
        d = self.acquire()
        self.assertFalse(d.ok)
        self.assertEqual(d.reason, "daily-cap")
        self.clock.t = MIDNIGHT + 1
        self.assertTrue(self.acquire().ok)

    def test_429_starts_a_cooldown_until_utc_midnight(self):
        self.acquire()
        ig_throttle.record(self.env, http_status=429, now=self.clock.now)
        d = self.acquire()
        self.assertFalse(d.ok)
        self.assertEqual(d.reason, "cooldown")
        st = ig_throttle.status(self.env, now=self.clock.now)
        self.assertEqual(st["state"], "cooldown")
        self.assertEqual(st["until_epoch"], MIDNIGHT)
        self.clock.t = MIDNIGHT + 1
        self.assertTrue(self.acquire().ok)

    def test_challenge_text_starts_a_cooldown(self):
        for text in ("checkpoint_required", "Please wait: challenge_required", "automated behavior detected"):
            os.remove(self.env["HIMMEL_IG_THROTTLE_STATE"]) if os.path.exists(self.env["HIMMEL_IG_THROTTLE_STATE"]) else None
            ig_throttle.record(self.env, text=text, now=self.clock.now)
            self.assertEqual(ig_throttle.status(self.env, now=self.clock.now)["state"], "cooldown", text)

    def test_plain_login_wall_is_not_a_cooldown(self):
        ig_throttle.record(self.env, http_status=200, text="login required", ok=False, now=self.clock.now)
        self.assertEqual(ig_throttle.status(self.env, now=self.clock.now)["state"], "ok")

    def test_failures_back_off_exponentially_and_success_resets(self):
        ig_throttle.record(self.env, ok=False, now=self.clock.now)
        self.assertEqual(self.acquire().ok, True)
        self.assertEqual(self.clock.slept, [60.0])
        ig_throttle.record(self.env, ok=False, now=self.clock.now)
        ig_throttle.record(self.env, ok=False, now=self.clock.now)
        self.clock.slept.clear()
        self.env["HIMMEL_IG_DAILY_CAP"] = "99"
        self.assertTrue(self.acquire().ok)
        self.assertEqual(self.clock.slept, [240.0])  # 60 * 2**(3-1)
        ig_throttle.record(self.env, ok=True, now=self.clock.now)
        self.clock.slept.clear()
        self.acquire()
        self.assertEqual(self.clock.slept, [30.0])  # back to the plain gap

    def test_backoff_longer_than_the_wait_ceiling_is_denied_not_slept(self):
        for _ in range(6):
            ig_throttle.record(self.env, ok=False, now=self.clock.now)
        d = self.acquire()
        self.assertFalse(d.ok)
        self.assertEqual(d.reason, "backoff")
        self.assertEqual(self.clock.slept, [])

    def test_no_sleep_env_zeroes_the_gap(self):
        self.env["IG_MEDIA_NO_SLEEP"] = "1"
        self.acquire()
        self.acquire()
        self.assertEqual(self.clock.slept, [])

    def test_state_file_has_the_documented_shape(self):
        self.acquire()
        data = json.loads(Path(self.env["HIMMEL_IG_THROTTLE_STATE"]).read_text())
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["day"], "2026-10-04")
        self.assertEqual(data["count"], 1)

    def test_a_lock_that_stays_held_denies_and_is_not_stolen(self):
        lock = Path(self.env["HIMMEL_IG_THROTTLE_STATE"] + ".lock")
        lock.write_text("")
        with mock.patch.object(ig_throttle.time, "sleep"):
            d = self.acquire()
        self.assertFalse(d.ok)
        self.assertEqual(d.reason, "lock-busy")
        self.assertTrue(lock.exists())   # another caller's lock is left alone
        self.assertFalse(Path(self.env["HIMMEL_IG_THROTTLE_STATE"]).exists())

    def test_a_cooldown_recorded_while_we_sleep_stops_the_request(self):
        self.acquire()

        def sleep_then_429(s):
            self.clock.sleep(s)
            ig_throttle.record(self.env, http_status=429, now=self.clock.now)

        d = ig_throttle.acquire(self.env, now=self.clock.now, sleep=sleep_then_429, rng=lambda a, b: 0.0)
        self.assertFalse(d.ok)
        self.assertEqual(d.reason, "http-429")

    def test_non_finite_knobs_fall_back_to_the_default(self):
        for bad in ("nan", "inf", "-inf"):
            cfg = ig_throttle.config({"HIMMEL_IG_DAILY_CAP": bad, "HIMMEL_IG_MIN_GAP_S": bad})
            self.assertEqual(cfg["cap"], 30)
            self.assertEqual(cfg["gap"], 45)


@unittest.skipUnless(NODE, "node not on PATH")
class CrossLanguageTests(unittest.TestCase):
    """Python and node callers must spend ONE budget (the state file)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = dict(os.environ)
        self.env.update({
            "HIMMEL_IG_THROTTLE_STATE": os.path.join(self.tmp, "ig.json"),
            "HIMMEL_IG_MIN_GAP_S": "0",
            "HIMMEL_IG_JITTER_S": "0",
            "HIMMEL_IG_DAILY_CAP": "2",
        })

    def node(self, *args):
        return subprocess.run([NODE, str(TOOLS / "lib" / "ig-throttle.mjs"), *args],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def py(self, *args):
        return subprocess.run([sys.executable, str(TOOLS / "lib" / "ig_throttle.py"), *args],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def test_daily_cap_is_shared_across_languages(self):
        self.assertEqual(self.py("acquire").returncode, 0)
        self.assertEqual(self.node("acquire").returncode, 0)
        r = self.py("acquire")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(json.loads(r.stdout)["reason"], "daily-cap")
        r = self.node("acquire")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)

    def test_a_python_recorded_429_stops_the_node_caller(self):
        self.assertEqual(self.py("record", "--http-status", "429").returncode, 0)
        r = self.node("acquire")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(json.loads(r.stdout)["reason"], "cooldown")
        st = json.loads(self.node("status").stdout)
        self.assertEqual(st["state"], "cooldown")

    def test_a_node_recorded_challenge_stops_the_python_caller(self):
        self.assertEqual(self.node("record", "--text", "checkpoint_required").returncode, 0)
        r = self.py("acquire")
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(json.loads(r.stdout)["reason"], "cooldown")


if __name__ == "__main__":
    unittest.main()
