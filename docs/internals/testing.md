# Testing — the non-guessable suite invocations

Load-on-need reference behind the REFERENCE INDEX pointer in CLAUDE.md. None
of the invocations below are discoverable by guessing the "obvious" command —
each one has a wired reason (a per-suite cwd rule, a quiet reporter, a runner
that both runs suites and reports the plan) — so this doc states them once,
here, rather than re-deriving them per session.

## Writing or reviewing a test

Use the `test-audit` skill (`.claude/skills/test-audit/SKILL.md`, adapted from
openclaw) whenever you write, change, review or sweep a test. Before adding a
test it asks four questions, and it lists the junk patterns to reject (a
self-comparison, a source grep standing in for behaviour, a negative control
that fails for an unrelated reason). Before removing a test it requires a
candidate-evidence record. A new or repaired assertion is shown RED against the
broken subject before it goes green.

## Corpus/replay containment

Corpus/replay tests run through the sandbox runner; execution of destructive
commands is VM-only. Feeding command text to a classification hook
is not execution, but a hook or harness bug must still meet a filesystem fence.
Invoke `bash scripts/lib/sandbox-run.sh -- <command> [args...]`: Linux bubblewrap
namespaces, read-only runtime directories and worktree, fresh tmpfs HOME and
scratch, runtime IPC masks and network isolation, and address-space/CPU/process limits.
Additional immutable fixtures use repeatable `--read-only <path>` arguments;
socket/device/FIFO inputs and broad namespace paths are refused. Runtime special
nodes are masked with null-device overlays; unreadable runtime directories become
read-only empty tmpfs. A runtime scan error refuses execution, as do fixture scan
errors. There is no wholesale host-root bind: read-only socket inodes would still
permit IPC. Missing
bubblewrap, prlimit, or namespace support refuses execution, never falls back to
the host.
On Darwin, the same runner uses `sandbox-exec`: a parameterized Seatbelt
profile denies network and filesystem writes except a canonical private scratch
root (HOME and TMPDIR) and `/dev/null`. A harmless profile preflight must succeed
before the payload starts; missing `sandbox-exec` or an unusable profile returns
125, never an unconfined fallback. This backend has no Linux namespace, runtime
inode masking, tmpfs sizing or prlimit guarantee: it confines writes/network,
not reads, Mach services or aggregate resources. Destructive execution remains
VM-only. Replay creates its handover state under the backend-owned TMPDIR.
Outputs leave through stdout/stderr; writable fixtures stay inside the backend's
private scratch (tmpfs on Linux).
Each invocation checks an absent host-side canary, including non-zero exits.
The canary's execution control is only a harmless touch in a throwaway tmp dir.
The CI architecture lint enforces `guard-corpus/diff` and the destructive-command
hook suite. Other fixture/replay owners currently warn, not certify: migrate the
hook latency and stack benchmarks, sanctioned script registry fixture suite, and Codex
smoke/PowerShell replay paths before treating those as station-safe. The three
sandbox/replay/classification suites select `sandbox-exec` on macOS and missing
confinement fails the run instead of green-skipping coverage. Windows retains a
loud capability skip while its confinement backend is parked; it never runs
these payloads unsandboxed. Linux resource bounds are per process, not aggregate cgroup
limits; do not use this classification runner for stress or destructive exec.
The inode scans are preflight observations, not atomic filesystem snapshots.
Concurrent changes to mounted runtime or fixture trees are outside this runner's
containment guarantee; use an immutable VM environment for adversarial execution.

## Chokepoint fixtures and the seam guard

Every sanctioned script in `scripts/chokepoints.json` sources
`scripts/lib/chokepoint-seam-guard.sh` and exits 96 if that lib is missing.
A fixture that copies a sanctioned script into a scratch tree must therefore copy the
lib beside it, at the same relative path (`<tree>/scripts/lib/`). The guard
enforces only on the anchor checkout's own copy. A scratch copy's tree root is
never the anchor, so a fixture can still set seams per call. A suite that
drives the anchor's REAL copy with a seam set from inside a Claude session
gets exit 96 by design. Point it at a scratch copy instead.

## Shell suites

`bash scripts/ci/run-shell-tests.sh` runs the full shell-test corpus. It is
the same entrypoint CI's `shell-unit` job runs, matrixed over
`ubuntu-latest` (the required, gating leg on every push/PR). Windows is
dropped (HIMMEL-5729) and macOS runs on its own cadence workflow, so no PR, no
nightly and no manual dispatch of `ci.yml` runs a Windows or macOS shard. Running the
full corpus is slow and noisy — run it in a subagent rather than foregrounding
it in an interactive session.

To verify a branch on macOS on demand, dispatch `os-verify`:
it runs only the suites the branch impacts
against `origin/main`, on one OS.

