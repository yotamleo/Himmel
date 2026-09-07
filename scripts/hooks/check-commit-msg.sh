#!/usr/bin/env bash
# Validates commit message format.
# Required: conventional commit  type[(scope)]: message
# A ticket reference is required by DEFAULT (HIMMEL-2442); TICKET_ID_REQUIRED=0
# opts out. The pattern comes from TICKET_ID_PATTERN, else JIRA_PROJECT_KEY
# (PROJECT-N), else himmel's own `#N` enumeration — the no-Jira ticket system
# the handover skill's new-epic/new-task allocates, not a relaxed fallback.
# Skips: merge commits and revert commits. fixup/squash skip only the shape check.

# HIMMEL-2461: resolve the message file, and FAIL CLOSED when there is not one.
# .pre-commit-config.yaml wired this hook with `pass_filenames: false`, so
# pre-commit never handed it the message path: `$1` was empty, `cat ""` failed
# to stderr underneath pre-commit's own "Passed" line, COMMIT_MSG was empty and
# the gate exited 0 — on every commit, including messages that are not
# conventional commits at all. Silence plus rc=0 is exactly how a gate certifies
# nothing for months, so an unreadable message is now a rejection naming the
# wiring, never a pass. The .git/COMMIT_EDITMSG fallback keeps the hook working
# under any other wiring that invokes it with no argument.
COMMIT_MSG_FILE="${1:-}"
if [ -z "${COMMIT_MSG_FILE}" ]; then
  COMMIT_MSG_FILE=$(git rev-parse --git-path COMMIT_EDITMSG 2>/dev/null || true)
fi
if [ -z "${COMMIT_MSG_FILE}" ] || [ ! -f "${COMMIT_MSG_FILE}" ] || [ ! -r "${COMMIT_MSG_FILE}" ]; then
  echo "COMMIT REJECTED: the commit-msg hook received no readable message file." >&2
  echo "  \$1 was '${1:-}'; the .git/COMMIT_EDITMSG fallback resolved to '${COMMIT_MSG_FILE:-<none>}'." >&2
  echo "  This is a HOOK WIRING fault, not a bad message. Check that the" >&2
  echo "  conventional-commit-msg entry in .pre-commit-config.yaml does NOT set" >&2
  echo "  'pass_filenames: false' — that starves this hook of the message and" >&2
  echo "  made it certify every commit." >&2
  exit 1
fi
if ! COMMIT_MSG=$(cat "${COMMIT_MSG_FILE}" 2>/dev/null); then
  echo "COMMIT REJECTED: could not read the commit-message file '${COMMIT_MSG_FILE}'." >&2
  echo "  This is a HOOK WIRING fault, not a bad message (see above)." >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load ticket configuration from the primary checkout's .env. Live env wins.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
if . "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null; then
  load_dotenv TICKET_ID_REQUIRED TICKET_ID_PATTERN TICKET_ID_EXEMPT_AUTHORS JIRA_PROJECT_KEY || true
fi

