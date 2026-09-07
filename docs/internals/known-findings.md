# Known findings — the pre-panel self-review (HIMMEL-2058)

CR rounds were being spent on finding classes the repo had already adjudicated:
CodeRabbit re-taught the same five corrections thousands of times, and the critic
panel kept raising the same portability / coverage / twin-parity shapes on fresh
diffs. This page indexes the one artifact that now holds those classes and the
three places it feeds. The JSON is the source of truth; this page is the map.

## The artifact

`scripts/cr/known-findings.json` — one entry per recurring class:

| field | meaning |
|---|---|
| `id` | stable slug, cited in PR bodies and adjudication reasons (`disproved: known class <id>`) |
| `kind` | `fix` = real defect with a canonical fix · `rebuttal` = false-premise class with a canonical rebuttal · `checklist` = judgment question the self-review asks |
| `globs` | which changed files the class applies to |
| `detector` | deterministic matcher for `--diff` (added-line ERE, twin-missing, no-test-change, removed-flag-in-docs, md-fence-no-lang, hook-header-no-fail-direction); `null` = prompt-only class |
| `canonical` | the fix, or the rebuttal to paste, in one paragraph |
| `coverage` | what already enforces it structurally (shell-lint rule, `.coderabbit.yaml` instruction, hook) and the gap, with ticket ids |
| `prompt` | `true` = rendered into every diff-mode critic prompt as "already adjudicated" |
| `evidence` | `learnings_uses` (CodeRabbit export), `cr_app_finding_comments_since_2026-08-10` (hand-measured from App review comments), `ledger` (rewritten by `--refresh`: verdict split of ledger findings whose file matches `globs` — the ledger stores no finding text, so this is the file-bucket's verdict history, not the class's) |

## Where it feeds

1. **`/pr-check` step 2.8** — `bash scripts/cr/known-findings.sh --diff` (a bare
   `--diff` resolves `<default-branch>...HEAD`; pass a range to override)
   prints the checklist for the diff. Fix / verify / pre-rebut every line BEFORE
   step 3 runs a critic. Advisory (always exit 0); the runbook owns the "do not
   proceed with an unhandled item" rule. After adjudication the session prints
   `known-findings: round-1 hits = N` — the acceptance metric.
2. **Critic prompts** — `scripts/cr/critic-first-pass.sh` appends
   `known-findings.sh --prompt` (the `prompt:true` classes) after the perspective
   block in diff mode: *do not re-raise unless the code regressed; if you do, cite
   why this instance differs*. `CRITIC_KNOWN_FINDINGS=0` opts out; artifact
   (charter) mode never carries it; a missing renderer is silently empty.
3. **`/cr-learnings-refresh`** — `known-findings.sh --refresh [--learnings <csv>]`
   re-mines the ledger per class and re-imports a CodeRabbit learnings export,
   rewriting only `evidence` + `refreshed_at`, and lists the unmatched
   high-usage learnings as new-class candidates. Lean-invoke, no cadence.

`known-findings.sh --list` prints the class table; `--json` on `--diff` gives
machine output. Tests: `scripts/cr/test-known-findings.sh` (detectors on a
fixture repo, prompt/list/json shapes, refresh on a copy, usage contract) and the
HIMMEL-2058 block in `scripts/cr/test-critic-first-pass.sh` (prompt injection).

## Classes (2026-09-02 snapshot — regenerate with `--list`)

