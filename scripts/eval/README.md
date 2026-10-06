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

```
bash scripts/eval/lane-quality/run.sh run --lane native --model claude-haiku-4-5-20251001 --reps 3 --max-usd 3
bash scripts/eval/lane-quality/run.sh table ~/.himmel/eval/lane-quality/<run-id>
bash scripts/eval/lane-quality/run.sh calibration ~/.himmel/eval/lane-quality/<run-id> --judge2-model sonnet --max-usd 1
```
