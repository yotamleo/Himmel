---
allowed-tools: Bash(himmel-run:*), Bash(node:*), Bash(gh:*)
description: Resolve a PR review thread by 6-char prefix. Pair with /gh-pr-comments to populate the prefix cache first.
argument-hint: "<thread-prefix>"
---

## Your task

Resolve repo context:

```
eval "$(node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/repo-context-cli.mjs)"
```

The prefix cache is keyed by `(owner, repo, PR-N)`. If the current session has not seen the PR number for this prefix, ask via AskUserQuestion; store in `$pr_n`.

Then expand prefix → full id → resolve:

```
tid=$(node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/thread-resolve-cli.mjs --owner "$owner" --repo "$name" --number "$pr_n" --prefix "$1") && \
  himmel-run gh --summary-regex '(resolved|isResolved.*true)' -- gh api graphql \
    -F threadId="$tid" \
    -F query=@$CLAUDE_PROJECT_DIR/plugins/himmel-gh/graphql/resolve-thread.gql
```

Output only the runner's one-line summary. If the prefix resolver fails, surface stderr and suggest re-running `/gh-pr-comments <N>` to refresh the cache.
