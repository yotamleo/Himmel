# Testing — the non-guessable suite invocations

Load-on-need reference behind the REFERENCE INDEX pointer in CLAUDE.md. None
of the invocations below are discoverable by guessing the "obvious" command —
each one has a wired reason (a per-suite cwd rule, a quiet reporter, a runner
that both runs suites and reports the plan) — so this doc states them once,
here, rather than re-deriving them per session.

## Shell suites

`bash scripts/ci/run-shell-tests.sh` runs the full shell-test corpus. It is
the same entrypoint CI's `shell-unit` job runs, matrixed over
`ubuntu-latest` (the required, gating leg on every push/PR) plus
`windows-latest` and `macos-latest` (advisory-only, `continue-on-error`,
added on the nightly `schedule` or a `force_all_os` dispatch). Running the
full corpus is slow and noisy — run it in a subagent rather than foregrounding
it in an interactive session.

`bash scripts/ci/run-shell-tests.sh --list [scan-root]` prints the run/skip
plan without executing anything — use it to check what a change would trigger
before committing to the long run.

## Lanes suite

```
node --test --test-reporter=dot "scripts/lanes/tests/**/*.test.mjs"
```

## Bun suites — per-suite cwd rule

Bun suites are not interchangeable on cwd. `scripts/luna-vitals` resolves
paths relative to its own directory, so it must run from there:

```
cd scripts/luna-vitals && bun test --dots
```

`scripts/telegram` resolves its fixtures repo-root-relative instead, so
running it the same way — `cd scripts/telegram && bun test` — fails every
wired case with an ENOENT that looks like a broken import, not a cwd bug. Run
it from the repo root instead, and never `cd scripts/telegram &&` first:

```
bun test scripts/telegram --dots
```

The reproduction of the telegram failure mode lives in
[`environment-gotchas.md`](environment-gotchas.md#the-bun-test-cwd-is-per-suite-scriptstelegram-runs-from-the-repo-root).

## Quiet reporters are deliberate

`--dots` and `--test-reporter=dot` are chosen, not an oversight: a noisy
default reporter buries the PASS/FAIL summary line in per-case output and
costs extra tail/grep round-trips to recover it.

## What counts as CI evidence

Public CI runs the suite jobs on every PR, so a green **`shell-unit`**
check-run **is** evidence a suite actually ran. The **`Mergeable`** check-run
is not: it lints only the commit message and PR title (see
[`operator-conventions.md`](../operator-conventions.md)) — never cite it as
evidence of CI health, review convergence, or suite results.
