# himmel-gh

Thin Claude Code plugin wrapping `gh` CLI through `scripts/himmel-run/`.

## Install

The plugin lives in this repo. Add via:

```
/plugin install ./plugins/himmel-gh
```

Requires `gh` CLI on PATH (install separately from https://cli.github.com/) and `himmel-run` on PATH (wired by `scripts/machine-setup/{ubuntu.sh,win11.ps1}`).

## Auth

`gh` owns its own credentials in `~/.config/gh/hosts.yml`. Bootstrap once per machine:

```
gh auth login --web
```

Then run `/gh-init` to verify scopes.

`GH_TOKEN` env var also works, but scope checks are skipped (token is opaque). To use a fine-grained PAT, leave `gh auth status` showing the env-token path; ensure your PAT carries `repo`, `read:org`, `workflow`.

## Commands

### Basics

- `/gh-init` — verify auth + scopes (run once per machine).
- `/gh-pr-view <N>` — one-line PR status (title | state | mergeable).
- `/gh-pr-list [--author "@me"]` — list open PRs (one-line "N open PR(s)" summary; full JSON in `normal.log`).
- `/gh-pr-create` — open a PR (pass through to `gh pr create`).
- `/gh-pr-checks <N>` — CI check status summary.

### Code-review loop

- `/gh-pr-review <N> [--approve|--request-changes|--comment] --body "<body>"` — submit a review with verdict.
- `/gh-pr-comment <N> "<body>"` — add a general comment to the PR.
- `/gh-pr-comments <N>` — list review threads (writes per-PR 6-char prefix cache; one-line `threads=N unresolved=M` summary; full table in normal.log).
- `/gh-pr-reply <prefix> "<body>"` — reply to a review thread. The prefix is
  expanded against the most recent PR's thread cache. The cache is keyed by
  `(owner, repo, PR-N)`, so if no PR is currently in session context the skill
  asks for the PR number first (or you can run `/gh-pr-comments <N>` to seed
  the cache).
- `/gh-pr-resolve <prefix>` — resolve a thread by 6-char prefix (same cache
  lookup semantics as `/gh-pr-reply`).

The three thread commands are **forge-aware** (spec §5.3): on a `github.com`
repo they use GitHub GraphQL; on a `bitbucket.org` repo they route through the
`bitbucket` CLI's `pr comments|reply|resolve` REST verbs (Bitbucket Cloud has no
GraphQL, so its flat comment+`parent` model is mapped into the same thread
abstraction). The 6-char prefix cache is identical across forges — only the
fetch/mutate calls differ.

Each command has a matching skill that auto-triggers on PR/GitHub intent. Skills explicitly do NOT trigger on Jira tickets (HIMMEL-N pattern → himmel-jira plugin), ambiguous "show issue" prompts, or whole-PR ops when the user means a thread.

## Logs + cache

`~/.cache/himmel-cli/gh/` (POSIX) or `%LOCALAPPDATA%\himmel-cli\gh\` (Windows):

- `normal.log` — append-only stdout (rotated at 10MB).
- `error.log` — append-only stderr.
- `index/<run-id>.json` — per-call metadata for `himmel-run gh --inspect <run-id>`.
- `repo-context.json` — cached `(owner, name)` keyed by cwd; refreshed when cwd changes.
- `threads/<owner>-<repo>-<N>.json` — per-PR 6-char prefix → full thread-id map. Written by every `/gh-pr-comments` call.

Inspect any run:

```
himmel-run gh --inspect <run-id-from-summary-line>
```
