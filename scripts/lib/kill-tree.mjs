// scripts/lib/kill-tree.mjs -- the ONE process-tree kill for the JS/TS side of
// the harness (HIMMEL-1956, consolidating HIMMEL-1835).
//
// WHY THIS FILE EXISTS: two copies of a killTree lived here (telegram/run.ts
// for the worker timeout paths, lanes/codex-bank-probe.ts for the codex
// app-server), and both carried the same defect -- the name promises a TREE
// kill but on POSIX they signalled the direct child only, so anything the
// child spawned survived. Every caller is a TIMEOUT path, so a survivor keeps
// spending a provider bank unsupervised and can hold the output pipes open,
// which means the parent's stream consumers never see EOF. Windows was never
// affected (taskkill /T walks the tree), which is why it stayed invisible on
// the operator's primary station.
//
// THE PRIMITIVE, MEASURED not assumed (bun 1.4.0, Linux 6.18 WSL2, 2026-08-20):
//
//   spawn         kill                                   grandchild
//   bare          child.kill(SIGKILL)                    SURVIVED  (pgid = the parent's)
//   detached      child.kill(SIGKILL)                    SURVIVED  (leader dies alone)
//   detached      process.kill(-pid, SIGKILL)            reaped
//   bare          process.kill(-pid, SIGKILL)            ESRCH, nothing signalled
//
// Both halves are required, and they live on opposite sides of the spawn: the
// GROUP has to exist before it can be signalled. Hence SPAWN_OWN_GROUP below,
// which every spawn site whose child may be killTree'd must spread into its
// options. This mirrors scripts/lib/proc-tree.sh, the shell-side equivalent,
// whose callers spawn under `set -m` for exactly the same reason.
//
// The bare+group row is why the group signal is safe to attempt unconditionally:
// a pgid always equals the pid of its leader, so if this pid never led a group
// there is no group to hit and the kernel answers ESRCH. It cannot land on a
// bystander.
import { spawnSync } from "node:child_process";

// Spread into spawn options so the child leads its own process group:
//   spawn(cmd, { ...SPAWN_OWN_GROUP, stdout: "pipe", ... })
// POSIX only. On Windows `detached` means a new console and a child that
// outlives its parent, buys nothing (taskkill /T already walks the tree), and
// would be a behaviour change on the one platform where this all works today.
//
// THE TRADEOFF, stated rather than discovered later: a child in its own group
// no longer receives the SIGINT a terminal delivers to the parent's foreground
// group, so on POSIX an operator Ctrl-C'ing a spawner leaves the worker running
// where it previously died along with the shell. That is the same property
// that makes the deadline kill work at all -- the group is ours to signal, so
// the stop must be explicit. Every caller here already stops explicitly on its
// deadline, and codex-bank-probe additionally reaps on SIGINT/SIGTERM/exit.
export const SPAWN_OWN_GROUP = process.platform === "win32" ? {} : { detached: true };

// killTree(pid, kill, opts) -- kill the process and everything under it.
//   pid   the direct child's pid
//   kill  signal the direct child (e.g. (s) => child.kill(s)); injected so the
//         caller's own process handle is used, which no-ops safely once the
//         child has been reaped instead of signalling a recycled pid
//   opts.exited  true when the direct child is already known to have exited
//
// Returns { ok, detail } rather than swallowing everything: a tree kill that
// silently failed is indistinguishable from one that worked, which is the
// third hole HIMMEL-1835 filed. Callers that verify the outcome another way
// (awaiting p.exited) may ignore it; callers that cannot should log detail
// when ok is false. detail can also be set WITH ok:true -- a deliberate skip
// is worth saying, but it is not a failure and must not be warned about.
export function killTree(pid, kill, opts = {}) {
  const problems = [];
  let note = "";
  if (process.platform === "win32") {
    // A Windows pid is recycled quickly, and taskkill takes a raw number --
    // once the child has exited, that number is no longer ours to aim a tree
    // kill at. The POSIX branch has no such restriction (see below), which is
    // why the skip is here and not around the whole function.
    if (opts.exited) {
      // A deliberate refusal, NOT a failure: declining to aim a tree stop at a
      // pid that is no longer ours is the correct outcome, and reporting it as
      // ok:false made every clean probe run log a WARNING that nothing had
      // gone wrong (PR #1751). Reported in detail so a caller can still say it.
      note = "skipped taskkill: the child already exited and its Windows pid may be recycled";
    } else {
      // spawnSync does NOT throw on ENOENT -- it reports the failure in
      // r.error and leaves status null. Reading only the status turned "the
      // taskkill binary is missing" into a bare `rc=null`, which names neither
      // the cause nor the fix. The try/catch stays for the exotic throw.
      let r;
      try {
        r = spawnSync("taskkill", ["/PID", String(pid), "/T", "/F"], { stdio: ["ignore", "ignore", "pipe"] });
      } catch (e) {
        problems.push(`taskkill could not be spawned: ${String(e?.message ?? e)}`);
      }
      if (r?.error) {
        problems.push(`taskkill could not be spawned: ${String(r.error.message ?? r.error)}`);
      } else if (r && r.status !== 0 && r.status !== 128) {
        // rc 128 is "no such process" -- the tree is already gone, not a failure.
        problems.push(`taskkill rc=${r.status ?? "null"}${r.stderr ? `: ${String(r.stderr).trim().slice(0, 200)}` : ""}`);
      }
    }
  } else {
    // Signal the GROUP. This stays correct after the direct child has exited,
    // which is what closes HIMMEL-1835's second hole -- a child that died on
    // its own while its descendants are still up is exactly when reaping
    // matters. The kernel keeps a pgid reserved while the group still has
    // members, so as long as there is anything here to reap, this pid still
    // names OUR group and nothing else.
    //
    // The boundary (panel codex-1), stated precisely rather than glossed: once
    // the group is EMPTY the pid is released, and a pid that is later recycled
    // BY A NEW GROUP LEADER would receive this signal. That requires the pid
    // space to wrap between the child's exit and this call, so the invariant
    // callers owe is simply not to sit on a stale pid: signal within your own
    // teardown (codex-bank-probe reaps in its finally / signal / exit
    // handlers), and cancel a deadline timer the moment the child is reaped
    // (runSession's clearTimeout-in-finally, whose comment already names this
    // recycled-pid hazard for the direct signal below -- the group signal
    // widens that same blast radius, it does not introduce it).
    try {
      process.kill(-pid, "SIGKILL");
    } catch (e) {
      if (e?.code !== "ESRCH") problems.push(`group kill failed: ${e?.code ?? String(e)}`);
    }
  }
  // The direct child last, and through the caller's own handle: it covers a
  // child spawned without SPAWN_OWN_GROUP (no group to signal) and is a no-op
  // once that handle has been reaped.
  try { kill("SIGKILL"); } catch { /* already gone */ }
  if (problems.length) return { ok: false, detail: problems.join("; ") };
  return note ? { ok: true, detail: note } : { ok: true };
}
