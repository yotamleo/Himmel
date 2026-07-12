#!/usr/bin/env bash
# Helper: prints `mode: <A|B>  root: <path>` to stdout.
# Used by setup.ps1 to surface handover-root state from PowerShell
# without dealing with PS quoting + EAP=Stop interaction.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/handover-path.sh"
_root=$(handover_root_ensure)
_mode=$(handover_mode)
echo "mode: $_mode  root: $_root"