```bash
gh workflow run os-verify.yml --ref <branch> -f os=macos -f suites=impacted
# os: macos (the only choice)      suites: impacted (default) | all
```

It is dispatch-only, never required, and its job names carry an `os-verify / `
prefix so it cannot satisfy a required check by name. GitHub Free allows 20
concurrent jobs and only 5 macOS, so keep to one OS unless the change is
OS-specific. It needs `os-verify.yml` on the default branch, and a branch
whose diff is docs-only reports `0 impacted shell suites` and passes.

### macOS runs on its own cadence, not the nightly

macOS shell-unit is `.github/workflows/macos-cadence.yml` (`CI (os:macos
cadence)`): Tuesday + Friday 05:43 UTC, the same 8-shard partition and
`SUITE_TIER_MODE=all` corpus the nightly's macOS legs had. `ci.yml` contains no
macOS job and no macOS health step, so a macOS red is a red of *that* workflow
and never of `CI` or main. It is never on `push` and never on an unlabelled PR,
and a red shard is not `continue-on-error`: it reddens the cadence run, which is
the point.

**Proving a macOS fix inside its PR: the `ci:macos` label.** A PR that fixes
macOS code (or whose brief says macOS) gets the label before `READY`; the
workflow then runs on the PR head when the label is added and on every later
push, and both its jobs are skipped on a PR without the label (after a push an unlabelled PR
lists its two `macos-cadence` checks as skipped, which use no macOS runner, so
the HIMMEL-3853 cost rule stands). A PR run
never records breakages and never uploads `macos-breakage-record`: that record
belongs to main's cadence runs.

```bash
gh pr edit <pr> --add-label ci:macos             # run the macOS suites on this PR's head
gh workflow run macos-cadence.yml --ref main     # dispatch (the file must be on the ref's default branch)
gh run list --workflow macos-cadence.yml         # its runs, apart from the nightly `CI` runs
```

**A macOS fix leg proves only its own suites (HIMMEL-7309).** A full run is 8
shards and 70-110 min, and it is red from suites unrelated to the PR. Dispatch
the PR branch with `suites` set instead: one runner runs just those suites
(`run-shell-tests.sh --only-list`) in minutes.

```bash
gh workflow run macos-cadence.yml --ref <branch> -f suites="<path/test-a.sh> <path/test-b.sh>"
```

`suites` is space-separated repo-relative `test-*.sh` paths. The run is titled
`macos-cadence suites: <paths>`, and `ready-check.sh` item 10 accepts it when
the run's log shows `[PASS] <suite>` for every named suite, however red the rest
is; a named suite that failed or never ran fails the check and is named. The
route holds only when the named suites cover every `test-*.sh` the PR changes
(an unnamed one fails the check and is named) and the PR's `macos-cadence.yml`
diff is the `suites` wiring alone; any other workflow edit still needs an
unfiltered dispatch at the head, green or red only where main already is. A
filtered run records no breakage metric
(a partial run would read the unlisted suites as fixed); empty `suites` is the
unchanged full cadence.

**Breakage metric.** Every cadence run's `summary` job records which suites are
red now that were green on the previous completed cadence run
(`scripts/ci/macos-breakage.sh`): a row in the run's job summary (both head
shas + the new breakages), and a `macos-breakage-record` artifact
(`record.json`, kept 90 days). A red run with no failed suite, or with fewer
shard reports than expected, is flagged `infra_suspect` — a shard died before
reporting, so the list is incomplete. To read it back:

```bash
bash scripts/ci/macos-breakage.sh report --repo yotamleo/Himmel --limit 12
```

It prints one line per recorded run (date, run id, head, previous head,
red/new counts, new suites) then `runs` and `new_breakages` per ISO week.

### A nightly OS red is a split slice, never a hold

macOS is verified by the cadence above (Windows is dropped); nothing else
runs it: there is no per-PR all-OS proof, and a PR is never blocked on an OS
it did not run. When the nightly goes red, or the macOS cadence goes
red:

- **The nightly files it.** A red `shell-unit` aggregator runs
  `scripts/ci/shell-extended-nightly-issue.sh`, which opens or refreshes ONE
  consolidated issue (label `shell-extended-nightly-ci`) and closes it when the
  nightly goes green. A red macOS cadence run files nothing: read the run's summary
  (new breakages) or `macos-breakage.sh report`.
- **The supervisor session splits it.** The supervisor session turns each distinct failure cluster
  into its own ticket under the epic that owns the OS-portability work,
  one slice per cluster. The slice is fixed and
  verified like any other change; it is **never** a hold on an unrelated PR.
- **Verifying a slice before the next cadence run** is optional and operator-
  requested only: the diagnostic `os-verify.yml` workflow
  dispatches the impacted suites on one OS. It is not a per-PR gate and no worker
  session dispatches it unasked.

