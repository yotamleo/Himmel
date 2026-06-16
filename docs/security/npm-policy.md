# npm policy

Local-only supply-chain hygiene for npm projects in this repo. Part of the
HIMMEL-19 security-tooling epic (tracked in the operator's private handover repo).

## Lockfile policy

Every `package.json` ships with a sibling `package-lock.json`, committed to
git. No exceptions. A `package.json` without a committed lockfile means the
next install pulls a floating dep tree — the "lockless install" footgun.

## Install command

- **Default:** `npm ci`. Reproducible install that reads the lockfile
  exactly and fails if `package.json` and `package-lock.json` disagree.
- **Adding or updating a dep:** `npm install <pkg>` (or `npm update <pkg>`).
  This is the only path that should rewrite `package-lock.json`. Commit the
  resulting lockfile in the same PR as the `package.json` change.
- **Never** run a bare `npm install` to "fix" things — it silently mutates
  the lockfile and drops the integrity gate.

## Enforcement

Pre-commit hook `lockfile-integrity` (registered in
`.pre-commit-config.yaml`) runs `scripts/hooks/check-lockfile-integrity.sh`
on every commit. For each `package.json` under `scripts/` it asserts:

1. A sibling `package-lock.json` exists.
2. The lockfile is tracked in git.
3. `npm ci --dry-run --ignore-scripts` succeeds — this is the lock-drift
   detector: `npm ci` refuses to run when the lockfile is out of sync with
   `package.json`.

A drifted lock fails the commit. Fix locally with `npm install` in the
affected package and re-commit the updated lockfile.

## Auto-install on missing node_modules

`check-npm-licenses.sh` (pre-push) self-installs production dependencies when
`node_modules` is missing for any in-scope `package.json` (e.g. fresh worktree
right after `git checkout`). It runs `npm ci --omit=dev --ignore-scripts` —
`--ignore-scripts` is mandatory so no third-party postinstall script ever runs
inside a pre-push gate. If `package-lock.json` is missing, it falls back to
`npm install --omit=dev --ignore-scripts` and continues. Cost: a one-time
~5-15s install on each fresh worktree's first push; zero overhead afterwards
(node_modules is gitignored but persists for the worktree lifetime).

## Reference

- Brief: HIMMEL-82 lockfile-integrity-check (tracked in the operator's private handover repo)
- Related (pre-push): `check-npm-audit.sh`, `check-npm-licenses.sh` (epic #10)
