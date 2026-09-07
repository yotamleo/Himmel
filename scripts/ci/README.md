# CI (`scripts/ci/`)

Helpers for the public-CI workflow (`.github/workflows/ci.yml`, HIMMEL-494).

---

## Trigger

The workflow is **`workflow_dispatch`-only** — it runs when manually triggered,
not on every push. The canonical mirror stays clean; the CI runs on a dedicated
public fork where free public runners are available. Promote the workflow to
push/PR triggers once it is green.

---

## Jobs

| Job | What it runs |
|-----|-------------|
| `secret-scan` | `scripts/ci/check-no-secrets.sh` — asserts no `${{ secrets.* }}` interpolation appears in `.github/workflows/`. Enforces the secret-free rail (see below). |
| `lint` | `shellcheck --severity=warning` over all `scripts/*.sh` (git pathspec — every depth) except `scripts/statusline/` (vendored). The pre-commit gate is stricter; CI catches warnings across all runner shellcheck versions. |
| `node-suites` | `npm ci && npm test` matrix across `scripts/jira`, `scripts/bitbucket`, `scripts/himmel-run`. |
| `bun-suites` | `bun install --frozen-lockfile && bun test` in `scripts/luna-vitals`. |
| `shell-unit` | `scripts/ci/run-shell-tests.sh` — discovers and runs all hermetic `test-*.sh` suites under `scripts/`, skipping the SKIP_LIST entries (see below). |

---

## Secret-free rail

All five jobs run with **zero `${{ secrets.* }}` interpolation** in the
workflow. No credentials, no `.env`, no API keys. The `secret-scan` job
enforces this mechanically — if any secrets interpolation appears, the job
fails before anything else runs.

The `shell-unit` job reflects this constraint: suites that need a live agent,
hermes runtime, or network credentials are excluded via the SKIP_LIST.

---

## SKIP_LIST — the runner-gap ledger

`run-shell-tests.sh` maintains a built-in `SKIP_LIST` of suites that cannot
run on a bare runner. Current entries:

The entries themselves are NOT duplicated here. This table used to list them
and had already drifted — it named `test-e2e-symmetry.sh`, which is not an
entry, while omitting eight that are, and it spelled them in the old
scan-root-relative form that the rule below now forbids. A second copy of a
ledger is exactly what goes stale, so read the live one:

```bash
sed -n '/^SKIP_LIST="/,/^"$/p' scripts/ci/run-shell-tests.sh
```

It carries a fuller per-entry reason than this table ever did.

**Write entries repo-root-relative, and they are scan-root invariant
(HIMMEL-2260).** An entry is spelled from the repo root —
`scripts/handover/test-arm-resume.sh`, the same convention `SUITE_TIER`
already used — and is matched on a `/` boundary against each suite's full
path under the *resolved* scan root. Two properties follow:

- **Root-invariance.** The entry holds its suite back identically in a full
  `scripts` run, in a scoped `scripts/handover` run, and under any nested,
  absolute, `./`-spelled, trailing-slashed or symlinked spelling of either.
  Before the fix the entry was compared against the *scan-root-relative* path,
  so every directory-qualified entry went inert the moment a run scoped into
  its own directory — the runner executed suites this ledger said could never
  run here, which is exactly the false evidence the ledger exists to prevent.
- **No basename over-reach.** Spelling the full path is what stops a bare
  `test-adopt.sh` from also matching some future `scripts/foo/test-adopt.sh`
  and silently skipping it. The `/` boundary bounds a match; it cannot recover
  specificity the entry never carried. **Qualify every new entry the same
  way.**

**This applies to EVERY built-in suite table, not just SKIP_LIST.**
`SUITE_CONDITIONAL`, `SUITE_TIER` and `SUITE_REQUIRE_TOOL` share the same
predicate and the same repo-root-relative entry spelling, so a namesake under
another directory can never inherit another suite's conditional rule or tool
gate. `--skip-extra` is the deliberate exception: it stays scan-root-relative
and is compared exactly, because the caller supplies it per run against a scan
root they just named, and every match prints a loud `[SKIP]` line.

