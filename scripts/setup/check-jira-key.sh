#!/usr/bin/env bash
# JIRA_PROJECT_KEY verify (HIMMEL-146; optionality gate HIMMEL-285).
#
# Usage: bash scripts/setup/check-jira-key.sh <required|optional>
#
#   required  (--with-jira)   unset key -> loud error + rc=1 (setup aborts)
#   optional  (default)       unset key -> one-line skip notice + rc=0
#   key set                   echo it + rc=0 (either mode)
#
# Extracted from setup.sh step 0.4 so the gating logic is hermetic-
# testable (test-check-jira-key.sh; precedent: test-install-cs.sh).
set -euo pipefail

mode="${1:-optional}"
case "$mode" in
  required|optional) ;;
  *) echo "usage: check-jira-key.sh <required|optional>" >&2; exit 2 ;;
esac

if [ -n "${JIRA_PROJECT_KEY:-}" ]; then
  echo "  JIRA_PROJECT_KEY=$JIRA_PROJECT_KEY"
  exit 0
fi

if [ "$mode" = "required" ]; then
  cat >&2 <<'JIRA_KEY_ERR'
ERROR: JIRA_PROJECT_KEY is not set.

--with-jira requires JIRA_PROJECT_KEY (e.g. ACME, HIMMEL).
No hardcoded fallback as of HIMMEL-146.

Fix:
  1. Add JIRA_PROJECT_KEY=<your-key> to .env (see .env.example).
  2. Or export it in the shell that launches setup.sh.

Then re-run: bash scripts/setup.sh --with-jira
JIRA_KEY_ERR
  exit 1
fi

echo "  Skipped: JIRA_PROJECT_KEY not set (Jira is optional without --with-jira)."
echo "  Jira-dependent steps will be skipped; set JIRA_* in .env and re-run with --with-jira to enable."
exit 0
