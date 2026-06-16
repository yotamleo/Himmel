#!/usr/bin/env bash
# Pre-push hook: security-review attestation gate (HIMMEL-176).
#
# Friction this prevents: code changes ship without an explicit security
# review pass. Existing CR-before-push (multi-agent code review) catches
# correctness and code-quality issues but does not specifically prompt for
# the security-focused lens that anthropics/claude-code-security-review
# was designed around (input handling, authn/authz, secrets exposure,
# command injection, SSRF, deserialization, etc.).
#
# Gate: if the diff vs main touches any non-docs code path, require either
#   1. a `Security reviewed: <token>` line in at least one commit body
#      being pushed, OR
#   2. the same line in the PR body (looked up via `gh pr view` when a
#      PR exists for the current branch), OR
#   3. an explicit bypass.
#
# The line is a self-attestation — the gate does NOT run the review
# itself. This is HIMMEL-128 compliant: no new headless-claude
# invocations are introduced; the operator runs the security review
# in-session (via /security-review slash command vendored from
# anthropics/claude-code-security-review, OR via any other mechanism the
# operator prefers) and attests the result in the commit message.
#
# This pattern matches the existing `platforms-tested` gate
# (`check-platforms-tested.sh`) — self-attestation with a recognised
# token vocabulary. The operator decides WHEN and HOW; the gate enforces
# that the decision was made consciously, before push.
#
# Recognised tokens (at least one must appear after the colon, followed
# by whitespace / end-of-line / one of [.,;] — see TOKEN_RE below for
# the anchored form that prevents `manualish` and friends from matching):
#   manual                — operator did a focused security read of the diff
#   claude-code-security-review — anthropics/claude-code-security-review
#                                 was run (locally or via Action)
#   pr-review-toolkit     — /pr-check or /pr-review-toolkit:review-pr was
#                           run on this branch (a reviewer flagged
#                           security-class issues OR confirmed none)
#   ad-hoc                — informal review (e.g. the diff is small + low-
#                           risk; operator-judged adequate)
#
# `n/a` was considered as a recognised token but rejected — the literal
# string `n/a` appears naturally inside file paths (e.g. `path/n/a.txt`
# typos or comment text), which would gamify the gate. Operators who
# believe the diff has no security surface should use the docs-only
# fast-path below, the `ad-hoc` token, or the `[skip security-review]`
# marker, all of which leave a clearer audit trail.
#
# Skip if changed-file set is docs-only (same `.md` / `.txt` / `docs/` /
# `handovers/` filter the CR-before-push hook uses) — security review
# does not apply.
#
# Bypass:
#   SKIP_SECURITY_REVIEW=1 git push ...    (env-var skip; logs WARNING)
#   `[skip security-review]` in any commit msg being pushed
#   git push --no-verify ...               (skip all pre-push hooks)
#
# Exit codes:
#   0 — pass (docs-only diff, attestation present, or bypass)
#   1 — block (code changed + no attestation + no bypass)
set -euo pipefail

branch=$(git branch --show-current)

# Detached HEAD or main push: skip. no-push-to-main covers main, and we
# can't compute a sensible diff base on detached HEAD.
if [ -z "$branch" ] || [ "$branch" = "main" ]; then
    exit 0
fi

if [ "${SKIP_SECURITY_REVIEW:-0}" = "1" ]; then
    echo "→ security-review: SKIP_SECURITY_REVIEW=1 — skipping (WARNING: confirm security review ran out-of-band before merge)" >&2
    exit 0
fi

# Resolve diff base. Mirror check-platforms-tested.sh — prefer origin/main
# over local main so linked worktrees do not re-flag work already on the
# push target.
if [ "${SECURITY_REVIEW_NO_FETCH:-0}" != "1" ]; then
    git fetch -q origin main 2>/dev/null || true
fi

diff_base=""
if git rev-parse --verify --quiet origin/main >/dev/null; then
    diff_base=origin/main
elif git rev-parse --verify --quiet main >/dev/null; then
    diff_base=main
else
    echo "→ security-review: no 'origin/main' or local 'main' ref — skipping (cannot compute diff)" >&2
    exit 0
