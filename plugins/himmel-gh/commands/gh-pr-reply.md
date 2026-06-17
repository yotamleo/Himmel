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

Then post the reply. The CLI expands the prefix to a thread id and routes the
mutate through the active forge (GitHub GraphQL or, for a `bitbucket.org` repo,
the `bitbucket pr reply` REST verb — spec §5.3):

```
himmel-run gh --summary-regex 'reply: ok' -- node $CLAUDE_PROJECT_DIR/plugins/himmel-gh/lib/thread-reply-cli.mjs --owner "$owner" --repo "$name" --number "$pr_n" --prefix "$1" --body "$2"
```

Output only the runner's one-line summary. If the CLI exits 1 (no-match, ambiguous, or no-cache), the runner prints its stderr — surface that to the user and suggest `/gh-pr-comments <N>` to refresh the cache.
