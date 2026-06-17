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
' | tr -d '\r' | while read -r SRC; do
  [[ -z "$SRC" || "$SRC" == UNKNOWN:* ]] && { echo "  skip: $SRC"; continue; }
  echo "  marketplace add: $SRC"
  run claude plugin marketplace add "$SRC" --scope "$SCOPE" \
    || echo "    (non-zero — already registered or transient failure)"
done

# ── Install plugins ─────────────────────────────────────────────────────────
echo "──── Installing plugins ($SCOPE scope) ────"
# tr -d '\r': jq emits CRLF on Windows; a trailing \r would corrupt both the
# install spec and the later presence comparison (INSTALLED_SPECS is \r-free).
SPECS=$(echo "$EXPANDED" | jq -r '.enabledPlugins | keys[]' | tr -d '\r')
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  echo "  install: $SPEC"
  run claude plugin install "$SPEC" --scope "$SCOPE" \
    || echo "    (non-zero — already installed or transient failure)"
done <<< "$SPECS"

# ── Verify (post-install presence check, HIMMEL-361) ─────────────────────────
# `claude plugin install` can legitimately exit non-zero on an already-installed
# plugin, so install exit codes can't tell a real failure from an idempotent
# no-op — which is exactly how a failed handover@himmel install used to look
# identical to "already installed". Verify by PRESENCE instead: list the
# installed plugins and confirm every enabledPlugins spec is there. Skipped
# under --dry-run (nothing was installed).
if [[ $DRY_RUN -eq 1 ]]; then
  echo "──── Done (dry-run; verify skipped) ────"
  exit 0
fi

echo "──── Verifying installed plugins ────"
# Fail closed: a verify step that cannot run has confirmed NOTHING, so it must
# not report success — that silent pass is the exact bug HIMMEL-361 kills. The
# pre-flight already proved `claude` is on PATH, so a `list` failure here is a
# real anomaly. Capture stderr (2>&1) so the operator sees WHY it failed.
if ! INSTALLED=$(claude plugin list 2>&1); then
  echo "ERROR: 'claude plugin list' failed — cannot verify plugin installs:" >&2
  # shellcheck disable=SC2001
  # Per-line indent — parameter expansion doesn't replicate sed's per-line anchor cleanly.
  echo "$INSTALLED" | sed 's/^/    /' >&2
  exit 1
fi
# Pull the bare <plugin>@<marketplace> tokens out of the list output (grep -oE);
# the exact whole-line compare happens below via `grep -qxF`, which is what
# avoids substring/prefix false-positives.
INSTALLED_SPECS=$(echo "$INSTALLED" | grep -oE '[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' || true)

MISSING=()
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  grep -qxF "$SPEC" <<< "$INSTALLED_SPECS" || MISSING+=("$SPEC")
done <<< "$SPECS"

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: ${#MISSING[@]} plugin(s) not present after install:" >&2
  for SPEC in "${MISSING[@]}"; do
    echo "    $SPEC — retry: claude plugin install $SPEC --scope $SCOPE" >&2
  done
  exit 1
fi

echo "  All $(grep -c . <<< "$SPECS") enabled plugins present."
echo "──── Done ────"