`bash scripts/ci/run-shell-tests.sh --list [scan-root]` prints the run/skip
plan without executing anything — use it to check what a change would trigger
before committing to the long run.

`bash scripts/ci/cr-first-measure.sh` measures how many CI runs were superseded by CodeRabbit fix pushes (read-only GitHub API) and is the HIMMEL-6575 before/after baseline.

## Running a brand-new suite before its first commit

`bash scripts/quiet-run.sh suite -- bash <path>` accepts a git-tracked
`test-*.sh`, **or** an untracked one that lies inside the current worktree, so
the RED-first run of a new suite works before anything is committed:

```bash
bash scripts/quiet-run.sh suite -- bash scripts/test-new-thing.sh
```

The untracked file must be named `test-*.sh`, be a regular file (a directory or
a symlink — even one pointing inside the tree — is refused), and its physical
path (parent symlinks resolved) must sit under the worktree's top level. A
`test-*.sh` outside the worktree, a non-test name, or a missing path is refused
with rc 2, exactly as before. Spell the path as a relative, `./`-relative or
absolute path; all three resolve.

`scripts/ci/run-shell-tests.sh --impacted <base>..<head>` reads a **committed**
range, so a suite still untracked is not listed and not run by it — commit the
new suite first (or run it by the `quiet-run` form above), then the range
selects it.

## Local suite-result ledger

`quiet-run.sh suite` and `scripts/ci/run-shell-tests.sh` append one JSON row per
suite run (`ts`, `suite`, `head`, `rc`, `sec`, `station`) to
`~/.himmel/state/suite-runs.jsonl`, so local catches are countable. The append
never changes a suite's exit code and creates the directory on demand. A
fixture-marked run (`HIMMEL_TEST_FIXTURE=1`) or a GitHub Actions run writes
nothing unless `HIMMEL_SUITE_LEDGER` names a file; tests point that variable at
a temp path. `bash scripts/ci/suite-runs-summary.sh --days N` (default 7)
prints `<red>/<runs>  <suite>` for every suite with a red run in the window.

## Impacted suites — which suites a change actually reaches

`bash scripts/cr/impacted-suites.sh <base>..<head>` lists every suite
(`test-*.sh`, `*.test.mjs`/`.js`/`.ts`) whose text references the basename of a
file the range changed (or `/<name>` for a slash command or skill) — including a
suite in another directory, which "sweep the owning directory" never reaches
(PR #2261: `uninstall-plugins.sh` changed, `scripts/test-uninstall.sh` drove it
and never ran). `run-shell-tests.sh --impacted <base>..<head>` runs just the
shell ones; `--impacted` is refused (rc 2) on a range that does not resolve, and
a suite outside the scan root is named, not silently dropped. `/pr-check` step
3.6 requires one `PASS` / `SKIP <reason>` / `BLOCKED <denial>` verdict per listed
suite (`impacted-suites.sh --check`); a missing one (rc 1) or a `BLOCKED` one (rc 3 — accounted for, but the suite did not run) leaves the row NOT clean.
References include conservative basename matching through shell sources and
repo JS/Python imports; generic intermediate shell execute/read chains are not
followed.

For operator-run dependency measurements, run
`python3 -I scripts/cr/suite-file-resolver.py --repo . --ref HEAD` to emit the
independent committed-tree oracle (exact edges, directory probes and unresolved
roots). It does not read selector maps and remains a lexical, incomplete oracle;
in particular, it does not resolve Python import/from statements transitively.
Run `bash scripts/cr/test-suite-file-selection.sh --property` explicitly when
measuring the full selector/oracle superset property. This expensive diagnostic
is not the default or a CI gate; timeouts and missing queries remain failures,
not a complete green result. To compare every completed query from a saved
measurement against pinned main, run
`bash scripts/cr/test-suite-file-selection.sh --monotonic <measurement-log>`.
The bare suite command runs fast fixture controls only. Full-property completion,
residual investigation and nightly disposition are deferred to HIMMEL-7096.

A `*.test.mjs`/`.js`/`.ts` suite's own runner is not "whatever's installed" —
`impacted-suites.sh --runner <path>` prints the exact CI-equivalent command,
read off `.github/workflows/ci.yml` (a node:test suite can pass
under `node --test` and fail under a guessed `bun test` on an unrelated bun fs
quirk, a false red no code change caused). It refuses non-zero, naming the
path, rather than guessing, when the path has no mapping; `--runner-check` is
a drift guard that fails when ci.yml runs a JS/TS test invocation the map does
not yet cover.

### PR shards run the impacted suites

On a pull request to `main`, the 8 `shell-unit-shard` jobs run only the
suites that the **base** commit's `scripts/ci/impacted-selection.sh` selects
for the PR's diff (`SUITE_IMPACTED_FROM_BASE`). The script decides on the
**full** sweep in any of these cases:

