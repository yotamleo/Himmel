---
description: Token-free PR merge-gate watcher — one process loops inside gh pr checks --watch --fail-fast, then verifies zero unresolved review threads and no changes-requested review, and returns a single exit code (0=green+resolved, 1=red, 2=cannot evaluate/no PR/usage error, 3=unresolved threads or changes requested), so merge-on-green costs ~zero tokens (HIMMEL-949).
argument-hint: [pr-number|branch|url] [--grace <sec>] [--settle <sec>] [--threads-only]
---

Watch the current branch's PR merge gate without an agent poll loop. All the
waiting happens inside ONE `gh pr checks --watch --fail-fast` process (plus a
settle re-watch for late-registering check runs and a review-thread query);
the session spends tokens only on launching the script and reading its exit
code. Green means all three: every check passed, every PR review thread
resolved, and no review requesting changes — an unresolved CR comment or a
CHANGES_REQUESTED review is a merge blocker, same as a red check.

Run it in a **background** Bash so work continues while checks run:

```bash
bash scripts/check-ci.sh $ARGUMENTS
```

(Bash tool with `run_in_background: true`; the completion notification
carries the exit code. With no argument it watches the PR for the current
branch; pass a PR number, branch, or URL when watching from elsewhere.
`--settle <sec>` is the pause after the first green verdict before ONE
re-watch — it catches check runs that register late, so the first green
can't certify an incomplete check set (default 30, `--settle 0` disables,
e.g. `bash scripts/check-ci.sh 1150 --settle 60`). `--threads-only` runs
just the review-thread gate — that's how `/pr-check` step 4.8 reuses this
implementation.)

Act on the exit code:

- `0` — checks green, all review threads resolved, and no CHANGES_REQUESTED
  review. The success line prints the certified head SHA (`… @ <sha>`). In an INTERACTIVE session with
  merge-on-green agreed: merge pinned to that exact commit —
  `gh pr merge <N> --squash --admin --match-head-commit <sha>` — so a push
  landing after certification aborts the merge instead of shipping unchecked
  code (this repo has no branch protection by design; the red-merge gate is
  the local pre-push hook). `--match-head-commit` pins the certified commit
  only — it is not a review-state gate; if meaningful time passed since exit
  0, re-run /check-ci before merging (the block-unresolved-cr-merge hook,
  HIMMEL-936, independently blocks `gh pr merge` while review threads are
  unresolved). Auto/overnight mode: stop at PR-ready — merge stays an
  operator action.
- `1` — a check failed (fail-fast: returns on the first red). If it went red
  within seconds, suspect a GitHub Actions billing/permissions block rather
  than the code — check the run annotations first. Read bulky CI failure
  logs in a subagent, not the parent context.
- `2` — cannot evaluate: no PR for this branch, checks never registered
  within the grace window (default 180s — pass `--grace <sec>` to widen),
  gh errored on the probe or during the watch (auth/network/cancellation —
  never reported as a red check), the thread-state query failed or returned
  a malformed page, the PR head moved during the run (the green verdict is
  bound to the watched head SHA — a concurrent push invalidates it), or
  usage error. Cannot-evaluate always blocks certification even if the
  checks themselves look green — re-run.
- `3` — checks green but the review state blocks the merge: unresolved
  review threads remain, or a review requests changes. Address each comment,
  resolve its thread (always resolve the thread when fixing a CR finding),
  then re-run.
