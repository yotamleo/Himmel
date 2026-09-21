---
description: Token-free PR merge-gate watcher — loops gh pr checks --watch, verifies threads resolved, returns one exit code.
argument-hint: [pr-number|branch|url] [--grace <sec>] [--settle <sec>] [--max-wait <sec>] [--threads-only]
---

CodeRabbit is best effort (HIMMEL-3360): it is one reviewer among several, CI-only,
never run locally, and this script neither pauses for its status to settle nor
asks it to run again. When
armed, its commit status is read and printed as an advisory NOTE — pending,
failure, error, absent, skipped, or any state other than success is surfaced,
never a block. The merge gate stays: every check green, every PR review thread
resolved (any author, CodeRabbit included), no review requesting changes, no
outside-diff-range CodeRabbit body finding left undispositioned.

Watch the current branch's PR merge gate without an agent poll loop. All the
waiting happens inside ONE `gh pr checks --watch --fail-fast` process (plus a
settle re-watch for late-registering check runs and a review-thread query);
the session spends tokens only on launching the script and reading its exit
code. Green means: every check passed, every PR review thread resolved, no
review requesting changes, no outside-diff-range CodeRabbit body finding left
undispositioned (an exact-head ledger `deferred`/`disproved` disposition counts,
HIMMEL-3124 — see the exit-3 text below). An unresolved CR comment or a
CHANGES_REQUESTED review is a merge blocker, same as a red check.
Non-blocking nitpick/additional body findings are surfaced in the success
line, never silenced (HIMMEL-1147/1148).

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
implementation. `--max-wait <sec>` (default 900, `CHECK_CI_MAX_WAIT` env,
0 = unbounded) bounds each `gh pr checks --watch` round — CodeRabbit's own
rollup CHECK can sit "pending" long after every other check, so the watch is
supervised and stopped early once the verdict no longer depends on any
non-CodeRabbit check still pending, or at this cap, whichever comes first
(`check-ci: watch cap reached (Ns) — evaluating now`, HIMMEL-2062); a cap hit
with genuine non-CodeRabbit work still pending refuses (exit 2) rather than
certifying green over unfinished checks. This bound never depends on
CodeRabbit's own commit status settling (HIMMEL-3360). `merge-on-green.sh`
calls this script with no flags, so it inherits the same bound via
`CHECK_CI_MAX_WAIT`.)

Act on the exit code:

- `0` — checks green, all review threads resolved, and no CHANGES_REQUESTED
  review. The success line prints the certified head SHA (`… @ <sha>`). When
  CodeRabbit is armed, any status other than success prints as an advisory
  `check-ci: NOTE — CodeRabbit <state> …` line — it does not change this exit
  code. In an INTERACTIVE session with merge-on-green agreed: merge pinned to
  that exact commit — `gh pr merge <N> --squash --admin --match-head-commit <sha>`
  — so a push landing after certification aborts the merge instead of shipping
  unchecked code (this repo has no branch protection by design; the red-merge
  gate is the local pre-push hook). `--match-head-commit` pins the certified
  commit only — it is not a review-state gate; if meaningful time passed since
  exit 0, re-run /check-ci before merging (the block-unresolved-cr-merge hook,
  HIMMEL-936, independently blocks `gh pr merge` while review threads are
  unresolved). Auto/overnight mode: stop at PR-ready — merge stays an
  operator action.
- `1` — a check failed (fail-fast: returns on the first red). If it went red
  within seconds, suspect a GitHub Actions billing/permissions block rather
  than the code — check the run annotations first. Read bulky CI failure
  logs in a subagent, not the parent context.
- `64` — usage error (sysexits `EX_USAGE`, HIMMEL-3317): an unknown flag, a flag
  missing its value, a non-numeric `--grace`/`--settle`/`--max-wait`, or two PR
  selectors. **No gate ran** — do not record it as a gate result. The PR number
  is POSITIONAL (`check-ci.sh 1003`, not `--pr 1003`); the watcher bound is
  `--max-wait`, there is no `--watch`. The `check-ci: verdict exit=64` line still
  prints; only `--help` (exit 0) stays clean.
- `2` — cannot evaluate: no PR for this branch, checks never registered
  within the grace window (default 180s — pass `--grace <sec>` to widen),
  gh errored on the probe or during the watch (auth/network/cancellation —
  never reported as a red check), the thread-state query failed or returned
  a malformed page, the PR head moved during the run (the green verdict is
  bound to the watched head SHA — a concurrent push invalidates it).
  CodeRabbit's own commit status never produces this code: a failed status
  query, a paged status list, absent, pending and skipped are all advisory
  NOTEs (HIMMEL-3360). Cannot-evaluate always blocks certification even if
  the checks themselves look green — re-run.
- `3` — checks green but the review state blocks the merge: unresolved
  review threads remain, a review requests changes, or (when CodeRabbit is
  armed) its review body reports an outside-diff-range finding that has no
  ledger disposition. The body read is CodeRabbit's latest review: the one at
  this head, or — when this head carries no review (best effort, HIMMEL-3360:
  nothing waits or re-triggers) — the latest one at a prior head, and a
  finding posted there blocks exactly the same way. Address each comment,
  resolve its thread (always resolve the thread when fixing a CR finding),
  then re-run. An outside-diff finding has no thread; besides a fix (a new
  commit, so a new review), it can be cleared by an explicit disposition at
  the exact head the finding was posted at (HIMMEL-3124; the recipe names it)
  — the exit-3 message prints the `ledger-append.sh finding …
  --model coderabbit-outside` recipe — `--verdict deferred` needs a tracked
  `--deferred-to <TICKET>` AND `--reason`, `--verdict disproved` needs
  `--reason`; any severity. It never carries to a new head. A header count the
  parser cannot match to findings is exit `2` (check the PR body manually).
- `4` — retired (HIMMEL-3360): no longer emitted. CodeRabbit's status being
  absent, pending, skipped, rate-limited, or its review anchored to a
  non-head commit is no longer a distinct exit — see `0` above.

`CR_PROFILE=none` / `CR_APP=0` skip reading CodeRabbit's status + body
findings together (see `scripts/lib/cr-available.sh`).

**A repo that never armed hears nothing about CodeRabbit** — that silence is
deliberate (HIMMEL-1125: nothing was configured, so nothing is missing, and an
adopter who does not use CodeRabbit should not be told about a product they do
not have). HIMMEL-2380 carves out the single state where silence would be a
lie: `git config --local himmel.coderabbit` set to a value git cannot parse as
a boolean. `git config --bool` errors on it, the error is swallowed, and the
repo reads as unarmed — so a clone that genuinely HAS CodeRabbit silently loses
the signal gate and every subsequent green certifies a review nobody checked
for. That state, and only that state, prints a WARNING naming the fix. It does
not block: exit 0 is unchanged, because a typo in a config value must not wedge
a merge (`scripts/lib/cr-available.sh`'s `cr_app_state`).

`merge-on-green.sh` records the same answer as a `cr=armed|not-configured|disabled|broken`
field on its audit line. An unattended `ARMAUTOMERGE` chain has no operator
reading this script's output, and `gate=check-ci:0` alone cannot distinguish
"CodeRabbit reviewed this and passed" from "there is no CodeRabbit here".
