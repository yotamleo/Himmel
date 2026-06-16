---
allowed-tools: Bash(himmel-run:*), Bash(gh:*), Bash(bash:*)
description: Open a GitHub PR. Refuses if HEAD == main or branch is already merged; warns on dirty worktree. Returns the PR URL on success. Forwards args to `gh pr create`. Override flags consumed by the guard (not forwarded to gh): --allow-dirty, --allow-merged-base.
argument-hint: "--title \"...\" --body \"...\" [--base BRANCH] [--head BRANCH] [--allow-dirty] [--allow-merged-base]"
---

## Your task

Run the guard, capture its cleaned argv, then forward to `gh`. The temp file
uses `mktemp` (not `/tmp/...$$`) to avoid symlink-clobber on shared systems
and PID-reuse on stale leftovers; the trap removes it on every exit path.

```
ARGV_FILE=$(mktemp -t guard-argv.XXXXXX) || { echo "gh-pr-create: mktemp failed" >&2; exit 2; }
trap 'rm -f "$ARGV_FILE"' EXIT
GUARD_OUT=$(bash scripts/guardrails/guard-gh.sh pr-create "$@" 2>&1 >"$ARGV_FILE")
GUARD_RC=$?
if [ "$GUARD_RC" -eq 2 ]; then
    printf '%s\n' "$GUARD_OUT" >&2
    exit 2
fi
if [ "$GUARD_RC" -eq 1 ]; then
    printf '%s\n' "$GUARD_OUT" >&2
fi
if ! mapfile -t CLEAN_ARGS < "$ARGV_FILE"; then
    echo "gh-pr-create: failed to read cleaned argv from $ARGV_FILE" >&2
    exit 2
fi
himmel-run gh -- gh pr create "${CLEAN_ARGS[@]+"${CLEAN_ARGS[@]}"}"
```

- If rc=2 (refuse): surface the guard's stderr message to the user verbatim. Do NOT run `gh pr create`. Stop.
- If rc=1 (warn): surface the stderr message AND proceed.
- If rc=0: proceed silently.

`gh pr create` prints the PR URL as its last line, which becomes the runner summary. Output only the runner's one-line summary (plus the guard warning above it, if any). Do not add commentary.

If the command needs interactive prompts (no `--title` / `--body` flags), the runner will hang. Always pass `--title` and `--body` explicitly.

The `--allow-dirty` and `--allow-merged-base` flags are consumed by the guard ONLY - they are stripped from argv before forwarding to `gh pr create` (which would otherwise reject them as unknown flags).