| id | kind | source | detector | title |
|---|---|---|---|---|
| `errexit-false-positive` | rebuttal | coderabbit-learning | — | errexit hazards claimed in scripts that do not (or do not relevantly) use set -e |
| `octal-leading-zero` | rebuttal | coderabbit-learning | added-line-regex | leading-zero operands: decimal in `[ ]`, octal only in arithmetic contexts |
| `handover-root-bootstrap` | rebuttal | coderabbit-learning | added-line-regex | handover-path.sh / handover_root demanded of a script that touches no handover path |
| `mktemp-no-template` | fix | coderabbit-learning | added-line-regex | bare `mktemp` / `mktemp -d` without a template (BSD/macOS portability) |
| `gnu-only-utility` | fix | cr-app-comments | added-line-regex | GNU-only command or flag in cross-platform shell (timeout, find -maxdepth, sed -i, date -d, readlink -f, grep -P, \s, hardcoded /usr/bin/cat) |
| `bash32-portability` | fix | coderabbit-learning | added-line-regex | bash 4+ construct (mapfile/readarray, declare -A, ${v,,}, \|&, &>>) |
| `ps1-twin-parity` | checklist | coderabbit-learning | twin-missing | a .sh/.ps1 twin changed without its counterpart |
| `ps1-bom-policy` | rebuttal | coderabbit-learning | — | UTF-8 BOM: required on a non-ASCII .ps1, an error on any .sh |
| `test-coverage-gap` | checklist | cr-app-comments | no-test-change | source changed, no test changed |
| `docs-flag-drift` | checklist | cr-app-comments | removed-flag-in-docs | a removed/renamed `--flag` is still documented |
| `grep-q-pipe-under-pipefail` | fix | ledger | added-line-regex | `<producer> \| grep -q` under `set -o pipefail` (early exit SIGPIPEs the producer; a negated guard inverts) |
| `jq-alternative-swallows-false` | fix | ledger | added-line-regex | jq's `//` swallows `false` as well as `null` — use has()/type for presence, not `// empty` |
| `non-ascii-bracket-expression` | fix | ledger | added-line-regex | non-ASCII literal inside a grep/sed/awk bracket expression never matches under the default locale — use an alternation |
| `md-fence-no-lang` | fix | cr-app-comments | md-fence-no-lang | fenced code block without a language tag (markdownlint MD040) |
| `hook-fail-direction` | checklist | ledger | hook-header-no-fail-direction | new hook without a stated fail-open/fail-closed direction + bypass |
| `test-fixture-stub-fidelity` | rebuttal | ledger | — | stub-fidelity / over-verification findings against a test fixture |
| `docs-prose-relitigation` | rebuttal | ledger | — | doc-wording findings that contradict the implementing script |
| `worker-worktree-plugin-profile` | fix | coderabbit-learning | — | spawn-glm/spawn-claudex: plugin-profile resolution and failure teardown target the worker worktree, never the dispatcher |
| `scheduler-task-xml-encoding` | rebuttal | ledger | — | UTF-16 / BOM claims about scheduled-task XML in the schtasks emitter family |
| `pr-check-anchor-handshake-escalation` | rebuttal | coderabbit-learning | — | PR_CHECK_ANCHOR_DELEGATED handshake called forgeable => privilege escalation |
| `cr-avail-artifact-perspective-scoping` | rebuttal | critic-panel | — | CR-ledger availability rows claimed to need artifact/perspective scoping |
| `test-setup-unchecked-vacuous-green` | checklist | cr-app-comments | — | test setup or child-process status unchecked — the suite cannot fail (vacuous green) |
| `exit-contract-drift` | checklist | cr-app-comments | — | an exit code gains a second meaning without its documented contract being updated |
| `suggestion-verdict-flow` | rebuttal | cr-app-comments | — | Suggestion findings need a verdict for the marker gate even though they never enter blocking counts — the flow is documented |

## What the 2026-08-23 measurement said (why these classes)

- CodeRabbit learnings export, 182 rows / 4,722 uses (up from 143 / 3,163 on
  2026-08-10): top 5 = 65 % of uses; errexit trio 1,786 (38 %), octal 552,
  handover-bootstrap 740 + 203 + 41, mktemp 220 (+ a contradicting 75-use entry),
  `\s` 199, PS1 BOM 91 (stale, contradicts HIMMEL-1432).
- A learning **use** is CodeRabbit applying the learning, not re-raising the
  finding. Measured on the App's own review comments (703 finding-comments on
  225 PRs since 2026-07-01; 158 on 48 PRs since 08-10), the big-usage classes
  are now nearly silent (errexit 2, octal 2, bare wait 1, rm -f 1 since 08-10 —
  half of them legitimate). What still re-raises: stale docs prose (21),
  GNU-vs-BSD portability (20), test-coverage gaps (16), fail-open/closed on
  hooks (10), markdownlint MD040/MD051 (~8), bare `mktemp -d` in new tests (6),
  .sh/.ps1 twin drift (5). Those became the `fix` / `checklist` detectors; the
  high-usage learnings became `rebuttal` prompt classes.
