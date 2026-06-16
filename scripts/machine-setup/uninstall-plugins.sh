#!/usr/bin/env bash
# uninstall-plugins — remove all Claude Code plugins listed in
# docs/setup/settings-template.json. Mirror of install-plugins.sh
# (HIMMEL-227 offboard).
#
# Reads `enabledPlugins` (plugin@marketplace keys) and uninstalls each via
# `claude plugin uninstall <plugin>@<marketplace>`, then removes each
# marketplace in `extraKnownMarketplaces` via
# `claude plugin marketplace remove <name>` (plugins first — a marketplace
# with installed plugins may refuse removal).
#
# WARNING: plugins are user-scope — removing them affects EVERY repo on
# this machine, not just himmel. Run via scripts/uninstall.sh (which
# gates on confirmation) or pass --dry-run first.
#
# Each CLI call's exit code is checked: failures are WARNed per call,
# counted, and the script exits 1 if any call failed (so the calling
# uninstall.sh can surface it). A not-installed plugin / unregistered
# marketplace also reports non-zero — inspect the per-call WARN lines.
#
# Usage:
#   bash uninstall-plugins.sh [--dry-run] [--template PATH]
#
# Flags:
#   --dry-run            Print commands instead of running them.
#   --template PATH      Override default template path.
set -euo pipefail

# ── Resolve script + repo paths ─────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
DRY_RUN=0
TEMPLATE="$REPO_ROOT/docs/setup/settings-template.json"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --template)      TEMPLATE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── Pre-flight ──────────────────────────────────────────────────────────────
[[ -f "$TEMPLATE" ]] || { echo "ERROR: template missing: $TEMPLATE" >&2; exit 1; }
command -v jq      >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
command -v claude  >/dev/null || { echo "ERROR: claude CLI required on PATH" >&2; exit 1; }

# ── Helper: run-or-print ────────────────────────────────────────────────────
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

# No <himmel-path> expansion needed — uninstall consumes only object KEYS
# (plugin specs + marketplace names), and the placeholder only appears in
# values.

# Keys are captured up-front (set -e catches a jq failure here) and the
# loops run in THIS shell, not a `jq | while` pipeline subshell — otherwise
# the failure counter would be lost when the subshell exits.
PLUGIN_SPECS="$(jq -r '.enabledPlugins | keys[]' "$TEMPLATE")"
MARKETPLACES="$(jq -r '.extraKnownMarketplaces | keys[]' "$TEMPLATE")"
FAILURES=0

# ── Uninstall plugins ───────────────────────────────────────────────────────
echo "──── Uninstalling plugins ────"
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  echo "  uninstall: $SPEC"
  _rc=0
  run claude plugin uninstall "$SPEC" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    echo "    WARN: uninstall failed (rc=$_rc) — not installed, or a transient failure" >&2
    FAILURES=$((FAILURES + 1))
  fi
done <<EOF
$PLUGIN_SPECS
EOF

# ── Remove marketplaces ─────────────────────────────────────────────────────
echo "──── Removing marketplaces ────"
while IFS= read -r NAME; do
  [[ -z "$NAME" ]] && continue
  echo "  marketplace remove: $NAME"
  _rc=0
  run claude plugin marketplace remove "$NAME" || _rc=$?
  if [[ $_rc -ne 0 ]]; then
    echo "    WARN: marketplace remove failed (rc=$_rc) — not registered, or a transient failure" >&2
    FAILURES=$((FAILURES + 1))
  fi
done <<EOF
$MARKETPLACES
EOF

echo "──── Done ────"
if [[ $FAILURES -gt 0 ]]; then
  echo "WARN: $FAILURES uninstall/remove call(s) failed — inspect the lines above." >&2
  exit 1
fi
