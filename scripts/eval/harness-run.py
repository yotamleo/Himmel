#!/usr/bin/env python3
"""harness-run.py -- run a judge / differential harness under a hard deadline
and leave NO descendant behind (HIMMEL-4183).

    python3 scripts/eval/harness-run.py --deadline SEC [--kill-after SEC] -- CMD [ARG...]

WHY: on 2026-10-03 eight hook copies spun at ~89 % CPU for 4-7 hours, load 150.
Their harness ran each hook with Popen(start_new_session=True) and killpg'd it on
its own timeout, but the harness itself was killed first, so every hook already
in flight sat in a session nobody owned and was reparented to the user
subreaper. `timeout(1)` and a killpg on the direct child's group cannot reach a
grandchild that called setsid; only a subreaper can.

What this runner does:
  * makes itself a child subreaper (PR_SET_CHILD_SUBREAPER), so any descendant
    orphaned under it is reparented HERE, not to systemd / init;
  * starts CMD in its own process group;
  * on the deadline: SIGTERM to that group, then SIGKILL after --kill-after
    seconds (the `timeout -s TERM --kill-after` contract), exit 124;
  * on SIGTERM / SIGINT / SIGHUP to the runner itself: the same sweep, exit
    128+signal;
  * whatever happened -- deadline, signal or a normal exit -- it then SIGKILLs
    every process still descended from the runner, escaped sessions included,
    and reaps them before it exits. Otherwise it exits with CMD's own code.

Only this runner's own descendants are ever signalled. Linux only (prctl,
/proc). Wrap the WHOLE harness, not each hook call: a harness's per-call
killpg still runs, and this is the backstop for when the harness dies.
ponytail: a SIGKILL to the runner itself cannot be caught, so its descendants
are then orphaned as before. Give the outer tool call a longer timeout than
--deadline + --kill-after; a cgroup scope is the upgrade if that still bites.
"""
import ctypes
import os
import signal
import subprocess
import sys
import time

PR_SET_CHILD_SUBREAPER = 36
USAGE = "usage: harness-run.py --deadline SEC [--kill-after SEC] -- CMD [ARG...]"


class Stop(Exception):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def on_signal(signum, _frame):
    raise Stop(signum)


def parse(argv):
    if "--" not in argv:
        return None
    opts, cmd = argv[: argv.index("--")], argv[argv.index("--") + 1 :]
    deadline, kill_after = None, 5.0
    i = 0
    try:
        while i < len(opts):
            if opts[i] == "--deadline":
                deadline = float(opts[i + 1])
            elif opts[i] == "--kill-after":
                kill_after = float(opts[i + 1])
            else:
                return None
            i += 2
    except (IndexError, ValueError):
        return None
    if deadline is None or deadline <= 0 or kill_after < 0 or not cmd:
        return None
    return deadline, kill_after, cmd


def descendants(root):
    """Every live pid below root, read from /proc/*/stat ppid fields."""
    kids = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name) as f:
                text = f.read()
        except OSError:
            continue  # exited between listdir and open
        # `pid (comm) state ppid ...` -- comm may hold spaces or parens.
        fields = text[text.rfind(")") + 2 :].split()
        if fields[0] != "Z":
            kids.setdefault(int(fields[1]), []).append(int(name))
    out, todo = [], [root]
    while todo:
        for pid in kids.get(todo.pop(), []):
            out.append(pid)
            todo.append(pid)
    return out


def signal_group(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def reap():
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


def sweep(pgid):
    """SIGKILL the child's group and every remaining descendant; reap them."""
    signal_group(pgid, signal.SIGKILL)
    swept = set()
    end = time.monotonic() + 10
    while time.monotonic() < end:
        reap()
        left = descendants(os.getpid())
        if not left:
            break
        for pid in left:
            swept.add(pid)
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        time.sleep(0.05)
    swept.discard(pgid)
    if swept:
        print("harness-run: swept %d leftover descendant(s)" % len(swept), file=sys.stderr)


def main(argv):
    parsed = parse(argv)
    if parsed is None:
        print(USAGE, file=sys.stderr)
        return 2
    deadline, kill_after, cmd = parsed
    if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        print("harness-run: prctl(PR_SET_CHILD_SUBREAPER) failed", file=sys.stderr)
        return 2
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)
    child = None
    try:
        child = subprocess.Popen(cmd, start_new_session=True)
        try:
            rc = child.wait(timeout=deadline)
            return 128 - rc if rc < 0 else rc
        except subprocess.TimeoutExpired:
            print("harness-run: deadline %ss hit, stopping %s" % (deadline, cmd[0]), file=sys.stderr)
            signal_group(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=kill_after)
            except subprocess.TimeoutExpired:
                pass
            return 124
    except Stop as stop:
        return 128 + stop.signum
    except OSError as err:
        print("harness-run: cannot start %s: %s" % (cmd[0], err), file=sys.stderr)
        return 127
    finally:
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        if child is not None:
            sweep(child.pid)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
