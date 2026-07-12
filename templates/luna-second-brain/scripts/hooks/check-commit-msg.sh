#!/usr/bin/env bash
# Validates commit message format.
# Required: conventional commit  type[(scope)]: message
# Optional: TICKET-N prefix after the colon+space (e.g. HIMMEL-119, LUNA-3)
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
STRIPPED=$(printf '%s\n' "${COMMIT_MSG}" | sed '/^#/d' | sed '/^[[:space:]]*$/d')
if [ -z "${STRIPPED}" ]; then
  exit 0
fi

FIRST_LINE=$(printf '%s\n' "${COMMIT_MSG}" | head -1)

# Pattern: type[(scope)][!]: [TICKET-N ]message
# type: feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert
# ticket: any uppercase alpha + digits prefix (HIMMEL, LUNA, ABC, etc.)
CONVENTIONAL_RE='^(feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert)(\([^)]+\))?!?:[[:space:]]+([A-Z][A-Z0-9]+-[0-9]+[[:space:]]+)?[^[:space:]].+'

if ! printf '%s\n' "${FIRST_LINE}" | grep -Eq "${CONVENTIONAL_RE}"; then
  echo ""
  echo "COMMIT REJECTED: message does not match conventional commit format."
  echo ""
  echo "  Required:  type(scope): message"
  echo "  Optional:  type(scope): TICKET-N message"
  echo ""
  echo "  Types: feat fix chore docs refactor test style perf ci build revert"
  echo ""
  echo "  Examples:"
  echo "    feat(vault): add Daily-Note template"
  echo "    fix(setup): HIMMEL-119 correct user-slug fallback"
  echo "    chore: update pre-commit hook versions"
  echo ""
  echo "  Got: ${FIRST_LINE}"
  echo ""
  exit 1
fi

exit 0
