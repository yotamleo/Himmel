# The CI and merge flow

How himmel's CI, the merge gate and a red main fit together. A chief, a worker or an
adopter reads this page instead of re-deriving the rules. Mechanism detail lives
elsewhere: the suite runner in [testing.md](testing.md), the merge gate exits in
[stuck-playbook.md](stuck-playbook.md), the worker-side rules in
`docs/handover/leg-sections/ci-red.md`.

## CI on main, and why PRs never update-branch

A PR runs `ci.yml` as a `pull_request` event, which can check out a merge ref rather than
the PR head (the `plugin-version-bump` job pins the head sha explicitly for that reason),
and some jobs run only for pull requests. Main runs `ci.yml` on a schedule, a sweep cron
roughly every 7 h plus a nightly, with a different job set, and `workflow_dispatch` for a
run on a selected ref; the completed run's `headSha` names the exact commit it covered.
There is no `push` trigger (HIMMEL-5113): per-merge runs on main
cost about 2,300 runner hours on the green ones alone and competed with PR runs for the
account's runner slots. The price is that a break on main surfaces up to a nominal 7 h
later (GitHub fires schedules late on this repo, so the real gap can reach about 11 to
12 h) and spans every merge since the previous run; the sweep prints that range and the
main-red issue names it.

Because main is verified separately, a PR does **not** have to contain the current tip of
main before it merges. Strict ("require branches to be up to date") is **off** on both the
branch protection and the `protect-main` ruleset, on purpose. Turning it on would force
every PR to update-branch and re-run a full CI round after each sibling merges, which
serialises merges and kills fleet parallelism. Do not enforce it.

The cost of that choice is a green merge can still turn main red (semantic skew between
two PRs that each passed alone, or a latent race exposed by load). That is expected
occasionally and is handled by the next section, not by tightening the gate.

## Main red after a green merge

Main-red must stay rare and be fixed fast. The merge gate backs this up:
`merge-on-green.sh` refuses (exit 22) while the newest completed `CI` run on main is red,
unless the PR is the declared fix (`Fixes-main-red:` line or a fix-GO; see the
[stuck-playbook](stuck-playbook.md)).

First classify the red, then act:

| Class | Example | Action |
|---|---|---|
| **Test only** | a flaky, racy or skewed test case; no product breakage | **Quarantine at once** (next section) with a ticket so the fleet keeps merging, then fix it ASAP, usually the same shift. |
| **Real blocker** | product breakage, a guard or invariant regression, a broken install or ship path | **HOLD the fleet.** Freeze GOs and merges until main is fixed. Dispatch the fix. |
| **Complex fix** | the cause or the fix is beyond the worker that found it | **Escalate** to a higher tier, a judge or the operator. Never leave it skipped and forgotten. |

Before acting on a red, check what it actually is:

- Read the newest `ci.yml` run on main **and its head sha**. A scheduled run at an older
  head says nothing about the current head. `gh workflow run ci.yml --ref main` only
  queues a run: wait until that run completes, then check its `headSha` and `conclusion`
  before classifying main. The merge gate ignores incomplete runs, so the earlier
  scheduled result is not the answer in the meantime.
- A PR that merged **while its own CI was red** is a different and more serious incident
  (the gate let it through): find out why before anything else.
- A worker that finds a general red it did not cause sends the chief one
  `MAIN-RED <job> <failing case> caused-by: #<pr>` (or `caused-by: unknown`); the chief
  has it fixed once, not once per worker.

## Quarantine

Quarantine is how a test-only red stops blocking the fleet without hiding.

- **Mechanism.** `SKIP_LIST` in `scripts/ci/run-shell-tests.sh` lists suites the runner
  does not run. A suite that fails only on a non-Linux host goes in `SKIP_LIST_NON_LINUX`
  instead, so Linux CI still runs it. One line per suite, full repo-relative path.
- **Tier quarantine.** A `quarantine` row in `scripts/ci/suite-tiers.tsv` keeps the suite
  running and reports a failure as `[QUARANTINE]` without failing the run, in every tier
  mode: a PR, a schedule and a dispatch run alike. The shard-manifest
  verifier records its `ran rc!=0` line as a NOTE, never as passed coverage.
- **A ticket is required.** A quarantine entry's trailing comment carries the ticket ID
  and the reason. A quarantine without a ticket is a silent skip, which is not allowed.
  `SKIP_LIST` also holds standing skips that are not quarantines: suites that need a real
  VM, a live `claude` or the hermes runtime. Their comment names what they need and
  where they are covered instead (the VM e2e, a dedicated `ci.yml` job).
- **Never silently.** A quarantined suite is "uncovered", never "CI verifies": a PR or
  handover that cites CI as evidence for a `SKIP_LIST` suite cites nothing.
  `bash scripts/handover/suite-coverage.sh <suite>...` answers per suite whether it runs
  in PR CI, only nightly, or not at all. The quarantine PR also tells the chief, so the
  fix is dispatched in the same breath.
- **Who lifts it.** The worker that fixes the ticket removes the `SKIP_LIST` entry, if any,
  and changes the suite's `quarantine` tier in `scripts/ci/suite-tiers.tsv` to a
  non-quarantine tier (the row stays: the table needs one row per tracked suite) in the
  fixing PR, so the suite runs again on that PR's own CI. The ticket is not done while the
  entry or the `quarantine` tier is still there. Phased-CI intent applies: keep `SKIP_LIST`
  minimal and justified.
- **What does not qualify.** A real bug stays red and takes the "real blocker" path.
  Quarantine is for a test, not for a product defect the test correctly caught.

## When a branch merges main in

Strict is off, so a branch merges main in only for a reason. Each reason below is a
deliberate merge commit, never a rebase and never a force-push.

1. **Real conflicts.** Git cannot merge the branch cleanly.
2. **A needed fix on main.** Your PR is red from a break it inherited and main has since
   fixed it. Merge-forward cures **only** an inherited red, never one your own change
   introduced (rule and proof script: `docs/handover/leg-sections/ci-red.md`).
3. **Proofs tied to the final head.** Evidence that must hold at the merged result (a
   gate or e2e proof pinned to a sha) is re-taken after the merge.

A sibling's plugin bump is not a reason. Plugin versions change only in the release cut,
the PR that changes the root `VERSION` file; a feature PR never changes a `plugin.json`
version, so two PRs editing one plugin from the same base both pass
`plugin-version-bump` and neither needs a merge of main. The merge-on-green recheck runs
the base-tip checker against the live base. It refuses a plugin version change outside a
release cut, and a release cut that leaves a plugin it changes at or below the base's
version, so two release cuts never ship different contents under one version.

Each merge-in costs a full round: a fresh CI run (PR median about 22 min, p90 about 36),
a CodeRabbit delta on the new range, a fresh `READY` and a fresh `GO` at the new head.
Measured 10-24: 8 of the last 40 merged PRs merged main in, and open-to-merge had a
median of 2.2 h. So do not merge main in speculatively "to be current".

## main-linux and main-macos are separate states

"Main red" means **`ci.yml` on main**, the Linux CI, and nothing else. The macOS cadence
(`macos-cadence.yml`, its own twice-weekly workflow) is tracked as its own state. A
macOS red never turns Linux CI red, never holds GOs and never makes "main green" false
for a Linux PR.

Report them side by side, never merged into one word:

```text
main-linux=<run> <sha8> <conclusion>   main-macos=<run> <sha8> <conclusion>
```

Verify the newest run and its head sha before relaying "main red" from a handoff: the
red a reader sees may be a macOS run, or a Linux run at an older head.
