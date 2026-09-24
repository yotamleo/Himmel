---
name: test-audit
description: "Invoke when writing, changing, reviewing or sweeping tests: authoring gate plus audit for low-value or coupled tests."
---

> **Vendored and adapted, pinned to a commit (HIMMEL-3580).** Source:
> `openclaw/openclaw`, commit `1370643e394f956dfae2e42f43ee030b0072434b`,
> path `.agents/skills/test-audit/SKILL.md` (sha256 of the upstream file
> `01c421239797a8950fe1287f293d2e05f127e69ac457d1b9cdf9b296ac77eacd`),
> fetched 2026-09-24. License: MIT, (c) 2026 OpenClaw Foundation (`LICENSE`
> at that commit; full text in
> [`docs/third-party-licenses.md`](../../../docs/third-party-licenses.md#vendored-skill-test-audit-mit-openclaw-foundation)).
> [`CAMPAIGN.md`](CAMPAIGN.md) is copied **verbatim** from the same commit;
> its Telegram/`extensions/` examples are upstream's own campaign, kept as
> worked examples.
>
> **Deviations from upstream** (re-check each still holds before re-syncing a
> future upstream revision against this file):
> 1. The Authoring gate, Junk patterns, Value bar,
>    Retention bar, Candidate evidence and Edit shape sections keep upstream's
>    text, except that `AGENTS.md` reads `CLAUDE.md` (himmel's scoped rules
>    files) and the Authoring gate gains the himmel RED-first paragraph.
> 2. Discovery lanes name himmel's trees (`scripts/`, `marketplace/plugins/`,
>    `plugins/`, `templates/`) instead of openclaw's `src/`, `packages/`,
>    `extensions/`.
> 3. Validation is rewritten for himmel's runners
>    ([`docs/internals/testing.md`](../../../docs/internals/testing.md)): shell
>    suites via `run-shell-tests.sh`, JS/TS suites via the CI-equivalent
>    command `impacted-suites.sh --runner` prints, shellcheck, and /pr-check.
>    Upstream's `run-vitest.mjs`, `check-changed.mjs`, `$openclaw-testing`,
>    `$crabbox` and `$autoreview` do not exist here.
> 4. Landing and continuation points at himmel's ship flow (worktree branch,
>    `/pr-check`, `check-ci`) instead of `$openclaw-pr-maintainer`.
> 5. A himmel section, "Scratch state", is added: tests never touch real
>    operator state.
> 6. The frontmatter `description` is shortened to fit himmel's 120-char
>    skill-description cap (`skill-description-cap` gate); upstream's reads
>    "Invoke whenever writing, changing, reviewing, or sweeping tests.
>    Authoring gate for new tests plus audit workflow for low-value,
>    implementation-coupled, or duplicative tests and the test-only
>    production seams they demand."
>
> No other rule text differs from the pinned commit.

# Test Audit

Three modes, one value bar. Authoring mode gates every new or changed test at
write time. Audit mode runs focused sweeps of tests that re-assert source,
duplicate stronger proof, couple behavior to implementation, or keep test-only
production seams alive. Continue broad audits as separate coherent follow-up
PRs; optimize for confidence, not deletion count. Campaign mode prunes one
whole subsystem's test surface (every test file a plugin or core area owns);
before starting one, read [CAMPAIGN.md](CAMPAIGN.md).

## Authoring gate

Before adding any test, answer four questions; a missing answer means do not
add it yet:

1. What observable behavior, invariant, or independent contract does it protect?
2. What credible regression makes it fail?
3. Why does existing coverage not already catch that failure? Each contract has
   one primary test owner at the strongest boundary; another layer needs its
   own distinct risk, such as a transport or lifecycle failure the owner cannot
   reach. Prefer extending a table-driven case or shared fixture over a
   near-duplicate test; consolidate duplicated setup in the same change.
4. Does it need a production seam (export, flag, wrapper, injection hook) that no
   production caller needs? If yes, move the test to the real boundary instead.

