// HIMMEL-3219: hermetic tests for the /proc quiet-run orphan scan. The "proc
// root" is a temp tree of real files and symlinks, so the scan exercises real
// readdir/readlink/readFile semantics without touching the live /proc.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { scanQuietRunOrphans } from "./quiet-run-orphans";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "quiet-run-orphans-")); });
afterEach(() => { rmSync(root, { recursive: true, force: true }); });

const LOG = "/tmp/quiet-run-suite-20260829-101500-4242.log";
const O_RDONLY = "0100000";
const O_WRONLY = "0100001";
const O_RDWR = "0100002";

type Fd = { n: number; target: string; flags: string };
type Proc = { comm: string; ppid: number; args: string[]; fds?: Fd[] };

// /proc/<pid>/stat is `pid (comm) S ppid ...`; comm may itself contain spaces
// and parens, which is what the parser must survive.
function addProc(pid: number, p: Proc): void {
  const dir = join(root, String(pid));
  mkdirSync(join(dir, "fd"), { recursive: true });
  mkdirSync(join(dir, "fdinfo"), { recursive: true });
  writeFileSync(join(dir, "stat"), `${pid} (${p.comm}) S ${p.ppid} ${pid} ${pid} 0 -1 4194560 100 0 0 0 1 1 0 0 20 0 1 0 12345 1000 100 18446744073709551615\n`);
  writeFileSync(join(dir, "cmdline"), p.args.join("\0") + "\0");
  for (const fd of p.fds ?? []) {
    symlinkSync(fd.target, join(dir, "fd", String(fd.n)));
    writeFileSync(join(dir, "fdinfo", String(fd.n)), `pos:\t0\nflags:\t${fd.flags}\nmnt_id:\t28\n`);
  }
}

const wrapper = (ppid: number): Proc => ({
  comm: "bash",
  ppid,
  args: ["bash", "scripts/quiet-run.sh", "suite", "--", "bash", "scripts/test-a.sh"],
});

test("wrapper reparented to pid 1 counts as an orphaned suite", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(100, wrapper(1));
  expect(scanQuietRunOrphans(root)).toEqual({ suite: 1, tail: 0 });
});

test("wrapper reparented to a systemd --user subreaper counts too", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(900, { comm: "systemd", ppid: 1, args: ["/usr/lib/systemd/systemd", "--user"] });
  addProc(100, wrapper(900));
  expect(scanQuietRunOrphans(root).suite).toBe(1);
});

test("wrapper still owned by a live session is not an orphan", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(50, { comm: "claude", ppid: 1, args: ["claude"] });
  addProc(60, { comm: "bash", ppid: 50, args: ["bash"] });
  addProc(100, wrapper(60));
  expect(scanQuietRunOrphans(root)).toEqual({ suite: 0, tail: 0 });
});

test("a SIGKILLed wrapper leaves its command writing the log: counted once, not per descendant", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  // wrapper (pid 100) is dead; its command was reparented to 1.
  addProc(101, { comm: "bash", ppid: 1, args: ["bash", "scripts/test-a.sh"], fds: [{ n: 1, target: LOG, flags: O_WRONLY }] });
  addProc(102, { comm: "sleep", ppid: 101, args: ["sleep", "999"], fds: [{ n: 1, target: LOG, flags: O_WRONLY }] });
  expect(scanQuietRunOrphans(root).suite).toBe(1);
});

test("a reparented process unrelated to quiet-run is not counted", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(100, { comm: "sleep", ppid: 1, args: ["sleep", "999"] });
  addProc(101, { comm: "bash", ppid: 1, args: ["bash", "scripts/other.sh"], fds: [{ n: 1, target: "/tmp/other.log", flags: O_WRONLY }] });
  expect(scanQuietRunOrphans(root)).toEqual({ suite: 0, tail: 0 });
});

const tail = (ppid: number, args: string[] = ["tail", "-n", "+1", "-f", LOG], target = LOG): Proc => ({
  comm: "tail",
  ppid,
  args,
  fds: [{ n: 3, target, flags: O_RDONLY }],
});

test("tail -f on a quiet-run log with no writer counts as an orphaned follower", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, tail(1));
  expect(scanQuietRunOrphans(root)).toEqual({ suite: 0, tail: 1 });
});

test("a follower whose log still has a writer is not counted", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(60, { comm: "bash", ppid: 1, args: ["bash"] });
  addProc(200, tail(60));
  addProc(201, { comm: "bash", ppid: 60, args: ["bash", "scripts/test-a.sh"], fds: [{ n: 2, target: LOG, flags: O_RDWR }] });
  expect(scanQuietRunOrphans(root).tail).toBe(0);
});

test("another READER of the log is not a writer", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, tail(1));
  addProc(201, tail(1));
  expect(scanQuietRunOrphans(root).tail).toBe(2);
});

test("a follower of a deleted log has no writer", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, tail(1, undefined, `${LOG} (deleted)`));
  expect(scanQuietRunOrphans(root).tail).toBe(1);
});

test("tail shapes that are not a quiet-run follower are ignored", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, tail(1, ["tail", "-n", "20", LOG])); // no follow flag
  addProc(201, tail(1, ["tail", "-f", "/var/log/syslog"], "/var/log/syslog")); // not a quiet-run log
  expect(scanQuietRunOrphans(root).tail).toBe(0);
});

test("follow flag spellings: -F, --follow=name, and a bundled -fn", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, tail(1, ["tail", "-F", LOG]));
  addProc(201, tail(1, ["tail", "--follow=name", LOG]));
  addProc(202, tail(1, ["tail", "-fn", "5", LOG]));
  expect(scanQuietRunOrphans(root).tail).toBe(3);
});

test("tail -F retrying on a missing log holds no fd but is still an orphaned follower", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, { comm: "tail", ppid: 1, args: ["tail", "-F", LOG] }); // log unlinked: no open fd
  addProc(201, { comm: "tail", ppid: 1, args: ["tail", "--follow=name", "--retry", "/var/log/syslog"] });
  expect(scanQuietRunOrphans(root).tail).toBe(1);
});

test("a retrying follower whose log is written by a live process is not counted", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(200, { comm: "tail", ppid: 1, args: ["tail", "-F", LOG] });
  addProc(201, { comm: "bash", ppid: 60, args: ["bash", "scripts/test-a.sh"], fds: [{ n: 1, target: LOG, flags: O_WRONLY }] });
  expect(scanQuietRunOrphans(root).tail).toBe(0);
});

test("a process whose /proc entry vanished mid-scan is skipped, not fatal", () => {
  addProc(1, { comm: "systemd", ppid: 0, args: ["/sbin/init"] });
  addProc(100, wrapper(1));
  mkdirSync(join(root, "999")); // dir with no stat, as after a race with exit
  mkdirSync(join(root, "self")); // non-numeric entries are not pids
  expect(scanQuietRunOrphans(root).suite).toBe(1);
});

test("an unreadable proc root throws so the exporter can say the scan did not run", () => {
  expect(() => scanQuietRunOrphans(join(root, "does-not-exist"))).toThrow();
});
