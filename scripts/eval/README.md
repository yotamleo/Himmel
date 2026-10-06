# scripts/eval

himmel's evals: each one measures one thing and writes its own output.

| Eval | Measures | Own output |
|---|---|---|
| `lane-quality/` | a lane or model on fixed tasks: acceptance, scope, judge scores, cost | `runs.jsonl` per sweep |
| `qmd-quality/` | qmd retrieval: hit@1, hit@5 and MRR per mode, plus latency | `scores.tsv`, `latency.tsv` |
| `guard-corpus/` | a hook change, base vs head, over a command corpus | `diff` stdout plus a `JSON` line |
| `scrape-bench/` | scrape providers on a fixed URL set | one JSONL row per URL |

## The eval-runs ledger (HIMMEL-4647)

Every run of these four evals also appends one row to
`~/.himmel/eval-runs.jsonl` (override: `HIMMEL_EVAL_RUNS_LEDGER`). That gives
one place to see how an eval has done across commits. The ledger is registered
as `eval-runs` in `scripts/observability/ledgers.json`.

- **Writer:** `lib/eval_runs.py`, Python stdlib only. Python evals import it and
  call `make_row` and `append_safe`; the bash evals call its CLI.
- **Schema:** the full v1 schema is in the docstring at the top of that file.
- **No model calls:** the writer never calls a model.
- **Failures:** a failed ledger write prints a warning and never changes the
  eval's own exit code.

What a row holds:

- The envelope: `v`, `ts`, `host`, `source`, `kind`.
- What was run: `run_id`, `eval`, `status`, `gitsha`, `git_dirty`, `model`,
  `lane`, `n` and `reps`.
- `config` with `confighash`. `config` holds the inputs that change what a
  score means. It never holds the git sha, so one config forms one series
  across commits.
- `metrics`: run-level numbers.
- `ci`, `ci_level` and `ci_method`: intervals, when the eval has them.
- `cases`: per-case scores, used for a paired compare.
- `artifact`: the path to the run's own output.
- `meta`: descriptive fields that are not hashed.

`status` is `ok`, `partial` (the run was cut short, for example by a budget
cap or a needs-auth URL) or `inconclusive` (the run measured nothing usable).
Only `ok` rows serve as baselines.

Tests always set `HIMMEL_EVAL_RUNS_LEDGER` to a temp path, so they never write
the live ledger.

Check a ledger: `python3 scripts/eval/lib/eval_runs.py validate <ledger>`.

## eval-compare

```
scripts/eval/eval-compare <eval> [--baseline <run-id> | --best-of N]
                                  [--ledger PATH] [--thresholds PATH]
```

The candidate is the eval's newest row. The baseline depends on the flags:

- **No flag:** the newest earlier `ok` row with the same `confighash`.
- **`--baseline ID`:** that run, whatever its config, if its status is `ok`.
- **`--best-of N`:** per metric, the best value among the last N earlier `ok`
  rows with the same config.

For each metric it prints the baseline, the candidate and the delta.

A metric regresses when it moves the wrong way past its noise band:

- **Both rows carry a CI:** the two intervals do not overlap.
- **Only one row carries a CI:** the other row's value falls outside it.
- **No CI:** the change is larger than the metric's band in
  `eval-compare.json`. That file has one table per eval, keyed by metric name
  or glob; a band is absolute (`band`) or a fraction of the baseline
  (`band_rel`).