Then check the test against every [junk pattern](#junk-patterns); a match fails
the gate unless the [retention bar](#retention-bar) names the contract it
independently guards. A test that would break under behavior-preserving
refactoring is asserting implementation, not behavior; rewrite it at the
owning boundary before landing it.

Bug regression tests must fail on the pre-fix code for the intended reason and
pass after the owner-boundary repair. A regression test that never demonstrably
failed proves the mock, not the fix. One regression at the owner boundary
covers the bug; do not replay the same scenario at every layer it crosses.

In himmel this is the **RED-first** convention: show the new or repaired
assertion failing against the broken subject (the pre-fix code, or a
deliberate one-line mutation of the owner), then passing against the real one,
and put that RED excerpt in the PR body. A suite that stays green when its
subject is deleted or inverted is the defect this skill exists to catch.

## Junk patterns

The shared checklist for both modes: the authoring gate rejects a new test that
matches one, and audits hunt for existing tests that do.

- assertion-free coverage probes;
- self-comparisons and identity copiers;
- copied fixtures, inventories, manifests, or export lists;
- exact source, import, or string greps;
- private predicate or call-shape tests duplicated at real boundaries;
- duplicate invocations of the same contract;
- provider-local replays of shared helpers;
- tests whose only purpose is preserving test-only exports, globals, or wrappers;
- dead production code whose only callers are tests;
- expected values produced by the helper or renderer under test;
- mocks that implement the asserted behavior, or one identical mock standing in
  for different APIs;
- fixtures that supply the receipt, admission, or callback ordering the owner
  should produce, or persistence asserted against a store the path never writes;
- capability tests that restate declared flags instead of exercising the
  delivery or acknowledgement the flag promises;
- negative controls that pass for an unrelated reason, such as a denial from a
  different guard or a rejection the production path never reaches;
- names or fixtures that promise more than the input exercises, such as a
  "retires the window" test asserting the window was not cleared.

## Value bar

Tests justify their maintenance cost by protecting behavior, a credible
regression, or an independently meaningful contract. In an audit, an existing
test that must change for behavior-preserving source reorganization is suspect,
not automatically deletable; the authoring gate still rejects new ones.

Before judging a candidate, read the complete test and production owner, its
entry point, callers, callees, sibling implementations, overlapping tests, CI
routing, and relevant history. Read root and scoped `CLAUDE.md` files first.
When the test claims dependency-backed behavior, inspect the dependency source
or types directly.

## Discovery

Keep discovery read-only and report evidence before editing. For broad scope,
run parallel discovery lanes when available:

- hooks, guardrails and gates (`scripts/hooks/`, `scripts/guardrails/`, `scripts/ci/`);
- the other shell and TypeScript tooling under `scripts/`;
- plugins (`marketplace/plugins/`, `plugins/`) and `templates/`;
- a cross-cutting pattern sweep.

Outside campaign mode, prefer a few high-confidence candidates over a large
speculative inventory. Hunt for the [junk patterns](#junk-patterns).

## Retention bar

Keep a test when it independently enforces a public API, plugin SDK, protocol,
config, migration, storage, security, platform, default, prompt-byte, generated
cross-language, package, release, or architecture contract. Also keep:

- call ordering when order is observable behavior;
- regressions with a credible failure mode;
- source inspection when it is the cheapest independent guard: it fails when
  the contract changes (the user-facing key, byte, or path) and survives an
  identifier-only refactor;
- a retained test that fails on the baseline: treat it as a possible product
  bug, reproduce it, and repair the owner rather than deleting it.

Static or slow is not a deletion reason. A test that resembles implementation
may still be the independent contract; prove otherwise before removing it.

## Candidate evidence

Record every field below before editing. A missing field means the candidate is
not ready for deletion:

- exact test name and location;
- what failure it can actually detect;
- non-test callers of the covered production or support seam;
- stronger remaining owner-boundary proof, or why no proof is needed;
- relevant history and the reason the test or seam exists;
- production or test-support deletion unlocked;
- risk and the focused validation command.

## Edit shape

Choose one coherent owner-boundary batch. Delete obsolete test-only exports,
globals, wrappers, and dead production paths instead of preserving aliases.
Move retained regressions to their canonical owners. Consolidate repeated
package or dependency assertions into one generic contract.

Prefer net-negative production LOC. Do not add replacement tests that restate
the same implementation, and do not convert uncertain candidates into cleanup
to increase deletion counts.

## Scratch state

Tests use a scratch `HOME` and `mktemp -d` directories. Nothing a suite runs
may read or write the real `~/.claude`, `~/.config/himmel`, `~/.himmel`, the
handover root, or a live vault; a test that needs one of those is asserting
against operator state, not against the code.

## Validation

Invocations are in
[`docs/internals/testing.md`](../../../docs/internals/testing.md); none of
them is the obvious guess.

1. Run the smallest owner and sibling suites: `bash <path>/test-<name>.sh` for
   a shell suite, and for a JS/TS suite the exact command
   `bash scripts/cr/impacted-suites.sh --runner <path>` prints (bun suites have
   a per-suite cwd rule).
2. For removed source greps or plan assertions, run the executable script or
   dry-run that owns the real contract.
3. `shellcheck` the changed shell files, then `git diff --check`.
4. List what the change reaches with
   `bash scripts/cr/impacted-suites.sh <base>..HEAD` and run each listed suite;
   `/pr-check` requires one verdict per listed suite.
5. Inspect `git diff --numstat`; report production/tooling separately from
   tests and test support.
6. After final audit edits, run `/pr-check`.

## Landing and continuation

Commit, push, open a PR, or land only when authorized, from a worktree branch
through himmel's normal ship flow (`/pr-check`, then `check-ci`). Land one
coherent PR at a time; after landing, refresh from current `main` and rerun
read-only discovery for the next high-confidence batch.

## Handoff

Report:

- root cause and removed low-value categories;
- production owner simplifications;
- retained false positives and why they remain valuable;
- focused and full proof actually run;
- production versus test LOC;
- PR and merge state;
- named follow-ups.
