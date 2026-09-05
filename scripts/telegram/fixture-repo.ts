// scripts/telegram/fixture-repo.ts -- real-git test fixtures for the
// spawn-glm / spawn-claudex suites, and the ONLY teardown those suites use.
//
// HIMMEL-1888. A teardown that decides what to delete by SHAPE ("looks
// abandoned", "zero commits", "branch is at main") cannot tell a spent fixture
// from a worktree an operator is working in: every freshly created worktree
// sits at main with zero commits until its first commit, and that state has no
// recovery path (nothing committed -> no reflog; branch deleted -> no handle;
// directory emptied -> no files). So this module never infers ownership: a
// path is removable only because THIS process created it, recorded here at
// creation time. Anything else is refused, loudly, and left alone.
//
// HIMMEL-1786. Two Windows-contention flakes in the same fixtures, fixed at the
// source rather than by widening timeouts:
//   * fixtures are HERMETIC -- the host's global core.hooksPath is switched off
//     inside the fixture repo, so the tokensave post-checkout auto-init does
//     not background a ~30s index into it (that index is what held the handle
//     that EBUSY'd cleanup and what pushed these cases past bun's 5s default);
//   * removal retries with a bounded backoff, because Windows can hold a
//     directory handle for a moment after the process that opened it exits.

import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";

// Real `git worktree add` + `branch -D` against a temp repo runs 6-16s on
// Windows, well over bun's 5000ms default, and every fixture here pays several
// git (and, in the shared-dispatch cases, bash) spawns before the first
// assertion. Pinned per-case so a loaded box produces a slow PASS rather than a
// false red -- never raised globally, which would also hide a real hang.
export const GIT_TEST_TIMEOUT_MS = 60_000;

// Bounded: the handle that blocks the first rm belongs to a process that has
// already exited, so it clears in tens of milliseconds or it is not a race at
// all. ~1s total, then give up loudly rather than stall the suite.
const RM_ATTEMPTS = 10;
const RM_BACKOFF_MS = 100;

// Normalize the trailing separator everywhere, and the CASE only on Windows,
// so a fixture cannot be "unregistered" by its own spelling. Case-folding is
// deliberately platform-gated: on a case-sensitive filesystem two paths that
// differ only in case are two different directories, and folding them would
// let a key match a directory this run never created -- the exact permission
// this module exists to withhold.
const key = (p: string) => {
  const norm = resolve(p).replace(/[\\/]+$/, "");
  return process.platform === "win32" ? norm.toLowerCase() : norm;
};

const created = new Set<string>();

// Register a directory this run created, so removeFixture may delete it.
// NOT exported (codex-1): an exported "authorize this path" call is a way to
// grant deletion of a directory nobody here made, which is the whole hazard.
// The only paths that reach it come from fixtureDir's own mkdtemp.
function registerFixture(dir: string): string {
  created.add(key(dir));
  return dir;
}

// A registered scratch directory, for a test that builds its own git state --
// the gitIsDirty / gitBranchExists probes exist to exercise git setup by hand,
// so they want the registered dir and nothing else. (The hermetic helper would
// also work: its no-hooks dir stays EMPTY, and git does not track empty
// directories, so it never shows up as dirt.)
export function fixtureDir(prefix: string): string {
  return registerFixture(mkdtempSync(join(tmpdir(), prefix)));
}

// Remove a fixture created by this run. Returns true when the path is gone.
//
// Never throws: it runs in `finally` blocks, where a throw would replace the
// assertion failure the test is actually reporting. A refusal or a stuck handle
// is reported on stderr and returned as false instead.
export function removeFixture(dir: string): boolean {
  const abs = resolve(dir);
  // Second, independent lock on a recursive delete: every fixture is minted by
  // mkdtemp under the OS temp dir, so a target outside it is wrong however it
  // came to be registered. Cheap, and this is the path the incident was about.
  const underTmp = key(abs).startsWith(key(tmpdir()) + sep);
  if (!created.has(key(dir)) || !underTmp) {
    console.error(`fixture-repo: REFUSED to remove ${abs} -- this run did not create it, or it is outside ${tmpdir()} (HIMMEL-1888: teardown removes registered fixtures only)`);
    return false;
  }
  let lastErr: unknown;
  for (let attempt = 1; attempt <= RM_ATTEMPTS; attempt++) {
    try {
      rmSync(dir, { recursive: true, force: true });
      created.delete(key(dir));
      // Loud on purpose (HIMMEL-1888 ask 3): the incident was only noticed
      // because a worker saw its files were gone -- a removal nobody printed is
      // a removal nobody can attribute.
      console.error(`fixture-repo: removed fixture ${abs}`);
      return true;
    } catch (e) {
      lastErr = e;
      Bun.sleepSync(RM_BACKOFF_MS);
    }
  }
  console.error(`fixture-repo: could NOT remove fixture ${abs} after ${RM_ATTEMPTS} attempts (${lastErr}) -- left for the OS temp cleaner`);
  return false;
}

// A throwaway repo with the HOST's global hooks switched off (see the
// hermeticity note above). `run` THROWS on a failed git command: setup errors
// must surface AS setup errors -- silently ignoring the core.hooksPath call
// would leave the test running WITHOUT the hermeticity this helper exists to
// guarantee, i.e. a false green.
export function initHermeticRepo(prefix: string): { repo: string; run: (args: string[]) => void } {
  const repo = fixtureDir(prefix);
  const run = (args: string[]) => {
    const r = Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed (rc=${r.exitCode}): ${r.stderr.toString().trim()}`);
  };
  try {
    run(["init", "-b", "main"]);
    const noHooks = join(repo, "no-hooks");
    mkdirSync(noHooks, { recursive: true });
    run(["config", "core.hooksPath", noHooks]);
    run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"]);
  } catch (e) {
    // The caller never receives `repo` when setup throws, so it cannot tear the
    // fixture down; clean up here rather than stranding a temp dir plus a live
    // registration for it.
    removeFixture(repo);
    throw e;
  }
  return { repo, run };
}

// A hermetic repo plus one linked worktree on `branch`, the shape the
// shared-dispatch (I6/I7) cases run against. `run` here RETURNS the spawn
// result rather than throwing: those tests read exit codes and stdout back out
// of git (config snapshots), so the raw result is the point.
export function makeSharedFixtureRepo(prefix: string, worktreeName: string, branch: string): {
  repo: string;
  wt: string;
  run: (args: string[], cwd: string) => ReturnType<typeof Bun.spawnSync>;
} {
  const { repo } = initHermeticRepo(prefix);
  const run = (args: string[], cwd: string) => Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  // SETUP is checked even though `run` is not: a silently failed `worktree add`
  // hands the test a path that does not exist, and the case then fails on some
  // later assertion that had nothing to do with the real problem.
  const mustRun = (args: string[], cwd: string) => {
    const r = run(args, cwd);
    if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed (rc=${r.exitCode}): ${r.stderr.toString().trim()}`);
  };
  const wt = join(repo, ".claude", "worktrees", worktreeName);
  try {
    mustRun(["remote", "add", "origin", repo], repo); // self-remote so a real push would resolve
    mustRun(["worktree", "add", "-b", branch, wt], repo);
  } catch (e) {
    removeFixture(repo); // same reason as initHermeticRepo: the caller never got `repo`
    throw e;
  }
  return { repo, wt, run };
}