A metric with no direction in that table is printed as `info` and never gated.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | no regression |
| 1 | regression |
| 2 | usage error |
| 3 | nothing to compare (no candidate, no baseline, a candidate whose status is not `ok`, no gated metric with a value on both sides, or a malformed ledger line after the candidate, which may be this eval's newest run); never a pass |

## lane-quality: repeats and judge calibration (HIMMEL-4648)

`run.sh run --reps N` runs the task set N times into one run dir. `table`
then shows the mean and a bootstrap 95% CI over the repeats for each task and
criterion. It counts the rows with no judge score instead of dropping them.

The ledger row carries:

- `reps`.
- A stratified bootstrap CI for each run-level metric. The repeats are
  resampled within each task.
- From 2 repeats on, per-task metrics: `<task>.judge_<criterion>`,
  `<task>.accept_frac` and `<task>.judge_missing`.

`run.sh calibration <run-dir>...` measures how far the judge can be trusted:

- **Judge vs acceptance:** the AUC and point-biserial r of each criterion
  against the hidden acceptance result (`accept_ok`), each with a bootstrap
  95% CI.
- **Judge vs judge:** with `--judge2-model` (and optionally
  `--judge2-effort`), it re-judges every stored judge packet once and reports
  quadratic weighted kappa per criterion. It reuses stored second-judge
  results, so a rerun makes no call.
- **Ledger:** it appends one `lane-quality-calibration` row unless you pass
  `--no-ledger`.

The first real multi-rep sweep is a console step. Run it on a quiet fleet: 3
repeats of the 4 tasks on one native lane. That is about 12 agent runs plus
their judge calls. For scale, one stored native haiku sweep of the 4 tasks
cost about 0.57 USD API-equivalent. Note the bank reading before and after.

```bash
bash scripts/eval/lane-quality/run.sh run --lane native --model claude-haiku-4-5-20251001 --reps 3 --max-usd 3
bash scripts/eval/lane-quality/run.sh table ~/.himmel/eval/lane-quality/<run-id>
bash scripts/eval/lane-quality/run.sh calibration ~/.himmel/eval/lane-quality/<run-id> --judge2-model sonnet --max-usd 1
```

## lane-quality: trajectory fields (HIMMEL-4651)

`lane-quality/trajectory.py` reads a run's session transcript and scores four
fields. It makes no model call and draws no bank. `run.sh` writes the fields
into each `runs.jsonl` row. The lane adapter in `lib/eval_runs.py` adds them
to the ledger row:

- `red_before_green_rate`, `denial_recovery_rate` and
  `verify_before_claim_rate`, each over the rows where the field is not null;
- `identical_denied_retries`, a sum.

A run dir written before these fields gets null metrics, and the row schema
does not change.

Terms the definitions use:

- **Test run:** a Bash call whose command runs a test file, directly or
  through an interpreter. A test file's basename is `test-*`, `test_*`,
  `*-test`, `*_test` or `*.test` with a script extension, or any `.bats`.
  A runner (`pytest`, `python3 -m pytest`, `bats`) runs the test files it
  names; one that names none, or `npm test` and the like, matches any test.
  `bash -n` is a syntax check, not a run, and so is a runner given a flag
  that only lists, counts or describes tests (`--collect-only`, `--help`,
  `--count` and the like). The command is split into commands at `&&`,
  `||`, `;`, `|`, `&` and newlines outside quotes.
- **Outcome:** a test run passed if its tool result is not an error, and
  failed if it is. A run whose exit status is masked has no outcome. It is
  masked when the command holds a pipe, `||` or `&`, or when a command
  follows the test after `;` or a newline. A failure in an `&&` chain counts
  only when every other command in the chain is setup (`cd`, `pushd`,
  `export`, `source`, `.`, `set`, `umask`), since the failure may be the
  other command's; a pass in an `&&` chain always counts.
- **Denial:** a tool result that is an error, does not start with
  `Exit code` (that is a command that ran and failed), and reads as a hook or
  permission refusal. A denied call never ran, so it is never a test run.
- **Implementation write:** a successful Write, Edit, MultiEdit or
  NotebookEdit of a file that is neither a test file nor a doc (`.md`,
  `.markdown`, `.txt`, `.rst`, `.adoc`).
- **Identical:** the same tool name and the same input, compared as
  canonical JSON.

The fields:

- **`red_before_green`:** true when a test run failed before the first
  implementation write and a test run passed after it. False when either run
  is missing, or when there was a test run but no implementation write. Null
  when there was neither a test run nor an implementation write.
- **`denial_recovery`:** the fraction of denials recovered from. A denial is
  recovered when the next call issued after its result is not identical to the
  denied call, or when no call follows. Calls sent in parallel with the denied
  one do not count as the next call. Null when there was no denial.
- **`identical_denied_retries`:** the number of calls, issued after a
  denial's result, that are identical to the denied call. They count whether
  or not they come right after it. 0 when there was no denial.
- **`verify_before_claim`:** true when every claim of passing tests in the
  final report is backed by a test run that passed after the last non-doc
  write. A claim that names test files needs a run of one of them; a runner
  run backs any claim. The report is `<stem>.report.md` when it exists, and
  otherwise the assistant text after the last tool call. A claim is a
  sentence that names tests, suites, cases, checks or a test file with a pass
  word
  (`pass`, `green`, `succeed`) and is not negated. Null when the report makes
  no such claim.

Known ceilings:

- The outcome is the exit status only; test output is not parsed.
- A respelled command (another path to the same file) counts as a changed
  approach.
- Files written through Bash (`cat >`, `sed -i`) are not seen as
  implementation writes.
- A RED caused by a syntax error in the test file still counts as a RED.
- Order is the order calls were issued. Calls sent in one parallel batch
  may finish in another order, so a write and a test run in the same batch
  are ordered as issued.
- Claim detection is a sentence-level regex, so an unusual wording can be
  missed or misread.

To re-score stored runs (read only, no model call):

```bash
python3 scripts/eval/lane-quality/trajectory.py rescore ~/.himmel/eval/lane-quality/<run-id> --transcripts ~/.claude/projects
```