- the PR changes a path listed in `scripts/ci/ci-trust-paths.txt` (ci.yml,
  the runner, the selector, the trust list itself). Under
  `SUITE_TIER_MODE=pr` only the selector-integrity paths count: ci.yml,
  `run-shell-tests.sh`, `impacted-selection.sh`, `ci-trust-paths.txt`,
  `suite-tiers.tsv`, `scripts/cr/impacted-*` and `anchor-handoff.sh`. Any other
  trust path gets the impacted suites plus the PR tier;
- the base is not on `origin/main`;
- the base predates the script;
- the selector errors.

A docs-only PR's shards exit 0 with nothing to run, so all required contexts
still report. Each shard writes a manifest (`SUITE_MANIFEST`) that holds the
selection header and every suite's fate. The `shell-unit` aggregator
recomputes the selection and runs `scripts/ci/shard-manifest-verify.sh`, which
fails the check when:

- a manifest is missing;
- a manifest comes from another sha, or its header differs from the
  selection;
- a selected suite never ran;
- a suite ran twice;
- a suite ran red;
- a suite was left unrun.

The main cron sweep (`ci.yml` has no push-to-main trigger),
a `workflow_dispatch` and the nightly schedule keep the full sweep. When a main
sweep is red, the aggregator records
`impacted-suites.sh --selector-miss` rows in the step summary and in the
`selector-miss-ledger` artifact. Those rows name the red suites a PR run
would not have selected.

### PR jobs and shard setup skip when the diff cannot reach them

On a pull request a `plan` job (HIMMEL-5524) runs the **base** commit's
`scripts/ci/pr-plan.sh` over `scripts/ci/pr-job-gates.txt` (`<group> <ERE>`
lines) and exposes one `run_<group>` output per gated job. A gated job skips only
when the plan succeeded and said `false`; a plan that failed, printed nothing
or did not run (push, schedule, dispatch) runs everything. The plan is all-true
on a trust-path diff, a path no group names, a base without the gates file or
any selector error, or an invalid regex in the list. `secret-scan` is not
gated (a secret can land in any file). Only path-pure jobs are gated; a job
whose suites glob or run files no gate group can enumerate (`lint`,
`bun-suites`, `claude-startup`, `lanes-and-trust-suites`) is ungated and runs on
every PR (trust judges j2543e, j2543g), pinned by test-pr-plan.sh A8. Gated
non-matrix jobs (`git-env-scrub`, ...) skip at job level, which reports
`skipped`. The matrix required job `node-suites` and `security-scan` always
start and skip their steps, so every required name still reports.

The short checks (`secret-scan`, `bwk-awk-mktemp-gate`, `unchecked-mktemp-range`,
`commit-lint`, `jira-cli-smoke`, `claude-startup`, `guardrail-matrices`,
`doc-invariants`) run as step groups of one job, `ci-quick` (HIMMEL-5675). A
gated group skips its own steps. Each old job name stays as a sentinel. It
carries the required context. It is skipped (green) when ci-quick reports its
group as `pass`, or when the run was cancelled (`!cancelled()`: eight runners
would only paint a dead run red). Otherwise it runs `exit 1`. That includes a
timed-out or skipped ci-quick, and a failed shared step. A red group fails only
its own sentinel. `scripts/ci/test-ci-quick.sh` pins the shape.

In each `shell-unit-shard`, `scripts/ci/shard-has-work.sh` asks
`run-shell-tests.sh --list` whether the shard has anything to run under the
same selection env and skips the apt/bun/ffmpeg/gitleaks/pre-commit setup when
it has not. The run step and manifest upload stay unconditional, so the
aggregator's manifest verification is unchanged.

On a pull request the plan also sizes the matrix (HIMMEL-5556).
`scripts/ci/plan-shards.sh` costs each selected suite from
`scripts/ci/suite-durations.tsv`. A suite missing from the ledger costs the
median. It packs the suites longest-first and picks the fewest shards (at most 8) whose
slowest shard stays under max(600 s, the 8-shard makespan). The shard total
reaches the run step's `--shard i/N` and the aggregator's `--shards`. Push and
nightly have no plan and keep 8 shards. If the `--list` fails, the plan falls
back to the per-shard `shard-has-work.sh` probes at 8. Each shard runs through
`scripts/ci/home-canary.sh`, so the honeytoken-HOME leak check shares the shard
plan and needs no matrix of its own.

## A failed suite is retried once; a pass on retry is a FLAKE

`run-shell-tests.sh` re-runs a failed suite once, alone. Passing on the retry
is a **FLAKE**: neither PASS nor FAIL, counted and listed in the summary, and
appended to a jsonl ledger (suite, case lines, sha, run id, timestamp,
repo id). On GitHub Actions a flake is also a `::warning` and a step-summary
section; the ledger is uploaded with the failure logs.

