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

## Shard assignment — the duration ledger (HIMMEL-2894)

`--shard <i>/<n>` splits the corpus across CI's `shell-unit-shard` matrix. The
split is **not** round-robin: `scripts/ci/suite-durations.tsv` is a committed
`suite<TAB>seconds` ledger, and the runner packs the run list greedily
longest-first — each suite goes to whichever shard is currently lightest. The
plan is computed from the suite list alone, so every shard derives the same
partition independently with no coordination, and the union of the shards is
still exactly the unsharded run list.

- **What it is.** A snapshot of one real matrix run's per-suite wall clock,
  keyed by the suite path *exactly as the runner prints it*. It tunes balance
  only — it can never change **which** suites run.
- **A suite missing from it** is assigned the median of the rows present, so a
  new suite is packed like an average one, never dropped.
- **A row naming a suite that no longer exists** is ignored for assignment —
  it matches no eligible suite — though its duration still counts toward the
  median that unknown suites inherit.
- **Any row that does not parse** as `<suite path><TAB><non-negative integer>`
  — a comment, a blank line, a truncated line, a merge-conflict marker — is
  ignored exactly like an unknown row, row by row. Individual junk therefore
  does *not* disable bin-packing; the suites it would have covered simply take
  the median, which is the same treatment a brand-new suite gets.
- **A ledger that is missing or unreadable** makes the runner print one notice
  on stderr and fall back to round-robin. That is the runner's *only* fallback,
  and it is safe precisely because shell builtins answer it off a committed
  file with no tool involved, so every shard reaches the same verdict and the
  round-robin partition holds matrix-wide.
- **A ledger that is present but carries no parseable row** is not a fallback at
  all: it packs, every suite takes the median of nothing (floored to 1s), and a
  pack with all durations equal degenerates exactly to `i % n`. Same partition,
  different route — and it prints its own one-line notice, so a committed
  ledger that has been broken does not cost balance in silence.
- **Anything else that goes wrong refuses instead of falling back.** Shards
  decide alone, so a fallback is only exact when *every* shard takes it. A dead
  `awk` or `sort`, a full `TMPDIR`, a broken `PATH` is local to one runner, so a
  shard recovering there would run a round-robin partition while its siblings
  ran a bin-packed one: some suites twice, others on no shard at all, every
  shard still green — HIMMEL-1128's false-green class. So past that builtin
  probe there is no recovery, and no per-stage classification either. The
  correctness invariant is asked **once**, at the output: the finished plan must
  hold every eligible suite exactly once, and this shard's slice must be exactly
  the plan's rows for `i`. Whatever broke upstream surfaces there as a plan that
  is not the run list or a slice that does not match it, and the shard fails
  with `refusing to report green` on stderr — one check, one message.
- `SUITE_DURATIONS=<path>` overrides the ledger path (the shard tests use it).

**Refresh** — replay one `shell-unit-shard` matrix run's logs (all shards at
once), then replace the rows and update the `source:` line in the header:

```bash
gh run view <run-id> --log \
  | sed -nE 's/.*\[(PASS|FAIL)\] ([^ ]+) \(([0-9]+)s\).*/\2\t\3/p' \
  | sort -u
```

Refresh when the corpus has moved enough that the shard times skew; it is
bumped on demand, not maintained by CI.

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

## Plugin evals (on-demand, billed)

`claude plugin eval` runs an agent against a real Claude Code session, so
every run is a billed call against the same 5-hour/weekly bank as
interactive use (HIMMEL-128) — these suites are **on-demand only**, run via
`/plugin-eval <plugin> <suite>` (`.claude/commands/plugin-eval.md`), never
wired into CI or a cadence, and never "all suites" in one invocation. The
command bank-preflights (`scripts/plugin-eval-preflight.sh`, refusing when
`bank-preflight.sh` returns `SKIPPED-BANK`) and checks the `claude` version
floor the subcommand needs (2.1.269) before ever shelling out.

Three suites ship under HIMMEL-2931:

- `marketplace/plugins/obsidian-triage/evals/telegram-clip-basic/` — a
  Telegram-message-shaped prompt against a seeded fixture vault, graded on
  the created clip's filename and frontmatter. **Passed clean** (2026-09-12
  run, score 1) once invoked with `--scaffold` — its `case.yaml` declares
  `context.scaffold_script: fixture.sh`, which `claude plugin eval` will not
  run without that flag.
- `marketplace/plugins/obsidian-triage/evals/read-link-vault-first/` — a
  **RED control**: with the plugin, `/obsidian-triage:read-link` must read a
  seeded fixture clip and never call `WebFetch` (`tool_used: WebFetch, min: 0,
  max: 0, arm: both`); without the plugin, the same prompt has no reason to
  stay off `WebFetch`. Both arms use a fixture vault under the suite dir —
  never the real `~/Documents/luna`. **Finding (2026-09-12 run):** WITH
  passed clean (score 1, vault content surfaced, 0 WebFetch calls). WITHOUT
  scored 0.5 but *not* for the intended reason — Claude Code's slash-command
  dispatcher intercepts the unrecognized `/obsidian-triage:read-link` line and
  returns a synthetic "Unknown command" response before any model turn runs,
  so the WITHOUT arm never gets a chance to reach for `WebFetch` at all. The
  numeric delta is real but doesn't demonstrate the tool-use asymmetry this
  control is meant to probe; a slash-command-first prompt structurally cannot
  produce a meaningful no-plugin baseline under `--ablation with-without`.
- `marketplace/plugins/qmd/evals/collections-scoping/` — a natural-language
  prompt asserting the `qmd` MCP `query` tool is called with a `collections`
  scope, against a suite-wide **mock** (`evals/mocks/qmd/`, including a
  `_tools.json` describing the real tool schema so the model knows a
  `collections` parameter exists) so no run ever touches the real qmd daemon.
  Whoever next changes the `qmd` tool surface owns keeping this mock in sync.
  **Unrun (bank):** the first attempt aborted before grading (the mock lacked
  `_tools.json`, since fixed); bank hit the 85% five-hour cap before a
  corrected run could confirm the fix.

### Assumptions this round shipped on (unanswered by the operator)

1. On-demand only — no CI or API-key wiring for these suites.
2. Agent-shaped eval targets (e.g. `pr-review-toolkit-himmel`) are out of
   scope; only skill-invoked plugin surfaces are covered.
3. The qmd mock lives at `marketplace/plugins/qmd/evals/mocks/`, owned by
   whoever next changes the `qmd` tool surface.
4. No marketplace-consistency gate (checking every plugin has a suite) is
   introduced by this round.
5. The Claude Code version floor (2.1.269) is enforced inside
   `/plugin-eval`'s own preflight, not by a separate installed-version check
   elsewhere.

## What counts as CI evidence

Public CI runs the suite jobs on every PR, so a green **`shell-unit`**
check-run **is** evidence a suite actually ran. The **`Mergeable`** check-run
is not: it lints only the commit message and PR title (see
[`operator-conventions.md`](../operator-conventions.md)) — never cite it as
evidence of CI health, review convergence, or suite results.
