---
description: Token-free PR merge-gate watcher — one process loops inside gh pr checks --watch --fail-fast, then verifies zero unresolved review threads, no changes-requested review, and (when CodeRabbit is armed) that its latest review is anchored to the head SHA, and returns a single exit code (0=green+resolved, 1=red, 2=cannot evaluate/no PR/usage error/indeterminate, 3=unresolved threads/changes requested/outside-diff body finding, 4=stale bot review or an incremental-silent review object), so merge-on-green costs ~zero tokens (HIMMEL-949 / HIMMEL-1181).
argument-hint: [pr-number|branch|url] [--grace <sec>] [--settle <sec>] [--threads-only] [--escalate]
---

Watch the current branch's PR merge gate without an agent poll loop. All the
waiting happens inside ONE `gh pr checks --watch --fail-fast` process (plus a
settle re-watch for late-registering check runs and a review-thread query);
the session spends tokens only on launching the script and reading its exit
code. Green means: every check passed, every PR review thread resolved, no
review requesting changes, zero outside-diff-range CodeRabbit body findings,
and — when CodeRabbit is armed (HIMMEL-1125) — the latest bot review is
anchored to the head SHA (HIMMEL-1181, B2). An unresolved CR comment, a
CHANGES_REQUESTED review, or a stale (never re-reviewed) head is a merge
blocker, same as a red check. Non-blocking nitpick/additional body findings
are surfaced in the success line, never silenced (HIMMEL-1147/1148).

Run it in a **background** Bash so work continues while checks run:

```bash
bash scripts/check-ci.sh $ARGUMENTS
```

(Bash tool with `run_in_background: true`; the completion notification
carries the exit code. Run the script BARE — never pipe it (`| tail`, `| grep`):
a pipeline's exit code is the LAST command's, so a piped run reads as exit 0
even when the gate blocked. As a backstop, every post-parse run also prints an
un-maskable final `check-ci: verdict exit=N` line on stdout (HIMMEL-974;
`--help` and usage-error exits stay clean) — trust that line over a
pipeline's exit code. With no argument it watches the
PR for the current branch; pass a PR number, branch, or URL when watching
from elsewhere.
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
  review threads remain, a review requests changes, or (when CodeRabbit is
  armed) its review body reports an outside-diff-range finding. Address each
  comment, resolve its thread (always resolve the thread when fixing a CR
  finding), then re-run.
- `4` — (when CodeRabbit is armed) either the latest bot review is anchored
  to a commit OTHER than the head SHA — the head was never re-reviewed, and
  GitHub auto-resolving threads on a later commit can mask this
  (HIMMEL-1181, B2: wait for / re-trigger a fresh review, then re-run) — or
  CodeRabbit concluded incrementally but posted no review object at the head
  while a prior head had outside-diff findings (request `@coderabbitai full
  review`, or opt in with `--escalate`). Distinct remedy from `3`: there is
  no thread to resolve here.

`CR_BOT_LOGINS` (default `coderabbitai`, a trailing `[bot]` suffix optional)
sets the review-author logins the freshness gate (`4`, stale case) treats as
the bot — for a repo whose review bot isn't CodeRabbit. `CR_PROFILE=none` /
`CR_APP=0` skip the freshness + body-findings + status gates together (see
`scripts/lib/cr-available.sh`).
