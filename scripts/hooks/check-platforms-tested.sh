#!/usr/bin/env bash
# Pre-push hook: cross-platform validation gate for shell/script changes.
#
# Friction this prevents: scripts in `scripts/` (shell + powershell + node
# shims) repeatedly ship with platform-specific bugs that only surface at
# runtime on the OTHER OS — e.g. spawn() missing `shell:true` on Windows,
# `$Args` collision in PowerShell, `python` vs `python3` on Linux, UTF-8
# BOM mojibake, unquoted `#` in YAML paths. CR catches some; many slip.
#
# Gate: if the diff vs main touches any cross-platform-sensitive path,
# require either
#   1. a commit body line `Platforms tested: <list>` in at least one
#      commit being pushed, OR
#   2. the same line in the PR body (looked up via `gh pr view` for the
#      current branch when a PR already exists), OR
#   3. an explicit bypass.
#
# The line itself is a self-attestation — we don't try to verify the
# claim. The point is forcing the operator to acknowledge the cross-
# platform surface before push, which is what catches the bugs early.
#
# Sensitive paths (basename or glob):
#   *.sh, *.bash, *.zsh, *.ps1, *.psm1, *.psd1, *.cmd, *.bat
#   scripts/**, **/bin/*
#
# Skip if changed-file set is empty after filtering.
#
# Bypass:
#   PLATFORMS_TESTED_OK=1 git push ...    (env-var skip; logs WARNING)
#   `[skip platforms-check]` in any commit msg being pushed
#   git push --no-verify ...              (skip all pre-push hooks)
#
# Exit codes:
#   0 — pass (no sensitive files, attestation present, or bypass)
#   1 — block (sensitive files changed + no attestation + no bypass)
#   2 — block (cannot evaluate — fail-closed: can't source guardrails/lib.sh,
#       can't read the current branch, or no diff base resolves on the online
#       path; HIMMEL-323)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# default_branch() resolves the protected default (main OR master, HIMMEL-297)
# used as the diff base below. Fail-closed: a missing guardrail substrate means
# we cannot compute the right base, so refuse the push.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ platforms-check: cannot source guardrails/lib.sh — refusing the push (rc=2 = cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi

# Resolve THIS worktree's branch via lib.sh::_branch (HIMMEL-323). `git branch
# --show-current` is worktree-correct under a normal pre-push (git points GIT_DIR
# at the worktree's own gitdir) but reads the PRIMARY worktree's HEAD if GIT_DIR
# is aimed at the shared .git; routing through _branch keeps the pre-push gates'
# branch reads on one path. _branch also returns rc=2 on an unreadable HEAD so we fail
# CLOSED with a clear diagnostic instead of letting `set -e` abort opaquely.
rc=0
branch=$(_branch) || rc=$?
if [ "$rc" -eq 2 ]; then
    echo "→ platforms-check: cannot resolve current branch (lib.sh::_branch rc=2) — refusing the push (cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi

# Detached HEAD (empty branch, rc=1) or a protected default (main/master): skip.
# no-push-to-main covers main/master; detached HEAD has no sensible diff base.
if [ -z "$branch" ] || is_on_main; then
    exit 0
fi

if [ "${PLATFORMS_TESTED_OK:-0}" = "1" ]; then
    echo "→ platforms-check: PLATFORMS_TESTED_OK=1 — skipping (WARNING: verify cross-platform behaviour manually before merge)" >&2
    exit 0
fi

# Resolve diff base. HIMMEL-113: prefer origin/<default>, NOT local <default>.
# Rationale: linked git worktrees cannot fast-forward their local default-branch
# ref while the primary worktree owns that checkout. That made
# `git diff <default>...HEAD` re-flag every shell/script file that was
# already on origin/<default> but not yet in the linked worktree's local
# copy - producing the friction we hit on HIMMEL-104, -110, -108 etc.
# origin/<default> is the actual push target; comparing against it is what
# the gate is conceptually about. <default> = main OR master (HIMMEL-297).
#
# Refresh origin/<default> first (silent, single ref, ~1s) so offline / very
# stale clones still get a fair comparison. Failure (no network, no
# remote, etc.) is non-fatal - we fall back to whatever origin/<default> is
# locally.
#
# PLATFORMS_TESTED_NO_FETCH=1 skips the fetch for offline workflows.
db=$(default_branch)
if [ "${PLATFORMS_TESTED_NO_FETCH:-0}" != "1" ]; then
    git fetch -q origin "$db" 2>/dev/null || true
fi

diff_base=""
if git rev-parse --verify --quiet "origin/$db" >/dev/null; then
    diff_base="origin/$db"
elif git rev-parse --verify --quiet "$db" >/dev/null; then
    diff_base="$db"
elif [ "${PLATFORMS_TESTED_NO_FETCH:-0}" = "1" ]; then
    # No resolvable base AND the operator opted into offline mode (NO_FETCH):
    # a shallow/offline clone legitimately may not carry the default ref. We
    # cannot evaluate the gate, but blocking here would break the documented
    # offline workflow — skip with a LOUD warning (HIMMEL-323).
    echo "→ platforms-check: no 'origin/$db' or local '$db' ref and PLATFORMS_TESTED_NO_FETCH=1 — cannot compute diff; SKIPPING the gate (WARNING: cross-platform surface NOT checked — verify manually before merge)" >&2
    exit 0
