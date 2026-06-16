---
allowed-tools: Bash(himmel-run:*), Bash(node:*), Bash(gh:*)
description: Reply to a PR review thread by 6-char prefix. Pair with /gh-pr-comments to populate the prefix cache first.
argument-hint: "<thread-prefix> \"<body>\""
---

## Your task

Resolve repo context:

```
eval "$(node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/repo-context-cli.mjs)"
```

The user supplied a PR number as part of an earlier `/gh-pr-comments <N>` call; the prefix cache is keyed by that N. If the current session has not yet seen a PR number, ask the user via AskUserQuestion which PR # the prefix belongs to. Store in `$pr_n`.

Then resolve the full thread id, and post the reply:

```
tid=$(node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/thread-resolve-cli.mjs --owner "$owner" --repo "$name" --number "$pr_n" --prefix "$1") && \
  himmel-run gh --summary-regex '(comment|reply)' -- gh api graphql \
    -F threadId="$tid" \
    -F body="$2" \
    -F query=@$CLAUDE_PROJECT_DIR/plugins/himmel-gh/graphql/reply-thread.gql
```

Output only the runner's one-line summary. If `thread-resolve-cli` exits 1 (no-match, ambiguous, or no-cache), the chain breaks and the runner prints its stderr — surface that to the user and suggest `/gh-pr-comments <N>` to refresh the cache.