# HIMMEL-2183: WARN-only negative-existence claim linter. Never blocks (exit
# code is untouched) and fails open on any error inside it — a broken regex
# or a garbled line must degrade to silence, not to a crash or a false deny.
warn_negative_existence_claims() {
  local msg="$1"
  local neg_re="we don't have|doesn't exist|isn't implemented|no [A-Za-z0-9_./-]+( [A-Za-z0-9_./-]+){0,3} found"
  # shellcheck disable=SC2016 # single-quoted on purpose — the backtick is a literal regex char, not an expansion
  local evidence_re='`[^`]+`|(^|[^A-Za-z0-9_.-])[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*\.[A-Za-z0-9]+|(^|[^A-Za-z0-9_])(scripts|docs|src|lib|test|tests|marketplace|templates)/|rg |grep |JQL|gh '
  local lines=()
  local line
  while IFS= read -r line; do
    lines+=("$line")
  done <<EOF
$msg
EOF
  local n=${#lines[@]}
  local i=0
  while [ "$i" -lt "$n" ]; do
    local cur="${lines[$i]}"
    local phrase
    phrase=$(printf '%s\n' "$cur" | grep -Eio "$neg_re" 2>/dev/null | head -1)
    if [ -n "$phrase" ]; then
      local ctx="$cur"
      [ "$i" -gt 0 ] && ctx="${lines[$((i-1))]}
$ctx"
      [ "$((i+1))" -lt "$n" ] && ctx="$ctx
${lines[$((i+1))]}"
      local evidence
      evidence=$(printf '%s\n' "$ctx" | grep -Eo "$evidence_re" 2>/dev/null | head -1)
      if [ -z "$evidence" ]; then
        echo "WARN check-commit-msg: negative-existence claim (\"${phrase}\") — add a file path, command output, or Jira JQL next to this claim." >&2
      fi
    fi
    i=$((i + 1))
  done
}
warn_negative_existence_claims "${COMMIT_MSG}" || true

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
  echo "  Ticket:    required by default; TICKET_ID_REQUIRED=0 opts out"
  echo ""
  echo "  Types: feat fix chore docs refactor test style perf ci build revert"
  echo ""
  echo "  Examples:"
  echo "    feat(auth): [#12] add JWT validation"
  echo "    fix(api): PROJECT-23 correct status code on 404"
  echo "    chore: [#13] update dependencies"
  echo ""
  echo "  Got: ${FIRST_LINE}"
  echo ""
  exit 1
fi

# HIMMEL-2442: default ON. An adopter with no .env at all is gated; the
# explicit opt-out is TICKET_ID_REQUIRED=0.
#
# CR3: normalize case instead of enumerating spellings. This arm used to list
# only `false|FALSE`, while the .ps1 twin's `switch -Regex` is case-insensitive
# by DEFAULT — so `TICKET_ID_REQUIRED=False` in one .env silently disabled the
# gate on Windows and rejected the commit as invalid config under bash. A
# half-enumerated grammar is what diverged; normalizing closes it for every
# spelling at once rather than adding two more arms.
TICKET_REQUIRED_RAW="${TICKET_ID_REQUIRED:-1}"
TICKET_REQUIRED=$(printf '%s' "${TICKET_REQUIRED_RAW}" | tr '[:upper:]' '[:lower:]')
case "${TICKET_REQUIRED}" in
  0|false|off|no) exit 0 ;;
  1|true|on|yes) ;;
  *)
    echo "COMMIT REJECTED: invalid TICKET_ID_REQUIRED='${TICKET_REQUIRED_RAW}'. Use 1/true/on/yes or 0/false/off/no." >&2
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
# CR2: a bare `#[0-9]+` matches INSIDE a longer token, so a CSS colour like
# `#123abc` satisfies the gate as ticket "#123" — defeating the traceability
# this default exists to provide, in exactly the no-Jira repos it targets. The
# boundaries are spelled with character classes rather than `\b` so the SAME
# regex works under GNU `grep -E` and the .ps1 twin's .NET engine. The
# JIRA_PROJECT_KEY-derived pattern above has the same looseness; that is
# pre-existing behaviour and deliberately not changed here.
TICKET_PATTERN="${TICKET_PATTERN:-(^|[^0-9A-Za-z_])#[0-9]+([^0-9A-Za-z_]|$)}"

printf '%s\n' "${COMMIT_MSG}" | grep -Eq "${TICKET_PATTERN}"
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 2 ]; then
    echo "COMMIT REJECTED: invalid TICKET_ID_PATTERN regex: ${TICKET_PATTERN}" >&2
  else
    echo "COMMIT REJECTED: no ticket reference matched: ${TICKET_PATTERN}" >&2
    echo "  That is the only pattern in force. It is chosen in this order:" >&2
    echo "    1. TICKET_ID_PATTERN  — your own regex, if set" >&2
    echo "    2. JIRA_PROJECT_KEY   — gives PROJECT-123, if set" >&2
    echo "    3. #123               — himmel's own enumeration, the default when neither is set" >&2
    echo "  Get an #N from '/handover new-epic' or '/handover new-task' (it allocates the next free number)." >&2
    echo "  Opt out entirely with TICKET_ID_REQUIRED=0 in the repo's .env or the environment." >&2
    echo "  Merge commits, revert commits, and TICKET_ID_EXEMPT_AUTHORS are exempt." >&2
  fi
  exit 1
fi

exit 0
