# Smoke test — luna-brain skeleton

Manual smoke test for the v1 luna-brain skeleton bootstrap.

## What's covered automatically

The pre-commit framework runs the full hook suite on every push:

```bash
pre-commit run --all-files
```

Expected output: every hook prints `Passed` (or `Skipped` for hooks
that have no files to check, e.g. `check-json` when nothing has
changed).

## Manual fresh-clone smoke test

Run from a directory outside the existing luna-brain clone so the
clone path is exercised:

```bash
cd /tmp
gh repo clone yotamleo/luna-brain luna-brain-smoke
cd luna-brain-smoke
bash scripts/setup.sh
```

Expected (all six steps green):

```
[1/6] Verifying foundational tools on PATH...
  All foundational tools present.

[2/6] Resolving USER_SLUG...
user-slug: '<your-slug>' (source: ...)

[3/6] Installing pre-commit...
  pre-commit already on PATH — skipping install   # or fresh install line

[4/6] Installing git hooks (pre-commit, pre-push, commit-msg)...
pre-commit installed at .git\hooks\pre-commit
pre-commit installed at .git\hooks\pre-push
pre-commit installed at .git\hooks\commit-msg

[5/6] Checking .env...
  Created .env from .env.example — edit if you want to override defaults.

[6/6] Handover root + vault sanity...
  Handover mode: A  root: <repo>/handovers
  Vault PARA dirs present.

Setup complete.
```

## Plugin install smoke (operator-driven, post-setup)

From inside Claude Code, after `setup.sh` completes:

```
claude plugin marketplace add <repo>/marketplace
claude plugin install obsidian@luna-brain
```

(`claude-obsidian` now ships via the himmel marketplace, not luna-brain.)

Verify `claude plugin list` shows it installed. Run any plugin
command (e.g. `/wiki-query`, `/save`) to confirm one demo skill
operates end-to-end.

## Worktree isolation smoke

Verify the pre-commit `worktree-isolation` hook refuses commits on
main:

```bash
git switch main
echo "test" >> README.md
git add README.md
git commit -m "test: should fail"
# Expected: "ERROR: Committing directly on 'main' is not allowed."
git checkout -- README.md  # undo
```

## Force-push refusal smoke (pre-push, optional)

```bash
git switch -c test-force-push
git push -u origin test-force-push
git commit --amend -m "rewritten"
git push --force-with-lease   # warns + proceeds (non-main)
git push --force-with-lease origin main   # ERROR: blocked
git branch -D test-force-push
git push origin --delete test-force-push
```

## Commit-msg validation smoke

```bash
git commit -m "bad message"
# Expected: COMMIT REJECTED: message does not match conventional commit format.

git commit -m "feat(infra): valid message"
# Expected: commit succeeds.

git commit -m "feat(infra): HIMMEL-119 with ticket"
# Expected: commit succeeds (ticket prefix optional but allowed).
```

## Tested on

| Platform        | Date       | Notes                                        |
|-----------------|------------|----------------------------------------------|
| Windows Git Bash| 2026-05-26 | All 6 steps green. Pre-commit suite clean.   |
