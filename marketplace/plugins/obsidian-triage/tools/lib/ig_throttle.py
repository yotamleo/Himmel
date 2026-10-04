#!/usr/bin/env python3
"""Shared Instagram request throttle (HIMMEL-4306).

Every Instagram request runs on the operator's logged-in account, so request
volume and cadence put that account at risk. Every caller (Python and node)
spends ONE budget kept in one state file, ~/.himmel/state/instagram-throttle.json
(override: HIMMEL_IG_THROTTLE_STATE):

  * minimum spacing + jitter between any two requests,
  * a daily cap (UTC day),
  * exponential backoff after a failed request,
  * a cooldown to the end of the UTC day after a 429 or a checkpoint/challenge
    response - nothing is sent until it lifts.

The node twin is ig-throttle.mjs; it reads and writes the same file in the same
shape, so keep the two in step.

API:  acquire(env) -> Decision(ok, reason, waited)   before EVERY request
      record(env, http_status=, text=, ok=)           after the response
      status(env) -> {"state": "ok"|"cooldown", ...}  read-only
CLI:  ig_throttle.py acquire|record|status   (exit 3 = denied, JSON on stdout)

Knobs (env): HIMMEL_IG_MIN_GAP_S (45), HIMMEL_IG_JITTER_S (30),
HIMMEL_IG_DAILY_CAP (30), HIMMEL_IG_BACKOFF_BASE_S (60). IG_MEDIA_NO_SLEEP zeroes
the gap and jitter (the test seam the ig-media suites already use).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import random
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

# A request that was refused, challenged or rate limited. A plain login wall is
# deliberately absent: an expired cookie is an auth problem, not a block.
BLOCK_RE = re.compile(
    r"\b429\b|too many requests|rate.?limit|challenge|checkpoint|automated behavio"
    r"|temporarily blocked|feedback_required|spam",
    re.IGNORECASE,
)
MAX_WAIT_S = 900  # a backoff longer than this is denied, not slept through
BACKOFF_CAP_S = 3600
LOCK_STALE_S = 30


@dataclass(frozen=True)
class Decision:
    ok: bool
    reason: str = ""
    waited: float = 0.0


def _num(env, key: str, default: float) -> float:
    try:
        value = float(env.get(key, default))
    except (TypeError, ValueError):
        return float(default)
    return value if math.isfinite(value) else float(default)


def config(env) -> dict:
    no_sleep = bool(env.get("IG_MEDIA_NO_SLEEP"))
    return {
        "gap": 0.0 if no_sleep else _num(env, "HIMMEL_IG_MIN_GAP_S", 45),
        "jitter": 0.0 if no_sleep else _num(env, "HIMMEL_IG_JITTER_S", 30),
        "cap": int(_num(env, "HIMMEL_IG_DAILY_CAP", 30)),
        "backoff_base": 0.0 if no_sleep else _num(env, "HIMMEL_IG_BACKOFF_BASE_S", 60),
    }


def state_path(env) -> Path:
    override = (env.get("HIMMEL_IG_THROTTLE_STATE") or "").strip()
    if override:
        return Path(override)
    home = env.get("HOME") or env.get("USERPROFILE") or str(Path.home())
    return Path(home) / ".himmel" / "state" / "instagram-throttle.json"


def _day(now: float) -> str:
    return datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")


def _next_midnight(now: float) -> float:
    d = datetime.fromtimestamp(now, timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    return (d + timedelta(days=1)).timestamp()


@contextlib.contextmanager
def _locked(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock = path.with_name(path.name + ".lock")
    held = False
    for _ in range(100):
        try:
            os.close(os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
            held = True
            break
        except FileExistsError:
            try:
                if time.time() - lock.stat().st_mtime > LOCK_STALE_S:
                    lock.unlink()
                    continue
            except OSError:
                pass
            time.sleep(0.1)
    try:
        yield held
    finally:
        if held:   # never unlink a lock another caller owns
            try:
                lock.unlink()
            except OSError:
                pass


def _load(path: Path, now: float) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    if data.get("day") != _day(now):
        data["day"] = _day(now)
        data["count"] = 0
    for key in ("count", "failures"):
        if not isinstance(data.get(key), int):
            data[key] = 0
    for key in ("last_slot", "backoff_until", "cooldown_until"):
        if not isinstance(data.get(key), (int, float)):
            data[key] = 0
    data["version"] = 1
    return data


def _save(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def acquire(env=None, *, now=time.time, sleep=time.sleep, rng=random.uniform, wait=True) -> Decision:
    """Reserve the next request slot and wait for it. Denied = send nothing.
    wait=False never sleeps: a slot that is not free right now is denied as
    "spacing" and reserves nothing (the health probe uses this)."""
    env = os.environ if env is None else env
    cfg, path = config(env), state_path(env)
    with _locked(path) as held:
        if not held:
            return Decision(False, "lock-busy")   # fail closed: never share a budget unlocked
        t = now()
        data = _load(path, t)
        if data["cooldown_until"] > t:
            return Decision(False, "cooldown")
        if data["count"] >= cfg["cap"]:
            return Decision(False, "daily-cap")
        if data["backoff_until"] - t > MAX_WAIT_S:
            return Decision(False, "backoff")
        spaced = data["last_slot"] + cfg["gap"] + (rng(0, cfg["jitter"]) if cfg["jitter"] else 0)
        slot = max(t, spaced, data["backoff_until"])
        if slot > t and not wait:
            return Decision(False, "spacing")
        data["last_slot"] = slot
        data["count"] += 1
        _save(path, data)
    delay = max(0.0, slot - t)
    if delay > 0:
        sleep(delay)
        # A 429/challenge recorded by another caller while we slept still stops us.
        again = status(env, now=now)
        if again["state"] == "cooldown" and again["reason"] != "daily-cap":
            return Decision(False, again["reason"], delay)
    return Decision(True, "", delay)


def record(env=None, *, http_status=None, text="", ok=None, now=time.time) -> None:
    """Report the outcome of a request. A 429 or challenge starts the day's
    cooldown; any other failure doubles the backoff; a success resets it."""
    env = os.environ if env is None else env
    cfg, path = config(env), state_path(env)
    with _locked(path):
        t = now()
        data = _load(path, t)
        if http_status == 429 or BLOCK_RE.search(text or ""):
            data["cooldown_until"] = _next_midnight(t)
            data["cooldown_reason"] = "http-429" if http_status == 429 else "challenge"
        elif ok is False or (http_status is not None and not 200 <= http_status < 300):
            data["failures"] += 1
            data["backoff_until"] = t + min(BACKOFF_CAP_S, cfg["backoff_base"] * 2 ** (data["failures"] - 1))
        elif ok or http_status is not None:
            data["failures"] = 0
            data["backoff_until"] = 0
        _save(path, data)


def status(env=None, *, now=time.time) -> dict:
    env = os.environ if env is None else env
    cfg, path = config(env), state_path(env)
    t = now()
    data = _load(path, t)
    out = {"state": "ok", "count": data["count"], "cap": cfg["cap"]}
    if data["cooldown_until"] > t:
        out.update(state="cooldown", until_epoch=data["cooldown_until"],
                   reason=data.get("cooldown_reason", "cooldown"))
    elif data["count"] >= cfg["cap"]:
        out.update(state="cooldown", until_epoch=_next_midnight(t), reason="daily-cap")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("op", choices=("acquire", "record", "status"))
    ap.add_argument("--http-status", type=int)
    ap.add_argument("--text", default="")
    ap.add_argument("--ok", choices=("true", "false"))
    args = ap.parse_args(argv)
    if args.op == "acquire":
        d = acquire()
        print(json.dumps({"ok": d.ok, "reason": d.reason, "waited": d.waited}))
        return 0 if d.ok else 3
    if args.op == "record":
        record(http_status=args.http_status, text=args.text,
               ok=None if args.ok is None else args.ok == "true")
        return 0
    print(json.dumps(status()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
