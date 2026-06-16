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
set -euo pipefail

branch=$(git branch --show-current)

# Detached HEAD or main push: skip — `no-push-to-main` covers main, and we
# can't compute a sensible diff base on detached HEAD.
if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    exit 0
fi

if [ "${PLATFORMS_TESTED_OK:-0}" = "1" ]; then
    echo "→ platforms-check: PLATFORMS_TESTED_OK=1 — skipping (WARNING: verify cross-platform behaviour manually before merge)" >&2
    exit 0
fi

# Resolve diff base. HIMMEL-113: prefer origin/main, NOT local main.
# Rationale: linked git worktrees cannot fast-forward their local `main`
# ref while the primary worktree owns the `main` checkout. That made
# `git diff main...HEAD` re-flag every shell/script file that was
# already on origin/main but not yet in the linked worktree's local
# main - producing the friction we hit on HIMMEL-104, -110, -108 etc.
# origin/main is the actual push target; comparing against it is what
# the gate is conceptually about.
#
# Refresh origin/main first (silent, single ref, ~1s) so offline / very
# stale clones still get a fair comparison. Failure (no network, no
# remote, etc.) is non-fatal - we fall back to whatever origin/main is
# locally.
#
# PLATFORMS_TESTED_NO_FETCH=1 skips the fetch for offline workflows.
if [ "${PLATFORMS_TESTED_NO_FETCH:-0}" != "1" ]; then
    git fetch -q origin main 2>/dev/null || true
fi

diff_base=""
if git rev-parse --verify --quiet origin/main >/dev/null; then
    diff_base=origin/main
elif git rev-parse --verify --quiet main >/dev/null; then
    diff_base=main
else
    echo "→ platforms-check: no 'origin/main' or local 'main' ref — skipping (cannot compute diff)" >&2
    exit 0
fi

changed=$(git diff --name-only "${diff_base}...HEAD" || true)
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
