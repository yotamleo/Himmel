// LIMITATION - PID recycling: this probe only ever DOWNGRADES an active job from
// running -> dead. The OS can reassign a dead job's pid to an unrelated process,
// in which case that recycled pid answers "alive" and masks the dead job as
// running until the next state write corrects the record. We accept this: the
// alternative (treating recycled pids as dead) would false-kill live jobs.
export function isPidAlive(pid: number): boolean {
  if (!Number.isFinite(pid) || pid <= 0) return false;
  if (process.platform === "win32") {
    try {
      const r = Bun.spawnSync(["tasklist", "/FI", `PID eq ${pid}`], { stdout: "pipe", stderr: "pipe", env: { ...process.env, MSYS_NO_PATHCONV: "1" } });
      const out = r.stdout.toString();
      return r.exitCode === 0 && out.includes(String(pid)) && !out.includes("No tasks");
    } catch (e) {
      // A persistent tasklist spawn failure would silently mark EVERY job dead;
      // surface it so the operator can see liveness is degraded, not truthful.
      console.error(`fleet-control: tasklist liveness probe failed for pid ${pid}: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    }
  }
  try { process.kill(pid, 0); return true; } catch { return false; }
}
