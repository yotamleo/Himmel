#!/usr/bin/env bash
# Validates commit message format.
# Required: conventional commit  type[(scope)]: message
# Optional: HIMMEL-N ticket ID after the colon+space
# Skips:    merge commits, fixup/squash commits, revert commits

COMMIT_MSG_FILE="${1}"
COMMIT_MSG=$(cat "${COMMIT_MSG_FILE}")

# Skip merge commits
if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
  exit 0
fi

# Skip fixup/squash/revert generated messages
case "${COMMIT_MSG}" in
  fixup!*|squash!*|revert!*|Revert*|Merge*)
    exit 0
    ;;
esac

# Skip empty or comment-only messages
STRIPPED=$(echo "${COMMIT_MSG}" | sed '/^#/d' | sed '/^[[:space:]]*$/d')
if [ -z "${STRIPPED}" ]; then
  exit 0
fi

FIRST_LINE=$(echo "${COMMIT_MSG}" | head -1)

# Pattern: type[(scope)][!]: [HIMMEL-N ]message
# type: feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert
CONVENTIONAL_RE='^(feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert)(\([^)]+\))?!?:[[:space:]]+(HIMMEL-[0-9]+[[:space:]]+)?[^[:space:]].+'

if ! echo "${FIRST_LINE}" | grep -Eq "${CONVENTIONAL_RE}"; then
  echo ""
  echo "COMMIT REJECTED: message does not match conventional commit format."
  echo ""
  echo "  Required:  type(scope): message"
  echo "  Optional:  type(scope): HIMMEL-N message"
  echo ""
  echo "  Types: feat fix chore docs refactor test style perf ci build revert"
  echo ""
  echo "  Examples:"
  echo "    feat(auth): add JWT validation"
  echo "    fix(api): HIMMEL-23 correct status code on 404"
  echo "    chore: update dependencies"
  echo ""
  echo "  Got: ${FIRST_LINE}"
  echo ""
  exit 1
fi

exit 0
