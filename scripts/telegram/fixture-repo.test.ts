// scripts/telegram/fixture-repo.test.ts — the teardown contract the spawn-glm /
// spawn-claudex REAL-GIT suites rely on (HIMMEL-1888).
import { expect, test, spyOn } from "bun:test";
import { mkdirSync, mkdtempSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { GIT_TEST_TIMEOUT_MS, initHermeticRepo, makeSharedFixtureRepo, removeFixture } from "./fixture-repo";

// A repo + linked worktree this module did NOT create: the shape of an
// operator's checkout, built by hand so the registry never learns about it.
// Zero commits beyond the seed and DIRTY (one staged file) — the exact state
// HIMMEL-1888 was filed about, and the one with no recovery path.
function foreignZeroCommitWorktree(): { repo: string; wt: string } {
  const repo = mkdtempSync(join(tmpdir(), "foreign-checkout-"));
  const git = (args: string[]) => {
    const r = Bun.spawnSync(["git", ...args], { cwd: repo, stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")} failed: ${r.stderr.toString().trim()}`);
  };
  git(["init", "-b", "main"]);
  const noHooks = join(repo, "no-hooks");
  mkdirSync(noHooks, { recursive: true });
  git(["config", "core.hooksPath", noHooks]);
  git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "seed"]);
  const wt = join(repo, ".claude", "worktrees", "docs+in-progress");
  git(["worktree", "add", "-b", "docs/in-progress", wt]); // branch AT main, zero commits
  writeFileSync(join(wt, "work-in-progress.txt"), "uncommitted work that must survive\n");
  Bun.spawnSync(["git", "-C", wt, "add", "work-in-progress.txt"], { stdout: "pipe", stderr: "pipe" });
  return { repo, wt };
}

test("HIMMEL-1888: removeFixture REFUSES a zero-commit dirty worktree this run did not create — the work survives", () => {
  const { repo, wt } = foreignZeroCommitWorktree();
  const stderr = spyOn(console, "error").mockImplementation(() => {});
  try {
    // Both the worktree and its containing checkout: neither was registered,
    // so neither may be reaped, whatever their commit count looks like.
    expect(removeFixture(wt)).toBe(false);
    expect(removeFixture(repo)).toBe(false);
    expect(existsSync(join(wt, "work-in-progress.txt"))).toBe(true);
    expect(existsSync(repo)).toBe(true);
    const said = stderr.mock.calls.map((c) => String(c[0])).join("\n");
    expect(said).toContain("REFUSED to remove");
    expect(said).toContain(wt); // names the path it refused, never a silent no-op
  } finally {
    stderr.mockRestore();
    // This test's own mess, removed by this test -- deliberately NOT through
    // removeFixture (the point of the fixture is that the registry never heard
    // of it). Swallowed because a Windows handle held a moment past git's exit
    // would otherwise fail a case whose assertions already passed; the OS temp
    // cleaner gets what is left.
    try { rmSync(repo, { recursive: true, force: true }); } catch { /* swept by the OS temp cleaner */ }
  }
}, GIT_TEST_TIMEOUT_MS);

test("HIMMEL-1888: a registered fixture IS removed, and the removal is announced with its path", () => {
  const { repo } = initHermeticRepo("fixture-registered-");
  const stderr = spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(removeFixture(repo)).toBe(true);
    expect(existsSync(repo)).toBe(false);
    const said = stderr.mock.calls.map((c) => String(c[0])).join("\n");
    expect(said).toContain("removed fixture");
    expect(said).toContain(repo);
    // and the registration is spent: a second call cannot delete a path that
    // some later run might reuse for something real
    expect(removeFixture(repo)).toBe(false);
  } finally { stderr.mockRestore(); }
}, GIT_TEST_TIMEOUT_MS);

test("HIMMEL-1786: shared-dispatch fixtures are hermetic — the host's global hooks never fire inside them", () => {
  const { repo, wt, run } = makeSharedFixtureRepo("hermetic-shared-", "glm+feat-live-pr", "feat/live-pr");
  try {
    // Ratchet: without this, a global core.hooksPath (tokensave installs one)
    // backgrounds a ~30s index into every fixture `git worktree add` mints —
    // which is what held the handle that EBUSY'd cleanup and what pushed this
    // family past bun's 5s default.
    expect(run(["config", "--get", "core.hooksPath"], repo).stdout.toString().trim()).toBe(join(repo, "no-hooks"));
    expect(existsSync(wt)).toBe(true);
  } finally { removeFixture(repo); }
}, GIT_TEST_TIMEOUT_MS);
