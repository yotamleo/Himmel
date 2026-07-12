#!/usr/bin/env bash
# preflight-adopter.sh — standalone check-only adopter preflight (HIMMEL-842
# fix-batch). An adopter can run this BEFORE committing to adopt.sh to surface
# the common fresh-machine gaps (uv/pipx, npm-less distro node, unbuilt
# scripts/jira/dist) in one pass, instead of discovering them one `set -e`
# abort at a time across three downstream scripts.
#
# Sources scripts/lib/preflight-adopter.sh — the SAME shared checks adopt.sh
# calls — so the two entry points can never drift (operator answer Q4: "BOTH
# standalone check-only AND auto-invoked").
#
# Advisory-first, matching adopt.sh's WARN-not-fail culture: prints WARN lines
# and ALWAYS exits 0 unless --strict is passed (then any WARN exits 1, for use
# in CI / a verification pass where "does this reach zero warnings" is the thing
# being measured). No fixes are applied — adopt.sh does the building; this only
# reports.
#
# Usage:
#   bash scripts/preflight-adopter.sh [--strict]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Exported: the sourced lib's preflight_check_jira_dist reads $HIMMEL_ROOT.
HIMMEL_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
export HIMMEL_ROOT

STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/preflight-adopter.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/preflight-adopter.sh"

echo "==> himmel adopter preflight (check-only)"

# Run each shared check, counting how many WARN. The `||` capture keeps a
# non-zero return (gap detected) from aborting under set -e and lets every check
# run so all gaps surface in one pass. adopt.sh calls these same functions, so
# the two entry points can never drift.
warns=0
preflight_check_uv_pipx       || warns=$((warns + 1))
preflight_check_npm_invocable || warns=$((warns + 1))
preflight_check_jira_dist     || warns=$((warns + 1))

if [ "$warns" -gt 0 ]; then
  echo "──── $warns warning(s). adopt.sh will warn on these too."
  echo "──── Re-run with --strict to exit non-zero on any warning."
else
  echo "──── preflight clean (0 warnings)."
fi

if [ "$STRICT" -eq 1 ] && [ "$warns" -gt 0 ]; then
  exit 1
fi
exit 0
