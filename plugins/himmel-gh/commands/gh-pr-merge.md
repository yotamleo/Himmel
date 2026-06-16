---
allowed-tools: Bash(himmel-run:*), Bash(gh:*), Bash(bash:*)
description: Merge a GitHub PR via `gh pr merge`. Refuses `--admin` by default (admin-merge bypasses branch protection). Set GH_ADMIN_MERGE_OK=1 in the shell that launched Claude to allow admin-merge for the session.
argument-hint: "<PR-NUMBER> [--squash|--merge|--rebase] [--admin] [--delete-branch]"
---

## Your task

Run the guard first, then forward to `gh`. The temp file uses `mktemp` (not
`/tmp/...$$`) to avoid symlink-clobber on shared systems and PID-reuse on
stale leftovers; the trap removes it on every exit path.

```
ARGV_FILE=$(mktemp -t guard-argv.XXXXXX) || { echo "gh-pr-merge: mktemp failed" >&2; exit 2; }
trap 'rm -f "$ARGV_FILE"' EXIT
GUARD_OUT=$(bash scripts/guardrails/guard-gh.sh pr-merge "$@" 2>&1 >"$ARGV_FILE")
GUARD_RC=$?
if [ "$GUARD_RC" -eq 2 ]; then
    printf '%s\n' "$GUARD_OUT" >&2
    exit 2
fi
if ! mapfile -t CLEAN_ARGS < "$ARGV_FILE"; then
    echo "gh-pr-merge: failed to read cleaned argv from $ARGV_FILE" >&2
    exit 2
fi
himmel-run gh -- gh pr merge "${CLEAN_ARGS[@]+"${CLEAN_ARGS[@]}"}"
```

If the guard refused (rc=2), surface its stderr verbatim and stop. Otherwise run the merge and output only the runner's one-line summary. Do not add commentary.

The `--admin` flag is forwarded to `gh` unchanged when allowed - the guard only inspects it for the refusal decision and does not strip it from the argv. (Contrast `--allow-*` flags on `/gh-pr-create`, which are consumed-and-stripped.)
