#!/usr/bin/env bash
# scripts/cloud/check-env.sh — the cloud environment, declared and self-checked
# (HIMMEL-5163). A claude.ai cloud environment cannot be created or read back
# from a repo file or a command, so the dialog stays a paste. This keeps that
# paste to one checked-in source and lets a session say when its environment
# differs from the repo.
#
# Usage:
#   check-env.sh            compare this session to the repo: every variable in
#                           scripts/cloud/environment.env, and the setup script
#                           that built the cached snapshot. Exit 0 all match,
#                           1 on any mismatch (each named on its own line).
#   check-env.sh --print    print the dialog fields (name, network, variables,
#                           setup script) from the declaration, using this
#                           checkout's origin as the clone URL.
#   check-env.sh --stamp    record the hash of setup-env.sh (the setup script
#                           calls this as its last step).
#
# Test seams: HIMMEL_CLOUD_ROOT (tree to act on), HIMMEL_CLOUD_MARKER (stamp).
set -uo pipefail

ROOT="${HIMMEL_CLOUD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DECL="$ROOT/scripts/cloud/environment.env"
SETUP="$ROOT/scripts/cloud/setup-env.sh"
MARKER="${HIMMEL_CLOUD_MARKER:-${TMPDIR:-/tmp}/himmel-setup-logs/setup-env.sha256}"
UPSTREAM_URL="https://github.com/yotamleo/Himmel"

sha() { # sha <file>: sha256 hex, GNU or BSD
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

decl_vars() { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$DECL"; }

case "${1:-}" in
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
  --stamp)
    [ -f "$SETUP" ] || { echo "check-env: $SETUP missing" >&2; exit 1; }
    mkdir -p "$(dirname "$MARKER")" && sha "$SETUP" > "$MARKER"
    exit $? ;;
  --print)
    [ -f "$DECL" ] || { echo "check-env: $DECL missing" >&2; exit 1; }
    url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || url=""
    case "$url" in
      git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
      ssh://git@github.com/*) url="https://github.com/${url#ssh://git@github.com/}" ;;
      https://github.com/*) ;;
      *) url="$UPSTREAM_URL" ;;
    esac
    url="${url%.git}"
    rev="$(sed -n 's/^# rev: *\([0-9][0-9]*\).*/\1/p' "$DECL" | head -n 1)"
    echo "Name:           himmel"
    echo "Network access: Trusted"
    echo
    echo "Environment variables:"
    decl_vars | sed 's/^/  /'
    echo
    echo "Setup script:"
    echo "#!/bin/bash"
    echo "# rev: ${rev:-1}"
    echo "rm -rf /tmp/himmel-setup \\"
    echo "  && git clone --depth 1 $url /tmp/himmel-setup \\"
    echo "  && bash /tmp/himmel-setup/scripts/cloud/setup-env.sh --with-plugins || true"
    exit 0 ;;
  "") ;;
  *) echo "check-env: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

[ -f "$DECL" ] || { echo "check-env: $DECL missing" >&2; exit 1; }
bad=0
while IFS='=' read -r k v; do
  actual="${!k:-}"
  if [ "$actual" = "$v" ]; then
    echo "env $k ok"
  else
    echo "env $k MISMATCH expected=$v actual=${actual:-<unset>}"
    bad=1
  fi
done < <(decl_vars)

if [ ! -f "$MARKER" ]; then
  echo "setup-script MISSING no stamp at $MARKER (setup script not run, or an older one)"
  bad=1
elif [ "$(cat "$MARKER")" = "$(sha "$SETUP")" ]; then
  echo "setup-script ok"
else
  echo "setup-script STALE the cached snapshot ran an older setup-env.sh; bump '# rev:' in the dialog's setup script to rebuild"
  bad=1
fi

[ "$bad" -eq 0 ] || echo "check-env: this environment differs from scripts/cloud/environment.env; fix the dialog from: bash scripts/cloud/check-env.sh --print" >&2
exit "$bad"
