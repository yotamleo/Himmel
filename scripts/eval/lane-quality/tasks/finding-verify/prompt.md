You are verifying two review findings. Each may be real or not. Check each one
against the code in this repository (read it, and run it where that helps); do
not fix anything.

- **F1** — `lq-work/parse-dur.sh`: `parse-dur.sh 45s` prints `2700` instead of
  `45`, because the `s` unit is scaled like minutes.
- **F2** — `scripts/eval/cache-probe.sh`: `--turns 0` is accepted silently and
  produces an empty report instead of a usage error.

Write your verdicts to `lq-work/verdicts.json`, exactly this shape:

    {"F1": {"verdict": "real", "evidence": "<path>:<line>"},
     "F2": {"verdict": "not-real", "evidence": "<path>:<line>"}}

`verdict` is `real` or `not-real`; `evidence` is the repository-relative path
and the line number of the code that decides it. The example values above are
placeholders, not answers.

Create no other file and change nothing else. Do not commit. When done, reply
with a short summary of each verdict and how you established it.
