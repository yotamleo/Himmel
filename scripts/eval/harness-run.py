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
  * starts CMD in its own process group, and while it waits reaps every
    orphan reparented to it, so exited grandchildren do not pile up as zombies;
  * on the deadline: SIGTERM to that group, then SIGKILL after --kill-after
    seconds (the `timeout -s TERM --kill-after` contract), exit 124;
  * on SIGTERM / SIGINT / SIGHUP to the runner itself: the same TERM, then
    --kill-after grace, exit 128+signal;
  * whatever happened -- deadline, signal or a normal exit -- it then SIGKILLs
    every process still descended from the runner, escaped sessions included,
    and reaps them before it exits. Otherwise it exits with CMD's own code;
  * if a descendant is still alive after the sweep gives up, it names the
    survivors on stderr and exits 125, whatever CMD returned.

Only this runner's own descendants are ever signalled. Linux only (prctl,
/proc). Wrap the WHOLE harness, not each hook call: a harness's per-call
killpg still runs, and this is the backstop for when the harness dies.
ponytail: a SIGKILL to the runner itself cannot be caught, so its descendants
are then orphaned as before. Give the outer tool call a longer timeout than
--deadline + --kill-after; a cgroup scope is the upgrade if that still bites.
"""
import ctypes
import math
import os
import signal
import subprocess
import sys
import time

PR_SET_CHILD_SUBREAPER = 36
SWEEP_SECS = 10
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
    if deadline is None or not cmd:
        return None
    # nan / inf would silently disable the deadline.
    if not (math.isfinite(deadline) and math.isfinite(kill_after)):
        return None
    if deadline <= 0 or kill_after < 0:
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
    """SIGKILL the child's group (if known) and every remaining descendant;
    reap them. Returns the descendants still alive when it gives up."""
    if pgid is not None:
        signal_group(pgid, signal.SIGKILL)
    swept = set()
    end = time.monotonic() + SWEEP_SECS
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
    reap()
    left = descendants(os.getpid())
    swept.discard(pgid)
    if swept:
        print("harness-run: swept %d leftover descendant(s)" % len(swept), file=sys.stderr)
    return left


def wait_child(child, timeout):
    """child.wait(timeout) that also reaps every orphan reparented to this
    subreaper while it waits; otherwise each one stays a zombie (holding a pid)
    until the final sweep. Raises subprocess.TimeoutExpired like child.wait."""
    end = time.monotonic() + timeout
    while child.returncode is None:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return child.wait()
        if pid == child.pid:
            child.returncode = os.waitstatus_to_exitcode(status)
            break
        # Checked on every poll: a steady stream of exiting orphans must not
        # starve the deadline.
        if time.monotonic() >= end:
            raise subprocess.TimeoutExpired(child.args, timeout)
        if pid == 0:
            time.sleep(0.05)
    return child.returncode


def stop_group(child, kill_after):
    """SIGTERM the child's group, then give it up to kill_after seconds."""
    signal_group(child.pid, signal.SIGTERM)
    try:
        wait_child(child, kill_after)
    except subprocess.TimeoutExpired:
        pass


def ignore_signals():
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)


def supervise(cmd, deadline, kill_after, box):
    """Run CMD to its exit or the deadline; box receives the Popen object."""
    try:
        box.append(subprocess.Popen(cmd, start_new_session=True))
        child = box[0]
        try:
            rc = wait_child(child, deadline)
            return 128 - rc if rc < 0 else rc
        except subprocess.TimeoutExpired:
            print("harness-run: deadline %ss hit, stopping %s" % (deadline, cmd[0]), file=sys.stderr)
            stop_group(child, kill_after)
            return 124
    except Stop as stop:
        ignore_signals()
        if box:
            stop_group(box[0], kill_after)
        return 128 + stop.signum


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
    box = []
    try:
        rc = supervise(cmd, deadline, kill_after, box)
    except Stop as stop:
        rc = 128 + stop.signum
    except OSError as err:
        print("harness-run: cannot start %s: %s" % (cmd[0], err), file=sys.stderr)
        rc = 127
    finally:
        ignore_signals()
        # Sweep even when Popen never returned a child: a signal can land after
        # the fork, and the /proc walk finds that child without its pid.
        left = sweep(box[0].pid if box else None)
    if left:
        print("harness-run: %d descendant(s) survived SIGKILL: %s"
              % (len(left), " ".join(str(p) for p in left)), file=sys.stderr)
        return 125
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
