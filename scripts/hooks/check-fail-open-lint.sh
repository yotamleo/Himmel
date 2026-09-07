#!/usr/bin/env bash
# Run the fail-open lint suite (HIMMEL-1776 round 2, codex-adv-1).
#
# The suite existed as a standalone script that only ran when somebody
# remembered to type it (or via the public-mirror CI). Private Actions are
# OFF on this repo by design, so until this hook existed a guard change
# could merge on the private path with the lint never having run once — a
# lint no gate runs enforces nothing. The suite re-makes three assertions
# on every invocation: each detector still fires on its pre-fix
# reconstruction, the fixed twins still pass, and the REAL guard surfaces
# are clean (instance six of "unknown treated as benign" cannot merge
# quietly) — plus the trigger-coverage check that THIS hook stays wired.
#
# Known gap (panel round 6, codex-1): this scans the WORKING TREE, not the
# staged index — same as every other pass_filenames:false hook in this repo
# (worktree-isolation, guardrail-matrices, etc). A partially-staged commit
# (staged content still vulnerable, an unstaged edit on the same file
# happens to fix it) can pass the gate while the commit itself carries the
# vulnerable staged content. Closing this needs stashing unstaged/untracked
# changes before the scan and restoring them after (git stash --keep-index
# + a restore trap) — deliberately NOT done here: a bug in that stash/pop
# sequence risks losing uncommitted work for every future committer, a far
# larger blast radius than the narrow partial-staging edge case it would
# close. `git commit -a` or `git add -u` before committing avoids the gap
# entirely by leaving nothing unstaged to diverge from.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$repo_root"

suite=scripts/guardrails/test-lint-fail-open.sh
if [ ! -f "$suite" ]; then
  echo "check-fail-open-lint: missing $suite" >&2
  exit 1
fi

if out=$(bash "$suite" 2>&1); then
  echo "$out"
  echo "  ok  $suite"
else
  echo "check-fail-open-lint: FAILED $suite" >&2
  echo "$out" >&2
  exit 1
fi
