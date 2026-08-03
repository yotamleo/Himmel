#!/usr/bin/env bash
# Validates commit message format.
# Required: conventional commit  type[(scope)]: message
# Strict mode (TICKET_ID_REQUIRED=1): message must reference the configured ticket.
# Skips: merge commits and revert commits. fixup/squash skip only the shape check.

COMMIT_MSG_FILE="${1}"
COMMIT_MSG=$(cat "${COMMIT_MSG_FILE}")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load ticket configuration from the primary checkout's .env. Live env wins.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
if . "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null; then
  load_dotenv TICKET_ID_REQUIRED TICKET_ID_PATTERN TICKET_ID_EXEMPT_AUTHORS JIRA_PROJECT_KEY || true
fi

# Skip real merge commits. MERGE_HEAD exists while Git is composing the commit.
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  exit 0
fi

FIRST_LINE=$(printf '%s\n' "${COMMIT_MSG}" | head -1)

# Git-generated revert commits are exempt from both checks. fixup/squash retain
# their generated shape, but strict mode still requires the referenced ticket.
# HIMMEL-1483 CR1: the reverted hash must resolve to a real commit object
# (git cat-file -e <hash>^{commit}); a revert-shaped MESSAGE alone is not
# enough, or a hand-typed revert with a fabricated hash bypasses both the
# conventional-format and the strict ticket check. On resolution failure fall
# through to normal validation — never hard-reject on resolution alone (a
# genuine revert under shallow history still deserves a verdict, not an opaque
# deny).
if printf '%s\n' "${FIRST_LINE}" | grep -Eq '^Revert ".+"$'; then
  REVERT_LINE=$(printf '%s\n' "${COMMIT_MSG}" | grep -E '^This reverts commit ([0-9a-fA-F]{40}|[0-9a-fA-F]{64})\.$' | head -1)
  if [ -n "${REVERT_LINE}" ]; then
    REVERTED_HASH="${REVERT_LINE#This reverts commit }"
    REVERTED_HASH="${REVERTED_HASH%.}"
    if git cat-file -e "${REVERTED_HASH}^{commit}" >/dev/null 2>&1; then
      exit 0
    fi
  fi
fi
case "${FIRST_LINE}" in
  fixup!*|squash!*) SKIP_CONVENTIONAL=1 ;;
  *) SKIP_CONVENTIONAL=0 ;;
esac

# Skip empty or comment-only messages
STRIPPED=$(printf '%s\n' "${COMMIT_MSG}" | sed '/^#/d' | sed '/^[[:space:]]*$/d')
if [ -z "${STRIPPED}" ]; then
  exit 0
fi

# Pattern: type[(scope)][!]: message
# type: feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert
CONVENTIONAL_RE='^(feat|fix|chore|docs|refactor|test|style|perf|ci|build|revert)(\([^)]+\))?!?:[[:space:]]+[^[:space:]].+'

if [ "${SKIP_CONVENTIONAL}" -eq 0 ] && ! printf '%s\n' "${FIRST_LINE}" | grep -Eq "${CONVENTIONAL_RE}"; then
  echo ""
  echo "COMMIT REJECTED: message does not match conventional commit format."
  echo ""
  echo "  Required:  type(scope): message"
  echo "  Ticket:    required only when TICKET_ID_REQUIRED=1"
  echo ""
  echo "  Types: feat fix chore docs refactor test style perf ci build revert"
  echo ""
  echo "  Examples:"
  echo "    feat(auth): add JWT validation"
  echo "    fix(api): PROJECT-23 correct status code on 404"
  echo "    chore: update dependencies"
  echo ""
  echo "  Got: ${FIRST_LINE}"
  echo ""
  exit 1
fi

case "${TICKET_ID_REQUIRED:-0}" in
  ''|0|false|FALSE|off|OFF|no|NO) exit 0 ;;
  1|true|TRUE|on|ON|yes|YES) ;;
  *)
    echo "COMMIT REJECTED: invalid TICKET_ID_REQUIRED='${TICKET_ID_REQUIRED}'. Use 1/true/on/yes or 0/false/off/no." >&2
    exit 1
    ;;
esac

AUTHOR_NAME="${TICKET_ID_AUTHOR:-${GIT_AUTHOR_NAME:-}}"
if [ -z "${AUTHOR_NAME}" ]; then
  AUTHOR_IDENT=$(git var GIT_AUTHOR_IDENT 2>/dev/null || true)
  AUTHOR_NAME=${AUTHOR_IDENT%% <*}
fi
EXEMPT_AUTHORS="${TICKET_ID_EXEMPT_AUTHORS:-dependabot[bot],dependabot}"
AUTHOR_EXEMPT=0
TRUSTED_AUTHOR_EXEMPT=0
OLD_IFS=$IFS
IFS=','
# HIMMEL-1483 CR2: the unquoted expansion below is deliberate (field split on
# IFS) but must not ALSO pathname-expand — `dependabot[bot]` is a glob, and a
# file like `dependabotb` in the repo root would replace it and silently break
# the exemption. Globbing off for the split, restored right after.
set -f
for EXEMPT_AUTHOR in $EXEMPT_AUTHORS; do
  EXEMPT_AUTHOR=$(printf '%s' "$EXEMPT_AUTHOR" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -n "$EXEMPT_AUTHOR" ] && [ "$(printf '%s' "$AUTHOR_NAME" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$EXEMPT_AUTHOR" | tr '[:upper:]' '[:lower:]')" ]; then
    AUTHOR_EXEMPT=1
  fi
  if [ -n "$EXEMPT_AUTHOR" ] && [ -n "${TICKET_ID_TRUSTED_AUTHOR:-}" ] && [ "$(printf '%s' "$TICKET_ID_TRUSTED_AUTHOR" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$EXEMPT_AUTHOR" | tr '[:upper:]' '[:lower:]')" ]; then
    TRUSTED_AUTHOR_EXEMPT=1
  fi
done
set +f
IFS=$OLD_IFS
if [ "$AUTHOR_EXEMPT" -eq 1 ] && { [ -z "${TICKET_ID_TRUSTED_AUTHOR+x}" ] || [ "$TRUSTED_AUTHOR_EXEMPT" -eq 1 ]; }; then
  exit 0
fi

TICKET_PATTERN="${TICKET_ID_PATTERN:-}"
if [ -z "${TICKET_PATTERN}" ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
  ESCAPED_PROJECT_KEY=$(printf '%s' "${JIRA_PROJECT_KEY}" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  TICKET_PATTERN="${ESCAPED_PROJECT_KEY}-[0-9]+"
fi
if [ -z "${TICKET_PATTERN}" ]; then
  echo "COMMIT REJECTED: TICKET_ID_REQUIRED=1 but no ticket pattern is configured." >&2
  echo "  Set JIRA_PROJECT_KEY (for PROJECT-N) or TICKET_ID_PATTERN (for another ticket system)." >&2
  exit 1
fi

printf '%s\n' "${COMMIT_MSG}" | grep -Eq "${TICKET_PATTERN}"
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 2 ]; then
    echo "COMMIT REJECTED: invalid TICKET_ID_PATTERN regex: ${TICKET_PATTERN}" >&2
  else
    echo "COMMIT REJECTED: TICKET_ID_REQUIRED=1 but no ticket reference matched: ${TICKET_PATTERN}" >&2
    echo "  Merge commits, revert commits, and TICKET_ID_EXEMPT_AUTHORS are exempt." >&2
  fi
  exit 1
fi

exit 0