**Graduating a suite out of SKIP_LIST:** remove its entry once the runner
provides the missing capability (e.g. a VM, a runtime, network access). If
a suite is skipped for a reason that can be resolved without a real VM — for
example by stubbing the binary — fix the suite first, then remove the entry.
A suite that stays in SKIP_LIST indefinitely without a realistic path to
graduation is a bug to track, not a permanent skip.

---

## SUITE_REQUIRE_TOOL — capability-conditional suites

A suite whose only blocker is a host TOOL (not a VM, not credentials) belongs
in `SUITE_REQUIRE_TOOL`, not `SKIP_LIST` (HIMMEL-1792): it **runs on every
host that has the tool** and is `[SKIP]`ped loudly with its reason where the
tool is absent — a SKIP_LIST entry would make it dead weight on exactly the
hosts whose coverage it exists to add. Entries are repo-root-relative, one per
line, `<repo-root-relative suite path>  <tool>  # <reason>` — e.g.
`scripts/test-claude-openrouter-pwsh.sh  pwsh` (the PowerShell twin smoke
suite). The suite's own runtime guard remains as the second layer for direct
invocation. Env-overridable (`SUITE_REQUIRE_TOOL`) so the runner self-test can
drive the skip branch deterministically.

---

## SUITE_TIER — declarative corpus reduction

A second, orthogonal axis from SKIP_LIST/SUITE_REQUIRE_TOOL: `SUITE_TIER`
(HIMMEL-2120) marks a suite `extended` when it is heavy/slow enough that
running it on every per-PR/agent invocation is not worth the wall-clock —
without ever dropping it from the corpus the way SKIP_LIST would. Grammar,
one entry per line:

```text
<repo-root-relative suite path>  extended  # <reason>
```

`SUITE_TIER_MODE` (env) selects which tier(s) actually run:

| Mode | Behavior |
|------|----------|
| unset / `all` | Runs every suite regardless of tier — byte-identical to no filter at all. This is the full corpus: use it pre-release / nightly. |
| `fast` | Runs everything NOT `extended`-listed; `extended`-listed suites are `[SKIP]`ped loudly with their reason. **Recommended for per-PR agent/operator runs.** |
| `extended` | Runs ONLY the `extended`-listed suites; everything else is `[SKIP]`ped loudly. |
| anything else | Loud misconfiguration, not a silent fallback: exit 2 immediately. |

Filter precedence (r2 F12): **SKIP_LIST → tier → SUITE_CONDITIONAL →
SUITE_REQUIRE_TOOL**. A suite both `extended`-listed and SKIP_LISTed never
runs (SKIP_LIST wins); an `extended`-listed suite whose required tool is
absent still loud-skips on the tool, even in `extended` mode — tier only
decides whether a suite is *offered* to the later filters, not whether it
ultimately runs.

The production table currently carries three `extended` entries, assigned from
measured per-suite cost under the >300s rule (HIMMEL-2120 Task 6):
`scripts/test-check-ci.sh` (559s), `scripts/handover/test-arm-resume-identity.sh`
(814s), and `scripts/handover/test-arm-resume-queue-lock.sh` (307s). Env-overridable
(`SUITE_TIER`), the same seam `SUITE_REQUIRE_TOOL` exposes, so the runner
self-test can drive fast/extended deterministically without touching the
production table.

**Scope note:** no automated consumer is wired for this yet — Actions is OFF
on the private repo by design (see CLAUDE.md), so the only consumers today
are agent/operator invocations choosing `SUITE_TIER_MODE=fast` for speed. A
scheduled `extended`-tier run (nightly) is a named follow-up, not implemented
here.

---

## First-run intent

The first CI run is a **discovery instrument**, not a merge gate. Some
`shell-unit` suites will fail because they expose real bugs; others will fail
because they depend on runner capabilities not yet wired. Triage:

- Fails for a missing runner capability → add to SKIP_LIST with a reason.
- Fails for a real bug → fix the bug (do not skip to hide it).

The workflow becomes a merge gate once the run is consistently green.