- A second flake of one suite inside `SUITE_FLAKE_WINDOW_DAYS` (default 7)
  prints a "file a ticket" line. The repeat check matches the suite **and** the
  repo id, so another repo's row never counts.
- A suite that fails both attempts is a real FAIL and keeps both logs.
- A suite whose header carries `# no-retry` is never retried, and a suite the
  watchdog killed at its cap is never retried either.
- The supervisor session tick prints `flakes=<rows>/<suites>@<top-suite>*<k>` and the board
  shows the same rows when this repo's ledger took a row since the supervisor session lock
  started; `scripts/observability/suite-flake-summary.sh --format
  detail` lists each row.

## Scan roots — what the corpus covers

The default scan root is `scripts` (a scoped run: `run-shell-tests.sh scripts/hooks`).
CI's shards pass root **`.`**, the whole-repo run: `scripts/`, `templates/` and
`marketplace/`. `.` is an include list, not a blind walk of the checkout (a local
run would otherwise also collect every `.claude/worktrees/*` copy), so a **new
top-level tree that gains a `test-*.sh` must be added to the list** in
`run-shell-tests.sh` — `test-run-shell-tests.sh` Case 23c fails on that drift. Paths
are repo-root-relative (`marketplace/plugins/...`), the key form the ledger and the
suite tables use. A `.` run takes the **same lock as a `scripts` run**, so the two
refuse to overlap rather than run the same trees twice.

The obsidian-triage suites need `js-yaml`/`playwright` from `tools/node_modules`;
CI installs them with `marketplace/plugins/obsidian-triage/tools/ensure-deps.sh` before
the shards, and locally run that once (it exits non-zero on any npm/network failure).
Suites that fail under the runner are quarantined on `SKIP_LIST` with a ticket ID — never silently.
The CI and merge flow, including when to quarantine and when main-red holds the fleet, is in [`ci-merge-flow.md`](ci-merge-flow.md).

**A `SKIP_LIST` suite is "uncovered", never "CI verifies".** CI does
not run it, so a PR or handover that cites CI as its evidence is citing nothing.
Look it up instead of recalling it: `bash scripts/handover/suite-coverage.sh
<suite>...` parses `run-shell-tests.sh` (SKIP_LIST, the `extended` tier table and
the per-suite cap function) and answers per suite — runs in PR CI / nightly only
(extended tier) / not run in CI (SKIP_LIST) / superseded by its `--only` wrappers
(e.g. `test-arm-resume.sh` → `test-arm-resume-fast.sh` per PR and
`test-arm-resume-1879.sh` nightly at a 1700 s cap). Nothing in that answer is
hand-copied, so it cannot drift from the runner.

## Shard assignment — the duration ledger

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
  shard still green — the false-green class. So past that builtin
  probe there is no recovery, and no per-stage classification either. The
  correctness invariant is asked **once**, at the output: the finished plan must
  hold every eligible suite exactly once, and this shard's slice must be exactly
  the plan's rows for `i`. Whatever broke upstream surfaces there as a plan that
  is not the run list or a slice that does not match it, and the shard fails
  with `refusing to report green` on stderr — one check, one message. The same
  check also asks whether the join actually finished (the pipeline's own exit
  status) and whether it read the whole ledger (bytes consumed against
  `wc -c`), since a clean short read can still produce a complete plan over
  partially loaded durations and pass the completeness half alone.
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
[`environment-gotchas.md`](environment-gotchas.md#the-bun-test-cwd-is-per-suite--scriptstelegram-runs-from-the-repo-root).

## Quiet reporters are deliberate

`--dots` and `--test-reporter=dot` are chosen, not an oversight: a noisy
default reporter buries the PASS/FAIL summary line in per-case output and
costs extra tail/grep round-trips to recover it.

## Plugin evals (on-demand, billed)

`claude plugin eval` runs an agent against a real Claude Code session, so
every run is a billed call against the same 5-hour/weekly subscription usage budget as
interactive use — these suites are **on-demand only**, run via
`/plugin-eval <plugin> <suite>` (`.claude/commands/plugin-eval.md`), never
wired into CI or a cadence, and never "all suites" in one invocation. The
command preflights the usage budget (`scripts/plugin-eval-preflight.sh`, refusing when
`bank-preflight.sh` returns `SKIPPED-BANK`) and checks the `claude` version
floor the subcommand needs (2.1.269) before ever shelling out.

Three suites ship:

- `marketplace/plugins/obsidian-triage/evals/telegram-clip-basic/` — a
  Telegram-message-shaped prompt against a seeded fixture vault, graded on
  the created clip's filename and frontmatter. **Passed clean** (2026-09-12
  run, score 1) once invoked with `--scaffold` — its `case.yaml` declares
  `context.scaffold_script: fixture.sh`, which `claude plugin eval` will not
  run without that flag.
