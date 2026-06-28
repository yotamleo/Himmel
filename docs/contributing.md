# Contributing to himmel

Solo-operator-first, multi-operator-capable workflow. The repo is engineered
for one main maintainer + occasional collaborators; the conventions below
keep that working at any team size.

## Branch + PR workflow

1. **Never edit on `main`.** Two enforcement layers work in tandem:
   `scripts/hooks/block-edit-on-main.sh` (PreToolUse) blocks edits at write
   time, and `scripts/hooks/check-worktree-isolation.sh` (pre-commit) catches
   any that reach commit stage.
2. **Create a worktree per ticket / unit of work:**

   ```bash
   bash scripts/worktree.sh feat/himmel-<N>-<slug>
   # or
   /worktree feat/himmel-<N>-<slug>   # in Claude Code
   ```

   Branch names must be `<type>/<slug>` where
   `type ∈ feat|fix|chore|docs|refactor|test`. The orchestrator
   enforces this.

3. **Commit format:** conventional commits with optional ticket key.

   ```
   type(scope): [HIMMEL-N ]message

   Optional longer body...

   Platforms tested: gitbash
   Co-Authored-By: ...
   ```

   `scripts/hooks/check-commit-msg.sh` validates the format on `commit-msg`.

   The `Co-Authored-By: Claude` trailer is emitted by Claude Code itself, not
   by any himmel script. To turn it off, set the `attribution` key in your
   user-scope `~/.claude/settings.json` (keeps it personal and out of the repo;
   for a project-local override use the gitignored `.claude/settings.local.json`):

   ```json
   {
     "attribution": { "commit": "", "pr": "" }
   }
   ```

   `attribution` (Claude Code 2.0.62+) supersedes the deprecated
   `includeCoAuthoredBy` boolean and takes precedence over it. Either disables
   the trailer; prefer `attribution`. This does not affect the
   `Platforms tested:` / `Security reviewed:` attestation trailers, which the
   pre-push gates require independently.

4. **Push** opens a multi-agent CR marker (HIMMEL-26). Run
   `/pr-check` (or `/pr-review-toolkit:review-pr`) in your Claude session
   before opening the PR; the marker blocks `gh pr create` until CR is clean.

5. **Open the PR**: `gh pr create --body-file <file>` (writing the body to
   a file avoids heredoc / shell-substitution surprises).

6. **Merge mode is squash + admin + delete-branch.** Repo settings forbid
   merge-commits.

   ```bash
   gh pr merge <N> --squash --admin --delete-branch
   ```

## Pre-commit / pre-push gates

All gates are wired in `.pre-commit-config.yaml`. Source of truth, not
this doc. Highlights:

- **Format / lint:** trailing-whitespace, EOF, yaml, json, shellcheck, gitleaks.
- **Branch hygiene:** worktree-isolation, merged-branch check, no-push-to-main.
- **Jira plugin enforcement:** committed code referencing Atlassian MCP Jira
  tools that have a `scripts/jira/` plugin equivalent is blocked
  (`mcp-plugin-refs`).
- **Headless-claude gate:** new `claude -p` / `--print` / `--bg` invocations
  must carry a `# headless-claude-ok: <reason>` marker (HIMMEL-128).
- **CR-before-push:** the multi-agent CR marker described above
  (`check-cr-before-push.sh`).
- **Platforms-tested:** shell / script changes must include a
  `Platforms tested: <platforms>` line in the commit body or PR description
  (HIMMEL-113).
- **PR mergeable + no force-push:** pre-push refuses pushes when the PR is
  CONFLICTING or when a force-push targets `main` (HIMMEL-136).

## Cross-platform conventions

- bash 3.2 is the floor (macOS default). Eight scripts use `mapfile` and
  require bash 4+ — documented in CLAUDE.md.
- Five scripts use `realpath -m` with a `python3` fallback so macOS works
  without `coreutils`.
- Windows operators run via Git Bash. `cygpath -m` normalizes paths when
  needed.

## Enable the doc-guard gate

The catalog-sync gate (`doc-guard`, `scripts/hooks/check-doc-guard.sh`) is **opt-in** — it guards
himmel contributors but must stay off for adopters who use himmel only as a
harness. Enable it by dropping a gitignored marker at the repo root:

```bash
touch .himmel-dev
```

Without this marker, `scripts/himmel-update.sh --plugins-check` will remind
you the gate is off. The marker is listed in `.gitignore` and never committed.

## Smoke tests

Every new shell hook or handover script ships with a paired smoke test
at `scripts/<area>/test-<thing>.sh`. Run after any edit:

```bash
bash scripts/hooks/test-check-cr-before-push.sh
bash scripts/handover/test-auto-commit.sh
# etc.
```

## Where to find things

| Concern                        | Doc                                                |
|--------------------------------|----------------------------------------------------|
| Repo-wide rules + conventions  | [`CLAUDE.md`](../CLAUDE.md)                         |
| First-time setup               | [`docs/setup/new-machine.md`](setup/new-machine.md) |
| Handover system                | [`docs/handover/`](handover/)                       |
| Overnight mode                 | [`docs/handover/overnight-mode.md`](handover/overnight-mode.md) |
| Luna-area docs convention      | [`docs/luna/`](luna/)                               |
| Tooling catalog                | [`docs/tooling-catalog.md`](tooling-catalog.md)     |

## Filing tickets

Use the local Jira CLI rather than the Atlassian MCP plugin (see CLAUDE.md
`## Jira tooling — prefer plugin over MCP` for the rationale and command
mapping).

```bash
node scripts/jira/dist/index.js create --project HIMMEL --type Task \
  --title "Short subject" --desc "Spec body with acceptance criteria"
```

## Reporting issues

Open a GitHub issue or file a Jira ticket directly. There's no separate
issue-template gate.

For **security vulnerabilities**, do not open a public issue — follow
[`SECURITY.md`](../SECURITY.md). All participation is governed by our
[`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md).
