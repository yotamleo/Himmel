#!/usr/bin/env bash
# JIRA_PROJECT_KEY verify (HIMMEL-146; optionality gate HIMMEL-285).
#
# Usage: bash scripts/setup/check-jira-key.sh <required|optional>
#
#   required  (--with-jira)   unset key -> loud error + rc=1 (setup aborts)
#   optional  (default)       unset key -> one-line skip notice + rc=0
#   key set                   echo it + rc=0 (either mode)
#   tracker not jira          (HIMMEL-4758) a set key no longer counts: the
#                             tracker comes from scripts/lib/project-mode.sh
#                             (TRACKER > git config himmel.tracker > jira when
#                             the key is set); required -> rc=1, optional -> skip
#   TRACKER=jira, no key     rc=1 in EITHER mode: an explicit jira tracker
#                             without a key is a config error, not a skip
#
# Extracted from setup.sh step 0.4 so the gating logic is hermetic-
# testable (test-check-jira-key.sh).
set -euo pipefail

mode="${1:-optional}"
case "$mode" in
  required|optional) ;;
  *) echo "usage: check-jira-key.sh <required|optional>" >&2; exit 2 ;;
esac

# shellcheck source=../lib/project-mode.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/project-mode.sh"
tracker=$(project_mode_tracker) || exit 1
if [ "$tracker" = jira ]; then
  echo "  JIRA_PROJECT_KEY=$JIRA_PROJECT_KEY"
  exit 0
fi
note="  (tracker resolved to '$tracker' — scripts/lib/project-mode.sh: TRACKER, git config himmel.tracker, else jira when JIRA_PROJECT_KEY is set)"
# A placeholder key separates "no key" (detection says local) from an
# explicit TRACKER / himmel.tracker of local or none, which a key never beats.
if [ "$(JIRA_PROJECT_KEY=X project_mode_tracker)" != jira ]; then
  if [ "$mode" = "required" ]; then
    echo "ERROR: --with-jira needs the jira tracker, but JIRA_PROJECT_KEY is overridden." >&2
    echo "$note" >&2
    exit 1
  fi
  echo "  Skipped: the tracker is not jira, so Jira-dependent steps will be skipped."
  echo "$note"
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
  echo "$note" >&2
  exit 1
fi

echo "  Skipped: JIRA_PROJECT_KEY not set (Jira is optional without --with-jira)."
echo "  Jira-dependent steps will be skipped; set JIRA_* in .env and re-run with --with-jira to enable."
echo "$note"
exit 0
