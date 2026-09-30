// HIMMEL-1687: the lane dispatch summary states pushed / commits / worktree_clean,
// computed from git at summary time (never from the worker's own claims).
import { expect, test } from "bun:test";
import { join } from "node:path";
import { writeFileSync } from "node:fs";
import { GIT_TEST_TIMEOUT_MS, fixtureDir, initHermeticRepo, removeFixture } from "./fixture-repo";
import { composeDispatchGitState } from "./spawn-glm";

const git = (cwd: string, args: string[]) => {
  const r = Bun.spawnSync(["git", "-C", cwd, "-c", "user.email=t@t", "-c", "user.name=t", ...args], { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr.toString().trim()}`);
  return r.stdout.toString().trim();
};

// A repo with a bare origin (never the real remote) and a worker branch cut from main.
function fixture() {
  const { repo, run } = initHermeticRepo("dispatch-state-");
  const bare = fixtureDir("dispatch-state-origin-");
  git(bare, ["init", "--bare", "-b", "main"]);
  run(["remote", "add", "origin", bare]);
  run(["checkout", "-b", "worker/x"]);
  const base = git(repo, ["rev-parse", "HEAD"]);
  const commit = (name: string) => {
    writeFileSync(join(repo, name), name);
    git(repo, ["add", name]);
    git(repo, ["commit", "-m", name]);
  };
  const cleanup = () => { removeFixture(repo); removeFixture(bare); };
  return { repo, base, commit, cleanup };
}

test("2 commits, clean tree, not pushed", () => {
  const f = fixture();
  try {
    f.commit("a"); f.commit("b");
    expect(composeDispatchGitState(f.repo, "worker/x", f.base)).toEqual([
      "pushed: no (by design, parent owns push)",
      "commits: 2",
      "worktree_clean: yes",
    ]);
  } finally { f.cleanup(); }
}, GIT_TEST_TIMEOUT_MS);

test("dirty tree reports worktree_clean: no", () => {
  const f = fixture();
  try {
    f.commit("a");
    writeFileSync(join(f.repo, "untracked"), "x");
    expect(composeDispatchGitState(f.repo, "worker/x", f.base)).toContain("worktree_clean: no");
  } finally { f.cleanup(); }
}, GIT_TEST_TIMEOUT_MS);

test("zero commits reports commits: 0", () => {
  const f = fixture();
  try {
    expect(composeDispatchGitState(f.repo, "worker/x", f.base)).toContain("commits: 0");
  } finally { f.cleanup(); }
}, GIT_TEST_TIMEOUT_MS);

test("a real push is reported as pushed with the remote sha", () => {
  const f = fixture();
  try {
    f.commit("a");
    git(f.repo, ["push", "origin", "worker/x"]);
    const head = git(f.repo, ["rev-parse", "HEAD"]);
    expect(composeDispatchGitState(f.repo, "worker/x", f.base)[0]).toBe(`pushed: yes (origin/worker/x at ${head})`);
  } finally { f.cleanup(); }
}, GIT_TEST_TIMEOUT_MS);

test("an unreadable git dir reports unknown for every field", () => {
  const gone = join(fixtureDir("dispatch-state-gone-"), "nope");
  try {
    expect(composeDispatchGitState(gone, "worker/x", "0".repeat(40))).toEqual([
      "pushed: unknown",
      "commits: unknown",
      "worktree_clean: unknown",
    ]);
  } finally { removeFixture(join(gone, "..")); }
}, GIT_TEST_TIMEOUT_MS);

test("a missing base sha reports commits: unknown, not a guess", () => {
  const f = fixture();
  try {
    expect(composeDispatchGitState(f.repo, "worker/x", undefined)).toContain("commits: unknown");
  } finally { f.cleanup(); }
}, GIT_TEST_TIMEOUT_MS);