- `marketplace/plugins/obsidian-triage/evals/read-link-vault-first/` — a
  **RED control**: with the plugin, reading the seeded fixture clip must never
  call `WebFetch` (`tool_used: WebFetch, min: 0, max: 0, arm: both`); without
  the plugin, the same prompt has no reason to stay off `WebFetch`. Both arms
  use a fixture vault under the suite dir — never the real
  `~/Documents/luna`. **`prompt.md` is natural language, not a leading
  `/obsidian-triage:read-link` line** — a literal slash command
  made Claude Code's dispatcher intercept the unrecognized command in the
  WITHOUT arm and return a synthetic "Unknown command" response before any
  model turn ran, so that arm never got a chance to reach for `WebFetch` at
  all. **Re-verified (2026-09-12):** WITH scored 1.00 clean (3/3
  runs, vault content surfaced, 0 WebFetch calls). WITHOUT scored 0.67 (2/3
  runs still found the fixture content directly via the generically-granted
  `Bash`/`Grep`/`Read` tools without calling `WebFetch`, since the prompt
  necessarily names the `./vault-fixture` path so the WITH arm's lookup CLI
  can find it; 1/3 runs failed for the intended reason — `WebFetch called 1x`
  and `vault-content-surfaced: pattern not found`). The dispatcher gap is
  fixed (every run now reaches a real model turn); the WITHOUT arm no longer
  fails deterministically because a no-plugin agent can sometimes replicate
  the vault-first behavior by hand with the same generic tools — a residual
  limitation of this suite design, not the dispatcher bug this round fixed.
- `marketplace/plugins/qmd/evals/collections-scoping/` — a natural-language
  prompt asserting the `qmd` MCP `query` tool is called with a `collections`
  scope, against a suite-wide **mock** (`evals/mocks/qmd/`, including a
  `_tools.json` describing the real tool schema so the model knows a
  `collections` parameter exists) so no run ever touches the real qmd server.
  Whoever next changes the `qmd` tool surface owns keeping this mock in sync.
  **Passed clean** (2026-09-12 run, score 1.00, 3/3 runs, $0.39) after two
  fixes: the mock initially lacked `_tools.json` (since fixed), and the
  grader's `input_match` regex (`"collections"[\s\S]*"himmel"`) would also
  pass a call whose `collections` array held extra collections, or was empty
  with "himmel" appearing elsewhere in the JSON-stringified input — tightened
  to `"collections":\s*\[\s*"himmel"\s*\]` to assert the scope is exactly
  `["himmel"]`. **Hardened further:** every WITH-only run makes
  **2** calls to `mcp__plugin_qmd_qmd__query` (the mock's `query` tool takes
  one query string, so the model issues its lex- and vec-style sub-queries as
  two separate calls) — the original `scoped-query` grader's `min: 1` only
  proved one of the two was in scope and never checked the other. A
  `graders/no-out-of-scope-query.md` grader now asserts `min: 0, max: 0` on
  any call whose full input does *not* contain `collections` scoped to
  exactly `["himmel"]`
  (`^(?!.*"collections":\s*\[\s*"himmel"\s*\]).*$`), so a genuinely
  out-of-scope call — including one that omits `collections` entirely, which
  an earlier `"collections":`-substring form of this regex missed (review round 1)
  — fails the run regardless of how many in-scope calls also happened. A
  `max: 1` on `scoped-query` itself was tried and reverted — re-verified
  (2026-09-12) against the real 2-calls-per-run behavior, it produced a false
  failure (`called 2x, expected 1..1`) even though both calls were correctly
  scoped (`no-out-of-scope-query` passed 0x violations across all 3 runs) —
  bounding the *count* of in-scope calls is the wrong lever when a legitimate
  turn makes more than one of them; asserting zero out-of-scope calls is not.

### Assumptions this round shipped on (unanswered by the operator)

1. On-demand only — no CI or API-key wiring for these suites.
2. Agent-shaped eval targets (e.g. a review agent) are out of
   scope; only skill-invoked plugin surfaces are covered.
3. The qmd mock lives at `marketplace/plugins/qmd/evals/mocks/`, owned by
   whoever next changes the `qmd` tool surface.
4. No marketplace-consistency gate (checking every plugin has a suite) is
   introduced by this round.
5. The Claude Code version floor (2.1.269) is enforced inside
   `/plugin-eval`'s own preflight, not by a separate installed-version check
   elsewhere.

## `test-ws5-invariants.sh` and renames

