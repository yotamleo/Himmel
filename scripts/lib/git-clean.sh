#!/usr/bin/env bash
# scripts/lib/git-clean.sh — shared env-scrub helper for trust-path git calls
# (HIMMEL-3570).
#
# WHY: a git subprocess on a trust path inherits the CALLER's GIT_DIR,
# GIT_WORK_TREE, GIT_COMMON_DIR and GIT_INDEX_FILE. An attacker-set value for
# any of the four steers which repo/worktree/index the call actually answers
# about — PR 1212 (anchor-handoff.sh, `ls-files --error-unmatch` under a
# poisoned GIT_DIR) and PR 1217 (plugin-profiles.mjs `primaryCheckout`, the
# same class via `git rev-parse --git-common-dir`) are both this bug.
#
# CAUTION — git hooks: `GIT_INDEX_FILE` is NOT always attacker-controlled
# noise to scrub. A running git hook (e.g. `pre-commit` under `commit -a`)
# can set it legitimately to the lock file it is committing through, and a
# hook-invoked trust-path script that calls `git_env_scrub` unconditionally
# near the top would unset that real value, so a later `git diff --cached`
# in the SAME script then reads the wrong (default) index instead of the
# hook's. A trust-path script that may run AS a git hook must not scrub
# GIT_INDEX_FILE file-wide — either scrub only around the specific
# non-index trust-path call (`git_clean -C ... rev-parse ...`, never a bare
# `git_env_scrub`), or scrub the other three and leave GIT_INDEX_FILE alone
# (console adversarial review, HIMMEL-3570, 2026-09-24).
#
# Source this file and use either form on any trust-path script
# (scripts/handover/**, scripts/lanes/**, scripts/hooks/**, scripts/cr/**,
# scripts/lib/go-gate.sh):
#
#   Per-call:            git_clean -C "$repo_root" rev-parse --git-common-dir
#   Once, near the top:  git_env_scrub   # then bare `git` calls are safe
#
# `check-git-env-scrub.sh` (the pre-commit/CI gate) treats a `git_clean` call
# as already-scrubbed per-call, and a `git_env_scrub` call before a script's
# first bare `git` invocation as scrubbing the whole file.
#
# git-env-ok: this file IS the scrub mechanism — git_clean's own `env -u`
# prefix on its `git "$@"` call is the scrub, not a bare invocation needing one.
git_clean() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
}

git_env_scrub() {
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
}
