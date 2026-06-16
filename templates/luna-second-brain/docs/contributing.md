# Contributing to luna-brain

luna-brain is an OSS vault skeleton. Contributions that broaden the
default vault layout, improve setup ergonomics, or harden the
guardrails are welcome.

## Workflow

1. **Open or claim an issue** before non-trivial work.
2. **Fork + clone**, then run setup:
   ```bash
   bash scripts/setup.sh
   ```
3. **Create a worktree branch** — never edit on `main`. The
   pre-commit `worktree-isolation` hook refuses commits when
   `HEAD == main`:
   ```bash
   git switch -c feat/<slug>
   ```
4. **Conventional commits.** Format:
   `type(scope): [TICKET-N ]message`. Validated by
   `scripts/hooks/check-commit-msg.sh`. Types: `feat`, `fix`,
   `chore`, `docs`, `refactor`, `test`, `style`, `perf`, `ci`,
   `build`, `revert`. Ticket prefix is optional.
5. **Pre-commit + pre-push hooks** must pass:
   ```bash
   pre-commit run --all-files
   ```
6. **Open a PR** against `main`. PRs are squash-merged to keep main
   history linear. Force-push to `main` is blocked by the
   `no-force-push` pre-push hook.

## What changes are in-scope

- Vault layout improvements (folder structure, templates).
- Setup script improvements (cross-platform robustness, fewer
  prereqs).
- Hook + guardrail additions that apply broadly to vault repos.
- README / docs improvements.
- New SHA-pinned plugin entries in `marketplace/.claude-plugin/marketplace.json`
  for upstream vault plugins that fit the skeleton's intent.

## What changes are out-of-scope

- Personal vault content (notes, decisions, journal entries) — those
  belong in a vault instantiated from this skeleton, not the
  skeleton itself.
- Skeleton tooling specific to one operator's workflow (e.g., Jira
  CLI). Those belong in the operator's own engine repo (e.g.,
  [himmel](https://github.com/yotamleo/Himmel)).
- Auto-installing 3rd-party plugins inside setup.sh. We document the
  install command and let the operator review before running.

## License

MIT — this skeleton ships inside the himmel repository and is covered by
its root `LICENSE`. Bundled `.obsidian` plugins retain their own upstream
licenses (see each plugin's `LICENSE`/`LICENCE` file under
`.obsidian/plugins/`).
