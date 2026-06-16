#!/usr/bin/env bash
# install-plugins — install all Claude Code plugins listed in
# docs/setup/settings-template.json.
#
# Reads `enabledPlugins` (plugin@marketplace keys) and
# `extraKnownMarketplaces` from the template, registers each marketplace
# via `claude plugin marketplace add`, then installs each plugin via
# `claude plugin install <plugin>@<marketplace> --scope <scope>`.
#
# Both CLI calls are idempotent — re-running this script on a fully
# installed machine is a no-op.
#
# Usage:
#   bash install-plugins.sh [--dry-run] [--scope SCOPE] [--template PATH] [--himmel-path PATH]
#
# Flags:
#   --dry-run            Print commands instead of running them.
#   --scope SCOPE        Where to declare the marketplaces + plugins:
#                        user (default, ~/.claude — every project),
#                        project (this repo's .claude/settings.json,
#                        shared on clone), or local (this repo's gitignored
#                        .claude/settings.local.json). For project/local the
#                        target is the CURRENT directory — run from the repo
#                        you want the plugins scoped to.
#   --template PATH      Override default template path.
#   --himmel-path PATH   Override $HIMMEL_PATH used for <himmel-path>
#                        placeholder expansion (defaults to repo root
#                        inferred from script location).
set -euo pipefail

# ── Resolve script + repo paths ─────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
DRY_RUN=0
SCOPE="user"
TEMPLATE="$REPO_ROOT/docs/setup/settings-template.json"
HIMMEL_PATH="$REPO_ROOT"

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --scope)         SCOPE="$2"; shift 2 ;;
    --template)      TEMPLATE="$2"; shift 2 ;;
    --himmel-path)   HIMMEL_PATH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── Validate scope ───────────────────────────────────────────────────────────
case "$SCOPE" in
  user|project|local) ;;
  *) echo "ERROR: invalid --scope: $SCOPE (expected user|project|local)" >&2; exit 2 ;;
esac

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

# ── Expand <himmel-path> in template ─────────────────────────────────────────
EXPANDED=$(sed "s|<himmel-path>|$HIMMEL_PATH|g" "$TEMPLATE")

# ── Register marketplaces ───────────────────────────────────────────────────
echo "──── Registering marketplaces ────"
echo "$EXPANDED" | jq -r '
  .extraKnownMarketplaces
  | to_entries[]
  | .value.source
  | if .source == "github"    then .repo
    elif .source == "directory" then .path
    elif .source == "url"       then .url
    else "UNKNOWN:" + (.|tostring)
    end
' | while read -r SRC; do
  [[ -z "$SRC" || "$SRC" == UNKNOWN:* ]] && { echo "  skip: $SRC"; continue; }
  echo "  marketplace add: $SRC"
  run claude plugin marketplace add "$SRC" --scope "$SCOPE" \
    || echo "    (non-zero — already registered or transient failure)"
done

# ── Install plugins ─────────────────────────────────────────────────────────
echo "──── Installing plugins ($SCOPE scope) ────"
echo "$EXPANDED" | jq -r '.enabledPlugins | keys[]' | while read -r SPEC; do
  echo "  install: $SPEC"
  run claude plugin install "$SPEC" --scope "$SCOPE" \
    || echo "    (non-zero — already installed or transient failure)"
done

echo "──── Done ────"
