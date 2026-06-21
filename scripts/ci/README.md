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

| Suite | Reason |
|-------|--------|
| `test-install-symmetry-vm.sh` | drives a real VM over SSH |
| `test-e2e-symmetry.sh` | full install/uninstall e2e against a VM |
| `test-himmel-update.sh` | live git pull + marketplace re-sync |
| `test-himmel-update-hermes.sh` | needs the hermes runtime |
| `hermes/test-invoke.sh` | needs the hermes runtime |
| `gemini/test-invoke.sh` | needs the gemini-cli binary |

**Graduating a suite out of SKIP_LIST:** remove its entry once the runner
provides the missing capability (e.g. a VM, a runtime, network access). If
a suite is skipped for a reason that can be resolved without a real VM — for
example by stubbing the binary — fix the suite first, then remove the entry.
A suite that stays in SKIP_LIST indefinitely without a realistic path to
graduation is a bug to track, not a permanent skip.

---

## First-run intent

The first CI run is a **discovery instrument**, not a merge gate. Some
`shell-unit` suites will fail because they expose real bugs; others will fail
because they depend on runner capabilities not yet wired. Triage:

- Fails for a missing runner capability → add to SKIP_LIST with a reason.
- Fails for a real bug → fix the bug (do not skip to hide it).

The workflow becomes a merge gate once the run is consistently green.