- Our ledger (12,522 rows, 3,667 unique findings): 62 % agreed / 21 % disproved /
  14 % deferred of the adjudicated; 38 % of unique findings carry no verdict,
  88 % of those on a head that was superseded before adjudication was recorded.
  Retired open-weight critics (kimi, qwen, gptoss, laguna) disproved at 70-90 %
  and are already off the panel; codex 23 %, codex-adv 6 %, glm 17 %,
  coderabbit 24 %. Test-fixture bucket disproves at ~29-34 %, docs at ~25 %.
- **Before-metric for NOW-19:** rounds per branch (distinct reviewed heads) —
  all branches since 2026-08-01 mean 3.24 / median 2 (n = 348); last 30 branches
  mean 2.63 / median 2, 3.9 findings per branch, 1.17 round-1 Critical+Important
  per branch. CodeRabbit App: 3.3 finding-comments per PR since 08-10.
- Of the 2026-08-10 analysis, nothing had been integrated: HIMMEL-1684 (the two
  `.coderabbit.yaml` carve-outs) is still To Do, and no ledger mining beyond
  `cr-tune`'s per-model buckets had happened. Full numbers + method in the
  handover analysis note `HIMMEL-2058-cr-learnings-analysis-2026-08-23.md`.

## What the 2026-09-02 refresh added (HIMMEL-2447)

- **The export's high-usage tail is now fully covered, and that is the finding.**
  227 rows / 4,824 uses: all 13 rows at >= 50 uses already map to an existing
  class, and the 139 unmatched rows total 323 uses between them (largest single
  row: 37). On the `/cr-learnings-refresh` threshold the correct answer was
  **zero** new classes from the CSV — the bar was not lowered to manufacture any.
- New classes came instead from a fresh measurement of the CodeRabbit App's own
  review comments: 69 comments across 60 PRs since 2026-08-20, bucketed by hand.
  What that window says still recurs: `handover-root-bootstrap` **8 raises across
  6 PRs, every one withdrawn on rebuttal** — the most-raised class in the window
  despite being the #1 learning at 1,009 uses, which is why its rebuttal now
  enumerates the four sub-shapes (transitive, REPO_ROOT, git-common-dir, blanket)
  rather than restating the rule; unchecked test setup / ignored child status (3);
  macOS-BSD portability (3); exit-contract drift (2); Suggestion adjudication (2).
- **A detector's noise is measured before it ships, not estimated.** The obvious
  broad form of `jq-alternative-swallows-false` matches 147 lines repo-wide (293
  raw `// empty` occurrences), nearly all legitimate string defaults; the narrow
  boolean-ish-field form ships instead, at 5 repo-wide hits. A detector that fires
  on every PR buries the checklist it is meant to sharpen.
- **Declined, with the reason recorded so the next refresh does not re-litigate:**
  the `<gate> | tail` return-code loss is already structurally enforced by the
  registered PreToolUse hook `block-tail-pipe-on-gates.sh` (HIMMEL-1696), so it is
  coverage, not a class; the ledger's `--set reason=` vs `--reason` trap is a
  CLI-workflow shape, not something a critic raises on a diff; `command -v` as a
  runnability probe had no App or ledger evidence in the window.
- Detectors are validated through `known-findings.sh` itself on a planted fixture,
  never a hand-rolled regex replica — a replica's escaping differs from `ere()`'s
  and produced two false alarms during this refresh. Each new detector ships with
  a bait line and the correct spelling one line below it (see
  `testdata/known-findings/README.md`); against the pre-change 19-class JSON
  exactly the six positive assertions fail (**64 ok / 6 fail**), which is the
  red-first proof. **Re-measure this pair of numbers whenever an assertion is
  added** — it is an evidence claim, not a description, and it went stale once
  during this very refresh (a sixth assertion was added while the text still
  said 63/5; the critic panel caught it at the gate re-stamp).
- **A red-first pair must be DISCRIMINATING, not merely present.** The pairs
  shipped in the first commit all passed against both a correct and a broken
  detector, because each exercised only a string both versions matched — which
  is how two detector defects reached review. The round-3 pair is the model to
  copy: bait `change1.sh:22` (`.agent_id // empty | type`) against control
  `change1.sh:15` (`(.agent_id | type) == "string"`), where flipping the one
  token under test changes the verdict. General rule + rationale: HIMMEL-2450.

Related: [`enforcement.md`](enforcement.md) (the CR gate), `/cr-tune` (per-model
tuning proposals — different question: *which critic* is miscalibrated; this
page answers *which finding class* keeps recurring), `/cr-scores`.
