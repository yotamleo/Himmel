#!/usr/bin/env bash
# Helper: prints `<slug>` to stdout on success, error message to stderr.
# Used by setup.ps1 to surface USER_SLUG resolution from PowerShell
# without dealing with PS quoting + EAP=Stop interaction.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=user-slug.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/user-slug.sh"
user_slug_verify