T13(b) is **not** rename-blind: its corpus is one full-tree
`git diff "$BASE...HEAD"` (since #776/#777), so rename pairing applies — a
pure `git mv` passes, a rename that also adds a trigger line still fails. The
earlier false positive came from a per-file pathspec that has been replaced.
The residual is T15: its new-script list is `--diff-filter=A` limited to
`scripts/`, so a rename from OUTSIDE `scripts/` reads as an addition — but T15
is advisory (`WARN`, never a CI gate). Read the assertion, then decide.

### T13(b) marker-only exemption

A read-only process lookup naming a daemon (`pgrep -f 'claude daemon run'`,
`pkill -0 -f '...'`, `ps ... | grep '...'`) is not a daemon start — it reads
`/proc`, nothing else. A first version of this gate tried a lexical carve-out
keyed on the line's command matching one of those lookup shapes with no
chaining, no command/process substitution and no backslash continuation, and
every fix closed one bypass while adversarial review kept finding the next —
ending in a Critical: a shell function or `alias` literally named
`pgrep`/`pkill`/`ps`/`grep`, SHADOWING the real command, while `daemon` sat on
the *call* line rather than the definition line the anchor was checking. A
per-line lexical scanner cannot tell a real `pgrep(1)` invocation from an
identifier spelled the same way, so the carve-out was **removed entirely**
rather than patched again (standing rule: stop adding arms, simplify).

The **only** exemption is now a trailing same-line `# t13b-ok: <reason>` (or
`// t13b-ok: <reason>` for JS/TS), which exempts that one line from T13(b)
only (not T13(a), not T12/T14/T15) — the general escape hatch so a real
read-only lookup does not need its own gate PR. It is hardened: the marker
must open with exactly `# t13b-ok: ` (or `// t13b-ok: `) — one space after
`#`/`//` and at least one after the colon (`#t13b-ok:`, `#  t13b-ok:` and
`# t13b-ok:x` do not exempt; extra spaces after the colon are tolerated,
ending up inside the trimmed reason).

**Real trailing comment, not raw text.** The marker is now
recognized by a minimal quote/brace-depth scan of the shipped line (no full
tokenizer), not by a text search — `index(t, "# t13b-ok: ")` was the whole
trust boundary once #1094 made the marker the only exemption, and a marker
spelled anywhere in the line's text used to exempt it. The scan tracks
single/double/backtick quoting, `${…}`/`$(…)` substitution nesting, and a
leading `/* … */` block comment, and only recognizes a `#`/`//` as a real
comment-open when it sits outside all of those. `#` opens a marker only on a
sh/code-kind line, only at word start (column 1 or preceded by whitespace —
mid-word `foo#…` and an escaped `\#…` do not count); `//` opens one only on a
js-kind line (`.js`/`.ts`/`.mjs`/`.cjs`). `//` never counts in a shell kind and
`#` never counts in a js/ts kind. The first real comment-open on the line is
final either way — once it opens, nothing later on the line can be a
different "start," whether or not it spells the exact marker text. This
rejects a marker hidden in a single- or double-quoted string, a `bash -c`
argument, a herestring, a `${x#…}` parameter expansion, a `$(…)` command
substitution, and a `//` inside a `.sh` file — read the `smg-*` cases in
`scripts/parity/test-t13b-daemon-prose.sh` for the full shape list. A
semicolon-chained command genuinely *after* a real marker on the same line
(`cmd & # t13b-ok: reason ; other-cmd &`) is not a bypass: everything past a
real `#` is a shell comment, so the chained command is unreachable code on
that line, and the gate still leaves it exempted (`mk-mid-chain`/
`sh-t13b-ok-mid-chain-comment-eats-rest`) — which line shapes the marker may
exempt is unchanged and out of scope here.

**Nested substitution inside a quote, and escaped word boundaries
(round 3).** The scan is a proper stack, not a single quote/depth
pair: `${…}`/`$(…)`/backtick can open one level DEEPER while already inside a
single, double or backtick quote (`x="$(echo " # t13b-ok: reason")"` and its
backtick and `${y:-"…"}` forms no longer desync — the inner `"` closes the
INNER frame it opened, not the outer string), and the same nesting applies to
a JS template literal's `` `${…}` `` interpolation. A backslash escape at top
level also marks the character it protects — including a literal space — as
not a real word boundary, so `foo\ # t13b-ok: reason` does not read that `#`
as a comment open either (an escaped space does not end the preceding shell
word). Nesting deeper than 20 stack frames, or left unbalanced at end of
line, **fails closed**: the marker does not count, never the other direction.
Read the `smg-nested-*`/`smg-js-nested-template`/
`smg-escaped-space-word-boundary` cases in
`scripts/parity/test-t13b-daemon-prose.sh`. Two narrower quote-desync gaps
(a JS regex literal, and bash's `$'…\'…'` ANSI-C escaped-quote form) are
unrelated to this nesting fix, remain open, and are tracked as known gaps —
flagged with a `ponytail:` at `find_marker_start()` and pinned
by the `sh-t13b-known-gap-*` fixture rows.

Once a real comment opens, the reason after it must be non-trivial: at least
8 characters trimmed AND containing a run of 3 or more letters, which kills an
all-digit reason (`12345678`), punctuation padding (`.......x`) and
whitespace padding, and a second `# t13b-ok: `/`// t13b-ok: ` nested inside
the reason does not extend the exemption. The marker never reaches a
different line (same-line only, unchanged). `ponytail:` in the gate: the
scan is per diff line with no concept of "this line is heredoc BODY
content, not a shell comment" — a heredoc body line whose text happens to
spell a real-looking marker still exempts a daemon shape on that same line;
out of scope, a known gap. Read cases in
`scripts/parity/test-t13b-daemon-prose.sh`. Precedent for a narrow, literal
carve-out done right: the exact-token `systemctl daemon-reload`
strip, which this gate keeps unchanged.

## VM round trip — station-only, never CI

`VBOXMANAGE_PATH=/usr/bin/VBoxManage bash scripts/vm/provenance-roundtrip.sh <ref> [--expect-red] [--purge-state] [--profile core|all]`
runs a seeded install/uninstall round trip on a real VirtualBox clone. The
details are in `docs/setup/vms.md`. The script is deliberately not named
`test-*.sh`, so neither `run-shell-tests.sh` nor the impacted map ever picks it
up. Its header carries the `STATION-ONLY: never run from CI` marker. CI runs
only the hermetic `scripts/vm/test-provenance-roundtrip-dry.sh` and
`scripts/vm/test-assert-provenance.sh`. The latter feeds `assert-provenance.sh`
and `seed-provenance.sh` synthetic inventories through the `INV_BASE` seam (no
VM, linux-only) and covers the state, stub, `claude.json` and
armed-crontab checks.

## What counts as CI evidence

Public CI runs the suite jobs on every PR, so a green **`shell-unit`**
check-run **is** evidence a suite actually ran. The **`Mergeable`** check-run
is not: it lints only the commit message and PR title (see
[`operator-conventions.md`](../operator-conventions.md)) — never cite it as
evidence of CI health, review convergence, or suite results.

Three readings that look like evidence and are not:

- `gh pr checks <pr> | awk '$2!="pass"'` mislabels greens as reds because
  check names contain spaces — read `gh pr view --json statusCheckRollup`.
- A branch-green `CI-DONE` event names a **commit**, not a PR; it says that
  head passed, nothing about the PR's current head.
- `gh api rate_limit` can report thousands of REST calls left while GraphQL is
  exhausted — read the `X-Ratelimit-*` headers of a real call
  (`gh api -i graphql …`), not the summary endpoint.

## Superseded runs under a runner backlog

With a large fleet the org's 60-job cap backs up, and superseded
`pull_request` runs sit in workflow-level `queued` — the concurrency group does
not cancel them, and `codeowner-review-gate` / `workflow_dispatch` runs are
outside it by design. From a supervisor session, `bash scripts/ci/cancel-superseded-runs.sh
--dry-run [--branch <b>]` lists, and without `--dry-run` cancels, every live CI
or codeowner-review-gate run on an open PR's branch whose head is not that PR's
current head. It never touches a run at the current head, main, a
schedule run or a branch with no open PR, and any `gh` read error cancels
nothing and exits 1. Cancels land ~20 s later. Run from a supervisor session only; not yet wired
into `tick.sh` or the worker session ship flow.

Never rerun a CI run by hand or in a loop: the concurrency group `ci-pr-<N>`
makes a rerun the newest request, so rerunning a run at a superseded sha cancels
the PR's real head run (HIMMEL-6509). `bash scripts/ci/rerun-head.sh [--dry-run] <pr>`
reruns (`--failed`) the newest CI run at the PR's current head only when it is
completed as failure, cancelled or timed_out; a live or green head run, a run
already rerun once and no run at the head are no-ops. `--run <id>` does the same
but exits 1 when that run's sha is not its PR's current head. `--fleet` runs
`cancel-superseded-runs.sh` first, then the `<pr>` pass over every open PR: the
one sanctioned recovery after an outage. Every run read precedes the first
rerun, so a `gh` error there reruns nothing and exits 1. The PR heads are
re-read right before each rerun and a moved head is skipped, so a fleet pass can
rerun some PRs and still exit 1 when a later re-read or rerun fails.

`bash scripts/lint/flag-parity.sh [--staged | --changed A..B] --baseline scripts/lint/flag-parity-baseline.tsv` fails a doc (`docs/`, `.claude/commands/`, skills) that writes a `--flag` after a tracked script name the script lacks; `--advisory` lists usage-header flags no doc mentions. Pre-commit and the CI lint job run it; ~0.3 s on the full tree.
