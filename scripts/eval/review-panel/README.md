# review-panel recall eval (HIMMEL-4649)

How many real defects does the review panel (`scripts/cr/critic-panel.sh`, the
critic half of `/pr-check`) catch, and how often does it raise one that is not
there? The CR ledger only has agreed%, a precision proxy the PR author decides.
This eval feeds the panel frozen diffs with known injected defects and clean
twins of the same diffs, then scores what it reports against a key it never
sees.

| path | what |
|---|---|
| `fixtures/case-NN.patch` | 24 frozen one-file git diffs: 12 seeded, 12 clean twins. Ids are opaque and shuffled, so a case id says nothing about its class or its twin |
| `key/seeds.json` | the answer key: per case its twin `pair`, `kind` (seeded / clean) and `defects` (`id`, `class`, `file`, new-file `line`), plus a `canary` string |
| `score.py` | `lint` (fixture/key integrity + leak lint) and `score` (matcher, metrics, eval-runs row) |
| `run.sh` | one sweep: lint, panel per fixture, score, one ledger row |
| `test-review-panel.sh` | the suite: canned critic outputs and a stub panel, no model call |

Classes, two seeded cases each: `logic`, `quoting`, `fail-open`, `toctou`,
`test-cannot-fail`, `scope-creep` (the ledger's recurring finding classes).

## Running a sweep (console only: draws codex bank)

Every fixture is one paid panel call (the codex row, `tier: paid`), so a sweep
is 24 calls; legs never run it. From the primary checkout, after
`bash scripts/lib/bank-preflight.sh` says PROCEED and with the codex
`used_percent` noted:

```bash
bash scripts/eval/review-panel/run.sh --out ~/.himmel/eval/review-panel/2026-10-07 --no-ledger
```

Then note codex `used_percent` again and record the row with the bank cost
(re-scoring is deterministic and free):

```bash
python3 scripts/eval/review-panel/score.py score --outputs ~/.himmel/eval/review-panel/2026-10-07 --critics codex --meta-json '{"codex_used_pct_before": 41, "codex_used_pct_after": 47}'
```

The table it prints is the result; the same command re-prints it from the
stored outputs at any time. `eval-compare review-panel` compares sweeps once
`eval-compare.json` carries the `review-panel` bands (listed in the PR that
added this eval).

## What the critic sees, and what keeps the key from it

- The diff alone, on stdin, from an empty scratch dir outside any git checkout
  (`run.sh`). Outside a checkout the panel also skips its CR-ledger self-append,
  so a sweep never pollutes `.git/cr-critic-scores.jsonl`.
- `CRITIC_KNOWN_FINDINGS=0`: himmel's own dispositioned findings are not
  injected into the prompt. `CR_TRIVIALITY_OVERRIDE=full`: the triviality gate
  would otherwise skip the paid tier on these small diffs. `CR_PROFILE` is
  dropped so `--tiers` decides the panel.
- `score.py lint` (run first by `run.sh`; a failure refuses the sweep before any
  panel call) refuses a fixture that carries the key canary, the key path, or a
  hint word (`seed`, `inject`, `planted`, `defect`, `canary`), and checks every
  seed line is an added line of its own diff.
- Leak flag: a case whose panel stdout or stderr carries the canary or the key
  path is reported as `LEAK <case>`, counted in `leaked`, and the row's status
  becomes `inconclusive`.

## Matching rules

A finding is a `- [<critic>-<n>]: <text> [<file>:<line>]` bullet under
Critical / Important / Suggestions; the critic is the id's slug. Re-raise and
dropped-citation bullets are not findings. A finding hits a defect when:

1. **location**: same file, and `|line - seed line| <= 3` (`--window`); and
2. **class**: its text matches the class's keyword pattern (`CLASS_PATTERNS` in
   `score.py`), so a style remark on the seeded line is not credited.

| metric | definition |
|---|---|
| `<c>.recall` | seeded defects with a location+class hit / seeded defects scored |
| `<c>.recall_loc` | the same with location only: the upper bound, so a keyword miss shows as a gap |
| `<c>.recall_gating` | hits at Critical or Important (what the CR gate blocks on) / defects |
| `<c>.precision` | findings that hit some defect / all findings (a lower bound: a real unseeded issue counts against it) |
| `<c>.fp_rate` | clean twins with >= 1 Critical/Important finding / clean twins scored |
| `<c>.class.<cls>.recall` | recall per class, with `.n` |
| `defects`, `cases`, `unscored`, `leaked` | run totals |

`<c>` is each critic slug plus `panel` (the union of all critics). A case whose
review was not performed (no output, `REVIEW NOT PERFORMED`, a transcript
missing any of the three severity headings, or a nonzero panel exit in
`<case>.rc`) is unscored;
a critic listed as unavailable in a case's Note block is dropped from that
case's denominators only. Recall, precision and fp_rate carry Wilson 95%
intervals in the row's `ci`. n is small (12 defects, 2 per class): a per-class
number is a direction, not a measurement.

## Adding a fixture

Write the seeded diff and its clean twin as two `case-NN.patch` files with new
opaque ids, add both to `key/seeds.json` under one `pair`, and run
`python3 scripts/eval/review-panel/score.py lint`. Changing any fixture or the
key changes `config.fixture_set`, and retuning the class keywords changes
`config.class_patterns`; either starts a new eval-compare series.
