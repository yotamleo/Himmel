// HIMMEL-3219: Linux /proc scan for the two quiet-run orphan shapes that
// HimmelOrphanProcesses (codex-fleet / codex-exec-registry only) never saw on
// 2026-08-29. Pure reader: no process control, same passivity contract as the
// rest of the exporter.
//
//   suite - a `quiet-run.sh <label> -- <cmd>` wrapper, or a process writing a
//           quiet-run log, that has been REPARENTED (its owning session is
//           gone). A wrapper that dies leaves the command reparented; a
//           wrapper whose session dies is itself reparented.
//   tail  - a `tail -f` on a quiet-run log that no process holds open for
//           writing any more (caller-side follower: quiet-run.sh starts none).
//
// ponytail: "reparented" means ppid 1 or a `systemd` parent (the
// `systemd --user` subreaper is where Linux desktop sessions re-home orphans),
// so a quiet-run started on purpose from a systemd unit or a setsid/nohup
// launch is counted too — the alert's `for:` window is the only allowance.
// Writer visibility needs read access to other processes' /proc/<pid>/fd, so
// a log written by a different user reads as writer-less. Linux only: there
// is no /proc on macOS, and Windows has its own host-detectors.ps1 path.
import { readFileSync, readdirSync, readlinkSync } from "node:fs";
import { join } from "node:path";

export type QuietRunOrphanCounts = { suite: number; tail: number };

// quiet-run.sh names its log ${TMPDIR:-/tmp}/quiet-run-<label>-<ts>-<pid>.log.
// The kernel appends " (deleted)" to a readlink target whose file was unlinked.
const QUIET_RUN_LOG = /\/quiet-run-[^/]+\.log(?: \(deleted\))?$/;

type Stat = { comm: string; ppid: number };

// /proc/<pid>/stat is `pid (comm) state ppid ...`, and comm may itself contain
// spaces or parens, so anchor on the LAST `)`.
function readStat(procRoot: string, pid: string): Stat | null {
  try {
    const text = readFileSync(join(procRoot, pid, "stat"), "utf8");
    const open = text.indexOf("(");
    const close = text.lastIndexOf(")");
    if (open < 0 || close < open) return null;
    const ppid = Number(text.slice(close + 1).trim().split(/\s+/)[1]);
    return Number.isInteger(ppid) ? { comm: text.slice(open + 1, close), ppid } : null;
  } catch {
    return null; // the process exited between readdir and read
  }
}

function readArgs(procRoot: string, pid: string): string[] {
  try {
    return readFileSync(join(procRoot, pid, "cmdline"), "utf8").split("\0").filter((a) => a !== "");
  } catch {
    return [];
  }
}

function isQuietRunWrapper(args: string[]): boolean {
  return args.slice(0, 2).some((a) => a === "quiet-run.sh" || a.endsWith("/quiet-run.sh"));
}

function isFollowing(args: string[]): boolean {
  return args.slice(1).some((a) => a === "--follow" || a.startsWith("--follow=") || /^-[A-Za-z0-9]*[fF]/.test(a));
}

// Quiet-run log targets among the process's open fds, split by open mode.
function quietRunLogFds(procRoot: string, pid: string): { written: string[]; all: string[] } {
  const out = { written: [] as string[], all: [] as string[] };
  let fds: string[];
  try {
    fds = readdirSync(join(procRoot, pid, "fd"));
  } catch {
    return out; // exited, or not ours to read
  }
  for (const fd of fds) {
    let target: string;
    try {
      target = readlinkSync(join(procRoot, pid, "fd", fd));
    } catch {
      continue;
    }
    if (!QUIET_RUN_LOG.test(target)) continue;
    out.all.push(target);
    try {
      const flags = /^flags:\s*(\d+)/m.exec(readFileSync(join(procRoot, pid, "fdinfo", fd), "utf8"));
      // O_ACCMODE: 0 = read-only; 1 and 2 (write-only, read-write) hold a writer.
      if (flags && (parseInt(flags[1], 8) & 3) !== 0) out.written.push(target);
    } catch {
      // fdinfo unreadable: cannot show a writer, so leave it out
    }
  }
  return out;
}

export function scanQuietRunOrphans(procRoot = "/proc"): QuietRunOrphanCounts {
  // Throws when the root itself is unreadable: the caller must be able to say
  // "the scan did not run" rather than export a 0 it never measured.
  const pids = readdirSync(procRoot).filter((name) => /^\d+$/.test(name));
  const stats = new Map<string, Stat>();
  for (const pid of pids) {
    const stat = readStat(procRoot, pid);
    if (stat) stats.set(pid, stat);
  }

  const reparented = (stat: Stat): boolean => stat.ppid === 1 || stats.get(String(stat.ppid))?.comm === "systemd";

  let suite = 0;
  const followers: { logs: string[] }[] = [];
  for (const [pid, stat] of stats) {
    if (stat.comm === "tail") {
      const args = readArgs(procRoot, pid);
      if (!isFollowing(args)) continue;
      const logs = quietRunLogFds(procRoot, pid).all;
      if (logs.length > 0) followers.push({ logs });
      continue;
    }
    if (!reparented(stat)) continue;
    if (isQuietRunWrapper(readArgs(procRoot, pid)) || quietRunLogFds(procRoot, pid).written.length > 0) suite++;
  }

  // The whole-table fd walk only runs when a follower exists to be judged.
  let tail = 0;
  if (followers.length > 0) {
    const written = new Set<string>();
    for (const pid of stats.keys()) for (const target of quietRunLogFds(procRoot, pid).written) written.add(target);
    tail = followers.filter((f) => !f.logs.some((log) => written.has(log))).length;
  }
  return { suite, tail };
}
