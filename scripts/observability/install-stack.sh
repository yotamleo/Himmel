#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
HIMMEL-922 Phase A only ships the Windows local stack installer.

Cross-platform packaging belongs to the ratified Phase B design. This script is
intentionally a loud placeholder so brew/apt/Docker behavior is not
half-implemented ahead of that phase.
EOF
exit 2
