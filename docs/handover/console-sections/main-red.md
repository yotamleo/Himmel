# Chief section — triaging a red main run

Read on demand: the CI row of `monitors.md` names this file when a main run
completes red, and a worker's `MAIN-RED` message lands here too. A red main
blocks every merge, so classify it first, using steps 1-3 below:

- **Test-only red** (a flake, a cap timeout, a fragile case; the code under
  test is fine): quarantine the case and file its ticket at once. The fleet
  keeps merging.
- **Real blocker** (main's code is broken): HOLD merges until the fix lands.
- **Complex** (no clear class, or more than one cause): escalate to a
  higher tier, a judge or the operator.

The first cause you name has to be the right one.

The full CI and merge flow, with the quarantine and main-red rules, is in [`ci-merge-flow.md`](../../internals/ci-merge-flow.md).

**1. Name the failing case from the CI log, before naming any cause.** Take the
failed job from `gh run view <run> --json jobs`, then its log:
`gh api --allow-escape-sequences repos/<o>/<r>/actions/jobs/<job-id>/logs`
into a scratch file. The `[FAIL]` row names the suite; the case is in the lines
under it. The runner prints only the last 100 lines of a failed suite inline,
so a long suite's failing case is often cut off. The full log is in the run's
`shell-unit-failed-logs-<os>-shard<n>` artifact
(`gh run download <run> -n <artifact> -D <scratch>`). Write down the suite, the
case, the pass/fail counts, and whether its own retry passed.

**2. Reproduce where CI runs, not where you are.** Make a fresh worktree at the
red sha (`git worktree add --detach <scratch>/red <sha>`) and run that one
suite there with `bash scripts/quiet-run.sh suite -- bash <suite>`. Never
reproduce from the primary checkout inside a Claude session. That copy is the
anchor, and on the anchor `chokepoint-seam-guard.sh` compares each
registered non-internal seam a fixture sets with the claude ancestor's launch
environment; if one differs, it refuses with exit 96. An exit 96 with no seam
difference has another cause and needs its own diagnosis. On 10-23, `scripts/api-lane/test-claude-api.sh` run from the
primary checkout failed 57 of 87 cases with BANK-UNKNOWN, while CI had failed
exactly one (the bulk-call `--cancel` race). The 57 came from the chief's own
environment, not from the code.

**3. Your failing set must match CI's before you name a cause.** Same suite,
same case, same count. A local run that fails more cases, other cases, or none
is reproducing something else. Say `inconclusive` and keep looking; never
attribute the CI red to what you see locally.

**4. Then pick the class.** These are ranked by how often each reddened main
in the 30 days to 10-23:

- **Merge skew.** A whole-tree assertion suite (a registry, a tier table, a
  wiring census, a `# selector: tree-scan` suite) goes red with a "not
  registered" or "got N want M" message. Two PRs were each green, but their
  combination is not, and neither PR's impacted shards ran that suite. Find the
  PRs merged since the last green run of that job. The fix is the missing row,
  never a revert.
- **Timing under load.** The case passes on the suite's own retry or on
  rerun, has a fixed `sleep`, a fixed wait-for-N-seconds, or a fixed grace
  before `kill -9`. shell-lint's `[kill-after]` names the last shape. Fix it
  with a bounded poll on the condition itself.
- **Caller environment.** The case reads `HOME`, `HIMMEL_REPO`,
  `JIRA_PROJECT_KEY` or another variable the runner did not pin. The runner
  calls `scrub_session_env` (`scripts/lib/override-env.sh`), which removes only
  its listed Claude, harness and credential namespaces. It keeps
  `JIRA_PROJECT_KEY` and never touches `HOME`, so those still reach a suite
  unless the runner sets them. It is no substitute for pinning in the runner.
  A suite run outside the runner sees every inherited value.

**5. Only then message a worker, or dispatch one,** with the run id, the job, the
case, the class, and the exact reproduction command.