else
    # Online path: we attempted `git fetch origin $db` and STILL cannot resolve
    # any base. That is a genuinely broken state (default renamed and origin/HEAD
    # not pointing at it, corrupt refs) — not a normal clone, which always has
    # origin/<default>. Fail CLOSED (HIMMEL-323): refusing the push beats silently
    # skipping the gate on an unattested change.
    echo "→ platforms-check: no 'origin/$db' or local '$db' ref after fetch — refusing the push (rc=2 = cannot evaluate the gate). Set PLATFORMS_TESTED_NO_FETCH=1 for a known-offline/shallow clone, or bypass with PLATFORMS_TESTED_OK=1 / git push --no-verify." >&2
    exit 2
fi

# Fail CLOSED if the diff itself can't be computed (HIMMEL-323). The 3-dot
# range needs a merge base; an orphan/unrelated-history branch makes `git diff`
# exit non-zero. The old `|| true` swallowed that to an empty list, which the
# `[ -z ]` line below then treated as "no changes" → a silent PASS on a branch
# we never actually inspected. An empty diff (genuinely no changes) still exits
# 0 via rev-parse'd success + the `[ -z ]` skip.
if ! changed=$(git diff --name-only "${diff_base}...HEAD" 2>/dev/null); then
    echo "→ platforms-check: cannot compute diff vs ${diff_base} (no merge base / git error) — refusing the push (rc=2 = cannot evaluate; bypass with PLATFORMS_TESTED_OK=1 or git push --no-verify)" >&2
    exit 2
fi
[ -z "$changed" ] && exit 0

# Filter sensitive paths.
sensitive=$(printf '%s\n' "$changed" | grep -E '(\.(sh|bash|zsh|ps1|psm1|psd1|cmd|bat)$|^scripts/|(^|/)bin/[^/]+$)' || true)
if [ -z "$sensitive" ]; then
    exit 0
fi

# Scan commit messages in the push range for `Platforms tested:` line OR
# the `[skip platforms-check]` opt-out.
commit_msgs=$(git log --format='%B' "${diff_base}..HEAD" 2>/dev/null || true)

# Recognised platform tokens. At least ONE must appear after the colon
# on a `Platforms tested:` line — empty values (`Platforms tested:`) and
# unrecognised values (`Platforms tested: yes`) do NOT count, otherwise
# operators game the gate by typing the prefix without naming a target.
PLATFORM_RE='(linux|windows|macos|ubuntu|debian|fedora|arch|mac|darwin|wsl|posix|gitbash|git-bash|powershell|pwsh)'
ATTEST_RE="^[[:space:]]*Platforms tested:.*\\b${PLATFORM_RE}\\b"

if printf '%s' "$commit_msgs" | grep -qiE '^\s*\[skip platforms-check\]'; then
    echo "→ platforms-check: [skip platforms-check] in commit msg — skipping (WARNING: verify cross-platform behaviour manually)" >&2
    exit 0
fi

if printf '%s' "$commit_msgs" | grep -qiE "$ATTEST_RE"; then
    line=$(printf '%s' "$commit_msgs" | grep -iE "$ATTEST_RE" | head -1 | sed 's/^[[:space:]]*//')
    echo "→ platforms-check: ${line}" >&2
    exit 0
fi

# Fall back to PR body (an open PR for this branch may carry the line even
# when commits don't). Tolerate gh not being available / not authed / no PR.
pr_body=""
if command -v gh >/dev/null 2>&1; then
    pr_body=$(gh pr view "$branch" --json body --jq '.body' 2>/dev/null || true)
fi
if [ -n "$pr_body" ] && printf '%s' "$pr_body" | grep -qiE "$ATTEST_RE"; then
    line=$(printf '%s' "$pr_body" | grep -iE "$ATTEST_RE" | head -1 | sed 's/^[[:space:]]*//')
    echo "→ platforms-check: ${line} (from PR body)" >&2
    exit 0
fi

# Block.
cat >&2 <<EOF
⛔ platforms-check: this push touches cross-platform-sensitive files but
   no \`Platforms tested:\` attestation found in commit messages or PR body.

   Sensitive files changed vs ${diff_base}:
$(printf '%s\n' "$sensitive" | sed 's/^/     /')

   Fix one of:
   1. Add a line to a commit body (or amend):
          Platforms tested: linux, windows
      Must name at least one recognised platform token:
        linux, windows, macos, ubuntu, debian, fedora, arch, mac,
        darwin, wsl, posix, gitbash, git-bash, powershell, pwsh
      An empty value (\`Platforms tested:\`) or an unrecognised value
      (\`Platforms tested: yes\`) does NOT count.
   2. Add the same line to the PR description, then re-push.
   3. Bypass for an unattested push:
          PLATFORMS_TESTED_OK=1 git push ...
      or include \`[skip platforms-check]\` in a commit message.

   Why: scripts in this repo run on both Linux/macOS (bash) and Windows
   (PowerShell + Git Bash). Bugs from one side keep slipping through CR
   (shell:true, \$Args, BOM, python vs python3, /bin/sh shims). This
   gate forces the cross-platform check to be acknowledged before push.
EOF
exit 1
