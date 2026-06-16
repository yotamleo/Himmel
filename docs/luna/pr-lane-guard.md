# luna PR-lane guard — opt-in worktree isolation (HIMMEL-214)

## Why

Worktree/branch isolation is structurally enforced only in himmel
(`block-edit-on-main.sh`, `check-worktree-isolation.sh`). luna documents a
**two-lane model** in its `_CLAUDE.md` — PR lane (worktree + branch + PR)
for structural files, plugin lane (direct commits to main via the
github-sync plugin) for vault content — but nothing enforced the PR lane.
A structural edit committed directly to luna `main` passed every luna hook
(observed risk: luna PR #33 used a worktree voluntarily).

Per HIMMEL-195 (structural > instructional), himmel now exports a portable
gate via `.pre-commit-hooks.yaml` that any repo can opt into. The gate is
**path-scoped**: it blocks commits on `main` only when staged files match
the consuming repo's `files:` regex, so luna's plugin-lane commits (daily
notes, clips) to main keep flowing untouched.

## How it works

- himmel's `.pre-commit-hooks.yaml` exports `pr-lane-isolation`
  (`scripts/hooks/check-pr-lane-isolation.sh`) and `worktree-isolation`
  (full block, himmel-grade).
- pre-commit clones himmel into its cache and runs the hook with CWD =
  the consuming repo root, passing only the staged filenames that matched
  the consumer's `files:` filter.
- On a feature branch: allow. On `main` with matched files: block with a
  message pointing at the two-lane rule. No matched files: pre-commit
  skips the hook entirely.

## luna opt-in snippet

Add to luna's `.pre-commit-config.yaml` (himmel is private — pre-commit
clones with the operator's normal git credentials):

```yaml
  - repo: https://github.com/yotamleo/Himmel
    rev: <himmel commit SHA>   # pin; bump with `pre-commit autoupdate --bleeding-edge`
    hooks:
      - id: pr-lane-isolation
        # luna PR-lane paths per _CLAUDE.md "two-lane model":
        # _Templates/, _CLAUDE.md, CLAUDE.md, docs/, .gitignore,
        # .obsidian/ config (plugins/themes/vault-wide settings).
        # Excluded: files that Obsidian or github-sync auto-writes on normal
        # UI use and commits to main via the plugin lane.  A non-empty
        # exclude keeps these from wedging the gate:
        #   plugins/*/data.json  — plugin-settings churn (original case)
        #   app.json / appearance.json — rewritten on every Obsidian launch
        #   workspace*.json — rewritten on window resize / mobile switch
        files: ^(_Templates/|_?CLAUDE\.md$|docs/|\.gitignore$|\.obsidian/)
        exclude: ^\.obsidian/(plugins/[^/]+/data\.json|app\.json|appearance\.json|workspace(-mobile)?\.json)$
```

Then `pre-commit install` (if hooks aren't already installed) and verify:

```bash
# on main, should BLOCK:
touch docs/probe.md && git add docs/probe.md && git commit -m "probe"
# expected: "ERROR: commit on 'main' touches PR-lane path(s): docs/probe.md"
git restore --staged docs/probe.md && rm docs/probe.md
```

## Acceptance mapping (HIMMEL-214)

- Commit to luna `main` touching a PR-lane path → refused, message points
  at the two-lane rule. Met: gate blocks + prints "Two-lane rule: …".
- Vault-content commits to luna `main` (plugin lane) → still pass. Met:
  no `files:` match → hook not invoked.

## Bypass / recovery

- Deliberate one-off exception: `SKIP=pr-lane-isolation git commit …`
  (pre-commit's native skip; use `SKIP=worktree-isolation` if consuming
  the full-block hook instead).
- The gate only fires on `main`; the normal path is a branch + PR per
  luna's documented lanes.

## Caveats

- The hook needs bash (Git for Windows ships it; pre-commit resolves the
  `#!/usr/bin/env bash` shebang for `language: script` hooks).
- pre-commit caches the himmel clone keyed by `(repo, rev)` — gate fixes in
  himmel reach luna only after bumping `rev`.
- `main` is hardcoded as the protected branch (shared
  `scripts/guardrails/lib.sh` predicate; both repos use `main`).