fi

changed=$(git diff --name-only "${diff_base}...HEAD" || true)
[ -z "$changed" ] && exit 0

# Docs-only skip — same filter shape as check-cr-before-push.sh:
# *.md, *.txt, docs/**, handovers/** do NOT require security review.
non_docs=$(printf '%s\n' "$changed" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)
if [ -z "$non_docs" ]; then
    echo "→ security-review: docs-only change — skipping" >&2
    exit 0
fi

# Scan commit messages in the push range for `Security reviewed:` line OR
# the `[skip security-review]` opt-out.
commit_msgs=$(git log --format='%B' "${diff_base}..HEAD" 2>/dev/null || true)

# At least ONE recognised token must appear after the colon, followed
# by a token-end character (whitespace, end-of-line, or one of [.,;]).
# Empty (`Security reviewed:`) or unrecognised (`Security reviewed: yes`)
# do NOT count — operators must explicitly pick a method. The token-end
# anchor prevents prefix-gaming substring matches:
#   `Security reviewed: manualish`         -> NO match (no end-anchor after manual)
#   `Security reviewed: please-manual-do`  -> NO match (`-` is not an end-anchor)
#   `Security reviewed: manual`            -> match
#   `Security reviewed: manual.`           -> match
#   `Security reviewed: manual, fix X`     -> match
TOKEN_RE='(manual|claude-code-security-review|pr-review-toolkit|ad-hoc)([[:space:]]|$|[.,;])'
ATTEST_RE="^[[:space:]]*Security reviewed:.*${TOKEN_RE}"

if printf '%s' "$commit_msgs" | grep -qiE '^\s*\[skip security-review\]'; then
    echo "→ security-review: [skip security-review] in commit msg — skipping (WARNING: confirm security review ran out-of-band before merge)" >&2
    exit 0
fi

if printf '%s' "$commit_msgs" | grep -qiE "$ATTEST_RE"; then
    line=$(printf '%s' "$commit_msgs" | grep -iE "$ATTEST_RE" | head -1 | sed 's/^[[:space:]]*//')
    echo "→ security-review: ${line}" >&2
    exit 0
fi

# Fall back to PR body for an open PR on the current branch.
pr_body=""
if command -v gh >/dev/null 2>&1; then
    pr_body=$(gh pr view "$branch" --json body --jq '.body' 2>/dev/null || true)
fi
if [ -n "$pr_body" ] && printf '%s' "$pr_body" | grep -qiE "$ATTEST_RE"; then
    line=$(printf '%s' "$pr_body" | grep -iE "$ATTEST_RE" | head -1 | sed 's/^[[:space:]]*//')
    echo "→ security-review: ${line} (from PR body)" >&2
    exit 0
fi

# Block.
cat >&2 <<EOF
⛔ security-review: this push touches non-docs code but no
   \`Security reviewed:\` attestation was found in commit messages or
   the PR body.

   Non-docs files changed vs ${diff_base}:
$(printf '%s\n' "$non_docs" | sed 's/^/     /')

   Fix one of:
   1. Run a security review (one of):
        - operator manual read of the diff for security-class issues
        - anthropics/claude-code-security-review (slash command or
          GitHub Action)
        - /pr-check or /pr-review-toolkit:review-pr (a reviewer in the
          fanout covers the security lens)
      Then add a line to a commit body (or amend):
          Security reviewed: <token>
      where <token> is one of:
        manual, claude-code-security-review, pr-review-toolkit, ad-hoc
   2. Add the same line to the PR description, then re-push.
   3. Bypass for an unattested push:
          SKIP_SECURITY_REVIEW=1 git push ...
      or include \`[skip security-review]\` in a commit message.

   Why: code changes can carry security-class issues (input handling,
   authn/authz, secrets exposure, command injection, SSRF, etc.) that
   the existing code-review-before-push gate is not specifically tuned
   to catch. This gate forces the security lens to be acknowledged
   before push — the gate does NOT run the review itself, so HIMMEL-128
   (no new headless-claude introductions) is respected.

   See \`docs/security-review.md\` for the suggested review playbook.
EOF
exit 1
